import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import 'secure_storage_service.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  CryptoService  —  RSA-OAEP-SHA256 + AES-256-CBC + SHA-256 fingerprint
//
//  Ключи хранятся в JSON-формате (компоненты BigInt в base64),
//  а не в PEM — это позволяет избежать зависимости от ASN1-кодировщиков.
//  Публичный ключ передаётся на сервер тоже в JSON (base64 n + e).
// ═══════════════════════════════════════════════════════════════════════════

class CryptoService {
  static final CryptoService _instance = CryptoService._();
  static CryptoService get instance => _instance;
  CryptoService._();

  // ─────────────────────────────────────────────────────────────────────────
  //  Генерация RSA-2048
  // ─────────────────────────────────────────────────────────────────────────

  /// Генерирует RSA-2048 в Isolate, сохраняет в SecureStorage.
  /// Возвращает публичный ключ в виде JSON-строки для отправки на сервер.
  Future<String> generateAndStoreKeyPair() async {
    debugPrint('[Crypto] Generating RSA-2048…');
    final pair = await compute(_generateRsaKeyPairIsolate, null);
    final pub  = pair.publicKey  as RSAPublicKey;
    final priv = pair.privateKey as RSAPrivateKey;

    final pubJson  = _publicKeyToJson(pub);
    final privJson = _privateKeyToJson(priv);

    await SecureStorageService.savePublicKey(pubJson);
    await SecureStorageService.savePrivateKey(privJson);
    debugPrint('[Crypto] Key pair ready.');
    return pubJson;
  }

