
import 'package:flutter/material.dart';

void main() => runApp(const MaterialApp(home: Accueil()));

class Accueil extends StatelessWidget {
  const Accueil({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mon éditeur PDF')),
      body: const Center(child: Text('Installation réussie !')),
    );
  }
}
