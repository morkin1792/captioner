import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/subtitle.dart';
import '../models/caption_config.dart';
import '../services/log_service.dart';

class CaptionEditorScreen extends StatefulWidget {
  final Map<String, List<Subtitle>> subtitles;
  final Function(Map<String, List<Subtitle>>) onSave;
  final String? videoPath; // Optional video path for audio playback

  const CaptionEditorScreen({
    super.key,
    required this.subtitles,
    required this.onSave,
    this.videoPath,
  });

  @override
  State<CaptionEditorScreen> createState() => _CaptionEditorScreenState();
}

class _CaptionEditorScreenState extends State<CaptionEditorScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late Map<String, List<Subtitle>> _editedSubtitles;
  
  // Audio playback state
  VideoPlayerController? _audioController;
  bool _isPlaying = false;
  bool _audioEnded = false; // Track if audio finished naturally
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  int _highlightedIndex = -1;
  bool _isSliding = false; // Track if user is actively sliding
  
  // Scroll controllers for each tab
  final Map<String, ScrollController> _scrollControllers = {};
  
  // Global keys for each caption card to enable accurate scrolling
  final Map<String, Map<int, GlobalKey>> _captionKeys = {};

  @override
  void initState() {
    super.initState();
    // Deep copy subtitles
    _editedSubtitles = {};
    for (final entry in widget.subtitles.entries) {
      _editedSubtitles[entry.key] = entry.value.map((s) => s.copyWith()).toList();
      _scrollControllers[entry.key] = ScrollController();
      // Initialize GlobalKey map for each language
      _captionKeys[entry.key] = {};
    }
    _tabController = TabController(length: widget.subtitles.length, vsync: this);
    
    // Initialize audio controller if video path provided
    if (widget.videoPath != null) {
      _initAudio();
    }
  }

  Future<void> _initAudio() async {
    try {
      _audioController = VideoPlayerController.file(File(widget.videoPath!));
      await _audioController!.initialize();
      _audioController!.addListener(_onAudioPositionChanged);
      setState(() {
        _totalDuration = _audioController!.value.duration;
      });
    } catch (e) {
      LogService.log('Error initializing audio: $e');
    }
  }

  void _onAudioPositionChanged() {
    if (!mounted || _audioController == null) return;
    
    final position = _audioController!.value.position;
    final isPlaying = _audioController!.value.isPlaying;
    
    // Find caption at current position
    final languages = widget.subtitles.keys.toList();
    final currentLang = languages.isNotEmpty 
        ? languages[_tabController.index] 
        : null;
    
    int newHighlightedIndex = -1;
    if (currentLang != null) {
      final subs = _editedSubtitles[currentLang]!;
      final posMs = position.inMilliseconds;
      
      for (var i = 0; i < subs.length; i++) {
        if (posMs >= subs[i].startMs && posMs < subs[i].endMs) {
          newHighlightedIndex = i;
          break;
        }
      }
    }
    
    setState(() {
      _currentPosition = position;
      _isPlaying = isPlaying;
      
      // Detect if audio just ended (was playing, now paused, at or near end)
      if (!isPlaying && position >= _totalDuration - const Duration(milliseconds: 200)) {
        _audioEnded = true;
      }
      
      // Auto-scroll to highlighted caption
      if (newHighlightedIndex != _highlightedIndex && newHighlightedIndex >= 0) {
        _highlightedIndex = newHighlightedIndex;
        _scrollToCaption(currentLang!, newHighlightedIndex);
      } else if (newHighlightedIndex == -1) {
        _highlightedIndex = newHighlightedIndex;
      }
    });
  }

  void _scrollToCaption(String lang, int index) {
    // Get the GlobalKey for this caption
    final keyMap = _captionKeys[lang];
    if (keyMap == null) return;
    
    final key = keyMap[index];
    if (key == null || key.currentContext == null) return;
    
    // Use ensureVisible for accurate scrolling
    Scrollable.ensureVisible(
      key.currentContext!,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      alignment: 0.3, // Position highlighted item 30% from top
    );
  }

  void _togglePlayPause() async {
    if (_audioController == null) return;
    
    if (_isPlaying) {
      _audioController!.pause();
      WakelockPlus.disable();
    } else {
      // If we muted for a seek while paused, need to handle unmuting
      if (_isMutedForSeek && (Platform.isAndroid || Platform.isIOS)) {
        await _audioController!.play();
        // Wait for playback to start, then unmute
        await Future.delayed(const Duration(milliseconds: 200));
        if (mounted) {
          await _audioController!.setVolume(1);
        }
        _isMutedForSeek = false;
      } else {
        _audioController!.play();
      }
      WakelockPlus.enable();
    }
  }

  void _seekTo(Duration position) async {
    if (_audioController == null) return;
    
    // Just seek without audio manipulation - that's handled by slide start/end
    await _audioController!.seekTo(position);
  }

  // Track if we muted for a paused seek (need to unmute on next play)
  bool _isMutedForSeek = false;

  /// Seek with noise reduction for mobile platforms (same treatment as slider)
  /// If audio had ended, auto-play after seeking
  Future<void> _seekToWithNoiseReduction(Duration position) async {
    if (_audioController == null) return;
    
    final wasPlaying = _isPlaying;
    final hadEnded = _audioEnded;
    
    // Clear ended flag since user is seeking
    _audioEnded = false;
    
    if (Platform.isAndroid || Platform.isIOS) {
      // Always mute before seeking to avoid noise
      await _audioController!.setVolume(0);
      
      // Always pause first to reset player state
      await _audioController!.pause();
      await Future.delayed(const Duration(milliseconds: 50));
      
      // If audio had ended, we need to: play() first, then seekTo()
      // because the player resets position when play() is called after completion
      if (hadEnded) {
        await _audioController!.play();
        await Future.delayed(const Duration(milliseconds: 50));
        await _audioController!.seekTo(position);
        await Future.delayed(const Duration(milliseconds: 150));
        
        // Restore volume
        if (mounted) {
          await _audioController!.setVolume(1);
          _isMutedForSeek = false;
        }
      } else {
        // Normal case: seek first, then play if was playing
        await _audioController!.seekTo(position);
        await Future.delayed(const Duration(milliseconds: 150));
        
        if (wasPlaying && mounted) {
          await _audioController!.play();
          await Future.delayed(const Duration(milliseconds: 200));
          if (mounted) {
            await _audioController!.setVolume(1);
            _isMutedForSeek = false;
          }
        } else {
          // Was paused - keep muted, will unmute when play is pressed
          _isMutedForSeek = true;
        }
      }
    } else {
      // Desktop (MDK/fvp): The player resets position when play() is called after completion
      // So we need to: pause -> play -> seek (in that order)
      if (hadEnded) {
        await _audioController!.pause();
        await Future.delayed(const Duration(milliseconds: 50));
        await _audioController!.play();
        await Future.delayed(const Duration(milliseconds: 50));
        await _audioController!.seekTo(position);
      } else {
        // Normal case: just seek
        await _audioController!.seekTo(position);
      }
    }
  }

  bool _wasPlayingBeforeSlide = false;
  bool _hadEndedBeforeSlide = false;

  /// Called when user starts sliding the seek bar
  Future<void> _onSlideStart() async {
    if (_audioController == null) return;
    _wasPlayingBeforeSlide = _isPlaying;
    _hadEndedBeforeSlide = _audioEnded;
    _isSliding = true;
    
    // Clear ended flag since user is seeking
    _audioEnded = false;
    
    // On mobile: mute and pause to avoid seek noise
    if (Platform.isAndroid || Platform.isIOS) {
      await _audioController!.setVolume(0);
      // If audio had ended, call pause() to reset from "completed" state
      if (_hadEndedBeforeSlide) {
        await _audioController!.pause();
      } else if (_isPlaying) {
        await _audioController!.pause();
      }
    } else {
      // Desktop: If audio had ended, call pause() to reset player state  
      if (_hadEndedBeforeSlide) {
        await _audioController!.pause();
      }
    }
  }

  /// Called when user finishes sliding (releases the slider)
  Future<void> _onSlideEnd(Duration position) async {
    if (_audioController == null) return;
    
    // Only do special handling on mobile
    if (Platform.isAndroid || Platform.isIOS) {
      // If audio had ended, we need to: play() first, then seekTo()
      // because the player resets position when play() is called after completion
      if (_hadEndedBeforeSlide) {
        await _audioController!.play();
        await Future.delayed(const Duration(milliseconds: 50));
        await _audioController!.seekTo(position);
        await Future.delayed(const Duration(milliseconds: 150));
        
        // Restore volume
        if (mounted) {
          await _audioController!.setVolume(1);
          _isMutedForSeek = false;
        }
      } else {
        // Normal case: seek to final position
        await _audioController!.seekTo(position);
        
        // Wait a bit for seek to settle
        await Future.delayed(const Duration(milliseconds: 150));
        
        if (_wasPlayingBeforeSlide && mounted) {
          await _audioController!.play();
          await Future.delayed(const Duration(milliseconds: 200));
          
          // Restore volume when resuming
          if (mounted) {
            await _audioController!.setVolume(1);
            _isMutedForSeek = false;
          }
        } else {
          // Was paused - keep muted, will unmute when play is pressed
          _isMutedForSeek = true;
        }
      }
    } else {
      // Desktop (MDK/fvp): If audio had ended, play first then seek
      // MDK resets position when play() is called after completion
      if (_hadEndedBeforeSlide && mounted) {
        await _audioController!.play();
        await Future.delayed(const Duration(milliseconds: 50));
        await _audioController!.seekTo(position);
      } else {
        // Normal case: just seek
        await _audioController!.seekTo(position);
      }
    }
    
    _isSliding = false;
  }

  void _updateHighlightForPosition(Duration position) {
    final languages = widget.subtitles.keys.toList();
    final currentLang = languages.isNotEmpty 
        ? languages[_tabController.index] 
        : null;
    
    if (currentLang == null) return;
    
    final subs = _editedSubtitles[currentLang]!;
    final posMs = position.inMilliseconds;
    
    int newIndex = -1;
    for (var i = 0; i < subs.length; i++) {
      if (posMs >= subs[i].startMs && posMs < subs[i].endMs) {
        newIndex = i;
        break;
      }
    }
    
    if (newIndex != _highlightedIndex) {
      setState(() {
        _highlightedIndex = newIndex;
      });
      if (newIndex >= 0) {
        _scrollToCaption(currentLang, newIndex);
      }
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable(); // Ensure wakelock is disabled when leaving
    _audioController?.removeListener(_onAudioPositionChanged);
    _audioController?.dispose();
    _tabController.dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    // Sort all subtitles by start time before saving
    for (final lang in _editedSubtitles.keys) {
      _editedSubtitles[lang]!.sort((a, b) => a.startMs.compareTo(b.startMs));
    }
    widget.onSave(_editedSubtitles);
    Navigator.of(context).pop();
  }

  void _addCaption(String lang) {
    final subs = _editedSubtitles[lang]!;
    final lastEnd = subs.isNotEmpty ? subs.last.endMs : 0;
    
    setState(() {
      subs.add(Subtitle(
        startMs: lastEnd,
        endMs: lastEnd + 3000, // 3 second default
        text: 'New caption',
      ));
      // Sort by start time
      subs.sort((a, b) => a.startMs.compareTo(b.startMs));
    });
  }

  void _deleteCaption(String lang, int index) {
    setState(() {
      _editedSubtitles[lang]!.removeAt(index);
    });
  }

  void _updateCaption(String lang, int index, {String? text, int? startMs, int? endMs}) {
    setState(() {
      final sub = _editedSubtitles[lang]![index];
      _editedSubtitles[lang]![index] = Subtitle(
        startMs: startMs ?? sub.startMs,
        endMs: endMs ?? sub.endMs,
        text: text ?? sub.text,
      );
      
      // Auto-sort by start time if timing changed
      if (startMs != null) {
        _editedSubtitles[lang]!.sort((a, b) => a.startMs.compareTo(b.startMs));
      }
    });
  }

  Future<void> _editTiming(String lang, int index) async {
    final sub = _editedSubtitles[lang]![index];
    
    final startController = TextEditingController(text: _formatTimeEditable(sub.startMs));
    final endController = TextEditingController(text: _formatTimeEditable(sub.endMs));
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Timing'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: startController,
              decoration: const InputDecoration(
                labelText: 'Start Time',
                hintText: 'MM:SS.mmm',
              ),
              keyboardType: TextInputType.text,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: endController,
              decoration: const InputDecoration(
                labelText: 'End Time',
                hintText: 'MM:SS.mmm',
              ),
              keyboardType: TextInputType.text,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == true) {
      final startMs = _parseTime(startController.text);
      final endMs = _parseTime(endController.text);
      
      if (startMs != null && endMs != null && startMs < endMs) {
        _updateCaption(lang, index, startMs: startMs, endMs: endMs);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid time format. Use MM:SS.mmm')),
        );
      }
    }
    
    startController.dispose();
    endController.dispose();
  }

  int? _parseTime(String text) {
    try {
      final parts = text.split(':');
      if (parts.length != 2) return null;
      
      final minutes = int.parse(parts[0]);
      final secondsParts = parts[1].split('.');
      final seconds = int.parse(secondsParts[0]);
      final millis = secondsParts.length > 1 
          ? int.parse(secondsParts[1].padRight(3, '0').substring(0, 3))
          : 0;
      
      return (minutes * 60 + seconds) * 1000 + millis;
    } catch (e) {
      return null;
    }
  }

  String _formatTimeEditable(int ms) {
    final minutes = ms ~/ 60000;
    final seconds = (ms % 60000) ~/ 1000;
    final millis = ms % 1000;
    return '$minutes:${seconds.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
  }

  Widget _buildAudioControls() {
    if (_audioController == null) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Seek slider
          Row(
            children: [
              Text(
                _formatDuration(_currentPosition),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Expanded(
                child: Slider(
                  value: _currentPosition.inMilliseconds.toDouble().clamp(
                    0,
                    _totalDuration.inMilliseconds.toDouble(),
                  ),
                  min: 0,
                  max: _totalDuration.inMilliseconds.toDouble().clamp(1, double.maxFinite),
                  onChangeStart: (_) => _onSlideStart(),
                  onChanged: (value) {
                    // Update position display and seek during drag
                    final pos = Duration(milliseconds: value.toInt());
                    setState(() => _currentPosition = pos);
                    _seekTo(pos);
                    
                    // Also scroll to caption for immediate feedback (especially on tap)
                    final languages = widget.subtitles.keys.toList();
                    final currentLang = languages.isNotEmpty 
                        ? languages[_tabController.index] 
                        : null;
                    if (currentLang != null) {
                      final subs = _editedSubtitles[currentLang]!;
                      for (var i = 0; i < subs.length; i++) {
                        if (value >= subs[i].startMs && value < subs[i].endMs) {
                          if (i != _highlightedIndex) {
                            setState(() => _highlightedIndex = i);
                            _scrollToCaption(currentLang, i);
                          }
                          break;
                        }
                      }
                    }
                  },
                  onChangeEnd: (value) async {
                    final pos = Duration(milliseconds: value.toInt());
                    
                    // Handle audio unmuting and resume
                    await _onSlideEnd(pos);
                    
                    // Scroll to current caption
                    final languages = widget.subtitles.keys.toList();
                    final currentLang = languages.isNotEmpty 
                        ? languages[_tabController.index] 
                        : null;
                    
                    if (currentLang == null) return;
                    
                    final subs = _editedSubtitles[currentLang]!;
                    final posMs = pos.inMilliseconds;
                    
                    // Find and scroll to current caption
                    for (var i = 0; i < subs.length; i++) {
                      if (posMs >= subs[i].startMs && posMs < subs[i].endMs) {
                        setState(() => _highlightedIndex = i);
                        _scrollToCaption(currentLang, i);
                        break;
                      }
                    }
                  },
                ),
              ),
              Text(
                _formatDuration(_totalDuration),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          // Play/Pause button
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: Icon(_isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled),
                iconSize: 48,
                color: Theme.of(context).colorScheme.primary,
                onPressed: _togglePlayPause,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final languages = widget.subtitles.keys.toList();
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Captions'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: languages.map((code) => Tab(
            text: CaptionConfig.getLanguageName(code),
          )).toList(),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Done', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: Column(
        children: [
          // Audio controls at top
          _buildAudioControls(),
          
          // Caption list
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: languages.map((lang) {
                final subs = _editedSubtitles[lang]!;

                return Column(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        controller: _scrollControllers[lang],
                        padding: const EdgeInsets.all(16),
                        itemCount: subs.length,
                        itemBuilder: (context, index) {
                          final sub = subs[index];
                          final isHighlighted = index == _highlightedIndex;

                          // Get or create GlobalKey for this caption
                          final captionKey = _captionKeys[lang]!.putIfAbsent(
                            index, 
                            () => GlobalKey(),
                          );

                          return GestureDetector(
                            onTap: () async {
                              // Seek audio to 0.5s before this caption's start time (to catch fast words)
                              final offsetMs = (sub.startMs - 500).clamp(0, sub.startMs);
                              final seekPosition = Duration(milliseconds: offsetMs);
                              // Use noise-reduced seek on mobile
                              await _seekToWithNoiseReduction(seekPosition);
                              setState(() {
                                _currentPosition = seekPosition;
                                _highlightedIndex = index;
                              });
                              _scrollToCaption(lang, index);
                            },
                            child: Card(
                              key: captionKey,
                              margin: const EdgeInsets.only(bottom: 12),
                              color: isHighlighted 
                                  ? colorScheme.primaryContainer 
                                  : null,
                              elevation: isHighlighted ? 4 : 1,
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                  Row(
                                    children: [
                                      // Now playing indicator
                                      if (isHighlighted)
                                        Padding(
                                          padding: const EdgeInsets.only(right: 8),
                                          child: Icon(
                                            Icons.play_arrow,
                                            size: 16,
                                            color: colorScheme.primary,
                                          ),
                                        ),
                                      // Timing (tappable)
                                      InkWell(
                                        onTap: () => _editTiming(lang, index),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.access_time, size: 16, color: colorScheme.primary),
                                            const SizedBox(width: 4),
                                            Text(
                                              '${_formatTime(sub.startMs)} → ${_formatTime(sub.endMs)}',
                                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                                    color: colorScheme.primary,
                                                    fontWeight: isHighlighted ? FontWeight.bold : null,
                                                  ),
                                            ),
                                            const SizedBox(width: 4),
                                            Icon(Icons.edit, size: 12, color: colorScheme.outline),
                                          ],
                                        ),
                                      ),
                                      const Spacer(),
                                      // Delete button
                                      IconButton(
                                        icon: Icon(Icons.delete_outline, color: Colors.red.shade400),
                                        onPressed: () => _deleteCaption(lang, index),
                                        tooltip: 'Delete caption',
                                        iconSize: 20,
                                        constraints: const BoxConstraints(),
                                        padding: const EdgeInsets.all(8),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  TextFormField(
                                    initialValue: sub.text,
                                    maxLines: null,
                                    decoration: const InputDecoration(
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: isHighlighted ? FontWeight.bold : null,
                                    ),
                                    onChanged: (value) {
                                      _updateCaption(lang, index, text: value);
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                          );
                        },
                      ),
                    ),
                    // Add caption button
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => _addCaption(lang),
                          icon: const Icon(Icons.add),
                          label: const Text('Add Caption'),
                        ),
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(int ms) {
    final duration = Duration(milliseconds: ms);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
