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

  // De variabele die bijhoudt of we écht verbonden zijn
  bool _isConnected = false;

  String? get laptopIp => _laptopIp;
  int get laptopPort => _laptopPort;
  bool get manuallyConfigured => _manuallyConfigured;
  String get status => _status;
  bool get isConfigured => _laptopIp != null && _laptopIp!.isNotEmpty;
  bool get isConnected => _isConnected;

  Future<void> loadConfig() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _laptopIp = prefs.getString(_prefsKeyIp);
      _laptopPort = prefs.getInt(_prefsKeyPort) ?? 5000;
      _manuallyConfigured = _laptopIp != null && _laptopIp!.isNotEmpty;
      
      if (_manuallyConfigured) {
        _status = 'Configuratie geladen: $_laptopIp:$_laptopPort';
        notifyListeners();
        // Direct na het inladen ook testen of de verbinding werkt
        await verifyConnection();
      } else {
        _status = 'Geen laptop configuratie gevonden';
        notifyListeners();
      }
    } catch (e) {
      _status = 'Fout bij laden configuratie: $e';
      notifyListeners();
    }
  }

  Future<void> saveConfig(String ip, int port) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKeyIp, ip);
      await prefs.setInt(_prefsKeyPort, port);
      _laptopIp = ip;
      _laptopPort = port;
      _manuallyConfigured = true;
      _status = 'Configuratie opgeslagen';
      notifyListeners();
      // Direct na het opslaan de connectie testen
      await verifyConnection();
    } catch (e) {
      _status = 'Fout bij opslaan configuratie: $e';
      notifyListeners();
    }
  }

  Future<void> updateIp(String ip) async {
    await saveConfig(ip, _laptopPort);
  }

  // De nieuwe functie die de Python '/health' endpoint controleert
  Future<bool> verifyConnection() async {
    if (!isConfigured) {
      _isConnected = false;
      _status = 'Laptop niet geconfigureerd';
      notifyListeners();
      return false;
    }

    _status = 'Verbinding met laptop testen...';
    notifyListeners();

    final HttpClient client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);

    try {
      final Uri uri = Uri.parse('http://$_laptopIp:$_laptopPort/health');
      final HttpClientRequest request = await client.getUrl(uri);
      
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 3),
      );

      if (response.statusCode == 200) {
        final String body = await response.transform(utf8.decoder).join();
        final dynamic decoded = jsonDecode(body);
        
        if (decoded is Map && decoded['status'] == 'ok') {
          _isConnected = true;
          _status = 'Succesvol verbonden met laptop!';
          notifyListeners();
          return true;
        }
      }

      _isConnected = false;
      _status = 'Laptop reageert met foutcode: ${response.statusCode}';
      notifyListeners();
      return false;
    } catch (e) {
      _isConnected = false;
      _status = 'Kan laptop niet bereiken (staat de server aan?)';
      notifyListeners();
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<LaptopUploadResult> uploadMidiToLaptop(
    Uint8List fileBytes,
    String fileName,
  ) async {
    if (!isConfigured) {
      throw const HttpException('Laptop IP is niet ingesteld. Ga naar dev mode om in te stellen.');
    }

    final HttpClient client = HttpClient();
    try {
      final Uri uri = Uri.parse('http://$_laptopIp:$_laptopPort/upload');
      final HttpClientRequest request = await client.postUrl(uri);

      final String boundary = '----DartFormBoundary${DateTime.now().millisecondsSinceEpoch}';
      request.headers.set('Content-Type', 'multipart/form-data; boundary=$boundary');
      request.headers.set('X-Client-Type', _clientType);
      request.headers.set('X-Client-Id', _clientId);

      final List<int> bodyBytes = _buildMultipartFormData(fileBytes, fileName, boundary);
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);

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

    result.addAll(utf8.encode('--$boundary$crlf'));
    result.addAll(utf8.encode('Content-Disposition: form-data; name="file"; filename="$fileName"$crlf'));
    result.addAll(utf8.encode('Content-Type: application/octet-stream$crlf$crlf'));
    result.addAll(fileData);
    result.addAll(utf8.encode(crlf));
    result.addAll(utf8.encode('--$boundary--$crlf'));

    return result;
  }
}