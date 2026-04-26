import 'package:flutter/material.dart';

class PolyphonyLimitPage extends StatelessWidget {
  const PolyphonyLimitPage({
    super.key,
    required this.fileName,
    required this.maxSimultaneousNotes,
  });

  final String fileName;
  final int maxSimultaneousNotes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Song Niet Toegelaten')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Deze MIDI gebruikt te veel noten tegelijk.',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text('Bestand: $fileName'),
            Text('Max tegelijk gedetecteerd: $maxSimultaneousNotes'),
            const SizedBox(height: 8),
            const Text('Toegelaten maximum is 5 noten tegelijk.'),
            const Spacer(),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.arrow_back),
              label: const Text('Terug'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
