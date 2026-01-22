import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'screens/setup_screen.dart';
import 'screens/home_screen.dart';
import 'services/storage_service.dart';
import 'services/log_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize log file on desktop
  await LogService.initialize();
  LogService.log('Captioner starting...');
  
  fvp.registerWith();
  
  // Debug platform instance
  try {
    // ignore: invalid_use_of_visible_for_testing_member
    final platformType = VideoPlayerPlatform.instance.runtimeType.toString();
    LogService.log('VideoPlayerPlatform instance: $platformType');
  } catch (e, stack) {
    LogService.error('Failed to check platform instance', e, stack);
  }
  
  // Note: LogService.initialize() sets up comprehensive error handlers

  runApp(
    MultiProvider(
      providers: [
        Provider<StorageService>(create: (_) => StorageService()),
      ],
      child: const CaptionerApp(),
    ),
  );
}

class CaptionerApp extends StatelessWidget {
  const CaptionerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Captioner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
        cardTheme: CardThemeData(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      home: const AppEntryPoint(),
    );
  }
}

class AppEntryPoint extends StatefulWidget {
  const AppEntryPoint({super.key});

  @override
  State<AppEntryPoint> createState() => _AppEntryPointState();
}

class _AppEntryPointState extends State<AppEntryPoint> {
  bool _loading = true;
  bool _hasApiKeys = false;

  @override
  void initState() {
    super.initState();
    _checkApiKeys();
  }

  Future<void> _checkApiKeys() async {
    final storage = context.read<StorageService>();
    final hasKeys = await storage.hasApiKeys();
    setState(() {
      _hasApiKeys = hasKeys;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (!_hasApiKeys) {
      return SetupScreen(
        onSetupComplete: () {
          setState(() {
            _hasApiKeys = true;
          });
        },
      );
    }

    return const HomeScreen();
  }
}
