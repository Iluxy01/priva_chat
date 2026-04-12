import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'core/constants/app_constants.dart';
import 'core/theme/app_theme.dart';
import 'core/services/auth_service.dart';
import 'core/services/presence_service.dart';
import 'core/services/crypto_service.dart';
import 'core/database/app_database.dart';
import 'core/services/local_storage_service.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/auth/screens/register_screen.dart';
import 'features/chats/screens/chats_list_screen.dart';
import 'features/chats/screens/chat_screen.dart';
import 'features/chats/screens/create_group_screen.dart';
import 'features/chats/screens/group_info_screen.dart';
import 'features/profile/screens/profile_screen.dart';
import 'features/search/screens/user_search_screen.dart';
import 'features/security/screens/device_verification_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Инициализируем локальную БД
  final db = AppDatabase();
  LocalStorageService.instance.init(db);

  // Инициализируем сервис присутствия
  PresenceService.instance.init();

  // Убеждаемся, что E2E ключи существуют (генерируем при первом запуске
  // если пользователь уже залогинен — например, после обновления приложения)
  final loggedIn = await AuthService.isLoggedIn();
  if (loggedIn) {
    try {
      // Убеждаемся что ключи есть локально
      final pubKey = await CryptoService.instance.ensureKeyPair();
      // Обновляем публичный ключ на сервере (на случай если
      // пользователь установил Task8 впервые на уже созданном аккаунте)
      final token = await AuthService.getToken();
      if (token != null) {
        try {
          await http.post(
            Uri.parse('${AppConstants.serverUrl}/auth/update-public-key'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer \$token',
            },
            body: jsonEncode({'public_key': pubKey}),
          ).timeout(const Duration(seconds: 10));
          debugPrint('[Startup] Public key synced to server');
        } catch (e) {
          debugPrint('[Startup] Could not sync public key: \$e');
        }
      }
    } catch (e) {
      debugPrint('[Startup] Key init error: \$e');
    }
  }

  runApp(const PrivaChatApp());
}

final _router = GoRouter(
  initialLocation: '/login',
  redirect: (context, state) async {
    final loggedIn = await AuthService.isLoggedIn();
    final onAuth = state.matchedLocation == '/login' ||
        state.matchedLocation == '/register';
    if (loggedIn && onAuth) return '/chats';
    if (!loggedIn && !onAuth) return '/login';
    return null;
  },
  routes: [
    GoRoute(path: '/login',        builder: (_, __) => const LoginScreen()),
    GoRoute(path: '/register',     builder: (_, __) => const RegisterScreen()),
    GoRoute(path: '/chats',        builder: (_, __) => const ChatsListScreen()),
    GoRoute(path: '/profile',      builder: (_, __) => const ProfileScreen()),
    GoRoute(path: '/search',       builder: (_, __) => const UserSearchScreen()),
    GoRoute(path: '/create-group', builder: (_, __) => const CreateGroupScreen()),
    GoRoute(
      path: '/chat/:id',
      builder: (_, state) =>
          ChatScreen(chatId: int.parse(state.pathParameters['id']!)),
    ),
    GoRoute(
      path: '/group-info/:id',
      builder: (_, state) =>
          GroupInfoScreen(chatId: int.parse(state.pathParameters['id']!)),
    ),
    // ── E2E верификация устройства ──────────────────────────────────────────
    GoRoute(
      path: '/verify/:peerId',
      builder: (_, state) {
        final extra = state.extra as Map<String, dynamic>? ?? {};
        return DeviceVerificationScreen(
          peerId:        int.parse(state.pathParameters['peerId']!),
          peerName:      extra['peerName'] as String? ?? 'Пользователь',
          peerPublicKey: extra['peerPublicKey'] as String?,
        );
      },
    ),
  ],
);

class PrivaChatApp extends StatelessWidget {
  const PrivaChatApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'PrivaChat',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}
