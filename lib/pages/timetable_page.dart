import 'package:flutter/material.dart';
import '../models/timetable_model.dart';
import '../services/api_service.dart';
import '../services/cache_service.dart';
import 'package:studentclass/pages/login_page.dart';

class TimetablePage extends StatefulWidget {
  final Map<String, dynamic> timetableJson;

  const TimetablePage({super.key, required this.timetableJson});

  @override
  State<TimetablePage> createState() => _TimetablePageState();
}

class _TimetablePageState extends State<TimetablePage> {
  late TimetableData timetableData;
  late TimetableSemester selectedSemester;
  late TimetableWeek selectedWeek;
  bool loadingWeeks = false;
  String? loadError;
  bool _preloading = false;

  @override
  void initState() {
    super.initState();
    timetableData = TimetableData.fromJson(widget.timetableJson);

    // 默认选中
    selectedSemester = timetableData.semesters.isNotEmpty
        ? timetableData.semesters.firstWhere(
            (s) => s.semName == timetableData.defaultSemester,
            orElse: () => timetableData.semesters.first,
          )
        : throw Exception('无可用学期');

    selectedWeek = selectedSemester.weeks.isNotEmpty
        ? selectedSemester.weeks.firstWhere(
            (w) => w.weekName == timetableData.defaultWeek,
            orElse: () => selectedSemester.weeks.first,
          )
        : TimetableWeek(weekName: '暂无周', courses: {}, weekId: '');

    // 首帧后后台静默预加载其它学期
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preloadOtherSemesters();
    });
  }

  Future<void> _relogin() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新登录'),
        content: const Text('将清空本地缓存并返回登录页获取最新课表，是否继续？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('继续')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await CacheService.clearAll();
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
    }
  }

  Future<void> _ensureSemesterWeeksLoaded(TimetableSemester sem) async {
    if (sem.weeks.isNotEmpty) return;
    setState(() {
      loadingWeeks = true;
      loadError = null;
    });
    try {
      final login = await CacheService.loadLoginPayload();
      if (login == null) {
        throw Exception('缓存登录信息缺失，请重新登录');
      }
      final resp = await ApiService.fetchSemesterWeeks(
        username: login['username']?.isNotEmpty == true ? login['username'] : null,
        password: login['password']?.isNotEmpty == true ? login['password'] : null,
        captcha: login['captcha']?.isNotEmpty == true ? login['captcha'] : null,
        sessionId: login['session_id']?.isNotEmpty == true ? login['session_id'] : null,
        semId: sem.semId,
        maxWeeks: 10,
      );
      // 合并返回到当前数据结构
      await _mergeWeeksIntoState(sem.semId, resp['weeks'] as List? ?? []);
    } catch (e) {
      setState(() {
        loadError = '加载失败: $e';
      });
    } finally {
      setState(() {
        loadingWeeks = false;
      });
    }
  }

  Future<void> _mergeWeeksIntoState(String semId, List weeksJson) async {
    final fetchedWeeks = weeksJson.map((e) => TimetableWeek.fromJson(e)).toList();

    // 构造新的 semesters 列表：存在则替换，不存在则追加
    final existingIndex = timetableData.semesters.indexWhere((s) => s.semId == semId);
    final List<TimetableSemester> newSemesters = [...timetableData.semesters];

    String resolvedSemName;
    if (existingIndex >= 0) {
      resolvedSemName = newSemesters[existingIndex].semName;
      newSemesters[existingIndex] = TimetableSemester(
        semId: semId,
        semName: resolvedSemName,
        weeks: fetchedWeeks,
      );
    } else {
      // 从 allSemestersMeta 中找学期名，找不到则用 semId 兜底
      final meta = timetableData.allSemestersMeta.firstWhere(
        (m) => m.semId == semId,
        orElse: () => SemesterMeta(semId: semId, semName: semId),
      );
      resolvedSemName = meta.semName;
      newSemesters.add(TimetableSemester(
        semId: semId,
        semName: resolvedSemName,
        weeks: fetchedWeeks,
      ));
    }

    final merged = {
      ...widget.timetableJson,
      'semesters': newSemesters
          .map((s) => {
                'sem_id': s.semId,
                'sem_name': s.semName,
                'weeks': s.weeks
                    .map((w) => {
                          'week_id': w.weekId,
                          'week_name': w.weekName,
                          'courses': w.courses,
                        })
                    .toList(),
              })
          .toList(),
      'all_semesters_meta': timetableData.allSemestersMeta
          .map((m) => {'sem_id': m.semId, 'sem_name': m.semName}).toList(),
      'default_semester': timetableData.defaultSemester,
      'default_week': timetableData.defaultWeek,
    };
    await CacheService.saveTimetable(merged);
    setState(() {
      timetableData = TimetableData.fromJson(merged);
      if (selectedSemester.semId == semId) {
        selectedSemester = timetableData.semesters.firstWhere((s) => s.semId == semId);
        selectedWeek = selectedSemester.weeks.isNotEmpty
            ? selectedSemester.weeks.first
            : TimetableWeek(weekName: '暂无周', courses: {}, weekId: '');
      }
    });
  }

  Future<void> _preloadOtherSemesters() async {
    if (_preloading) return;
    _preloading = true;
    try {
      final login = await CacheService.loadLoginPayload();
      if (login == null) return;
      final metas = timetableData.allSemestersMeta;
      final loadedById = {for (var s in timetableData.semesters) s.semId: s};
      for (final meta in metas) {
        final s = loadedById[meta.semId];
        final alreadyLoaded = s != null && s.weeks.isNotEmpty;
        if (alreadyLoaded) continue;
        try {
          final resp = await ApiService.fetchSemesterWeeks(
            username: login['username']?.isNotEmpty == true ? login['username'] : null,
            password: login['password']?.isNotEmpty == true ? login['password'] : null,
            captcha: login['captcha']?.isNotEmpty == true ? login['captcha'] : null,
            sessionId: login['session_id']?.isNotEmpty == true ? login['session_id'] : null,
            semId: meta.semId,
            maxWeeks: 10,
          );
          await _mergeWeeksIntoState(meta.semId, resp['weeks'] as List? ?? []);
        } catch (_) {
          // 静默失败，继续下一个
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
    } finally {
      _preloading = false;
    }
  }

  List<String> _collectPeriods(TimetableWeek week) {
    final set = <String>{};
    week.courses.forEach((day, list) {
      for (final c in list) {
        final p = (c['period'] ?? '').toString();
        if (p.isNotEmpty) set.add(p);
      }
    });
    final periods = set.toList();
    periods.sort((a, b) {
      final na = int.tryParse(RegExp(r'\d+').firstMatch(a)?.group(0) ?? '0') ?? 0;
      final nb = int.tryParse(RegExp(r'\d+').firstMatch(b)?.group(0) ?? '0') ?? 0;
      return na.compareTo(nb);
    });
    return periods;
  }

  Color _colorForCourse(String key) {
    final colors = [
      const Color(0xFF42A5F5), // blue
      const Color(0xFF66BB6A), // green
      const Color(0xFFEF5350), // red
      const Color(0xFFAB47BC), // purple
      const Color(0xFFFFA726), // orange
      const Color(0xFF26A69A), // teal
      const Color(0xFF5C6BC0), // indigo
    ];
    final idx = (key.hashCode & 0x7fffffff) % colors.length;
    return colors[idx];
  }

  Widget _buildCourseChip(Map<String, dynamic> c) {
    final content = (c['content'] ?? '').toString();
    String name = content;
    String teacher = '';
    String place = '';
    
    // 直接在字符串中查找"233-1班"或"233_1班"的位置
    String classMarker = '';
    if (content.contains('233-1班')) {
      classMarker = '233-1班';
    } else if (content.contains('233_1班')) {
      classMarker = '233_1班';
    }
    
    if (classMarker.isNotEmpty) {
      // 分割字符串
      List<String> segments = content.split(classMarker);
      if (segments.length >= 2) {
        // 课程名是"233-1班"之前的内容
        name = segments[0].trim();
        
        // 教师名和地点在"233-1班"之后
        String afterClass = segments[1].trim();
        
        // 查找"高新"的位置来分割教师名和地点
        if (afterClass.contains('高新')) {
          List<String> teacherPlace = afterClass.split('高新');
          if (teacherPlace.length >= 2) {
            teacher = teacherPlace[0].trim();
            place = '高新' + teacherPlace[1].trim();
          } else {
            teacher = afterClass;
          }
        } else {
          teacher = afterClass;
        }
      }
    }

    final color = _colorForCourse(name);

    return GestureDetector(
      onTap: () {
        showDialog(
          context: context,
          builder: (ctx) => Dialog(
            child: Container(
              padding: const EdgeInsets.all(16),
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.6,
                maxWidth: MediaQuery.of(context).size.width * 0.9,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('课程详情', style: TextStyle(color: color.darken(0.3), fontWeight: FontWeight.bold, fontSize: 20)),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('课程名:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87, fontSize: 16)),
                          const SizedBox(height: 4),
                          Text(name, style: TextStyle(fontSize: 16, color: Colors.black87)),
                        ],
                      ),
                    ),
                    if (teacher.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('教师:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87, fontSize: 16)),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(Icons.person, size: 18, color: Colors.black54),
                                const SizedBox(width: 4),
                                Text(teacher, style: TextStyle(fontSize: 16, color: Colors.black87)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    if (place.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('地点:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87, fontSize: 16)),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(Icons.location_on, size: 18, color: Colors.black54),
                                const SizedBox(width: 4),
                                Expanded(child: Text(place, style: TextStyle(fontSize: 16, color: Colors.black87))),
                              ],
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('关闭', style: TextStyle(fontSize: 16)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.4), width: 1),
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.2),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 5,
              height: 80,
              decoration: BoxDecoration(
                color: color,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12),
                  bottomLeft: Radius.circular(12),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: color.darken(0.3),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (teacher.isNotEmpty) const SizedBox(height: 4),
                    if (teacher.isNotEmpty)
                      Text(
                        teacher,
                        style: const TextStyle(fontSize: 12, color: Colors.black87),
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (place.isNotEmpty) const SizedBox(height: 2),
                    if (place.isNotEmpty)
                      Text(
                        place,
                        style: const TextStyle(fontSize: 11, color: Colors.black54),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget _buildTimetableTable() {
    if (selectedSemester.weeks.isEmpty) {
      return const Center(child: Text('本学期暂无课表'));
    }
    final days = selectedWeek.courses.keys.toList();
    if (days.isEmpty) {
      return const Center(child: Text('本周暂无课程'));
    }
    final periods = _collectPeriods(selectedWeek);

    final header = TableRow(
      decoration: const BoxDecoration(color: Color(0xFFF5F5F5)),
      children: [
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('节次', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        ...days.map((d) => Padding(
              padding: const EdgeInsets.all(8),
              child: Text(d, style: const TextStyle(fontWeight: FontWeight.bold)),
            )),
      ],
    );

    List<TableRow> rows = [header];

    for (final period in periods) {
      rows.add(
        TableRow(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(period, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            ...days.map((d) {
              final items = selectedWeek.courses[d]?.where((c) => (c['period'] ?? '') == period).toList() ?? [];
              return Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  border: Border(
                    left: BorderSide(color: Color(0xFFE0E0E0)),
                  ),
                ),
                child: items.isEmpty
                    ? const SizedBox.shrink()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: items.map((c) => _buildCourseChip(c)).toList(),
                      ),
              );
            }),
          ],
        ),
      );
    }

    return Card(
      elevation: 2,
      margin: const EdgeInsets.all(8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Table(
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              columnWidths: {
                0: const FixedColumnWidth(72),
                for (int i = 1; i <= days.length; i++) i: const FixedColumnWidth(120),
              },
              border: const TableBorder(
                top: BorderSide(color: Color(0xFFE0E0E0)),
                right: BorderSide(color: Color(0xFFE0E0E0)),
                left: BorderSide(color: Color(0xFFE0E0E0)),
                bottom: BorderSide(color: Color(0xFFE0E0E0)),
                horizontalInside: BorderSide(color: Color(0xFFE0E0E0)),
                verticalInside: BorderSide(color: Color(0xFFE0E0E0)),
              ),
              children: rows,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                  'assets/images/logo.png',
                  width: 32,
                  height: 32, 
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Text('课程表'),
          ],
        ),
        centerTitle: true,
        backgroundColor: const Color.fromARGB(255, 235, 115, 107),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _relogin(),
          ),
        ],
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 学期选择
            if (timetableData.semesters.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Center( // 添加Center包装整个下拉菜单
                  child: DropdownButton<String>(
                    alignment: Alignment.center, // 添加居中对齐
                    value: selectedSemester.semId.isNotEmpty ? selectedSemester.semId : null,
                    items: timetableData.semesters.take(6).map((s) { // 只显示前6个学期
                      return DropdownMenuItem(
                        value: s.semId,
                        child: Center( // 添加Center包装
                          child: Text(s.semName),
                        ),
                      );
                    }).toList(),
                    onChanged: (id) async {
                      if (id == null) return;
                      final s = timetableData.semesters.firstWhere((e) => e.semId == id);
                      await _ensureSemesterWeeksLoaded(s);
                      setState(() {
                        selectedSemester = s;
                        selectedWeek = s.weeks.isNotEmpty
                            ? s.weeks.first
                            : TimetableWeek(weekName: '暂无周', courses: {}, weekId: '');
                      });
                    },
                  ),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('暂无学期数据')),
              ),
            // 周次选择
            if (selectedSemester.weeks.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Center( // 添加Center包装整个下拉菜单
                  child: DropdownButton<String>(
                    alignment: Alignment.center, // 添加居中对齐
                    value: selectedWeek.weekId.isNotEmpty ? selectedWeek.weekId : null,
                    items: selectedSemester.weeks.map((w) {
                      return DropdownMenuItem(
                        value: w.weekId,
                        child: Center( // 添加Center包装
                          child: Text(w.weekName),
                        ),
                      );
                    }).toList(),
                    onChanged: (wid) {
                      if (wid != null) {
                        final w = selectedSemester.weeks.firstWhere((e) => e.weekId == wid, orElse: () => selectedSemester.weeks.first);
                        setState(() {
                          selectedWeek = w;
                        });
                      }
                    },
                  ),
                ),
              ),
            // 加载状态
            if (loadingWeeks)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (loadError != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('加载错误: $loadError', style: const TextStyle(color: Colors.red)),
              ),
            // 课表内容
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(20),
                    topRight: Radius.circular(20),
                  ),
                ),
                child: _buildTimetableTable(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension _ColorShade on Color {
  Color darken([double amount = .2]) {
    assert(amount >= 0 && amount <= 1);
    final hsl = HSLColor.fromColor(this);
    final hslDark = hsl.withLightness((hsl.lightness - amount).clamp(0.0, 1.0));
    return hslDark.toColor();
  }
}