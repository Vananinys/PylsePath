import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notification_permission_service.dart';
import '../config.dart';
import '../config/app_variant.dart';
import '../models/chat_message.dart';
import '../utils/notification_identity.dart';
import 'chat_service.dart';
import 'notification_service.dart';

/// Notification payloads are displayed by FCM in background/terminated state.
/// Foreground delivery is displayed once by the local notification plugin.
@pragma('vm:entry-point')
Future<void> pulsePathBackgroundMessage(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) await Firebase.initializeApp();
  // Do not show a second notification: FCM already displays notification payloads.
  if (message.notification == null && message.data['type'] == 'chat') {
    await ensureNotificationSession();
    await PushService.instance._ensureLocalNotifications();
    if (message.data['showPreview'] == 'true') {
      final id = message.data['messageId']?.toString();
      if (id != null) {
        final row = await ChatService()
            .fetchMessage(id)
            .timeout(const Duration(seconds: 5), onTimeout: () => null);
        if (row != null &&
            row.receiverId == message.data['receiverId'] &&
            row.senderId == message.data['senderId']) {
          if (row.isRead) return;
          final body = row.isVideo
              ? '🎬 Видео'
              : row.isPhoto
              ? '📷 Фото'
              : row.isVoice
              ? '🎤 Голосовое сообщение'
              : row.isStickerOnly
              ? 'Стикер ${row.sticker}'
              : row.body ?? '';
          message = RemoteMessage(data: {...message.data, 'body': body});
        }
      }
    }
    await PushService.instance._onForeground(message, background: true);
  }
}

Future<void> ensureNotificationSession() async {
  try {
    Supabase.instance.client;
  } catch (_) {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabasePublishableKey,
      authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
    );
  }
}

@pragma('vm:entry-point')
void pulsePathNotificationAction(NotificationResponse response) async {
  await ensureNotificationSession();
  await PushService.instance._ensureLocalNotifications();
  await PushService.instance._handleNotificationResponse(response);
}

