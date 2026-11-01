import 'package:supabase_flutter/supabase_flutter.dart';

class ClubException implements Exception {
  const ClubException(this.message, {this.accessLost = false});
  final String message;
  final bool accessLost;
  @override
  String toString() => message;
}

/// Every mutation is authorized by the server; no local sample clubs.
class ClubService {
  ClubService({SupabaseClient? client}) : _client = client;
  final SupabaseClient? _client;
  SupabaseClient get client => _client ?? Supabase.instance.client;
  String? get userId => client.auth.currentUser?.id;
  Future<dynamic> action(
    String action, {
    String? club,
    Map<String, dynamic> data = const {},
  }) async {
    final owner = userId;
    if (owner == null) throw const ClubException('Войдите в аккаунт.');
    try {
      final result = await client
          .rpc(
            'club_action',
            params: {'p_action': action, 'p_club': club, 'p_data': data},
          )
          .timeout(const Duration(seconds: 20));
      if (userId != owner)
        throw const ClubException(
          'Аккаунт изменился. Откройте клуб заново.',
          accessLost: true,
        );
      return result;
    } on ClubException {
      rethrow;
    } on PostgrestException catch (error) {
      final message = error.message;
      final text = <String, String>{
        'CLUB_CODE_INVALID':
            'Приглашение не найдено или код обновлён. Попросите новый код.',
        'CLUB_INVITE_REQUIRED': 'Это закрытый клуб. Нужен код приглашения.',
        'CLUB_MEMBER_REQUIRED':
            'Вы больше не участник клуба. Вернитесь к списку клубов.',
        'CLUB_OWNER_REQUIRED': 'Это действие доступно организатору клуба.',
        'CLUB_TRANSFER_FIRST':
            'Сначала передайте управление другому участнику.',
        'CLUB_UNAVAILABLE': 'Клуб недоступен.',
        'CLUB_RIDE_HOST_REQUIRED': 'Сначала создайте совместную тренировку.',
        'CLUB_RIDE_CLOSED':
            'Эта поездка уже завершена. Попросите новое приглашение.',
        'CLUB_RATE_LIMIT': 'Слишком много действий. Попробуйте немного позже.',
        'CLUB_EVENT_TIME':
            'Выберите будущее время события, не дальше двух лет.',
        'CLUB_EVENT_CLOSED': 'Событие уже началось или отменено.',
        'REPLACE_REQUIRED': 'Вы уже участвуете в другой совместной поездке.',
        'CLUB_LIMIT': 'Можно состоять не более чем в 50 клубах.',
      }.entries.where((e) => message.contains(e.key)).firstOrNull?.value;
      throw ClubException(
        text ?? 'Сервер не подтвердил действие. Обновите данные и повторите.',
        accessLost:
            message.contains('CLUB_MEMBER_REQUIRED') ||
            message.contains('CLUB_UNAVAILABLE') ||
            message.contains('AUTH_REQUIRED'),
      );
    } catch (_) {
      throw const ClubException(
        'Нет ответа от сервера. Проверьте интернет и повторите.',
      );
    }
  }

  Future<List<Map<String, dynamic>>> home() async => rows(await action('home'));
  Future<Map<String, dynamic>> snapshot(String id) async =>
      Map<String, dynamic>.from(await action('snapshot', club: id) as Map);
  static List<Map<String, dynamic>> rows(dynamic raw) => (raw as List? ?? [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
}
