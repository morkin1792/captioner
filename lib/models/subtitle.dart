class Subtitle {
  final int startMs;
  final int endMs;
  final String text;

  const Subtitle({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  Subtitle copyWith({
    int? startMs,
    int? endMs,
    String? text,
  }) {
    return Subtitle(
      startMs: startMs ?? this.startMs,
      endMs: endMs ?? this.endMs,
      text: text ?? this.text,
    );
  }

  Map<String, dynamic> toJson() => {
        'startMs': startMs,
        'endMs': endMs,
        'text': text,
      };

  factory Subtitle.fromJson(Map<String, dynamic> json) => Subtitle(
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        text: json['text'] as String,
      );

  /// Parse SRT format string into list of subtitles
  static List<Subtitle> parseSrt(String srtContent) {
    final subtitles = <Subtitle>[];
    final blocks = srtContent.trim().split(RegExp(r'\n\n+'));

    for (final block in blocks) {
      final lines = block.trim().split('\n');
      if (lines.length < 3) continue;

      // Parse timestamp line (e.g., "00:00:01,000 --> 00:00:04,000")
      final timeMatch = RegExp(
        r'(\d+):(\d+):(\d+)[,.](\d+)\s*-->\s*(\d+):(\d+):(\d+)[,.](\d+)',
      ).firstMatch(lines[1]);

      if (timeMatch == null) continue;

      final startMs = _parseTimeToMs(
        int.parse(timeMatch.group(1)!),
        int.parse(timeMatch.group(2)!),
        int.parse(timeMatch.group(3)!),
        int.parse(timeMatch.group(4)!),
      );

      final endMs = _parseTimeToMs(
        int.parse(timeMatch.group(5)!),
        int.parse(timeMatch.group(6)!),
        int.parse(timeMatch.group(7)!),
        int.parse(timeMatch.group(8)!),
      );

      // Join remaining lines as text
      final text = lines.sublist(2).join('\n');

      subtitles.add(Subtitle(
        startMs: startMs,
        endMs: endMs,
        text: text,
      ));
    }

    return subtitles;
  }

  static int _parseTimeToMs(int hours, int minutes, int seconds, int millis) {
    // Handle milliseconds that might be in different formats (e.g., 32 vs 320)
    if (millis < 10) millis *= 100;
    else if (millis < 100) millis *= 10;

    return hours * 3600000 + minutes * 60000 + seconds * 1000 + millis;
  }

  @override
  String toString() => 'Subtitle($startMs-$endMs: $text)';
}
