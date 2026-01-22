import 'dart:io';
import 'package:path/path.dart' as path;

/// Log service that writes logs to a file next to the executable on desktop
class LogService {
  static File? _logFile;
  static IOSink? _logSink;
  static bool _initialized = false;
  static const int _maxLogSizeBytes = 100 * 1024 * 1024; // 100MB
  
  /// Initialize log file (only on desktop platforms)
  static Future<void> initialize() async {
    if (_initialized) return;
    
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      try {
        // Get executable directory
        final executablePath = Platform.resolvedExecutable;
        final executableDir = path.dirname(executablePath);
        
        // Use fixed filename
        final logPath = path.join(executableDir, 'captioner.log');
        _logFile = File(logPath);
        
        // Check file size - overwrite if > 100MB, otherwise append
        FileMode mode = FileMode.append;
        if (await _logFile!.exists()) {
          final size = await _logFile!.length();
          if (size > _maxLogSizeBytes) {
            mode = FileMode.write; // Overwrite
          }
        }
        
        _logSink = _logFile!.openWrite(mode: mode);
        
        // Write session header
        _logSink!.writeln('');
        _logSink!.writeln('='.padRight(80, '='));
        _logSink!.writeln('=== Captioner Session Started at ${DateTime.now()} ===');
        _logSink!.writeln('Platform: ${Platform.operatingSystem}');
        _logSink!.writeln('Executable: $executablePath');
        _logSink!.writeln('='.padRight(80, '='));
        _logSink!.writeln('');
        
        // Just print to file, avoid console for initialization
        _logSink!.writeln('[${DateTime.now().toIso8601String()}] Log file initialized: $logPath');
        
        _initialized = true;
        
      } catch (e) {
        // Silent fail - can't log if logging fails
      }
    }
    _initialized = true;
  }
  
  /// Log a message (only to file, use print() separately for console if needed)
  static void log(String message) {
    // Use print instead of debugPrint to avoid StreamSink issues
    print(message);
    
    // Write to file if available
    if (_logSink != null) {
      final timestamp = DateTime.now().toIso8601String();
      _logSink!.writeln('[$timestamp] $message');
    }
  }
  
  /// Log an error with optional stack trace
  static void error(String message, [dynamic exception, StackTrace? stackTrace]) {
    // Build error message
    final buffer = StringBuffer();
    final timestamp = DateTime.now().toIso8601String();
    buffer.writeln('[$timestamp] ERROR: $message');
    if (exception != null) buffer.writeln('  Exception: $exception');
    if (stackTrace != null) buffer.writeln('  Stack trace:\n$stackTrace');
    
    final errorText = buffer.toString();
    
    // Print to console
    print(errorText);
    
    // Write to file if available
    if (_logSink != null) {
      _logSink!.write(errorText);
    }
  }
  
  /// Force flush and close the log file
  static Future<void> close() async {
    if (_logSink != null) {
      _logSink!.writeln('');
      _logSink!.writeln('=== Captioner Session Ended at ${DateTime.now()} ===');
      _logSink!.writeln('');
      await _logSink!.flush();
      await _logSink!.close();
      _logSink = null;
      _logFile = null;
      _initialized = false;
    }
  }
  
  /// Get the log file path (or null if not initialized)
  static String? get logFilePath => _logFile?.path;
}
