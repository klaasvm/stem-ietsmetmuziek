import 'package:flutter/material.dart';

import 'app_update_service.dart';
import 'dev.dart';
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
  AppUpdateInfo? _requiredUpdate;
  bool _updateCheckDone = false;
  bool _isInstallingUpdate = false;
  String _updateStatus = '';

  @override
  void initState() {
    super.initState();
    () async {
      try {
        await GitHubSongCatalog.load();
      } catch (error, stackTrace) {
        debugPrint('GitHubSongCatalog prefetch mislukt: $error');
        debugPrint(stackTrace.toString());
      }
    }();
    _checkForUpdate();
  }

  Future<void> _checkForUpdate() async {
    try {
      final AppUpdateInfo? updateInfo = await _appUpdateService
          .checkForRequiredUpdate();
      if (!mounted) {
        return;
      }
      setState(() {
        _requiredUpdate = updateInfo;
        _updateCheckDone = true;
      });
    } on UpdateReleaseNotPublishedException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _requiredUpdate = null;
        _updateCheckDone = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Update beschikbaar (${error.currentVersion} -> ${error.latestVersion}), maar release staat nog niet op GitHub.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _requiredUpdate = null;
        _updateCheckDone = true;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Update check mislukt: $error')));
    }
  }

  Future<void> _startMandatoryUpdate() async {
    final AppUpdateInfo? update = _requiredUpdate;
    if (update == null || _isInstallingUpdate) {
      return;
    }

    setState(() {
      _isInstallingUpdate = true;
      _updateStatus = 'Update download gestart...';
    });

    try {
      await _appUpdateService.installUpdate(
        update,
        onStatus: (String message) {
          if (!mounted) {
            return;
          }
          setState(() {
            _updateStatus = message;
          });
        },
      );

      if (!mounted) {
        return;
      }
      setState(() {
        _updateStatus = 'Installatie gestart. Rond de update af in Android.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isInstallingUpdate = false;
        _updateStatus = 'Update mislukt: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_updateCheckDone) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_requiredUpdate != null) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                Color(0xFF10172A),
                Color(0xFF1C2A5A),
                Color(0xFF0F172A),
              ],
            ),
          ),
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Card(
                    color: Colors.black.withValues(alpha: 0.35),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(
                            Icons.system_update,
                            size: 60,
                            color: Colors.white,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Update verplicht',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Huidige versie: ${_requiredUpdate!.currentVersion}\nBeschikbaar: ${_requiredUpdate!.latestVersion}',
                            style: TextStyle(
                              fontSize: 16,
                              height: 1.4,
                              color: Colors.white.withValues(alpha: 0.9),
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 14),
                          Text(
                            _updateStatus.isEmpty
                                ? 'Download en installatie starten via GitHub release.'
                                : _updateStatus,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white.withValues(alpha: 0.78),
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            onPressed: _isInstallingUpdate
                                ? null
                                : _startMandatoryUpdate,
                            icon: _isInstallingUpdate
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.download),
                            label: Text(
                              _isInstallingUpdate
                                  ? 'Bezig met updaten...'
                                  : 'Update nu',
                            ),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(52),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Color(0xFF10172A),
              Color(0xFF1C2A5A),
              Color(0xFF0F172A),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    const Icon(Icons.music_note, size: 72, color: Colors.white),
                    const SizedBox(height: 20),
                    const Text(
                      'Stem Iets Met Muziek',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Kies Play voor de normale modus of Dev voor de debug / MIDI inspectie.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.4,
                        color: Colors.white.withValues(alpha: 0.82),
                      ),
                    ),
                    const SizedBox(height: 32),
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const PlayPage(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                const DevPage(title: 'MIDI Raw Data Viewer'),
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
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
