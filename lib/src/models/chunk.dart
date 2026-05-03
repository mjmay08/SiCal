import 'dart:convert';
import 'event.dart';

class Chunk {
  final String period; // e.g. "2026-04"
  final List<CalendarEvent> events;

  const Chunk({required this.period, required this.events});

  Map<String, dynamic> toJson() => {
    'period': period,
    'events': events.map((e) => e.toJson()).toList(),
  };

  factory Chunk.fromJson(Map<String, dynamic> json) => Chunk(
    period: json['period'] as String,
    events: (json['events'] as List<dynamic>)
        .map((e) => CalendarEvent.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  String encode() => jsonEncode(toJson());

  factory Chunk.decode(String data) =>
      Chunk.fromJson(jsonDecode(data) as Map<String, dynamic>);
}
