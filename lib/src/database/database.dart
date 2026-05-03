import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import '../models/event.dart';

class AppDatabase {
  late final Database _db;

  AppDatabase._();

  static AppDatabase? _instance;
  static Future<AppDatabase> getInstance() async {
    if (_instance != null) return _instance!;
    _instance = AppDatabase._();
    await _instance!._open();
    return _instance!;
  }

  Future<void> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'sia_calendar.db');
    _db = sqlite3.open(dbPath);
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('PRAGMA foreign_keys=ON');
    _createTables();
  }

  void _createTables() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS events (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        start TEXT NOT NULL,
        end TEXT NOT NULL,
        all_day INTEGER NOT NULL DEFAULT 0,
        recurrence_rule TEXT,
        reminders_json TEXT NOT NULL DEFAULT '[15]',
        location TEXT NOT NULL DEFAULT '',
        period TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        is_dirty INTEGER NOT NULL DEFAULT 1
      )
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS chunks (
        period TEXT PRIMARY KEY,
        object_id TEXT NOT NULL,
        version INTEGER NOT NULL DEFAULT 0,
        last_synced_at TEXT NOT NULL
      )
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS manifest (
        id INTEGER PRIMARY KEY DEFAULT 1,
        object_id TEXT,
        version INTEGER NOT NULL DEFAULT 0,
        calendar_name TEXT NOT NULL DEFAULT 'My Calendar',
        timezone TEXT NOT NULL DEFAULT 'UTC',
        color TEXT NOT NULL DEFAULT '#1ED660'
      )
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        id INTEGER PRIMARY KEY DEFAULT 1,
        cursor TEXT NOT NULL DEFAULT '',
        cursor_id TEXT NOT NULL DEFAULT '',
        last_sync_at TEXT
      )
    ''');
    // Migration: add cursor_id if missing (table created before it existed).
    final cols = _db.select("PRAGMA table_info('sync_state')");
    if (!cols.any((r) => r['name'] == 'cursor_id')) {
      _db.execute(
        "ALTER TABLE sync_state ADD COLUMN cursor_id TEXT NOT NULL DEFAULT ''",
      );
    }
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_events_period ON events(period)',
    );
    _db.execute('CREATE INDEX IF NOT EXISTS idx_events_start ON events(start)');

    // Migration: add recurrence exception columns if missing.
    final eventCols = _db.select("PRAGMA table_info('events')");
    if (!eventCols.any((r) => r['name'] == 'master_event_id')) {
      _db.execute('ALTER TABLE events ADD COLUMN master_event_id TEXT');
    }
    if (!eventCols.any((r) => r['name'] == 'original_start')) {
      _db.execute('ALTER TABLE events ADD COLUMN original_start TEXT');
    }
    if (!eventCols.any((r) => r['name'] == 'is_cancelled')) {
      _db.execute(
        'ALTER TABLE events ADD COLUMN is_cancelled INTEGER NOT NULL DEFAULT 0',
      );
    }
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_events_master ON events(master_event_id)',
    );
  }

  /// Delete all local data — events, chunks, manifest, and sync state.
  void clearAllTables() {
    _db.execute('DELETE FROM events');
    _db.execute('DELETE FROM chunks');
    _db.execute('DELETE FROM manifest');
    _db.execute('DELETE FROM sync_state');
  }

  // -----------------------------------------------------------------------
  // Events
  // -----------------------------------------------------------------------

  List<CalendarEvent> getEventsForPeriod(String period) {
    final result = _db.select('SELECT * FROM events WHERE period = ?', [
      period,
    ]);
    return result.map(_rowToEvent).toList();
  }

  CalendarEvent? getEventById(String id) {
    final result = _db.select('SELECT * FROM events WHERE id = ?', [id]);
    return result.isEmpty ? null : _rowToEvent(result.first);
  }

  List<CalendarEvent> getEventsInRange(DateTime from, DateTime to) {
    final result = _db.select(
      'SELECT * FROM events WHERE start >= ? AND start < ? ORDER BY start',
      [from.toIso8601String(), to.toIso8601String()],
    );
    return result.map(_rowToEvent).toList();
  }

  List<CalendarEvent> getDirtyEvents() {
    final result = _db.select('SELECT * FROM events WHERE is_dirty = 1');
    return result.map(_rowToEvent).toList();
  }

  List<String> getDirtyPeriods() {
    final result = _db.select(
      'SELECT DISTINCT period FROM events WHERE is_dirty = 1',
    );
    return result.map((r) => r['period'] as String).toList();
  }

  void upsertEvent(CalendarEvent event) {
    _db.execute(
      '''
      INSERT OR REPLACE INTO events
        (id, title, description, start, end, all_day, recurrence_rule,
         reminders_json, location, period, created_at, updated_at, is_dirty,
         master_event_id, original_start, is_cancelled)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
      [
        event.id,
        event.title,
        event.description,
        event.start.toIso8601String(),
        event.end.toIso8601String(),
        event.allDay ? 1 : 0,
        event.recurrenceRule,
        jsonEncode(event.reminderMinutes),
        event.location,
        event.period,
        event.createdAt.toIso8601String(),
        event.updatedAt.toIso8601String(),
        event.isDirty ? 1 : 0,
        event.masterEventId,
        event.originalStart,
        event.isCancelled ? 1 : 0,
      ],
    );
  }

  void markEventsClean(String period) {
    _db.execute('UPDATE events SET is_dirty = 0 WHERE period = ?', [period]);
  }

  void deleteEvent(String id) {
    // Also delete any exceptions that reference this master.
    _db.execute('DELETE FROM events WHERE master_event_id = ?', [id]);
    _db.execute('DELETE FROM events WHERE id = ?', [id]);
  }

  /// Get all recurring master events whose series could produce instances
  /// within [from]..[to]. A master qualifies if its start <= [to] (the series
  /// may extend forward) and it has a recurrence rule.
  List<CalendarEvent> getRecurringMastersInRange(DateTime from, DateTime to) {
    final result = _db.select(
      '''SELECT * FROM events
         WHERE recurrence_rule IS NOT NULL
           AND master_event_id IS NULL
           AND start <= ?
         ORDER BY start''',
      [to.toIso8601String()],
    );
    return result.map(_rowToEvent).toList();
  }

  /// Get all exception events for a given master event.
  List<CalendarEvent> getExceptionsForMaster(String masterEventId) {
    final result = _db.select(
      'SELECT * FROM events WHERE master_event_id = ?',
      [masterEventId],
    );
    return result.map(_rowToEvent).toList();
  }

  /// Get non-recurring, non-exception events in a date range.
  List<CalendarEvent> getNonRecurringEventsInRange(DateTime from, DateTime to) {
    final result = _db.select(
      '''SELECT * FROM events
         WHERE start >= ? AND start < ?
           AND (recurrence_rule IS NULL OR recurrence_rule = '')
           AND master_event_id IS NULL
         ORDER BY start''',
      [from.toIso8601String(), to.toIso8601String()],
    );
    return result.map(_rowToEvent).toList();
  }

  List<CalendarEvent> getAllEventsForPeriod(String period) =>
      getEventsForPeriod(period);

  // -----------------------------------------------------------------------
  // Chunks
  // -----------------------------------------------------------------------

  Map<String, dynamic>? getChunk(String period) {
    final result = _db.select('SELECT * FROM chunks WHERE period = ?', [
      period,
    ]);
    return result.isEmpty ? null : result.first;
  }

  void upsertChunk(String period, String objectId, int version) {
    _db.execute(
      '''
      INSERT OR REPLACE INTO chunks (period, object_id, version, last_synced_at)
      VALUES (?, ?, ?, ?)
    ''',
      [period, objectId, version, DateTime.now().toUtc().toIso8601String()],
    );
  }

  void deleteChunk(String period) {
    _db.execute('DELETE FROM chunks WHERE period = ?', [period]);
  }

  List<String> getAllChunkPeriods() {
    final result = _db.select('SELECT period FROM chunks');
    return result.map((r) => r['period'] as String).toList();
  }

  // -----------------------------------------------------------------------
  // Manifest
  // -----------------------------------------------------------------------

  ManifestRow? getManifest() {
    final result = _db.select('SELECT * FROM manifest WHERE id = 1');
    if (result.isEmpty) return null;
    final r = result.first;
    final oid = r['object_id'] as String?;
    return ManifestRow(
      objectId: (oid != null && oid.isNotEmpty) ? oid : null,
      version: r['version'] as int,
      calendarName: r['calendar_name'] as String,
      timezone: r['timezone'] as String,
      color: r['color'] as String,
    );
  }

  void upsertManifest({
    String? objectId,
    int? version,
    String? calendarName,
    String? timezone,
    String? color,
  }) {
    final existing = getManifest();
    if (existing == null) {
      _db.execute(
        '''
        INSERT INTO manifest (id, object_id, version, calendar_name, timezone, color)
        VALUES (1, ?, ?, ?, ?, ?)
      ''',
        [
          objectId,
          version ?? 0,
          calendarName ?? 'My Calendar',
          timezone ?? 'UTC',
          color ?? '#1ED660',
        ],
      );
    } else {
      final sets = <String>[];
      final params = <Object?>[];
      if (objectId != null) {
        sets.add('object_id = ?');
        params.add(objectId);
      }
      if (version != null) {
        sets.add('version = ?');
        params.add(version);
      }
      if (calendarName != null) {
        sets.add('calendar_name = ?');
        params.add(calendarName);
      }
      if (timezone != null) {
        sets.add('timezone = ?');
        params.add(timezone);
      }
      if (color != null) {
        sets.add('color = ?');
        params.add(color);
      }
      if (sets.isNotEmpty) {
        _db.execute(
          'UPDATE manifest SET ${sets.join(', ')} WHERE id = 1',
          params,
        );
      }
    }
  }

  // -----------------------------------------------------------------------
  // Sync State
  // -----------------------------------------------------------------------

  SyncStateRow? getSyncState() {
    final result = _db.select('SELECT * FROM sync_state WHERE id = 1');
    if (result.isEmpty) return null;
    final r = result.first;
    return SyncStateRow(
      cursor: r['cursor'] as String,
      cursorId: r['cursor_id'] as String? ?? '',
      lastSyncAt: r['last_sync_at'] != null
          ? DateTime.parse(r['last_sync_at'] as String)
          : null,
    );
  }

  void updateSyncCursor(String cursor, String cursorId) {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.execute(
      '''
      INSERT OR REPLACE INTO sync_state (id, cursor, cursor_id, last_sync_at)
      VALUES (1, ?, ?, ?)
    ''',
      [cursor, cursorId, now],
    );
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  CalendarEvent _rowToEvent(Row r) => CalendarEvent(
    id: r['id'] as String,
    title: r['title'] as String,
    description: r['description'] as String? ?? '',
    start: DateTime.parse(r['start'] as String),
    end: DateTime.parse(r['end'] as String),
    allDay: (r['all_day'] as int) == 1,
    recurrenceRule: r['recurrence_rule'] as String?,
    reminderMinutes: _parseReminders(r['reminders_json'] as String),
    location: r['location'] as String? ?? '',
    period: r['period'] as String,
    createdAt: DateTime.parse(r['created_at'] as String),
    updatedAt: DateTime.parse(r['updated_at'] as String),
    isDirty: (r['is_dirty'] as int) == 1,
    masterEventId: r['master_event_id'] as String?,
    originalStart: r['original_start'] as String?,
    isCancelled: (r['is_cancelled'] as int?) == 1,
  );

  List<int> _parseReminders(String json) {
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => e as int).toList();
  }

  void close() => _db.dispose();
}

class ManifestRow {
  final String? objectId;
  final int version;
  final String calendarName;
  final String timezone;
  final String color;
  const ManifestRow({
    this.objectId,
    required this.version,
    required this.calendarName,
    required this.timezone,
    required this.color,
  });
}

class SyncStateRow {
  final String cursor;
  final String cursorId;
  final DateTime? lastSyncAt;
  const SyncStateRow({
    required this.cursor,
    required this.cursorId,
    this.lastSyncAt,
  });
}
