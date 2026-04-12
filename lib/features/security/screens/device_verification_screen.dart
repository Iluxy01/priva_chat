import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/services/crypto_service.dart';
import '../../../core/services/secure_storage_service.dart';

/// Экран верификации устройства (Safety Numbers / Security Code).
/// Показывает fingerprint публичного ключа пользователя и собеседника,
/// чтобы пользователи могли убедиться что переписка не перехвачена.
class DeviceVerificationScreen extends StatefulWidget {
  final int peerId;
  final String peerName;
  final String? peerPublicKey;

  const DeviceVerificationScreen({
    super.key,
    required this.peerId,
    required this.peerName,
    this.peerPublicKey,
  });

  @override
  State<DeviceVerificationScreen> createState() =>
      _DeviceVerificationScreenState();
}

class _DeviceVerificationScreenState
    extends State<DeviceVerificationScreen> {
  String? _myFingerprint;
  String? _peerFingerprint;
  bool _loading = true;
  bool _verified = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final myPub = await SecureStorageService.getPublicKey();

    final myFp = myPub != null ? CryptoService.fingerprint(myPub) : null;
    final peerFp = widget.peerPublicKey != null
        ? CryptoService.fingerprint(widget.peerPublicKey!)
        : null;

    // Проверяем сохранённый статус верификации
    final verifiedKey = 'verified_${widget.peerId}';
    final savedPeerFp = await SecureStorageService.getSecret(verifiedKey);
    final alreadyVerified =
        savedPeerFp != null && savedPeerFp == widget.peerPublicKey;

    if (mounted) {
      setState(() {
        _myFingerprint   = myFp;
        _peerFingerprint = peerFp;
        _verified        = alreadyVerified;
        _loading         = false;
      });
    }
  }

  Future<void> _markVerified() async {
    if (widget.peerPublicKey == null) return;
    final verifiedKey = 'verified_${widget.peerId}';
    await SecureStorageService.saveSecret(verifiedKey, widget.peerPublicKey!);
    if (mounted) {
      setState(() => _verified = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Устройство подтверждено'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  void _copyFingerprint(String fp) {
    Clipboard.setData(ClipboardData(text: fp.replaceAll(':', ' ')));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Скопировано в буфер')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Верификация устройства'),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // ── Значок и заголовок ─────────────────────────────────
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: _verified
                          ? Colors.green.withOpacity(0.12)
                          : const Color(0xFF6C63FF).withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _verified ? Icons.verified_user : Icons.security,
                      size: 40,
                      color: _verified ? Colors.green : const Color(0xFF6C63FF),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _verified ? 'Устройство подтверждено' : 'Проверь подлинность',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Сравни коды безопасности с ${widget.peerName} через другой канал связи. '
                    'Если они совпадают — связь защищена и не перехвачена.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 32),

                  // ── Мой fingerprint ────────────────────────────────────
                  _FingerprintCard(
                    label: 'Твой код',
                    fingerprint: _myFingerprint,
                    isDark: isDark,
                    onCopy: _myFingerprint != null
                        ? () => _copyFingerprint(_myFingerprint!)
                        : null,
                  ),
                  const SizedBox(height: 16),

                  // ── Fingerprint собеседника ────────────────────────────
                  _FingerprintCard(
                    label: 'Код ${widget.peerName}',
                    fingerprint: _peerFingerprint,
                    isDark: isDark,
                    onCopy: _peerFingerprint != null
                        ? () => _copyFingerprint(_peerFingerprint!)
                        : null,
                  ),
                  const SizedBox(height: 32),

                  // ── Предупреждение ─────────────────────────────────────
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.amber.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.amber.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline,
                            color: Colors.amber, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Никогда не подтверждай, если коды не совпадают. '
                            'Это может означать атаку посредника (MITM).',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.amber[800]),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Кнопка ────────────────────────────────────────────
                  if (widget.peerPublicKey != null && !_verified)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _markVerified,
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text('Коды совпадают — подтвердить'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  if (_verified)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check_circle, color: Colors.green),
                          SizedBox(width: 8),
                          Text(
                            'Подтверждено тобой',
                            style: TextStyle(
                                color: Colors.green,
                                fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  if (widget.peerPublicKey == null)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Публичный ключ собеседника недоступен',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

// ── Виджет карточки с fingerprint ──────────────────────────────────────────

class _FingerprintCard extends StatelessWidget {
  final String label;
  final String? fingerprint;
  final bool isDark;
  final VoidCallback? onCopy;

  const _FingerprintCard({
    required this.label,
    required this.fingerprint,
    required this.isDark,
    this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withOpacity(0.08)
              : Colors.black.withOpacity(0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: Color(0xFF6C63FF),
                ),
              ),
              if (onCopy != null)
                GestureDetector(
                  onTap: onCopy,
                  child: const Icon(Icons.copy, size: 18, color: Colors.grey),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (fingerprint != null)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: fingerprint!
                  .split(':')
                  .map((group) => _FingerprintChip(group))
                  .toList(),
            )
          else
            const Text('Не найден',
                style: TextStyle(color: Colors.grey, fontSize: 13)),
        ],
      ),
    );
  }
}

class _FingerprintChip extends StatelessWidget {
  final String text;
  const _FingerprintChip(this.text);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF6C63FF).withOpacity(0.18)
            : const Color(0xFF6C63FF).withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          fontWeight: FontWeight.w500,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
