import 'package:flutter_test/flutter_test.dart';
import 'package:sical/src/app.dart';

void main() {
  testWidgets('shows SiCal title', (WidgetTester tester) async {
    await tester.pumpWidget(const SiCalApp());

    expect(find.text('SiCal'), findsOneWidget);
  });
}
