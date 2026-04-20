import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_midi/flutter_midi.dart';

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
      home: const MyHomePage(title: 'MIDI Raw Data Viewer'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  static const String _soundFontAsset =
      'assets/sf2/generaluser_gs_softsynth_v144.sf2';

  final FlutterMidi _flutterMidi = FlutterMidi();
  final List<Timer> _activeTimers = <Timer>[];

  String? _selectedFileName;
  Uint8List? _fileData;
  ParsedMidiSong? _parsedSong;
  String _hexDisplay = '';
  String _statusMessage = 'Soundfont laden...';
  bool _soundFontReady = false;
  bool _isPlaying = false;
  bool _showDebugPanel = true;
  int _playbackSession = 0;
  final List<String> _debugLog = <String>[];
  Timer? _playheadTimer;
  int _playStartEpochMicros = 0;
  int _playTotalDurationMicros = 0;
  double _playheadMillis = 0;

  @override
  void initState() {
    super.initState();
    _logDebug('App gestart op ${Platform.operatingSystem}');
    _loadSoundFont();
  }

  @override
  void dispose() {
    _logDebug('Dispose gestart; playback stop wordt uitgevoerd');
    _stopPlayback();
    _playheadTimer?.cancel();
    super.dispose();
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

    if (!mounted) {
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
        _logDebug('flutter_midi.unmute klaar, elapsedMs=${stopwatch.elapsedMilliseconds}');
      } catch (error, stackTrace) {
        _logDebug(
          'flutter_midi.unmute mislukt, doorgaan zonder unmute',
          error: error,
          stackTrace: stackTrace,
        );
      }

      _logDebug('flutter_midi.prepare gestart');
      await _flutterMidi.prepare(
        sf2: soundFontBytes,
        name: 'generaluser_gs_softsynth_v144.sf2',
      ).timeout(const Duration(seconds: 20));
      _logDebug('flutter_midi.prepare klaar, totalElapsedMs=${stopwatch.elapsedMilliseconds}');

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
        _logDebug('Bestandskiezer geannuleerd na ${stopwatch.elapsedMilliseconds}ms');
        return;
      }

      final PlatformFile file = result.files.first;
      _logDebug(
        'Bestand gekozen: name=${file.name}, size=${file.size}, hasBytes=${file.bytes != null}, path=${file.path}',
      );
      final Uint8List bytes = file.bytes ?? await File(file.path!).readAsBytes();
      _logDebug('Bestand bytes geladen: ${bytes.length} bytes, elapsedMs=${stopwatch.elapsedMilliseconds}');

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
      _logDebug('Fout tijdens bestandskiezer', error: error, updateStatus: true);
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fout bij openen bestand: $error')),
      );
    }
  }

  Future<void> _playSelectedMidi() async {
    _playbackSession += 1;
    final int session = _playbackSession;
    final Stopwatch stopwatch = Stopwatch()..start();
    _logDebug('Playback sessie $session gestart');

    if (!_soundFontReady) {
      _logDebug('Playback sessie $session afgebroken: soundfont niet ready', updateStatus: true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Soundfont is nog niet geladen.')),
      );
      return;
    }

    final Uint8List? bytes = _fileData;
    if (bytes == null) {
      _logDebug('Playback sessie $session afgebroken: geen MIDI bytes', updateStatus: true);
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
        _logDebug('MIDI parser fout in sessie $session', error: error, updateStatus: true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('MIDI parser fout: $error')),
        );
        return;
      }
    }

    final ParsedMidiSong finalSong = song;

    if (finalSong.notes.isEmpty) {
      _logDebug('Playback sessie $session: geen noten om af te spelen', updateStatus: true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Geen afspeelbare noten gevonden in dit MIDI-bestand.')),
      );
      return;
    }

    _stopPlayback();
    setState(() {
      _isPlaying = true;
      _statusMessage = 'Afspelen gestart';
    });
    _startPlayhead(finalSong.totalDurationMicros);
    _logDebug('Playback sessie $session loopt, notes=${finalSong.notes.length}', updateStatus: true);

    final int playStartMicros = DateTime.now().microsecondsSinceEpoch;
    int noteIndex = 0;

    for (final MidiNoteEvent note in finalSong.notes) {
      if (!mounted || !_isPlaying) {
        _logDebug('Playback sessie $session onderbroken bij noteIndex=$noteIndex');
        break;
      }

      final int targetStartMicros = playStartMicros + note.startMicros;
      final int delayMicros = targetStartMicros - DateTime.now().microsecondsSinceEpoch;
      if (delayMicros > 0) {
        await Future<void>.delayed(Duration(microseconds: delayMicros));
      }

      if (!mounted || !_isPlaying) {
        _logDebug('Playback sessie $session stop na wachttijd bij noteIndex=$noteIndex');
        break;
      }

      try {
        await _flutterMidi.playMidiNote(
          midi: note.note,
        );
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
            _logDebug('stopMidiNote timer fout voor note=${note.note}', error: error);
          }
        },
      );
      _activeTimers.add(offTimer);
      noteIndex += 1;
    }

    final int endMicros = playStartMicros + finalSong.totalDurationMicros;
    final int remainingMicros = endMicros - DateTime.now().microsecondsSinceEpoch;
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
    _logDebug('Playback sessie $session klaar in ${stopwatch.elapsedMilliseconds}ms', updateStatus: true);
  }

  void _startPlayhead(int totalDurationMicros) {
    _playheadTimer?.cancel();
    _playStartEpochMicros = DateTime.now().microsecondsSinceEpoch;
    _playTotalDurationMicros = totalDurationMicros;
    _playheadMillis = 0;

    _playheadTimer = Timer.periodic(const Duration(milliseconds: 33), (Timer timer) {
      if (!mounted || !_isPlaying) {
        timer.cancel();
        return;
      }

      final int elapsedMicros = DateTime.now().microsecondsSinceEpoch - _playStartEpochMicros;
      final int clampedMicros = elapsedMicros.clamp(0, _playTotalDurationMicros);
      setState(() {
        _playheadMillis = clampedMicros / 1000;
      });
    });
  }

  void _stopPlayback() {
    _logDebug('Stop playback gevraagd; timers=${_activeTimers.length}, wasPlaying=$_isPlaying');
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

      final String hexBytes = chunk.map((int byte) {
        return byte.toRadixString(16).padLeft(2, '0');
      }).join(' ');
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
                      Text('Debug regels: ${_debugLog.length}'),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          FilledButton.icon(
                            onPressed: _pickMidiFile,
                            icon: const Icon(Icons.folder_open),
                            label: const Text('MIDI openen'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: _isPlaying ? _stopPlayback : _playSelectedMidi,
                            icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow),
                            label: Text(_isPlaying ? 'Stop' : 'Afspelen'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: () {
                              setState(() {
                                _showDebugPanel = !_showDebugPanel;
                              });
                            },
                            icon: Icon(_showDebugPanel ? Icons.bug_report : Icons.bug_report_outlined),
                            label: Text(_showDebugPanel ? 'Debug verbergen' : 'Debug tonen'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _debugLog.isEmpty
                                ? null
                                : () {
                                    Clipboard.setData(ClipboardData(text: _debugLog.join('\n')));
                                    _logDebug('Debuglog gekopieerd naar klembord');
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
                child: SizedBox(
                  height: 240,
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
                          Text('Max tegelijk gespeelde noten: ${_parsedSong!.maxSimultaneousNotes}'),
                          const SizedBox(height: 10),
                          Expanded(
                            child: _MidiPianoRoll(
                              song: _parsedSong!,
                              playheadMillis: _playheadMillis,
                            ),
                          ),
                        ],
                      ),
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

class MidiParser {
  static ParsedMidiSong parse(Uint8List bytes) {
    final _ByteReader reader = _ByteReader(bytes);

    final String headerId = reader.readAscii(4);
    if (headerId != 'MThd') {
      throw FormatException('Geen geldig MIDI-bestand: ontbrekende MThd-header.');
    }

    final int headerLength = reader.readUint32();
    if (headerLength < 6) {
      throw FormatException('Ongeldige MIDI header length.');
    }

    final int format = reader.readUint16();
    final int trackCount = reader.readUint16();
    final int division = reader.readUint16();

    if (headerLength > 6) {
      reader.skip(headerLength - 6);
    }

    if ((division & 0x8000) != 0) {
      throw FormatException('SMPTE timing wordt niet ondersteund.');
    }

    final int ticksPerQuarterNote = division;
    final List<_TempoChange> tempoMap = <_TempoChange>[
      _TempoChange(0, 500000),
    ];
    final Map<int, List<_PendingNote>> pendingNotes = <int, List<_PendingNote>>{};
    final List<_RawNote> rawNotes = <_RawNote>[];

    for (int trackIndex = 0; trackIndex < trackCount; trackIndex++) {
      final String trackId = reader.readAscii(4);
      if (trackId != 'MTrk') {
        throw FormatException('Ongeldige track header op track $trackIndex.');
      }

      final int trackLength = reader.readUint32();
      final int trackEnd = reader.position + trackLength;
      int absoluteTick = 0;
      int runningStatus = 0;

      while (reader.position < trackEnd) {
        absoluteTick += reader.readVarLen();

        final int statusOrData = reader.readUint8();
        int status = statusOrData;

        if (statusOrData < 0x80) {
          if (runningStatus == 0) {
            throw FormatException('Running status zonder vorige status op track $trackIndex.');
          }
          status = runningStatus;
          reader.rewind(1);
        } else {
          runningStatus = status;
        }

        if (status == 0xFF) {
          final int metaType = reader.readUint8();
          final int metaLength = reader.readVarLen();
          final Uint8List metaData = reader.readBytes(metaLength);

          if (metaType == 0x51 && metaLength == 3) {
            final int tempoMicros = (metaData[0] << 16) | (metaData[1] << 8) | metaData[2];
            tempoMap.add(_TempoChange(absoluteTick, tempoMicros));
          }

          if (metaType == 0x2F) {
            break;
          }
          continue;
        }

        if (status == 0xF0 || status == 0xF7) {
          final int sysexLength = reader.readVarLen();
          reader.skip(sysexLength);
          continue;
        }

        final int eventType = status & 0xF0;
        final int channel = status & 0x0F;
        switch (eventType) {
          case 0x80:
            final int note = reader.readUint8();
            reader.readUint8();
            _closeNote(pendingNotes, rawNotes, channel, note, absoluteTick);
            break;
          case 0x90:
            final int note = reader.readUint8();
            final int velocity = reader.readUint8();
            if (velocity == 0) {
              _closeNote(pendingNotes, rawNotes, channel, note, absoluteTick);
            } else {
              _openNote(pendingNotes, channel, note, absoluteTick, velocity);
            }
            break;
          case 0xA0:
          case 0xB0:
          case 0xE0:
            reader.readUint8();
            reader.readUint8();
            break;
          case 0xC0:
          case 0xD0:
            reader.readUint8();
            break;
          default:
            throw FormatException('Niet-ondersteund MIDI statusbyte: 0x${status.toRadixString(16)}');
        }
      }

      reader.position = trackEnd;
    }

    rawNotes.sort((_RawNote a, _RawNote b) {
      return a.startTick.compareTo(b.startTick);
    });

    final List<MidiNoteEvent> notes = <MidiNoteEvent>[];
    int totalDurationMicros = 0;
    for (final _RawNote note in rawNotes) {
      final int startMicros = _ticksToMicros(note.startTick, ticksPerQuarterNote, tempoMap);
      final int endMicros = _ticksToMicros(note.endTick, ticksPerQuarterNote, tempoMap);
      if (endMicros <= startMicros) {
        continue;
      }

      notes.add(
        MidiNoteEvent(
          note: note.note,
          velocity: note.velocity,
          startMicros: startMicros,
          endMicros: endMicros,
        ),
      );
      totalDurationMicros = endMicros > totalDurationMicros ? endMicros : totalDurationMicros;
    }

    notes.sort((MidiNoteEvent a, MidiNoteEvent b) {
      final int startComparison = a.startMicros.compareTo(b.startMicros);
      if (startComparison != 0) {
        return startComparison;
      }
      return a.note.compareTo(b.note);
    });

    final int maxSimultaneousNotes = _calculateMaxSimultaneousNotes(notes);

    if (format == 0 && trackCount == 0) {
      throw FormatException('Geen tracks gevonden in MIDI-bestand.');
    }

    return ParsedMidiSong(
      notes: notes,
      totalDurationMicros: totalDurationMicros + 250000,
      format: format,
      trackCount: trackCount,
      ticksPerQuarterNote: ticksPerQuarterNote,
      tempoChangeCount: tempoMap.length,
      rawNoteCount: rawNotes.length,
      maxSimultaneousNotes: maxSimultaneousNotes,
    );
  }

  static int _calculateMaxSimultaneousNotes(List<MidiNoteEvent> notes) {
    if (notes.isEmpty) {
      return 0;
    }

    final List<_PolyphonyEdge> edges = <_PolyphonyEdge>[];
    for (final MidiNoteEvent note in notes) {
      edges.add(_PolyphonyEdge(note.startMicros, 1));
      edges.add(_PolyphonyEdge(note.endMicros, -1));
    }

    edges.sort((_PolyphonyEdge a, _PolyphonyEdge b) {
      final int timeCmp = a.timeMicros.compareTo(b.timeMicros);
      if (timeCmp != 0) {
        return timeCmp;
      }
      return a.delta.compareTo(b.delta);
    });

    int current = 0;
    int max = 0;
    for (final _PolyphonyEdge edge in edges) {
      current += edge.delta;
      if (current > max) {
        max = current;
      }
    }
    return max;
  }

  static void _openNote(
    Map<int, List<_PendingNote>> pendingNotes,
    int channel,
    int note,
    int tick,
    int velocity,
  ) {
    final int key = _noteKey(channel, note);
    final List<_PendingNote> stack = pendingNotes.putIfAbsent(key, () => <_PendingNote>[]);
    stack.add(_PendingNote(startTick: tick, velocity: velocity));
  }

  static void _closeNote(
    Map<int, List<_PendingNote>> pendingNotes,
    List<_RawNote> rawNotes,
    int channel,
    int note,
    int tick,
  ) {
    final int key = _noteKey(channel, note);
    final List<_PendingNote>? stack = pendingNotes[key];
    if (stack == null || stack.isEmpty) {
      return;
    }

    final _PendingNote openedNote = stack.removeLast();
    rawNotes.add(
      _RawNote(
        note: note,
        velocity: openedNote.velocity,
        startTick: openedNote.startTick,
        endTick: tick,
      ),
    );
  }

  static int _noteKey(int channel, int note) {
    return (channel << 7) | note;
  }

  static int _ticksToMicros(
    int tick,
    int ticksPerQuarterNote,
    List<_TempoChange> tempoMap,
  ) {
    int totalMicros = 0;
    int previousTick = 0;
    int currentTempo = tempoMap.first.microsecondsPerQuarterNote;

    for (final _TempoChange change in tempoMap.skip(1)) {
      if (change.tick > tick) {
        break;
      }

      totalMicros += ((change.tick - previousTick) * currentTempo / ticksPerQuarterNote).round();
      previousTick = change.tick;
      currentTempo = change.microsecondsPerQuarterNote;
    }

    totalMicros += ((tick - previousTick) * currentTempo / ticksPerQuarterNote).round();
    return totalMicros;
  }
}

class _ByteReader {
  _ByteReader(this._bytes);

  final Uint8List _bytes;
  int position = 0;

  int readUint8() {
    if (position >= _bytes.length) {
      throw FormatException('Unexpected end of MIDI data.');
    }

    return _bytes[position++];
  }

  int readUint16() {
    return (readUint8() << 8) | readUint8();
  }

  int readUint32() {
    return (readUint8() << 24) | (readUint8() << 16) | (readUint8() << 8) | readUint8();
  }

  Uint8List readBytes(int length) {
    if (position + length > _bytes.length) {
      throw FormatException('Unexpected end of MIDI data.');
    }

    final Uint8List result = Uint8List.sublistView(_bytes, position, position + length);
    position += length;
    return result;
  }

  String readAscii(int length) {
    return String.fromCharCodes(readBytes(length));
  }

  int readVarLen() {
    int value = 0;
    while (true) {
      final int byte = readUint8();
      value = (value << 7) | (byte & 0x7F);
      if ((byte & 0x80) == 0) {
        return value;
      }
    }
  }

  void skip(int length) {
    position += length;
    if (position > _bytes.length) {
      throw FormatException('Unexpected end of MIDI data.');
    }
  }

  void rewind(int length) {
    position -= length;
    if (position < 0) {
      position = 0;
    }
  }
}

class _TempoChange {
  _TempoChange(this.tick, this.microsecondsPerQuarterNote);

  final int tick;
  final int microsecondsPerQuarterNote;
}

class _PendingNote {
  _PendingNote({required this.startTick, required this.velocity});

  final int startTick;
  final int velocity;
}

class _RawNote {
  _RawNote({
    required this.note,
    required this.velocity,
    required this.startTick,
    required this.endTick,
  });

  final int note;
  final int velocity;
  final int startTick;
  final int endTick;
}

class _PolyphonyEdge {
  _PolyphonyEdge(this.timeMicros, this.delta);

  final int timeMicros;
  final int delta;
}

class _MidiPianoRoll extends StatelessWidget {
  const _MidiPianoRoll({
    required this.song,
    required this.playheadMillis,
  });

  final ParsedMidiSong song;
  final double playheadMillis;

  @override
  Widget build(BuildContext context) {
    if (song.notes.isEmpty) {
      return const Center(child: Text('Geen noten om te visualiseren'));
    }

    const double pixelsPerSecond = 120;
    const double minWidth = 640;
    final double durationSeconds = song.totalDurationMicros / 1000000;
    final double contentWidth = (durationSeconds * pixelsPerSecond + 80).clamp(minWidth, 32000);

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        color: const Color(0xFF050505),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: CustomPaint(
            size: Size(contentWidth, 170),
            painter: _MidiPianoRollPainter(
              song: song,
              playheadMillis: playheadMillis,
              pixelsPerSecond: pixelsPerSecond,
            ),
          ),
        ),
      ),
    );
  }
}

class _MidiPianoRollPainter extends CustomPainter {
  _MidiPianoRollPainter({
    required this.song,
    required this.playheadMillis,
    required this.pixelsPerSecond,
  });

  final ParsedMidiSong song;
  final double playheadMillis;
  final double pixelsPerSecond;

  @override
  void paint(Canvas canvas, Size size) {
    const double leftPadding = 24;
    const double topPadding = 8;
    final Paint gridPaint = Paint()
      ..color = const Color(0xFF1C1C1C)
      ..strokeWidth = 1;
    final Paint strongGridPaint = Paint()
      ..color = const Color(0xFF2A2A2A)
      ..strokeWidth = 1.4;

    final int minNote = song.notes.map((MidiNoteEvent note) => note.note).reduce((int a, int b) => a < b ? a : b);
    final int maxNote = song.notes.map((MidiNoteEvent note) => note.note).reduce((int a, int b) => a > b ? a : b);
    final int noteSpan = (maxNote - minNote + 1).clamp(12, 96);
    final double drawableHeight = size.height - topPadding * 2;
    final double noteHeight = (drawableHeight / noteSpan).clamp(2.5, 11);

    final int totalSeconds = (song.totalDurationMicros / 1000000).ceil();
    for (int second = 0; second <= totalSeconds; second++) {
      final double x = leftPadding + second * pixelsPerSecond;
      final Paint paint = (second % 4 == 0) ? strongGridPaint : gridPaint;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    for (int idx = 0; idx < noteSpan; idx++) {
      final int noteValue = maxNote - idx;
      final double y = topPadding + idx * noteHeight;
      final Paint paint = (noteValue % 12 == 0) ? strongGridPaint : gridPaint;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    for (final MidiNoteEvent note in song.notes) {
      final double startX = leftPadding + (note.startMicros / 1000000) * pixelsPerSecond;
      final double width = ((note.durationMicros / 1000000) * pixelsPerSecond).clamp(2, 6000);
      final double yIndex = (maxNote - note.note).toDouble();
      final double y = topPadding + yIndex * noteHeight;
      final Rect noteRect = Rect.fromLTWH(startX, y + 0.6, width, (noteHeight - 1.2).clamp(1.2, noteHeight));

      final Color color = _noteColor(note.note);
      final Paint fillPaint = Paint()..color = color;
      final Paint borderPaint = Paint()
        ..color = color.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6;

      canvas.drawRRect(
        RRect.fromRectAndRadius(noteRect, const Radius.circular(2)),
        fillPaint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(noteRect, const Radius.circular(2)),
        borderPaint,
      );
    }

    final double playheadX = leftPadding + (playheadMillis / 1000) * pixelsPerSecond;
    final Paint playheadPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;
    canvas.drawLine(Offset(playheadX, 0), Offset(playheadX, size.height), playheadPaint);
  }

  Color _noteColor(int note) {
    const List<Color> palette = <Color>[
      Color(0xFF5FE3F8),
      Color(0xFF5AC8FA),
      Color(0xFFF76BE9),
      Color(0xFFFEEB5A),
      Color(0xFF7CF29A),
      Color(0xFFA98BFF),
    ];
    return palette[note % palette.length];
  }

  @override
  bool shouldRepaint(covariant _MidiPianoRollPainter oldDelegate) {
    return oldDelegate.playheadMillis != playheadMillis || oldDelegate.song != song;
  }
}
