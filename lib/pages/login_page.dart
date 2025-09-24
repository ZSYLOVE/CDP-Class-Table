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
    } else if (resp['semesters'] != null || (resp['all_semesters_meta'] != null && resp['default_semester'] != null && resp['default_week'] != null)) {
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
    final screenHeight = MediaQuery.of(context).size.height;
    
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min, 
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.asset(
                  "assets/images/logo.png",
                  width: 32,
                  height: 32, 
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Text("课表登录"),
          ],
        ),
        centerTitle: true,
        backgroundColor: const Color.fromARGB(255, 235, 115, 107),
        elevation: 0,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.fromARGB(255, 248, 249, 250), 
              Color(0xFFE9ECEF), 
            ],
          ),
        ),
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: screenHeight - MediaQuery.of(context).padding.top - kToolbarHeight,
            ),
            child: IntrinsicHeight(
              child: Column(
                children: [
                  Container(
                    height: screenHeight * 0.20,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color.fromARGB(255, 235, 115, 107),
                          Color.fromARGB(255, 248, 249, 250),
                        ],
                      ),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(36),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.1),
                                  blurRadius: 10,
                                  offset: const Offset(0, 5),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(40),
                              child: Image.asset(
                                "assets/images/logo.png",
                                width: 72,
                                height: 72, 
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          const SizedBox(height: 1),
                          const Text(
                            "学生课表系统",
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const Text(
                            "Student Timetable System",
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              "用户登录",
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: Color.fromARGB(255, 235, 115, 107),
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              "请输入您的学号和密码",
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey,
                              ),
                            ),
                            const SizedBox(height: 15),
                            _buildInputField(
                              controller: _userController,
                              label: "学号",
                              icon: Icons.person,
                              enabled: !loading,
                            ),
                            const SizedBox(height: 15),
                            _buildInputField(
                              controller: _passController,
                              label: "密码",
                              icon: Icons.lock,
                              obscureText: true,
                              enabled: !loading,
                            ),
                            const SizedBox(height: 15),
                            if (isCaptchaReady) ...[
                              Row(
                                children: [
                                  Expanded(
                                    flex: 2,
                                    child: _buildInputField(
                                      controller: _captchaController,
                                      label: "验证码",
                                      icon: Icons.security,
                                      enabled: !loading,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    flex: 1,
                                    child: GestureDetector(
                                      onTap: loading ? null : _getCaptcha,
                                      child: Container(
                                        height: 56,
                                        decoration: BoxDecoration(
                                          border: Border.all(color: Colors.grey.shade300),
                                          borderRadius: BorderRadius.circular(12),
                                          color: Colors.grey.shade50,
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(12),
                                          child: Image.memory(
                                            base64Decode(captchaBase64!.split(",").last),
                                            fit: BoxFit.contain,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: loading ? null : _getCaptcha,
                                  child: const Text(
                                    "刷新验证码",
                                    style: TextStyle(
                                      color: Color.fromARGB(255, 235, 115, 107),
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            
                            if (errorMsg != null)
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                margin: const EdgeInsets.only(bottom: 16),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.red.shade200),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.error_outline, color: Colors.red.shade600, size: 20),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        errorMsg!,
                                        style: TextStyle(
                                          color: Colors.red.shade600,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: ElevatedButton(
                                onPressed: loading ? null : _login,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color.fromARGB(255, 235, 115, 107),
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: loading
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2, 
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Text(
                                        "登录",
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              "请使用您的学号和密码登录系统",
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

 Widget _buildInputField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscureText = false,
    bool enabled = true,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        enabled: enabled,
        style: const TextStyle(fontSize: 16),
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(
            icon,
            color: const Color.fromARGB(255, 235, 115, 107),
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(
              color: Color.fromARGB(255, 235, 115, 107),
              width: 2,
            ),
          ),
          filled: true,
          fillColor: enabled ? Colors.white : Colors.grey.shade100,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      ),
    );
  }
