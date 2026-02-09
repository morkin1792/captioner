import 'dart:io';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:android_intent_plus/android_intent.dart';
import '../services/storage_service.dart';
import '../services/log_service.dart';
import '../services/assemblyai_service.dart';
import '../services/gemini_service.dart';
import '../services/ffmpeg_service.dart';
import '../services/font_service.dart';
import '../models/caption_config.dart';
import '../models/subtitle.dart';
import 'setup_screen.dart';
import 'caption_editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // Step tracking (0-5 for 6 steps)
  int _currentStep = 0;
  
  // Video state
  String? _videoPath;
  VideoPlayerController? _videoController;
  bool _isPlaying = false;
  
  // Language settings
  String _originalLanguage = 'pt';
  Set<String> _selectedLanguages = {'pt', 'en'};
  
  // Transcription cache
  String? _cachedVideoPath;
  List<Subtitle>? _cachedTranscription;
  List<Map<String, dynamic>>? _cachedRawWords;
  Map<String, List<Subtitle>>? _cachedTranslations;
  Set<String>? _cachedLanguages;
  
  // Edited subtitles (after review step)
  Map<String, List<Subtitle>>? _editedSubtitles;
  
  // Caption style (per-language)
  Map<String, LanguageStyle> _languageStyles = {};
  String? _selectedStyleLanguage; // specific language code (first language by default)
  
  // Processing state
  bool _processing = false;
  String _processingStatus = '';
  double _processingProgress = 0.0;
  String? _outputPath;
  
  // Resolution setting for rendering
  String _selectedResolution = '1080p'; // Default to 1080p
  int? _videoWidth;
  int? _videoHeight;
  
  // Segmentation setting (characters per caption segment)
  int _charsPerSegment = 25;
  
  // System fonts
  List<String> _systemFonts = ['Roboto'];
  bool _fontsLoaded = false;
  
  // Export captions preference
  bool _exportCaptionsOnRender = false;
  
  // Auto-load SRT files when video is loaded
  bool _autoLoadSrt = false;
  
  // Translation toggle (requires Gemini API key)
  bool _useTranslation = true; // Default to true if key is available
  bool _hasGeminiKey = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clearCacheOnStart();
    _loadSavedSettings();
    _loadSystemFonts();
  }

  /// Clear any leftover video cache from previous sessions
  Future<void> _clearCacheOnStart() async {
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await FilePicker.platform.clearTemporaryFiles();
        LogService.log('[CACHE] Cleared video cache on app start');
      } catch (e) {
        LogService.log('[CACHE] Error clearing cache: $e');
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Clean cache when app is being closed
    if (state == AppLifecycleState.detached) {
      _clearCacheOnStart(); // Reuse the same cleanup method
    }
  }

  Future<void> _loadSavedSettings() async {
    // Load custom color palette
    await CaptionConfig.loadCustomColors();
    
    final saved = await CaptionConfig.loadSettings();
    if (saved != null) {
      setState(() {
        _originalLanguage = saved.originalLanguage;
        _selectedLanguages = saved.selectedLanguages;
        _languageStyles = Map.from(saved.languageStyles);
      });
    }
    
    // Load export preference (default to true for first-time users)
    final prefs = await SharedPreferences.getInstance();
    
    // Check if Gemini key is available
    final storage = context.read<StorageService>();
    final hasGemini = await storage.hasGeminiKey();
    
    setState(() {
      _exportCaptionsOnRender = prefs.getBool('exportCaptionsOnRender') ?? true;
      _charsPerSegment = prefs.getInt('charsPerSegment') ?? 25;
      _autoLoadSrt = prefs.getBool('autoLoadSrt') ?? false;
      _hasGeminiKey = hasGemini;
      _useTranslation = hasGemini; // Default to true only if key is available
    });
  }

  Future<void> _loadSystemFonts() async {
    final fonts = await FontService.getAvailableFonts();
    final lastFont = await FontService.getLastUsedFont();
    
    // Use the first available font as default if no font was previously saved
    final defaultFont = fonts.isNotEmpty ? fonts.first : lastFont;
    
    setState(() {
      _systemFonts = fonts;
      _fontsLoaded = true;
      
      // Apply last used font (or first available) to any language that doesn't have a custom font
      if (_languageStyles.isEmpty && _selectedLanguages.isNotEmpty) {
        for (final lang in _selectedLanguages) {
          _languageStyles[lang] = LanguageStyle(fontFamily: lastFont != 'Roboto' ? lastFont : defaultFont);
        }
      }
    });
  }

  Future<void> _saveSettings() async {
    await CaptionConfig.saveSettings(
      originalLanguage: _originalLanguage,
      selectedLanguages: _selectedLanguages,
      languageStyles: _languageStyles,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _videoController?.dispose();
    super.dispose();
  }

  bool _isDragging = false;

  /// Handle dropped video file (desktop only)
  Future<void> _handleDroppedVideo(DropDoneDetails details) async {
    // Only accept drops on step 0
    if (_currentStep != 0) return;
    
    if (details.files.isEmpty) return;
    
    final file = details.files.first;
    final filePath = file.path;
    
    // Check if it's a video file
    final ext = path.extension(filePath).toLowerCase();
    const videoExtensions = ['.mp4', '.mov', '.avi', '.mkv', '.webm', '.m4v'];
    if (!videoExtensions.contains(ext)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please drop a video file (mp4, mov, avi, mkv, webm)')),
      );
      return;
    }
    
    // Clear cache if video changed
    if (_cachedVideoPath != filePath) {
      _cachedTranscription = null;
      _cachedTranslations = null;
      _editedSubtitles = null;
    }
    
    try {
      await _initializeVideoPlayer(filePath);
      setState(() {
        _videoPath = filePath;
        _cachedVideoPath = filePath;
        _currentStep = 1; // Move to next step
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading video: $e')),
      );
    }
  }

  Future<void> _pickVideo() async {
    // Show loading dialog while file picker works (on mobile, files are copied to cache)
    if (Platform.isAndroid || Platform.isIOS) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 24),
              Expanded(child: Text('Preparing video file...\nThis may take a moment for large files.')),
            ],
          ),
        ),
      );
    }

    try {
      // Clear previous video cache before picking new one (single-video strategy)
      if (Platform.isAndroid || Platform.isIOS) {
        await FilePicker.platform.clearTemporaryFiles();
        LogService.log('[CACHE] Cleared previous video cache');
      }

      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: false,
      );

      // Dismiss loading dialog on mobile
      if ((Platform.isAndroid || Platform.isIOS) && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }

      if (result != null && result.files.isNotEmpty) {
        final selectedPath = result.files.first.path!;
        
        // Show loading while video initializes
        if (Platform.isAndroid || Platform.isIOS) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => const AlertDialog(
              content: Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 24),
                  Text('Loading video...'),
                ],
              ),
            ),
          );
        }
        
        // Check if video changed - if so, clear cache
        if (_cachedVideoPath != selectedPath) {
          _cachedTranscription = null;
          _cachedTranslations = null;
          _editedSubtitles = null;
        }
        
        try {
          await _initializeVideoPlayer(selectedPath);
          
          // Dismiss loading dialog
          if ((Platform.isAndroid || Platform.isIOS) && mounted) {
            Navigator.of(context, rootNavigator: true).pop();
          }
          
          setState(() {
            _videoPath = selectedPath;
            _currentStep = 1;
          });
        } catch (e, stack) {
          // Dismiss loading dialog on error
          if ((Platform.isAndroid || Platform.isIOS) && mounted) {
            Navigator.of(context, rootNavigator: true).pop();
          }
          stderr.writeln('[ERROR] Error loading video: $e\n$stack');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error loading video: $e')),
            );
          }
        }
      }
    } catch (e) {
      // Dismiss loading dialog on error
      if ((Platform.isAndroid || Platform.isIOS) && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error picking file: $e')),
        );
      }
    }
  }

  Future<void> _initializeVideoPlayer(String path) async {
    final controller = VideoPlayerController.file(File(path));
    await controller.initialize();
    if (mounted) {
      setState(() {
        _videoController?.dispose();
        _videoController = controller;
        // Capture video dimensions for resolution selector
        _videoWidth = controller.value.size.width.toInt();
        _videoHeight = controller.value.size.height.toInt();
      });
    }
  }


  Future<void> _runTranscription() async {
    if (_videoPath == null) return;
    
    // Check if we can use cached transcription
    if (_cachedVideoPath == _videoPath && _cachedTranscription != null) {
      bool needTranslation = false;
      if (_useTranslation) {
        // Check if any selected language (other than original) is missing from cache
        final missingLangs = _selectedLanguages
            .where((l) => l != _originalLanguage)
            .where((l) => _cachedTranslations == null || !_cachedTranslations!.containsKey(l));
        if (missingLangs.isNotEmpty) {
          needTranslation = true;
        }
      }

      // If we don't need translation AND the language selection hasn't changed (or we just don't want translations)
      // we can skip to the review step.
      if (!needTranslation) {
        if (_cachedLanguages != null && 
            _cachedLanguages!.difference(_selectedLanguages).isEmpty &&
            _selectedLanguages.difference(_cachedLanguages!).isEmpty) {
          // Same video and same languages - skip to step 3
          setState(() => _currentStep = 3);
          return;
        }
      }
    }

    setState(() {
      _processing = true;
      _processingProgress = 0.0;
      _processingStatus = 'Initializing...';
    });
    
    await WakelockPlus.enable();

    try {
      final storage = context.read<StorageService>();
      final assemblyAiKey = await storage.getAssemblyAiKey();
      // Gemini key is fetched later if needed

      if (assemblyAiKey == null) {
        throw Exception('AssemblyAI API key not found. Please set it in Settings.');
      }

      // Step 1: Transcribe (only if video changed)
      if (_cachedVideoPath != _videoPath || _cachedTranscription == null) {
        setState(() => _processingStatus = 'Extracting audio...');
        final assemblyAi = AssemblyAiService(assemblyAiKey);
        final result = await assemblyAi.transcribe(
          filePath: _videoPath!,
          languageCode: _originalLanguage,
          maxCharsPerSegment: _charsPerSegment,
          onStatus: (status) {
            setState(() => _processingStatus = status);
          },
          onProgress: (progress) {
            // Transcription is 0-30% of total progress
            setState(() => _processingProgress = progress * 0.3);
          },
        );
        
        _cachedVideoPath = _videoPath;
        _cachedTranscription = result.subtitles;
        _cachedRawWords = result.rawWords;
        setState(() => _processingProgress = 0.3);
      }

      // Step 2: Translate to other languages (only if enabled)
      final allSubtitles = <String, List<Subtitle>>{};
      allSubtitles[_originalLanguage] = _cachedTranscription!;

      if (_useTranslation) {
        final geminiKey = await storage.getGeminiKey();
        if (geminiKey == null) {
           // Should not happen if _useTranslation is true, but good safety
           throw Exception('Gemini API key is missing but translation was requested.');
        }
        
        final gemini = GeminiService(geminiKey);
        final otherLanguages = _selectedLanguages.where((l) => l != _originalLanguage).toList();
  
        for (var i = 0; i < otherLanguages.length; i++) {
          final lang = otherLanguages[i];
          
          // Check if we already have this translation cached
          if (_cachedTranslations != null && _cachedTranslations!.containsKey(lang)) {
            allSubtitles[lang] = _cachedTranslations![lang]!;
            continue;
          }
          
          setState(() {
            _processingStatus = 'Translating to ${CaptionConfig.getLanguageName(lang)}...';
          });
  
          final translated = await gemini.translateSubtitles(
            subtitles: _cachedTranscription!,
            sourceLanguage: CaptionConfig.getLanguageName(_originalLanguage),
            targetLanguage: CaptionConfig.getLanguageName(lang),
            onProgress: (p) {
              setState(() {
                _processingProgress = 0.3 + (0.6 * (i + p) / otherLanguages.length);
              });
            },
          );
          allSubtitles[lang] = translated;
        }
      } else {
        // If translation is disabled, we only have the original language
        // Only include the original language subtitles
      }

      // Cache everything
      _cachedTranslations = Map.from(allSubtitles);
      _cachedLanguages = Set.from(_selectedLanguages);
      
      setState(() {
        _editedSubtitles = Map.from(allSubtitles);
        _processing = false;
        _processingProgress = 1.0;
        _currentStep++;
      });
    } catch (e) {
      setState(() {
        _processing = false;
        _processingStatus = 'Error: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      await WakelockPlus.disable();
    }
  }

  Future<void> _reSegmentAndRetranslate() async {
    if (_cachedRawWords == null) return;

    setState(() {
      _processing = true;
      _processingProgress = 0.0;
      _processingStatus = 'Re-segmenting...';
    });

    try {
      final storage = context.read<StorageService>();
      final geminiKey = await storage.getGeminiKey();
      if (geminiKey == null) throw Exception('Gemini key not found');

      // 1. Re-segment original language
      final newOriginalSubs = AssemblyAiService.createSubtitlesFromWords(
        _cachedRawWords!, 
        _charsPerSegment
      );
      _cachedTranscription = newOriginalSubs;
      
      // 2. Clear translation cache for this video since segmentation changed
      _cachedTranslations = {_originalLanguage: newOriginalSubs};

      // 3. Re-translate to all selected languages
      final gemini = GeminiService(geminiKey);
      final otherLanguages = _selectedLanguages.where((l) => l != _originalLanguage).toList();

      for (var i = 0; i < otherLanguages.length; i++) {
        final lang = otherLanguages[i];
        
        setState(() {
          _processingStatus = 'Translating to ${CaptionConfig.getLanguageName(lang)}...';
        });

        final translated = await gemini.translateSubtitles(
          subtitles: newOriginalSubs,
          sourceLanguage: CaptionConfig.getLanguageName(_originalLanguage),
          targetLanguage: CaptionConfig.getLanguageName(lang),
          onProgress: (p) {
            setState(() {
              _processingProgress = (i + p) / otherLanguages.length;
            });
          },
        );
        _cachedTranslations![lang] = translated;
      }

      setState(() {
        _editedSubtitles = Map.from(_cachedTranslations!);
        _processing = false;
        _processingProgress = 1.0;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Captions updated with new segmentation')),
      );
    } catch (e) {
      setState(() {
        _processing = false;
        _processingStatus = 'Error: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _renderVideo() async {
    if (_editedSubtitles == null || _videoPath == null) return;

    // Desktop & Mobile: Full video rendering
    setState(() {
      _processing = true;
      _processingProgress = 0.0;
      _processingStatus = 'Generating subtitles...';
    });
    
    await WakelockPlus.enable();

    // Dispose video controller to free up hardware resources for FFmpeg
    // This is critical for 4K rendering on Android to avoid buffer/codec exhaustion
    if (_videoController != null) {
      await _videoController!.dispose();
      setState(() {
        _videoController = null;
      });
    }

    try {
      final ffmpeg = FfmpegService();
      // On mobile, FFmpegKit will handle this. On desktop, system ffmpeg.
      final dimensions = await ffmpeg.getVideoDimensions(_videoPath!);

      final config = CaptionConfig(
        originalLanguage: _originalLanguage,
        targetLanguages: _selectedLanguages.toList(),
        languageStyles: _languageStyles,
      );

      // Generate ASS with all languages
      final assContent = ffmpeg.generateMultiLanguageAssSubtitle(
        subtitlesByLanguage: _editedSubtitles!,
        config: config,
        videoWidth: dimensions.width,
        videoHeight: dimensions.height,
      );

      final tempDir = await getTemporaryDirectory();
      final assPath = '${tempDir.path}/subtitles.ass';
      await File(assPath).writeAsString(assContent);

      setState(() => _processingStatus = 'Rendering video...');
      final inputName = path.basenameWithoutExtension(_videoPath!);
      final outputDir = path.dirname(_videoPath!);
      final outputPath = '$outputDir/${inputName}_captioned.mp4';

      final success = await ffmpeg.burnSubtitles(
        inputVideo: _videoPath!,
        outputVideo: outputPath,
        assSubtitlePath: assPath,
        targetResolution: _selectedResolution,
        onProgress: (p) {
          setState(() {
            _processingProgress = 0.2 + (0.8 * p);
          });
        },
      );

      if (success) {
        // On mobile, copy to Downloads folder for easy access
        String finalPath = outputPath;
        if (Platform.isAndroid) {
          try {
            final downloadsDir = Directory('/storage/emulated/0/Download');
            if (await downloadsDir.exists()) {
              final fileName = path.basename(outputPath);
              final downloadsPath = '${downloadsDir.path}/$fileName';
              await File(outputPath).copy(downloadsPath);
              finalPath = downloadsPath;
              LogService.log('[SAVE] Video saved to Downloads: $finalPath');
            }
          } catch (e) {
            LogService.log('[SAVE] Could not copy to Downloads: $e');
            // Fall back to cache path
          }
        }
        
        setState(() {
          _outputPath = finalPath;
          _processingStatus = 'Complete!';
          _processingProgress = 1.0;
          _processing = false;
        });
        
        // Export SRT files if checkbox is enabled
        if (_exportCaptionsOnRender) {
          await _exportCaptionsToSrt(showNotification: false);
        }
      } else {
        throw Exception('Video rendering failed');
      }
    } catch (e, stack) {
      LogService.log('RENDER ERROR: $e\n$stack');
      setState(() {
        _processingStatus = 'Error: $e';
        _processing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      // Re-initialize video player after rendering (to restore preview)
      if (_videoPath != null && mounted) {
         // Optimization: We disposed the controller to free resources for FFmpeg
         // Now we need to bring it back.
         try {
           await _initializeVideoPlayer(_videoPath!);
         } catch (e) {
           LogService.log('Error re-initializing player: $e');
         }
      }
      await WakelockPlus.disable();
    }

  }


  Future<void> _resetCaptions() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Captions?'),
        content: const Text(
          'This will discard all your edits and restore the original captions from the transcription. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed == true && _cachedTranslations != null) {
      setState(() {
        // Deep copy from cached translations
        _editedSubtitles = {};
        for (final entry in _cachedTranslations!.entries) {
          _editedSubtitles![entry.key] = entry.value.map((s) => s.copyWith()).toList();
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Captions reset to original')),
      );
    }
  }

  Future<void> _retranslate() async {
    if (_editedSubtitles == null) return;
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Retranslate Captions?'),
        content: Text(
          'This will re-translate all non-$_originalLanguage captions based on your edited ${CaptionConfig.getLanguageName(_originalLanguage)} captions. '
          'Your edits to translations will be replaced.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Retranslate'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _processing = true;
      _processingProgress = 0.0;
      _processingStatus = 'Retranslating...';
    });

    try {
      final storage = context.read<StorageService>();
      final geminiKey = await storage.getGeminiKey();

      if (geminiKey == null) {
        throw Exception('Gemini API key not found. Please set it in Settings.');
      }

      final gemini = GeminiService(geminiKey);
      final originalSubs = _editedSubtitles![_originalLanguage]!;
      
      // Get target languages: all selected languages except the original one
      // We use _selectedLanguages instead of _editedSubtitles.keys to ensure
      // that if translation was skipped, it's added now.
      final targetLanguages = _selectedLanguages
          .where((lang) => lang != _originalLanguage)
          .toList();

      int completed = 0;
      for (final targetLang in targetLanguages) {
        setState(() => _processingStatus = 'Translating to ${CaptionConfig.getLanguageName(targetLang)}...');
        
        final translated = await gemini.translateSubtitles(
          subtitles: originalSubs,
          sourceLanguage: _originalLanguage,
          targetLanguage: targetLang,
          onProgress: (p) {
            setState(() {
              _processingProgress = (completed + p) / targetLanguages.length;
            });
          },
        );
        
        // Replace the translation while preserving any custom timing edits
        _editedSubtitles![targetLang] = translated;
        completed++;
      }

      setState(() {
        _processingStatus = 'Done!';
        _processingProgress = 1.0;
        _processing = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Retranslation complete!')),
      );
    } catch (e) {
      setState(() {
        _processingStatus = 'Error: $e';
        _processing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _showImportSrtDialog() async {
    int importMode = 0; // 0: Auto, 1: Manual
    String? manualSrtPath;
    String manualLanguage = _originalLanguage;
    
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('Import SRT'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RadioListTile<int>(
                    title: const Text('Auto find SRT files'),
                    subtitle: const Text('Looks for "videoname.lang.srt" in the same folder'),
                    value: 0,
                    groupValue: importMode,
                    onChanged: (val) => setDialogState(() => importMode = val!),
                  ),
                  RadioListTile<int>(
                    title: const Text('Select SRT file manually'),
                    value: 1,
                    groupValue: importMode,
                    onChanged: (val) => setDialogState(() => importMode = val!),
                  ),
                  if (importMode == 1) ...[
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () async {
                              final result = await FilePicker.platform.pickFiles(
                                type: FileType.custom,
                                allowedExtensions: ['srt'],
                              );
                              if (result != null) {
                                setDialogState(() {
                                  manualSrtPath = result.files.single.path;
                                });
                              }
                            },
                            icon: const Icon(Icons.folder_open),
                            label: Text(manualSrtPath == null ? 'Select .srt File' : path.basename(manualSrtPath!)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: manualSrtPath == null ? null : Colors.green,
                            ),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            value: manualLanguage,
                            decoration: const InputDecoration(
                              labelText: 'Language',
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            items: CaptionConfig.supportedLanguages.entries.map((e) {
                              return DropdownMenuItem(value: e.key, child: Text(e.value));
                            }).toList(),
                            onChanged: (val) => setDialogState(() => manualLanguage = val!),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  if (importMode == 1 && manualSrtPath == null) {
                    return; // Verify file selected
                  }
                  Navigator.pop(context); // Close dialog first to avoid context issues
                  if (importMode == 0) {
                    _autoImportSrt();
                  } else {
                    _importSrtManual(manualSrtPath!, manualLanguage);
                  }
                },
                child: const Text('Import'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<int> _autoImportSrt() async {
    if (_videoPath == null) return 0;
    
    setState(() => _processingStatus = 'Searching for SRT files...');

    try {
      final videoName = path.basenameWithoutExtension(_videoPath!);
      Directory searchDir;
      if (Platform.isAndroid) {
        searchDir = Directory('/storage/emulated/0/Download');
      } else {
        searchDir = Directory(path.dirname(_videoPath!));
      }

      if (!await searchDir.exists()) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Directory not found for auto-import.')),
        );
        return 0;
      }

      int importedCount = 0;
      final files = searchDir.listSync();
      
      for (var f in files) {
        if (f is File && f.path.endsWith('.srt')) {
          final filename = path.basename(f.path);
          // Check pattern: videoName.lang.srt
          if (filename.startsWith('$videoName.')) {
            // Extract language code
            // format: name.CODE.srt
            final parts = filename.split('.');
            if (parts.length >= 3) {
              final langCode = parts[parts.length - 2];
              if (CaptionConfig.supportedLanguages.containsKey(langCode)) {
                await _importSrtFile(f.path, langCode);
                importedCount++;
              }
            }
          }
        }
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported $importedCount SRT files.')),
      );
      return importedCount;
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error auto-importing: $e'), backgroundColor: Colors.red),
      );
      return 0;
    }
  }

  Future<void> _importSrtManual(String path, String language) async {
    try {
      await _importSrtFile(path, language);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported subtitles for ${CaptionConfig.getLanguageName(language)}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error importing SRT: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _importSrtFile(String filePath, String language) async {
    final file = File(filePath);
    final content = await file.readAsString();
    final subtitles = _parseSrt(content);
    
    setState(() {
      _editedSubtitles ??= {};
      _editedSubtitles![language] = subtitles;
      
      // Also add to select languages if not present
      if (!_selectedLanguages.contains(language)) {
        _selectedLanguages.add(language);
      }
    });
  }

  List<Subtitle> _parseSrt(String content) {
    final subs = <Subtitle>[];
    // Check for CRLF and normalize
    final lines = content.replaceAll('\r\n', '\n').split('\n');
    
    int index = 0;
    while (index < lines.length) {
      final line = lines[index].trim();
      
      if (line.isEmpty) {
        index++;
        continue;
      }

      // 1. Index number (we can ignore it, but let's check it looks like a number)
      if (int.tryParse(line) != null) {
        index++; // Move to timestamp line
        if (index >= lines.length) break;
      }
      
      // 2. Timestamp: 00:00:00,000 --> 00:00:02,500
      final timeLine = lines[index].trim();
      if (!timeLine.contains('-->')) {
        // Not a valid timestamp line, maybe we are out of sync or it's not a standard SRT
        index++;
        continue;
      }
      
      final parts = timeLine.split('-->');
      final startMs = _parseSrtTime(parts[0].trim());
      final endMs = _parseSrtTime(parts[1].trim());
      
      index++; // Move to text
      
      // 3. Text content (can be multiple lines until empty line)
      String text = '';
      while (index < lines.length && lines[index].trim().isNotEmpty) {
        if (text.isNotEmpty) text += '\n';
        text += lines[index].trim();
        index++;
      }
      
      if (text.isNotEmpty) {
        subs.add(Subtitle(
          startMs: startMs,
          endMs: endMs,
          text: text,
        ));
      }
    }
    
    return subs;
  }

  int _parseSrtTime(String timestamp) {
    // 00:00:00,000
    try {
      final parts = timestamp.split(':');
      final h = int.parse(parts[0]);
      final m = int.parse(parts[1]);
      final sParts = parts[2].split(',');
      final s = int.parse(sParts[0]);
      final ms = int.parse(sParts[1]);
      return (h * 3600000) + (m * 60000) + (s * 1000) + ms;
    } catch (e) {
      LogService.log('Error parsing SRT time: $timestamp');
      return 0;
    }
  }

  /// Export captions to SRT files for YouTube
  Future<void> _exportCaptionsToSrt({bool showNotification = true}) async {
    if (_editedSubtitles == null || _videoPath == null) return;
    
    try {
      // Get video filename without extension
      final videoName = path.basenameWithoutExtension(_videoPath!);
      
      // Determine output directory
      late Directory outputDir;
      if (Platform.isAndroid) {
        outputDir = Directory('/storage/emulated/0/Download');
      } else {
        outputDir = Directory(path.dirname(_videoPath!));
      }
      
      final exportedFiles = <String>[];
      
      // Check for existing files first
      bool anyExist = false;
      for (final lang in _editedSubtitles!.keys) {
        final srtPath = '${outputDir.path}/$videoName.$lang.srt';
        if (await File(srtPath).exists()) {
          anyExist = true;
          break;
        }
      }

      if (anyExist && showNotification) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Overwrite SRT files?'),
            content: const Text('One or more SRT files already exist. Do you want to overwrite them?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Overwrite'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }
      
      for (final entry in _editedSubtitles!.entries) {
        final lang = entry.key;
        final subs = entry.value;
        
        // Create SRT content
        final buffer = StringBuffer();
        for (var i = 0; i < subs.length; i++) {
          final sub = subs[i];
          buffer.writeln('${i + 1}');
          buffer.writeln('${_formatSrtTime(sub.startMs)} --> ${_formatSrtTime(sub.endMs)}');
          buffer.writeln(sub.text);
          buffer.writeln();
        }
        
        // Save file: videoname.lang.srt
        final srtPath = '${outputDir.path}/$videoName.$lang.srt';
        await File(srtPath).writeAsString(buffer.toString());
        exportedFiles.add('$videoName.$lang.srt');
      }
      
      if (showNotification) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported: ${exportedFiles.join(", ")}')),
        );
      }
    } catch (e) {
      if (showNotification) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  String _formatSrtTime(int ms) {
    final hours = ms ~/ 3600000;
    final minutes = (ms % 3600000) ~/ 60000;
    final seconds = (ms % 60000) ~/ 1000;
    final millis = ms % 1000;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')},${millis.toString().padLeft(3, '0')}';
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SetupScreen(
          isSettings: true,
          onSetupComplete: () => Navigator.of(context).pop(),
        ),
      ),
    );
    _loadSavedSettings();
  }

  Future<void> _openOutputVideo() async {
    if (_outputPath == null) return;
    
    try {
      if (Platform.isLinux) {
        await Process.run('xdg-open', [_outputPath!]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [_outputPath!]);
      } else if (Platform.isWindows) {
        await Process.run('start', ['', _outputPath!], runInShell: true);
      } else if (Platform.isAndroid || Platform.isIOS) {
        // Use OpenFilex for 'Open with' system picker on mobile
        final result = await OpenFilex.open(_outputPath!);
        if (result.type != ResultType.done) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open file: ${result.message}')),
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error opening video: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Captioner'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
            tooltip: 'Settings',
          ),
        ],
      ),
      body: _buildBodyWithDropZone(colorScheme),
    );
  }

  Widget _buildBodyWithDropZone(ColorScheme colorScheme) {
    final mainContent = _processing
        ? _buildProcessingView(colorScheme)
        : _outputPath != null
            ? _buildCompleteView(colorScheme)
            : _buildStepperView(colorScheme);
    
    // Only enable full-window drop on desktop and step 0
    if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
      return mainContent;
    }
    
    return DropTarget(
      onDragDone: _handleDroppedVideo,
      onDragEntered: (_) {
        if (_currentStep == 0 && !_processing && _outputPath == null) {
          setState(() => _isDragging = true);
        }
      },
      onDragExited: (_) => setState(() => _isDragging = false),
      child: Stack(
        children: [
          mainContent,
          // Drag overlay - only show when dragging on step 0
          if (_isDragging && _currentStep == 0)
            Positioned.fill(
              child: Container(
                color: colorScheme.primaryContainer.withOpacity(0.9),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.video_file, size: 80, color: colorScheme.primary),
                      const SizedBox(height: 16),
                      Text(
                        'Drop video file here',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProcessingView(ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              value: _processingProgress > 0 ? _processingProgress : null,
            ),
            const SizedBox(height: 24),
            Text(
              _processingStatus,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              '${(_processingProgress * 100).toInt()}%',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: colorScheme.primary,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompleteView(ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, size: 80, color: Colors.green),
            const SizedBox(height: 24),
            Text(
              'Video Complete!',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 16),
            InkWell(
              onTap: _openOutputVideo,
              child: Text(
                _outputPath ?? '',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Click to play',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.outline,
                  ),
            ),
            // Show subtitles exported info if enabled
            if (_exportCaptionsOnRender) ...[
              const SizedBox(height: 24),
              const Icon(Icons.subtitles, size: 40, color: Colors.green),
              const SizedBox(height: 8),
              Text(
                'Subtitles exported',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 4),
              InkWell(
                onTap: () async {
                  if (Platform.isAndroid) {
                    // Use AndroidIntent to open Downloads folder
                    try {
                      const intent = AndroidIntent(
                        action: 'android.intent.action.VIEW',
                        data: 'content://com.android.externalstorage.documents/document/primary%3ADownload',
                        type: 'vnd.android.document/directory',
                      );
                      await intent.launch();
                    } catch (e) {
                      // Fallback: show snackbar if intent fails
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('SRT files saved to Downloads folder - open Files app to view'),
                          duration: Duration(seconds: 3),
                        ),
                      );
                    }
                  } else {
                    final dir = path.dirname(_videoPath ?? '');
                    if (Platform.isWindows) {
                      Process.run('explorer', [dir]);
                    } else if (Platform.isMacOS) {
                      Process.run('open', [dir]);
                    } else if (Platform.isLinux) {
                      Process.run('xdg-open', [dir]);
                    }
                  }
                },
                child: Text(
                  Platform.isAndroid ? 'Download folder' : path.dirname(_videoPath ?? ''),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Click to open',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.outline,
                    ),
              ),
            ],
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  _outputPath = null;
                  _videoPath = null;
                  _cachedTranscription = null;
                  _cachedTranslations = null;
                  _cachedVideoPath = null;
                  _editedSubtitles = null;
                  _currentStep = 0;
                });
              },
              icon: const Icon(Icons.add),
              label: const Text('Process Another Video'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _outputPath = null;
                  _currentStep = 4; // Go back to Style step
                });
              },
              icon: const Icon(Icons.edit),
              label: const Text('Return to Edit'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepperView(ColorScheme colorScheme) {
    return Stepper(
      currentStep: _currentStep,
      onStepContinue: _handleStepContinue,
      onStepCancel: () {
        if (_currentStep > 0) {
          setState(() => _currentStep--);
        }
      },
      onStepTapped: (step) {
        // Allow going back to previous steps
        if (step < _currentStep) {
          setState(() => _currentStep = step);
        }
      },
      controlsBuilder: (context, details) {
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Row(
            children: [
              ElevatedButton(
                onPressed: _canContinue() ? details.onStepContinue : null,
                child: Text(_getButtonText()),
              ),
              if (_currentStep > 0) ...[
                const SizedBox(width: 12),
                TextButton(
                  onPressed: details.onStepCancel,
                  child: const Text('Back'),
                ),
              ],
            ],
          ),
        );
      },
      steps: [
        Step(
          title: const Text('Select Video'),
          content: _buildVideoStep(colorScheme),
          isActive: _currentStep >= 0,
          state: _currentStep > 0 ? StepState.complete : StepState.indexed,
        ),
        Step(
          title: const Text('Languages'),
          content: _buildLanguageStep(colorScheme),
          isActive: _currentStep >= 1,
          state: _currentStep > 1 ? StepState.complete : StepState.indexed,
        ),
        Step(
          title: const Text('Transcribe'),
          content: _buildTranscribeStep(colorScheme),
          isActive: _currentStep >= 2,
          state: _currentStep > 2 ? StepState.complete : StepState.indexed,
        ),
        Step(
          title: const Text('Review Captions'),
          content: _buildReviewStep(colorScheme),
          isActive: _currentStep >= 3,
          state: _currentStep > 3 ? StepState.complete : StepState.indexed,
        ),
        Step(
          title: const Text('Caption Style'),
          content: _buildStyleStep(colorScheme),
          isActive: _currentStep >= 4,
          state: _currentStep > 4 ? StepState.complete : StepState.indexed,
        ),
        Step(
          title: const Text('Render'),
          content: _buildRenderStep(colorScheme),
          isActive: _currentStep >= 5,
          state: StepState.indexed,
        ),
      ],
    );
  }

  bool _canContinue() {
    switch (_currentStep) {
      case 0: return _videoPath != null;
      case 1: return _selectedLanguages.isNotEmpty;
      case 2: return true;
      case 3: return _editedSubtitles != null;
      case 4: return true;
      case 5: return true;
      default: return false;
    }
  }

  String _getButtonText() {
    switch (_currentStep) {
      case 2: 
        // Show 'Continue' if cached, otherwise 'Start Transcription'
        final hasCached = _cachedVideoPath == _videoPath && _cachedTranscription != null;
        return hasCached ? 'Continue' : 'Start Transcription';
      case 5: return 'Render Video';
      default: return 'Continue';
    }
  }

  Future<void> _handleStepContinue() async {
    switch (_currentStep) {
      case 1:
        // Languages step: check auto-load SRT
        if (_autoLoadSrt) {
          final count = await _autoImportSrt();
          if (count > 0) {
            setState(() => _currentStep = 3); // Skip to Review Captions
            return;
          }
        }
        setState(() => _currentStep++);
        break;
      case 2:
        _runTranscription();
        break;
      case 5:
        _renderVideo();
        break;
      default:
        if (_currentStep < 5) {
          setState(() => _currentStep++);
        }
    }
  }

  Widget _buildVideoStep(ColorScheme colorScheme) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_videoPath != null) ...[
          Card(
            child: ListTile(
              leading: Icon(Icons.video_file, color: colorScheme.primary),
              title: Text(path.basename(_videoPath!)),
              subtitle: Text(path.dirname(_videoPath!)),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _videoPath = null;
                  _cachedTranscription = null;
                  _cachedTranslations = null;
                }),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        OutlinedButton.icon(
          onPressed: _pickVideo,
          icon: const Icon(Icons.folder_open),
          label: Text(_videoPath == null ? 'Select Video File' : 'Change Video'),
        ),
        // Drag and drop hint for desktop
        if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) ...[
          const SizedBox(height: 16),
          Text(
            'Or drag and drop a video file here',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );

    return content;
  }

  Widget _buildLanguageStep(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Original Language (spoken in video)',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: _originalLanguage,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          items: CaptionConfig.supportedLanguages.entries.map((e) {
            return DropdownMenuItem(value: e.key, child: Text(e.value));
          }).toList(),
          onChanged: (value) {
            if (value != null) {
              setState(() => _originalLanguage = value);
              _saveSettings();
            }
          },
        ),
        const SizedBox(height: 24),
        Text('Caption Languages', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: CaptionConfig.supportedLanguages.entries.map((e) {
            final isSelected = _selectedLanguages.contains(e.key);
            return FilterChip(
              label: Text(e.value),
              selected: isSelected,
              onSelected: (selected) {
                setState(() {
                  if (selected) {
                    _selectedLanguages.add(e.key);
                  } else if (_selectedLanguages.length > 1) {
                    _selectedLanguages.remove(e.key);
                  }
                });
                _saveSettings();
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
        CheckboxListTile(
          title: const Text('Auto load SRT files'),
          subtitle: const Text('Import matching SRT files and skip to review'),
          value: _autoLoadSrt,
          onChanged: (val) async {
            setState(() => _autoLoadSrt = val ?? false);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('autoLoadSrt', _autoLoadSrt);
          },
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
        ),
      ],
    );
  }

  Widget _buildTranscribeStep(ColorScheme colorScheme) {
    final hasCached = _cachedVideoPath == _videoPath && _cachedTranscription != null;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      hasCached ? Icons.check_circle : Icons.pending,
                      color: hasCached ? Colors.green : colorScheme.outline,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        hasCached
                            ? 'Transcription cached (${_cachedTranscription!.length} segments)'
                            : 'Ready to transcribe',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                  ],
                ),
                if (hasCached) ...[
                  const SizedBox(height: 8),
                  Text(
                    'The transcription is already done. Click Continue to proceed or change the video to re-transcribe.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.outline,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: CheckboxListTile(
            title: const Text('Use Gemini API to translate captions'),
            subtitle: _hasGeminiKey 
                ? const Text('Uncheck to skip translation step')
                : Text(
                    'Gemini API key not set in Settings. Translation is disabled.',
                    style: TextStyle(color: colorScheme.error),
                  ),
            value: _useTranslation,
            onChanged: _hasGeminiKey 
                ? (value) => setState(() => _useTranslation = value ?? false)
                : null,
            secondary: Icon(
              Icons.translate,
              color: _useTranslation ? colorScheme.primary : Colors.grey,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReviewStep(ColorScheme colorScheme) {
    if (_editedSubtitles == null) {
      return const Text('Complete transcription first.');
    }

    final isMobile = Platform.isAndroid || Platform.isIOS;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Review and edit your captions. Tap "Edit Captions" to modify text and timing.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        // Words per segment setting - use Column on mobile for better fit
        if (isMobile)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('Max chars/caption:', style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(width: 12),
                  DropdownButton<int>(
                    value: _charsPerSegment,
                    items: [15, 20, 25, 30, 35, 40].map((n) => DropdownMenuItem(
                      value: n,
                      child: Text('$n chars'),
                    )).toList(),
                    onChanged: (value) async {
                      if (value != null && value != _charsPerSegment) {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Change Character Limit?'),
                            content: const Text(
                              'Changing the character limit will reconstruct all captions and DISCARD any manual edits. Translation will also be re-run.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel'),
                              ),
                              ElevatedButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Proceed'),
                              ),
                            ],
                          ),
                        );

                        if (confirmed == true) {
                          setState(() => _charsPerSegment = value);
                          // Persist the preference
                          SharedPreferences.getInstance().then((prefs) {
                            prefs.setInt('charsPerSegment', value);
                          });
                          _reSegmentAndRetranslate();
                        }
                      }
                    },
                  ),
                ],
              ),
              Text(
                'Updates all languages dynamically',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.outline,
                ),
              ),
            ],
          )
        else
          Row(
            children: [
              Text('Max chars/caption:', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(width: 12),
              DropdownButton<int>(
                value: _charsPerSegment,
                items: [15, 20, 25, 30, 35, 40].map((n) => DropdownMenuItem(
                  value: n,
                  child: Text('$n chars'),
                )).toList(),
                onChanged: (value) async {
                  if (value != null && value != _charsPerSegment) {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Change Character Limit?'),
                        content: const Text(
                          'Changing the character limit will reconstruct all captions and DISCARD any manual edits. Translation will also be re-run.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          ElevatedButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Proceed'),
                          ),
                        ],
                      ),
                    );

                    if (confirmed == true) {
                      setState(() => _charsPerSegment = value);
                      // Persist the preference
                      SharedPreferences.getInstance().then((prefs) {
                        prefs.setInt('charsPerSegment', value);
                      });
                      _reSegmentAndRetranslate();
                    }
                  }
                },
              ),
              const SizedBox(width: 12),
              Text(
                '(dynamically updates all languages)',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.outline,
                ),
              ),
            ],
          ),
        const SizedBox(height: 16),
        // Use Wrap for buttons to handle narrow screens
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            ElevatedButton.icon(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => CaptionEditorScreen(
                      subtitles: _editedSubtitles!,
                      videoPath: _videoPath,
                      onSave: (result) {
                        setState(() => _editedSubtitles = result);
                      },
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.edit),
              label: const Text('Edit Captions'),
            ),
            OutlinedButton.icon(
              onPressed: _exportCaptionsToSrt,
              icon: const Icon(Icons.upload),
              label: const Text('Export SRT'),
            ),
            OutlinedButton.icon(
              onPressed: _showImportSrtDialog,
              icon: const Icon(Icons.download),
              label: const Text('Import SRT'),
            ),
            // Show retranslate button only if there are non-original languages
            if (_selectedLanguages.length > 1)
              OutlinedButton.icon(
                onPressed: _hasGeminiKey ? _retranslate : null,
                icon: const Icon(Icons.translate),
                label: const Text('Retranslate'),
              ),
            OutlinedButton.icon(
              onPressed: _resetCaptions,
              icon: const Icon(Icons.refresh),
              label: const Text('Reset'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _editedSubtitles!.entries.map((entry) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(Icons.language, size: 16, color: colorScheme.primary),
                      const SizedBox(width: 8),
                      Text('${CaptionConfig.getLanguageName(entry.key)}: '),
                      Text('${entry.value.length} captions',
                          style: TextStyle(color: colorScheme.outline)),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStyleStep(ColorScheme colorScheme) {
    final languages = _editedSubtitles?.keys.toList() ?? _selectedLanguages.toList();
    
    // Initialize default styles if not set - stagger positions for each language
    for (var i = 0; i < languages.length; i++) {
      final lang = languages[i];
      if (!_languageStyles.containsKey(lang)) {
        // Stagger positions: first at 85%, then 77%, 69%, etc.
        final defaultPosition = 85.0 - (i * 8.0);
        _languageStyles[lang] = LanguageStyle(
          verticalPosition: defaultPosition.clamp(50.0, 95.0),
        );
      }
    }
    
    // Reset selected language if it's no longer in the list
    if (_selectedStyleLanguage != null && !languages.contains(_selectedStyleLanguage)) {
      _selectedStyleLanguage = languages.isNotEmpty ? languages.first : null;
    }
    
    // Set default selected language if not set
    _selectedStyleLanguage ??= languages.isNotEmpty ? languages.first : null;
    
    // Get current style based on selection
    final currentStyle = _languageStyles[_selectedStyleLanguage] ?? const LanguageStyle();
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Language selector
        Text('Language', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: _selectedStyleLanguage,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          items: languages.map((lang) => DropdownMenuItem(
            value: lang,
            child: Text(CaptionConfig.getLanguageName(lang)),
          )).toList(),
          onChanged: (value) {
            if (value != null) setState(() => _selectedStyleLanguage = value);
          },
        ),
        const SizedBox(height: 24),
        
        // Font Family
        Text('Font Family', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        _fontsLoaded && _systemFonts.isNotEmpty
            ? DropdownButtonFormField<String>(
                value: _systemFonts.contains(currentStyle.fontFamily)
                    ? currentStyle.fontFamily
                    : _systemFonts.first,
                decoration: const InputDecoration(border: OutlineInputBorder()),
                items: _systemFonts.map((font) {
                  TextStyle fontStyle;
                  try {
                    if (FontService.isGoogleFont(font)) {
                      fontStyle = GoogleFonts.getFont(font);
                    } else {
                      fontStyle = TextStyle(fontFamily: font);
                    }
                  } catch (e) {
                    // Fallback if GoogleFonts can't find the font
                    fontStyle = TextStyle(fontFamily: font);
                  }
                  return DropdownMenuItem(
                    value: font, 
                    child: Text(font, style: fontStyle),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    _updateLanguageStyle(fontFamily: value);
                    FontService.saveLastUsedFont(value);
                  }
                },
              )
            : const CircularProgressIndicator(),
        const SizedBox(height: 24),
        
        // Font Size
        Text('Font Size: ${currentStyle.fontSize.toStringAsFixed(1)}%',
            style: Theme.of(context).textTheme.titleSmall),
        Slider(
          value: currentStyle.fontSize,
          min: 2.0,
          max: 8.0,
          divisions: 12,
          label: '${currentStyle.fontSize.toStringAsFixed(1)}%',
          onChanged: (value) => _updateLanguageStyle(fontSize: value),
        ),
        const SizedBox(height: 16),
        
        // Caption Color
        Text('Caption Color', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // Preset colors
            ...List.generate(CaptionConfig.availableColors.length, (i) {
              final color = CaptionConfig.availableColors[i];
              final isSelected = currentStyle.color.value == color.value;
              return InkWell(
                onTap: () => _updateLanguageStyle(color: color),
                onLongPress: () => _showEditColorPicker(i, color),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color,
                    border: Border.all(
                      color: isSelected ? colorScheme.primary : Colors.grey,
                      width: isSelected ? 3 : 1,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: isSelected
                      ? Stack(
                          alignment: Alignment.center,
                          children: [
                            Icon(Icons.check, color: color.computeLuminance() > 0.5 ? Colors.black : Colors.white, size: 18),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                padding: const EdgeInsets.all(1),
                                decoration: BoxDecoration(
                                  color: colorScheme.primary,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: InkWell(
                                  onTap: () => _showEditColorPicker(i, color),
                                  child: Icon(Icons.edit, size: 10, color: colorScheme.onPrimary),
                                ),
                              ),
                            ),
                          ],
                        )
                      : null,
                ),
              );
            }),
            // Custom color picker button (add new color)
            InkWell(
              onTap: () => _showCustomColorPicker(currentStyle.color),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Colors.red, Colors.blue, Colors.green]),
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.colorize, color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        
        // Vertical Position
        Text('Vertical Position: ${currentStyle.verticalPosition.toInt()}%',
            style: Theme.of(context).textTheme.titleSmall),
        Slider(
          value: currentStyle.verticalPosition,
          min: 50.0,
          max: 95.0,
          divisions: 20,
          label: '${currentStyle.verticalPosition.toInt()}%',
          onChanged: (value) => _updateLanguageStyle(verticalPosition: value),
        ),
        const SizedBox(height: 16),
        
        // Border Width
        Text('Border Width: ${currentStyle.borderWidth.toInt()}',
            style: Theme.of(context).textTheme.titleSmall),
        Slider(
          value: currentStyle.borderWidth,
          min: 0.0,
          max: 10.0,
          divisions: 10,
          label: '${currentStyle.borderWidth.toInt()}',
          onChanged: (value) => _updateLanguageStyle(borderWidth: value),
        ),
        const SizedBox(height: 16),
        _buildPreviewCard(colorScheme),
      ],
    );
  }

  /// Build the enhanced color picker dialog content (shared between custom and edit)
  Widget _buildColorPickerContent({
    required Color selectedColor,
    required StateSetter setDialogState,
    required TextEditingController hexController,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Color preview with grey background for transparency visibility
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey),
            color: Colors.grey.shade800,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: selectedColor,
              borderRadius: BorderRadius.circular(7),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Hex code input
        Row(
          children: [
            const Text('#', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(width: 4),
            Expanded(
              child: TextField(
                controller: hexController,
                decoration: const InputDecoration(
                  hintText: 'RRGGBBAA',
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                onSubmitted: (value) {
                  final parsed = _parseHexColor(value);
                  if (parsed != null) {
                    setDialogState(() {});
                  }
                },
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.content_copy, size: 18),
              tooltip: 'Copy',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: hexController.text));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Color code copied'), duration: Duration(seconds: 1)),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.content_paste, size: 18),
              tooltip: 'Paste',
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null) {
                  final cleaned = data!.text!.replaceAll('#', '').trim();
                  hexController.text = cleaned;
                  final parsed = _parseHexColor(cleaned);
                  if (parsed != null) {
                    setDialogState(() {});
                  }
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Red slider
        _buildColorSlider('R', Colors.red, selectedColor.red.toDouble(), (v) {
          setDialogState(() {
            final c = selectedColor.withRed(v.toInt());
            hexController.text = _colorToHex(c);
          });
        }),
        // Green slider
        _buildColorSlider('G', Colors.green, selectedColor.green.toDouble(), (v) {
          setDialogState(() {
            final c = selectedColor.withGreen(v.toInt());
            hexController.text = _colorToHex(c);
          });
        }),
        // Blue slider
        _buildColorSlider('B', Colors.blue, selectedColor.blue.toDouble(), (v) {
          setDialogState(() {
            final c = selectedColor.withBlue(v.toInt());
            hexController.text = _colorToHex(c);
          });
        }),
        // Alpha slider
        _buildColorSlider('A', Colors.grey, selectedColor.alpha.toDouble(), (v) {
          setDialogState(() {
            final c = selectedColor.withAlpha(v.toInt());
            hexController.text = _colorToHex(c);
          });
        }),
      ],
    );
  }

  Widget _buildColorSlider(String label, Color activeColor, double value, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 16, child: Text(label, style: TextStyle(color: activeColor, fontWeight: FontWeight.bold))),
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 255,
            activeColor: activeColor,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 32, child: Text('${value.toInt()}')),
      ],
    );
  }

  String _colorToHex(Color c) {
    final r = c.red.toRadixString(16).padLeft(2, '0');
    final g = c.green.toRadixString(16).padLeft(2, '0');
    final b = c.blue.toRadixString(16).padLeft(2, '0');
    final a = c.alpha.toRadixString(16).padLeft(2, '0');
    return '$r$g$b$a'.toUpperCase();
  }

  Color? _parseHexColor(String hex) {
    hex = hex.replaceAll('#', '').trim().toUpperCase();
    if (hex.length == 6) hex = '${hex}FF'; // Default to full opacity
    if (hex.length != 8) return null;
    try {
      final r = int.parse(hex.substring(0, 2), radix: 16);
      final g = int.parse(hex.substring(2, 4), radix: 16);
      final b = int.parse(hex.substring(4, 6), radix: 16);
      final a = int.parse(hex.substring(6, 8), radix: 16);
      return Color.fromARGB(a, r, g, b);
    } catch (e) {
      return null;
    }
  }

  Future<void> _showCustomColorPicker(Color initialColor) async {
    final hexController = TextEditingController(text: _colorToHex(initialColor));
    Color selectedColor = initialColor;
    
    final result = await showDialog<Color>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose Color'),
        content: StatefulBuilder(
          builder: (context, setDialogState) {
            // Sync selectedColor from hex controller
            final parsed = _parseHexColor(hexController.text);
            if (parsed != null) selectedColor = parsed;

            return _buildColorPickerContent(
              selectedColor: selectedColor,
              setDialogState: setDialogState,
              hexController: hexController,
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final parsed = _parseHexColor(hexController.text);
              Navigator.pop(context, parsed ?? selectedColor);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );

    hexController.dispose();

    if (result != null) {
      _updateLanguageStyle(color: result);
    }
  }

  Future<void> _showEditColorPicker(int colorIndex, Color initialColor) async {
    final hexController = TextEditingController(text: _colorToHex(initialColor));
    Color selectedColor = initialColor;
    
    final result = await showDialog<Color>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Color'),
        content: StatefulBuilder(
          builder: (context, setDialogState) {
            final parsed = _parseHexColor(hexController.text);
            if (parsed != null) selectedColor = parsed;

            return _buildColorPickerContent(
              selectedColor: selectedColor,
              setDialogState: setDialogState,
              hexController: hexController,
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final parsed = _parseHexColor(hexController.text);
              Navigator.pop(context, parsed ?? selectedColor);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    hexController.dispose();

    if (result != null) {
      setState(() {
        CaptionConfig.availableColors[colorIndex] = result;
      });
      _updateLanguageStyle(color: result);
      // Persist the custom color palette
      await CaptionConfig.saveCustomColors(CaptionConfig.availableColors);
    }
  }
  
  void _updateLanguageStyle({String? fontFamily, double? fontSize, Color? color, double? verticalPosition, double? borderWidth}) {
    if (_selectedStyleLanguage == null) return;
    
    setState(() {
      final current = _languageStyles[_selectedStyleLanguage] ?? const LanguageStyle();
      _languageStyles[_selectedStyleLanguage!] = current.copyWith(
        fontFamily: fontFamily,
        fontSize: fontSize,
        color: color,
        verticalPosition: verticalPosition,
        borderWidth: borderWidth,
      );
    });
    _saveSettings(); // Persist changes
  }

  Widget _buildPreviewCard(ColorScheme colorScheme) {
    final languages = _editedSubtitles?.keys.toList() ?? [];
    
    return Card(
      color: colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 280,
        width: double.infinity,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_videoController != null && _videoController!.value.isInitialized)
              AspectRatio(
                aspectRatio: _videoController!.value.aspectRatio,
                child: VideoPlayer(_videoController!),
              )
            else
              Container(
                color: Colors.black,
                child: const Center(
                  child: Icon(Icons.video_library, size: 48, color: Colors.white54),
                ),
              ),

            // Multi-language caption overlay
            ...List.generate(languages.length, (index) {
              final lang = languages[index];
              final subs = _editedSubtitles?[lang];
              final style = _languageStyles[lang] ?? const LanguageStyle();
              final previewText = subs?.isNotEmpty == true 
                  ? subs!.first.text
                  : 'Caption';
              
              // Use per-language vertical position
              // Convert percentage (50-95) to alignment (-1 to 1)
              final verticalAlign = (style.verticalPosition - 50) / 50;
              
              // Calculate proper font size scaling
              double fontSize = 14.0;
              if (_videoController != null && _videoController!.value.isInitialized) {
                final videoHeight = _videoController!.value.size.height;
                final previewHeight = 280.0;
                final scaleFactor = previewHeight / videoHeight;
                fontSize = videoHeight * (style.fontSize / 100) * scaleFactor;
              }
              
              return Align(
                alignment: Alignment(0, verticalAlign.clamp(-1.0, 1.0)),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: () {
                    TextStyle textStyle;
                    try {
                      if (FontService.isGoogleFont(style.fontFamily)) {
                        textStyle = GoogleFonts.getFont(style.fontFamily, 
                          fontSize: fontSize,
                          color: style.color,
                        );
                      } else {
                        textStyle = TextStyle(
                          fontSize: fontSize,
                          color: style.color,
                          fontFamily: style.fontFamily,
                        );
                      }
                    } catch (e) {
                      textStyle = TextStyle(
                        fontSize: fontSize,
                        color: style.color,
                        fontFamily: style.fontFamily,
                      );
                    }
                    
                    if (style.borderWidth > 0) {
                      // Render text with outline using Stack of stroke + fill
                      return Stack(
                        children: [
                          // Stroke layer
                          Text(
                            previewText,
                            style: textStyle.copyWith(
                              foreground: Paint()
                                ..style = PaintingStyle.stroke
                                ..strokeWidth = style.borderWidth
                                ..color = Colors.black,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                          // Fill layer
                          Text(
                            previewText,
                            style: textStyle,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ],
                      );
                    } else {
                      return Text(
                        previewText,
                        style: textStyle,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      );
                    }
                  }(),
                ),
              );
            }),

            // Play/Pause Button
            if (_videoController != null && _videoController!.value.isInitialized)
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        if (_videoController!.value.isPlaying) {
                          _videoController!.pause();
                          _isPlaying = false;
                        } else {
                          _videoController!.play();
                          _isPlaying = true;
                        }
                      });
                    },
                    child: AnimatedOpacity(
                      opacity: _videoController!.value.isPlaying ? 0.0 : 0.7,
                      duration: const Duration(milliseconds: 300),
                      child: Container(
                        color: Colors.black26,
                        child: const Center(
                          child: Icon(Icons.play_circle_fill, size: 64, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRenderStep(ColorScheme colorScheme) {
    // Build resolution options based on video dimensions
    final resolutionOptions = _getAvailableResolutions();
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _summaryRow('Video', _videoPath != null ? path.basename(_videoPath!) : 'Not selected'),
                _summaryRow('Original Language', CaptionConfig.getLanguageName(_originalLanguage)),
                _summaryRow('Caption Languages', _selectedLanguages.map((l) => CaptionConfig.getLanguageName(l)).join(', ')),
                _summaryRow('Styles', '${_languageStyles.length} language(s) configured'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Resolution selector
        Text('Output Resolution', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: resolutionOptions.contains(_selectedResolution) ? _selectedResolution : resolutionOptions.first,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            helperText: '',
          ),
          items: resolutionOptions.map((res) {
            return DropdownMenuItem(value: res, child: Text(_getResolutionLabel(res)));
          }).toList(),
          onChanged: (value) {
            if (value != null) {
              setState(() => _selectedResolution = value);
            }
          },
        ),
        const SizedBox(height: 16),
        // Export SRT checkbox
        CheckboxListTile(
          value: _exportCaptionsOnRender,
          onChanged: (value) async {
            setState(() => _exportCaptionsOnRender = value ?? false);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('exportCaptionsOnRender', _exportCaptionsOnRender);
          },
          title: const Text('Export SRT files on render'),
          subtitle: const Text('YouTube-compatible subtitle files'),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: 8),
        Text(
          'Click "Render Video" to burn captions into your video.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.outline,
              ),
        ),
      ],
    );
  }

  List<String> _getAvailableResolutions() {
    final w = _videoWidth ?? 1920;
    final h = _videoHeight ?? 1080;
    final isPortrait = h > w;
    final maxDim = isPortrait ? h : w;
    
    final options = <String>[];
    
    // Check if original matches a standard resolution
    final standardRes = _getStandardResolutionFor(maxDim);
    
    // Add standard resolutions <= video resolution
    // Skip the one that matches original to avoid duplicates
    if (maxDim >= 3840 && standardRes != '4k') options.add('4k');
    if (maxDim >= 2560 && standardRes != '1440p') options.add('1440p');
    if (maxDim >= 1920 && standardRes != '1080p') options.add('1080p');
    if (maxDim >= 1280 && standardRes != '720p') options.add('720p');
    if (standardRes != '480p') options.add('480p');
    
    // Add 'original' first (with resolution label if it matches standard)
    options.insert(0, 'original');
    
    return options;
  }

  String? _getStandardResolutionFor(int dimension) {
    if (dimension == 3840) return '4k';
    if (dimension == 2560) return '1440p';
    if (dimension == 1920 || dimension == 1080) return '1080p';
    if (dimension == 1280 || dimension == 720) return '720p';
    if (dimension == 854 || dimension == 480) return '480p';
    return null;
  }

  (int, int) _calculateDimensions(String res) {
    final w = _videoWidth ?? 1920;
    final h = _videoHeight ?? 1080;
    final isPortrait = h > w;
    
    int targetShortSide;
    switch (res) {
      case '4k': targetShortSide = 2160; break;
      case '1440p': targetShortSide = 1440; break;
      case '1080p': targetShortSide = 1080; break;
      case '720p': targetShortSide = 720; break;
      case '480p': targetShortSide = 480; break;
      default: return (w, h); // original
    }
    
    if (isPortrait) {
      // Portrait: width is shorter, height is longer
      // targetShortSide = new width, calculate new height
      final newHeight = (targetShortSide * h / w).round();
      // Ensure even dimensions
      return (targetShortSide ~/ 2 * 2, newHeight ~/ 2 * 2);
    } else {
      // Landscape: height is shorter, width is longer
      // targetShortSide = new height, calculate new width
      final newWidth = (targetShortSide * w / h).round();
      return (newWidth ~/ 2 * 2, targetShortSide ~/ 2 * 2);
    }
  }

  String _getResolutionLabel(String res) {
    final (calcW, calcH) = _calculateDimensions(res);
    switch (res) {
      case 'original': 
        final stdRes = _getStandardResolutionFor((_videoWidth ?? 1920) > (_videoHeight ?? 1080) 
            ? (_videoWidth ?? 1920) 
            : (_videoHeight ?? 1080));
        if (stdRes != null) {
          return 'Original ($calcW×$calcH) - ${stdRes.toUpperCase()}';
        }
        return 'Original ($calcW×$calcH)';
      case '4k': return '4K ($calcW×$calcH)';
      case '1440p': return '1440p ($calcW×$calcH)';
      case '1080p': return '1080p ($calcW×$calcH)';
      case '720p': return '720p ($calcW×$calcH)';
      case '480p': return '480p ($calcW×$calcH)';
      default: return res;
    }
  }

  Widget _summaryRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
