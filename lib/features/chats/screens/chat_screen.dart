import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/database/app_database.dart';
import '../../../core/services/chat_service.dart';
import '../../../core/services/crypto_service.dart';
import '../../../core/services/local_storage_service.dart';
import '../../../core/services/secure_storage_service.dart';
import '../../../core/services/websocket_service.dart';
import '../../../core/widgets/connection_status_bar.dart';
import '../widgets/message_bubble.dart';

const _deletedChatsKey = 'deleted_chat_ids';

class ChatScreen extends StatefulWidget {
  final int chatId;
  const ChatScreen({super.key, required this.chatId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textCtrl   = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _uuid       = const Uuid();

  int    _myUserId = 0;
  Chat?  _chat;
  int?   _peerId;
  Contact? _peerContact;

  List<int> _memberIds = [];

  bool _isTyping   = false;
  Timer? _typingTimer;
  Timer? _myTypingTimer;
  bool _sending    = false;
  bool _loadingMembers = true;

  final List<StreamSubscription> _subs = [];
  final Map<int, String> _senderNames = {};

  // E2E: кэш публичных ключей участников
  final Map<int, String> _publicKeys = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _myUserId = prefs.getInt(AppConstants.userIdKey) ?? 0;

    _chat = await LocalStorageService.instance.getChat(widget.chatId);

    if (_chat?.type == 'direct' && _chat?.peerId != null) {
      _peerId = _chat!.peerId;
      _peerContact = await LocalStorageService.instance.getContact(_peerId!);
      if (_peerContact?.publicKey != null && _peerContact!.publicKey!.isNotEmpty) {
        _publicKeys[_peerId!] = _peerContact!.publicKey!;
      }
    }

    // Загружаем участников из локальной БД
    await _loadMembers();

    // Всегда получаем свежие ключи с сервера — public_key мог
    // отсутствовать в локальном кэше (старая запись до Task 8)
    await _fetchMembersFromServer();

    if (mounted) setState(() => _loadingMembers = false);
    await LocalStorageService.instance.clearUnread(widget.chatId);
    _subscribeWs();
  }

  Future<void> _loadMembers() async {
    final members = await LocalStorageService.instance.getChatMembers(widget.chatId);
    _memberIds = members.map((m) => m.userId).where((id) => id != _myUserId).toList();

    for (final m in members) {
      if (m.userId == _myUserId) continue;
      final c = await LocalStorageService.instance.getContact(m.userId);
      if (c != null) {
        _senderNames[m.userId] = c.displayName;
        if (c.publicKey != null && c.publicKey!.isNotEmpty) {
          _publicKeys[m.userId] = c.publicKey!;
        }
      }
    }
  }

  Future<void> _fetchMembersFromServer() async {
    try {
      final serverMembers = await ChatService.getChatMembers(widget.chatId);
      for (final u in serverMembers) {
        // Сохраняем / обновляем контакт в локальной БД (включая public_key)
        await LocalStorageService.instance.saveContact(
          id: u.id, username: u.username,
          displayName: u.displayName, avatarUrl: u.avatarUrl,
          publicKey: u.publicKey, lastSeen: u.lastSeen,
        );
        await LocalStorageService.instance.saveMember(widget.chatId, u.id);

        if (u.id != _myUserId) {
          _senderNames[u.id] = u.displayName;
          // Обновляем ключ — это главная цель вызова
          if (u.publicKey != null && u.publicKey!.isNotEmpty) {
            _publicKeys[u.id] = u.publicKey!;
            debugPrint('[E2E] Loaded public key for user \${u.id} (\${u.username})');
          } else {
            debugPrint('[E2E] ⚠️ No public key for user \${u.id} (\${u.username}) — not yet on Task8');
          }
        }
      }
      await _loadMembers();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[ChatScreen] fetchMembers error: \$e');
    }
  }

  void _subscribeWs() {
    final ws = WebSocketService.instance;

    _subs.add(ws.onMessage.listen((msg) {
      if (msg.chatId != widget.chatId) return;
      _handleIncoming(msg);
    }));

    _subs.add(ws.onTyping.listen((t) {
      if (t.chatId != widget.chatId || t.senderId == _myUserId) return;
      _typingTimer?.cancel();
      if (!mounted) return;
      setState(() => _isTyping = t.isTyping);
      if (t.isTyping) {
        _typingTimer = Timer(
          const Duration(seconds: 3),
          () { if (mounted) setState(() => _isTyping = false); },
        );
      }
    }));

    _subs.add(ws.onAck.listen((ack) async {
      if (ack.chatId != widget.chatId) return;
      if (ack.tempId != null) {
        await LocalStorageService.instance.updateMessageStatus(
            ack.tempId!, ack.delivered ? 'delivered' : 'sent');
      }
    }));

    _subs.add(ws.onRead.listen((r) {
      if (r.chatId != widget.chatId) return;
    }));
  }

  // ── Дешифрование входящего сообщения ────────────────────────────────────

  Future<String> _decryptIncoming(WsMessage msg) async {
    // Если нет IV или encryptedKey — сообщение не зашифровано (legacy / fallback)
    if (msg.iv == null || msg.encryptedKey == null) {
      return msg.encryptedContent;
    }
    try {
      return await CryptoService.instance.decryptMessage2(
        encryptedContent: msg.encryptedContent,
        iv:               msg.iv!,
        rawEncryptedKey:  msg.encryptedKey!,
        myUserId:         _myUserId,
      );
    } catch (e) {
      debugPrint('[ChatScreen] Decrypt error: $e');
      return '[🔒 Не удалось расшифровать]';
    }
  }

  Future<void> _handleIncoming(WsMessage msg) async {
    final plaintext = await _decryptIncoming(msg);

    await LocalStorageService.instance.saveMessage(
      id:        msg.tempId ?? _uuid.v4(),
      chatId:    msg.chatId,
      senderId:  msg.senderId,
      content:   plaintext,    // Сохраняем расшифрованное
      mediaType: msg.mediaType,
      sentAt:    msg.sentAt,
      status:    'delivered',
      isMe:      false,
    );
    await LocalStorageService.instance.updateLastMessage(
        msg.chatId, plaintext, msg.sentAt);

    if (!_senderNames.containsKey(msg.senderId)) {
      final c = await LocalStorageService.instance.getContact(msg.senderId);
      if (c != null && mounted) {
        setState(() => _senderNames[msg.senderId] = c.displayName);
        if (c.publicKey != null) _publicKeys[msg.senderId] = c.publicKey!;
      }
    }
    if (!_memberIds.contains(msg.senderId)) {
      if (mounted) setState(() => _memberIds.add(msg.senderId));
    }

    if (_chat?.type == 'direct') {
      WebSocketService.instance.sendRead(
        chatId:     widget.chatId,
        senderId:   msg.senderId,
        upToTempId: msg.tempId,
      );
    }
    _scrollToBottom();
  }

  // ── Шифрование и отправка ─────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _sending) return;

    if (_memberIds.isEmpty) {
      await _fetchMembersFromServer();
      if (_memberIds.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось загрузить участников')),
        );
        return;
      }
    }

