import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'core/theme/app_theme.dart';
import 'core/services/auth_service.dart';
import 'core/database/app_database.dart';
import 'core/services/local_storage_service.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/auth/screens/register_screen.dart';
import 'features/chats/screens/chats_list_screen.dart';
import 'features/profile/screens/profile_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Инициализируем локальную БД
  final db = AppDatabase();
  LocalStorageService.instance.init(db);

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
    GoRoute(path: '/login',    builder: (_, __) => const LoginScreen()),
    GoRoute(path: '/register', builder: (_, __) => const RegisterScreen()),
    GoRoute(path: '/chats',    builder: (_, __) => const ChatsListScreen()),
    GoRoute(path: '/profile',  builder: (_, __) => const ProfileScreen()),
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
