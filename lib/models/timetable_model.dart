class TimetableWeek {
  final String weekId;
  final String weekName;
  final Map<String, List<Map<String, dynamic>>> courses;

  TimetableWeek({
    required this.weekId,
    required this.weekName,
    required this.courses,
  });

  factory TimetableWeek.fromJson(Map<String, dynamic> json) {
    final courses = <String, List<Map<String, dynamic>>>{};
    if (json['courses'] is Map<String, dynamic>) {
      (json['courses'] as Map<String, dynamic>).forEach((k, v) {
        courses[k] = List<Map<String, dynamic>>.from(v ?? []);
      });
    }
    return TimetableWeek(
      weekId: json['week_id']?.toString() ?? '',
      weekName: json['week_name'] ?? '',
      courses: courses,
    );
  }
}

class TimetableSemester {
  final String semId;
  final String semName;
  final List<TimetableWeek> weeks;

  TimetableSemester({
    required this.semId,
    required this.semName,
    required this.weeks,
  });

  factory TimetableSemester.fromJson(Map<String, dynamic> json) {
    return TimetableSemester(
      semId: json['sem_id']?.toString() ?? '',
      semName: json['sem_name'] ?? '',
      weeks: (json['weeks'] as List?)
              ?.map((e) => TimetableWeek.fromJson(e))
              .toList() ??
          [],
    );
  }
}

class SemesterMeta {
  final String semId;
  final String semName;

  SemesterMeta({required this.semId, required this.semName});

  factory SemesterMeta.fromJson(Map<String, dynamic> json) {
    return SemesterMeta(
      semId: json['sem_id']?.toString() ?? '',
      semName: json['sem_name'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'sem_id': semId,
        'sem_name': semName,
      };
}

class TimetableData {
  final List<TimetableSemester> semesters;
  final String defaultSemester;
  final String defaultWeek;
  final List<SemesterMeta> allSemestersMeta;

  TimetableData({
    required this.semesters,
    required this.defaultSemester,
    required this.defaultWeek,
    required this.allSemestersMeta,
  });

  factory TimetableData.fromJson(Map<String, dynamic> json) {
    return TimetableData(
      semesters: (json['semesters'] as List?)
              ?.map((e) => TimetableSemester.fromJson(e))
              .toList() ??
          [],
      defaultSemester: json['default_semester'] ?? '',
      defaultWeek: json['default_week'] ?? '',
      allSemestersMeta: (json['all_semesters_meta'] as List?)
              ?.map((e) => SemesterMeta.fromJson(e))
              .toList() ??
          [],
    );
  }
}