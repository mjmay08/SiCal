import 'dart:convert';

class Manifest {
  final String calendarName;
  final String timezone;
  final String color;
  final Map<String, String> chunks; // period -> object_id
  final DateTime updatedAt;

  const Manifest({
    required this.calendarName,
    required this.timezone,
    required this.color,
    required this.chunks,
    required this.updatedAt,
  });

  Manifest copyWith({
    String? calendarName,
    String? timezone,
    String? color,
    Map<String, String>? chunks,
    DateTime? updatedAt,
  }) => Manifest(
    calendarName: calendarName ?? this.calendarName,
    timezone: timezone ?? this.timezone,
    color: color ?? this.color,
    chunks: chunks ?? Map.of(this.chunks),
    updatedAt: updatedAt ?? DateTime.now().toUtc(),
  );

  Map<String, dynamic> toJson() => {
    'calendar_name': calendarName,
    'timezone': timezone,
    'color': color,
    'chunks': chunks,
    'updated_at': updatedAt.toIso8601String(),
  };

  factory Manifest.fromJson(Map<String, dynamic> json) => Manifest(
    calendarName: json['calendar_name'] as String,
    timezone: json['timezone'] as String,
    color: json['color'] as String,
    chunks: Map<String, String>.from(json['chunks'] as Map),
    updatedAt: DateTime.parse(json['updated_at'] as String),
  );

  String encode() => jsonEncode(toJson());

  factory Manifest.decode(String data) =>
      Manifest.fromJson(jsonDecode(data) as Map<String, dynamic>);

  factory Manifest.empty() => Manifest(
    calendarName: 'My Calendar',
    timezone: 'UTC',
    color: '#1ED660',
    chunks: {},
    updatedAt: DateTime.now().toUtc(),
  );
}