    setState(() => _sending = true);
    _textCtrl.clear();
    _stopMyTyping();

    final tempId = _uuid.v4();
    final sentAt = DateTime.now().toUtc().toIso8601String();

    // Сохраняем plaintext локально сразу
    await LocalStorageService.instance.saveMessage(
      id:       tempId,
      chatId:   widget.chatId,
      senderId: _myUserId,
      content:  text,
      sentAt:   sentAt,
      status:   'sending',
      isMe:     true,
    );
    await LocalStorageService.instance.updateLastMessage(widget.chatId, text, sentAt);
    _scrollToBottom();

    // Шифруем для каждого получателя
    String encryptedContent = text;
    String? iv;
    Map<int, String> encryptedKeys = {};
    bool encryptionOk = false;

    try {
      if (_chat?.type == 'direct' && _peerId != null) {
        final peerPubKey = _publicKeys[_peerId!];
        if (peerPubKey != null && peerPubKey.isNotEmpty) {
          final payload = CryptoService.instance.encryptForRecipient(text, peerPubKey);
          encryptedContent = payload.encryptedContent;
          iv               = payload.iv;
          encryptedKeys[_peerId!] = payload.encryptedKey;
          encryptionOk = true;
        }
      } else if (_chat?.type == 'group') {
        // Группа: шифруем для всех у кого есть публичный ключ
        final keysAvailable = Map<int, String>.from(_publicKeys)
          ..remove(_myUserId);
        if (keysAvailable.isNotEmpty) {
          final payload = CryptoService.instance.encryptForGroup(text, keysAvailable);
          encryptedContent = payload.encryptedContent;
          iv               = payload.iv;
          encryptedKeys    = payload.encryptedKeys;
          encryptionOk = true;
        }
      }
    } catch (e) {
      debugPrint('[ChatScreen] Encrypt error: $e — sending plaintext');
    }

