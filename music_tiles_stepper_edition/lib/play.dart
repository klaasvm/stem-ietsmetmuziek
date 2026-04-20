import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_midi/flutter_midi.dart';

import 'dev.dart' as dev;

class GitHubMidiSong {
  GitHubMidiSong({required this.name, required this.path});

  final String name;
  final String path;
}

class GitHubSongCatalog {
  GitHubSongCatalog._();

  static const String _githubOwner = 'klaasvm';
  static const String _githubRepo = 'stem-ietsmetmuziek';
  static const String _githubBranch = 'main';
  static const String _githubMusicFolder = 'music';

  static Future<List<GitHubMidiSong>>? _cachedFuture;
  static final Map<String, Future<Uint8List>> _cachedSongBytes = <String, Future<Uint8List>>{};

  static Future<List<GitHubMidiSong>> load() {
    return _cachedFuture ??= _loadInternal();
  }

  static Future<Uint8List> loadSongBytes(String path) {
    return _cachedSongBytes.putIfAbsent(path, () => _downloadSongBytes(path));
  }

  static void prefetchSongs(Iterable<GitHubMidiSong> songs) {
    for (final GitHubMidiSong song in songs) {
      loadSongBytes(song.path);
    }
  }

  static Future<List<GitHubMidiSong>> _loadInternal() async {
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
    final List<dynamic> treeEntries = decoded['tree'] as List<dynamic>? ?? <dynamic>[];
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
      if (!path.toLowerCase().endsWith('.mid') && !path.toLowerCase().endsWith('.midi')) {
        continue;
      }

      songs.add(
        GitHubMidiSong(
          name: path.split('/').last,
          path: path,
        ),
      );
    }

    songs.sort((GitHubMidiSong a, GitHubMidiSong b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return songs;
  }

  static Future<Uint8List> _downloadSongBytes(String path) async {
    final String rawUrl = 'https://raw.githubusercontent.com/$_githubOwner/$_githubRepo/$_githubBranch/$path';
    final HttpClient client = HttpClient();
    client.userAgent = 'music_tiles_stepper_edition';
    final HttpClientRequest request = await client.getUrl(Uri.parse(rawUrl));
    final HttpClientResponse response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('GitHub raw download status ${response.statusCode}');
    }

    return response.fold<BytesBuilder>(BytesBuilder(), (BytesBuilder builder, List<int> chunk) {
      builder.add(chunk);
      return builder;
    }).then((BytesBuilder builder) => builder.takeBytes());
  }
}

class PlayPage extends StatefulWidget {
  const PlayPage({super.key});

  @override
  State<PlayPage> createState() => _PlayPageState();
}

class _PlayPageState extends State<PlayPage> {
  late Future<List<GitHubMidiSong>> _songsFuture;
  bool _prefetchStarted = false;

  @override
  void initState() {
    super.initState();
    _songsFuture = GitHubSongCatalog.load();
  }

