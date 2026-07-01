import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sical/src/database/database.dart';
import 'package:sical/src/models/event.dart';
import 'package:sical/src/services/sia_storage_service.dart';
import 'package:sical/src/services/sync_engine.dart';

class _FakeSiaStorageService extends SiaStorageService {
  final List<(List<SiaObjectEvent>, String, String, bool)> pages;
  final Map<String, (String, String)> objectsById;
  int _pageIndex = 0;

  _FakeSiaStorageService({required this.pages, this.objectsById = const {}});

  @override
  Future<(List<SiaObjectEvent>, String, String, bool)> listObjects(
    String cursorAfter,
    String cursorId,
  ) async {
    if (_pageIndex >= pages.length) {
      return (<SiaObjectEvent>[], cursorAfter, cursorId, false);
    }
    return pages[_pageIndex++];
  }

  @override
  Future<(String, String)> downloadObject(String objectId) async {
    final payload = objectsById[objectId];
    if (payload == null) {
      throw StateError('No fake object registered for $objectId');
    }
    return payload;
  }
}

CalendarEvent _buildEvent({
  required String id,
  required String calendarId,
  required DateTime start,
}) {
  return CalendarEvent(
    id: id,
    calendarId: calendarId,
    title: 'Test Event',
    start: start,
    end: start.add(const Duration(hours: 1)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  late AppDatabase db;
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('sical_phase1_tests_');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          return tempDir.path;
        });

    db = await AppDatabase.getInstance();
  });

  tearDown(() {
    db.clearAllTables();
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);

    db.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('Sync regression guards', () {
    test('sync_state keeps independent cursors per calendar', () {
      db.updateSyncCursor('cursor-default', 'cursor-id-default');
      db.updateSyncCursor('cursor-work', 'cursor-id-work', calendarId: 'work');

      expect(
        db.getSyncState(calendarId: kDefaultCalendarId)?.cursor,
        'cursor-default',
      );
      expect(db.getSyncState(calendarId: 'work')?.cursor, 'cursor-work');
    });

    test('chunks keep independent rows per calendar for same period', () {
      db.upsertChunk('2026-06', 'object-default', 0);
      db.upsertChunk('2026-06', 'object-work', 0, calendarId: 'work');

      expect(
        db.getChunk('2026-06', calendarId: kDefaultCalendarId)?['object_id'],
        'object-default',
      );
      expect(
        db.getChunk('2026-06', calendarId: 'work')?['object_id'],
        'object-work',
      );
    });

    test(
      'pullChanges deletes local period data when a remote chunk is deleted',
      () async {
        const calendarId = kDefaultCalendarId;
        const period = '2026-04';

        db.upsertEvent(
          _buildEvent(
            id: 'event-a',
            calendarId: calendarId,
            start: DateTime.utc(2026, 4, 12, 9),
          ),
        );
        db.upsertChunk(period, 'chunk-old', 0, calendarId: calendarId);

        final fakeSia = _FakeSiaStorageService(
          pages: [
            (
              [
                const SiaObjectEvent(
                  objectId: 'chunk-old',
                  deleted: true,
                  metadataJson:
                      '{"type":"chunk","period":"2026-04","calendar_id":"default"}',
                ),
              ],
              'cursor-1',
              'id-1',
              false,
            ),
          ],
        );

        final engine = SyncEngine(db, fakeSia);
        await engine.pullChanges(calendarId: calendarId);

        expect(
          db.getAllEventsForPeriod(period, calendarIds: [calendarId]),
          isEmpty,
        );
        expect(db.getChunk(period, calendarId: calendarId), isNull);
      },
    );

    test(
      'pullChanges removes periods missing from latest manifest chunk map',
      () async {
        const calendarId = kDefaultCalendarId;
        const period = '2026-04';
        const manifestObjectId = 'manifest-new';

        db.upsertEvent(
          _buildEvent(
            id: 'event-b',
            calendarId: calendarId,
            start: DateTime.utc(2026, 4, 13, 12),
          ),
        );
        db.upsertChunk(period, 'chunk-old', 0, calendarId: calendarId);

        final fakeSia = _FakeSiaStorageService(
          pages: [
            (
              [
                const SiaObjectEvent(
                  objectId: manifestObjectId,
                  deleted: false,
                  metadataJson: '{"type":"manifest","calendar_id":"default"}',
                ),
              ],
              'cursor-2',
              'id-2',
              false,
            ),
          ],
          objectsById: const {
            manifestObjectId: (
              '{"calendar_name":"My Calendar","timezone":"UTC","color":"#1ED660","calendar_id":"default","chunks":{}}',
              '{"type":"manifest","calendar_id":"default"}',
            ),
          },
        );

        final engine = SyncEngine(db, fakeSia);
        await engine.pullChanges(calendarId: calendarId);

        expect(
          db.getAllEventsForPeriod(period, calendarIds: [calendarId]),
          isEmpty,
        );
        expect(db.getChunk(period, calendarId: calendarId), isNull);
      },
    );

    test('pullChanges creates local calendar for non-default manifest', () async {
      const calendarId = 'work';
      const manifestObjectId = 'manifest-work';

      final fakeSia = _FakeSiaStorageService(
        pages: [
          (
            [
              const SiaObjectEvent(
                objectId: manifestObjectId,
                deleted: false,
                metadataJson: '{"type":"manifest","calendar_id":"work"}',
              ),
            ],
            'cursor-2b',
            'id-2b',
            false,
          ),
        ],
        objectsById: const {
          manifestObjectId: (
            '{"calendar_name":"Work","timezone":"America/New_York","color":"#3366FF","calendar_id":"work","chunks":{}}',
            '{"type":"manifest","calendar_id":"work"}',
          ),
        },
      );

      final engine = SyncEngine(db, fakeSia);
      await engine.pullChanges(calendarId: calendarId);

      final calendar = db.getCalendarById(calendarId);
      expect(calendar, isNotNull);
      expect(calendar?.name, 'Work');
      expect(calendar?.timezone, 'America/New_York');
      expect(calendar?.color, '#3366FF');
    });

    test(
      'pullChanges removes local events missing from updated remote chunk',
      () async {
        const calendarId = kDefaultCalendarId;
        const period = '2026-04';
        const chunkObjectId = 'chunk-new';
        final keptEvent = _buildEvent(
          id: 'event-keep',
          calendarId: calendarId,
          start: DateTime.utc(2026, 4, 15, 10),
        );

        db.upsertEvent(keptEvent);
        db.upsertEvent(
          _buildEvent(
            id: 'event-delete',
            calendarId: calendarId,
            start: DateTime.utc(2026, 4, 16, 10),
          ),
        );
        db.markEventsClean(period, calendarId: calendarId);
        db.upsertChunk(period, 'chunk-old', 0, calendarId: calendarId);

        final chunkJson = jsonEncode({
          'period': period,
          'events': [keptEvent.toJson()],
        });

        final fakeSia = _FakeSiaStorageService(
          pages: [
            (
              [
                const SiaObjectEvent(
                  objectId: chunkObjectId,
                  deleted: false,
                  metadataJson:
                      '{"type":"chunk","period":"2026-04","calendar_id":"default"}',
                ),
              ],
              'cursor-3',
              'id-3',
              false,
            ),
          ],
          objectsById: {
            chunkObjectId: (
              chunkJson,
              '{"type":"chunk","period":"2026-04","calendar_id":"default"}',
            ),
          },
        );

        final engine = SyncEngine(db, fakeSia);
        await engine.pullChanges(calendarId: calendarId);

        final events = db.getAllEventsForPeriod(
          period,
          calendarIds: [calendarId],
        );
        expect(events.map((e) => e.id).toSet(), {'event-keep'});
      },
    );
  });
}