    if (!encryptionOk) {
      debugPrint('[ChatScreen] No public key — sending without encryption');
    }

    final sent = WebSocketService.instance.sendMessage(
      chatId:           widget.chatId,
      tempId:           tempId,
      encryptedContent: encryptedContent,
      recipientIds:     _memberIds,
      iv:               iv,
      encryptedKeys:    encryptedKeys,
    );

    if (!sent) {
      await LocalStorageService.instance.updateMessageStatus(tempId, 'sending');
    }

    if (mounted) setState(() => _sending = false);
  }

  void _onTextChanged(String _) {
    if (_memberIds.isEmpty) return;
    _myTypingTimer?.cancel();
    WebSocketService.instance.sendTyping(
      chatId: widget.chatId, recipientIds: _memberIds, isTyping: true);
    _myTypingTimer = Timer(const Duration(seconds: 2), _stopMyTyping);
  }

  void _stopMyTyping() {
    _myTypingTimer?.cancel();
    if (_memberIds.isEmpty) return;
    WebSocketService.instance.sendTyping(
      chatId: widget.chatId, recipientIds: _memberIds, isTyping: false);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _openVerification() async {
    if (_peerContact == null) return;
    context.push('/verify/${_peerId}', extra: {
      'peerName':      _peerContact!.displayName,
      'peerPublicKey': _peerContact!.publicKey,
    });
  }

  Future<void> _deleteChat() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Удалить чат?'),
        content: const Text(
            'Все сообщения будут удалены с этого устройства. '
            'Собеседник не потеряет свои сообщения.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_deletedChatsKey) ?? [];
    if (!raw.contains(widget.chatId.toString())) {
      raw.add(widget.chatId.toString());
      await prefs.setStringList(_deletedChatsKey, raw);
    }

    await ChatService.deleteChat(widget.chatId);
    await LocalStorageService.instance.deleteChatFull(widget.chatId);
    if (mounted) context.go('/chats');
  }

  @override
  void dispose() {
    for (final s in _subs) s.cancel();
    _typingTimer?.cancel();
    _myTypingTimer?.cancel();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _stopMyTyping();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: Column(
        children: [
          const ConnectionStatusBar(),
          Expanded(child: _buildMessages()),
          if (_isTyping) _buildTypingIndicator(),
          _buildInput(),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final isGroup = _chat?.type == 'group';
    final name    = isGroup ? (_chat?.name ?? 'Группа')
                            : (_peerContact?.displayName ?? 'Пользователь');
    final avatarUrl = isGroup ? _chat?.avatarUrl : _peerContact?.avatarUrl;

    // Проверяем верификацию
    final bool hasKey = !isGroup && (_peerContact?.publicKey?.isNotEmpty ?? false);

    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () {
          if (context.canPop()) context.pop();
          else context.go('/chats');
        },
      ),
      titleSpacing: 0,
      title: GestureDetector(
        onTap: isGroup ? () => context.push('/group-info/${widget.chatId}') : null,
        child: Row(
          children: [
            _AppBarAvatar(name: name, url: avatarUrl, isGroup: isGroup),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  if (!isGroup && _peerId != null)
                    OnlineStatusText(userId: _peerId!, style: const TextStyle(fontSize: 12))
                  else if (isGroup)
                    Text('${_memberIds.length + 1} участников',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        // Иконка замка / верификации
        if (hasKey)
          IconButton(
            icon: const Icon(Icons.verified_user_outlined),
            tooltip: 'Верификация устройства',
            onPressed: _openVerification,
          ),
        if (isGroup)
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => context.push('/group-info/${widget.chatId}'),
          ),
        PopupMenuButton<String>(
          onSelected: (v) { if (v == 'delete') _deleteChat(); },
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'delete',
              child: Row(children: [
                Icon(Icons.delete_outline, color: Colors.red),
                SizedBox(width: 8),
                Text('Удалить чат', style: TextStyle(color: Colors.red)),
              ]),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMessages() {
    if (_loadingMembers) {
      return const Center(child: CircularProgressIndicator());
    }
    return StreamBuilder<List<Message>>(
      stream: LocalStorageService.instance.watchMessages(widget.chatId),
      builder: (context, snap) {
        final msgs = snap.data ?? [];
        if (msgs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Напиши первое сообщение 👋',
                    style: TextStyle(color: Colors.grey)),
                const SizedBox(height: 8),
                if (_chat?.type == 'direct' && _peerContact?.publicKey != null)
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock, size: 14, color: Colors.green),
                      SizedBox(width: 4),
                      Text('E2E шифрование активно',
                          style: TextStyle(fontSize: 12, color: Colors.green)),
                    ],
                  ),
              ],
            ),
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
        return ListView.builder(
          controller: _scrollCtrl,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: msgs.length,
          itemBuilder: (context, i) {
            final msg = msgs[i];
            final showDate = i == 0 ||
                !_sameDay(DateTime.parse(msgs[i - 1].sentAt), DateTime.parse(msg.sentAt));
            final showSender = _chat?.type == 'group' && !msg.isMe;
            return Column(
              children: [
                if (showDate) _DateDivider(iso: msg.sentAt),
                MessageBubble(
                  message:    msg,
                  myUserId:   _myUserId,
                  senderName: showSender ? (_senderNames[msg.senderId] ?? 'Участник') : null,
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildTypingIndicator() {
    final name = _chat?.type == 'group' ? 'Участник' : (_peerContact?.displayName ?? '');
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 4),
      child: Row(children: [
        Text(name, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(width: 4),
        const Text('печатает...', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(width: 6),
        const _TypingDots(),
      ]),
    );
  }

  Widget _buildInput() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF252525) : const Color(0xFFF0F0F0),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller:      _textCtrl,
                  onChanged:       _onTextChanged,
                  onSubmitted:     (_) => _send(),
                  maxLines:        null,
                  textInputAction: TextInputAction.send,
                  decoration: const InputDecoration(
                    hintText: 'Сообщение...',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            FloatingActionButton.small(
              onPressed: _sending ? null : _send,
              elevation: 1,
              child: _sending
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded),
            ),
          ],
        ),
      ),
    );
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _AppBarAvatar extends StatelessWidget {
  final String name;
  final String? url;
  final bool isGroup;
  const _AppBarAvatar({required this.name, this.url, required this.isGroup});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 18,
      backgroundColor: const Color(0xFF6C63FF),
      backgroundImage: url != null ? NetworkImage(url!) : null,
      child: url == null
          ? (isGroup
              ? const Icon(Icons.group, color: Colors.white, size: 18)
              : Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))
          : null,
    );
  }
}

class _DateDivider extends StatelessWidget {
  final String iso;
  const _DateDivider({required this.iso});

  @override
  Widget build(BuildContext context) {
    final dt  = DateTime.parse(iso).toLocal();
    final now = DateTime.now();
    final String label;
    if (now.difference(dt).inDays == 0)
      label = 'Сегодня';
    else if (now.difference(dt).inDays == 1)
      label = 'Вчера';
    else
      label = '${dt.day}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        const Expanded(child: Divider()),
      ]),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Row(
        children: List.generate(3, (i) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: Opacity(
            opacity: (((_ctrl.value * 3 - i) % 3 + 3) % 3 < 1) ? 1.0 : 0.3,
            child: const CircleAvatar(radius: 3, backgroundColor: Colors.grey),
          ),
        )),
      ),
    );
  }
}
