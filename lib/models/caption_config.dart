import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Style configuration for a single language's captions
class LanguageStyle {
  final String fontFamily;
  final double fontSize; // As percentage of video height
  final Color color;
  final double verticalPosition; // As percentage from top (0-100)
  final double borderWidth; // Outline thickness for ASS subtitles

  const LanguageStyle({
    this.fontFamily = 'Roboto',
    this.fontSize = 5.0,
    this.color = Colors.white,
    this.verticalPosition = 85.0, // Default near bottom
    this.borderWidth = 4.0,
  });

  LanguageStyle copyWith({
    String? fontFamily,
    double? fontSize,
    Color? color,
    double? verticalPosition,
    double? borderWidth,
  }) {
    return LanguageStyle(
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      color: color ?? this.color,
      verticalPosition: verticalPosition ?? this.verticalPosition,
      borderWidth: borderWidth ?? this.borderWidth,
    );
  }

  Map<String, dynamic> toJson() => {
    'fontFamily': fontFamily,
    'fontSize': fontSize,
    'color': color.value,
    'verticalPosition': verticalPosition,
    'borderWidth': borderWidth,
  };

  factory LanguageStyle.fromJson(Map<String, dynamic> json) => LanguageStyle(
    fontFamily: json['fontFamily'] as String? ?? 'Roboto',
    fontSize: (json['fontSize'] as num?)?.toDouble() ?? 5.0,
    color: Color(json['color'] as int? ?? 0xFFFFFFFF),
    verticalPosition: (json['verticalPosition'] as num?)?.toDouble() ?? 85.0,
    borderWidth: (json['borderWidth'] as num?)?.toDouble() ?? 4.0,
  );
}

class CaptionConfig {
  final String originalLanguage;
  final List<String> targetLanguages;
  final Map<String, LanguageStyle> languageStyles; // Per-language styles

  const CaptionConfig({
    required this.originalLanguage,
    required this.targetLanguages,
    this.languageStyles = const {},
  });

  /// Get style for a language, with fallback to default
  LanguageStyle getStyleForLanguage(String langCode) {
    return languageStyles[langCode] ?? const LanguageStyle();
  }

  CaptionConfig copyWith({
    String? originalLanguage,
    List<String>? targetLanguages,
    Map<String, LanguageStyle>? languageStyles,
  }) {
    return CaptionConfig(
      originalLanguage: originalLanguage ?? this.originalLanguage,
      targetLanguages: targetLanguages ?? this.targetLanguages,
      languageStyles: languageStyles ?? this.languageStyles,
    );
  }

  /// Commonly supported languages for AssemblyAI
  static const supportedLanguages = {
    'en': 'English',
    'pt': 'Portuguese',
    'es': 'Spanish',
    'fr': 'French',
    'de': 'German',
    'it': 'Italian',
    'ja': 'Japanese',
    'ko': 'Korean',
    'zh': 'Chinese',
    'ru': 'Russian',
    'ar': 'Arabic',
    'hi': 'Hindi',
    'vi': 'Vietnamese',
    'th': 'Thai',
    'id': 'Indonesian'
  };

  /// Available fonts for captions
  static const availableFonts = [
    'Roboto',
    'Arial',
    'Helvetica',
    'Open Sans',
    'Lato',
    'Montserrat',
    'Source Sans Pro',
    'Noto Sans',
  ];

  /// Default preset colors for captions
  static const defaultColors = [
    Color.fromARGB(255, 0, 214, 255), // Cyan
    Color.fromARGB(255, 255, 18, 99), // Red/Pink
    Colors.white,
    Colors.yellow,
    Colors.amber,
    Colors.lime,
    Colors.orange
  ];

  /// Mutable color list (can be overridden by saved custom colors)
  static List<Color> availableColors = List.from(defaultColors);

  static String getLanguageName(String code) {
    return supportedLanguages[code] ?? code;
  }

  /// Convert Color to ASS hex format (&HAABBGGRR)
  static String colorToAssHex(Color color) {
    final r = color.red.toRadixString(16).padLeft(2, '0');
    final g = color.green.toRadixString(16).padLeft(2, '0');
    final b = color.blue.toRadixString(16).padLeft(2, '0');
    // ASS uses BBGGRR format (reversed)
    return '&H00$b$g$r'.toUpperCase();
  }

  // ========== Persistence Methods ==========

  static const _prefsKeyOriginalLang = 'captioner_original_language';
  static const _prefsKeySelectedLangs = 'captioner_selected_languages';
  static const _prefsKeyStyles = 'captioner_language_styles';
  static const _prefsKeyCustomColors = 'captioner_custom_colors';

  /// Save custom color palette to SharedPreferences
  static Future<void> saveCustomColors(List<Color> colors) async {
    final prefs = await SharedPreferences.getInstance();
    final colorValues = colors.map((c) => c.value.toString()).toList();
    await prefs.setStringList(_prefsKeyCustomColors, colorValues);
    availableColors = List.from(colors);
  }

  /// Load custom color palette from SharedPreferences
  static Future<void> loadCustomColors() async {
    final prefs = await SharedPreferences.getInstance();
    final colorValues = prefs.getStringList(_prefsKeyCustomColors);
    if (colorValues != null && colorValues.isNotEmpty) {
      availableColors = colorValues
          .map((v) => Color(int.parse(v)))
          .toList();
    } else {
      availableColors = List.from(defaultColors);
    }
  }

  /// Save settings to SharedPreferences
  static Future<void> saveSettings({
    required String originalLanguage,
    required Set<String> selectedLanguages,
    required Map<String, LanguageStyle> languageStyles,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    
    await prefs.setString(_prefsKeyOriginalLang, originalLanguage);
    await prefs.setStringList(_prefsKeySelectedLangs, selectedLanguages.toList());
    
    // Save styles as JSON
    final stylesJson = <String, dynamic>{};
    for (final entry in languageStyles.entries) {
      stylesJson[entry.key] = entry.value.toJson();
    }
    await prefs.setString(_prefsKeyStyles, jsonEncode(stylesJson));
  }

  /// Load settings from SharedPreferences
  static Future<SavedSettings?> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    if (!prefs.containsKey(_prefsKeyOriginalLang)) {
      return null; // No saved settings
    }
    
    final originalLang = prefs.getString(_prefsKeyOriginalLang) ?? 'pt';
    final selectedLangs = prefs.getStringList(_prefsKeySelectedLangs) ?? ['pt', 'en'];
    
    Map<String, LanguageStyle> styles = {};
    final stylesJson = prefs.getString(_prefsKeyStyles);
    if (stylesJson != null) {
      final decoded = jsonDecode(stylesJson) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        styles[entry.key] = LanguageStyle.fromJson(entry.value as Map<String, dynamic>);
      }
    }
    
    return SavedSettings(
      originalLanguage: originalLang,
      selectedLanguages: selectedLangs.toSet(),
      languageStyles: styles,
    );
  }
}

/// Container for saved settings
class SavedSettings {
  final String originalLanguage;
  final Set<String> selectedLanguages;
  final Map<String, LanguageStyle> languageStyles;

  SavedSettings({
    required this.originalLanguage,
    required this.selectedLanguages,
    required this.languageStyles,
  });
}
