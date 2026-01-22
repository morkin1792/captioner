import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import '../models/subtitle.dart';
import 'log_service.dart';

class AssemblyAiService {
  final String apiKey;
  static const _baseUrl = 'https://api.assemblyai.com/v2';

  AssemblyAiService(this.apiKey);

  Map<String, String> get _headers => {
        'Authorization': apiKey,
        'Content-Type': 'application/json',
      };

  /// Transcribe a video/audio file and return subtitles and raw word data
  Future<TranscriptionResult> transcribe({
    required String filePath,
    required String languageCode,
    int maxCharsPerSegment = 25,
    Function(String)? onStatus,
    Function(double)? onProgress,
  }) async {
    onStatus?.call('Extracting audio...');
    onProgress?.call(0.0);

    // Step 1: Extract audio from video (much smaller file to upload)
    final audioPath = await _extractAudio(filePath, onStatus: onStatus);

    onStatus?.call('Uploading file...');
    onProgress?.call(0.1);

    // Step 2: Upload the audio file with progress
    final uploadUrl = await _uploadFileWithProgress(
      audioPath,
      onProgress: (p) => onProgress?.call(0.1 + p * 0.3), // 10-40%
      onStatus: onStatus,
    );

    onStatus?.call('Starting transcription...');
    onProgress?.call(0.4);

    // Step 3: Create transcription request
    final transcriptId = await _createTranscription(
      audioUrl: uploadUrl,
      languageCode: languageCode,
    );

    onStatus?.call('Transcribing audio...');

    // Step 4: Poll for completion
    final result = await _pollForCompletion(
      transcriptId,
      onStatus: onStatus,
      onProgress: (p) => onProgress?.call(0.4 + p * 0.5), // 40-90%
    );

    onStatus?.call('Processing subtitles...');
    onProgress?.call(0.95);

    // Clean up temporary audio file
    try {
      await File(audioPath).delete();
    } catch (_) {}

    onProgress?.call(1.0);

    // Step 5: Parse words into subtitle segments
    final words = (result['words'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
    final subtitles = createSubtitlesFromWords(words, maxCharsPerSegment);
    
    return TranscriptionResult(
      subtitles: subtitles,
      rawWords: words,
    );
  }

  /// Extract audio from video using FFmpeg
  Future<String> _extractAudio(String videoPath, {Function(String)? onStatus}) async {
    final tempDir = await getTemporaryDirectory();
    final audioPath = '${tempDir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';

    onStatus?.call('Extracting audio from video...');

    try {
      if (Platform.isAndroid || Platform.isIOS) {
        // Use FFmpegKit on mobile
        final command = '-i "$videoPath" -vn -acodec aac -b:a 128k -ar 44100 -y "$audioPath"';
        final session = await FFmpegKit.execute(command);
        final returnCode = await session.getReturnCode();
        
        if (!ReturnCode.isSuccess(returnCode)) {
          final logs = await session.getAllLogsAsString();
          LogService.log('FFmpeg Error: $logs'); // Debug
          onStatus?.call('Audio extraction failed ($logs), uploading original...');
          return videoPath;
        }
      } else {
        // Use system FFmpeg on desktop
        final result = await Process.run('ffmpeg', [
          '-i', videoPath,
          '-vn',           // No video
          '-acodec', 'aac',
          '-b:a', '128k',   // 128kbps audio
          '-ar', '44100',  // 44.1kHz sample rate
          '-y',            // Overwrite
          audioPath,
        ]);

        if (result.exitCode != 0) {
          onStatus?.call('Audio extraction failed, uploading original...');
          return videoPath;
        }
      }
    } catch (e) {
      onStatus?.call('Audio extraction error: $e, uploading original...');
      return videoPath;
    }

    final audioFile = File(audioPath);
    final videoFile = File(videoPath);
    final audioSize = await audioFile.length();
    final videoSize = await videoFile.length();
    
    onStatus?.call('Audio extracted (${(audioSize / 1024 / 1024).toStringAsFixed(1)}MB vs ${(videoSize / 1024 / 1024).toStringAsFixed(1)}MB video)');

    return audioPath;
  }

  /// Upload file with progress tracking
  Future<String> _uploadFileWithProgress(
    String filePath, {
    Function(double)? onProgress,
    Function(String)? onStatus,
  }) async {
    final file = File(filePath);
    final fileSize = await file.length();
    final fileSizeMB = (fileSize / 1024 / 1024).toStringAsFixed(1);
    
    onStatus?.call('Starting upload ($fileSizeMB MB)...');
    
    // Use HttpClient for progress tracking
    final client = HttpClient();
    client.connectionTimeout = const Duration(minutes: 5);
    
    try {
      final request = await client.postUrl(Uri.parse('$_baseUrl/upload'));
      
      request.headers.set('Authorization', apiKey);
      request.headers.set('Content-Type', 'application/octet-stream');
      request.contentLength = fileSize;

      // Stream the file with progress updates
      int bytesSent = 0;
      final fileStream = file.openRead();
      
      await for (final chunk in fileStream) {
        request.add(chunk);
        bytesSent += chunk.length;
        final progress = bytesSent / fileSize;
        onProgress?.call(progress * 0.9); // Reserve 10% for finalization
        final percent = (progress * 100).toInt();
        onStatus?.call('Uploading... $percent%');
      }

      onStatus?.call('Waiting Assembly Transcription API...');
      onProgress?.call(0.95);
      
      Timer? timer;
      if (onStatus != null) {
        final startTime = DateTime.now();
        timer = Timer.periodic(const Duration(seconds: 1), (t) {
           final elapsed = DateTime.now().difference(startTime).inSeconds;
           final elapsedStr = elapsed < 60 ? '${elapsed}s' : '${elapsed ~/ 60}m ${elapsed % 60}s';
           onStatus('Waiting Assembly Transcription API... ($elapsedStr)');
        });
      }
      
      HttpClientResponse response;
      try {
        response = await request.close().timeout(
          const Duration(minutes: 10),
          onTimeout: () {
            throw Exception('Upload timed out. Please try again with a smaller file or better connection.');
          },
        );
      } finally {
        timer?.cancel();
      }
      
      onStatus?.call('Processing response...');
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        throw Exception('Upload failed (${response.statusCode}): $responseBody');
      }

      final json = jsonDecode(responseBody);
      onProgress?.call(1.0);
      
      return json['upload_url'] as String;
    } finally {
      client.close();
    }
  }

  Future<String> _createTranscription({
    required String audioUrl,
    required String languageCode,
  }) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/transcript'),
      headers: _headers,
      body: jsonEncode({
        'audio_url': audioUrl,
        'language_code': languageCode,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Transcription request failed: ${response.body}');
    }

    final json = jsonDecode(response.body);
    return json['id'] as String;
  }

  Future<Map<String, dynamic>> _pollForCompletion(
    String transcriptId, {
    Function(String)? onStatus,
    Function(double)? onProgress,
  }) async {
    int pollCount = 0;
    const maxPolls = 100; // ~5 minutes max
    final startTime = DateTime.now();
    
    while (pollCount < maxPolls) {
      final response = await http.get(
        Uri.parse('$_baseUrl/transcript/$transcriptId'),
        headers: _headers,
      );

      if (response.statusCode != 200) {
        throw Exception('Polling failed: ${response.body}');
      }

      final json = jsonDecode(response.body);
      final status = json['status'] as String;

      if (status == 'completed') {
        return json;
      } else if (status == 'error') {
        throw Exception('Transcription error: ${json['error']}');
      }

      pollCount++;
      // Estimate progress based on poll count (rough approximation)
      onProgress?.call((pollCount / maxPolls).clamp(0.0, 0.95));
      
      // Show more informative status based on API status
      final elapsed = DateTime.now().difference(startTime).inSeconds;
      final elapsedStr = elapsed < 60 ? '${elapsed}s' : '${elapsed ~/ 60}m ${elapsed % 60}s';
      
      switch (status) {
        case 'queued':
          onStatus?.call('Waiting in queue... ($elapsedStr)');
          break;
        case 'processing':
          onStatus?.call('Processing audio... ($elapsedStr)');
          break;
        default:
          onStatus?.call('Transcribing... ($elapsedStr)');
      }
      
      await Future.delayed(const Duration(seconds: 3));
    }

    throw Exception('Transcription timed out');
  }

  /// Static method to create subtitles from raw word data for on-the-fly re-segmentation
  /// Now uses character-based limit instead of word count
  static List<Subtitle> createSubtitlesFromWords(List<Map<String, dynamic>> words, int maxChars) {
    if (words.isEmpty) {
      return [];
    }

    final subtitles = <Subtitle>[];
    final currentWords = <Map<String, dynamic>>[];
    int segmentStart = 0;
    int currentCharCount = 0;

    const maxDurationMs = 2500;

    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      final wordText = word['text'] as String;
      
      if (currentWords.isEmpty) {
        segmentStart = word['start'] as int;
        currentCharCount = 0;
      }

      // Calculate what the char count would be if we add this word
      final wordLen = wordText.length;
      final spaceLen = currentWords.isEmpty ? 0 : 1; // Space before word
      final wouldBeCharCount = currentCharCount + spaceLen + wordLen;
      
      // Check if next word is just punctuation (should stay with current word)
      bool nextIsPunctuation = false;
      if (i + 1 < words.length) {
        final nextWord = words[i + 1]['text'] as String;
        nextIsPunctuation = RegExp(r'^[,\.!?\;\:\-\—\–]+$').hasMatch(nextWord.trim());
      }

      // Check limits
      final segmentDuration = (word['end'] as int) - segmentStart;
      final wouldExceedChars = wouldBeCharCount > maxChars;
      final wouldExceedDuration = segmentDuration >= maxDurationMs;

      // If adding word exceeds limits and we have words, save current segment first
      // But don't break if next word is punctuation (keep it with current word)
      if (currentWords.isNotEmpty && (wouldExceedChars || wouldExceedDuration) && !nextIsPunctuation) {
        subtitles.add(Subtitle(
          startMs: segmentStart,
          endMs: currentWords.last['end'] as int,
          text: currentWords.map((w) => w['text']).join(' '),
        ));
        currentWords.clear();
        currentCharCount = 0;
        segmentStart = word['start'] as int;
      }

      currentWords.add(word as Map<String, dynamic>);
      currentCharCount += (currentWords.length == 1 ? 0 : 1) + wordLen; // Add space if not first
    }

    // Add remaining words
    if (currentWords.isNotEmpty) {
      subtitles.add(Subtitle(
        startMs: segmentStart,
        endMs: currentWords.last['end'] as int,
        text: currentWords.map((w) => w['text']).join(' '),
      ));
    }

    return subtitles;
  }

  /// Export subtitles to SRT file
  Future<String> exportToSrt(List<Subtitle> subtitles) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/subtitles_${DateTime.now().millisecondsSinceEpoch}.srt');

    final buffer = StringBuffer();
    for (var i = 0; i < subtitles.length; i++) {
      final sub = subtitles[i];
      buffer.writeln('${i + 1}');
      buffer.writeln('${_formatSrtTime(sub.startMs)} --> ${_formatSrtTime(sub.endMs)}');
      buffer.writeln(sub.text);
      buffer.writeln();
    }

    await file.writeAsString(buffer.toString());
    return file.path;
  }

  String _formatSrtTime(int ms) {
    final hours = ms ~/ 3600000;
    final minutes = (ms % 3600000) ~/ 60000;
    final seconds = (ms % 60000) ~/ 1000;
    final millis = ms % 1000;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')},${millis.toString().padLeft(3, '0')}';
  }
}

class TranscriptionResult {
  final List<Subtitle> subtitles;
  final List<Map<String, dynamic>> rawWords;

  TranscriptionResult({
    required this.subtitles,
    required this.rawWords,
  });
}
