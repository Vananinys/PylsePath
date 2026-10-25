import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../widgets/auth_header.dart';
import '../data/privacy_consent_store.dart';
import '../models/privacy_consent.dart';
import '../widgets/registration_privacy_fields.dart';

/// Экран регистрации. После успешного создания аккаунта запись в `profiles`
/// создаётся в [AuthService.signUp], а переключение на карту делает AuthGate.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, this.authService, this.consentStore});

  final AuthService? authService;
  final PrivacyConsentStore? consentStore;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();

  bool _loading = false;
  bool _obscurePassword = true;
  RegistrationAgeGroup? _ageGroup;
  bool _processingAccepted = false;
  bool _consentError = false;

  AuthService get _auth => widget.authService ?? AuthService();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  String? _validateEmail(String? raw) {
    final value = (raw ?? '').trim();
    if (value.isEmpty) return 'Введите e-mail';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value)) {
      return 'Некорректный e-mail';
    }
    return null;
  }

  String? _validatePassword(String? raw) {
    final value = raw ?? '';
    if (value.isEmpty) return 'Введите пароль';
    if (value.length < 6) return 'Пароль должен быть не короче 6 символов';
    return null;
  }

  String? _validateConfirm(String? raw) {
    if ((raw ?? '').isEmpty) return 'Повторите пароль';
    if (raw != _passwordController.text) return 'Пароли не совпадают';
    return null;
  }

  Future<void> _submit() async {
    if (_loading || _ageGroup?.canSelfRegister != true) return;
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!_processingAccepted) {
      setState(() => _consentError = true);
      return;
    }

    setState(() => _loading = true);
    final store = widget.consentStore ?? PrivacyConsentStore();
    final receipt = PrivacyConsentReceipt(
      ageGroup: _ageGroup!,
      acceptedAt: DateTime.now(),
      source: 'registration',
    );
    var registrationStarted = false;
    try {
      // Persist the actual choices before making the registration request.
      await store.savePending(receipt);
      registrationStarted = true;
      final user = await _auth.signUp(
        email: _emailController.text,
        password: _passwordController.text,
      );
      final saved = await _saveReceiptForAccount(store, user.id, receipt);
      if (!mounted) return;
      _showMessage(
        saved ? 'Аккаунт создан. Добро пожаловать в PulsePath!' : 'Аккаунт создан. Подтверждение осталось в локальном черновике; проверьте свободное место на телефоне.',
      );
      // Дальше AuthGate сам покажет карту.
    } on AuthServiceException catch (error) {
      if (error.createdUserId != null) {
        await _saveReceiptForAccount(store, error.createdUserId!, receipt);
      }
      if (!mounted) return;
      _showMessage(
        error.message,
        isError: true,
        // При подтверждении почты аккаунт уже создан — даём время прочитать.
        duration: error.isEmailNotConfirmed
            ? const Duration(seconds: 8)
            : const Duration(seconds: 4),
      );
    } catch (_) {
      if (!mounted) return;
      _showMessage(
        registrationStarted
            ? 'Не удалось завершить регистрацию. Проверьте связь; если аккаунт создан, попробуйте войти.'
            : 'Не удалось сохранить подтверждение на телефоне. Регистрация не началась. Проверьте свободное место.',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _saveReceiptForAccount(
    PrivacyConsentStore store,
    String owner,
    PrivacyConsentReceipt receipt,
  ) async {
    try {
      await store.saveForAccount(owner, receipt);
      return true;
    } catch (_) {
      // The auth request has succeeded; don't suggest creating a second account.
      return false;
    }
  }

  void _showMessage(
    String message, {
    bool isError = false,
    Duration duration = const Duration(seconds: 4),
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red[700] : null,
        duration: duration,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Регистрация'),
        backgroundColor: Colors.deepOrange,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AuthHeader(
                    title: 'Создать аккаунт',
                    subtitle:
                        'Почта, пароль и возрастная группа. '
                        'Точная дата рождения не нужна.',
                  ),
                  const SizedBox(height: 28),
                  Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Form(
                        key: _formKey,
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        child: Column(
                          children: [
                            RegistrationAgePicker(
                              value: _ageGroup,
                              enabled: !_loading,
                              onChanged: (value) => setState(() {
                                _ageGroup = value;
                                _processingAccepted = false;
                                _consentError = false;
                              }),
                            ),
                            const SizedBox(height: 16),
                            if (_ageGroup?.canSelfRegister == true) ...[
                              TextFormField(
                                controller: _emailController,
                                keyboardType: TextInputType.emailAddress,
                                autofillHints: const [AutofillHints.email],
                                textInputAction: TextInputAction.next,
                                validator: _validateEmail,
                                decoration: const InputDecoration(
                                  labelText: 'E-mail',
                                  prefixIcon: Icon(Icons.mail_outline),
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: _passwordController,
                                obscureText: _obscurePassword,
                                autofillHints: const [
                                  AutofillHints.newPassword,
                                ],
                                textInputAction: TextInputAction.next,
                                validator: _validatePassword,
                                decoration: InputDecoration(
                                  labelText: 'Пароль',
                                  helperText: 'Минимум 6 символов',
                                  prefixIcon: const Icon(Icons.lock_outline),
                                  border: const OutlineInputBorder(),
                                  suffixIcon: IconButton(
                                    tooltip: _obscurePassword
                                        ? 'Показать пароль'
                                        : 'Скрыть пароль',
                                    icon: Icon(
                                      _obscurePassword
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                    ),
                                    onPressed: () => setState(
                                      () =>
                                          _obscurePassword = !_obscurePassword,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: _confirmController,
                                obscureText: _obscurePassword,
                                textInputAction: TextInputAction.done,
                                validator: _validateConfirm,
                                onFieldSubmitted: (_) => _submit(),
                                decoration: const InputDecoration(
                                  labelText: 'Повторите пароль',
                                  prefixIcon: Icon(Icons.lock_reset_outlined),
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 20),
                              RegistrationConsentFields(
                                processingAccepted: _processingAccepted,
                                enabled: !_loading,
                                showError: _consentError,
                                onProcessingChanged: (value) => setState(() {
                                  _processingAccepted = value;
                                  _consentError = false;
                                }),
                              ),
                              const SizedBox(height: 16),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: _loading ? null : _submit,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.deepOrange,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                  ),
                                  child: _loading
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Text('Зарегистрироваться'),
                                ),
                              ),
                            ] else
                              TextButton.icon(
                                onPressed: () => showPrivacyDocument(
                                  context,
                                  PrivacyDocumentKind.information,
                                ),
                                icon: const Icon(Icons.shield_outlined),
                                label: const Text('Данные и правила участия'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _loading ? null : () => Navigator.pop(context),
                    child: const Text('Уже есть аккаунт? Войти'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
