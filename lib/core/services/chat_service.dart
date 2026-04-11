import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../constants/app_constants.dart';
import '../services/auth_service.dart';
import '../../features/auth/models/user_model.dart';

class ChatService {
  static const _base = AppConstants.serverUrl;

  // ── Заголовки ──────────────────────────────────────────────────────────────

  static Future<Map<String, String>> _headers() async {
    final token = await AuthService.getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // ── Хелпер: достать список из ответа сервера ───────────────────────────────
  // Сервер может вернуть:
  //   {"users": [...]}   ← нормальный формат (src/routes/users.js)
  //   [...]              ← голый массив (старая версия)
  static List<dynamic> _extractList(dynamic body, String key) {
    if (body is List) return body;
    if (body is Map) return (body[key] as List<dynamic>?) ?? [];
    return [];
  }

  // ── Поиск пользователей ────────────────────────────────────────────────────

  static Future<List<UserModel>> searchUsers(String query) async {
    if (query.trim().length < 2) return [];

    final headers = await _headers();
    if (!headers.containsKey('Authorization')) {
      throw const ChatException('Не авторизован — войди заново');
    }

    final uri = Uri.parse('$_base/users/search')
        .replace(queryParameters: {'q': query.trim()});

    debugPrint('[ChatService] GET $uri');

    http.Response res;
    try {
      res = await http.get(uri, headers: headers).timeout(const Duration(seconds: 10));
    } on Exception catch (e) {
      debugPrint('[ChatService] Network error: $e');
      throw const ChatException('Нет соединения с сервером');
    }

    debugPrint('[ChatService] search → ${res.statusCode}: ${res.body}');

    switch (res.statusCode) {
      case 200:
        final body = jsonDecode(res.body);
        final list = _extractList(body, 'users');
        return list.map((u) => UserModel.fromJson(u as Map<String, dynamic>)).toList();
      case 400:
        final b = jsonDecode(res.body);
        throw ChatException((b is Map ? b['error'] : null) ?? 'Слишком короткий запрос');
      case 401:
        throw const ChatException('Сессия устарела — войди заново');
      case 404:
        throw const ChatException('Маршрут не найден (404) — проверь URL сервера');
      default:
        throw ChatException('Ошибка сервера: ${res.statusCode}');
    }
  }

  // ── Список чатов с сервера ─────────────────────────────────────────────────

  static Future<List<ServerChat>> getChats() async {
    final headers = await _headers();
    if (!headers.containsKey('Authorization')) return [];

    http.Response res;
    try {
      res = await http
          .get(Uri.parse('$_base/chats'), headers: headers)
          .timeout(const Duration(seconds: 15));
    } on Exception catch (e) {
      debugPrint('[ChatService] getChats error: $e');
      return [];
    }

    debugPrint('[ChatService] getChats → ${res.statusCode}');

    if (res.statusCode == 200) {
      final body = jsonDecode(res.body);
      final list = _extractList(body, 'chats');
      return list.map((c) => ServerChat.fromJson(c as Map<String, dynamic>)).toList();
    }
    return [];
  }

  // ── Создать личный чат ─────────────────────────────────────────────────────

  static Future<int?> createDirectChat(int targetUserId) async {
    final headers = await _headers();
    if (!headers.containsKey('Authorization')) {
      throw const ChatException('Не авторизован');
    }

    http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('$_base/chats/direct'),
            headers: headers,
            body: jsonEncode({'target_user_id': targetUserId}),
          )
          .timeout(const Duration(seconds: 10));
    } on Exception catch (e) {
      debugPrint('[ChatService] createDirectChat error: $e');
      throw const ChatException('Нет соединения с сервером');
    }

    debugPrint('[ChatService] createDirectChat → ${res.statusCode}: ${res.body}');

    if (res.statusCode == 200 || res.statusCode == 201) {
      final body = jsonDecode(res.body);
      // Тоже может быть голый int или {"chat_id": N}
      if (body is int) return body;
      if (body is Map) return body['chat_id'] as int?;
    }
    throw ChatException('Ошибка создания чата: ${res.statusCode}');
  }

  // ── Участники чата ─────────────────────────────────────────────────────────

  static Future<List<UserModel>> getChatMembers(int chatId) async {
    final headers = await _headers();
    if (!headers.containsKey('Authorization')) return [];

    http.Response res;
    try {
      res = await http
          .get(Uri.parse('$_base/chats/$chatId/members'), headers: headers)
          .timeout(const Duration(seconds: 10));
    } on Exception catch (e) {
      debugPrint('[ChatService] getChatMembers error: $e');
      return [];
    }

    if (res.statusCode == 200) {
      final body = jsonDecode(res.body);
      final list = _extractList(body, 'members');
      return list.map((u) => UserModel.fromJson(u as Map<String, dynamic>)).toList();
    }
    return [];
  }
}

// ── Исключение ────────────────────────────────────────────────────────────────

class ChatException implements Exception {
  final String message;
  const ChatException(this.message);

  @override
  String toString() => message;
}

// ── DTO с сервера ──────────────────────────────────────────────────────────────

class ServerChat {
  final int id;
  final String type;
  final String? name;
  final String? avatarUrl;
  final List<UserModel> members;

  const ServerChat({
    required this.id,
    required this.type,
    this.name,
    this.avatarUrl,
    required this.members,
  });

  factory ServerChat.fromJson(Map<String, dynamic> j) {
    final rawMembers = j['members'] as List<dynamic>? ?? [];
    return ServerChat(
      id:        j['id'] as int,
      type:      j['type'] as String,
      name:      j['name'] as String?,
      avatarUrl: j['avatar_url'] as String?,
      members:   rawMembers
          .map((m) => UserModel.fromJson(m as Map<String, dynamic>))
          .toList(),
    );
  }
}
