import 'dart:async';

import 'package:flutter/services.dart';

class CalendarFileOpenService {
  CalendarFileOpenService._();

  static final CalendarFileOpenService instance = CalendarFileOpenService._();

  static const MethodChannel _channel = MethodChannel(
    'dev.mmay.sical/calendar_file',
  );

  final List<String> _pendingTexts = <String>[];
  FutureOr<void> Function(String text)? _listener;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onCalendarFileText') return;

      await _consumePendingFromNative();
      await _flushQueued();
    });
  }

  Future<void> setListener(FutureOr<void> Function(String text) listener) async {
    _listener = listener;
    await _consumePendingFromNative();
    await _flushQueued();
  }

  void clearListener() {
    _listener = null;
  }

  Future<void> _consumePendingFromNative() async {
    while (true) {
      final text = await _channel.invokeMethod<String>(
        'consumePendingCalendarFileText',
      );
      if (text == null || text.isEmpty) break;
      await _dispatchOrQueue(text);
    }
  }

  Future<void> _dispatchOrQueue(String text) async {
    final listener = _listener;
    if (listener == null) {
      _pendingTexts.add(text);
      return;
    }

    await listener(text);
  }

  Future<void> _flushQueued() async {
    final listener = _listener;
    if (listener == null || _pendingTexts.isEmpty) return;

    while (_pendingTexts.isNotEmpty) {
      final text = _pendingTexts.removeAt(0);
      await listener(text);
    }
  }
}