  void _openGame(GitHubMidiSong song) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GamePage(song: song),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Play'),
      ),
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              Color(0xFFF7F4FF),
              Color(0xFFE9EEF9),
              Color(0xFFDDE6F5),
            ],
          ),
        ),
        child: SafeArea(
          child: FutureBuilder<List<GitHubMidiSong>>(
            future: _songsFuture,
            builder: (BuildContext context, AsyncSnapshot<List<GitHubMidiSong>> snapshot) {
              final bool loading = snapshot.connectionState == ConnectionState.waiting;
              final Object? error = snapshot.error;
              final List<GitHubMidiSong> songs = snapshot.data ?? <GitHubMidiSong>[];

              return ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x22000000),
                          blurRadius: 24,
                          offset: Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Row(
                          children: <Widget>[
                            Icon(Icons.queue_music_rounded, size: 32),
                            SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Kies een song',
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          loading
                              ? 'Songs worden op de achtergrond geladen...'
                              : 'Tik op een song om meteen te starten.',
                          style: const TextStyle(fontSize: 16, height: 1.4),
                        ),
                        if (error != null) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            'GitHub laden mislukt: $error',
                            style: const TextStyle(color: Colors.redAccent),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (loading)
                    const LinearProgressIndicator(),
                  if (!loading && songs.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: Text(
                        'Geen songs gevonden in de GitHub-map music/.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (!loading && songs.isNotEmpty && !_prefetchStarted)
                    Builder(
                      builder: (BuildContext context) {
                        _prefetchStarted = true;
                        GitHubSongCatalog.prefetchSongs(songs.take(5));
                        return const SizedBox.shrink();
                      },
                    ),
                  const SizedBox(height: 16),
                  ...songs.map(
                    (GitHubMidiSong song) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        elevation: 2,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () {
                            GitHubSongCatalog.loadSongBytes(song.path);
                            _openGame(song);
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: <Widget>[
                                Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF111827),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: const Icon(
                                    Icons.music_note,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        song.name,
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        song.path,
                                        style: TextStyle(
                                          color: Colors.grey.shade700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Terug'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class GamePage extends StatefulWidget {
  const GamePage({super.key, required this.song});

  final GitHubMidiSong song;

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> {
  static const String _soundFontAsset = 'assets/sf2/generaluser_gs_softsynth_v144.sf2';

  static const double _previewAheadMillis = 2100;
  static const double _tapWindowEarlyMillis = 3200;
  static const double _tapWindowLateMillis = 900;
  static const double _missAfterMillis = 1150;
  static const int _hiddenStartDelayMillis = 2000;
  static const double _perfectWindowMillis = 55;
  static const double _goodWindowMillis = 105;
  static const double _okWindowMillis = 170;
  static const int _minimumGameplayGapMicros = 140000;
  static const int _startGroupWindowMicros = 120000;
  static const int _minimumDoubleGapMicros = 280000;

  final FlutterMidi _flutterMidi = FlutterMidi();
  final List<_ScheduledNoteOff> _scheduledNoteOffs = <_ScheduledNoteOff>[];
  final Set<int> _activeTrackNotes = <int>{};
  final List<_GameTileNote> _notes = <_GameTileNote>[];

  dev.ParsedMidiSong? _parsedSong;

  bool _soundFontReady = false;
  bool _isLoading = true;
  bool _isPlaying = false;
  bool _gameOver = false;
  bool _songFinished = false;

  String _status = 'Laden...';
  String? _errorMessage;

  int _score = 0;
  int _combo = 0;
  int _maxCombo = 0;
  int _perfectCount = 0;
  int _goodCount = 0;
  int _okCount = 0;
  int _missCount = 0;
  String _lastJudgement = '';
  DateTime? _lastJudgementAt;

  double _playheadMillis = 0;
  int _songStartMicros = 0;
  int _songDurationMicros = 0;
  int _audioCursor = 0;
  double _boardWidth = 0;
  int _nextMissIndex = 0;
  int _remainingNotes = 0;

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _initGame();
  }

  @override
  void dispose() {
    _stopGame();
    super.dispose();
  }

  Future<void> _initGame() async {
    try {
      final List<dynamic> loaded = await Future.wait<dynamic>(<Future<dynamic>>[
        _loadSoundFont(),
        GitHubSongCatalog.loadSongBytes(widget.song.path),
      ]);
      final Uint8List bytes = loaded[1] as Uint8List;
      final dev.ParsedMidiSong parsedSong = dev.MidiParser.parse(bytes);
      if (!mounted) {
        return;
      }

      final List<_GameTileNote> notes = _buildGameNotes(parsedSong);
      setState(() {
        _parsedSong = parsedSong;
        _notes
          ..clear()
          ..addAll(notes);
        _songDurationMicros = parsedSong.totalDurationMicros;
        _isLoading = false;
        _status = notes.isEmpty ? 'Geen speelbare noten' : 'Druk op Start';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _status = 'Laden mislukt';
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _loadSoundFont() async {
    final ByteData soundFontBytes = await rootBundle.load(_soundFontAsset);
    try {
      await _flutterMidi.unmute();
    } catch (_) {}
    await _flutterMidi.prepare(
      sf2: soundFontBytes,
      name: 'generaluser_gs_softsynth_v144.sf2',
    );
    _soundFontReady = true;
  }

  List<_GameTileNote> _buildGameNotes(dev.ParsedMidiSong song) {
    final List<dev.MidiNoteEvent> sorted = List<dev.MidiNoteEvent>.from(song.notes)
      ..sort((dev.MidiNoteEvent a, dev.MidiNoteEvent b) {
        final int byStart = a.startMicros.compareTo(b.startMicros);
        if (byStart != 0) {
          return byStart;
        }
        return b.velocity.compareTo(a.velocity);
      });

    if (sorted.isEmpty) {
      return <_GameTileNote>[];
    }

    int minPitch = sorted.first.note;
    int maxPitch = sorted.first.note;
    for (final dev.MidiNoteEvent note in sorted) {
      if (note.note < minPitch) {
        minPitch = note.note;
      }
      if (note.note > maxPitch) {
        maxPitch = note.note;
      }
    }

    int laneForPitch(int pitch) {
      if (maxPitch == minPitch) {
        return 1;
      }
      final double normalized = (pitch - minPitch) / (maxPitch - minPitch);
      return (normalized * 3).round().clamp(0, 3);
    }

    final List<List<dev.MidiNoteEvent>> groups = <List<dev.MidiNoteEvent>>[];
    List<dev.MidiNoteEvent> current = <dev.MidiNoteEvent>[];
    int? currentStart;
    for (final dev.MidiNoteEvent note in sorted) {
      if (currentStart == null || note.startMicros - currentStart <= _startGroupWindowMicros) {
        current.add(note);
        currentStart ??= note.startMicros;
      } else {
        groups.add(current);
        current = <dev.MidiNoteEvent>[note];
        currentStart = note.startMicros;
      }
    }
    if (current.isNotEmpty) {
      groups.add(current);
    }

    final List<_GameTileNote> result = <_GameTileNote>[];
    int? lastAcceptedStart;
    int? lastDoubleStart;
    int? previousLeadLane;
    int id = 0;

    for (final List<dev.MidiNoteEvent> group in groups) {
      final int start = group.first.startMicros;
      if (lastAcceptedStart != null && start - lastAcceptedStart < _minimumGameplayGapMicros) {
        continue;
      }

      final Map<int, dev.MidiNoteEvent> strongestByPitch = <int, dev.MidiNoteEvent>{};
      for (final dev.MidiNoteEvent note in group) {
        final dev.MidiNoteEvent? existing = strongestByPitch[note.note];
        if (existing == null || note.velocity > existing.velocity) {
          strongestByPitch[note.note] = note;
        }
      }

      final List<dev.MidiNoteEvent> pitchNotes = strongestByPitch.values.toList()
        ..sort((dev.MidiNoteEvent a, dev.MidiNoteEvent b) => b.velocity.compareTo(a.velocity));
      if (pitchNotes.isEmpty) {
        continue;
      }

      final dev.MidiNoteEvent primary = pitchNotes.first;
      int laneA = laneForPitch(primary.note);
      if (previousLeadLane != null && (laneA - previousLeadLane).abs() > 1) {
        laneA = previousLeadLane! + (laneA > previousLeadLane! ? 1 : -1);
      }
      laneA = laneA.clamp(0, 3);
      previousLeadLane = laneA;

      result.add(
        _GameTileNote(
          id: id++,
          midiNote: primary.note,
          lane: laneA,
          startMicros: start,
          endMicros: primary.endMicros,
        ),
      );

        final bool denseChord = pitchNotes.length >= 4;
        final bool canAddDouble = pitchNotes.length >= 2 &&
          (lastDoubleStart == null ||
            start - lastDoubleStart >= _minimumDoubleGapMicros ||
            denseChord);
      if (canAddDouble) {
        dev.MidiNoteEvent secondary = pitchNotes[1];
        int bestDistance = (secondary.note - primary.note).abs();
        for (int i = 2; i < pitchNotes.length; i++) {
          final int distance = (pitchNotes[i].note - primary.note).abs();
          if (distance > bestDistance) {
            secondary = pitchNotes[i];
            bestDistance = distance;
          }
        }

        if (bestDistance >= 4) {
          int laneB = laneForPitch(secondary.note);
          if (laneB == laneA) {
            laneB = laneA <= 1 ? laneA + 2 : laneA - 2;
          }
          laneB = laneB.clamp(0, 3);

          result.add(
            _GameTileNote(
              id: id++,
              midiNote: secondary.note,
              lane: laneB,
              startMicros: start,
              endMicros: secondary.endMicros,
            ),
          );
          lastDoubleStart = start;
        }
      }

      lastAcceptedStart = start;
    }

    result.sort(( _GameTileNote a, _GameTileNote b) {
      final int byStart = a.startMicros.compareTo(b.startMicros);
      if (byStart != 0) {
        return byStart;
      }
      return a.lane.compareTo(b.lane);
    });

    return result;
  }

  void _startGameLoop() {
    if (!_soundFontReady || _parsedSong == null || _notes.isEmpty) {
      return;
    }

    _stopGame(stopSound: false, keepOverlay: true);

    for (final _GameTileNote note in _notes) {
      note.hit = false;
      note.missed = false;
      note.sounded = false;
    }

    setState(() {
      _isPlaying = true;
      _gameOver = false;
      _songFinished = false;
      _status = 'Spelen';
      _errorMessage = null;
      _score = 0;
      _combo = 0;
      _maxCombo = 0;
      _perfectCount = 0;
      _goodCount = 0;
      _okCount = 0;
      _missCount = 0;
      _lastJudgement = '';
      _lastJudgementAt = null;
      _playheadMillis = -_hiddenStartDelayMillis.toDouble();
    });

    _songStartMicros = DateTime.now().microsecondsSinceEpoch + (_hiddenStartDelayMillis * 1000);
    _audioCursor = 0;
    _scheduledNoteOffs.clear();
    _activeTrackNotes.clear();
    _nextMissIndex = 0;
    _remainingNotes = _notes.length;

    _ticker = Timer.periodic(const Duration(milliseconds: 5), (Timer timer) {
      if (!mounted || !_isPlaying || _gameOver || _songFinished) {
        timer.cancel();
        return;
      }

      final int nowMicros = DateTime.now().microsecondsSinceEpoch;
      final double elapsedMillis = (nowMicros - _songStartMicros) / 1000;

      if (elapsedMillis < 0) {
        setState(() {
          _playheadMillis = elapsedMillis;
        });
        return;
      }

      setState(() {
        _playheadMillis = elapsedMillis;
      });

      _processTrackAudio(elapsedMillis);

      if (_processMisses(elapsedMillis)) {
        return;
      }

      if (_remainingNotes <= 0) {
        _songFinished = true;
        _isPlaying = false;
        _status = 'Klaar';
        _stopAllAudio();
        timer.cancel();
      }
    });
  }

  bool _processMisses(double elapsedMillis) {
    while (_nextMissIndex < _notes.length) {
      final _GameTileNote note = _notes[_nextMissIndex];

      if (note.hit || note.missed) {
        _nextMissIndex += 1;
        continue;
      }

      if (elapsedMillis > note.startMillis + _missAfterMillis) {
        note.missed = true;
        _remainingNotes -= 1;
        _registerMiss('Miss');
        _endGame('GAME OVER', 'Een blok verdween uit beeld');
        return true;
      }

      break;
    }

    return false;
  }

  void _processTrackAudio(double elapsedMillis) {
    final dev.ParsedMidiSong? parsedSong = _parsedSong;
    if (parsedSong == null) {
      return;
    }

    while (_audioCursor < parsedSong.notes.length) {
      final dev.MidiNoteEvent note = parsedSong.notes[_audioCursor];
      final double startMillis = note.startMicros / 1000;
      if (startMillis > elapsedMillis) {
        break;
      }

      _playTrackNote(note.note);
      _scheduledNoteOffs.add(
        _ScheduledNoteOff(
          midiNote: note.note,
          endMillis: note.endMicros / 1000,
        ),
      );
      _audioCursor += 1;
    }

    int index = 0;
    while (index < _scheduledNoteOffs.length) {
      final _ScheduledNoteOff off = _scheduledNoteOffs[index];
      if (off.endMillis <= elapsedMillis) {
        _stopTrackNote(off.midiNote);
        _scheduledNoteOffs.removeAt(index);
        continue;
      }
      index += 1;
    }
  }

  Future<void> _playTrackNote(int midiNote) async {
    try {
      await _flutterMidi.playMidiNote(midi: midiNote);
      _activeTrackNotes.add(midiNote);
    } catch (_) {}
  }

  void _stopTrackNote(int midiNote) {
    try {
      _flutterMidi.stopMidiNote(midi: midiNote);
      _activeTrackNotes.remove(midiNote);
    } catch (_) {}
  }

  void _stopAllAudio() {
    _scheduledNoteOffs.clear();
    _audioCursor = 0;
    for (final int midiNote in _activeTrackNotes.toList()) {
      _stopTrackNote(midiNote);
    }
    try {
      _flutterMidi.stopMidiNote(midi: 0);
    } catch (_) {}
  }

  void _stopGame({bool stopSound = true, bool keepOverlay = false}) {
    _ticker?.cancel();
    _ticker = null;
    if (stopSound) {
      _stopAllAudio();
    }
    _isPlaying = false;
    if (!keepOverlay) {
      _gameOver = false;
      _songFinished = false;
    }
  }

  void _registerJudgement(String judgement) {
    _lastJudgement = judgement;
    _lastJudgementAt = DateTime.now();
  }

  void _registerMiss(String label) {
    _combo = 0;
    _missCount += 1;
    _registerJudgement(label);
  }

  int _laneFromX(double x) {
    if (_boardWidth <= 0) {
      return 0;
    }
    final int lane = (x / (_boardWidth / 4)).floor();
    return lane.clamp(0, 3);
  }

  _GameTileNote? _findTappedNoteInLane(int lane) {
    final List<_GameTileNote> candidates = _notes
        .where(
          (_GameTileNote note) =>
              !note.hit &&
              !note.missed &&
              note.lane == lane &&
              _playheadMillis >= note.startMillis - _tapWindowEarlyMillis &&
              _playheadMillis <= note.startMillis + _tapWindowLateMillis &&
              note.startMillis - _playheadMillis <= _previewAheadMillis,
        )
        .toList();

    if (candidates.isEmpty) {
      return null;
    }

    candidates.sort(( _GameTileNote a, _GameTileNote b) {
      final double da = (a.startMillis - _playheadMillis).abs();
      final double db = (b.startMillis - _playheadMillis).abs();
      return da.compareTo(db);
    });
    return candidates.first;
  }

  _GameTileNote? _findTappedNoteByPosition(double dx) {
    final int lane = _laneFromX(dx);
    _GameTileNote? best = _findTappedNoteInLane(lane);

    // When tapping close to lane borders, also accept the neighboring lane.
    const double borderTolerance = 36;
    final double laneWidth = _boardWidth > 0 ? _boardWidth / 4 : 0;
    if (laneWidth > 0) {
      final double laneLeft = lane * laneWidth;
      final double laneRight = laneLeft + laneWidth;

      final List<int> neighbors = <int>[];
      if (dx - laneLeft <= borderTolerance && lane > 0) {
        neighbors.add(lane - 1);
      }
      if (laneRight - dx <= borderTolerance && lane < 3) {
        neighbors.add(lane + 1);
      }

      for (final int neighbor in neighbors) {
        final _GameTileNote? candidate = _findTappedNoteInLane(neighbor);
        if (candidate == null) {
          continue;
        }
        if (best == null) {
          best = candidate;
          continue;
        }
        final double bestDelta = (best.startMillis - _playheadMillis).abs();
        final double candidateDelta = (candidate.startMillis - _playheadMillis).abs();
        if (candidateDelta < bestDelta) {
          best = candidate;
        }
      }
    }

    return best;
  }

  void _handleBoardPointerDown(PointerDownEvent event) {
    if (_gameOver || _songFinished || _isLoading || !_isPlaying) {
      return;
    }

    final _GameTileNote? tapped = _findTappedNoteByPosition(event.localPosition.dx);
    if (tapped == null) {
      _registerJudgement('Bad Tap');
      _endGame('GAME OVER', 'Je tikte naast een blok');
      return;
    }

    _hitNote(tapped);
  }

  void _hitNote(_GameTileNote note) {
    setState(() {
      note.hit = true;
      note.sounded = true;
      _remainingNotes -= 1;

      final double diff = (_playheadMillis - note.startMillis).abs();
      if (diff <= _perfectWindowMillis) {
        _perfectCount += 1;
        _combo += 1;
        _score += 300 + (_combo * 2);
        _registerJudgement('Perfect');
      } else if (diff <= _goodWindowMillis) {
        _goodCount += 1;
        _combo += 1;
        _score += 180 + _combo;
        _registerJudgement('Good');
      } else {
        _okCount += 1;
        _combo += 1;
        _score += 100;
        _registerJudgement('Ok');
      }

      if (_combo > _maxCombo) {
        _maxCombo = _combo;
      }
    });
  }

  void _endGame(String title, String subtitle) {
    if (_gameOver) {
      return;
    }

    _stopAllAudio();

    setState(() {
      _gameOver = true;
      _isPlaying = false;
      _status = title;
      _errorMessage = subtitle;
    });

    _ticker?.cancel();
    _ticker = null;
  }

  Color _laneAccent(int lane) {
    switch (lane) {
      case 0:
        return const Color(0xFFB7B7B7);
      case 1:
        return const Color(0xFF7F7F7F);
      case 2:
        return const Color(0xFFD0D0D0);
      default:
        return const Color(0xFF9E9E9E);
    }
  }

  Color _tileColor(int lane, {required bool active, required bool hit}) {
    if (hit) {
      return const Color(0xFF050505);
    }
    return active ? const Color(0xFF101010) : const Color(0xFF080808);
  }

  @override
  Widget build(BuildContext context) {
    final dev.ParsedMidiSong? song = _parsedSong;
    final bool ready = !_isLoading && song != null;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              Color(0xFF050505),
              Color(0xFF0C0C0C),
              Color(0xFF111111),
            ],
          ),
        ),
        child: SafeArea(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : _errorMessage != null && song == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _errorMessage!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    )
                  : Column(
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                          child: Row(
                            children: <Widget>[
                              GestureDetector(
                                onTap: () => Navigator.of(context).pop(),
                                child: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.06),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: Colors.white12),
                                  ),
                                  child: const Icon(Icons.chevron_left, color: Colors.white),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  widget.song.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Text(
                                _gameOver
                                    ? 'GAME OVER'
                                    : _songFinished
                                        ? 'CLEARED'
                                        : _isPlaying
                                            ? 'PLAY'
                                            : 'READY',
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: <Widget>[
                                  Text(
                                    'Score $_score',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  Text(
                                    'Combo $_combo',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(26),
                              child: Container(
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: <Color>[
                                      Color(0xFF050505),
                                      Color(0xFF0A0A0A),
                                      Color(0xFF111111),
                                    ],
                                  ),
                                  border: Border.all(color: Colors.white10),
                                ),
                                child: LayoutBuilder(
                                  builder: (BuildContext context, BoxConstraints constraints) {
                                    _boardWidth = constraints.maxWidth;
                                    final double laneWidth = constraints.maxWidth / 4;
                                    final double hitZoneY = constraints.maxHeight * 0.82;
                                    final double travelDistance = hitZoneY + 120;
                                    final List<Widget> notes = ready
                                        ? _buildVisibleNotes(
                                            constraints.maxHeight,
                                            laneWidth,
                                            hitZoneY,
                                            travelDistance,
                                          )
                                        : <Widget>[];

                                    return Stack(
                                      children: <Widget>[
                                        Positioned.fill(
                                          child: Row(
                                            children: List<Widget>.generate(4, (int index) {
                                              return Expanded(
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    border: Border(
                                                      left: index == 0 ? BorderSide.none : const BorderSide(color: Colors.white10),
                                                    ),
                                                  ),
                                                ),
                                              );
                                            }),
                                          ),
                                        ),
                                        ...notes,
                                        Positioned(
                                          left: 16,
                                          right: 16,
                                          top: hitZoneY - 72,
                                          child: IgnorePointer(
                                            child: Container(
                                              height: 144,
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF9E9E9E).withValues(alpha: 0.18),
                                                borderRadius: BorderRadius.circular(18),
                                                border: Border.all(
                                                  color: const Color(0xFFBDBDBD).withValues(alpha: 0.55),
                                                  width: 2,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          left: 12,
                                          right: 12,
                                          top: 12,
                                          child: Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: <Widget>[
                                              Text(
                                                'P $_perfectCount  G $_goodCount  O $_okCount  M $_missCount',
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                              Text(
                                                'MAX $_maxCombo',
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Positioned.fill(
                                          child: Listener(
                                            behavior: HitTestBehavior.opaque,
                                            onPointerDown: _handleBoardPointerDown,
                                            child: const SizedBox.expand(),
                                          ),
                                        ),
                                        if (_gameOver || _songFinished)
                                          Positioned.fill(
                                            child: Container(
                                              color: Colors.black.withValues(alpha: 0.72),
                                              child: Center(
                                                child: Container(
                                                  margin: const EdgeInsets.all(24),
                                                  padding: const EdgeInsets.all(22),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFF101010),
                                                    borderRadius: BorderRadius.circular(24),
                                                    border: Border.all(color: Colors.white12),
                                                  ),
                                                  child: Column(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: <Widget>[
                                                      Text(
                                                        _gameOver ? 'GAME OVER' : 'DONE',
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 28,
                                                          fontWeight: FontWeight.w900,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 10),
                                                      Text(
                                                        _errorMessage ?? 'Goed gespeeld',
                                                        textAlign: TextAlign.center,
                                                        style: const TextStyle(color: Colors.white70),
                                                      ),
                                                      const SizedBox(height: 16),
                                                      FilledButton(
                                                        onPressed: () {
                                                          _startGameLoop();
                                                        },
                                                        child: const Text('Play Again'),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        if (!_isLoading && !_isPlaying && !_gameOver && !_songFinished)
                                          Positioned.fill(
                                            child: Container(
                                              color: Colors.black.withValues(alpha: 0.36),
                                              child: Center(
                                                child: FilledButton(
                                                  onPressed: _startGameLoop,
                                                  style: FilledButton.styleFrom(
                                                    backgroundColor: Colors.white,
                                                    foregroundColor: Colors.black,
                                                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                                                    textStyle: const TextStyle(
                                                      fontSize: 22,
                                                      fontWeight: FontWeight.w900,
                                                    ),
                                                  ),
                                                  child: const Text('START'),
                                                ),
                                              ),
                                            ),
                                          ),
                                        if (_lastJudgement.isNotEmpty &&
                                            _lastJudgementAt != null &&
                                            DateTime.now().difference(_lastJudgementAt!) < const Duration(milliseconds: 700))
                                          Positioned(
                                            left: 0,
                                            right: 0,
                                            top: hitZoneY - 78,
                                            child: IgnorePointer(
                                              child: Center(
                                                child: Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black.withValues(alpha: 0.54),
                                                    borderRadius: BorderRadius.circular(999),
                                                    border: Border.all(color: Colors.white24),
                                                  ),
                                                  child: Text(
                                                    _lastJudgement,
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 16,
                                                      fontWeight: FontWeight.w900,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
        ),
      ),
    );
  }

  List<Widget> _buildVisibleNotes(
    double height,
    double laneWidth,
    double hitZoneY,
    double travelDistance,
  ) {
    final double elapsedMillis = _playheadMillis;
    final List<Widget> widgets = <Widget>[];

    for (final _GameTileNote note in _notes) {
      if (note.missed) {
        continue;
      }

      if (note.hit) {
        continue;
      }

      final double noteStartMillis = note.startMillis;
      if (noteStartMillis - elapsedMillis > _previewAheadMillis || elapsedMillis - noteStartMillis > _missAfterMillis) {
        continue;
      }

      final double timeToHit = noteStartMillis - elapsedMillis;
      final double top = hitZoneY - (timeToHit / _previewAheadMillis) * travelDistance;
      final double tileHeight = (height * 0.13).clamp(72.0, 120.0);
      final double left = note.lane * laneWidth + 2;
      final double width = laneWidth - 4;
      final double clampedTop = top.clamp(-tileHeight, height - 16);

      widgets.add(
        Positioned(
          left: left,
          top: clampedTop,
          width: width,
          height: tileHeight,
          child: Container(
            decoration: BoxDecoration(
              color: _tileColor(note.lane, active: false, hit: false),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _laneAccent(note.lane).withValues(alpha: 0.82),
                width: 1.0,
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 10,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Stack(
              children: <Widget>[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 6,
                    decoration: BoxDecoration(
                      color: _laneAccent(note.lane).withValues(alpha: 0.92),
                      borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return widgets;
  }
}

class _ScheduledNoteOff {
  const _ScheduledNoteOff({required this.midiNote, required this.endMillis});

  final int midiNote;
  final double endMillis;
}

class _GameTileNote {
  _GameTileNote({
    required this.id,
    required this.midiNote,
    required this.lane,
    required this.startMicros,
    required this.endMicros,
  });

  final int id;
  final int midiNote;
  final int lane;
  final int startMicros;
  final int endMicros;

  bool hit = false;
  bool missed = false;
  bool sounded = false;

  int get durationMicros => endMicros - startMicros;
  double get startMillis => startMicros / 1000;
}
