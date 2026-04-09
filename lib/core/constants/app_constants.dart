class AppConstants {
  // Замени на свой URL после деплоя на Render
  static const serverUrl = 'https://privachat-server.onrender.com';
  static const wsUrl = 'wss://privachat-server.onrender.com';
  
  // Для локальной разработки:
  // static const serverUrl = 'http://10.0.2.2:3000'; // Android эмулятор
  // static const wsUrl = 'ws://10.0.2.2:3000';
  
  static const tokenKey = 'auth_token';
  static const userIdKey = 'user_id';
  static const privateKeyKey = 'private_key';
  static const publicKeyKey = 'public_key';
}