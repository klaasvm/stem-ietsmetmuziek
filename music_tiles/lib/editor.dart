import 'package:flutter/material.dart';

class MidiEditNote {
  MidiEditNote({
    required this.id,
    required this.note,
    required this.velocity,
    required this.startMicros,
    required this.endMicros,
  });

  final int id;
  final int note;
  final int velocity;
  final int startMicros;
  final int endMicros;

  int get durationMicros => endMicros - startMicros;
}

class MidiEditDraft {
  MidiEditDraft({
    required this.notes,
    required this.totalDurationMicros,
    required this.rawNoteCount,
    required this.tempoChangeCount,
    required this.trackCount,
    required this.format,
    required this.ticksPerQuarterNote,
  });

  final List<MidiEditNote> notes;
  final int totalDurationMicros;
  final int rawNoteCount;
  final int tempoChangeCount;
  final int trackCount;
  final int format;
  final int ticksPerQuarterNote;

  MidiEditDraft copyWith({
    List<MidiEditNote>? notes,
    int? totalDurationMicros,
    int? rawNoteCount,
    int? tempoChangeCount,
    int? trackCount,
    int? format,
    int? ticksPerQuarterNote,
  }) {
    return MidiEditDraft(
      notes: notes ?? List<MidiEditNote>.from(this.notes),
      totalDurationMicros: totalDurationMicros ?? this.totalDurationMicros,
      rawNoteCount: rawNoteCount ?? this.rawNoteCount,
      tempoChangeCount: tempoChangeCount ?? this.tempoChangeCount,
      trackCount: trackCount ?? this.trackCount,
      format: format ?? this.format,
      ticksPerQuarterNote: ticksPerQuarterNote ?? this.ticksPerQuarterNote,
    );
  }
}

class MidiEditResult {
  MidiEditResult({
    required this.draft,
    required this.removedNoteCount,
    required this.limit,
  });

  final MidiEditDraft draft;
  final int removedNoteCount;
  final int limit;
}

enum _FixPriority { velocity, duration }

