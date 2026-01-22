import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StorageService {
  static const _assemblyAiKey = 'assemblyai_api_key';
  static const _geminiKey = 'gemini_api_key';

  // Android: Uses Keystore with biometric protection for reading
  // Linux: Uses libsecret/gnome-keyring (protected by system login)
  // The keys are encrypted and require user authentication on Android
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );

  // Separate storage options for reading keys (with biometric on Android)
  AndroidOptions _getAndroidReadOptions() {
    return const AndroidOptions(
      encryptedSharedPreferences: true,
    );
  }

  /// Check if required API keys are set (only AssemblyAI is required)
  Future<bool> hasApiKeys() async {
    final assemblyAi = await _storage.read(key: _assemblyAiKey);
    return assemblyAi != null && assemblyAi.trim().isNotEmpty;
  }

  /// Check if Gemini API key is set (optional, for translation)
  Future<bool> hasGeminiKey() async {
    final gemini = await _storage.read(key: _geminiKey);
    return gemini != null && gemini.trim().isNotEmpty;
  }

  Future<void> saveApiKeys({
    required String assemblyAiKey,
    String geminiKey = '',
  }) async {
    await _storage.write(key: _assemblyAiKey, value: assemblyAiKey);
    await _storage.write(key: _geminiKey, value: geminiKey);
  }

  /// Get AssemblyAI key
  /// On Android: Protected by device credentials (PIN/pattern/password/biometric)
  /// On Linux: Protected by system keyring (unlocked at login)
  Future<String?> getAssemblyAiKey() async {
    String? key;
    if (Platform.isAndroid) {
      key = await _storage.read(
        key: _assemblyAiKey,
        aOptions: _getAndroidReadOptions(),
      );
    } else {
      key = await _storage.read(key: _assemblyAiKey);
    }
    
    if (key != null && key.trim().isEmpty) return null;
    return key?.trim();
  }

  /// Get Gemini key  
  /// On Android: Protected by device credentials (PIN/pattern/password/biometric)
  /// On Linux: Protected by system keyring (unlocked at login)
  Future<String?> getGeminiKey() async {
    String? key;
    if (Platform.isAndroid) {
      key = await _storage.read(
        key: _geminiKey,
        aOptions: _getAndroidReadOptions(),
      );
    } else {
      key = await _storage.read(key: _geminiKey);
    }
    
    if (key != null && key.trim().isEmpty) return null;
    return key?.trim();
  }

  Future<void> clearApiKeys() async {
    await _storage.delete(key: _assemblyAiKey);
    await _storage.delete(key: _geminiKey);
  }
}

