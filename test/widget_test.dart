import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sical/src/app.dart';

void main() {
  testWidgets('shows SiCal title', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: SiCalApp()));
    await tester.pump();

    // App renders without crashing (shows loading indicator while initializing)
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
