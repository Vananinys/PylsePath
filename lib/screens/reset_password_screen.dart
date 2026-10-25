import 'package:flutter/material.dart';

import '../services/auth_service.dart';

class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({
    super.key,
    required this.authService,
    required this.onSaved,
  });
  final AuthService authService;
  final VoidCallback onSaved;

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.authService.updatePassword(_password.text);
      if (mounted) widget.onSaved();
    } on AuthServiceException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Новый пароль')),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _password,
                  obscureText: true,
                  enabled: !_saving,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: const InputDecoration(labelText: 'Новый пароль'),
                  validator: (value) =>
                      (value ?? '').length < 6 ? 'Минимум 6 символов' : null,
                ),
                TextFormField(
                  obscureText: true,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'Повторите пароль',
                  ),
                  validator: (value) =>
                      value != _password.text ? 'Пароли не совпадают' : null,
                  onFieldSubmitted: (_) => _save(),
                ),
                if (_error != null) Text(_error!),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Сохранение…' : 'Сохранить пароль'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
