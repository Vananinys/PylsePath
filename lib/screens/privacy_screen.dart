import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/privacy_consent_store.dart';
import '../data/user_scope.dart';
import '../models/privacy_consent.dart';
import '../widgets/registration_privacy_fields.dart';

class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key});

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  final _store = PrivacyConsentStore();
  final String? _owner = UserScope.currentUserId();
  PrivacyConsentReceipt? _receipt;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  bool get _sameAccount =>
      _owner != null && UserScope.currentUserId() == _owner;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final receipt = _owner == null
          ? null
          : await _store.readForAccount(_owner);
      if (!mounted) return;
      setState(() {
        _receipt = _sameAccount ? receipt : null;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось прочитать локальное подтверждение. Оно не считается полученным автоматически.';
      });
    }
  }

  Future<void> _review() async {
    if (_saving || !_sameAccount) return;
    final receipt = await Navigator.of(context).push<PrivacyConsentReceipt>(
      MaterialPageRoute(builder: (_) => const _ConsentReviewScreen()),
    );
    if (receipt == null || !mounted) return;
    if (!_sameAccount) {
      _message('Аккаунт изменился. Откройте раздел заново.');
      return;
    }
    setState(() => _saving = true);
    try {
      await _store.saveForAccount(_owner!, receipt);
      if (!mounted) return;
      if (!_sameAccount) {
        _message(
          'Подтверждение относится к предыдущему аккаунту. Откройте раздел заново.',
        );
        return;
      }
      setState(() {
        _receipt = receipt;
        _error = null;
      });
      _message('Подтверждение сохранено на этом телефоне.');
    } catch (_) {
      if (mounted) {
        _message(
          'Не удалось сохранить подтверждение. Проверьте свободное место.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _contact() async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Обращение о данных'),
        content: const Text(
          'Напишите с e-mail вашего аккаунта, какие данные нужно предоставить, исправить или удалить, либо какое согласие вы хотите отозвать. Не отправляйте пароль или документы.\n\nПисьмо нужно отправить самостоятельно. Открытие почты не удаляет аккаунт и не подтверждает получение запроса оператором.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Закрыть'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Открыть почту'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    final uri = Uri(
      scheme: 'mailto',
      path: PrivacyDocuments.contactEmail,
      query:
          'subject=${Uri.encodeComponent('PulsePath: обращение о персональных данных')}',
    );
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
          mounted) {
        _message(
          'Почтовая программа недоступна. Адрес: ${PrivacyDocuments.contactEmail}',
        );
      }
    } catch (_) {
      if (mounted) {
        _message(
          'Напишите на ${PrivacyDocuments.contactEmail} из вашей почты.',
        );
      }
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  String _receiptSummary() {
    final receipt = _receipt;
    if (receipt == null) {
      return 'На этом телефоне нет подтверждения для текущего аккаунта. Старые установки не считаются автоматически согласившимися.';
    }
    final date = receipt.acceptedAt.toLocal();
    final formatted =
        '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
    return '${receipt.ageGroup.label} · подтверждено $formatted\n'
        'Информация и согласие: ${receipt.policyVersion}\n'
        'Правила: ${receipt.termsVersion}'
        '${receipt.isCurrent ? '' : '\nТекст обновился: можно прочитать и подтвердить новую версию.'}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Данные и согласия')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ваш выбор на этом телефоне',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  if (_loading)
                    const LinearProgressIndicator()
                  else if (_error != null) ...[
                    Text(_error!),
                    TextButton(
                      onPressed: _load,
                      child: const Text('Повторить'),
                    ),
                  ] else
                    Text(_receiptSummary()),
                  const SizedBox(height: 12),
                  const Text(
                    'Подтверждение хранится локально, отдельно для каждого аккаунта. На другом устройстве этой записи может не быть. Возраст в спортивном профиле её не заменяет.',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _sameAccount && !_loading && !_saving
                        ? _review
                        : null,
                    child: Text(
                      _saving ? 'Сохранение…' : 'Прочитать и подтвердить',
                    ),
                  ),
                ],
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('Информация о данных'),
            subtitle: const Text(
              'Что сохраняется, где находится и кому передаётся',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                showPrivacyDocument(context, PrivacyDocumentKind.information),
          ),
          ListTile(
            leading: const Icon(Icons.fact_check_outlined),
            title: const Text('Текст согласия'),
            onTap: () =>
                showPrivacyDocument(context, PrivacyDocumentKind.consent),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Правила закрытого теста'),
            onTap: () =>
                showPrivacyDocument(context, PrivacyDocumentKind.terms),
          ),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Статистика и отчёты об ошибках',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Продуктовая аналитика и автоматическая отправка диагностики не подключены. Здесь нет скрытого согласия на их будущее включение. При появлении сбора будет отдельный выбор.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Оператор: ${PrivacyDocuments.operatorName}',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SelectableText(PrivacyDocuments.contactEmail),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.mail_outline),
            title: const Text('Доступ, удаление данных и отзыв согласия'),
            subtitle: const Text('Обращение оператору по e-mail'),
            onTap: _contact,
          ),
        ],
      ),
    ),
  );
}

class _ConsentReviewScreen extends StatefulWidget {
  const _ConsentReviewScreen();
  @override
  State<_ConsentReviewScreen> createState() => _ConsentReviewScreenState();
}

class _ConsentReviewScreenState extends State<_ConsentReviewScreen> {
  RegistrationAgeGroup? _age;
  bool _processing = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Подтверждение выбора')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          RegistrationAgePicker(
            value: _age,
            onChanged: (value) => setState(() {
              _age = value;
              _processing = false;
            }),
          ),
          const SizedBox(height: 16),
          if (_age?.canSelfRegister == true) ...[
            RegistrationConsentFields(
              processingAccepted: _processing,
              submitLabel: 'Сохранить подтверждение',
              onProcessingChanged: (value) =>
                  setState(() => _processing = value),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _processing
                  ? () => Navigator.pop(
                      context,
                      PrivacyConsentReceipt(
                        ageGroup: _age!,
                        acceptedAt: DateTime.now(),
                        source: 'settings',
                      ),
                    )
                  : null,
              child: const Text('Сохранить подтверждение'),
            ),
          ] else
            TextButton(
              onPressed: () =>
                  showPrivacyDocument(context, PrivacyDocumentKind.information),
              child: const Text('Прочитать информацию о данных'),
            ),
        ],
      ),
    ),
  );
}
