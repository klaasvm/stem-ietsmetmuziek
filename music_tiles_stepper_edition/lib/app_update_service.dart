import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pub_semver/pub_semver.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.downloadUrl,
    required this.assetName,
  });

  final String currentVersion;
  final String latestVersion;
  final String downloadUrl;
  final String assetName;
}

class AppUpdateService {
  static const String _owner = 'klaasvm';
  static const String _repo = 'stem-ietsmetmuziek';
  static const String _branch = 'main';
  static const String _versionJsonPath = 'version.json';
  static const String _defaultApkName = 'app-release.apk';

  Future<AppUpdateInfo?> checkForRequiredUpdate() async {
    if (!Platform.isAndroid) {
      return null;
    }

    final PackageInfo packageInfo = await PackageInfo.fromPlatform();
    final String currentVersion = _normalizeVersion(packageInfo.version);

    final Map<String, dynamic> remoteConfig = await _fetchRemoteVersionConfig();
    final String latestVersion = _normalizeVersion(
      (remoteConfig['version'] as String?) ?? '',
    );

    if (latestVersion.isEmpty) {
      return null;
    }

    final Version current = Version.parse(currentVersion);
    final Version latest = Version.parse(latestVersion);

    if (latest <= current) {
      return null;
    }

    final String? configuredTag = _asString(remoteConfig['releaseTag']);
    final String configuredAsset =
        _asString(remoteConfig['apkAssetName']) ?? _defaultApkName;

    final String downloadUrl = await _resolveReleaseApkUrl(
      releaseTag: configuredTag,
      preferredAssetName: configuredAsset,
    );

    return AppUpdateInfo(
      currentVersion: currentVersion,
      latestVersion: latestVersion,
      downloadUrl: downloadUrl,
      assetName: configuredAsset,
    );
  }

  Future<void> installUpdate(
    AppUpdateInfo updateInfo, {
    void Function(String message)? onStatus,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'Automatische APK-update wordt alleen ondersteund op Android.',
      );
    }

    final Completer<void> completer = Completer<void>();

    OtaUpdate()
        .execute(
          updateInfo.downloadUrl,
          destinationFilename: updateInfo.assetName,
        )
        .listen(
          (OtaEvent event) {
            final OtaStatus status = event.status;
            final String value = event.value ?? '';
            onStatus?.call('$status ${value.isEmpty ? '' : value}'.trim());

            if (status == OtaStatus.INSTALLING) {
              if (!completer.isCompleted) {
                completer.complete();
              }
              return;
            }

            if (status == OtaStatus.PERMISSION_NOT_GRANTED_ERROR ||
                status == OtaStatus.INTERNAL_ERROR ||
                status == OtaStatus.DOWNLOAD_ERROR ||
                status == OtaStatus.CHECKSUM_ERROR) {
              if (!completer.isCompleted) {
                completer.completeError(
                  Exception('Update mislukt: $status $value'),
                );
              }
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          },
        );

    return completer.future;
  }

  Future<Map<String, dynamic>> _fetchRemoteVersionConfig() async {
    final Uri uri = Uri.parse(
      'https://raw.githubusercontent.com/$_owner/$_repo/$_branch/$_versionJsonPath',
    );

    final HttpClient client = HttpClient()
      ..userAgent = 'music_tiles_stepper_edition';
    final HttpClientRequest request = await client.getUrl(uri);
    final HttpClientResponse response = await request.close();

    if (response.statusCode != 200) {
      throw HttpException(
        'Kon version.json niet laden (status ${response.statusCode}).',
      );
    }

    final String rawBody = await response.transform(utf8.decoder).join();
    final dynamic decoded = jsonDecode(rawBody);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('version.json moet een JSON object zijn.');
    }

    return decoded;
  }

  Future<String> _resolveReleaseApkUrl({
    required String? releaseTag,
    required String preferredAssetName,
  }) async {
    final String endpoint = (releaseTag != null && releaseTag.isNotEmpty)
        ? 'https://api.github.com/repos/$_owner/$_repo/releases/tags/$releaseTag'
        : 'https://api.github.com/repos/$_owner/$_repo/releases/latest';

    final HttpClient client = HttpClient()
      ..userAgent = 'music_tiles_stepper_edition';
    final HttpClientRequest request = await client.getUrl(Uri.parse(endpoint));
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    final HttpClientResponse response = await request.close();

    if (response.statusCode != 200) {
      throw HttpException(
        'Kon GitHub release niet laden (status ${response.statusCode}).',
      );
    }

    final String body = await response.transform(utf8.decoder).join();
    final dynamic decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('GitHub release response is ongeldig.');
    }

    final List<dynamic> assets =
        decoded['assets'] as List<dynamic>? ?? <dynamic>[];

    for (final dynamic asset in assets) {
      if (asset is! Map<String, dynamic>) {
        continue;
      }
      final String name = (asset['name'] as String?) ?? '';
      final String url = (asset['browser_download_url'] as String?) ?? '';
      if (name == preferredAssetName && url.isNotEmpty) {
        return url;
      }
    }

    for (final dynamic asset in assets) {
      if (asset is! Map<String, dynamic>) {
        continue;
      }
      final String name = (asset['name'] as String?) ?? '';
      final String url = (asset['browser_download_url'] as String?) ?? '';
      if (name.toLowerCase().endsWith('.apk') && url.isNotEmpty) {
        return url;
      }
    }

    throw const FormatException(
      'Geen APK asset gevonden in de geselecteerde release.',
    );
  }

  String _normalizeVersion(String value) {
    final String cleaned = value.trim();
    if (cleaned.isEmpty) {
      return '0.0.0';
    }

    final String withoutPrefix = cleaned.startsWith('v')
        ? cleaned.substring(1)
        : cleaned;
    final RegExp corePattern = RegExp(r'^(\d+)\.(\d+)\.(\d+)');
    final Match? match = corePattern.firstMatch(withoutPrefix);
    if (match == null) {
      return '0.0.0';
    }

    final String core = '${match.group(1)}.${match.group(2)}.${match.group(3)}';
    final String suffix = withoutPrefix.substring(match.end);
    return '$core$suffix';
  }

  String? _asString(Object? value) {
    if (value is! String) {
      return null;
    }
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
