import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'core/theme/app_theme.dart';
import 'core/services/auth_service.dart';
import 'core/services/websocket_service.dart';
import 'core/services/presence_service.dart';
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  timeago.setLocaleMessages('ru', timeago.RuMessages());
  final db = AppDatabase();
  LocalStorageService.instance.init(db);
  PresenceService.instance.init();
  final loggedIn = await AuthService.isLoggedIn();
  if (loggedIn) WebSocketService.instance.connect();
  runApp(const PrivaChatApp());
}

final _router = GoRouter(
  initialLocation: '/login',
  redirect: (context, state) async {
    final loggedIn = await AuthService.isLoggedIn();
    final onAuth = state.matchedLocation == '/login' ||
        state.matchedLocation == '/register';
    if (loggedIn && onAuth) {
      WebSocketService.instance.connect();
      return '/chats';
    }
    if (!loggedIn && !onAuth) return '/login';
    return null;
  },
  routes: [
    GoRoute(path: '/login',        builder: (_, __) => const LoginScreen()),
    GoRoute(path: '/register',     builder: (_, __) => const RegisterScreen()),
    GoRoute(path: '/chats',        builder: (_, __) => const ChatsListScreen()),
    GoRoute(path: '/profile',      builder: (_, __) => const ProfileScreen()),
    GoRoute(path: '/search',       builder: (_, __) => const UserSearchScreen()),
    GoRoute(path: '/new-group',    builder: (_, __) => const CreateGroupScreen()),
    GoRoute(
      path: '/chat/:id',
      builder: (_, state) => ChatScreen(
        chatId: int.parse(state.pathParameters['id']!),
      ),
    ),
    GoRoute(
      path: '/group-info/:id',
      builder: (_, state) => GroupInfoScreen(
        chatId: int.parse(state.pathParameters['id']!),
      ),
    ),
  ],
);

class PrivaChatApp extends StatefulWidget {
  const PrivaChatApp({super.key});
  @override
  State<PrivaChatApp> createState() => _PrivaChatAppState();
}

class _PrivaChatAppState extends State<PrivaChatApp> with WidgetsBindingObserver {
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.resumed:
        if (await AuthService.isLoggedIn()) WebSocketService.instance.connect();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        WebSocketService.instance.disconnect();
        break;
      default: break;
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'PrivaChat',
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: ThemeMode.system,
    routerConfig: _router,
    debugShowCheckedModeBanner: false,
  );
}
