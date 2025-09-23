import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class CacheService {
  static const String _keyTimetable = 'timetable_cache_v1';
  static const String _keyLoginPayload = 'login_payload_v1';
  static const int _ttlSeconds = 3 * 24 * 60 * 60; // 3 days

  static Future<void> saveTimetable(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'data': data,
    };
    await prefs.setString(_keyTimetable, jsonEncode(payload));
  }

  static Future<Map<String, dynamic>?> loadTimetable() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyTimetable);
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    final ts = decoded['timestamp'] as int? ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if ((now - ts) / 1000 > _ttlSeconds) {
      await prefs.remove(_keyTimetable);
      return null;
    }
    return Map<String, dynamic>.from(decoded['data'] ?? {});
  }

  static Future<void> saveLoginPayload(Map<String, String> payload) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLoginPayload, jsonEncode(payload));
  }

  static Future<Map<String, String>?> loadLoginPayload() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyLoginPayload);
    if (raw == null) return null;
    final data = Map<String, dynamic>.from(jsonDecode(raw));
    return data.map((k, v) => MapEntry(k, v?.toString() ?? ''));
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyTimetable);
    await prefs.remove(_keyLoginPayload);
  }
} 