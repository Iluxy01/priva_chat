import 'package:flutter/material.dart';
import '../../../core/database/app_database.dart';

class MessageBubble extends StatelessWidget {
  final Message message;
  final int myUserId;

  const MessageBubble({
    super.key,
    required this.message,
    required this.myUserId,
  });

  @override
  Widget build(BuildContext context) {
    final isMe = message.isMe;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bubbleColor = isMe
        ? const Color(0xFF6C63FF)
        : (isDark ? const Color(0xFF2C2C2C) : const Color(0xFFEEEEEE));

    final textColor = isMe
        ? Colors.white
        : (isDark ? const Color(0xFFF0F0F0) : const Color(0xFF1A1A1A));

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          top: 2,
          bottom: 2,
          left:  isMe ? 60 : 0,
          right: isMe ? 0  : 60,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft:     const Radius.circular(18),
            topRight:    const Radius.circular(18),
            bottomLeft:  Radius.circular(isMe ? 18 : 4),
            bottomRight: Radius.circular(isMe ? 4  : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message.content,
              style: TextStyle(color: textColor, fontSize: 15, height: 1.3),
            ),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _fmtTime(message.sentAt),
                  style: TextStyle(
                    fontSize: 10,
                    color: isMe ? Colors.white70 : Colors.grey,
                  ),
                ),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  _StatusIcon(status: message.status),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmtTime(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }
}

class _StatusIcon extends StatelessWidget {
  final String status;
  const _StatusIcon({required this.status});

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      'sending'   => const Icon(Icons.access_time_rounded,         size: 12, color: Colors.white54),
      'sent'      => const Icon(Icons.check_rounded,                size: 12, color: Colors.white70),
      'delivered' => const Icon(Icons.done_all_rounded,             size: 12, color: Colors.white70),
      'read'      => const Icon(Icons.done_all_rounded,             size: 12, color: Color(0xFF80DFFF)),
      _           => const SizedBox.shrink(),
    };
  }
}
