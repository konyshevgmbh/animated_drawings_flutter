import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_animated_drawings/app/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const AnimatedDrawingsApp());
    expect(find.byType(AnimatedDrawingsApp), findsOneWidget);
  });
}
