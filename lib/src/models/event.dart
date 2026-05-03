import 'package:uuid/uuid.dart';

class CalendarEvent {
  final String id;
  final String title;
  final String description;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String? recurrenceRule;
  final List<int> reminderMinutes;
  final String location;
  final String period; // e.g. "2026-04"
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isDirty;

  // Recurrence exception fields — set when this event overrides a single
  // instance of a recurring master event.
  final String? masterEventId;
  final String? originalStart; // ISO-8601 of the instance being replaced
  final bool isCancelled; // true = "deleted this occurrence"

  /// Transient — set at query time for virtual recurring instances.
  /// Not persisted. Identifies which occurrence date this instance represents.
  final DateTime? instanceStart;

  CalendarEvent({
    String? id,
    required this.title,
    this.description = '',
    required this.start,
    required this.end,
    this.allDay = false,
    this.recurrenceRule,
    this.reminderMinutes = const [15],
    this.location = '',
    String? period,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.isDirty = true,
    this.masterEventId,
    this.originalStart,
    this.isCancelled = false,
    this.instanceStart,
  }) : id = id ?? const Uuid().v4(),
       period = period ?? _derivePeriod(start),
       createdAt = createdAt ?? DateTime.now().toUtc(),
       updatedAt = updatedAt ?? DateTime.now().toUtc();

  static String _derivePeriod(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}';
  }

  /// Whether this is a recurring master event.
  bool get isRecurring => recurrenceRule != null && masterEventId == null;

  /// Whether this is an exception to a recurring series.
  bool get isException => masterEventId != null;

  /// Whether this is a virtual (non-persisted) instance of a recurring event.
  bool get isVirtualInstance => instanceStart != null;

  CalendarEvent copyWith({
    String? id,
    String? title,
    String? description,
    DateTime? start,
    DateTime? end,
    bool? allDay,
    Object? recurrenceRule = _sentinel,
    List<int>? reminderMinutes,
    String? location,
    bool? isDirty,
    DateTime? updatedAt,
    Object? masterEventId = _sentinel,
    Object? originalStart = _sentinel,
    bool? isCancelled,
    Object? instanceStart = _sentinel,
  }) {
    final newStart = start ?? this.start;
    return CalendarEvent(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      start: newStart,
      end: end ?? this.end,
      allDay: allDay ?? this.allDay,
      recurrenceRule: recurrenceRule == _sentinel
          ? this.recurrenceRule
          : recurrenceRule as String?,
      reminderMinutes: reminderMinutes ?? this.reminderMinutes,
      location: location ?? this.location,
      period: _derivePeriod(newStart),
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now().toUtc(),
      isDirty: isDirty ?? this.isDirty,
      masterEventId: masterEventId == _sentinel
          ? this.masterEventId
          : masterEventId as String?,
      originalStart: originalStart == _sentinel
          ? this.originalStart
          : originalStart as String?,
      isCancelled: isCancelled ?? this.isCancelled,
      instanceStart: instanceStart == _sentinel
          ? this.instanceStart
          : instanceStart as DateTime?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'start': start.toIso8601String(),
    'end': end.toIso8601String(),
    'all_day': allDay,
    'recurrence_rule': recurrenceRule,
    'reminder_minutes': reminderMinutes,
    'location': location,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'master_event_id': masterEventId,
    'original_start': originalStart,
    'is_cancelled': isCancelled,
  };

  factory CalendarEvent.fromJson(Map<String, dynamic> json) => CalendarEvent(
    id: json['id'] as String,
    title: json['title'] as String,
    description: json['description'] as String? ?? '',
    start: DateTime.parse(json['start'] as String),
    end: DateTime.parse(json['end'] as String),
    allDay: json['all_day'] as bool? ?? false,
    recurrenceRule: json['recurrence_rule'] as String?,
    reminderMinutes:
        (json['reminder_minutes'] as List<dynamic>?)
            ?.map((e) => e as int)
            .toList() ??
        const [15],
    location: json['location'] as String? ?? '',
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
    isDirty: false,
    masterEventId: json['master_event_id'] as String?,
    originalStart: json['original_start'] as String?,
    isCancelled: json['is_cancelled'] as bool? ?? false,
  );
}

const _sentinel = Object();
