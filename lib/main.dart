import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';

const _channel = MethodChannel("com.nabilainas.pdfeditor/open_pdf");

void main() => runApp(const MaterialApp(home: Accueil()));

class Accueil extends StatefulWidget {
  const Accueil({super.key});

  @override
  State<Accueil> createState() => _AccueilState();
}

class _AccueilState extends State<Accueil> {
  String? pdfPath;
  String statut = "Chargement...";

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final path = await _channel.invokeMethod<String>("getInitialPdfPath");
      if (path != null) {
        setState(() => pdfPath = path);
        return;
      }
    } catch (_) {}
    _chargerPdfDeTest();
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
      setState(() => pdfPath = fichier.path);
    } catch (e) {
      setState(() => statut = "Erreur : $e");
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
