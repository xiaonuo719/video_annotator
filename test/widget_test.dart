import 'package:flutter_test/flutter_test.dart';

import 'package:video_annotator/main.dart';

void main() {
  testWidgets('App starts', (WidgetTester tester) async {
    await tester.pumpWidget(const VideoAnnotatorApp());
    expect(find.text('视频标注'), findsOneWidget);
  });
}
