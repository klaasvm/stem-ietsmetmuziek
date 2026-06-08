import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_update_service.dart';
import 'dev.dart';
import 'esp32_service.dart';
import 'laptop_service.dart';
import 'play.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MIDI Raw Data Viewer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const StartPage(),
    );
  }
}

class StartPage extends StatefulWidget {
  const StartPage({super.key});

  @override
  State<StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<StartPage> {
  final AppUpdateService _appUpdateService = AppUpdateService();
  final Esp32Service _esp32Service = Esp32Service.instance;
  final LaptopService _laptopService = LaptopService.instance;
  
  AppUpdateInfo? _requiredUpdate;
  bool _updateCheckDone = false;
  bool _isInstallingUpdate = false;
  String _updateStatus = '';
  bool _esp32LookupRunning = true;
  bool? _esp32LookupSucceeded;

  @override
  void initState() {
    super.initState();
    // Luister naar de LaptopService voor real-time status updates
    _laptopService.addListener(_onLaptopServiceChanged);
    
    _initConnectionCheck();
    _runStartupChecks();
  }

  @override
  void dispose() {
    _laptopService.removeListener(_onLaptopServiceChanged);
    super.dispose();
  }

  void _onLaptopServiceChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _initConnectionCheck() async {
    // Laad IP en controleer of de laptop server draait
    await _laptopService.loadConfig();
  }

  Future<void> _runStartupChecks() async {
    try {
      final AppUpdateInfo? update = await _appUpdateService.checkForUpdate();
      if (mounted) {
        setState(() {
          _requiredUpdate = update;
          _updateCheckDone = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _updateCheckDone = true;
        });
      }
    }

    if (_requiredUpdate == null) {
      await _findEsp32();
    }
  }

  Future<void> _findEsp32() async {
    setState(() {
      _esp32LookupRunning = true;
    });

    try {
      final bool found = await _esp32Service.findEsp32();
      if (mounted) {
        setState(() {
          _esp32LookupSucceeded = found;
          _esp32LookupRunning = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _esp32LookupSucceeded = false;
          _esp32LookupRunning = false;
        });
      }
    }
  }

  Future<void> _installUpdate() async {
    if (_requiredUpdate == null) return;
    setState(() {
      _isInstallingUpdate = true;
      _updateStatus = 'Bezig met downloaden...';
    });

    try {
      await _appUpdateService.downloadAndInstallUpdate(
        _requiredUpdate!,
        onProgress: (String status) {
          if (mounted) {
            setState(() {
              _updateStatus = status;
            });
          }
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _updateStatus = 'Fout bij installatie:\n$e';
          _isInstallingUpdate = false;
        });
      }
    }
  }

  void _openPlayModeChooser() {
    // Jouw navigatie-logica naar de play-pagina (PlayMode chooser of game)
    // Zorg ervoor dat dit linkt naar de juiste widget uit play.dart!
    // Voorbeeld: Navigator.of(context).push(...) 
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // UI als er een update bezig is (uit je originele code)
                if (!_updateCheckDone || _isInstallingUpdate) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(_updateStatus.isNotEmpty ? _updateStatus : 'Opstarten...'),
                ] else if (_requiredUpdate != null) ...[
                  const Text('Nieuwe update beschikbaar!'),
                  ElevatedButton(
                    onPressed: _installUpdate,
                    child: const Text('Update nu'),
                  ),
                ] else ...[
                  // De hoofd UI
                  if (_esp32LookupRunning)
                    const CircularProgressIndicator()
                  else
                    Column(
                      children: [
                        FilledButton.icon(
                          // Play knop is klikbaar als de ESP32 óf de Laptop succesvol is verbonden!
                          onPressed: (_esp32LookupSucceeded == true || _laptopService.isConnected)
                              ? _openPlayModeChooser
                              : null,
                          icon: const Icon(Icons.play_arrow),
                          label: Text(
                            (_esp32LookupSucceeded == true || _laptopService.isConnected)
                                ? 'Play'
                                : 'Play (wacht op verbinding)',
                          ),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                          ),
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const DevPage(title: 'MIDI Raw Data Viewer'),
                              ),
                            );
                          },
                          icon: const Icon(Icons.bug_report),
                          label: const Text('Dev'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white70),
                          ),
                        ),
                        const SizedBox(height: 24),
                        // Laat handig zien of je laptop echt online is via de app!
                        Text(
                          'Laptop: ${_laptopService.status}',
                          style: const TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ],
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}