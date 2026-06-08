import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LaptopUploadResult {
  const LaptopUploadResult({
    required this.ip,
    required this.fileName,
    required this.serverMessage,
  });

  final String ip;
  final String fileName;
  final String serverMessage;
}

class LaptopService extends ChangeNotifier {
  LaptopService._();

  static final LaptopService instance = LaptopService._();
  static const String _clientType = 'mobile';
  final String _clientId = 'mobile-${DateTime.now().millisecondsSinceEpoch}';

  String? _laptopIp;
  int _laptopPort = 5000;
  bool _manuallyConfigured = false;
  String _status = 'Laptop niet geconfigureerd';
  static const String _prefsKeyIp = 'laptop_ip';
  static const String _prefsKeyPort = 'laptop_port';

  String? get laptopIp => _laptopIp;
  int get laptopPort => _laptopPort;
  bool get manuallyConfigured => _manuallyConfigured;
  String get status => _status;
  bool get isConfigured => _laptopIp != null && _laptopIp!.isNotEmpty;

  Future<void> loadConfig() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _laptopIp = prefs.getString(_prefsKeyIp);
      _laptopPort = prefs.getInt(_prefsKeyPort) ?? 5000;
      _manuallyConfigured = _laptopIp != null;
      if (_laptopIp != null) {
        _status = 'Laptop ingesteld op $_laptopIp:$_laptopPort';
      }
      notifyListeners();
    } catch (_) {
      // ignore
    }
  }

  Future<void> setLaptopIp(String ip, {int port = 5000}) async {
    if (ip.isEmpty) {
      _laptopIp = null;
      _manuallyConfigured = false;
      _status = 'Laptop niet geconfigureerd';
    } else {
      _laptopIp = ip;
      _laptopPort = port;
      _manuallyConfigured = true;
      _status = 'Laptop ingesteld op $ip:$port';
    }

    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (ip.isEmpty) {
        await prefs.remove(_prefsKeyIp);
        await prefs.remove(_prefsKeyPort);
      } else {
        await prefs.setString(_prefsKeyIp, ip);
        await prefs.setInt(_prefsKeyPort, port);
      }
    } catch (_) {
      // ignore
    }

    notifyListeners();
  }

  bool _isValidIpv4(String value) {
    final RegExp pattern = RegExp(
      r'^(25[0-5]|2[0-4]\d|1?\d?\d)\.(25[0-5]|2[0-4]\d|1?\d?\d)\.(25[0-5]|2[0-4]\d|1?\d?\d)\.(25[0-5]|2[0-4]\d|1?\d?\d)$',
    );
    return pattern.hasMatch(value.trim());
  }

  Future<bool> testConnection() async {
    if (_laptopIp == null || _laptopIp!.isEmpty) {
      return false;
    }

    final HttpClient client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);

    try {
      final HttpClientRequest request = await client
          .getUrl(Uri.parse('http://$_laptopIp:$_laptopPort/health'))
          .timeout(const Duration(seconds: 4));
      _setClientHeaders(request);
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 4),
      );

      if (response.statusCode != 200) {
        return false;
      }

      final String body = await response.transform(utf8.decoder).join();
      final dynamic decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> && decoded['status'] == 'ok';
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<LaptopUploadResult> uploadMidiFile({
    required Uint8List data,
    required String fileName,
  }) async {
    if (data.isEmpty) {
      throw const HttpException('Bestand is leeg.');
    }

    if (_laptopIp == null || _laptopIp!.isEmpty) {
      throw const HttpException('Laptop niet geconfigureerd.');
    }

    final Uri uri = Uri.parse('http://$_laptopIp:$_laptopPort/upload');

    final HttpClient client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 4);

    try {
      final HttpClientRequest request = await client
          .postUrl(uri)
          .timeout(const Duration(seconds: 5));
      _setClientHeaders(request);

      // Send as multipart form data
      final String boundary = 'dart-http-boundary-${DateTime.now().millisecondsSinceEpoch}';
      request.headers.contentType = ContentType.parse('multipart/form-data; boundary=$boundary');

      final List<int> formData = _buildMultipartFormData(data, fileName, boundary);
      request.headers.contentLength = formData.length;
      request.add(formData);

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

      final dynamic decoded = jsonDecode(body);
      final String message = decoded is Map ? (decoded['message'] ?? body) : body;

      return LaptopUploadResult(
        ip: _laptopIp!,
        fileName: fileName,
        serverMessage: message,
      );
    } finally {
      client.close(force: true);
    }
  }

  List<int> _buildMultipartFormData(Uint8List fileData, String fileName, String boundary) {
    final List<int> result = <int>[];
    const String crlf = '\r\n';

    // Add file part
    result.addAll(utf8.encode('--$boundary$crlf'));
    result.addAll(utf8.encode('Content-Disposition: form-data; name="file"; filename="$fileName"$crlf'));
    result.addAll(utf8.encode('Content-Type: application/octet-stream$crlf$crlf'));
    result.addAll(fileData);
    result.addAll(utf8.encode(crlf));

    // Add boundary end
    result.addAll(utf8.encode('--$boundary--$crlf'));

    return result;
  }

  void _setClientHeaders(HttpClientRequest request) {
    request.headers.set('X-Client-Type', _clientType);
    request.headers.set('X-Client-Id', _clientId);
  }
}
