import 'package:http/http.dart' as http;
import 'dart:convert';

class ApiService {
  static const String baseUrl = 'http://z.zsyyyds.top';

  static Future<Map<String, dynamic>> fetchCaptcha() async {
    final response = await http.get(Uri.parse('$baseUrl/captcha'));
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('获取验证码失败');
    }
  }

  static Future<Map<String, dynamic>> fetchTimetable({
    required String sessionId,
    required String username,
    required String password,
    required String captcha,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/timetable'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'session_id': sessionId,
        'username': username,
        'password': password,
        'captcha': captcha,
      }),
    );
    return jsonDecode(response.body);
  }

  static Future<Map<String, dynamic>> fetchSemesterWeeks({
    String? username,
    String? password,
    String? captcha,
    String? sessionId,
    required String semId,
    int maxWeeks = 10,
  }) async {
    final body = {
      if (username != null) 'username': username,
      if (password != null) 'password': password,
      if (captcha != null) 'captcha': captcha,
      if (sessionId != null) 'session_id': sessionId,
      'sem_id': semId,
      'max_weeks': maxWeeks,
    };

    final response = await http.post(
      Uri.parse('$baseUrl/timetable/semester-weeks'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    final respBody = jsonDecode(response.body);
    if (response.statusCode >= 400) {
      throw Exception(respBody['detail'] ?? '获取学期课表失败');
    }
    return respBody;
  }
}