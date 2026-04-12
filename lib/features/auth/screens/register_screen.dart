import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/crypto_service.dart';
import '../../../core/theme/app_theme.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _displayNameCtrl = TextEditingController();
  final _usernameCtrl    = TextEditingController();
  final _passwordCtrl    = TextEditingController();
  final _confirmCtrl     = TextEditingController();
  bool _loading      = false;
  bool _obscure      = true;
  bool _generatingKey = false;
  String? _error;

  @override
  void dispose() {
    _displayNameCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    final displayName = _displayNameCtrl.text.trim();
    final username    = _usernameCtrl.text.trim().toLowerCase();
    final password    = _passwordCtrl.text;
    final confirm     = _confirmCtrl.text;

    if (displayName.isEmpty || username.isEmpty || password.isEmpty) {
      setState(() => _error = 'Заполни все поля');
      return;
    }
    if (!RegExp(r'^[a-z0-9_.]{3,32}$').hasMatch(username)) {
      setState(() => _error = 'Username: 3–32 символа, только a-z, 0-9, _ или .');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = 'Пароль минимум 6 символов');
      return;
    }
    if (password != confirm) {
      setState(() => _error = 'Пароли не совпадают');
      return;
    }

    setState(() { _loading = true; _error = null; });

    try {
      // Шаг 1: Генерация RSA-2048 ключей
      setState(() => _generatingKey = true);
      String publicKey;
      try {
        publicKey = await CryptoService.instance.generateAndStoreKeyPair();
      } catch (e) {
        setState(() {
          _error = 'Ошибка генерации ключей шифрования';
          _loading = false;
          _generatingKey = false;
        });
        return;
      }
      setState(() => _generatingKey = false);

      // Шаг 2: Регистрация на сервере с публичным ключом
      final result = await AuthService.register(
        username:    username,
        displayName: displayName,
        password:    password,
        publicKey:   publicKey,
      );

      if (!mounted) return;

      if (result['success']) {
        context.go('/chats');
      } else {
        setState(() => _error = result['error']);
      }
    } catch (e) {
      setState(() => _error = 'Нет соединения с сервером');
    } finally {
      if (mounted) setState(() { _loading = false; _generatingKey = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 48),
              Center(
                child: Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: const Icon(Icons.person_add_outlined, color: Colors.white, size: 36),
                ),
              ),
              const SizedBox(height: 20),
              Text('Создать аккаунт',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 26, fontWeight: FontWeight.bold,
                  color: dark ? AppColors.textDark : AppColors.textLight,
                ),
              ),
              const SizedBox(height: 8),
              Text('Твои данные в безопасности',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14,
                  color: dark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
              ),
              const SizedBox(height: 36),

              TextField(
                controller: _displayNameCtrl,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  hintText: 'Имя (как тебя видят другие)',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _usernameCtrl,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  hintText: 'Username (a-z, 0-9, _, .)',
                  prefixIcon: Icon(Icons.alternate_email),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordCtrl,
                obscureText: _obscure,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  hintText: 'Пароль (мин. 6 символов)',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _confirmCtrl,
                obscureText: _obscure,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _register(),
                decoration: const InputDecoration(
                  hintText: 'Повтори пароль',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(_error!,
                    style: const TextStyle(color: Colors.red, fontSize: 13),
                    textAlign: TextAlign.center),
                ),
              ],

              if (_generatingKey) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C63FF).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF6C63FF)),
                      ),
                      const SizedBox(width: 10),
                      Text('Генерация ключей шифрования...',
                        style: TextStyle(fontSize: 13,
                          color: dark ? const Color(0xFFB0AAF8) : const Color(0xFF6C63FF)),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 24),
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: _loading ? null : _register,
                  child: _loading && !_generatingKey
                      ? const SizedBox(
                          width: 22, height: 22,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                      : const Text('Зарегистрироваться'),
                ),
              ),

              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.lock, size: 14, color: Colors.green),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'RSA + AES ключи генерируются прямо на устройстве',
                        style: TextStyle(fontSize: 11,
                          color: dark ? Colors.green[300] : Colors.green[700]),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Уже есть аккаунт? ',
                    style: TextStyle(
                      color: dark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight)),
                  GestureDetector(
                    onTap: () => context.go('/login'),
                    child: const Text('Войти',
                      style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
