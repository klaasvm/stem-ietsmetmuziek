import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

class Esp32UploadResult {
  const Esp32UploadResult({
    required this.ip,
    required this.fileId,
    required this.fileName,
    required this.serverMessage,
  });

  final String ip;
  final String fileId;
  final String fileName;
  final String serverMessage;
}

class Esp32Service extends ChangeNotifier {
  Esp32Service._();

  static final Esp32Service instance = Esp32Service._();

  bool _lookupRunning = true;
  bool? _lookupSucceeded;
  String _status = 'ESP32 zoeken op netwerk...';
  String _rawData = '';
  String? _ip;
  bool _started = false;
  bool _lookupInProgress = false;
  bool _healthCheckInProgress = false;
  Timer? _retryTimer;

  bool get lookupRunning => _lookupRunning;
  bool? get lookupSucceeded => _lookupSucceeded;
  String get status => _status;
  String get rawData => _rawData;
  String? get ip => _ip;

  void startBackgroundLookup() {
    if (_started) {
      return;
    }

    _started = true;
    _runLookup();
    _retryTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_ip == null) {
        _runLookup();
        return;
      }
      _checkConnectionHealth();
    });
  }

  Future<void> retryNow() async {
    _ip = null;
    _lookupSucceeded = null;
    _lookupRunning = true;
    _status = 'ESP32 zoeken op netwerk...';
    _rawData = '';
    notifyListeners();
    await _runLookup();
  }

  Future<String?> waitForIp({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    startBackgroundLookup();

    if (_ip != null) {
      return _ip;
    }

    final Completer<String?> completer = Completer<String?>();
    late VoidCallback listener;
    Timer? timeoutTimer;

    listener = () {
      if (_ip != null && !completer.isCompleted) {
        completer.complete(_ip);
      }
    };

    addListener(listener);
    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    });

    await _runLookup();

    final String? result = await completer.future;
    timeoutTimer.cancel();
    removeListener(listener);
    return result;
  }

  Future<Esp32UploadResult> uploadFile({
    required Uint8List data,
    required String fileName,
    String? fileId,
  }) async {
    if (data.isEmpty) {
      throw const HttpException('Bestand is leeg.');
    }

    final String? foundIp = await waitForIp();
    if (foundIp == null) {
      throw const HttpException('Geen ESP32 gevonden voor upload.');
    }

    final String safeName = _sanitizeFileName(fileName);
    final String uploadId = (fileId == null || fileId.isEmpty)
        ? DateTime.now().millisecondsSinceEpoch.toString()
        : fileId;

    final Uri uri = Uri.parse('http://$foundIp/upload').replace(
      queryParameters: <String, String>{'name': safeName, 'id': uploadId},
    );

    final HttpClient client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 4);

    try {
      final HttpClientRequest request = await client
          .postUrl(uri)
          .timeout(const Duration(seconds: 5));
      request.headers.contentType = ContentType.binary;
      request.headers.contentLength = data.length;
      request.add(data);

      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final String body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        throw HttpException('Upload mislukt (${response.statusCode}): $body');
      }

      return Esp32UploadResult(
        ip: foundIp,
        fileId: uploadId,
        fileName: safeName,
        serverMessage: body.trim(),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _runLookup() async {
    if (_lookupInProgress || _ip != null) {
      return;
    }

    _lookupInProgress = true;
    _lookupRunning = true;
    _lookupSucceeded = null;
    _status = 'ESP32 zoeken op netwerk...';
    notifyListeners();

    try {
      final String? discoveredIp = await _discoverEsp32Ip();
      if (discoveredIp == null) {
        _lookupRunning = false;
        _lookupSucceeded = false;
        _status = 'Geen ESP32 gevonden (blijft zoeken...)';
        _rawData = 'Geen response ontvangen in lokaal subnet.';
        notifyListeners();
        return;
      }

      final String raw = await _fetchEsp32Raw(discoveredIp);
      _ip = discoveredIp;
      _lookupRunning = false;
      _lookupSucceeded = true;
      _status = 'ESP32 gevonden op $discoveredIp';
      _rawData = raw;
      notifyListeners();
    } catch (error) {
      _lookupRunning = false;
      _lookupSucceeded = false;
      _status = 'ESP32 check mislukt';
      _rawData = 'Fout: $error';
      notifyListeners();
    } finally {
      _lookupInProgress = false;
    }
  }

  Future<void> _checkConnectionHealth() async {
    if (_healthCheckInProgress) {
      return;
    }

    final String? currentIp = _ip;
    if (currentIp == null) {
      return;
    }

    _healthCheckInProgress = true;
    try {
      final bool ok = await _hasExpectedConfirmToken(currentIp);
      if (ok) {
        return;
      }

      _ip = null;
      _lookupRunning = false;
      _lookupSucceeded = false;
      _status = 'ESP32 verbinding verbroken, opnieuw zoeken...';
      _rawData = 'Confirm check faalde op $currentIp';
      notifyListeners();

      await _runLookup();
    } finally {
      _healthCheckInProgress = false;
    }
  }

  Future<String?> _discoverEsp32Ip() async {
    final String? mdnsIp = await _discoverEsp32ViaHostnames();
    if (mdnsIp != null) {
      return mdnsIp;
    }

    if (_ip != null && await _looksLikeEsp32(_ip!)) {
      return _ip;
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
      final List<bool> matches = await Future.wait(batch.map(_looksLikeEsp32));

      for (int i = 0; i < batch.length; i++) {
        if (matches[i]) {
          return batch[i];
        }
      }
    }

    return null;
  }

  Future<String?> _discoverEsp32ViaHostnames() async {
    const List<String> hostnames = <String>['esp32.local', 'esp32'];

    for (final String host in hostnames) {
      try {
        final List<InternetAddress> resolved = await InternetAddress.lookup(
          host,
        ).timeout(const Duration(milliseconds: 900));
        for (final InternetAddress address in resolved) {
          final String testIp = address.address;
          if (!_isPrivateIpv4(testIp)) {
            continue;
          }
          if (await _looksLikeEsp32(testIp)) {
            return testIp;
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

      final String body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(milliseconds: 1200));
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

        final String body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(milliseconds: 1200));

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

  String _sanitizeFileName(String value) {
    final StringBuffer buffer = StringBuffer();
    for (final int codeUnit in value.codeUnits) {
      final String ch = String.fromCharCode(codeUnit);
      final bool allowed = RegExp(r'[A-Za-z0-9._-]').hasMatch(ch);
      buffer.write(allowed ? ch : '_');
    }

    final String sanitized = buffer.toString();
    if (sanitized.isEmpty) {
      return 'upload.mid';
    }
    return sanitized;
  }
}
