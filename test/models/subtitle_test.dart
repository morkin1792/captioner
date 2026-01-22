import 'package:flutter_test/flutter_test.dart';
import 'package:captioner/models/subtitle.dart';

void main() {
  group('Subtitle', () {
    test('parses SRT format correctly', () {
      const srtContent = '''1
00:00:01,000 --> 00:00:04,000
Hello, world!

2
00:00:05,500 --> 00:00:08,200
This is a test subtitle.
''';

      final subtitles = Subtitle.parseSrt(srtContent);

      expect(subtitles.length, 2);
      expect(subtitles[0].startMs, 1000);
      expect(subtitles[0].endMs, 4000);
      expect(subtitles[0].text, 'Hello, world!');
      expect(subtitles[1].startMs, 5500);
      expect(subtitles[1].endMs, 8200);
      expect(subtitles[1].text, 'This is a test subtitle.');
    });

    test('handles multi-line subtitle text', () {
      const srtContent = '''1
00:00:01,000 --> 00:00:04,000
Line one
Line two
''';

      final subtitles = Subtitle.parseSrt(srtContent);

      expect(subtitles.length, 1);
      expect(subtitles[0].text, 'Line one\nLine two');
    });

    test('copyWith creates new instance with updated fields', () {
      final original = Subtitle(startMs: 1000, endMs: 2000, text: 'Original');
      final modified = original.copyWith(text: 'Modified');

      expect(modified.startMs, 1000);
      expect(modified.endMs, 2000);
      expect(modified.text, 'Modified');
      expect(original.text, 'Original');
    });

    test('toJson and fromJson roundtrip', () {
      final original = Subtitle(startMs: 1234, endMs: 5678, text: 'Test');
      final json = original.toJson();
      final restored = Subtitle.fromJson(json);

      expect(restored.startMs, original.startMs);
      expect(restored.endMs, original.endMs);
      expect(restored.text, original.text);
    });
  });
}
