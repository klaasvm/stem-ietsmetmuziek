import 'dart:convert';
import 'dart:io';

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
  bool _esp32LookupRunning = true;
  bool? _esp32LookupSucceeded;
  String _esp32Status = 'ESP32 zoeken op netwerk...';
  String _esp32RawData = '';
  String? _esp32Ip;

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
    _startEsp32Lookup();
  }

  Future<void> _startEsp32Lookup() async {
    if (!mounted) {
      return;
    }

    setState(() {
      _esp32LookupRunning = true;
      _esp32LookupSucceeded = null;
      _esp32Status = 'ESP32 zoeken op netwerk...';
      _esp32RawData = '';
      _esp32Ip = null;
    });

    try {
      final String? ip = await _discoverEsp32Ip();
      if (!mounted) {
        return;
      }

      if (ip == null) {
        setState(() {
          _esp32LookupRunning = false;
          _esp32LookupSucceeded = false;
          _esp32Status = 'Geen ESP32 gevonden';
          _esp32RawData = 'Geen response ontvangen in lokaal subnet.';
        });
        return;
      }

      final String rawData = await _fetchEsp32Raw(ip);
      if (!mounted) {
        return;
      }

      debugPrint('ESP32 gevonden op $ip');
      debugPrint('ESP32 raw data:\n$rawData');

      setState(() {
        _esp32LookupRunning = false;
        _esp32LookupSucceeded = true;
        _esp32Ip = ip;
        _esp32Status = 'ESP32 gevonden';
        _esp32RawData = rawData;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _esp32LookupRunning = false;
        _esp32LookupSucceeded = false;
        _esp32Status = 'ESP32 check mislukt';
        _esp32RawData = 'Fout: $error';
      });
    }
  }

  Future<String?> _discoverEsp32Ip() async {
    final String? mdnsIp = await _discoverEsp32ViaHostnames();
    if (mdnsIp != null) {
      return mdnsIp;
    }

    if (_esp32Ip != null && await _looksLikeEsp32(_esp32Ip!)) {
      return _esp32Ip;
    }

    final Map<String, int> prefixes = await _collectSubnetPrefixes();
    final List<String> candidates = <String>[];

    for (final MapEntry<String, int> entry in prefixes.entries) {
      final String prefix = entry.key;
      final int ownLastOctet = entry.value;
      for (int host = 2; host <= 254; host++) {
        if (host == ownLastOctet) {
          continue;
        }
        candidates.add('$prefix.$host');
      }
    }

    const int batchSize = 24;
    for (int index = 0; index < candidates.length; index += batchSize) {
      final int end = (index + batchSize) > candidates.length
          ? candidates.length
          : (index + batchSize);
      final List<String> batch = candidates.sublist(index, end);
      final List<bool> matches = await Future.wait(
        batch.map(_looksLikeEsp32),
      );

      for (int i = 0; i < batch.length; i++) {
        if (matches[i]) {
          return batch[i];
        }
      }
    }

    return null;
  }

  Future<String?> _discoverEsp32ViaHostnames() async {
    const List<String> hostnames = <String>[
      'esp32.local',
      'esp32',
    ];

    for (final String host in hostnames) {
      try {
        final List<InternetAddress> resolved = await InternetAddress.lookup(host)
            .timeout(const Duration(milliseconds: 900));
        for (final InternetAddress address in resolved) {
          final String ip = address.address;
          if (!_isPrivateIpv4(ip)) {
            continue;
          }
          if (await _looksLikeEsp32(ip)) {
            return ip;
          }
        }
      } catch (_) {
        // Hostname niet beschikbaar op dit netwerk.
      }
    }

    return null;
  }

  Future<Map<String, int>> _collectSubnetPrefixes() async {
    final Map<String, int> prefixes = <String, int>{};
    try {
      final List<NetworkInterface> interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (final NetworkInterface interface in interfaces) {
        for (final InternetAddress address in interface.addresses) {
          final String ip = address.address;
          final List<String> segments = ip.split('.');
          if (segments.length != 4) {
            continue;
          }
          if (!_isPrivateIpv4(ip)) {
            continue;
          }

          final int? host = int.tryParse(segments[3]);
          if (host == null) {
            continue;
          }

          prefixes['${segments[0]}.${segments[1]}.${segments[2]}'] = host;
        }
      }
    } catch (_) {
      // Val terug op veelgebruikte thuisnetwerken als interface lookup faalt.
    }

    prefixes.putIfAbsent('192.168.0', () => -1);
    prefixes.putIfAbsent('192.168.1', () => -1);
    prefixes.putIfAbsent('192.168.2', () => -1);
    prefixes.putIfAbsent('192.168.178', () => -1);
    return prefixes;
  }

  bool _isPrivateIpv4(String ip) {
    final List<String> segments = ip.split('.');
    if (segments.length != 4) {
      return false;
    }

    final int? a = int.tryParse(segments[0]);
    final int? b = int.tryParse(segments[1]);
    if (a == null || b == null) {
      return false;
    }

    if (a == 10) {
      return true;
    }
    if (a == 172 && b >= 16 && b <= 31) {
      return true;
    }
    if (a == 192 && b == 168) {
      return true;
    }
    return false;
  }

  Future<bool> _looksLikeEsp32(String ip) async {
    final String? rawBody = await _fetchRawFromEsp32Endpoints(ip);
    if (rawBody == null) {
      return false;
    }

    final bool hasConfirmToken = await _hasExpectedConfirmToken(ip);
    if (!hasConfirmToken) {
      return false;
    }

    final String trimmed = rawBody.trim();
    final RegExp timePattern = RegExp(r'^\d{2}:\d{2}:\d{2}$');
    if (timePattern.hasMatch(trimmed)) {
      return true;
    }

    final String lowered = trimmed.toLowerCase();
    return lowered.contains('esp32') || lowered.contains('<html');
  }

  Future<bool> _hasExpectedConfirmToken(String ip) async {
    final HttpClient client = HttpClient();
    client.connectionTimeout = const Duration(milliseconds: 700);
    try {
      final HttpClientRequest request = await client
          .getUrl(Uri.parse('http://$ip/confirm'))
          .timeout(const Duration(milliseconds: 1000));
      final HttpClientResponse response = await request.close().timeout(
        const Duration(milliseconds: 1100),
      );

      if (response.statusCode != 200) {
        return false;
      }

      final String body = await response.transform(utf8.decoder).join().timeout(
        const Duration(milliseconds: 1200),
      );
      return body.toLowerCase().contains('ietsmetmuziek');
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _fetchRawFromEsp32Endpoints(String ip) async {
    const List<String> endpoints = <String>['/raw', '/'];

    for (final String endpoint in endpoints) {
      final HttpClient client = HttpClient();
      client.connectionTimeout = const Duration(milliseconds: 700);
      try {
        final HttpClientRequest request = await client
            .getUrl(Uri.parse('http://$ip$endpoint'))
            .timeout(const Duration(milliseconds: 1000));
        final HttpClientResponse response = await request.close().timeout(
          const Duration(milliseconds: 1100),
        );

        if (response.statusCode != 200) {
          continue;
        }

        final String body = await response.transform(utf8.decoder).join().timeout(
          const Duration(milliseconds: 1200),
        );

        if (body.trim().isNotEmpty) {
          return body;
        }
      } catch (_) {
        // Probeer volgende endpoint.
      } finally {
        client.close(force: true);
      }
    }

    return null;
  }

  Future<String> _fetchEsp32Raw(String ip) async {
    final String? body = await _fetchRawFromEsp32Endpoints(ip);
    if (body == null) {
      throw const HttpException('Geen bruikbare ESP32 response op /raw of /.');
    }

    final String trimmed = body.trim();
    return trimmed.isEmpty ? '(lege response)' : trimmed;
  }

  String _sanitizeBadgeText(String text) {
    final String lowered = text.toLowerCase();
    if (lowered.contains('localhost') || lowered.contains('127.0.0.1')) {
      return 'ESP32 antwoord ontvangen';
    }
    return text;
  }

  Widget _buildEsp32LookupBadge() {
    final Widget leadingIcon;
    if (_esp32LookupRunning) {
      leadingIcon = const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (_esp32LookupSucceeded == true) {
      leadingIcon = const Icon(
        Icons.check_circle,
        color: Color(0xFF36D399),
        size: 18,
      );
    } else {
      leadingIcon = const Icon(
        Icons.cancel,
        color: Color(0xFFFF6B6B),
        size: 18,
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              leadingIcon,
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _esp32Status,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton(
                onPressed: _esp32LookupRunning ? null : _startEsp32Lookup,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                ),
                child: const Text('Opnieuw'),
              ),
            ],
          ),
          if (_esp32RawData.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              _sanitizeBadgeText(_esp32RawData),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.82),
                fontSize: 11,
                height: 1.3,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      ),
    );
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
                    _buildEsp32LookupBadge(),
                    const SizedBox(height: 22),
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
