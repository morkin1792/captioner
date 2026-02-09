import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import '../models/subtitle.dart';
import '../models/caption_config.dart';
import 'font_service.dart';
import 'log_service.dart';

class FfmpegService {
  static bool _fontsInitialized = false;
  
  /// Initialize font configuration for FFmpeg
  /// Copies bundled fonts to app directory and registers them with FFmpegKit (Android) or fontsdir (desktop)
  static Future<void> initializeFonts() async {
    if (_fontsInitialized) return;
    
    // Copy bundled fonts to app directory on all platforms
    try {
      final bundledFontsDir = await FontService.copyBundledFontsToAppDirectory();
      LogService.log('[FFMPEG] Bundled fonts copied to: $bundledFontsDir');
      
      if (Platform.isAndroid || Platform.isIOS) {
        // Android/iOS: Generate a custom fonts.conf file for fontconfig
        final fontsConfPath = await _generateFontsConf(bundledFontsDir);
        LogService.log('[FFMPEG] Generated fonts.conf at: $fontsConfPath');
        
        // Set FONTCONFIG_FILE environment variable
        await FFmpegKitConfig.setEnvironmentVariable('FONTCONFIG_FILE', fontsConfPath);
        await FFmpegKitConfig.setEnvironmentVariable('FONTCONFIG_PATH', File(fontsConfPath).parent.path);
        
        LogService.log('[FFMPEG] Font environment variables set.');
      }
      // Desktop: fonts are accessed via fontsdir option in _buildVideoFilter
    } catch (e, stack) {
      LogService.log('[FFMPEG] Error initializing fonts: $e\n$stack');
    }
    
    _fontsInitialized = true;
  }

  /// Generate a fonts.conf file for fontconfig
  static Future<String> _generateFontsConf(String bundledFontsDir) async {
    // Save fonts.conf inside the bundled fonts directory
    final fontsConfFile = File('$bundledFontsDir/fonts.conf');
    
    // Determine a safe cache directory (start with bundled dir's parent, go to cache)
    // bundledFontsDir is typically .../app_flutter/fonts
    // We want .../cache/fontconfig
    // But safely we can just use a subdirectory of the bundled dir for cache if needed,
    // or better, rely on the system.
    // For simplicity, let's use a subdirectory of the bundled fonts dir for the cache
    // so we don't need to guess absolute paths.
    final cacheDir = '$bundledFontsDir/fc_cache';
    await Directory(cacheDir).create(recursive: true);
    
    const xmlContent = '''
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
    <dir>/system/fonts</dir>
    <dir>%BUNDLED_DIR%</dir>
    <match target="pattern">
        <test qual="any" name="family"><string>sans-serif</string></test>
        <edit name="family" mode="assign" binding="same"><string>Roboto</string></edit>
    </match>
    <match target="pattern">
        <test qual="any" name="family"><string>Montserrat</string></test>
        <edit name="family" mode="assign" binding="same"><string>Montserrat</string></edit>
    </match>
    <cachedir>%CACHE_DIR%</cachedir>
</fontconfig>
''';

    // Replace placeholders with absolute paths
    final content = xmlContent
        .replaceFirst('%BUNDLED_DIR%', bundledFontsDir)
        .replaceFirst('%CACHE_DIR%', cacheDir);
        
    await fontsConfFile.writeAsString(content);
    return fontsConfFile.path;
  }