class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.fileName,
    required this.initialDraft,
    this.maxSimultaneousNotes = 5,
  });

  final String fileName;
  final MidiEditDraft initialDraft;
  final int maxSimultaneousNotes;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  late List<MidiEditNote> _originalNotes;
  late List<MidiEditNote> _workingNotes;
  bool _autoFixApplied = false;
  bool _showOnlyHotspots = false;
  _FixPriority _fixPriority = _FixPriority.velocity;

  @override
  void initState() {
    super.initState();
    _originalNotes = List<MidiEditNote>.from(widget.initialDraft.notes);
    _workingNotes = List<MidiEditNote>.from(widget.initialDraft.notes);
  }

  int get _currentMax => _computeMaxSimultaneousNotes(_workingNotes);

  int get _removedCount => _originalNotes.length - _workingNotes.length;

  List<_OverlapHotspot> get _hotspots => _computeHotspots(
    notes: _workingNotes,
    limit: widget.maxSimultaneousNotes,
  );

  List<MidiEditNote> get _visibleNotes {
    if (!_showOnlyHotspots) {
      return _workingNotes;
    }

    final List<_OverlapHotspot> hotspots = _hotspots;
    if (hotspots.isEmpty) {
      return <MidiEditNote>[];
    }

    return _workingNotes.where((MidiEditNote note) {
      for (final _OverlapHotspot hotspot in hotspots) {
        final bool overlaps =
            note.startMicros < hotspot.endMicros &&
            note.endMicros > hotspot.startMicros;
        if (overlaps) {
          return true;
        }
      }
      return false;
    }).toList();
  }

  Future<void> _applyAutoFixWithConfirmation() async {
    final List<MidiEditNote> fixedPreview = _limitPolyphony(
      _workingNotes,
      widget.maxSimultaneousNotes,
      _fixPriority,
    );
    final int removeCount = _workingNotes.length - fixedPreview.length;

    if (removeCount <= 0) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Geen extra fix nodig; song zit al binnen limiet.'),
        ),
      );
      return;
    }

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Fix toepassen?'),
          content: Text(
            'Er worden $removeCount noten verwijderd om overal maximaal ${widget.maxSimultaneousNotes} tegelijk te houden.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Annuleren'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Toepassen'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    setState(() {
      _workingNotes = fixedPreview;
      _autoFixApplied = true;
    });

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Auto-fix klaar: $removeCount noten verwijderd, max nu ${_computeMaxSimultaneousNotes(_workingNotes)}.',
        ),
      ),
    );
  }

  void _restoreOriginal() {
    setState(() {
      _workingNotes = List<MidiEditNote>.from(_originalNotes);
      _autoFixApplied = false;
    });
  }

  void _removeNote(int id) {
    setState(() {
      _workingNotes = _workingNotes
          .where((MidiEditNote n) => n.id != id)
          .toList();
    });
  }

  void _saveAndClose() {
    final List<MidiEditNote> sorted = List<MidiEditNote>.from(_workingNotes)
      ..sort((MidiEditNote a, MidiEditNote b) {
        final int compareStart = a.startMicros.compareTo(b.startMicros);
        if (compareStart != 0) {
          return compareStart;
        }
        return a.note.compareTo(b.note);
      });

    final int totalDurationMicros = sorted.isEmpty
        ? 0
        : sorted
              .map((MidiEditNote note) => note.endMicros)
              .reduce((int a, int b) => a > b ? a : b);

    final MidiEditDraft resultDraft = widget.initialDraft.copyWith(
      notes: sorted,
      totalDurationMicros: totalDurationMicros,
    );

    Navigator.of(context).pop(
      MidiEditResult(
        draft: resultDraft,
        removedNoteCount: _removedCount,
        limit: widget.maxSimultaneousNotes,
      ),
    );
  }

  String _formatMillis(int micros) {
    return '${(micros / 1000).round()} ms';
  }

  Widget _buildStatTile({
    required BuildContext context,
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(label, style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 2),
                Text(value, style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final int maxNow = _currentMax;
    final bool overLimit = maxNow > widget.maxSimultaneousNotes;
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final double pressure = widget.maxSimultaneousNotes <= 0
        ? 0
        : (maxNow / widget.maxSimultaneousNotes).clamp(0, 1).toDouble();
    final int durationMicros = _workingNotes.isEmpty
        ? 0
        : _workingNotes
              .map((MidiEditNote n) => n.endMicros)
              .reduce((int a, int b) => a > b ? a : b);
    final List<_OverlapHotspot> hotspots = _hotspots;

    return Scaffold(
      appBar: AppBar(title: const Text('Fix Editor')),
      body: SafeArea(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
                colorScheme.surface,
              ],
            ),
          ),
          child: Column(
            children: <Widget>[
              Flexible(
                flex: 4,
                child: SingleChildScrollView(
                  child: Column(
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                        child: Card(
                          elevation: 1,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  widget.fileName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: <Widget>[
                                    Chip(
                                      avatar: Icon(
                                        overLimit
                                            ? Icons.warning_amber
                                            : Icons.check,
                                        size: 16,
                                      ),
                                      label: Text(
                                        overLimit
                                            ? 'Boven limiet'
                                            : 'Binnen limiet',
                                      ),
                                    ),
                                    if (_autoFixApplied)
                                      const Chip(
                                        avatar: Icon(
                                          Icons.auto_fix_high,
                                          size: 16,
                                        ),
                                        label: Text('Auto-fix toegepast'),
                                      ),
                                    if (_removedCount > 0)
                                      Chip(
                                        avatar: const Icon(
                                          Icons.delete_outline,
                                          size: 16,
                                        ),
                                        label: Text(
                                          'Verwijderd: $_removedCount',
                                        ),
                                      ),
                                    Chip(
                                      avatar: const Icon(
                                        Icons.filter_list,
                                        size: 16,
                                      ),
                                      label: Text(
                                        'Hotspots: ${hotspots.length}',
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'Polyphony druk',
                                  style: Theme.of(context).textTheme.labelLarge,
                                ),
                                const SizedBox(height: 6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: LinearProgressIndicator(
                                    minHeight: 10,
                                    value: pressure,
                                    color: overLimit
                                        ? colorScheme.error
                                        : colorScheme.primary,
                                    backgroundColor:
                                        colorScheme.surfaceContainerHighest,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '$maxNow / ${widget.maxSimultaneousNotes} tegelijk',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(height: 12),
                                GridView.count(
                                  crossAxisCount: 2,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                  childAspectRatio: 2.2,
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  children: <Widget>[
                                    _buildStatTile(
                                      context: context,
                                      icon: Icons.piano,
                                      label: 'Noten nu',
                                      value: '${_workingNotes.length}',
                                    ),
                                    _buildStatTile(
                                      context: context,
                                      icon: Icons.history,
                                      label: 'Origineel',
                                      value: '${_originalNotes.length}',
                                    ),
                                    _buildStatTile(
                                      context: context,
                                      icon: Icons.timer,
                                      label: 'Totale duur',
                                      value: _formatMillis(durationMicros),
                                    ),
                                    _buildStatTile(
                                      context: context,
                                      icon: Icons.speed,
                                      label: 'Limiet',
                                      value: '${widget.maxSimultaneousNotes}',
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: <Widget>[
                                    Expanded(
                                      child: SegmentedButton<_FixPriority>(
                                        segments:
                                            const <ButtonSegment<_FixPriority>>[
                                              ButtonSegment<_FixPriority>(
                                                value: _FixPriority.velocity,
                                                label: Text('Hoge velocity'),
                                                icon: Icon(Icons.graphic_eq),
                                              ),
                                              ButtonSegment<_FixPriority>(
                                                value: _FixPriority.duration,
                                                label: Text('Lange noten'),
                                                icon: Icon(Icons.timelapse),
                                              ),
                                            ],
                                        selected: <_FixPriority>{_fixPriority},
                                        onSelectionChanged:
                                            (Set<_FixPriority> values) {
                                              setState(() {
                                                _fixPriority = values.first;
                                              });
                                            },
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text(
                                    'Toon alleen hotspot-noten',
                                  ),
                                  subtitle: const Text(
                                    'Laat enkel noten zien die in overlap > limiet zitten.',
                                  ),
                                  value: _showOnlyHotspots,
                                  onChanged: (bool value) {
                                    setState(() {
                                      _showOnlyHotspots = value;
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (hotspots.isNotEmpty)
                        SizedBox(
                          height: 110,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: hotspots.length,
                            itemBuilder: (BuildContext context, int index) {
                              final _OverlapHotspot hotspot = hotspots[index];
                              return Container(
                                width: 220,
                                margin: const EdgeInsets.only(
                                  right: 10,
                                  bottom: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: colorScheme.errorContainer,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        'Hotspot ${index + 1}',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleSmall,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${_formatMillis(hotspot.startMicros)} - ${_formatMillis(hotspot.endMicros)}',
                                      ),
                                      Text(
                                        'Piek: ${hotspot.peakSimultaneous} tegelijk',
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Row(
                          children: <Widget>[
                            Icon(Icons.tune, color: colorScheme.primary),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Noten overzicht (visueel en verwijderbaar)',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 6,
                child: _visibleNotes.isEmpty
                    ? Center(
                        child: Text(
                          'Geen noten zichtbaar voor huidige filter.',
                          style: Theme.of(context).textTheme.bodyLarge,
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        itemCount: _visibleNotes.length,
                        itemBuilder: (BuildContext context, int index) {
                          final MidiEditNote note = _visibleNotes[index];
                          final double hue = ((note.note % 12) / 12.0) * 360;
                          final Color accent = HSVColor.fromAHSV(
                            1,
                            hue,
                            0.48,
                            0.90,
                          ).toColor();

                          return Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: accent.withValues(alpha: 0.22),
                                child: Text(
                                  '${note.note}',
                                  style: TextStyle(
                                    color: accent,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              title: Text('Velocity ${note.velocity}'),
                              subtitle: Text(
                                'Start ${_formatMillis(note.startMicros)} | Duur ${_formatMillis(note.durationMicros)}',
                              ),
                              trailing: IconButton.filledTonal(
                                tooltip: 'Verwijder noot',
                                onPressed: () => _removeNote(note.id),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
                label: const Text('Weiger'),
              ),
              OutlinedButton.icon(
                onPressed: _restoreOriginal,
                icon: const Icon(Icons.restore),
                label: const Text('Herstel'),
              ),
              FilledButton.tonalIcon(
                onPressed: _applyAutoFixWithConfirmation,
                icon: const Icon(Icons.auto_fix_high),
                label: Text('Fix naar ${widget.maxSimultaneousNotes}'),
              ),
              FilledButton.icon(
                onPressed: _saveAndClose,
                icon: const Icon(Icons.check),
                label: const Text('Toepassen'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static int _computeMaxSimultaneousNotes(List<MidiEditNote> notes) {
    if (notes.isEmpty) {
      return 0;
    }

    final List<_NoteBoundary> boundaries = <_NoteBoundary>[];
    for (final MidiEditNote note in notes) {
      boundaries.add(_NoteBoundary(time: note.startMicros, delta: 1));
      boundaries.add(_NoteBoundary(time: note.endMicros, delta: -1));
    }

    boundaries.sort((_NoteBoundary a, _NoteBoundary b) {
      final int compareTime = a.time.compareTo(b.time);
      if (compareTime != 0) {
        return compareTime;
      }
      return a.delta.compareTo(b.delta);
    });

    int active = 0;
    int maxActive = 0;
    for (final _NoteBoundary boundary in boundaries) {
      active += boundary.delta;
      if (active > maxActive) {
        maxActive = active;
      }
    }
    return maxActive;
  }

  static List<_OverlapHotspot> _computeHotspots({
    required List<MidiEditNote> notes,
    required int limit,
  }) {
    if (notes.isEmpty || limit < 0) {
      return <_OverlapHotspot>[];
    }

    final List<_NoteBoundary> boundaries = <_NoteBoundary>[];
    for (final MidiEditNote note in notes) {
      boundaries.add(_NoteBoundary(time: note.startMicros, delta: 1));
      boundaries.add(_NoteBoundary(time: note.endMicros, delta: -1));
    }
    boundaries.sort((_NoteBoundary a, _NoteBoundary b) {
      final int compareTime = a.time.compareTo(b.time);
      if (compareTime != 0) {
        return compareTime;
      }
      return a.delta.compareTo(b.delta);
    });

    final List<_OverlapHotspot> hotspots = <_OverlapHotspot>[];
    int active = 0;
    int index = 0;
    int? segmentStart;
    int segmentPeak = 0;

    while (index < boundaries.length) {
      final int time = boundaries[index].time;

      if (segmentStart != null && time > segmentStart && active <= limit) {
        hotspots.add(
          _OverlapHotspot(
            startMicros: segmentStart,
            endMicros: time,
            peakSimultaneous: segmentPeak,
          ),
        );
        segmentStart = null;
        segmentPeak = 0;
      }

      int deltaSum = 0;
      while (index < boundaries.length && boundaries[index].time == time) {
        deltaSum += boundaries[index].delta;
        index += 1;
      }

      active += deltaSum;

      if (active > limit) {
        segmentStart ??= time;
        if (active > segmentPeak) {
          segmentPeak = active;
        }
      } else if (segmentStart != null) {
        hotspots.add(
          _OverlapHotspot(
            startMicros: segmentStart,
            endMicros: time,
            peakSimultaneous: segmentPeak,
          ),
        );
        segmentStart = null;
        segmentPeak = 0;
      }
    }

    return hotspots
        .where((_OverlapHotspot h) => h.endMicros > h.startMicros)
        .toList();
  }

  static List<MidiEditNote> _limitPolyphony(
    List<MidiEditNote> notes,
    int maxSimultaneousNotes,
    _FixPriority priority,
  ) {
    if (maxSimultaneousNotes <= 0 || notes.isEmpty) {
      return <MidiEditNote>[];
    }

    final List<MidiEditNote> sortedByStart = List<MidiEditNote>.from(notes)
      ..sort((MidiEditNote a, MidiEditNote b) {
        final int compareStart = a.startMicros.compareTo(b.startMicros);
        if (compareStart != 0) {
          return compareStart;
        }
        return b.velocity.compareTo(a.velocity);
      });

    final Set<int> keptIds = <int>{};
    final List<MidiEditNote> active = <MidiEditNote>[];

    for (final MidiEditNote candidate in sortedByStart) {
      active.removeWhere(
        (MidiEditNote note) => note.endMicros <= candidate.startMicros,
      );

      if (active.length < maxSimultaneousNotes) {
        active.add(candidate);
        keptIds.add(candidate.id);
        continue;
      }

      MidiEditNote weakest = active.first;
      for (final MidiEditNote item in active.skip(1)) {
        if (_isWeaker(item, weakest, priority)) {
          weakest = item;
        }
      }

      if (_isWeaker(weakest, candidate, priority)) {
        active.removeWhere((MidiEditNote note) => note.id == weakest.id);
        keptIds.remove(weakest.id);
        active.add(candidate);
        keptIds.add(candidate.id);
      }
    }

    final List<MidiEditNote> result = notes
        .where((MidiEditNote note) => keptIds.contains(note.id))
        .toList();

    result.sort((MidiEditNote a, MidiEditNote b) {
      final int compareStart = a.startMicros.compareTo(b.startMicros);
      if (compareStart != 0) {
        return compareStart;
      }
      return a.note.compareTo(b.note);
    });

    return result;
  }

  static bool _isWeaker(MidiEditNote a, MidiEditNote b, _FixPriority priority) {
    if (priority == _FixPriority.velocity) {
      if (a.velocity != b.velocity) {
        return a.velocity < b.velocity;
      }
      if (a.durationMicros != b.durationMicros) {
        return a.durationMicros < b.durationMicros;
      }
      return a.note < b.note;
    }

    if (a.durationMicros != b.durationMicros) {
      return a.durationMicros < b.durationMicros;
    }
    if (a.velocity != b.velocity) {
      return a.velocity < b.velocity;
    }
    return a.note < b.note;
  }
}

class _OverlapHotspot {
  _OverlapHotspot({
    required this.startMicros,
    required this.endMicros,
    required this.peakSimultaneous,
  });

  final int startMicros;
  final int endMicros;
  final int peakSimultaneous;
}

class _NoteBoundary {
  _NoteBoundary({required this.time, required this.delta});

  final int time;
  final int delta;
}
