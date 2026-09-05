import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

const _channel = MethodChannel("com.nabilainas.pdfeditor/open_pdf");

void main() => runApp(const MaterialApp(home: Accueil()));

class MotDetecte {
  final String texte;
  final Rect zone;
  MotDetecte(this.texte, this.zone);
}

class Accueil extends StatefulWidget {
  const Accueil({super.key});

  @override
  State<Accueil> createState() => _AccueilState();
}

class _AccueilState extends State<Accueil> {
  List<MotDetecte> mots = [];
  Size taillePage = const Size(595, 842);
  String statut = "Chargement...";
  MotDetecte? motSelectionne;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final path = await _channel.invokeMethod<String>("getInitialPdfPath");
      if (path != null) {
        await _analyser(File(path).readAsBytesSync());
        return;
      }
    } catch (_) {}
    await _chargerPdfDeTest();
  }

  Future<void> _chargerPdfDeTest() async {
    try {
      final url = Uri.parse(
          "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf");
      final client = HttpClient();
      final request = await client.getUrl(url);
      final response = await request.close();
      final builder = BytesBuilder();
      await for (final chunk in response) {
        builder.add(chunk);
      }
      await _analyser(builder.toBytes());
    } catch (e) {
      setState(() => statut = "Erreur : $e");
    }
  }

  Future<void> _analyser(Uint8List octets) async {
    try {
      final document = PdfDocument(inputBytes: octets);
      final extracteur = PdfTextExtractor(document);
      final lignes = extracteur.extractTextLines(startPageIndex: 0, endPageIndex: 0);

      final page = document.pages[0];
      final trouves = <MotDetecte>[];

      for (final ligne in lignes) {
        for (final mot in ligne.wordCollection) {
          if (mot.text.trim().isEmpty) continue;
          trouves.add(MotDetecte(
            mot.text,
            Rect.fromLTWH(
              mot.bounds.left,
              mot.bounds.top,
              mot.bounds.width,
              mot.bounds.height,
            ),
          ));
        }
      }

      setState(() {
        mots = trouves;
        taillePage = Size(page.size.width, page.size.height);
        statut = "${trouves.length} mot(s) détecté(s)";
      });

      document.dispose();
    } catch (e) {
      setState(() => statut = "Erreur d'analyse : $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Mon éditeur PDF")),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              motSelectionne == null ? statut : "Mot : ${motSelectionne!.texte}",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: mots.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final echelle = constraints.maxWidth / taillePage.width;
                      return SingleChildScrollView(
                        child: SizedBox(
                          width: constraints.maxWidth,
                          height: taillePage.height * echelle,
                          child: Stack(
                            children: [
                              Container(color: Colors.white),
                              for (final mot in mots)
                                Positioned(
                                  left: mot.zone.left * echelle,
                                  top: mot.zone.top * echelle,
                                  width: mot.zone.width * echelle,
                                  height: mot.zone.height * echelle,
                                  child: GestureDetector(
                                    onTap: () =>
                                        setState(() => motSelectionne = mot),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: motSelectionne == mot
                                              ? Colors.red
                                              : Colors.blue.withOpacity(0.3),
                                          width: motSelectionne == mot ? 2 : 1,
                                        ),
                                      ),
                                      child: FittedBox(
                                        fit: BoxFit.contain,
                                        child: Text(mot.texte),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