  /// Check if FFmpeg is available on the system
  Future<bool> checkFfmpegAvailable() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        // FFmpeg is bundled on Android/iOS
        return true;
      }

      // On Linux, check for system FFmpeg
      final result = await Process.run('ffmpeg', ['-version']);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  /// Generate ASS subtitle content with styling (single language, uses default style)
  String generateAssSubtitle({
    required List<Subtitle> subtitles,
    required CaptionConfig config,
    required int videoWidth,
    required int videoHeight,
    String? languageCode,
  }) {
    final style = languageCode != null 
        ? config.getStyleForLanguage(languageCode)
        : const LanguageStyle();
    final fontSize = (style.fontSize * videoHeight / 100).round();
    final marginV = ((100 - style.verticalPosition) * videoHeight / 100).round();
    final colorHex = CaptionConfig.colorToAssHex(style.color);

    final buffer = StringBuffer();
    buffer.writeln('[Script Info]');
    buffer.writeln('Title: Captioner Subtitles');
    buffer.writeln('ScriptType: v4.00+');
    buffer.writeln('PlayResX: $videoWidth');
    buffer.writeln('PlayResY: $videoHeight');
    buffer.writeln('');
    buffer.writeln('[V4+ Styles]');
    buffer.writeln('Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding');
    final outline = style.borderWidth.round();
    buffer.writeln('Style: Default,${style.fontFamily},$fontSize,$colorHex,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,$outline,1,2,10,10,$marginV,1');
    buffer.writeln('');
    buffer.writeln('[Events]');
    buffer.writeln('Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text');

    for (final sub in subtitles) {
      final start = _formatAssTime(sub.startMs);
      final end = _formatAssTime(sub.endMs);
      // Single line - remove newlines
      final text = sub.text.replaceAll('\n', ' ').replaceAll('\\N', ' ');
      buffer.writeln('Dialogue: 0,$start,$end,Default,,0,0,0,,$text');
    }

    return buffer.toString();
  }

  /// Generate ASS subtitle content with multiple languages, each at different vertical positions
  /// Supports per-language styling (font, size, color, position)
  String generateMultiLanguageAssSubtitle({
    required Map<String, List<Subtitle>> subtitlesByLanguage,
    required CaptionConfig config,
    required int videoWidth,
    required int videoHeight,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('[Script Info]');
    buffer.writeln('Title: Captioner Multi-Language Subtitles');
    buffer.writeln('ScriptType: v4.00+');
    buffer.writeln('WrapStyle: 0'); // 0=smart wrap, 1=end-of-line, 2=no wrap, 3=smart+lower wider
    buffer.writeln('PlayResX: $videoWidth');
    buffer.writeln('PlayResY: $videoHeight');
    buffer.writeln('');
    buffer.writeln('[V4+ Styles]');
    buffer.writeln('Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding');

    // Create a style for each language with its own vertical position
    final languages = subtitlesByLanguage.keys.toList();
    for (var i = 0; i < languages.length; i++) {
      final lang = languages[i];
      final style = config.getStyleForLanguage(lang);
      final fontSize = (style.fontSize * videoHeight / 100).round();
      final colorHex = CaptionConfig.colorToAssHex(style.color);
      // Use per-language vertical position (percentage from top -> margin from bottom)
      final marginV = ((100 - style.verticalPosition) * videoHeight / 100).round().clamp(10, videoHeight - 50);
      final outline = style.borderWidth.round();
      buffer.writeln('Style: Lang_$lang,${style.fontFamily},$fontSize,$colorHex,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,$outline,1,2,10,10,$marginV,1');
    }

    buffer.writeln('');
    buffer.writeln('[Events]');
    buffer.writeln('Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text');

    // Add dialogue for each language with explicit positioning to bypass collision detection
    for (final entry in subtitlesByLanguage.entries) {
      final lang = entry.key;
      final style = config.getStyleForLanguage(lang);
      // Calculate exact Y position from vertical position percentage (from top)
      final yPos = (style.verticalPosition * videoHeight / 100).round();
      final xPos = videoWidth ~/ 2; // Center horizontally
      
      for (final sub in entry.value) {
        final start = _formatAssTime(sub.startMs);
        final end = _formatAssTime(sub.endMs);
        // Clean text - ensure single line (replace newlines with space)
        final text = sub.text.replaceAll('\n', ' ').replaceAll('\\N', ' ');
        // Use \pos to place at exact position, bypassing collision detection
        buffer.writeln('Dialogue: 0,$start,$end,Lang_$lang,,0,0,0,,{\\pos($xPos,$yPos)}$text');
      }
    }

    return buffer.toString();
  }

  String _formatAssTime(int ms) {
    final hours = ms ~/ 3600000;
    final minutes = (ms % 3600000) ~/ 60000;
    final seconds = (ms % 60000) ~/ 1000;
    final centiseconds = (ms % 1000) ~/ 10;
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.${centiseconds.toString().padLeft(2, '0')}';
  }

  /// Generate SRT subtitle content
  String generateSrtSubtitle(List<Subtitle> subtitles) {
    final buffer = StringBuffer();

    for (var i = 0; i < subtitles.length; i++) {
      final sub = subtitles[i];
      buffer.writeln('${i + 1}');
      buffer.writeln('${_formatSrtTime(sub.startMs)} --> ${_formatSrtTime(sub.endMs)}');
      buffer.writeln(sub.text);
      buffer.writeln();
    }

    return buffer.toString();
  }

  String _formatSrtTime(int ms) {
    final hours = ms ~/ 3600000;
    final minutes = (ms % 3600000) ~/ 60000;
    final seconds = (ms % 60000) ~/ 1000;
    final millis = ms % 1000;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')},${millis.toString().padLeft(3, '0')}';
  }

  /// Burn subtitles into video
  /// [targetResolution] can be: 'original', '4k', '1440p', '1080p', '720p', '480p'
  Future<bool> burnSubtitles({
    required String inputVideo,
    required String outputVideo,
    required String assSubtitlePath,
    String targetResolution = 'original',
    Function(double)? onProgress,
  }) async {
    try {
      // Initialize fonts before rendering (required for Android subtitle rendering)
      await initializeFonts();
      
      // Debug logging for caption issue
      LogService.log('[FFMPEG DEBUG] ========== BURN SUBTITLES START ==========');
      LogService.log('[FFMPEG DEBUG] Input video: $inputVideo');
      LogService.log('[FFMPEG DEBUG] Output video: $outputVideo');
      LogService.log('[FFMPEG DEBUG] ASS subtitle path: $assSubtitlePath');
      LogService.log('[FFMPEG DEBUG] Target resolution: $targetResolution');
      
      // Check if ASS file exists and log its content preview
      final assFile = File(assSubtitlePath);
      if (await assFile.exists()) {
        final assContent = await assFile.readAsString();
        LogService.log('[FFMPEG DEBUG] ASS file SIZE: ${assContent.length} bytes');
        LogService.log('[FFMPEG DEBUG] ASS file PREVIEW (first 500 chars):');
        LogService.log(assContent.substring(0, assContent.length > 500 ? 500 : assContent.length));
      } else {
        LogService.log('[FFMPEG DEBUG] ERROR: ASS file does NOT exist at path!');
      }
      
      // Get video duration for progress calculation
      final durationMs = await _getVideoDuration(inputVideo);
      
      // Get video dimensions for correct scaling (account for rotation)
      final dims = await getVideoDimensions(inputVideo);
      LogService.log('[FFMPEG DEBUG] Video dimensions: ${dims.width}x${dims.height}');
      
      // Get fonts directory for bundled fonts (desktop needs fontsdir, mobile uses fontconfig)
      final fontsDir = FontService.bundledFontsDirectory;
      LogService.log('[FFMPEG DEBUG] Fonts directory: $fontsDir');
      
      // Build filter chain based on resolution
      String vfFilter = _buildVideoFilter(assSubtitlePath, targetResolution, dims.width, dims.height, 
          fontsDir: Platform.isLinux || Platform.isMacOS || Platform.isWindows ? fontsDir : null);
      LogService.log('[FFMPEG DEBUG] Video filter: $vfFilter');

      if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        // Use system FFmpeg on desktop
        final args = [
          '-i', inputVideo,
          '-vf', vfFilter,
          '-c:a', 'copy',
          '-y', outputVideo
        ];
        
        LogService.log('[FFMPEG] executing: ffmpeg ${args.join(' ')}');

        final process = await Process.start('ffmpeg', args);
        
        process.stderr.transform(utf8.decoder).listen((output) {
          // Parse progress
           if (output.contains('time=')) {
            final timeMatch = RegExp(r'time=(\d+):(\d+):(\d+)\.(\d+)').firstMatch(output);
            if (timeMatch != null && durationMs > 0) {
              final hours = int.parse(timeMatch.group(1)!);
              final minutes = int.parse(timeMatch.group(2)!);
              final seconds = int.parse(timeMatch.group(3)!);
              final currentMs = (hours * 3600 + minutes * 60 + seconds) * 1000;
              final progress = currentMs / durationMs;
              onProgress?.call(progress.clamp(0.0, 1.0));
            }
          }
        });

        final exitCode = await process.exitCode;
        if (exitCode == 0) {
          onProgress?.call(1.0);
          return true;
        } else {
          LogService.log('[FFMPEG] failed with exit code $exitCode');
          return false;
        }
      }

      // Mobile: Use plugin
      final command =
          '-i "$inputVideo" -vf "$vfFilter" -c:a copy -y "$outputVideo"';
      
      LogService.log('[FFMPEG] Mobile command: $command');

      // Use Completer to properly wait for async execution
      final completer = Completer<bool>();

      await FFmpegKit.executeAsync(
        command,
        (session) async {
          // This callback fires when FFmpeg completes
          final returnCode = await session.getReturnCode();
          final success = ReturnCode.isSuccess(returnCode);
          
          if (success) {
            onProgress?.call(1.0);
            LogService.log('[FFMPEG] Completed successfully!');
          } else {
            final logs = await session.getAllLogsAsString();
            LogService.log('[FFMPEG] FAILED with return code: $returnCode');
            LogService.log('[FFMPEG] Full logs:\n$logs');
          }
          
          completer.complete(success);
        },
        (log) {
          // Parse progress from log AND print for debugging
          final output = log.getMessage();
          LogService.log('[FFMPEG] $output');
          if (output.contains('time=')) {
            final timeMatch = RegExp(r'time=(\d+):(\d+):(\d+)\.(\d+)').firstMatch(output);
            if (timeMatch != null && durationMs > 0) {
              final hours = int.parse(timeMatch.group(1)!);
              final minutes = int.parse(timeMatch.group(2)!);
              final seconds = int.parse(timeMatch.group(3)!);
              final currentMs = (hours * 3600 + minutes * 60 + seconds) * 1000;
              final progress = currentMs / durationMs;
              onProgress?.call(progress.clamp(0.0, 1.0));
            }
          }
        },
        (stats) {},
      );

      // Wait for FFmpeg to actually complete
      return await completer.future;
    } catch (e) {
      LogService.log('FFmpeg error: $e');
      return false;
    }
  }

  /// Build video filter string with optional scaling
  String _buildVideoFilter(String assPath, String targetResolution, int videoWidth, int videoHeight, {String? fontsDir}) {
    final isPortrait = videoHeight > videoWidth;
    
    // Get target short-side dimension based on resolution
    int? targetShortSide;
    switch (targetResolution) {
      case '4k':
        targetShortSide = 2160;
        break;
      case '1440p':
        targetShortSide = 1440;
        break;
      case '1080p':
        targetShortSide = 1080;
        break;
      case '720p':
        targetShortSide = 720;
        break;
      case '480p':
        targetShortSide = 480;
        break;
      default:
        // 'original' - no scaling
        targetShortSide = null;
    }

    // Normalize path for FFmpeg filter: 
    // 1. Convert Windows backslashes to forward slashes (FFmpeg accepts both, cleaner)
    // 2. Escape special characters for FFmpeg filter syntax: ' and :
    final normalizedPath = assPath.replaceAll('\\', '/');
    final escapedAssPath = normalizedPath
        .replaceAll("'", "'\\''")     // Escape single quotes with '\''
        .replaceAll(':', '\\:');      // Escape colons

    // Build subtitles filter with optional fontsdir for bundled fonts
    String subtitlesFilter;
    if (fontsDir != null) {
      final escapedFontsDir = fontsDir.replaceAll('\\', '/').replaceAll(':', '\\:');
      subtitlesFilter = "subtitles='$escapedAssPath':fontsdir='$escapedFontsDir'";
    } else {
      subtitlesFilter = "subtitles='$escapedAssPath'";
    }

    if (targetShortSide == null) {
      // Original resolution - just apply subtitles
      return subtitlesFilter;
    } else {
      // Apply subtitles FIRST (on original resolution), THEN scale
      // For portrait: scale width, let height adjust automatically
      // For landscape: scale height, let width adjust automatically
      if (isPortrait) {
        return "$subtitlesFilter,scale=$targetShortSide:-2";
      } else {
        return "$subtitlesFilter,scale=-2:$targetShortSide";
      }
    }
  }

  Future<int> _getVideoDuration(String videoPath) async {
    try {
      String? output;
      
      if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        final result = await Process.run('ffmpeg', ['-i', videoPath]);
        // FFmpeg writes info to stderr
        output = result.stderr.toString() + result.stdout.toString(); 
      } else {
        final session = await FFmpegKit.execute('-i "$videoPath" 2>&1');
        output = await session.getOutput();
      }

      if (output != null) {
        final durationMatch =
            RegExp(r'Duration: (\d+):(\d+):(\d+)\.(\d+)').firstMatch(output);
        if (durationMatch != null) {
          final hours = int.parse(durationMatch.group(1)!);
          final minutes = int.parse(durationMatch.group(2)!);
          final seconds = int.parse(durationMatch.group(3)!);
          return (hours * 3600 + minutes * 60 + seconds) * 1000;
        }
      }
    } catch (e) {
      LogService.log('Error getting duration: $e');
    }
    return 0;
  }

  /// Get video dimensions, accounting for rotation metadata
  Future<({int width, int height})> getVideoDimensions(String videoPath) async {
    try {
      String? output;
      
      if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        final result = await Process.run('ffmpeg', ['-i', videoPath]);
        output = result.stderr.toString() + result.stdout.toString();
      } else {
        final session = await FFmpegKit.execute('-i "$videoPath" 2>&1');
        output = await session.getOutput();
      }

      if (output != null) {
        // Parse dimensions
        final sizeMatch = RegExp(r'(\d{2,5})x(\d{2,5})').firstMatch(output);
        if (sizeMatch != null) {
          int width = int.parse(sizeMatch.group(1)!);
          int height = int.parse(sizeMatch.group(2)!);
          
          // Check for rotation metadata
          // Look for patterns like "rotate : 90" or "displaymatrix: rotation of -90.00"
          final rotateMatch = RegExp(r'rotate\s*:\s*(-?\d+)').firstMatch(output);
          final displayMatrixMatch = RegExp(r'rotation of\s*(-?\d+)').firstMatch(output);
          
          int rotation = 0;
          if (rotateMatch != null) {
            rotation = int.parse(rotateMatch.group(1)!).abs();
          } else if (displayMatrixMatch != null) {
            rotation = int.parse(displayMatrixMatch.group(1)!).abs();
          }
          
          // Swap dimensions if rotated 90 or 270 degrees
          if (rotation == 90 || rotation == 270) {
            LogService.log('[FFMPEG] Video has rotation=$rotation°, swapping dimensions');
            return (width: height, height: width);
          }
          
          return (width: width, height: height);
        }
      }
    } catch (e) {
      LogService.log('Error getting dimensions: $e');
    }
    return (width: 1920, height: 1080); // Default to 1080p
  }
}
