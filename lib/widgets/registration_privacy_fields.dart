import 'package:flutter/material.dart';

import '../models/privacy_consent.dart';

enum PrivacyDocumentKind { information, consent, terms }

Future<void> showPrivacyDocument(
  BuildContext context,
  PrivacyDocumentKind kind,
) => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    builder: (_) => Scaffold(
      appBar: AppBar(
        title: Text(switch (kind) {
          PrivacyDocumentKind.information => 'Данные и приватность',
          PrivacyDocumentKind.consent => 'Согласие на обработку данных',
          PrivacyDocumentKind.terms => 'Правила закрытого теста',
        }),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: SelectableText(switch (kind) {
            PrivacyDocumentKind.information => PrivacyDocuments.policy,
            PrivacyDocumentKind.consent => PrivacyDocuments.processingConsent,
            PrivacyDocumentKind.terms => PrivacyDocuments.terms,
          }, style: const TextStyle(fontSize: 16, height: 1.5)),
        ),
      ),
    ),
  ),
);

class RegistrationAgePicker extends StatelessWidget {
  const RegistrationAgePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });
  final RegistrationAgeGroup? value;
  final ValueChanged<RegistrationAgeGroup?> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DropdownButtonFormField<RegistrationAgeGroup>(
        key: const ValueKey('registration-age'),
        initialValue: value,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Возрастная группа',
          helperText: 'Точная дата рождения не нужна',
          prefixIcon: Icon(Icons.person_outline),
        ),
        items: [
          for (final group in RegistrationAgeGroup.values)
            DropdownMenuItem(value: group, child: Text(group.label)),
        ],
        onChanged: enabled ? onChanged : null,
        validator: (group) =>
            group == null ? 'Выберите возрастную группу' : null,
      ),
      if (value == RegistrationAgeGroup.under14)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            'PulsePath доступен с 14 лет. Запрос на создание аккаунта не отправляется.',
            key: const ValueKey('registration-age-explanation'),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
    ],
  );
}

class RegistrationConsentFields extends StatelessWidget {
  const RegistrationConsentFields({
    super.key,
    required this.processingAccepted,
    required this.onProcessingChanged,
    this.enabled = true,
    this.showError = false,
    this.submitLabel = 'Зарегистрироваться',
  });
  final bool processingAccepted;
  final ValueChanged<bool> onProcessingChanged;
  final bool enabled;
  final bool showError;
  final String submitLabel;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      CheckboxListTile(
        key: const ValueKey('processing-consent'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text('Согласен на обработку данных'),
        value: processingAccepted,
        onChanged: enabled
            ? (value) => onProcessingChanged(value == true)
            : null,
      ),
      Wrap(
        spacing: 4,
        children: [
          TextButton(
            onPressed: () =>
                showPrivacyDocument(context, PrivacyDocumentKind.consent),
            child: const Text('Согласие'),
          ),
          TextButton(
            onPressed: () =>
                showPrivacyDocument(context, PrivacyDocumentKind.information),
            child: const Text('Приватность'),
          ),
          TextButton(
            onPressed: () =>
                showPrivacyDocument(context, PrivacyDocumentKind.terms),
            child: const Text('Правила'),
          ),
        ],
      ),
      if (showError)
        Text(
          'Подтвердите согласие на обработку данных.',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      const SizedBox(height: 8),
      Text(
        'Нажимая «$submitLabel», вы принимаете правила использования PulsePath.',
        style: const TextStyle(fontSize: 12),
      ),
    ],
  );
}
