import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/database/app_database.dart';
import '../../../core/services/local_storage_service.dart';
import '../../../core/services/chat_service.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/websocket_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/connection_status_bar.dart';
import '../widgets/chat_tile.dart';

class ChatsListScreen extends StatefulWidget {
  const ChatsListScreen({super.key});

  @override
  State<ChatsListScreen> createState() => _ChatsListScreenState();
}

class _ChatsListScreenState extends State<ChatsListScreen> {
  int _myUserId = 0;

  @override
  void initState() {
    super.initState();
    _loadMyId();
    _syncChats();
  }

  Future<void> _loadMyId() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _myUserId = prefs.getInt(AppConstants.userIdKey) ?? 0);
  }

  // Подтягивает чаты с сервера и сохраняет локально
  Future<void> _syncChats() async {
    try {
      final serverChats = await ChatService.getChats();
      final storage = LocalStorageService.instance;

      for (final sc in serverChats) {
        // Найти собеседника в direct-чате
        int? peerId;
        if (sc.type == 'direct') {
          final prefs = await SharedPreferences.getInstance();
          final myId = prefs.getInt(AppConstants.userIdKey) ?? 0;
          peerId = sc.members.firstWhere((m) => m.id != myId, orElse: () => sc.members.first).id;
        }

        await storage.saveChat(
          id: sc.id,
          type: sc.type,
          name: sc.name,
          avatarUrl: sc.avatarUrl,
          peerId: peerId,
        );

        // Сохранить участников и их профили локально
        for (final member in sc.members) {
          await storage.saveContact(
            id: member.id,
            username: member.username,
            displayName: member.displayName,
            avatarUrl: member.avatarUrl,
            status: member.status,
            publicKey: member.publicKey,
            lastSeen: member.lastSeen,
          );
          await storage.saveMember(sc.id, member.id);
        }
      }
    } catch (_) {
      // Если нет сети — показываем локальные данные
    }
  }

  Future<void> _logout() async {
    await AuthService.logout();
    WebSocketService.instance.disconnect();
    if (mounted) context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PrivaChat', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Найти пользователя',
            onPressed: () => context.push('/search'),
          ),
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'Профиль',
            onPressed: () => context.push('/profile'),
          ),
          PopupMenuButton<String>(
            onSelected: (v) { if (v == 'logout') _logout(); },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'logout', child: Text('Выйти')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          const ConnectionStatusBar(),
          Expanded(child: _buildList()),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/search'),
        tooltip: 'Новый чат',
        child: const Icon(Icons.edit_outlined),
      ),
    );
  }

  Widget _buildList() {
    return StreamBuilder<List<Chat>>(
      stream: LocalStorageService.instance.watchChats(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final chats = snap.data ?? [];

        if (chats.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.chat_bubble_outline,
                    size: 72, color: AppColors.primary.withOpacity(0.35)),
                const SizedBox(height: 20),
                const Text('Пока нет чатов',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                const Text('Нажми 🖊 чтобы найти собеседника',
                    style: TextStyle(color: Colors.grey)),
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: _syncChats,
          child: ListView.builder(
            itemCount: chats.length,
            itemBuilder: (context, i) => ChatTile(
              chat: chats[i],
              myUserId: _myUserId,
              onTap: () => context.push('/chat/${chats[i].id}'),
            ),
          ),
        );
      },
    );
  }
}
