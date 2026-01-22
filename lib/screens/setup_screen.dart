import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/storage_service.dart';
import '../services/ffmpeg_service.dart';

class SetupScreen extends StatefulWidget {
  final VoidCallback onSetupComplete;
  final bool isSettings; // True when opened from Settings button

  const SetupScreen({
    super.key, 
    required this.onSetupComplete,
    this.isSettings = false,
  });

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _assemblyAiController = TextEditingController();
  final _geminiController = TextEditingController();
  bool _loading = false;
  bool _obscureAssemblyAi = true;
  bool _obscureGemini = true;
  String? _ffmpegStatus;
  bool _ffmpegChecking = true;
  bool _hasExistingKeys = false;

  @override
  void initState() {
    super.initState();
    _checkFfmpeg();
    _loadExistingKeys();
  }

  Future<void> _loadExistingKeys() async {
    if (widget.isSettings) {
      final storage = context.read<StorageService>();
      final assemblyKey = await storage.getAssemblyAiKey();
      final geminiKey = await storage.getGeminiKey();
      
      setState(() {
        // Load each key independently if it exists
        if (assemblyKey != null) {
          _hasExistingKeys = true;
          _assemblyAiController.text = assemblyKey;
        }
        if (geminiKey != null) {
          _hasExistingKeys = true;
          _geminiController.text = geminiKey;
        }
      });
    }
  }

  Future<void> _checkFfmpeg() async {
    final ffmpegService = FfmpegService();
    final isAvailable = await ffmpegService.checkFfmpegAvailable();
    setState(() {
      _ffmpegChecking = false;
      _ffmpegStatus = isAvailable ? 'FFmpeg is available' : 'FFmpeg not found! Please install FFmpeg.';
    });
  }

  @override
  void dispose() {
    _assemblyAiController.dispose();
    _geminiController.dispose();
    super.dispose();
  }

  Future<void> _saveKeys() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);

    try {
      final storage = context.read<StorageService>();
      await storage.saveApiKeys(
        assemblyAiKey: _assemblyAiController.text.trim(),
        geminiKey: _geminiController.text.trim(),
      );
      widget.onSetupComplete();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving keys: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: widget.isSettings ? AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ) : null,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              colorScheme.surface,
              colorScheme.surface.withOpacity(0.8),
              colorScheme.primaryContainer.withOpacity(0.3),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Logo/Title (only show on initial setup)
                      if (!widget.isSettings) ...[
                        Icon(
                          Icons.closed_caption,
                          size: 80,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Captioner',
                          style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: colorScheme.onSurface,
                              ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'AI-powered video captioning',
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                color: colorScheme.onSurface.withOpacity(0.7),
                              ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 48),
                      ],

                      // FFmpeg status
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              if (_ffmpegChecking)
                                const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              else
                                Icon(
                                  _ffmpegStatus?.contains('available') == true
                                      ? Icons.check_circle
                                      : Icons.error,
                                  color: _ffmpegStatus?.contains('available') == true
                                      ? Colors.green
                                      : Colors.red,
                                ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _ffmpegChecking ? 'Checking FFmpeg...' : _ffmpegStatus ?? '',
                                  style: TextStyle(
                                    color: _ffmpegStatus?.contains('available') == true
                                        ? Colors.green
                                        : Colors.red,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // API Keys Card
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'API Keys',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                widget.isSettings 
                                    ? 'Update your API keys below.'
                                    : 'Enter your API keys to get started. Keys are stored securely on your device.',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: colorScheme.onSurface.withOpacity(0.7),
                                    ),
                              ),
                              const SizedBox(height: 24),

                              // AssemblyAI Key
                              TextFormField(
                                controller: _assemblyAiController,
                                obscureText: _obscureAssemblyAi,
                                decoration: InputDecoration(
                                  labelText: 'AssemblyAI API Key',
                                  hintText: 'Enter your AssemblyAI key',
                                  prefixIcon: const Icon(Icons.key),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscureAssemblyAi
                                          ? Icons.visibility
                                          : Icons.visibility_off,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        _obscureAssemblyAi = !_obscureAssemblyAi;
                                      });
                                    },
                                  ),
                                ),
                                validator: (value) {
                                  if (value == null || value.trim().isEmpty) {
                                    return 'Please enter your AssemblyAI API key';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 16),

                              // Gemini Key (Optional)
                              TextFormField(
                                controller: _geminiController,
                                obscureText: _obscureGemini,
                                decoration: InputDecoration(
                                  labelText: 'Gemini API Key (Optional)',
                                  hintText: 'For translation to other languages',
                                  prefixIcon: const Icon(Icons.key),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscureGemini
                                          ? Icons.visibility
                                          : Icons.visibility_off,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        _obscureGemini = !_obscureGemini;
                                      });
                                    },
                                  ),
                                ),
                                // No validator - Gemini key is optional
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),

                      // Buttons
                      ElevatedButton(
                        onPressed: _loading ? null : _saveKeys,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: colorScheme.primary,
                          foregroundColor: colorScheme.onPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: _loading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(
                                widget.isSettings ? 'Save Changes' : 'Get Started',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                      if (widget.isSettings) ...[
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
