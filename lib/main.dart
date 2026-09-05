import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

void main() => runApp(const MaterialApp(home: Accueil()));

class Accueil extends StatefulWidget {
  const Accueil({super.key});

  @override
  State<Accueil> createState() => _AccueilState();
}

class _AccueilState extends State<Accueil> {
  String? pdfPath;
  String statut = "Chargement...";
  late StreamSubscription _intentSub;

  @override
  void initState() {
    super.initState();

    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((files) {
      if (files.isNotEmpty) {
        setState(() {
          pdfPath = files.first.path;
        });
      }
    });

    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      if (files.isNotEmpty) {
        setState(() {
          pdfPath = files.first.path;
        });
      } else {
        _chargerPdfDeTest();
      }
    });
  }

  @override
  void dispose() {
    _intentSub.cancel();
    super.dispose();
  }

  Future<void> _chargerPdfDeTest() async {
    try {
      final url = Uri.parse(
          "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf");
      final client = HttpClient();
      final request = await client.getUrl(url);
      final response = await request.close();
      final bytesBuilder = BytesBuilder();
      await for (final chunk in response) {
        bytesBuilder.add(chunk);
      }
      final fichier = File("${Directory.systemTemp.path}/test.pdf");
      await fichier.writeAsBytes(bytesBuilder.toBytes());
      setState(() {
        pdfPath = fichier.path;
      });
    } catch (e) {
      setState(() {
        statut = "Erreur : $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Mon éditeur PDF")),
      body: pdfPath == null
          ? Center(child: Text(statut))
          : PDFView(filePath: pdfPath!),
    );
  }
} 

