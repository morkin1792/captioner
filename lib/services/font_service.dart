import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_fonts/system_fonts.dart';


class FontService {
  static const _lastFontKey = 'last_used_font';
  static const _defaultFont = 'Roboto';
  
  static List<String>? _cachedFonts;
  static String? _bundledFontsDirectory;
  
  // Dynamically loaded bundled fonts from assets/fonts/
  static Map<String, String>? _bundledFontFiles;
  
  // System fonts on Android
  static const _androidSystemFonts = [
    'Roboto',
    'Noto Sans',
    'Droid Sans',
  ];
  
  /// Load bundled fonts from asset manifest at runtime
  /// Maps font display name to filename (e.g., 'Montserrat' -> 'Montserrat-Regular.ttf')
  static Future<Map<String, String>> _loadBundledFontFiles() async {
    if (_bundledFontFiles != null) return _bundledFontFiles!;
    
    final fonts = <String, String>{};
    
    try {
      // Use Flutter's AssetManifest API (works with both old and new Flutter)
      final assetManifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final allAssets = assetManifest.listAssets();
      
      // Find all TTF files in assets/fonts/
      for (final assetPath in allAssets) {
        if (assetPath.startsWith('assets/fonts/') && assetPath.endsWith('.ttf')) {
          final filename = assetPath.split('/').last;
          // Convert filename to display name
          // e.g., 'Montserrat-Regular.ttf' -> 'Montserrat'
          // e.g., 'Montserrat-Bold.ttf' -> 'Montserrat Bold'
          // e.g., 'BebasNeue-Regular.ttf' -> 'Bebas Neue'
          final displayName = _filenameToDisplayName(filename);
          fonts[displayName] = filename;
          debugPrint('[FONTS] Found bundled font: $displayName ($filename)');
        }
      }
    } catch (e) {
      debugPrint('[FONTS] Error loading asset manifest: $e');
    }
    
    // Fallback: If no fonts found from manifest, use known bundled fonts
    if (fonts.isEmpty) {
      debugPrint('[FONTS] Using fallback font list');
      fonts.addAll({
        'Montserrat Fallback': 'Montserrat-Regular.ttf',
      });
    }
    
    _bundledFontFiles = fonts;
    return fonts;
  }
  
  /// Convert font filename to display name
  /// e.g., 'Montserrat-Regular.ttf' -> 'Montserrat'
  /// e.g., 'Montserrat-Bold.ttf' -> 'Montserrat Bold'
  /// e.g., 'BebasNeue-Regular.ttf' -> 'Bebas Neue'
  static String _filenameToDisplayName(String filename) {
    // Remove .ttf extension
    var name = filename.replaceAll('.ttf', '');
    
    // Split by hyphen to get base name and variant
    final parts = name.split('-');
    var baseName = parts[0];
    final variant = parts.length > 1 ? parts[1] : '';
    
    // Add spaces before capital letters (CamelCase to spaces)
    // e.g., 'BebasNeue' -> 'Bebas Neue'
    baseName = baseName.replaceAllMapped(
      RegExp(r'([a-z])([A-Z])'),
      (match) => '${match.group(1)} ${match.group(2)}'
    );
    
    // Add variant if not "Regular"
    if (variant.isNotEmpty && variant.toLowerCase() != 'regular') {
      return '$baseName $variant';
    }
    
    return baseName;
  }
  
  /// Copy bundled fonts to app's files directory for FFmpeg access
  /// Returns the directory path where fonts are copied
  static Future<String> copyBundledFontsToAppDirectory() async {
    if (_bundledFontsDirectory != null) return _bundledFontsDirectory!;
    
    final fontFiles = await _loadBundledFontFiles();
    
    final appDir = await getApplicationDocumentsDirectory();
    final fontsDir = Directory('${appDir.path}/fonts');
    
    if (!await fontsDir.exists()) {
      await fontsDir.create(recursive: true);
    }
    
    // Copy each bundled font from assets to app directory
    for (final entry in fontFiles.entries) {
      final fontFile = File('${fontsDir.path}/${entry.value}');
      if (!await fontFile.exists()) {
        try {
          final data = await rootBundle.load('assets/fonts/${entry.value}');
          await fontFile.writeAsBytes(data.buffer.asUint8List());
          debugPrint('[FONTS] Copied ${entry.key} to ${fontFile.path}');
        } catch (e) {
          debugPrint('[FONTS] Error copying ${entry.key}: $e');
        }
      }
    }
    
    _bundledFontsDirectory = fontsDir.path;
    return _bundledFontsDirectory!;
  }
  
  /// Get the bundled fonts directory (or null if not initialized)
  static String? get bundledFontsDirectory => _bundledFontsDirectory;
  
  /// Get available fonts (platform-appropriate for video rendering)
  static Future<List<String>> getAvailableFonts() async {
    if (_cachedFonts != null) return _cachedFonts!;
    
    // Ensure bundled fonts are loaded
    final bundledFonts = await _loadBundledFontFiles();
    
    final fonts = <String>{};
    
    if (Platform.isAndroid || Platform.isIOS) {
      // Android system fonts that work with FFmpeg
      fonts.addAll(_androidSystemFonts);
      // Bundled Google Fonts (we copy these to app directory for FFmpeg)
      fonts.addAll(bundledFonts.keys);
    } else {
      // Desktop: Get System Fonts
      try {
        final systemFonts = SystemFonts().getFontList();
        fonts.addAll(systemFonts);
      } catch (e) {
        debugPrint('Error loading system fonts: $e');
        fonts.addAll(['Roboto', 'sans-serif', 'serif', 'monospace']);
      }
      
      // Add bundled fonts for desktop too (Set prevents duplicates)
      fonts.addAll(bundledFonts.keys);
    }
    
    _cachedFonts = fonts.toList()..sort();
    return _cachedFonts!;
  }
  
  /// Get the font file name for a bundled font (for FFmpeg font mapping)
  static String? getBundledFontFile(String fontName) {
    return _bundledFontFiles?[fontName];
  }
  
  /// Get the last used font, or default
  static Future<String> getLastUsedFont() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastFontKey) ?? _defaultFont;
  }
  
  /// Save the last used font
  static Future<void> saveLastUsedFont(String fontFamily) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastFontKey, fontFamily);
  }
  
  /// Clear the cached fonts
  static void clearCache() {
    _cachedFonts = null;
    _bundledFontFiles = null;
  }

  /// Whether a font is a Google Font (for UI rendering in Flutter)
  /// Checks if font is in our bundled fonts
  static bool isGoogleFont(String fontName) {
    return _bundledFontFiles?.containsKey(fontName) ?? false;
  }
}
