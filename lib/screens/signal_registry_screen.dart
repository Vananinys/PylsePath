import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/signal_state_database.dart';
import '../services/signal_device_registry.dart';

Future<void> registerCurrentSignalDevice() async {
  final client = Supabase.instance.client;
  final owner = client.auth.currentUser?.id;
  if (owner == null) throw StateError('Sign in required');
  final directory = await getDatabasesPath();
  final name = sha256.convert(utf8.encode(owner));
  final db = await SignalStateDatabase.open(
    path: '$directory/signal-account-$name.db',
    owner: owner,
    currentOwner: () => client.auth.currentUser?.id,
  );
  try {
    await SignalDeviceRegistry(
      db,
      (name, params) async => await client.rpc(name, params: params),
      () => client.auth.currentUser?.id,
    ).synchronize();
  } finally {
    await db.close();
  }
}

class SignalRegistryScreen extends StatefulWidget {
  const SignalRegistryScreen({
    super.key,
    this.connect = registerCurrentSignalDevice,
  });
  final Future<void> Function() connect;
  @override
  State<SignalRegistryScreen> createState() => _SignalRegistryScreenState();
}

class _SignalRegistryScreenState extends State<SignalRegistryScreen> {
  bool _busy = false;
  String? _status;
  Future<void> _connect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await widget.connect();
      if (mounted) {
        setState(
          () => _status =
              'Устройство зарегистрировано, публичные ключи опубликованы и сверены. '
              'Обычные чаты пока используют прежнюю схему E2EE.',
        );
      }
    } catch (error) {
      var message =
          'Подключение не завершено. Проверьте интернет и повторите. '
          'Сохранённые ключи будут использованы повторно.';
      if (error is PostgrestException) {
        if (error.message.contains('SIGNAL_ROLLOUT_DISABLED')) {
          message = 'Этот аккаунт пока не включён в тест Signal. Обычные чаты работают.';
        } else if (error.message.contains('SIGNAL_LINK_APPROVAL_REQUIRED')) {
          message = 'В аккаунте уже есть устройство Signal. Подключение второго устройства пока недоступно.';
        } else if (error.message.contains('SIGNAL_DEVICE_')) {
          message = 'Сервер не подтвердил устройство. Не удаляйте данные приложения: требуется проверка подключения.';
        }
      } else if (error is FormatException || error is StateError) {
        message = 'Не удалось безопасно подтвердить устройство. Ключи не сбрасываются; сообщите об ошибке.';
      }
      if (mounted) setState(() => _status = message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Устройство Signal')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Подготовка к Signal · эксперимент',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        const Text(
          'Подключите этот телефон к тестовому реестру Signal. '
          'Секретные ключи сохранятся на телефоне; сервер получит только публичные ключи.',
        ),
        const SizedBox(height: 12),
        const Text(
          'Это подготовительный этап. Переписка и уведомления продолжают работать '
          'на прежней схеме E2EE. Перенос чатов, восстановление истории Signal и '
          'подключение второго устройства ещё не включены. Не удаляйте данные приложения.',
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _busy ? null : _connect,
          icon: const Icon(Icons.phonelink_lock),
          label: Text(_busy ? 'Подключение…' : 'Подключить этот телефон'),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: LinearProgressIndicator(),
          ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Text(_status!),
          ),
      ],
    ),
  );
}
