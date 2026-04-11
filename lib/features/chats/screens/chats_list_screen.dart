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
  bool _fabOpen = false;

  @override
  void initState() { super.initState(); _loadMyId(); _syncChats(); }

  Future<void> _loadMyId() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _myUserId = prefs.getInt(AppConstants.userIdKey) ?? 0);
  }

  Future<void> _syncChats() async {
    try {
      final serverChats = await ChatService.getChats();
      final storage = LocalStorageService.instance;
      for (final sc in serverChats) {
        int? peerId;
        if (sc.type == 'direct') {
          final prefs = await SharedPreferences.getInstance();
          final myId = prefs.getInt(AppConstants.userIdKey) ?? 0;
          peerId = sc.members.firstWhere(
              (m) => m.id != myId, orElse: () => sc.members.first).id;
        }
        await storage.saveChat(
          id: sc.id, type: sc.type, name: sc.name,
          avatarUrl: sc.avatarUrl, peerId: peerId,
        );
        for (final m in sc.members) {
          await storage.saveContact(
            id: m.id, username: m.username, displayName: m.displayName,
            avatarUrl: m.avatarUrl, status: m.status,
            publicKey: m.publicKey, lastSeen: m.lastSeen,
          );
          await storage.saveMember(sc.id, m.id);
        }
      }
    } catch (_) {}
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
          IconButton(icon: const Icon(Icons.person_outline),
              onPressed: () => context.push('/profile')),
          PopupMenuButton<String>(
            onSelected: (v) { if (v == 'logout') _logout(); },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'logout', child: Text('Выйти')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        const ConnectionStatusBar(),
        Expanded(child: _buildList()),
      ]),
      floatingActionButton: _buildFab(),
    );
  }

  Widget _buildList() {
    return StreamBuilder<List<Chat>>(
      stream: LocalStorageService.instance.watchChats(),
      builder: (context, snap) {
        final chats = snap.data ?? [];
        if (chats.isEmpty) {
          return Center(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.chat_bubble_outline,
                  size: 72, color: AppColors.primary.withOpacity(0.35)),
              const SizedBox(height: 20),
              const Text('Пока нет чатов',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              const Text('Нажми ✏ для нового чата или группы',
                  style: TextStyle(color: Colors.grey)),
            ]),
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

  Widget _buildFab() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (_fabOpen) ...[
          // Новая группа
          _FabOption(
            icon: Icons.group_add_outlined,
            label: 'Новая группа',
            onTap: () { setState(() => _fabOpen = false); context.push('/new-group'); },
          ),
          const SizedBox(height: 8),
          // Новый личный чат
          _FabOption(
            icon: Icons.person_add_outlined,
            label: 'Личный чат',
            onTap: () { setState(() => _fabOpen = false); context.push('/search'); },
          ),
          const SizedBox(height: 12),
        ],
        FloatingActionButton(
          onPressed: () => setState(() => _fabOpen = !_fabOpen),
          child: AnimatedRotation(
            turns: _fabOpen ? 0.125 : 0,
            duration: const Duration(milliseconds: 200),
            child: const Icon(Icons.edit_outlined),
          ),
        ),
      ],
    );
  }
}

class _FabOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _FabOption({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          elevation: 2,
          borderRadius: BorderRadius.circular(8),
          color: Theme.of(context).colorScheme.surfaceVariant,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
        ),
        const SizedBox(width: 8),
        FloatingActionButton.small(
          heroTag: label,
          onPressed: onTap,
          child: Icon(icon),
        ),
      ],
    );
  }
}
