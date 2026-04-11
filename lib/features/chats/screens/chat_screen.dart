import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/database/app_database.dart';
import '../../../core/services/local_storage_service.dart';
import '../../../core/services/websocket_service.dart';
import '../../../core/widgets/connection_status_bar.dart';
import '../widgets/message_bubble.dart';

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

  // Direct: единственный собеседник
  int?     _peerId;
  Contact? _peerContact;

  // Group: все участники кроме себя (для relay)
  List<int> _memberIds = [];

  bool _isTyping = false;
  Timer? _typingTimer;
  Timer? _myTypingTimer;
  bool _sending = false;

  final List<StreamSubscription> _subs = [];

  // Кэш имён отправителей для группы
  final Map<int, String> _senderNames = {};

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
    }

    // Загружаем всех участников (и для direct, и для group)
    final members = await LocalStorageService.instance.getChatMembers(widget.chatId);
    _memberIds = members
        .map((m) => m.userId)
        .where((id) => id != _myUserId)
        .toList();

    // Кэш имён для группы
    for (final m in members) {
      if (m.userId == _myUserId) continue;
      final c = await LocalStorageService.instance.getContact(m.userId);
      if (c != null) _senderNames[m.userId] = c.displayName;
    }

    if (mounted) setState(() {});

    await LocalStorageService.instance.clearUnread(widget.chatId);
    _subscribeWs();
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
        _typingTimer = Timer(const Duration(seconds: 3),
            () { if (mounted) setState(() => _isTyping = false); });
      }
    }));

    _subs.add(ws.onRead.listen((r) {
      if (r.chatId != widget.chatId) return;
      // TODO: обновить статус read в Шаге 8
    }));
  }

  Future<void> _handleIncoming(WsMessage msg) async {
    await LocalStorageService.instance.saveMessage(
      id:        msg.tempId ?? _uuid.v4(),
      chatId:    msg.chatId,
      senderId:  msg.senderId,
      content:   msg.encryptedContent, // TODO: decrypt Step 8
      mediaType: msg.mediaType,
      sentAt:    msg.sentAt,
      status:    'delivered',
      isMe:      false,
    );
    await LocalStorageService.instance.updateLastMessage(
        msg.chatId, msg.encryptedContent, msg.sentAt);

    // read receipt только для direct
    if (_chat?.type == 'direct') {
      WebSocketService.instance.sendRead(
        chatId:    widget.chatId,
        senderId:  msg.senderId,
        upToTempId: msg.tempId,
      );
    }
    _scrollToBottom();
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _sending || _memberIds.isEmpty) return;

    setState(() => _sending = true);
    _textCtrl.clear();
    _stopMyTyping();

    final tempId = _uuid.v4();
    final sentAt = DateTime.now().toUtc().toIso8601String();

    await LocalStorageService.instance.saveMessage(
      id:       tempId,
      chatId:   widget.chatId,
      senderId: _myUserId,
      content:  text,
      sentAt:   sentAt,
      status:   'sending',
      isMe:     true,
    );
    await LocalStorageService.instance.updateLastMessage(
        widget.chatId, text, sentAt);

    _scrollToBottom();

    // TODO (Шаг 8): зашифровать text
    final sent = WebSocketService.instance.sendMessage(
      chatId:           widget.chatId,
      tempId:           tempId,
      encryptedContent: text,
      recipientIds:     _memberIds, // для групп — все участники
    );

    if (!sent) debugPrint('[Chat] WS offline — message queued locally');

    late StreamSubscription ackSub;
    ackSub = WebSocketService.instance.onAck.listen((ack) async {
      if (ack.tempId != tempId) return;
      await LocalStorageService.instance.updateMessageStatus(
          tempId, ack.delivered ? 'delivered' : 'sent');
      ackSub.cancel();
    });

    if (mounted) setState(() => _sending = false);
  }

  void _onTextChanged(String _) {
    if (_memberIds.isEmpty) return;
    _myTypingTimer?.cancel();
    WebSocketService.instance.sendTyping(
      chatId:       widget.chatId,
      recipientIds: _memberIds,
      isTyping:     true,
    );
    _myTypingTimer = Timer(const Duration(seconds: 2), _stopMyTyping);
  }

  void _stopMyTyping() {
    _myTypingTimer?.cancel();
    if (_memberIds.isEmpty) return;
    WebSocketService.instance.sendTyping(
      chatId:       widget.chatId,
      recipientIds: _memberIds,
      isTyping:     false,
    );
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

  // ── Build ──────────────────────────────────────────────────────────────────

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
    final name = isGroup
        ? (_chat?.name ?? 'Группа')
        : (_peerContact?.displayName ?? 'Пользователь');
    final avatarUrl = isGroup ? _chat?.avatarUrl : _peerContact?.avatarUrl;

    return AppBar(
      titleSpacing: 0,
      title: GestureDetector(
        onTap: isGroup
            ? () => context.push('/group-info/${widget.chatId}')
            : null,
        child: Row(
          children: [
            _AppBarAvatar(
                name: name, url: avatarUrl, isGroup: isGroup),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  if (!isGroup && _peerId != null)
                    OnlineStatusText(userId: _peerId!,
                        style: const TextStyle(fontSize: 12))
                  else if (isGroup)
                    Text('${_memberIds.length + 1} участников',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (isGroup)
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => context.push('/group-info/${widget.chatId}'),
          ),
      ],
    );
  }

  Widget _buildMessages() {
    return StreamBuilder<List<Message>>(
      stream: LocalStorageService.instance.watchMessages(widget.chatId),
      builder: (context, snap) {
        final msgs = snap.data ?? [];
        if (msgs.isEmpty) {
          return const Center(
            child: Text('Напиши первое сообщение 👋',
                style: TextStyle(color: Colors.grey)),
          );
        }
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _scrollToBottom());

        return ListView.builder(
          controller: _scrollCtrl,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: msgs.length,
          itemBuilder: (context, i) {
            final msg = msgs[i];
            final showDate = i == 0 ||
                !_sameDay(DateTime.parse(msgs[i - 1].sentAt),
                    DateTime.parse(msg.sentAt));
            // Показываем имя отправителя в группах
            final showSender = _chat?.type == 'group' && !msg.isMe;
            return Column(
              children: [
                if (showDate) _DateDivider(iso: msg.sentAt),
                MessageBubble(
                  message:    msg,
                  myUserId:   _myUserId,
                  senderName: showSender
                      ? (_senderNames[msg.senderId] ?? 'Участник')
                      : null,
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
                  color: isDark
                      ? const Color(0xFF252525) : const Color(0xFFF0F0F0),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller:       _textCtrl,
                  onChanged:        _onTextChanged,
                  onSubmitted:      (_) => _send(),
                  maxLines:         null,
                  textInputAction:  TextInputAction.send,
                  decoration: const InputDecoration(
                    hintText: 'Сообщение...',
                    border: InputBorder.none,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
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
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)))
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
    if (now.difference(dt).inDays == 0)      label = 'Сегодня';
    else if (now.difference(dt).inDays == 1) label = 'Вчера';
    else label = '${dt.day}.${dt.month.toString().padLeft(2,'0')}.${dt.year}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
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
