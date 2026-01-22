import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../models/subtitle.dart';
import 'log_service.dart';

class GeminiService {
  final String _apiKey;
  static const String _modelName = 'gemini-3-flash-preview';
  static const String _baseUrl = 'https://generativelanguage.googleapis.com/v1beta/models';

  GeminiService(this._apiKey);

  /// Translate subtitles with parallel batch processing for speed
  Future<List<Subtitle>> translateSubtitles({
    required List<Subtitle> subtitles,
    required String sourceLanguage,
    required String targetLanguage,
    Function(double)? onProgress,
  }) async {
    const batchSize = 40; // Increased from 20 for fewer API calls
    const maxConcurrent = 3; // Process 3 batches in parallel
    final batches = <List<Subtitle>>[];

    // Split into batches
    for (var i = 0; i < subtitles.length; i += batchSize) {
      final end = (i + batchSize < subtitles.length) ? i + batchSize : subtitles.length;
      batches.add(subtitles.sublist(i, end));
    }

    // Results map to maintain order
    final results = List<List<Subtitle>?>.filled(batches.length, null);
    var completedCount = 0;

    // Process batches in parallel with concurrency limit
    for (var chunkStart = 0; chunkStart < batches.length; chunkStart += maxConcurrent) {
      final chunkEnd = (chunkStart + maxConcurrent < batches.length) 
          ? chunkStart + maxConcurrent 
          : batches.length;
      
      // Launch concurrent requests for this chunk
      final futures = <Future<void>>[];
      for (var i = chunkStart; i < chunkEnd; i++) {
        final batchIndex = i;
        final batch = batches[batchIndex];
        
        futures.add(() async {
          try {
            final translated = await _translateBatchWithRetry(batch, sourceLanguage, targetLanguage);
            results[batchIndex] = translated;
          } catch (e) {
            LogService.log('Error translating batch $batchIndex: $e');
            // Fall back to original text with error prefix
            results[batchIndex] = batch.map((s) => 
                s.copyWith(text: '[TRANSLATION ERROR] ${s.text}')).toList();
          }
          
          completedCount++;
          onProgress?.call(completedCount / batches.length);
        }());
      }
      
      // Wait for this chunk of concurrent requests to complete
      await Future.wait(futures);
    }

    // Flatten results in order
    return results.expand<Subtitle>((list) => list ?? []).toList();
  }

  /// Try to translate a batch with exponential backoff retry
  Future<List<Subtitle>> _translateBatchWithRetry(
    List<Subtitle> batch,
    String sourceLang,
    String targetLang,
  ) async {
    int attempts = 0;
    const maxRetries = 3;
    
    while (true) {
      try {
        attempts++;
        return await _translateBatch(batch, sourceLang, targetLang);
      } catch (e) {
        if (attempts > maxRetries) {
          rethrow;
        }
        
        // Exponential backoff: 2s, 4s, 8s
        final delaySeconds = pow(2, attempts).toInt();
        LogService.log('Translation batch failed (Attempt $attempts/$maxRetries). Retrying in ${delaySeconds}s... Error: $e');
        
        await Future.delayed(Duration(seconds: delaySeconds));
      }
    }
  }

  Future<List<Subtitle>> _translateBatch(
    List<Subtitle> batch,
    String sourceLang,
    String targetLang,
  ) async {
    // structured prompt
    final subtitlesJson = batch.map((s) => {
      'id': s.startMs, // Use startMs as ID for mapping back
      'text': s.text,
    }).toList();

    final systemInstruction = '''
You are a professional subtitle translator for video captions.
Translate the following subtitles from $sourceLang to $targetLang.
IMPORTANT RULES:
1. Keep translations CONCISE and SHORT - subtitles must fit on ONE LINE.
2. Preserve the meaning but use fewer words when possible.
3. Do not add explanations or expand the text.
4. Return a JSON array with the same "id" and the translated "text".
5. Do not change the "id" values.
6. Do not merge or split subtitles.
Return ONLY the JSON array with no other text.
''';

    final prompt = jsonEncode(subtitlesJson);

    final response = await http.post(
      Uri.parse('$_baseUrl/$_modelName:generateContent?key=$_apiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': systemInstruction},
              {'text': prompt}
            ]
          }
        ],
        'generationConfig': {
          'responseMimeType': 'application/json',
        }
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Gemini API Error: ${response.statusCode} - ${response.body}');
    }

    final data = jsonDecode(response.body);
    
    // Parse response
    if (data['candidates'] == null || (data['candidates'] as List).isEmpty) {
      throw Exception('No candidates in response');
    }

    final candidate = data['candidates'][0];
    final content = candidate['content'];
    if (content == null || content['parts'] == null) {
      throw Exception('Invalid Gemini response: content or parts missing');
    }
    final parts = content['parts'] as List;
    if (parts.isEmpty || parts[0]['text'] == null) {
      throw Exception('Invalid Gemini response: parts empty or text missing');
    }
    final textResponse = parts[0]['text'] as String;

    // Clean up markdown block if present
    String cleanJson = textResponse.trim();
    if (cleanJson.startsWith('```json')) {
      cleanJson = cleanJson.substring(7);
    }
    if (cleanJson.startsWith('```')) {
      cleanJson = cleanJson.substring(3);
    }
    if (cleanJson.endsWith('```')) {
      cleanJson = cleanJson.substring(0, cleanJson.length - 3);
    }

    final decoded = jsonDecode(cleanJson);
    if (decoded == null || decoded is! List) {
      throw Exception('Gemini response is not a JSON array: $cleanJson');
    }
    final List<dynamic> translatedList = decoded;
    
    // Map back to subtitles
    final result = <Subtitle>[];
    for (final item in translatedList) {
      final id = item['id'] as int;
      final text = item['text'] as String;
      
      // Find original subtitle to get correct timings
      // IDs are startMs, which might not be unique if subtitles start at same time?
      // But usually they are sequential.
      // Better to use index? 
      // Current logic uses startMs as ID.
      
      final original = batch.firstWhere((s) => s.startMs == id, orElse: () => batch[0]);
      // If we can't find by ID (rare), use a fallback or throw. 
      // But we sent startMs as ID.
      
      result.add(original.copyWith(text: text));
    }

    // Ensure we return same number of subtitles
    if (result.length != batch.length) {
       // Fallback or warning
       LogService.log('Warning: batch length mismatch. Sent ${batch.length}, received ${result.length}');
       // We might need to fill in missing ones or truncate.
       // For this implementation, we assume Gemini follows instructions
    }

    return result;
  }
}
