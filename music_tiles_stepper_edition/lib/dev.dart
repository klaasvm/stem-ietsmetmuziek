import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_midi/flutter_midi.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'editor.dart';
import 'esp32_service.dart';

class DevPage extends StatefulWidget {
  const DevPage({super.key, required this.title});

  final String title;

  @override
  State<DevPage> createState() => _DevPageState();
}

class _DevPageState extends State<DevPage> {
  static const String _soundFontAsset =
      'assets/sf2/generaluser_gs_softsynth_v144.sf2';
  static const String _githubOwner = 'klaasvm';
  static const String _githubRepo = 'stem-ietsmetmuziek';
  static const String _githubBranch = 'main';
  static const String _githubMusicFolder = 'music';
  static const int _editorMaxSimultaneousNotes = 5;

  final FlutterMidi _flutterMidi = FlutterMidi();
  final Esp32Service _esp32Service = Esp32Service.instance;
  final List<Timer> _activeTimers = <Timer>[];

  String? _selectedFileName;
  String? _selectedSourceLabel;
  Uint8List? _fileData;
  ParsedMidiSong? _parsedSong;
  String _hexDisplay = '';
  String _statusMessage = 'Soundfont laden...';
  bool _soundFontReady = false;
  Future<void>? _soundFontLoadFuture;
  bool _isPlaying = false;
  bool _showDebugPanel = true;
  int _playbackSession = 0;
  final List<String> _debugLog = <String>[];
  bool _isDisposing = false;
  Timer? _playheadTimer;
  int _playStartEpochMicros = 0;
  int _playTotalDurationMicros = 0;
  double _playheadMillis = 0;
  List<GitHubMidiSong> _githubSongs = <GitHubMidiSong>[];
  bool _githubSongsLoading = false;
  String _appVersionLabel = 'Versie laden...';
  bool _isUploadingToEsp32 = false;
  bool _isExportingMidi = false;

  @override
  void initState() {
    super.initState();
    _esp32Service.startBackgroundLookup();
    _esp32Service.addListener(_onEsp32ServiceChanged);
    _logDebug('App gestart op ${Platform.operatingSystem}');
    _loadAppVersion();
    // Defer loading the large soundfont until playback is requested to avoid
    // OutOfMemoryError on devices with limited heap.
    // _loadSoundFont();
    _loadGitHubSongCatalog();
  }

  Future<void> ensureSoundFontLoaded() async {
    if (_soundFontReady) return;
    final Future<void> inFlight = _soundFontLoadFuture ??= _loadSoundFont();
    await inFlight;
  }

