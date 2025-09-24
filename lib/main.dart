import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'pages/login_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '课表App',
      theme: ThemeData(
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: const OrientationWrapper(child: LoginPage()),
    );
  }
}

class OrientationWrapper extends StatefulWidget {
  final Widget child;
  
  const OrientationWrapper({super.key, required this.child});

  @override
  State<OrientationWrapper> createState() => _OrientationWrapperState();
}

class _OrientationWrapperState extends State<OrientationWrapper> {
  @override
  void initState() {
    super.initState();
    // 设置支持横屏和竖屏
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}