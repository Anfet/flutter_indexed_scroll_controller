import 'package:example/fingerprint_screen.dart';
import 'package:example/horizontal_screen.dart';
import 'package:example/vertical_screen.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Indexed Scroll Example',
      home: HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Indexed Scroll Controller Examples')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Fingerprint Invalidation'),
            subtitle: const Text('Automatic invalidation on data change'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const FingerprintScreen(),
                ),
              );
            },
          ),
          ListTile(
            title: const Text('Vertical'),
            subtitle: const Text('Vertical scrolling with alignment control'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const VerticalScreen(),
                ),
              );
            },
          ),
          ListTile(
            title: const Text('Horizontal'),
            subtitle:
                const Text('Horizontal scrolling with variable card widths'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const HorizontalScreen(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