  Future<void> _uploadSelectedFileToEsp32() async {
    final Uint8List? data = _fileData;
    if (data == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Kies eerst een MIDI-bestand om te uploaden.'),
        ),
      );
      return;
    }

    setState(() {
      _isUploadingToEsp32 = true;
      _statusMessage = 'Upload naar ESP32 gestart...';
    });

    try {
      final String fileId = DateTime.now().millisecondsSinceEpoch.toString();
      final Esp32UploadResult result = await _esp32Service.uploadFile(
        data: data,
        fileName: _selectedFileName ?? 'upload.mid',
        fileId: fileId,
      );

      if (!mounted) {
        return;
      }

      _logDebug(
        'ESP32 upload klaar: ip=${result.ip}, id=${result.fileId}, name=${result.fileName}, server=${result.serverMessage}',
      );
      setState(() {
        _statusMessage =
            'ESP32 upload klaar (${result.fileName}, id=${result.fileId})';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Upload gelukt naar ${result.ip} met id=${result.fileId}',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (error, stackTrace) {
      _logDebug(
        'ESP32 upload mislukt',
        error: error,
        stackTrace: stackTrace,
        updateStatus: true,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = 'ESP32 upload mislukt: $error';
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ESP32 upload mislukt: $error')));
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingToEsp32 = false;
        });
      }
    }
  }

  Future<void> _loadAppVersion() async {
    try {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      if (!mounted) {
        return;
      }

      setState(() {
        _appVersionLabel = packageInfo.buildNumber.isEmpty
            ? packageInfo.version
            : '${packageInfo.version}+${packageInfo.buildNumber}';
      });
      _logDebug('App versie geladen: $_appVersionLabel');
    } catch (error, stackTrace) {
      _logDebug(
        'App versie laden mislukt',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _appVersionLabel = 'Onbekend';
      });
    }
  }

  @override
  void dispose() {
    _isDisposing = true;
    _logDebug('Dispose gestart; playback stop wordt uitgevoerd');
    _stopPlayback();
    _playheadTimer?.cancel();
    _esp32Service.removeListener(_onEsp32ServiceChanged);
    super.dispose();
  }

  void _onEsp32ServiceChanged() {
    if (_isDisposing || !mounted) return;
    setState(() {});
  }

  void _logDebug(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    bool updateStatus = false,
  }) {
    final String timestamp = DateTime.now().toIso8601String();
    final StringBuffer line = StringBuffer('[$timestamp] $message');
    if (error != null) {
      line.write(' | error=$error');
    }

    final String entry = line.toString();
    debugPrint(entry);
    if (stackTrace != null) {
      debugPrint(stackTrace.toString());
    }

    if (_isDisposing || !mounted) {
      return;
    }

    setState(() {
      _debugLog.add(entry);
      if (stackTrace != null) {
        _debugLog.add(stackTrace.toString());
      }
      if (_debugLog.length > 800) {
        _debugLog.removeRange(0, _debugLog.length - 800);
      }
      if (updateStatus) {
        _statusMessage = message;
      }
    });
  }

  Future<void> _loadSoundFont() async {
    final Stopwatch stopwatch = Stopwatch()..start();
    _logDebug('Soundfont laden gestart: $_soundFontAsset', updateStatus: true);
    try {
      _logDebug('rootBundle.load gestart');
      final ByteData soundFontBytes = await rootBundle.load(_soundFontAsset);
      _logDebug(
        'rootBundle.load klaar, bytes=${soundFontBytes.lengthInBytes}, elapsedMs=${stopwatch.elapsedMilliseconds}',
      );

      _logDebug('flutter_midi.unmute gestart');
      try {
        await _flutterMidi.unmute();
        _logDebug(
          'flutter_midi.unmute klaar, elapsedMs=${stopwatch.elapsedMilliseconds}',
        );
      } catch (error, stackTrace) {
        _logDebug(
          'flutter_midi.unmute mislukt, doorgaan zonder unmute',
          error: error,
          stackTrace: stackTrace,
        );
      }

      _logDebug('flutter_midi.prepare gestart');
      await _flutterMidi
          .prepare(
            sf2: soundFontBytes,
            name: 'generaluser_gs_softsynth_v144.sf2',
          )
          .timeout(const Duration(seconds: 20));
      _logDebug(
        'flutter_midi.prepare klaar, totalElapsedMs=${stopwatch.elapsedMilliseconds}',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _soundFontReady = true;
        _statusMessage = 'Piano soundfont geladen';
      });
      _logDebug('Soundfont status op ready gezet', updateStatus: true);
    } catch (error) {
      _logDebug(
        'Soundfont laden mislukt na ${stopwatch.elapsedMilliseconds}ms',
        error: error,
        updateStatus: true,
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _statusMessage = 'Soundfont laden mislukt: $error';
      });
    } finally {
      if (!_soundFontReady) {
        _soundFontLoadFuture = null;
      }
    }
  }

  Future<void> _loadGitHubSongCatalog() async {
    if (_githubSongsLoading) {
      return;
    }

    _githubSongsLoading = true;
    _logDebug('GitHub song catalog laden gestart');

    try {
      final Uri uri = Uri.parse(
        'https://api.github.com/repos/$_githubOwner/$_githubRepo/git/trees/$_githubBranch?recursive=1',
      );
      final HttpClient client = HttpClient();
      client.userAgent = 'music_tiles_stepper_edition';
      final HttpClientRequest request = await client.getUrl(uri);
      final HttpClientResponse response = await request.close();

      if (response.statusCode != 200) {
        throw HttpException('GitHub API status ${response.statusCode}');
      }

      final String responseBody = await response.transform(utf8.decoder).join();
      final dynamic decoded = jsonDecode(responseBody);
      if (decoded is! Map<String, dynamic>) {
        throw FormatException('GitHub API response is geen object');
      }

      final List<GitHubMidiSong> songs = <GitHubMidiSong>[];
      final List<dynamic> treeEntries =
          decoded['tree'] as List<dynamic>? ?? <dynamic>[];
      for (final dynamic entry in treeEntries) {
        if (entry is! Map<String, dynamic>) {
          continue;
        }

        final String? path = entry['path'] as String?;
        final String? type = entry['type'] as String?;
        if (path == null || type != 'blob') {
          continue;
        }
        if (!path.startsWith('$_githubMusicFolder/')) {
          continue;
        }
        if (!path.toLowerCase().endsWith('.mid') &&
            !path.toLowerCase().endsWith('.midi')) {
          continue;
        }

        songs.add(GitHubMidiSong(name: path.split('/').last, path: path));
      }

      songs.sort(
        (GitHubMidiSong a, GitHubMidiSong b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _githubSongs = songs;
        _statusMessage = songs.isEmpty
            ? 'GitHub songs geladen: geen MIDI-files gevonden'
            : 'GitHub songs geladen: ${songs.length} files';
      });
      _logDebug('GitHub song catalog klaar: count=${songs.length}');
    } catch (error, stackTrace) {
      _logDebug(
        'GitHub song catalog laden mislukt',
        error: error,
        stackTrace: stackTrace,
        updateStatus: true,
      );
      if (mounted) {
        setState(() {
          _statusMessage = 'GitHub songs laden mislukt: $error';
        });
      }
    } finally {
      _githubSongsLoading = false;
    }
  }

  Future<void> _openGitHubSongPicker() async {
    if (_githubSongs.isEmpty) {
      await _loadGitHubSongCatalog();
    }

    if (!mounted) {
      return;
    }

    if (_githubSongs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Geen GitHub MIDI songs gevonden.')),
      );
      return;
    }

    final GitHubMidiSong? selectedSong =
        await showModalBottomSheet<GitHubMidiSong>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          builder: (BuildContext context) {
            return SafeArea(
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _githubSongs.length + 1,
                separatorBuilder: (_, int separatorIndex) =>
                    const Divider(height: 1),
                itemBuilder: (BuildContext context, int index) {
                  if (index == 0) {
                    return ListTile(
                      leading: const Icon(Icons.cloud_download),
                      title: Text(
                        'GitHub songs ($_githubOwner/$_githubRepo/music)',
                      ),
                      subtitle: Text('$_githubBranch branch'),
                    );
                  }

                  final GitHubMidiSong song = _githubSongs[index - 1];
                  return ListTile(
                    leading: const Icon(Icons.music_note),
                    title: Text(song.name),
                    subtitle: Text(song.path),
                    onTap: () => Navigator.of(context).pop(song),
                  );
                },
              ),
            );
          },
        );

    if (selectedSong == null) {
      _logDebug('GitHub song picker geannuleerd');
      return;
    }

    await _importGitHubSong(selectedSong);
  }

  Future<void> _importGitHubSong(GitHubMidiSong song) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    _logDebug('GitHub song import gestart: ${song.name}');

    try {
      final String rawUrl =
          'https://raw.githubusercontent.com/$_githubOwner/$_githubRepo/$_githubBranch/${song.path}';
      final HttpClient client = HttpClient();
      client.userAgent = 'music_tiles_stepper_edition';
      final HttpClientRequest request = await client.getUrl(Uri.parse(rawUrl));
      final HttpClientResponse response = await request.close();

      if (response.statusCode != 200) {
        throw HttpException(
          'GitHub raw download status ${response.statusCode}',
        );
      }

      final Uint8List bytes = await response
          .fold<BytesBuilder>(BytesBuilder(), (
            BytesBuilder builder,
            List<int> chunk,
          ) {
            builder.add(chunk);
            return builder;
          })
          .then((BytesBuilder builder) => builder.takeBytes());

      _logDebug(
        'GitHub song bytes geladen: ${bytes.length} bytes, elapsedMs=${stopwatch.elapsedMilliseconds}',
      );

      ParsedMidiSong? parsedSong;
      try {
        final Stopwatch parseWatch = Stopwatch()..start();
        parsedSong = MidiParser.parse(bytes);
        _logDebug(
          'GitHub song parser klaar in ${parseWatch.elapsedMilliseconds}ms: notes=${parsedSong.notes.length}, maxPolyphony=${parsedSong.maxSimultaneousNotes}',
        );
      } catch (error, stackTrace) {
        _logDebug(
          'GitHub song parser faalde',
          error: error,
          stackTrace: stackTrace,
        );
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _selectedFileName = song.name;
        _selectedSourceLabel = 'GitHub';
        _fileData = bytes;
        _parsedSong = parsedSong;
        _playheadMillis = 0;
        _hexDisplay = _formatHexDump(bytes);
        _statusMessage = parsedSong == null
            ? 'GitHub song geladen: ${song.name} (parser fout)'
            : 'GitHub song geladen: ${song.name} (${parsedSong.notes.length} noten, max ${parsedSong.maxSimultaneousNotes} tegelijk)';
      });
      _logDebug('GitHub song import klaar: ${song.name}');
    } catch (error, stackTrace) {
      _logDebug(
        'GitHub song import mislukt',
        error: error,
        stackTrace: stackTrace,
        updateStatus: true,
      );
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('GitHub song import mislukt: $error')),
      );
    }
  }

  Future<void> _pickMidiFile() async {
    final Stopwatch stopwatch = Stopwatch()..start();
    _logDebug('Bestandskiezer gestart');
    try {
      final FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['mid', 'midi'],
        withData: true,
      );

      if (result == null) {
        _logDebug(
          'Bestandskiezer geannuleerd na ${stopwatch.elapsedMilliseconds}ms',
        );
        return;
      }

      final PlatformFile file = result.files.first;
      _logDebug(
        'Bestand gekozen: name=${file.name}, size=${file.size}, hasBytes=${file.bytes != null}, path=${file.path}',
      );
      final Uint8List bytes =
          file.bytes ?? await File(file.path!).readAsBytes();
      _logDebug(
        'Bestand bytes geladen: ${bytes.length} bytes, elapsedMs=${stopwatch.elapsedMilliseconds}',
      );

      ParsedMidiSong? parsedSong;
      try {
        final Stopwatch parseWatch = Stopwatch()..start();
        parsedSong = MidiParser.parse(bytes);
        _logDebug(
          'Parser bij openen klaar in ${parseWatch.elapsedMilliseconds}ms: notes=${parsedSong.notes.length}, maxPolyphony=${parsedSong.maxSimultaneousNotes}, durationMs=${(parsedSong.totalDurationMicros / 1000).round()}',
        );
      } catch (error, stackTrace) {
        _logDebug(
          'Parser bij openen faalde (raw-data blijft zichtbaar)',
          error: error,
          stackTrace: stackTrace,
        );
      }

      setState(() {
        _selectedFileName = file.name;
        _selectedSourceLabel = 'Lokaal';
        _fileData = bytes;
        _parsedSong = parsedSong;
        _playheadMillis = 0;
        _hexDisplay = _formatHexDump(bytes);
        _statusMessage = parsedSong == null
            ? 'Bestand geladen: ${file.name} (parser fout)'
            : 'Bestand geladen: ${file.name} (${parsedSong.notes.length} noten, max ${parsedSong.maxSimultaneousNotes} tegelijk)';
      });
      _logDebug('Hexdump opgebouwd, chars=${_hexDisplay.length}');
    } catch (error) {
      _logDebug(
        'Fout tijdens bestandskiezer',
        error: error,
        updateStatus: true,
      );
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fout bij openen bestand: $error')),
      );
    }
  }

  Future<ParsedMidiSong?> _ensureParsedSong() async {
    final ParsedMidiSong? existing = _parsedSong;
    if (existing != null) {
      return existing;
    }

    final Uint8List? bytes = _fileData;
    if (bytes == null) {
      return null;
    }

    final ParsedMidiSong parsed = MidiParser.parse(bytes);
    if (!mounted) {
      return parsed;
    }

    setState(() {
      _parsedSong = parsed;
    });
    return parsed;
  }

  Future<void> _openFixEditor() async {
    final ParsedMidiSong? song = await _ensureParsedSong();
    if (song == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kies eerst een MIDI-bestand.')),
      );
      return;
    }

    final MidiEditDraft draft = MidiEditDraft(
      notes: song.notes
          .asMap()
          .entries
          .map(
            (MapEntry<int, MidiNoteEvent> entry) => MidiEditNote(
              id: entry.key,
              note: entry.value.note,
              velocity: entry.value.velocity,
              startMicros: entry.value.startMicros,
              endMicros: entry.value.endMicros,
            ),
          )
          .toList(),
      totalDurationMicros: song.totalDurationMicros,
      rawNoteCount: song.rawNoteCount,
      tempoChangeCount: song.tempoChangeCount,
      trackCount: song.trackCount,
      format: song.format,
      ticksPerQuarterNote: song.ticksPerQuarterNote,
    );

    final MidiEditResult? result = await Navigator.of(context)
        .push<MidiEditResult>(
          MaterialPageRoute<MidiEditResult>(
            builder: (BuildContext context) => EditorPage(
              fileName: _selectedFileName ?? 'Onbekend MIDI-bestand',
              initialDraft: draft,
              maxSimultaneousNotes: _editorMaxSimultaneousNotes,
            ),
          ),
        );

    if (result == null || !mounted) {
      _logDebug('Fix editor geannuleerd');
      return;
    }

    final List<MidiNoteEvent> updatedNotes = result.draft.notes
        .map(
          (MidiEditNote note) => MidiNoteEvent(
            note: note.note,
            velocity: note.velocity,
            startMicros: note.startMicros,
            endMicros: note.endMicros,
          ),
        )
        .toList();

    int maxSimultaneousNotes = 0;
    final List<_NoteBoundary> boundaries = <_NoteBoundary>[];
    for (final MidiNoteEvent note in updatedNotes) {
      boundaries.add(_NoteBoundary(time: note.startMicros, delta: 1));
      boundaries.add(_NoteBoundary(time: note.endMicros, delta: -1));
    }
    boundaries.sort((a, b) {
      final int compareTime = a.time.compareTo(b.time);
      if (compareTime != 0) {
        return compareTime;
      }
      return a.delta.compareTo(b.delta);
    });
    int active = 0;
    for (final _NoteBoundary boundary in boundaries) {
      active += boundary.delta;
      if (active > maxSimultaneousNotes) {
        maxSimultaneousNotes = active;
      }
    }

    setState(() {
      _parsedSong = ParsedMidiSong(
        notes: updatedNotes,
        totalDurationMicros: result.draft.totalDurationMicros,
        format: result.draft.format,
        trackCount: result.draft.trackCount,
        ticksPerQuarterNote: result.draft.ticksPerQuarterNote,
        tempoChangeCount: result.draft.tempoChangeCount,
        rawNoteCount: result.draft.rawNoteCount,
        maxSimultaneousNotes: maxSimultaneousNotes,
      );
      _statusMessage =
          'Fix toegepast: ${result.removedNoteCount} noten verwijderd, max nu $maxSimultaneousNotes';
      _selectedSourceLabel = _selectedSourceLabel == null
          ? 'Bewerkt in Fix'
          : '$_selectedSourceLabel (Fix)';
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Fix opgeslagen. Verwijderd: ${result.removedNoteCount}. Max tegelijk nu: $maxSimultaneousNotes.',
        ),
      ),
    );
  }

  Future<void> _exportEditedMidi() async {
    if (_isExportingMidi) {
      return;
    }

    final ParsedMidiSong? song = await _ensureParsedSong();
    if (song == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kies eerst een MIDI-bestand.')),
      );
      return;
    }

    setState(() {
      _isExportingMidi = true;
    });

    try {
      final Uint8List midiBytes = MidiFileWriter.fromParsedSong(song);
      final String baseName = (_selectedFileName ?? 'edited_song.mid')
          .replaceAll(RegExp(r'\.(mid|midi)$', caseSensitive: false), '');
      final String suggestedName = '${baseName}_fixed.mid';

      final String? outputPath = await FilePicker.saveFile(
        dialogTitle: 'Sla aangepaste MIDI op',
        fileName: suggestedName,
        type: FileType.custom,
        allowedExtensions: const <String>['mid'],
        bytes: midiBytes,
      );

      if (outputPath == null) {
        _logDebug('MIDI export geannuleerd door gebruiker');
        return;
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _statusMessage =
            'Aangepaste MIDI opgeslagen: ${outputPath.split(Platform.pathSeparator).last}';
      });
      _logDebug(
        'MIDI export klaar: path=$outputPath, bytes=${midiBytes.length}',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('MIDI opgeslagen op: $outputPath')),
      );
    } catch (error, stackTrace) {
      _logDebug(
        'MIDI export mislukt',
        error: error,
        stackTrace: stackTrace,
        updateStatus: true,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('MIDI export mislukt: $error')));
    } finally {
      if (mounted) {
        setState(() {
          _isExportingMidi = false;
        });
      }
    }
  }

  Future<void> _playSelectedMidi() async {
    _playbackSession += 1;
    final int session = _playbackSession;
    final Stopwatch stopwatch = Stopwatch()..start();
    _logDebug('Playback sessie $session gestart');

    if (!_soundFontReady) {
      _logDebug('Playback sessie $session wacht op soundfont laden', updateStatus: true);
      if (mounted) {
        setState(() {
          _statusMessage = 'Soundfont laden...';
        });
      }
      await ensureSoundFontLoaded();
    }

    if (!_soundFontReady) {
      _logDebug(
        'Playback sessie $session afgebroken: soundfont niet ready',
        updateStatus: true,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Soundfont is nog niet geladen.')),
      );
      return;
    }

    final Uint8List? bytes = _fileData;
    if (bytes == null) {
      _logDebug(
        'Playback sessie $session afgebroken: geen MIDI bytes',
        updateStatus: true,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kies eerst een .mid bestand.')),
      );
      return;
    }

    ParsedMidiSong? song = _parsedSong;
    if (song == null) {
      try {
        final Stopwatch parseWatch = Stopwatch()..start();
        song = MidiParser.parse(bytes);
        _logDebug(
          'Parser on-demand klaar in ${parseWatch.elapsedMilliseconds}ms: format=${song.format}, tracks=${song.trackCount}, tpqn=${song.ticksPerQuarterNote}, tempos=${song.tempoChangeCount}, rawNotes=${song.rawNoteCount}, playableNotes=${song.notes.length}, maxPolyphony=${song.maxSimultaneousNotes}, durationMs=${(song.totalDurationMicros / 1000).round()}',
        );
        if (mounted) {
          setState(() {
            _parsedSong = song;
          });
        }
      } catch (error) {
        _logDebug(
          'MIDI parser fout in sessie $session',
          error: error,
          updateStatus: true,
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('MIDI parser fout: $error')));
        return;
      }
    }

    final ParsedMidiSong finalSong = song;

    if (finalSong.notes.isEmpty) {
      _logDebug(
        'Playback sessie $session: geen noten om af te spelen',
        updateStatus: true,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Geen afspeelbare noten gevonden in dit MIDI-bestand.'),
        ),
      );
      return;
    }

    _stopPlayback();
    setState(() {
      _isPlaying = true;
      _statusMessage = 'Afspelen gestart';
    });
    _startPlayhead(finalSong.totalDurationMicros);
    _logDebug(
      'Playback sessie $session loopt, notes=${finalSong.notes.length}',
      updateStatus: true,
    );

    final int playStartMicros = DateTime.now().microsecondsSinceEpoch;
    int noteIndex = 0;

    for (final MidiNoteEvent note in finalSong.notes) {
      if (!mounted || !_isPlaying) {
        _logDebug(
          'Playback sessie $session onderbroken bij noteIndex=$noteIndex',
        );
        break;
      }

      final int targetStartMicros = playStartMicros + note.startMicros;
      final int delayMicros =
          targetStartMicros - DateTime.now().microsecondsSinceEpoch;
      if (delayMicros > 0) {
        await Future<void>.delayed(Duration(microseconds: delayMicros));
      }

      if (!mounted || !_isPlaying) {
        _logDebug(
          'Playback sessie $session stop na wachttijd bij noteIndex=$noteIndex',
        );
        break;
      }

      try {
        await _flutterMidi.playMidiNote(midi: note.note);
      } catch (error, stackTrace) {
        _logDebug(
          'playMidiNote fout in sessie $session op noteIndex=$noteIndex (note=${note.note})',
          error: error,
          stackTrace: stackTrace,
          updateStatus: true,
        );
        rethrow;
      }

      if (noteIndex < 20 || noteIndex % 200 == 0) {
        _logDebug(
          'Sessie $session noteOn index=$noteIndex note=${note.note} velocity=${note.velocity} startMs=${(note.startMicros / 1000).round()} durMs=${(note.durationMicros / 1000).round()}',
        );
      }

      final Timer offTimer = Timer(
        Duration(microseconds: note.durationMicros),
        () {
          try {
            _flutterMidi.stopMidiNote(midi: note.note);
          } catch (error) {
            _logDebug(
              'stopMidiNote timer fout voor note=${note.note}',
              error: error,
            );
          }
        },
      );
      _activeTimers.add(offTimer);
      noteIndex += 1;
    }

    final int endMicros = playStartMicros + finalSong.totalDurationMicros;
    final int remainingMicros =
        endMicros - DateTime.now().microsecondsSinceEpoch;
    if (remainingMicros > 0) {
      await Future<void>.delayed(Duration(microseconds: remainingMicros));
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _isPlaying = false;
      _statusMessage = 'Afspelen klaar';
      _playheadMillis = finalSong.totalDurationMicros / 1000;
    });
    _playheadTimer?.cancel();
    _playheadTimer = null;
    _logDebug(
      'Playback sessie $session klaar in ${stopwatch.elapsedMilliseconds}ms',
      updateStatus: true,
    );
  }

  void _startPlayhead(int totalDurationMicros) {
    _playheadTimer?.cancel();
    _playStartEpochMicros = DateTime.now().microsecondsSinceEpoch;
    _playTotalDurationMicros = totalDurationMicros;
    _playheadMillis = 0;

    _playheadTimer = Timer.periodic(const Duration(milliseconds: 33), (
      Timer timer,
    ) {
      if (!mounted || !_isPlaying) {
        timer.cancel();
        return;
      }

      final int elapsedMicros =
          DateTime.now().microsecondsSinceEpoch - _playStartEpochMicros;
      final int clampedMicros = elapsedMicros.clamp(
        0,
        _playTotalDurationMicros,
      );
      setState(() {
        _playheadMillis = clampedMicros / 1000;
      });
    });
  }

  void _stopPlayback() {
    _logDebug(
      'Stop playback gevraagd; timers=${_activeTimers.length}, wasPlaying=$_isPlaying',
    );
    for (final Timer timer in _activeTimers) {
      timer.cancel();
    }
    _activeTimers.clear();
    _playheadTimer?.cancel();
    _playheadTimer = null;
    _flutterMidi.stopMidiNote(midi: 0);
    if (mounted) {
      setState(() {
        _isPlaying = false;
      });
    }
    _logDebug('Stop playback afgerond');
  }

  String _formatHexDump(Uint8List data) {
    final StringBuffer buffer = StringBuffer();
    buffer.writeln('Bestandsgrootte: ${data.length} bytes\n');
    buffer.writeln('Hexadecimale weergave:\n');

    for (int index = 0; index < data.length; index += 16) {
      final int end = (index + 16 < data.length) ? index + 16 : data.length;
      final Uint8List chunk = data.sublist(index, end);

      final String hexBytes = chunk
          .map((int byte) {
            return byte.toRadixString(16).padLeft(2, '0');
          })
          .join(' ');
      buffer.write(hexBytes.padRight(48));
      buffer.write('  ');

      for (final int byte in chunk) {
        if (byte >= 32 && byte <= 126) {
          buffer.writeCharCode(byte);
        } else {
          buffer.write('.');
        }
      }

      buffer.writeln();
    }

    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            onPressed: _pickMidiFile,
            icon: const Icon(Icons.folder_open),
            tooltip: 'MIDI-bestand openen',
          ),
          IconButton(
            onPressed: _isPlaying ? _stopPlayback : _playSelectedMidi,
            icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow),
            tooltip: _isPlaying ? 'Stop' : 'Afspelen',
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Card(
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _statusMessage,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _soundFontReady
                            ? 'Piano soundfont actief'
                            : 'Soundfont nog aan het laden',
                      ),
                      const SizedBox(height: 6),
                      Text('App versie: $_appVersionLabel'),
                      const SizedBox(height: 6),
                      Text('Debug regels: ${_debugLog.length}'),
                      if (_selectedSourceLabel != null) ...[
                        const SizedBox(height: 4),
                        Text('Bron: $_selectedSourceLabel'),
                      ],
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          FilledButton.icon(
                            onPressed: _githubSongsLoading
                                ? null
                                : _openGitHubSongPicker,
                            icon: const Icon(Icons.cloud_download),
                            label: Text(
                              _githubSongsLoading
                                  ? 'GitHub songs laden...'
                                  : 'GitHub songs',
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: _pickMidiFile,
                            icon: const Icon(Icons.folder_open),
                            label: const Text('MIDI openen'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: _isPlaying
                                ? _stopPlayback
                                : _playSelectedMidi,
                            icon: Icon(
                              _isPlaying ? Icons.stop : Icons.play_arrow,
                            ),
                            label: Text(_isPlaying ? 'Stop' : 'Afspelen'),
                          ),
                          FilledButton.icon(
                            onPressed: _openFixEditor,
                            icon: const Icon(Icons.auto_fix_high),
                            label: const Text('Fix'),
                          ),
                          FilledButton.icon(
                            onPressed: _isExportingMidi
                                ? null
                                : _exportEditedMidi,
                            icon: _isExportingMidi
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.download),
                            label: Text(
                              _isExportingMidi ? 'Opslaan...' : 'Download MIDI',
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: _isUploadingToEsp32
                                ? null
                                : _uploadSelectedFileToEsp32,
                            icon: _isUploadingToEsp32
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.upload_file),
                            label: Text(
                              _isUploadingToEsp32
                                  ? 'Uploaden...'
                                  : 'Upload naar ESP32',
                            ),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: () {
                              setState(() {
                                _showDebugPanel = !_showDebugPanel;
                              });
                            },
                            icon: Icon(
                              _showDebugPanel
                                  ? Icons.bug_report
                                  : Icons.bug_report_outlined,
                            ),
                            label: Text(
                              _showDebugPanel
                                  ? 'Debug verbergen'
                                  : 'Debug tonen',
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: _debugLog.isEmpty
                                ? null
                                : () {
                                    Clipboard.setData(
                                      ClipboardData(text: _debugLog.join('\n')),
                                    );
                                    _logDebug(
                                      'Debuglog gekopieerd naar klembord',
                                    );
                                  },
                            icon: const Icon(Icons.copy_all),
                            label: const Text('Kopieer debuglog'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _debugLog.isEmpty
                                ? null
                                : () {
                                    setState(() {
                                      _debugLog.clear();
                                    });
                                    _logDebug('Debuglog gewist');
                                  },
                            icon: const Icon(Icons.delete_sweep),
                            label: const Text('Wis debuglog'),
                          ),
                        ],
                      ),
                      if (_selectedFileName != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Bestand: $_selectedFileName',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                      if (_selectedSourceLabel != null) ...[
                        const SizedBox(height: 4),
                        Text('Importbron: $_selectedSourceLabel'),
                      ],
                      const SizedBox(height: 12),
                      _buildEsp32CacheCard(),
                    ],
                  ),
                ),
              ),
            ),
            if (_showDebugPanel)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  height: 180,
                  child: Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: _debugLog.isEmpty
                          ? const Text('Nog geen debugregels')
                          : SingleChildScrollView(
                              child: SelectableText(
                                _debugLog.join('\n'),
                                style: const TextStyle(
                                  fontFamily: 'Courier',
                                  fontSize: 11,
                                  height: 1.3,
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            if (_parsedSong != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'MIDI Visualizer',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Playhead: ${_playheadMillis.toStringAsFixed(0)} ms / ${(_parsedSong!.totalDurationMicros / 1000).round()} ms',
                        ),
                        Text(
                          'Max tegelijk gespeelde noten: ${_parsedSong!.maxSimultaneousNotes}',
                        ),
                        const SizedBox(height: 10),
                        LayoutBuilder(
                          builder:
                              (
                                BuildContext context,
                                BoxConstraints constraints,
                              ) {
                                return SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: _MidiPianoRoll(
                                    song: _parsedSong!,
                                    playheadMillis: _playheadMillis,
                                    minWidth: constraints.maxWidth,
                                  ),
                                );
                              },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _fileData == null
                      ? SizedBox(
                          height: 160,
                          child: Center(
                            child: Text(
                              'Kies een .mid bestand om de raw data te zien en af te spelen',
                              style: Theme.of(context).textTheme.titleMedium,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : SelectableText(
                          _hexDisplay,
                          style: const TextStyle(
                            fontFamily: 'Courier',
                            fontSize: 11,
                            height: 1.35,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEsp32CacheCard() {
    final List<Esp32CacheEntry> cached = _esp32Service.cachedDevices;
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Gevonden ESP32 apparaten', style: TextStyle(fontWeight: FontWeight.bold)),
                TextButton.icon(
                  onPressed: () => _showAddManualEsp32Dialog(),
                  icon: const Icon(Icons.add),
                  label: const Text('Toevoegen'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (cached.isEmpty)
              const Text('Geen apparaten in cache')
            else
              Column(
                children: cached.map((entry) {
                  return ListTile(
                    title: Text(entry.ip),
                    subtitle: Text('Laatste: ${entry.lastSeen.toLocal()} — ${entry.healthy ? 'OK' : 'onbekend'}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.check_circle_outline),
                          tooltip: 'Gebruik als actieve ESP32',
                          onPressed: () {
                            _esp32Service.setManualIp(entry.ip);
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit),
                          tooltip: 'Bewerken',
                          onPressed: () => _showEditCachedIpDialog(entry.ip),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete),
                          tooltip: 'Verwijderen',
                          onPressed: () {
                            _esp32Service.removeCachedIp(entry.ip);
                          },
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddManualEsp32Dialog() async {
    final TextEditingController ctrl = TextEditingController();
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('Handmatige ESP32 toevoegen'),
          content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(hintText: 'IP adres, bijv. 192.168.1.42'),
            keyboardType: TextInputType.number,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Annuleren')),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()), child: const Text('Toevoegen')),
          ],
        );
      },
    );

    if (result == null || result.isEmpty) return;
    await _esp32Service.addOrUpdateCachedIp(result);
  }

  Future<void> _showEditCachedIpDialog(String existingIp) async {
    final TextEditingController ctrl = TextEditingController(text: existingIp);
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('Bewerk cached IP'),
          content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(hintText: 'IP adres'),
            keyboardType: TextInputType.number,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Annuleren')),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()), child: const Text('Opslaan')),
          ],
        );
      },
    );

    if (result == null || result.isEmpty) return;
    // remove old, add new
    _esp32Service.removeCachedIp(existingIp);
    await _esp32Service.addOrUpdateCachedIp(result);
  }
}

class MidiNoteEvent {
  MidiNoteEvent({
    required this.note,
    required this.velocity,
    required this.startMicros,
    required this.endMicros,
  });

  final int note;
  final int velocity;
  final int startMicros;
  final int endMicros;

  int get durationMicros => endMicros - startMicros;
}

class ParsedMidiSong {
  ParsedMidiSong({
    required this.notes,
    required this.totalDurationMicros,
    required this.format,
    required this.trackCount,
    required this.ticksPerQuarterNote,
    required this.tempoChangeCount,
    required this.rawNoteCount,
    required this.maxSimultaneousNotes,
  });

  final List<MidiNoteEvent> notes;
  final int totalDurationMicros;
  final int format;
  final int trackCount;
  final int ticksPerQuarterNote;
  final int tempoChangeCount;
  final int rawNoteCount;
  final int maxSimultaneousNotes;
}

class MidiFileWriter {
  static Uint8List fromParsedSong(ParsedMidiSong song) {
    final int ticksPerQuarterNote = song.ticksPerQuarterNote <= 0
        ? 480
        : song.ticksPerQuarterNote;
    const int microsPerQuarterNote = 500000;

    final List<_MidiFileEvent> events = <_MidiFileEvent>[];
    for (final MidiNoteEvent note in song.notes) {
      final int midiNote = note.note.clamp(0, 127);
      final int velocity = note.velocity.clamp(1, 127);
      final int startTick = _microsToTicks(
        note.startMicros,
        ticksPerQuarterNote,
        microsPerQuarterNote,
      );
      final int endTickRaw = _microsToTicks(
        note.endMicros,
        ticksPerQuarterNote,
        microsPerQuarterNote,
      );
      final int endTick = endTickRaw <= startTick ? startTick + 1 : endTickRaw;

      events.add(
        _MidiFileEvent(
          tick: startTick,
          status: 0x90,
          data1: midiNote,
          data2: velocity,
          isNoteOff: false,
        ),
      );
      events.add(
        _MidiFileEvent(
          tick: endTick,
          status: 0x80,
          data1: midiNote,
          data2: 0,
          isNoteOff: true,
        ),
      );
    }

    events.sort((a, b) {
      final int tickCompare = a.tick.compareTo(b.tick);
      if (tickCompare != 0) {
        return tickCompare;
      }
      if (a.isNoteOff != b.isNoteOff) {
        return a.isNoteOff ? -1 : 1;
      }
      return a.data1.compareTo(b.data1);
    });

    final List<int> trackData = <int>[];
    int previousTick = 0;

    trackData.addAll(<int>[0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]);

    for (final _MidiFileEvent event in events) {
      final int delta = event.tick - previousTick;
      trackData.addAll(_encodeVarInt(delta));
      trackData.add(event.status);
      trackData.add(event.data1);
      trackData.add(event.data2);
      previousTick = event.tick;
    }

    trackData.addAll(<int>[0x00, 0xFF, 0x2F, 0x00]);

    final BytesBuilder output = BytesBuilder();
    output.add(<int>[0x4D, 0x54, 0x68, 0x64]);
    output.add(_encodeUint32(6));
    output.add(_encodeUint16(0));
    output.add(_encodeUint16(1));
    output.add(_encodeUint16(ticksPerQuarterNote));
    output.add(<int>[0x4D, 0x54, 0x72, 0x6B]);
    output.add(_encodeUint32(trackData.length));
    output.add(trackData);
    return output.takeBytes();
  }

  static int _microsToTicks(
    int micros,
    int ticksPerQuarterNote,
    int microsPerQuarterNote,
  ) {
    if (micros <= 0) {
      return 0;
    }
    return (micros * ticksPerQuarterNote) ~/ microsPerQuarterNote;
  }

  static List<int> _encodeVarInt(int value) {
    int buffer = value & 0x7F;
    final List<int> encoded = <int>[];
    while ((value >>= 7) > 0) {
      buffer <<= 8;
      buffer |= ((value & 0x7F) | 0x80);
    }
    while (true) {
      encoded.add(buffer & 0xFF);
      if ((buffer & 0x80) != 0) {
        buffer >>= 8;
      } else {
        break;
      }
    }
    return encoded;
  }

  static List<int> _encodeUint16(int value) {
    return <int>[(value >> 8) & 0xFF, value & 0xFF];
  }

  static List<int> _encodeUint32(int value) {
    return <int>[
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];
  }
}

class _MidiFileEvent {
  _MidiFileEvent({
    required this.tick,
    required this.status,
    required this.data1,
    required this.data2,
    required this.isNoteOff,
  });

  final int tick;
  final int status;
  final int data1;
  final int data2;
  final bool isNoteOff;
}

class MidiParser {
  static ParsedMidiSong parse(Uint8List bytes) {
    final _ByteReader reader = _ByteReader(bytes);
    final String header = reader.readAscii(4);
    if (header != 'MThd') {
      throw FormatException('MIDI header MThd ontbreekt');
    }

    final int headerLength = reader.readUint32();
    if (headerLength < 6) {
      throw FormatException('Ongeldige MIDI header lengte: $headerLength');
    }

    final int format = reader.readUint16();
    final int trackCount = reader.readUint16();
    final int division = reader.readUint16();
    if (division & 0x8000 != 0) {
      throw FormatException('SMPTE tijdsindeling wordt niet ondersteund');
    }
    final int ticksPerQuarterNote = division;

    if (headerLength > 6) {
      reader.skip(headerLength - 6);
    }

    final List<_ParsedTrackNote> parsedNotes = <_ParsedTrackNote>[];
    final List<_TempoChange> tempoChanges = <_TempoChange>[];
    int rawNoteCount = 0;
    int maxTick = 0;

    for (int trackIndex = 0; trackIndex < trackCount; trackIndex++) {
      final String trackChunk = reader.readAscii(4);
      if (trackChunk != 'MTrk') {
        throw FormatException(
          'Verwacht MTrk, kreeg $trackChunk op track $trackIndex',
        );
      }

      final int trackLength = reader.readUint32();
      final int trackEnd = reader.offset + trackLength;
      int absoluteTick = 0;
      int runningStatus = 0;
      final Map<int, List<_ActiveNote>> activeNotes =
          <int, List<_ActiveNote>>{};

      while (reader.offset < trackEnd) {
        absoluteTick += reader.readVarInt();
        final int statusByte = reader.peekUint8();
        int eventStatus = statusByte;

        if (statusByte < 0x80) {
          if (runningStatus == 0) {
            throw FormatException(
              'Running status zonder vorige status op track $trackIndex',
            );
          }
          eventStatus = runningStatus;
        } else {
          eventStatus = reader.readUint8();
          if (eventStatus < 0xF0) {
            runningStatus = eventStatus;
          }
        }

        if (eventStatus == 0xFF) {
          final int metaType = reader.readUint8();
          final int metaLength = reader.readVarInt();
          final List<int> metaData = reader.readBytes(metaLength);
          if (metaType == 0x2F) {
            break;
          }
          if (metaType == 0x51 && metaLength == 3) {
            final int tempo =
                (metaData[0] << 16) | (metaData[1] << 8) | metaData[2];
            tempoChanges.add(
              _TempoChange(
                tick: absoluteTick,
                microsecondsPerQuarterNote: tempo,
              ),
            );
          }
          continue;
        }

        if (eventStatus == 0xF0 || eventStatus == 0xF7) {
          final int sysexLength = reader.readVarInt();
          reader.skip(sysexLength);
          continue;
        }

        final int eventType = eventStatus & 0xF0;
        final int channel = eventStatus & 0x0F;

        switch (eventType) {
          case 0x80:
          case 0x90:
            final int note = reader.readUint8();
            final int velocity = reader.readUint8();
            if (eventType == 0x90 && velocity > 0) {
              rawNoteCount += 1;
              activeNotes
                  .putIfAbsent(note, () => <_ActiveNote>[])
                  .add(
                    _ActiveNote(
                      note: note,
                      velocity: velocity,
                      startTick: absoluteTick,
                    ),
                  );
            } else {
              final List<_ActiveNote>? stack = activeNotes[note];
              if (stack != null && stack.isNotEmpty) {
                final _ActiveNote active = stack.removeLast();
                parsedNotes.add(
                  _ParsedTrackNote(
                    note: active.note,
                    velocity: active.velocity,
                    startTick: active.startTick,
                    endTick: absoluteTick,
                    channel: channel,
                  ),
                );
                if (absoluteTick > maxTick) {
                  maxTick = absoluteTick;
                }
              }
            }
            break;
          case 0xA0:
          case 0xB0:
          case 0xE0:
            reader.skip(2);
            break;
          case 0xC0:
          case 0xD0:
            reader.skip(1);
            break;
          default:
            throw FormatException(
              'Onbekende MIDI status 0x${eventStatus.toRadixString(16)} op track $trackIndex',
            );
        }
      }

      reader.offset = trackEnd;
    }

    if (parsedNotes.isEmpty) {
      return ParsedMidiSong(
        notes: <MidiNoteEvent>[],
        totalDurationMicros: 0,
        format: format,
        trackCount: trackCount,
        ticksPerQuarterNote: ticksPerQuarterNote,
        tempoChangeCount: tempoChanges.length,
        rawNoteCount: rawNoteCount,
        maxSimultaneousNotes: 0,
      );
    }

    tempoChanges.sort((a, b) => a.tick.compareTo(b.tick));
    final List<MidiNoteEvent> playableNotes = <MidiNoteEvent>[];
    int maxEndTick = 0;
    for (final _ParsedTrackNote note in parsedNotes) {
      if (note.endTick > maxEndTick) {
        maxEndTick = note.endTick;
      }
      final int startMicros = _ticksToMicros(
        note.startTick,
        tempoChanges,
        ticksPerQuarterNote,
      );
      final int endMicros = _ticksToMicros(
        note.endTick,
        tempoChanges,
        ticksPerQuarterNote,
      );
      playableNotes.add(
        MidiNoteEvent(
          note: note.note,
          velocity: note.velocity,
          startMicros: startMicros,
          endMicros: endMicros,
        ),
      );
    }

    playableNotes.sort((a, b) {
      final int compareStart = a.startMicros.compareTo(b.startMicros);
      if (compareStart != 0) {
        return compareStart;
      }
      return a.note.compareTo(b.note);
    });

    int maxSimultaneousNotes = 0;
    final List<_NoteBoundary> boundaries = <_NoteBoundary>[];
    for (final MidiNoteEvent note in playableNotes) {
      boundaries.add(_NoteBoundary(time: note.startMicros, delta: 1));
      boundaries.add(_NoteBoundary(time: note.endMicros, delta: -1));
    }
    boundaries.sort((a, b) {
      final int compareTime = a.time.compareTo(b.time);
      if (compareTime != 0) {
        return compareTime;
      }
      return a.delta.compareTo(b.delta);
    });

    int active = 0;
    for (final _NoteBoundary boundary in boundaries) {
      active += boundary.delta;
      if (active > maxSimultaneousNotes) {
        maxSimultaneousNotes = active;
      }
    }

    final int totalDurationMicros = _ticksToMicros(
      maxEndTick,
      tempoChanges,
      ticksPerQuarterNote,
    );

    return ParsedMidiSong(
      notes: playableNotes,
      totalDurationMicros: totalDurationMicros,
      format: format,
      trackCount: trackCount,
      ticksPerQuarterNote: ticksPerQuarterNote,
      tempoChangeCount: tempoChanges.length,
      rawNoteCount: rawNoteCount,
      maxSimultaneousNotes: maxSimultaneousNotes,
    );
  }

  static int _ticksToMicros(
    int tick,
    List<_TempoChange> tempoChanges,
    int ticksPerQuarterNote,
  ) {
    if (tick <= 0) {
      return 0;
    }

    int currentTempo = 500000;
    int previousTick = 0;
    int micros = 0;

    for (final _TempoChange tempoChange in tempoChanges) {
      if (tempoChange.tick > tick) {
        break;
      }
      micros +=
          ((tempoChange.tick - previousTick) * currentTempo) ~/
          ticksPerQuarterNote;
      previousTick = tempoChange.tick;
      currentTempo = tempoChange.microsecondsPerQuarterNote;
    }

    micros += ((tick - previousTick) * currentTempo) ~/ ticksPerQuarterNote;
    return micros;
  }
}

class _ByteReader {
  _ByteReader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  String readAscii(int length) {
    final List<int> values = readBytes(length);
    return String.fromCharCodes(values);
  }

  int readUint8() {
    if (offset >= bytes.length) {
      throw RangeError('Unexpected EOF');
    }
    return bytes[offset++];
  }

  int peekUint8() {
    if (offset >= bytes.length) {
      throw RangeError('Unexpected EOF');
    }
    return bytes[offset];
  }

  int readUint16() {
    return (readUint8() << 8) | readUint8();
  }

  int readUint32() {
    return (readUint8() << 24) |
        (readUint8() << 16) |
        (readUint8() << 8) |
        readUint8();
  }

  int readVarInt() {
    int value = 0;
    while (true) {
      final int byte = readUint8();
      value = (value << 7) | (byte & 0x7F);
      if (byte & 0x80 == 0) {
        return value;
      }
    }
  }

  List<int> readBytes(int length) {
    if (offset + length > bytes.length) {
      throw RangeError('Unexpected EOF');
    }
    final List<int> slice = bytes.sublist(offset, offset + length);
    offset += length;
    return slice;
  }

  void skip(int length) {
    readBytes(length);
  }
}

class _ActiveNote {
  _ActiveNote({
    required this.note,
    required this.velocity,
    required this.startTick,
  });

  final int note;
  final int velocity;
  final int startTick;
}

class _ParsedTrackNote {
  _ParsedTrackNote({
    required this.note,
    required this.velocity,
    required this.startTick,
    required this.endTick,
    required this.channel,
  });

  final int note;
  final int velocity;
  final int startTick;
  final int endTick;
  final int channel;
}

class _TempoChange {
  _TempoChange({required this.tick, required this.microsecondsPerQuarterNote});

  final int tick;
  final int microsecondsPerQuarterNote;
}

class _NoteBoundary {
  _NoteBoundary({required this.time, required this.delta});

  final int time;
  final int delta;
}

class GitHubMidiSong {
  GitHubMidiSong({required this.name, required this.path});

  final String name;
  final String path;
}

class _MidiPianoRoll extends StatelessWidget {
  const _MidiPianoRoll({
    required this.song,
    required this.playheadMillis,
    required this.minWidth,
  });

  final ParsedMidiSong song;
  final double playheadMillis;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final double contentWidth = _MidiPianoRollPainter.estimateContentWidth(
      song,
      minWidth,
    );
    return SizedBox(
      width: contentWidth,
      height: 260,
      child: CustomPaint(
        painter: _MidiPianoRollPainter(
          song: song,
          playheadMillis: playheadMillis,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _MidiPianoRollPainter extends CustomPainter {
  _MidiPianoRollPainter({required this.song, required this.playheadMillis});

  final ParsedMidiSong song;
  final double playheadMillis;

  static const double _pixelsPerMillisecond = 0.18;
  static const double _noteHeight = 8.0;
  static const double _noteSpacing = 2.0;

  static double estimateContentWidth(ParsedMidiSong song, double minimumWidth) {
    final double estimatedWidth =
        (song.totalDurationMicros / 1000) * _pixelsPerMillisecond + 120;
    return estimatedWidth < minimumWidth ? minimumWidth : estimatedWidth;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final Paint backgroundPaint = Paint()..color = const Color(0xFF111827);
    canvas.drawRect(Offset.zero & size, backgroundPaint);

    if (song.notes.isEmpty) {
      final TextPainter emptyPainter = TextPainter(
        text: const TextSpan(
          text: 'Nog geen noten beschikbaar',
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);
      emptyPainter.paint(
        canvas,
        Offset(
          (size.width - emptyPainter.width) / 2,
          (size.height - emptyPainter.height) / 2,
        ),
      );
      return;
    }

    final double totalDurationMillis = song.totalDurationMicros / 1000;
    final double maxDuration = totalDurationMillis <= 0
        ? 1
        : totalDurationMillis;
    final List<int> noteValues = song.notes
        .map((MidiNoteEvent note) => note.note)
        .toList();
    final int lowestNote = noteValues.reduce((int a, int b) => a < b ? a : b);
    final int highestNote = noteValues.reduce((int a, int b) => a > b ? a : b);
    final int noteRange = (highestNote - lowestNote + 1).clamp(1, 128);
    final double noteStep =
        (size.height - 20).clamp(1.0, double.infinity) / noteRange;
    final double scaleX = size.width / maxDuration;

    final Paint gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 1;

    for (int note = lowestNote; note <= highestNote; note++) {
      final double y = size.height - ((note - lowestNote + 1) * noteStep);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final Paint barPaint = Paint();
    for (final MidiNoteEvent note in song.notes) {
      final double left = note.startMicros / 1000 * scaleX;
      final double width = (note.durationMicros / 1000 * scaleX).clamp(
        2.0,
        size.width,
      );
      final double noteY =
          size.height - ((note.note - lowestNote + 1) * noteStep);
      final Rect rect = Rect.fromLTWH(
        left,
        noteY - _noteHeight,
        width,
        (_noteHeight - _noteSpacing).clamp(2.0, noteStep),
      );
      final double hue = ((note.note % 12) / 12.0);
      barPaint.color = HSVColor.fromAHSV(0.92, hue * 360, 0.55, 0.95).toColor();
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        barPaint,
      );
    }

    final double playheadX =
        (playheadMillis.clamp(0, maxDuration) / maxDuration) * size.width;
    final Paint playheadPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(playheadX, 0),
      Offset(playheadX, size.height),
      playheadPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _MidiPianoRollPainter oldDelegate) {
    return oldDelegate.song != song ||
        oldDelegate.playheadMillis != playheadMillis;
  }
}