  /// Гарантирует наличие ключей; если нет — генерирует.
  Future<String> ensureKeyPair() async {
    if (await SecureStorageService.hasKeys()) {
      final pub = await SecureStorageService.getPublicKey();
      if (pub != null && pub.isNotEmpty) return pub;
    }
    return generateAndStoreKeyPair();
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  RSA OAEP — шифрование / дешифрование AES-ключей
  // ─────────────────────────────────────────────────────────────────────────

  /// Шифрует 32-байтный AES-ключ RSA-OAEP публичным ключом получателя.
  String encryptAesKey(Uint8List aesKey, String recipientPublicKeyJson) {
    final pub    = _publicKeyFromJson(recipientPublicKeyJson);
    final cipher = OAEPEncoding.withSHA256(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(pub));
    return base64.encode(cipher.process(aesKey));
  }

  /// Расшифровывает AES-ключ нашим RSA приватным ключом.
  Future<Uint8List> decryptAesKeyFromBase64(String encryptedBase64) async {
    final privJson = await SecureStorageService.getPrivateKey();
    if (privJson == null || privJson.isEmpty) {
      throw const CryptoException('Приватный ключ не найден');
    }
    final priv   = _privateKeyFromJson(privJson);
    final cipher = OAEPEncoding.withSHA256(RSAEngine())
      ..init(false, PrivateKeyParameter<RSAPrivateKey>(priv));
    return cipher.process(base64.decode(encryptedBase64));
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  AES-256-CBC
  // ─────────────────────────────────────────────────────────────────────────

  EncryptedMessage _aesEncrypt(String plaintext, Uint8List aesKey, Uint8List iv) {
    final encrypter = enc.Encrypter(enc.AES(enc.Key(aesKey), mode: enc.AESMode.cbc));
    final encrypted = encrypter.encrypt(plaintext, iv: enc.IV(iv));
    return EncryptedMessage(
      ciphertext: encrypted.base64,
      iv:         base64.encode(iv),
      aesKey:     aesKey,
    );
  }

  String decryptMessage(String ciphertextBase64, Uint8List aesKey, String ivBase64) {
    final encrypter = enc.Encrypter(enc.AES(enc.Key(aesKey), mode: enc.AESMode.cbc));
    return encrypter.decrypt64(ciphertextBase64, iv: enc.IV(base64.decode(ivBase64)));
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Высокоуровневое API
  // ─────────────────────────────────────────────────────────────────────────

  OutgoingPayload encryptForRecipient(String plaintext, String recipientPublicKeyJson) {
    final aesKey    = _randomBytes(32);
    final iv        = _randomBytes(16);
    final encrypted = _aesEncrypt(plaintext, aesKey, iv);
    return OutgoingPayload(
      encryptedContent: encrypted.ciphertext,
      iv:               encrypted.iv,
      encryptedKey:     encryptAesKey(aesKey, recipientPublicKeyJson),
    );
  }

  OutgoingGroupPayload encryptForGroup(
    String plaintext,
    Map<int, String> recipientPublicKeys,
  ) {
    final aesKey    = _randomBytes(32);
    final iv        = _randomBytes(16);
    final encrypted = _aesEncrypt(plaintext, aesKey, iv);
    final keys      = <int, String>{};
    for (final e in recipientPublicKeys.entries) {
      keys[e.key] = encryptAesKey(aesKey, e.value);
    }
    return OutgoingGroupPayload(
      encryptedContent: encrypted.ciphertext,
      iv:               encrypted.iv,
      encryptedKeys:    keys,
    );
  }

  /// Расшифровывает входящее сообщение.
  /// [rawEncryptedKey] — base64-строка или JSON {userId: base64}
  Future<String> decryptMessage2({
    required String encryptedContent,
    required String iv,
    required String rawEncryptedKey,
    int? myUserId,
  }) async {
    String keyBase64 = rawEncryptedKey;

    if (rawEncryptedKey.startsWith('{')) {
      try {
        final map = jsonDecode(rawEncryptedKey) as Map<String, dynamic>;
        keyBase64 = '';
        if (myUserId != null) {
          keyBase64 = (map[myUserId.toString()] ?? map[myUserId] ?? '') as String;
        }
        if (keyBase64.isEmpty) {
          for (final v in map.values) {
            if (v is String && v.isNotEmpty) { keyBase64 = v; break; }
          }
        }
        if (keyBase64.isEmpty) throw const CryptoException('Ключ не найден');
      } catch (e) {
        if (e is CryptoException) rethrow;
        throw CryptoException('Ошибка разбора ключа: $e');
      }
    }

    final aesKey = await decryptAesKeyFromBase64(keyBase64);
    return decryptMessage(encryptedContent, aesKey, iv);
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Fingerprint (SHA-256)
  // ─────────────────────────────────────────────────────────────────────────

  static String fingerprint(String publicKeyJson) {
    final digest = sha256.convert(utf8.encode(publicKeyJson));
    final hex    = digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final groups = <String>[];
    for (var i = 0; i < hex.length; i += 4) {
      groups.add(hex.substring(i, min(i + 4, hex.length)));
    }
    return groups.join(':').toUpperCase();
  }

  static String shortFingerprint(String publicKeyJson) =>
      fingerprint(publicKeyJson).replaceAll(':', '').substring(0, 8);

  static bool verifyFingerprint(String key1, String key2) =>
      fingerprint(key1) == fingerprint(key2);

  // ─────────────────────────────────────────────────────────────────────────
  //  Сериализация ключей (JSON с BigInt в base64)
  //  Формат публичного: {"n": "<base64>", "e": "<base64>"}
  //  Формат приватного: {"n":"…","e":"…","d":"…","p":"…","q":"…"}
  // ─────────────────────────────────────────────────────────────────────────

  static String _publicKeyToJson(RSAPublicKey key) {
    return jsonEncode({
      'n': _bigIntToBase64(key.modulus!),
      'e': _bigIntToBase64(key.exponent!),
    });
  }

  static String _privateKeyToJson(RSAPrivateKey key) {
    return jsonEncode({
      'n': _bigIntToBase64(key.modulus!),
      'e': _bigIntToBase64(BigInt.from(65537)), // always 65537
      'd': _bigIntToBase64(key.privateExponent!),
      'p': _bigIntToBase64(key.p!),
      'q': _bigIntToBase64(key.q!),
    });
  }

  static RSAPublicKey _publicKeyFromJson(String json) {
    final m = jsonDecode(json) as Map<String, dynamic>;
    return RSAPublicKey(
      _base64ToBigInt(m['n'] as String),
      _base64ToBigInt(m['e'] as String),
    );
  }

  static RSAPrivateKey _privateKeyFromJson(String json) {
    final m = jsonDecode(json) as Map<String, dynamic>;
    return RSAPrivateKey(
      _base64ToBigInt(m['n'] as String),
      _base64ToBigInt(m['d'] as String),
      _base64ToBigInt(m['p'] as String),
      _base64ToBigInt(m['q'] as String),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  BigInt ↔ Base64
  // ─────────────────────────────────────────────────────────────────────────

  static String _bigIntToBase64(BigInt n) {
    // Convert BigInt to big-endian bytes
    var hex = n.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return base64Url.encode(bytes);
  }

  static BigInt _base64ToBigInt(String b64) {
    final bytes = base64Url.decode(b64);
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Random bytes
  // ─────────────────────────────────────────────────────────────────────────

  static Uint8List _randomBytes(int n) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
  }
}

// ── Isolate worker ────────────────────────────────────────────────────────

AsymmetricKeyPair<PublicKey, PrivateKey> _generateRsaKeyPairIsolate(void _) {
  final secRandom = FortunaRandom()
    ..seed(KeyParameter(_isolateRandomBytes(32)));
  final gen = RSAKeyGenerator()
    ..init(ParametersWithRandom(
      RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
      secRandom,
    ));
  return gen.generateKeyPair();
}

Uint8List _isolateRandomBytes(int n) {
  final rng = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
}

// ═══════════════════════════════════════════════════════════════════════════
//  Data classes
// ═══════════════════════════════════════════════════════════════════════════

class EncryptedMessage {
  final String ciphertext;
  final String iv;
  final Uint8List aesKey;
  const EncryptedMessage({required this.ciphertext, required this.iv, required this.aesKey});
}

class OutgoingPayload {
  final String encryptedContent;
  final String iv;
  final String encryptedKey;
  const OutgoingPayload({
    required this.encryptedContent,
    required this.iv,
    required this.encryptedKey,
  });
}

class OutgoingGroupPayload {
  final String encryptedContent;
  final String iv;
  final Map<int, String> encryptedKeys;
  const OutgoingGroupPayload({
    required this.encryptedContent,
    required this.iv,
    required this.encryptedKeys,
  });
}

class CryptoException implements Exception {
  final String message;
  const CryptoException(this.message);
  @override
  String toString() => 'CryptoException: $message';
}
