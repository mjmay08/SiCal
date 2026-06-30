import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import '../models/calendar.dart';
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
      CREATE TABLE IF NOT EXISTS calendars (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        timezone TEXT NOT NULL DEFAULT 'UTC',
        color TEXT NOT NULL DEFAULT '#1ED660',
        is_visible INTEGER NOT NULL DEFAULT 1,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        app_key_hex TEXT
      )
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS events (
        id TEXT PRIMARY KEY,
        calendar_id TEXT NOT NULL DEFAULT 'default',
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
        period TEXT NOT NULL,
        calendar_id TEXT NOT NULL DEFAULT 'default',
        object_id TEXT NOT NULL,
        version INTEGER NOT NULL DEFAULT 0,
        last_synced_at TEXT NOT NULL,
        PRIMARY KEY (period, calendar_id)
      )
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS manifest (
        calendar_id TEXT PRIMARY KEY,
        object_id TEXT,
        version INTEGER NOT NULL DEFAULT 0,
        calendar_name TEXT NOT NULL DEFAULT 'My Calendar',
        timezone TEXT NOT NULL DEFAULT 'UTC',
        color TEXT NOT NULL DEFAULT '#1ED660'
      )
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        calendar_id TEXT PRIMARY KEY,
        cursor TEXT NOT NULL DEFAULT '',
        cursor_id TEXT NOT NULL DEFAULT '',
        last_sync_at TEXT
      )
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    // Migration: add cursor_id if missing (table created before it existed).
    final cols = _db.select("PRAGMA table_info('sync_state')");
    if (!cols.any((r) => r['name'] == 'cursor_id')) {
      _db.execute(
        "ALTER TABLE sync_state ADD COLUMN cursor_id TEXT NOT NULL DEFAULT ''",
      );
    }
    if (!cols.any((r) => r['name'] == 'calendar_id')) {
      _db.execute(
        "ALTER TABLE sync_state ADD COLUMN calendar_id TEXT NOT NULL DEFAULT 'default'",
      );
    }
    _migrateSyncStateToCalendarPrimaryKey();
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
    if (!eventCols.any((r) => r['name'] == 'timezone')) {
      _db.execute('ALTER TABLE events ADD COLUMN timezone TEXT');
    }
    if (!eventCols.any((r) => r['name'] == 'is_deleted')) {
      _db.execute(
        'ALTER TABLE events ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!eventCols.any((r) => r['name'] == 'calendar_id')) {
      _db.execute(
        "ALTER TABLE events ADD COLUMN calendar_id TEXT NOT NULL DEFAULT 'default'",
      );
    }

    final chunkCols = _db.select("PRAGMA table_info('chunks')");
    if (!chunkCols.any((r) => r['name'] == 'calendar_id')) {
      _db.execute(
        "ALTER TABLE chunks ADD COLUMN calendar_id TEXT NOT NULL DEFAULT 'default'",
      );
    }
    _migrateChunksToCompositePrimaryKey();

    final manifestCols = _db.select("PRAGMA table_info('manifest')");
    if (!manifestCols.any((r) => r['name'] == 'calendar_id')) {
      _db.execute(
        "ALTER TABLE manifest ADD COLUMN calendar_id TEXT NOT NULL DEFAULT 'default'",
      );
    }
    _migrateManifestToCalendarPrimaryKey();

    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_events_master ON events(master_event_id)',
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_events_calendar_id ON events(calendar_id)',
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_events_calendar_period ON events(calendar_id, period)',
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_calendars_visible ON calendars(is_visible, sort_order)',
    );

    _seedDefaultCalendarFromManifest();
    _backfillLegacyRowsToDefaultCalendar();
  }

  void _seedDefaultCalendarFromManifest() {
    final existing = _db.select('SELECT id FROM calendars LIMIT 1');
    if (existing.isNotEmpty) return;

    var legacyManifest = _db.select(
      'SELECT * FROM manifest WHERE calendar_id = ?',
      [kDefaultCalendarId],
    );
    if (legacyManifest.isEmpty) {
      legacyManifest = _db.select('SELECT * FROM manifest LIMIT 1');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final name = legacyManifest.isNotEmpty
        ? (legacyManifest.first['calendar_name'] as String? ?? 'My Calendar')
        : 'My Calendar';
    final timezone = legacyManifest.isNotEmpty
        ? (legacyManifest.first['timezone'] as String? ?? 'UTC')
        : 'UTC';
    final color = legacyManifest.isNotEmpty
        ? (legacyManifest.first['color'] as String? ?? '#1ED660')
        : '#1ED660';

    _db.execute(
      '''
      INSERT OR REPLACE INTO calendars
      (id, name, timezone, color, is_visible, sort_order, created_at, updated_at)
      VALUES (?, ?, ?, ?, 1, 0, ?, ?)
      ''',
      [kDefaultCalendarId, name, timezone, color, now, now],
    );
  }

  void _backfillLegacyRowsToDefaultCalendar() {
    _db.execute(
      "UPDATE events SET calendar_id = ? WHERE calendar_id IS NULL OR calendar_id = ''",
      [kDefaultCalendarId],
    );
    _db.execute(
      "UPDATE chunks SET calendar_id = ? WHERE calendar_id IS NULL OR calendar_id = ''",
      [kDefaultCalendarId],
    );
    _db.execute(
      "UPDATE sync_state SET calendar_id = ? WHERE calendar_id IS NULL OR calendar_id = ''",
      [kDefaultCalendarId],
    );
    _db.execute(
      "UPDATE manifest SET calendar_id = ? WHERE calendar_id IS NULL OR calendar_id = ''",
      [kDefaultCalendarId],
    );
  }

  void _migrateManifestToCalendarPrimaryKey() {
    final manifestCols = _db.select("PRAGMA table_info('manifest')");
    final calendarPk = manifestCols
        .where((r) => r['name'] == 'calendar_id')
        .map((r) => (r['pk'] as int?) ?? 0)
        .fold<int>(0, (a, b) => a + b);
    if (calendarPk > 0) return;

    _db.execute('BEGIN');
    try {
      _db.execute('''
        CREATE TABLE manifest_new (
          calendar_id TEXT PRIMARY KEY,
          object_id TEXT,
          version INTEGER NOT NULL DEFAULT 0,
          calendar_name TEXT NOT NULL DEFAULT 'My Calendar',
          timezone TEXT NOT NULL DEFAULT 'UTC',
          color TEXT NOT NULL DEFAULT '#1ED660'
        )
      ''');
      _db.execute('''
        INSERT OR REPLACE INTO manifest_new
        (calendar_id, object_id, version, calendar_name, timezone, color)
        SELECT
          CASE
            WHEN calendar_id IS NULL OR calendar_id = '' THEN 'default'
            ELSE calendar_id
          END,
          object_id,
          version,
          calendar_name,
          timezone,
          color
        FROM manifest
      ''');
      _db.execute('DROP TABLE manifest');
      _db.execute('ALTER TABLE manifest_new RENAME TO manifest');
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _migrateSyncStateToCalendarPrimaryKey() {
    final cols = _db.select("PRAGMA table_info('sync_state')");
    final calendarPk = cols
        .where((r) => r['name'] == 'calendar_id')
        .map((r) => (r['pk'] as int?) ?? 0)
        .fold<int>(0, (a, b) => a + b);
    if (calendarPk > 0) return;

    _db.execute('BEGIN');
    try {
      _db.execute('''
        CREATE TABLE sync_state_new (
          calendar_id TEXT PRIMARY KEY,
          cursor TEXT NOT NULL DEFAULT '',
          cursor_id TEXT NOT NULL DEFAULT '',
          last_sync_at TEXT
        )
      ''');
      _db.execute('''
        INSERT OR REPLACE INTO sync_state_new
        (calendar_id, cursor, cursor_id, last_sync_at)
        SELECT
          CASE
            WHEN calendar_id IS NULL OR calendar_id = '' THEN 'default'
            ELSE calendar_id
          END,
          cursor,
          cursor_id,
          last_sync_at
        FROM sync_state
      ''');
      _db.execute('DROP TABLE sync_state');
      _db.execute('ALTER TABLE sync_state_new RENAME TO sync_state');
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _migrateChunksToCompositePrimaryKey() {
    final cols = _db.select("PRAGMA table_info('chunks')");
    final periodPk = cols
        .where((r) => r['name'] == 'period')
        .map((r) => (r['pk'] as int?) ?? 0)
        .fold<int>(0, (a, b) => a + b);
    final calendarPk = cols
        .where((r) => r['name'] == 'calendar_id')
        .map((r) => (r['pk'] as int?) ?? 0)
        .fold<int>(0, (a, b) => a + b);
    if (periodPk > 0 && calendarPk > 0) return;

    _db.execute('BEGIN');
    try {
      _db.execute('''
        CREATE TABLE chunks_new (
          period TEXT NOT NULL,
          calendar_id TEXT NOT NULL DEFAULT 'default',
          object_id TEXT NOT NULL,
          version INTEGER NOT NULL DEFAULT 0,
          last_synced_at TEXT NOT NULL,
          PRIMARY KEY (period, calendar_id)
        )
      ''');
      _db.execute('''
        INSERT OR REPLACE INTO chunks_new
        (period, calendar_id, object_id, version, last_synced_at)
        SELECT
          period,
          CASE
            WHEN calendar_id IS NULL OR calendar_id = '' THEN 'default'
            ELSE calendar_id
          END,
          object_id,
          version,
          last_synced_at
        FROM chunks
      ''');
      _db.execute('DROP TABLE chunks');
      _db.execute('ALTER TABLE chunks_new RENAME TO chunks');
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Delete all local data — events, chunks, manifest, and sync state.
  void clearAllTables() {
    _db.execute('DELETE FROM calendars');
    _db.execute('DELETE FROM events');
    _db.execute('DELETE FROM chunks');
    _db.execute('DELETE FROM manifest');
    _db.execute('DELETE FROM sync_state');
    _db.execute('DELETE FROM app_settings');
    _seedDefaultCalendarFromManifest();
  }

  // -----------------------------------------------------------------------
  // Events
  // -----------------------------------------------------------------------

  List<CalendarEvent> getEventsForPeriod(
    String period, {
    Iterable<String>? calendarIds,
  }) {
    final result = _selectEventsWithCalendarFilter(
      where: 'period = ? AND is_deleted = 0',
      params: [period],
      calendarIds: calendarIds,
    );
    return result.map(_rowToEvent).toList();
  }

  CalendarEvent? getEventById(String id) {
    final result = _db.select('SELECT * FROM events WHERE id = ?', [id]);
    return result.isEmpty ? null : _rowToEvent(result.first);
  }

  List<CalendarEvent> getEventsInRange(
    DateTime from,
    DateTime to, {
    Iterable<String>? calendarIds,
  }) {
    final result = _selectEventsWithCalendarFilter(
      where: 'start >= ? AND start < ? AND is_deleted = 0',
      params: [from.toIso8601String(), to.toIso8601String()],
      calendarIds: calendarIds,
      orderBy: 'start',
    );
    return result.map(_rowToEvent).toList();
  }

  List<CalendarEvent> getDirtyEvents({Iterable<String>? calendarIds}) {
    final result = _selectEventsWithCalendarFilter(
      where: 'is_dirty = 1',
      calendarIds: calendarIds,
    );
    return result.map(_rowToEvent).toList();
  }

  List<String> getDirtyPeriods({Iterable<String>? calendarIds}) {
    final (clause, args) = _calendarFilterClause(calendarIds);
    final sql = 'SELECT DISTINCT period FROM events WHERE is_dirty = 1$clause';
    final result = _db.select(sql, args);
    return result.map((r) => r['period'] as String).toList();
  }

  void upsertEvent(CalendarEvent event) {
    _db.execute(
      '''
      INSERT OR REPLACE INTO events
        (id, title, description, start, end, all_day, recurrence_rule,
         reminders_json, location, period, created_at, updated_at, is_dirty,
         timezone, master_event_id, original_start, is_cancelled, calendar_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        event.timezone,
        event.masterEventId,
        event.originalStart,
        event.isCancelled ? 1 : 0,
        event.calendarId,
      ],
    );
  }

  /// Upsert an event received from the network.
  /// Skips the update if a local row already exists with uncommitted changes
  /// (is_dirty = 1), so local edits and soft-deletes are never clobbered
  /// by a pull.
  void upsertRemoteEvent(CalendarEvent event) {
    final existing = getEventById(event.id);
    if (existing != null && existing.isDirty) return;
    upsertEvent(event);
  }

  void markEventsClean(String period, {String? calendarId}) {
    final targetCalendarId = calendarId ?? kDefaultCalendarId;
    // Remove soft-deleted rows now that their period has been synced.
    _db.execute(
      'DELETE FROM events WHERE period = ? AND calendar_id = ? AND is_deleted = 1',
      [period, targetCalendarId],
    );
    _db.execute(
      'UPDATE events SET is_dirty = 0 WHERE period = ? AND calendar_id = ?',
      [period, targetCalendarId],
    );
  }

  void deleteEvent(String id) {
    final existing = getEventById(id);
    final calendarId = existing?.calendarId ?? kDefaultCalendarId;
    // Soft-delete so the sync engine sees the period as dirty and re-uploads
    // the chunk (or removes it if this was the last event in the period).
    // Rows are physically removed by markEventsClean() after a successful sync.
    _db.execute(
      '''
      UPDATE events
      SET is_deleted = 1, is_dirty = 1
      WHERE master_event_id = ? AND calendar_id = ?
      ''',
      [id, calendarId],
    );
    _db.execute(
      'UPDATE events SET is_deleted = 1, is_dirty = 1 WHERE id = ? AND calendar_id = ?',
      [id, calendarId],
    );
  }

  /// Permanently delete a single event row.
  ///
  /// Used during pull reconciliation when a remote chunk no longer contains
  /// an event that still exists locally.
  void hardDeleteEvent(String id, {String? calendarId}) {
    _db.execute('DELETE FROM events WHERE id = ? AND calendar_id = ?', [
      id,
      calendarId ?? kDefaultCalendarId,
    ]);
  }

  /// Get all recurring master events whose series could produce instances
  /// within [from]..[to]. A master qualifies if its start <= [to] (the series
  /// may extend forward) and it has a recurrence rule.
  List<CalendarEvent> getRecurringMastersInRange(
    DateTime from,
    DateTime to, {
    Iterable<String>? calendarIds,
  }) {
    final result = _selectEventsWithCalendarFilter(
      where: '''recurrence_rule IS NOT NULL
           AND TRIM(recurrence_rule) != ''
           AND (master_event_id IS NULL
                OR TRIM(master_event_id) = ''
                OR LOWER(TRIM(master_event_id)) = 'null')
           AND is_deleted = 0
           AND start <= ?''',
      params: [to.toIso8601String()],
      calendarIds: calendarIds,
      orderBy: 'start',
    );
    return result.map(_rowToEvent).toList();
  }

  /// Get all exception events for a given master event.
  List<CalendarEvent> getExceptionsForMaster(
    String masterEventId, {
    String? calendarId,
  }) {
    final result = _selectEventsWithCalendarFilter(
      where: 'master_event_id = ? AND is_deleted = 0',
      params: [masterEventId],
      calendarIds: calendarId == null ? null : [calendarId],
    );
    return result.map(_rowToEvent).toList();
  }

  /// Get non-recurring, non-exception events in a date range.
  List<CalendarEvent> getNonRecurringEventsInRange(
    DateTime from,
    DateTime to, {
    Iterable<String>? calendarIds,
  }) {
    final result = _selectEventsWithCalendarFilter(
      where: '''start >= ? AND start < ?
           AND (recurrence_rule IS NULL OR recurrence_rule = '')
           AND (master_event_id IS NULL OR TRIM(master_event_id) = '')
           AND is_deleted = 0''',
      params: [from.toIso8601String(), to.toIso8601String()],
      calendarIds: calendarIds,
      orderBy: 'start',
    );
    return result.map(_rowToEvent).toList();
  }

  List<CalendarEvent> getAllEventsForPeriod(
    String period, {
    Iterable<String>? calendarIds,
  }) => getEventsForPeriod(period, calendarIds: calendarIds);

  // -----------------------------------------------------------------------
  // Chunks
  // -----------------------------------------------------------------------

  Map<String, dynamic>? getChunk(String period, {String? calendarId}) {
    final result = _db.select(
      'SELECT * FROM chunks WHERE period = ? AND calendar_id = ?',
      [period, calendarId ?? kDefaultCalendarId],
    );
    return result.isEmpty ? null : result.first;
  }

  void upsertChunk(
    String period,
    String objectId,
    int version, {
    String? calendarId,
  }) {
    _db.execute(
      '''
      INSERT OR REPLACE INTO chunks
      (period, calendar_id, object_id, version, last_synced_at)
      VALUES (?, ?, ?, ?, ?)
    ''',
      [
        period,
        calendarId ?? kDefaultCalendarId,
        objectId,
        version,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  void deleteChunk(String period, {String? calendarId}) {
    _db.execute('DELETE FROM chunks WHERE period = ? AND calendar_id = ?', [
      period,
      calendarId ?? kDefaultCalendarId,
    ]);
  }

  // -----------------------------------------------------------------------
  // App settings
  // -----------------------------------------------------------------------

  static const _defaultEventRemindersKey = 'default_event_reminders_json';

  List<int> getDefaultEventReminderMinutes() {
    final result = _db.select('SELECT value FROM app_settings WHERE key = ?', [
      _defaultEventRemindersKey,
    ]);
    if (result.isEmpty) return const [15];
    try {
      final parsed =
          jsonDecode(result.first['value'] as String) as List<dynamic>;
      return parsed.map((e) => e as int).toList()..sort();
    } catch (_) {
      return const [15];
    }
  }

  void setDefaultEventReminderMinutes(List<int> reminderMinutes) {
    final normalized = reminderMinutes.toSet().toList()..sort();
    _db.execute(
      '''
      INSERT OR REPLACE INTO app_settings (key, value)
      VALUES (?, ?)
      ''',
      [_defaultEventRemindersKey, jsonEncode(normalized)],
    );
  }

  List<String> getAllChunkPeriods({String? calendarId}) {
    final result = _db.select(
      'SELECT period FROM chunks WHERE calendar_id = ?',
      [calendarId ?? kDefaultCalendarId],
    );
    return result.map((r) => r['period'] as String).toList();
  }

  // -----------------------------------------------------------------------
  // Manifest
  // -----------------------------------------------------------------------

  ManifestRow? getManifest({String? calendarId}) {
    final targetCalendarId = calendarId ?? kDefaultCalendarId;
    final result = _db.select('SELECT * FROM manifest WHERE calendar_id = ?', [
      targetCalendarId,
    ]);
    if (result.isEmpty) return null;
    final r = result.first;
    final oid = r['object_id'] as String?;
    return ManifestRow(
      objectId: (oid != null && oid.isNotEmpty) ? oid : null,
      version: r['version'] as int,
      calendarName: r['calendar_name'] as String,
      timezone: r['timezone'] as String,
      color: r['color'] as String,
      calendarId: r['calendar_id'] as String? ?? kDefaultCalendarId,
    );
  }

  void upsertManifest({
    String? calendarId,
    String? objectId,
    int? version,
    String? calendarName,
    String? timezone,
    String? color,
  }) {
    final targetCalendarId = calendarId ?? kDefaultCalendarId;
    final existing = getManifest(calendarId: targetCalendarId);
    if (existing == null) {
      _db.execute(
        '''
        INSERT INTO manifest
        (calendar_id, object_id, version, calendar_name, timezone, color)
        VALUES (?, ?, ?, ?, ?, ?)
      ''',
        [
          targetCalendarId,
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
          'UPDATE manifest SET ${sets.join(', ')} WHERE calendar_id = ?',
          [...params, targetCalendarId],
        );
      }
    }

    if (targetCalendarId == kDefaultCalendarId) {
      final existingCalendar = getCalendarById(kDefaultCalendarId);
      if (existingCalendar != null) {
        upsertCalendar(
          existingCalendar.copyWith(
            name: calendarName ?? existingCalendar.name,
            timezone: timezone ?? existingCalendar.timezone,
            color: color ?? existingCalendar.color,
          ),
        );
      }
    }
  }

  // -----------------------------------------------------------------------
  // Sync State
  // -----------------------------------------------------------------------

  SyncStateRow? getSyncState({String? calendarId}) {
    final result = _db.select(
      'SELECT * FROM sync_state WHERE calendar_id = ?',
      [calendarId ?? kDefaultCalendarId],
    );
    if (result.isEmpty) return null;
    final r = result.first;
    return SyncStateRow(
      cursor: r['cursor'] as String,
      cursorId: r['cursor_id'] as String? ?? '',
      calendarId: r['calendar_id'] as String? ?? kDefaultCalendarId,
      lastSyncAt: r['last_sync_at'] != null
          ? DateTime.parse(r['last_sync_at'] as String)
          : null,
    );
  }

  void updateSyncCursor(String cursor, String cursorId, {String? calendarId}) {
    final now = DateTime.now().toUtc().toIso8601String();
    final targetCalendarId = calendarId ?? kDefaultCalendarId;
    _db.execute(
      '''
      INSERT OR REPLACE INTO sync_state
      (calendar_id, cursor, cursor_id, last_sync_at)
      VALUES (?, ?, ?, ?)
    ''',
      [targetCalendarId, cursor, cursorId, now],
    );
  }

  // -----------------------------------------------------------------------
  // Calendars
  // -----------------------------------------------------------------------

  List<CalendarInfo> getCalendars() {
    final rows = _db.select(
      'SELECT * FROM calendars ORDER BY sort_order, name',
    );
    return rows.map(_rowToCalendar).toList();
  }

  List<CalendarInfo> getVisibleCalendars() {
    final rows = _db.select(
      'SELECT * FROM calendars WHERE is_visible = 1 ORDER BY sort_order, name',
    );
    return rows.map(_rowToCalendar).toList();
  }

  CalendarInfo? getCalendarById(String calendarId) {
    final rows = _db.select('SELECT * FROM calendars WHERE id = ?', [
      calendarId,
    ]);
    return rows.isEmpty ? null : _rowToCalendar(rows.first);
  }

  void upsertCalendar(CalendarInfo calendar) {
    _db.execute(
      '''
      INSERT OR REPLACE INTO calendars
      (id, name, timezone, color, is_visible, sort_order, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        calendar.id,
        calendar.name,
        calendar.timezone,
        calendar.color,
        calendar.isVisible ? 1 : 0,
        calendar.sortOrder,
        calendar.createdAt.toIso8601String(),
        calendar.updatedAt.toIso8601String(),
      ],
    );
  }

  void deleteCalendar(String calendarId) {
    if (calendarId == kDefaultCalendarId) return;
    _db.execute('DELETE FROM calendars WHERE id = ?', [calendarId]);
    _db.execute('DELETE FROM events WHERE calendar_id = ?', [calendarId]);
    _db.execute('DELETE FROM chunks WHERE calendar_id = ?', [calendarId]);
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  CalendarEvent _rowToEvent(Row r) => CalendarEvent(
    id: r['id'] as String,
    calendarId: r['calendar_id'] as String? ?? kDefaultCalendarId,
    title: r['title'] as String,
    description: r['description'] as String? ?? '',
    start: DateTime.parse(r['start'] as String),
    end: DateTime.parse(r['end'] as String),
    allDay: (r['all_day'] as int) == 1,
    recurrenceRule:
        ((r['recurrence_rule'] as String?)?.trim().isNotEmpty ?? false)
        ? (r['recurrence_rule'] as String).trim()
        : null,
    reminderMinutes: _parseReminders(r['reminders_json'] as String),
    location: r['location'] as String? ?? '',
    period: r['period'] as String,
    createdAt: DateTime.parse(r['created_at'] as String),
    updatedAt: DateTime.parse(r['updated_at'] as String),
    isDirty: (r['is_dirty'] as int) == 1,
    timezone: ((r['timezone'] as String?)?.trim().isNotEmpty ?? false)
        ? (r['timezone'] as String).trim()
        : null,
    masterEventId:
        ((r['master_event_id'] as String?)?.trim().isNotEmpty ?? false)
        ? (r['master_event_id'] as String).trim()
        : null,
    originalStart:
        ((r['original_start'] as String?)?.trim().isNotEmpty ?? false)
        ? (r['original_start'] as String).trim()
        : null,
    isCancelled: (r['is_cancelled'] as int?) == 1,
  );

  CalendarInfo _rowToCalendar(Row r) => CalendarInfo(
    id: r['id'] as String,
    name: r['name'] as String,
    timezone: r['timezone'] as String,
    color: r['color'] as String,
    isVisible: (r['is_visible'] as int?) != 0,
    sortOrder: r['sort_order'] as int? ?? 0,
    createdAt: DateTime.parse(r['created_at'] as String),
    updatedAt: DateTime.parse(r['updated_at'] as String),
  );

  ResultSet _selectEventsWithCalendarFilter({
    required String where,
    List<Object?> params = const [],
    Iterable<String>? calendarIds,
    String? orderBy,
  }) {
    final (calendarClause, calendarParams) = _calendarFilterClause(calendarIds);
    final order = orderBy == null ? '' : ' ORDER BY $orderBy';
    final sql = 'SELECT * FROM events WHERE $where$calendarClause$order';
    return _db.select(sql, [...params, ...calendarParams]);
  }

  (String, List<Object?>) _calendarFilterClause(Iterable<String>? calendarIds) {
    if (calendarIds == null) return ('', const []);
    final ids = calendarIds.where((id) => id.isNotEmpty).toList();
    if (ids.isEmpty) return (' AND 1 = 0', const []);
    final placeholders = List.filled(ids.length, '?').join(', ');
    return (' AND calendar_id IN ($placeholders)', ids);
  }

  List<int> _parseReminders(String json) {
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => e as int).toList();
  }

  void close() => _db.dispose();
}

class ManifestRow {
  final String calendarId;
  final String? objectId;
  final int version;
  final String calendarName;
  final String timezone;
  final String color;
  const ManifestRow({
    required this.calendarId,
    this.objectId,
    required this.version,
    required this.calendarName,
    required this.timezone,
    required this.color,
  });
}

class SyncStateRow {
  final String calendarId;
  final String cursor;
  final String cursorId;
  final DateTime? lastSyncAt;
  const SyncStateRow({
    required this.calendarId,
    required this.cursor,
    required this.cursorId,
    this.lastSyncAt,
  });
}