class PushService {
  PushService._();
  static final instance = PushService._();
  final _localNotifications = FlutterLocalNotificationsPlugin();
  Future<void>? _initFuture;
  Future<void>? _localInitFuture;
  int _workoutReminderGeneration = 0;
  static const _waterNotificationId = 900002;
  bool _ready = false;
  bool _unregistering = false;
  bool notificationsAuthorized = false;
  bool _updateTopicSubscribed = false;
  Future<void> _tokenTail = Future.value();
  StreamSubscription<RemoteMessage>? _tapSubscription;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<String>? _tokenSubscription;
  final Set<String> _seenTaps = {};
  final Set<String> _seenForeground = {};
  bool get _supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static Future<void> prepareBackgroundDelivery() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(pulsePathBackgroundMessage);
    } catch (error) {
      debugPrint('[Push] Firebase configuration missing: $error');
    }
  }

  Future<void> Function(String senderId)? onChatOpen;
  Future<bool> Function(String messageId)? onInvitationOpen;
  Future<bool> Function(String messageId)? onChatPreview;
  Future<void> Function()? onUpdateOpen;
  Future<void> Function()? onGarageOpen;
  String? _pendingGarageOwner;
  bool _openingGarage = false;
  bool _pendingUpdate = false;
  bool _openingUpdate = false;
  String? _pendingSender;
  String? _pendingReceiver;
  String? _pendingMessage;
  bool _opening = false;
  String? lastError;
  bool get isReady => _ready;
  Future<void> init() async {
    if (!_supported) return;
    try {
      await (_initFuture ??= _initialise());
      if (Platform.isAndroid && !_updateTopicSubscribed) {
        try {
          await FirebaseMessaging.instance.subscribeToTopic(
            AppVariant.updateTopic,
          );
          _updateTopicSubscribed = true;
        } catch (error) {
          debugPrint('[Push] update topic subscription failed: $error');
        }
      }
      final settings = await FirebaseMessaging.instance
          .getNotificationSettings();
      notificationsAuthorized =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
      await _saveToken();
      if (Platform.isIOS) await _drainRemoteActions();
      await flushPendingTap();
    } catch (error) {
      lastError = error.toString();
      _initFuture = null;
      debugPrint('[Push] init failed: $error');
    }
  }

  Future<void> _initialise() async {
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
    await _ensureLocalNotifications();
    await _initialisePushDelivery();
    if (Platform.isIOS) {
      _remoteActions.setMethodCallHandler((call) async {
        if (call.method == 'pendingActions') await _drainRemoteActions();
      });
      await _drainRemoteActions();
    }
  }

  static const _remoteActions = MethodChannel(
    'pulsepath/remote_notification_actions',
  );
  bool _drainingRemoteActions = false;
  Future<void> _drainRemoteActions() async {
    if (_drainingRemoteActions) return;
    _drainingRemoteActions = true;
    try {
      while (true) {
        final events =
            await _remoteActions.invokeListMethod<dynamic>('pending') ?? [];
        if (events.isEmpty) break;
        for (final value in events) {
          final event = Map<String, dynamic>.from(value as Map);
          if (Supabase.instance.client.auth.currentUser == null) return;
          await _handleNotificationResponse(
            NotificationResponse(
              notificationResponseType:
                  NotificationResponseType.selectedNotificationAction,
              actionId: event['actionId'] as String?,
              input: event['input'] as String?,
              payload: jsonEncode(event),
            ),
          );
          await _remoteActions.invokeMethod<void>('complete', event['key']);
        }
      }
    } finally {
      _drainingRemoteActions = false;
    }
  }

  Future<void> _ensureLocalNotifications() async {
    try {
      await (_localInitFuture ??= _initialiseLocalNotifications());
    } catch (_) {
      _localInitFuture = null;
      rethrow;
    }
  }

  Future<void> _initialiseLocalNotifications() async {
    const android = AndroidInitializationSettings('ic_stat_pulsepath');
    await _localNotifications.initialize(
      settings: InitializationSettings(
        android: android,
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
          notificationCategories: [
            DarwinNotificationCategory(
              'chat_message',
              actions: [
                DarwinNotificationAction.text(
                  'reply',
                  'Ответить',
                  buttonTitle: 'Отправить',
                  placeholder: 'Сообщение',
                ),
                DarwinNotificationAction.plain('read', 'Прочитано'),
              ],
            ),
          ],
        ),
      ),
      onDidReceiveNotificationResponse: (response) =>
          unawaited(_handleNotificationResponse(response)),
      onDidReceiveBackgroundNotificationResponse: pulsePathNotificationAction,
    );
    final launch = await _localNotifications.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      final response = launch?.notificationResponse;
      if (response != null) unawaited(_handleNotificationResponse(response));
    }
    await _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            'chat_messages',
            'Сообщения',
            importance: Importance.high,
          ),
        );
    await _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            'app_updates',
            'Обновления приложения',
            importance: Importance.high,
          ),
        );
  }

  Future<void> _initialisePushDelivery() async {
    if (Platform.isAndroid) {
      notificationsAuthorized = await NotificationPermissionService.request();
    } else {
      final permission = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      notificationsAuthorized =
          permission.authorizationStatus == AuthorizationStatus.authorized ||
          permission.authorizationStatus == AuthorizationStatus.provisional;
    }
    // iOS must not auto-present AND also show a local foreground notification.
    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(
          alert: false,
          badge: false,
          sound: false,
        );
    // Bind listeners only after successful initialization; retries replace old subscriptions.
    await _tapSubscription?.cancel();
    await _foregroundSubscription?.cancel();
    await _tokenSubscription?.cancel();
    _tapSubscription = FirebaseMessaging.onMessageOpenedApp.listen(_onPushTap);
    _foregroundSubscription = FirebaseMessaging.onMessage.listen((message) {
      unawaited(_onForeground(message));
    });
    _tokenSubscription = FirebaseMessaging.instance.onTokenRefresh.listen((
      token,
    ) {
      unawaited(_saveToken(token: token));
    });
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _onPushTap(initial);
    _ready = true;
    lastError = notificationsAuthorized
        ? null
        : 'Разрешение на уведомления не выдано';
  }

  final Set<String> _shownMessages = {};

  Future<void> showIncomingChat(
    AppNotification item,
    ChatMessage message,
  ) async {
    if (!_supported || ChatService.openChatFriendId == message.senderId) return;
    await _ensureLocalNotifications();
    await _onForeground(
      RemoteMessage(
        data: {
          'type': 'chat',
          'senderId': message.senderId,
          'receiverId': message.receiverId,
          'messageId': message.id,
          'title': item.title,
          'body': item.subtitle,
        },
      ),
      background: true,
    );
  }

  Future<void> _handleNotificationResponse(
    NotificationResponse response,
  ) async {
    if (response.actionId != 'reply' && response.actionId != 'read') {
      _onLocalTap(response.payload);
      return;
    }
    var replySent = false;
    try {
      final payload =
          jsonDecode(response.payload ?? '') as Map<String, dynamic>;
      final owner = payload['receiverId'] as String?;
      final sender = payload['senderId'] as String?;
      final messageId = payload['messageId'] as String?;
      final chat = ChatService();
      if (owner == null ||
          chat.userId != owner ||
          sender == null ||
          messageId == null) {
        return;
      }
      final message = await chat.fetchMessage(messageId);
      if (chat.userId != owner) return;
      if (message == null) {
        throw const ChatServiceException(
          'Сообщение недоступно. Проверьте соединение',
        );
      }
      if (message.receiverId != owner ||
          message.senderId != sender ||
          chat.userId != owner) {
        return;
      }
      if (response.actionId == 'reply') {
        final text = response.input?.trim() ?? '';
        if (text.isEmpty) return;
        final sent = await chat.sendMessage(
          sender,
          text: text,
          replyToId: messageId,
          messageId: notificationReplyId(owner, messageId, text),
          retry: true,
        );
        if (sent == null) {
          throw const ChatServiceException('Ответ не отправлен');
        }
        replySent = true;
      }
      if (!await chat.markMessageRead(message)) {
        throw const ChatServiceException('Не удалось отметить прочитанным');
      }
      await clearChatNotification(owner, sender, messageId: messageId);
      await chat.refreshUnread();
      await NotificationService.instance.refresh();
    } catch (error) {
      lastError = error.toString();
      await _ensureLocalNotifications();
      await _localNotifications.show(
        id: response.id ?? 900007,
        title: replySent
            ? 'Ответ отправлен. Не удалось обновить прочтение'
            : 'Действие не выполнено. Откройте чат',
        body: !replySent && response.input?.isNotEmpty == true
            ? 'Неотправленный ответ: ${response.input}'
            : 'Проверьте подключение к интернету',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'chat_messages',
            'Сообщения',
            importance: Importance.high,
            priority: Priority.high,
            icon: 'ic_stat_pulsepath',
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
          ),
        ),
        payload: response.payload,
      );
    }
  }

  Future<void> clearChatNotification(
    String owner,
    String sender, {
    String? messageId,
  }) async {
    if (!_supported) return;
    await _ensureLocalNotifications();
    final id = chatNotificationId(owner, sender);
    if (messageId != null) {
      final active = await _localNotifications.getActiveNotifications();
      for (final notification in active.where((n) => n.id == id)) {
        final payload =
            jsonDecode(notification.payload ?? '{}') as Map<String, dynamic>;
        // A reply to an older alert must not dismiss a newer arrival.
        if (payload['messageId'] != messageId) return;
      }
    }
    await _localNotifications.cancel(id: id, tag: 'chat_$sender');
  }

  void _onLocalTap(String? value) {
    try {
      final payload = jsonDecode(value ?? '') as Map<String, dynamic>;
      if (payload['type'] == 'garage_maintenance' &&
          payload['owner'] is String) {
        _pendingGarageOwner = payload['owner'] as String;
        unawaited(flushPendingTap());
        return;
      }
      if (payload['type'] == 'app_update') {
        _pendingUpdate = true;
        unawaited(flushPendingTap());
        return;
      }
      final sender = payload['senderId'] as String?;
      final receiver = payload['receiverId'] as String?;
      if (sender == null ||
          sender.isEmpty ||
          receiver == null ||
          receiver.isEmpty) {
        return;
      }
      _pendingSender = sender;
      _pendingReceiver = receiver;
      _pendingMessage = payload['messageId']?.toString();
      unawaited(flushPendingTap());
    } catch (_) {
      /* Reject legacy sender-only payloads. */
    }
  }

  Future<bool> showMaintenanceReminder(String uid, String body) async {
    if (!_supported || !notificationsAuthorized) return false;
    try {
      await _ensureLocalNotifications();
      if (Supabase.instance.client.auth.currentUser?.id != uid) return false;
      await _localNotifications.show(
        id: 900006,
        title: 'Пора проверить велосипед',
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'bike_maintenance',
            'Обслуживание велосипеда',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            icon: 'ic_stat_pulsepath',
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBadge: false,
          ),
        ),
        payload: jsonEncode({'type': 'garage_maintenance', 'owner': uid}),
      );
      return true;
    } catch (error) {
      debugPrint('[Garage] reminder unavailable: $error');
      return false;
    }
  }

  Future<void> clearMaintenanceReminder() async {
    if (!_supported || _localInitFuture == null) return;
    try {
      await _localNotifications.cancel(id: 900006);
    } catch (_) {
      /* Next refresh can retry. */
    }
  }

  Future<void> showWaterReminder({bool preview = false}) async {
    if (!_supported) return;
    final generation = _workoutReminderGeneration;
    try {
      await _ensureLocalNotifications();
      if (generation != _workoutReminderGeneration) return;
      await _localNotifications.show(
        id: _waterNotificationId,
        title: preview
            ? 'Проверка напоминания о воде'
            : 'Время сделать глоток воды',
        body: preview ? 'Так выглядит напоминание во время тренировки.' : 'Если удобно, сделайте небольшой перерыв. Тренировка продолжается.',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'workout_reminders',
            'Напоминания тренировки',
            channelDescription:
                'Напоминания о воде во время активной тренировки',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            icon: 'ic_stat_pulsepath',
            timeoutAfter: 60000,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBadge: false,
          ),
        ),
        payload: jsonEncode({'type': 'workout_water'}),
      );
      if (generation != _workoutReminderGeneration) {
        await _localNotifications.cancel(id: _waterNotificationId);
      }
    } catch (error) {
      debugPrint('[Workout] water reminder unavailable: $error');
    }
  }

  Future<void> clearWaterReminder() async {
    _workoutReminderGeneration++;
    if (!_supported || _localInitFuture == null) return;
    try {
      await _localNotifications.cancel(id: _waterNotificationId);
      await _localNotifications.cancel(id: 900004);
    } catch (error) {
      debugPrint('[Workout] clear water reminder failed: $error');
    }
  }

  Future<void> showRouteDeviation() async {
    if (!_supported) return;
    try {
      await _ensureLocalNotifications();
      await _localNotifications.show(
        id: 900003,
        title: 'Вы сошли с маршрута',
        body: 'Остановитесь в удобном месте и проверьте путь на карте.',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'navigation_alerts',
            'Навигация',
            importance: Importance.high,
            priority: Priority.high,
            icon: 'ic_stat_pulsepath',
            timeoutAfter: 30000,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBadge: false,
          ),
        ),
        payload: jsonEncode({'type': 'navigation'}),
      );
    } catch (error) {
      debugPrint('[Navigation] alert unavailable: $error');
    }
  }

  Future<void> showWorkoutCue(String title, String body) async {
    if (!_supported) return;
    final generation = _workoutReminderGeneration;
    try {
      await _ensureLocalNotifications();
      if (generation != _workoutReminderGeneration) return;
      await _localNotifications.show(
        id: 900004,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'workout_intervals',
            'Этапы тренировки',
            importance: Importance.high,
            priority: Priority.high,
            icon: 'ic_stat_pulsepath',
            timeoutAfter: 20000,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBadge: false,
          ),
        ),
        payload: jsonEncode({'type': 'workout_interval'}),
      );
      if (generation != _workoutReminderGeneration) {
        await _localNotifications.cancel(id: 900004);
      }
    } catch (error) {
      debugPrint('[Workout] cue unavailable: $error');
    }
  }

  /// Explicit developer action, using a separate ID/channel from ride alerts.
  Future<bool> showDeveloperNotification() async {
    if (!_supported || !await NotificationPermissionService.request())
      return false;
    await _ensureLocalNotifications();
    await _localNotifications.show(
      id: 900099,
      title: 'Тест PulsePath',
      body: 'Системные уведомления работают.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'developer_tests',
          'Тестирование PulsePath',
          importance: Importance.high,
          priority: Priority.high,
          icon: 'ic_stat_pulsepath',
          timeoutAfter: 30000,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          presentBadge: false,
        ),
      ),
      payload: jsonEncode({'type': 'developer_test'}),
    );
    return true;
  }

  Future<void> _onForeground(
    RemoteMessage message, {
    bool background = false,
  }) async {
    if (message.data['type'] == 'app_update') {
      final key = message.messageId;
      if (key != null && !_seenForeground.add(key)) return;
      try {
        await _localNotifications.show(
          id: 900001,
          title: message.notification?.title ?? 'Обновление PulsePath',
          body: message.notification?.body ?? 'Доступна новая версия',
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'app_updates',
              'Обновления приложения',
              importance: Importance.high,
              priority: Priority.high,
              icon: 'ic_stat_pulsepath',
              tag: 'app_update',
            ),
          ),
          payload: jsonEncode({'type': 'app_update'}),
        );
      } catch (error) {
        debugPrint('[Push] update notification failed: $error');
      }
      return;
    }
    final uid = Supabase.instance.client.auth.currentUser?.id;
    final sender = message.data['senderId']?.toString();
    if (uid == null ||
        sender == null ||
        sender.isEmpty ||
        message.data['receiverId']?.toString() != uid ||
        message.data['type'] != 'chat') {
      return;
    }
    final key = message.data['messageId']?.toString() ?? message.messageId;
    if (key != null && !_shownMessages.add(key)) return;
    if (_shownMessages.length > 1000) {
      _shownMessages.remove(_shownMessages.first);
    }
    if (_seenForeground.length > 1000) {
      _seenForeground.remove(_seenForeground.first);
    }
    try {
      if (Supabase.instance.client.auth.currentUser?.id != uid) return;
      // Чат с этим отправителем открыт на экране — сообщение и так видно
      // в ленте, системный пуш не показываем.
      if (!background && ChatService.openChatFriendId == sender) return;
      final preview = onChatPreview;
      final previewId = message.data['messageId']?.toString();
      if (!background && previewId != null && preview != null) {
        try {
          if (key != null) _shownMessages.remove(key);
          if (await preview(previewId)) return;
          if (key != null && !_shownMessages.add(key)) return;
        } catch (_) {
          // Keep the standard notification if authenticated preview loading fails.
        }
      }
      if (Supabase.instance.client.auth.currentUser?.id != uid) return;
      await _localNotifications.show(
        id: chatNotificationId(uid, sender),
        title:
            message.notification?.title ??
            message.data['title']?.toString() ??
            'Новое сообщение',
        body:
            message.notification?.body ??
            message.data['body']?.toString() ??
            'Откройте PulsePath, чтобы прочитать',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'chat_messages',
            'Сообщения',
            channelDescription: 'Новые сообщения в чатах PulsePath',
            importance: Importance.high,
            priority: Priority.high,
            icon: 'ic_stat_pulsepath',
            tag: 'chat_$sender',
            category: AndroidNotificationCategory.message,
            groupKey: 'pulsepath_chats_$uid',
            visibility: NotificationVisibility.private,
            styleInformation: BigTextStyleInformation(
              message.notification?.body ??
                  message.data['body']?.toString() ??
                  'Новое сообщение',
            ),
            actions: const [
              AndroidNotificationAction(
                'reply',
                'Ответить',
                cancelNotification: false,
                semanticAction: SemanticAction.reply,
                inputs: [AndroidNotificationActionInput(label: 'Сообщение')],
              ),
              AndroidNotificationAction(
                'read',
                'Прочитано',
                cancelNotification: false,
                semanticAction: SemanticAction.markAsRead,
              ),
            ],
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBadge: false,
            threadIdentifier: 'chat_$sender',
            categoryIdentifier: 'chat_message',
          ),
        ),
        payload: jsonEncode({
          'senderId': sender,
          'receiverId': uid,
          'messageId': key,
        }),
      );
      if (Supabase.instance.client.auth.currentUser?.id != uid) {
        await _localNotifications.cancel(
          id: chatNotificationId(uid, sender),
          tag: 'chat_$sender',
        );
      }
    } catch (error) {
      if (key != null) _shownMessages.remove(key);
      lastError = 'Не удалось показать уведомление';
      debugPrint('[Push] foreground notification failed: $error');
    }
    try {
      await ChatService().refreshUnread();
      await NotificationService.instance.refresh();
    } catch (error) {
      debugPrint('[Push] inbox refresh failed: $error');
    }
  }

  Future<void> _saveToken({String? token}) {
    final operation = _tokenTail.then((_) => _registerToken(token: token));
    _tokenTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<void> _registerToken({String? token}) async {
    try {
      if (_unregistering) return;
      final client = Supabase.instance.client;
      final uid = client.auth.currentUser?.id;
      if (uid == null) return;
      final value = token ?? await FirebaseMessaging.instance.getToken();
      if (_unregistering ||
          value == null ||
          client.auth.currentUser?.id != uid) {
        return;
      }
      // Server derives auth.uid(), moves ownership atomically and enforces a unique token.
      await client
          .rpc(
            'pulsepath_register_device_token_v2',
            params: {'p_token': value, 'p_platform': Platform.operatingSystem},
          )
          .timeout(const Duration(seconds: 10));
      lastError = notificationsAuthorized
          ? null
          : 'Разрешение на уведомления не выдано';
    } catch (error) {
      lastError = error.toString();
      debugPrint('[Push] register token failed: $error');
    }
  }

  Future<void> unregisterCurrentDevice() async {
    if (!_supported || Firebase.apps.isEmpty) return;
    _unregistering = true;
    try {
      await _tokenTail;
      final client = Supabase.instance.client;
      final uid = client.auth.currentUser?.id;
      if (uid == null) return;
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await client
            .rpc(
              'pulsepath_unregister_device_token',
              params: {'p_token': token},
            )
            .timeout(const Duration(seconds: 10));
      }
      _pendingSender = null;
      _pendingReceiver = null;
      await _localNotifications.cancelAll();
    } catch (_) {
      _unregistering = false;
      rethrow;
    }
  }

  /// Call after sign-out completes, or when sign-out fails.
  void finishSignOut() {
    _unregistering = false;
  }

  void detach() {
    onGarageOpen = null;
    _pendingGarageOwner = null;
    onChatOpen = null;
    onInvitationOpen = null;
    onChatPreview = null;
  }

  void _onPushTap(RemoteMessage message) {
    if (message.data['type'] == 'app_update') {
      final key = message.messageId;
      if (key != null && !_seenTaps.add(key)) return;
      _pendingUpdate = true;
      unawaited(flushPendingTap());
      return;
    }
    final sender = message.data['senderId']?.toString();
    final receiver = message.data['receiverId']?.toString();
    if (sender == null ||
        sender.isEmpty ||
        receiver == null ||
        receiver.isEmpty) {
      return;
    }
    final key = message.messageId;
    if (key != null && !_seenTaps.add(key)) return;
    if (_seenTaps.length > 200) _seenTaps.remove(_seenTaps.first);
    _pendingSender = sender;
    _pendingReceiver = receiver;
    _pendingMessage = message.data['messageId']?.toString();
    unawaited(flushPendingTap());
  }

  Future<void> flushPendingTap() async {
    if (_pendingGarageOwner != null &&
        onGarageOpen != null &&
        !_openingGarage) {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid != null) {
        final owner = _pendingGarageOwner;
        _pendingGarageOwner = null;
        if (owner == uid) {
          _openingGarage = true;
          try {
            await onGarageOpen!();
          } catch (error) {
            debugPrint('[Garage] open failed: $error');
          } finally {
            _openingGarage = false;
          }
        }
      }
    }
    if (_pendingUpdate && onUpdateOpen != null && !_openingUpdate) {
      _pendingUpdate = false;
      _openingUpdate = true;
      try {
        await onUpdateOpen!();
      } catch (error) {
        debugPrint('[Push] open update failed: $error');
      } finally {
        _openingUpdate = false;
      }
    }
    final sender = _pendingSender, callback = onChatOpen;
    if (sender == null || callback == null || _opening) return;
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return; // wait for login and a mounted Navigator
    if (_pendingReceiver != null && _pendingReceiver != uid) {
      _pendingSender = null;
      _pendingReceiver = null;
      return;
    }
    _pendingSender = null;
    _pendingReceiver = null;
    final messageId = _pendingMessage;
    _pendingMessage = null;
    _opening = true;
    try {
      if (messageId != null &&
          onInvitationOpen != null &&
          await onInvitationOpen!(messageId))
        return;
      await callback(sender);
    } catch (error) {
      debugPrint('[Push] open chat failed: $error');
    } finally {
      _opening = false;
      if (_pendingSender != null) unawaited(flushPendingTap());
    }
  }
}
