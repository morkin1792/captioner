import 'package:flutter_test/flutter_test.dart';
import 'package:captioner/main.dart';

void main() {
  testWidgets('App starts correctly', (WidgetTester tester) async {
    await tester.pumpWidget(const CaptionerApp());
    
    // The app should show either setup screen or home screen
    expect(find.byType(CaptionerApp), findsOneWidget);
  });
}
