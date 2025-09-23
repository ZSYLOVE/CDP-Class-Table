import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:studentclass/pages/timetable_page.dart';
import '../services/api_service.dart';
import '../services/cache_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _captchaController = TextEditingController();

  String? sessionId;
  String? captchaBase64;
  bool loading = false;
  String? errorMsg;

  @override
  void initState() {
    super.initState();
    _tryLoadCacheThenCaptcha();
  }

  Future<void> _tryLoadCacheThenCaptcha() async {
    setState(() {
      loading = true;
      errorMsg = null;
    });
    try {
      final cached = await CacheService.loadTimetable();
      if (cached != null && mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => TimetablePage(timetableJson: cached),
          ),
        );
        return;
      }
    } catch (_) {}
    finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
    await _getCaptcha();
  }

  Future<void> _getCaptcha() async {
    setState(() {
      loading = true;
      errorMsg = null;
      captchaBase64 = null;
      sessionId = null;
      _captchaController.clear();
    });
    try {
      final data = await ApiService.fetchCaptcha();
      setState(() {
        sessionId = data['session_id'];
        captchaBase64 = data['captcha_base64'];
      });
    } catch (e) {
      setState(() {
        errorMsg = '获取验证码失败: $e';
      });
    } finally {
      setState(() {
        loading = false;
      });
    }
  }

  Future<void> _login() async {
  if (_userController.text.trim().isEmpty || _passController.text.isEmpty) {
    setState(() {
      errorMsg = '学号和密码不能为空';
    });
    return;
  }
  if (_captchaController.text.isEmpty) {
    setState(() {
      errorMsg = '验证码不能为空';
    });
    return;
  }
  setState(() {
    loading = true;
    errorMsg = null;
  });
  try {
    final resp = await ApiService.fetchTimetable(
      sessionId: sessionId!,
      username: _userController.text,
      password: _passController.text,
      captcha: _captchaController.text,
    );
    print(resp);
    if (resp['need_manual_captcha'] == true) {
      setState(() {
        captchaBase64 = resp['captcha_base64'];
        errorMsg = resp['message'] ?? '验证码错误，请重新输入';
        loading = false;
      });
      return;
    } else if (resp['semesters'] != null) {
      // 保存缓存与登录载荷（用于懒加载其它学期）
      await CacheService.saveTimetable(resp);
      await CacheService.saveLoginPayload({
        'username': _userController.text,
        'password': _passController.text,
        'captcha': _captchaController.text,
        'session_id': sessionId ?? '',
      });
      setState(() {
        loading = false;
      });
      if (context.mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => TimetablePage(timetableJson: resp),
          ),
        );
      }
    } else {
      setState(() {
        errorMsg = resp['detail'] ?? '登录失败，未知错误';
        loading = false;
      });
    }
  } catch (e) {
    setState(() {
      errorMsg = '登录失败: $e';
      loading = false;
    });
  }
}

  @override
  Widget build(BuildContext context) {
    final isCaptchaReady = captchaBase64 != null;
    return Scaffold(
      appBar: AppBar(title: const Text('课表登录')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            TextField(
              controller: _userController,
              decoration: const InputDecoration(labelText: '学号'),
              enabled: !loading,
            ),
            TextField(
              controller: _passController,
              decoration: const InputDecoration(labelText: '密码'),
              obscureText: true,
              enabled: !loading,
            ),
            if (isCaptchaReady)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: loading ? null : _getCaptcha,
                      child: Image.memory(
                        base64Decode(captchaBase64!.split(',').last),
                        width: 120,
                        height: 40,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _captchaController,
                        decoration: const InputDecoration(labelText: '请输入验证码'),
                        enabled: !loading,
                      ),
                    ),
                  ],
                ),
              ),
            if (errorMsg != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  errorMsg!,
                  style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                ),
              ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: loading ? null : _login,
                child: loading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('登录'),
              ),
            ),
            TextButton(
              onPressed: loading ? null : _getCaptcha,
              child: const Text('刷新验证码'),
            ),
          ],
        ),
      ),
    );
  }
}