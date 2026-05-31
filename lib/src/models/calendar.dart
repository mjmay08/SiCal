import 'event.dart';

class CalendarInfo {
  final String id;
  final String name;
  final String timezone;
  final String color;
  final bool isVisible;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  const CalendarInfo({
    required this.id,
    required this.name,
    required this.timezone,
    required this.color,
    required this.isVisible,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
  });

  factory CalendarInfo.defaultCalendar({
    String name = 'My Calendar',
    String timezone = 'UTC',
    String color = '#1ED660',
  }) {
    final now = DateTime.now().toUtc();
    return CalendarInfo(
      id: kDefaultCalendarId,
      name: name,
      timezone: timezone,
      color: color,
      isVisible: true,
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
    );
  }

  CalendarInfo copyWith({
    String? id,
    String? name,
    String? timezone,
    String? color,
    bool? isVisible,
    int? sortOrder,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return CalendarInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      timezone: timezone ?? this.timezone,
      color: color ?? this.color,
      isVisible: isVisible ?? this.isVisible,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
