import 'dart:async';
import 'package:flutter/material.dart';
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
  final _textCtrl  = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _uuid      = const Uuid();

  int _myUserId  = 0;
  int? _peerId;
  String _peerName = '';
  Contact? _peerContact;
  Chat? _chat;

  bool _isTyping = false;         // собеседник печатает
  Timer? _typingTimer;            // сбрасывает индикатор через 3с
  Timer? _myTypingTimer;          // debounce нашего typing event
  bool _sending = false;

  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _myUserId = prefs.getInt(AppConstants.userIdKey) ?? 0;

    _chat = await LocalStorageService.instance.getChat(widget.chatId);
    if (_chat != null && _chat!.peerId != null) {
      _peerId = _chat!.peerId;
      _peerContact = await LocalStorageService.instance.getContact(_peerId!);
      _peerName = _peerContact?.displayName ?? _peerContact?.username ?? 'Пользователь';
    }

    if (mounted) setState(() {});

    // Очистить непрочитанные
    await LocalStorageService.instance.clearUnread(widget.chatId);

    _subscribeWs();
  }

  void _subscribeWs() {
    final ws = WebSocketService.instance;

    // Входящие сообщения
    _subs.add(ws.onMessage.listen((msg) {
      if (msg.chatId != widget.chatId) return;
      _handleIncoming(msg);
    }));

    // Индикатор печати
    _subs.add(ws.onTyping.listen((t) {
      if (t.chatId != widget.chatId || t.senderId == _myUserId) return;
      _typingTimer?.cancel();
      if (!mounted) return;
      setState(() => _isTyping = t.isTyping);
      if (t.isTyping) {
        _typingTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _isTyping = false);
        });
      }
    }));

    // Статус "прочитано"
    _subs.add(ws.onRead.listen((r) {
      if (r.chatId != widget.chatId) return;
      // В Шаге 8 обновим статус сообщений; здесь просто логируем
    }));
  }

  Future<void> _handleIncoming(WsMessage msg) async {
    // На данном этапе (до Шага 8) сохраняем encrypted_content как plaintext.
    // После добавления E2E (Шаг 8) здесь будет расшифровка.
    await LocalStorageService.instance.saveMessage(
      id:        msg.tempId ?? _uuid.v4(),
      chatId:    msg.chatId,
      senderId:  msg.senderId,
      content:   msg.encryptedContent, // TODO: decrypt in Step 8
      mediaType: msg.mediaType,
      sentAt:    msg.sentAt,
      status:    'delivered',
      isMe:      false,
    );

    await LocalStorageService.instance.updateLastMessage(
      msg.chatId,
      msg.encryptedContent,
      msg.sentAt,
    );

    // Отправить read-receipt
    if (_peerId != null) {
      WebSocketService.instance.sendRead(
        chatId:     widget.chatId,
        senderId:   msg.senderId,
        upToTempId: msg.tempId,
      );
    }

    _scrollToBottom();
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _sending || _peerId == null) return;

    setState(() => _sending = true);
    _textCtrl.clear();
    _stopMyTyping();

    final tempId  = _uuid.v4();
    final sentAt  = DateTime.now().toUtc().toIso8601String();

    // Сохраняем локально сразу (optimistic)
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
      widget.chatId, text, sentAt,
    );

    _scrollToBottom();

    // TODO (Шаг 8): зашифровать text перед отправкой
    final sent = WebSocketService.instance.sendMessage(
      chatId:           widget.chatId,
      tempId:           tempId,
      encryptedContent: text, // TODO: encrypt in Step 8
      recipientIds:     [_peerId!],
    );

    if (!sent) {
      // WS не подключён — помечаем 'sending', доставим при reconnect (Шаг 9)
      debugPrint('[Chat] WS offline — message queued locally');
    }

    // Слушаем ACK, чтобы обновить статус
    late StreamSubscription ackSub;
    ackSub = WebSocketService.instance.onAck.listen((ack) async {
      if (ack.tempId != tempId) return;
      await LocalStorageService.instance.updateMessageStatus(
        tempId,
        ack.delivered ? 'delivered' : 'sent',
      );
      ackSub.cancel();
    });

    if (mounted) setState(() => _sending = false);
  }

  // ── Typing indicator ────────────────────────────────────────────────────────

  void _onTextChanged(String _) {
    if (_peerId == null) return;
    _myTypingTimer?.cancel();

    WebSocketService.instance.sendTyping(
      chatId:       widget.chatId,
      recipientIds: [_peerId!],
      isTyping:     true,
    );

    _myTypingTimer = Timer(const Duration(seconds: 2), _stopMyTyping);
  }

  void _stopMyTyping() {
    _myTypingTimer?.cancel();
    if (_peerId == null) return;
    WebSocketService.instance.sendTyping(
      chatId:       widget.chatId,
      recipientIds: [_peerId!],
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
    return AppBar(
      titleSpacing: 0,
      title: Row(
        children: [
          _SmallAvatar(name: _peerName, url: _peerContact?.avatarUrl),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_peerName,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                if (_peerId != null)
                  OnlineStatusText(userId: _peerId!, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
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

        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

        return ListView.builder(
          controller: _scrollCtrl,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: msgs.length,
          itemBuilder: (context, i) {
            final msg = msgs[i];
            final showDate = i == 0 ||
                !_sameDay(
                    DateTime.parse(msgs[i - 1].sentAt),
                    DateTime.parse(msg.sentAt));
            return Column(
              children: [
                if (showDate) _DateDivider(iso: msg.sentAt),
                MessageBubble(message: msg, myUserId: _myUserId),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 4),
      child: Row(
        children: [
          Text(_peerName, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(width: 4),
          const Text('печатает...', style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(width: 6),
          const _TypingDots(),
        ],
      ),
    );
  }

  Widget _buildInput() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

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
                  controller: _textCtrl,
                  onChanged: _onTextChanged,
                  onSubmitted: (_) => _send(),
                  maxLines: null,
                  textInputAction: TextInputAction.send,
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
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              child: FloatingActionButton.small(
                onPressed: _sending ? null : _send,
                elevation: 1,
                child: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send_rounded),
              ),
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

class _DateDivider extends StatelessWidget {
  final String iso;
  const _DateDivider({required this.iso});

  @override
  Widget build(BuildContext context) {
    final dt = DateTime.parse(iso).toLocal();
    final now = DateTime.now();
    String label;
    if (now.difference(dt).inDays == 0)       label = 'Сегодня';
    else if (now.difference(dt).inDays == 1)  label = 'Вчера';
    else                                       label = '${dt.day}.${dt.month.toString().padLeft(2,'0')}.${dt.year}';

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

class _SmallAvatar extends StatelessWidget {
  final String name;
  final String? url;
  const _SmallAvatar({required this.name, this.url});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 18,
      backgroundColor: const Color(0xFF6C63FF),
      backgroundImage: url != null ? NetworkImage(url!) : null,
      child: url == null
          ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
          : null,
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
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return Row(
          children: List.generate(3, (i) {
            final opacity = (((_ctrl.value * 3 - i) % 3 + 3) % 3 < 1)
                ? 1.0
                : 0.3;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Opacity(
                opacity: opacity,
                child: const CircleAvatar(
                    radius: 3, backgroundColor: Colors.grey),
              ),
            );
          }),
        );
      },
    );
  }
}
