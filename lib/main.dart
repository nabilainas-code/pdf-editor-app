import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

const _channel = MethodChannel("com.nabilainas.pdfeditor/open_pdf");

void main() => runApp(const MaterialApp(home: Accueil()));

class MotDetecte {
  String texte;
  final Rect zone;
  MotDetecte(this.texte, this.zone);
}

class Accueil extends StatefulWidget {
  const Accueil({super.key});

  @override
  State<Accueil> createState() => _AccueilState();
}

class _AccueilState extends State<Accueil> {
  PdfDocument? document;
  List<MotDetecte> mots = [];
  Size taillePage = const Size(595, 842);
  String statut = "Chargement...";
  MotDetecte? motSelectionne;
  bool enregistrementEnCours = false;

  Uint8List? imageDeFond;
  img.Image? imageDecodee;
  double echelleOcr = 1;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    document?.dispose();
    super.dispose();
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

  Future<void> _importerDocument() async {
    try {
      final resultat = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      final chemin = resultat?.files.single.path;
      if (chemin == null) return;
      setState(() {
        motSelectionne = null;
        statut = "Chargement...";
      });
      await _analyser(File(chemin).readAsBytesSync());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erreur d'importation : $e")),
        );
      }
    }
  }

  Future<void> _analyser(Uint8List octets) async {
    document?.dispose();
    document = null;
    try {
      final doc = PdfDocument(inputBytes: octets);
      final extracteur = PdfTextExtractor(doc);
      final lignes = extracteur.extractTextLines(startPageIndex: 0, endPageIndex: 0);

      final page = doc.pages[0];
      final trouvesTexte = <MotDetecte>[];

      for (final ligne in lignes) {
        for (final mot in ligne.wordCollection) {
          if (mot.text.trim().isEmpty) continue;
          trouvesTexte.add(MotDetecte(
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

      if (trouvesTexte.isNotEmpty) {
        setState(() {
          document = doc;
          mots = trouvesTexte;
          taillePage = Size(page.size.width, page.size.height);
          imageDeFond = null;
          imageDecodee = null;
          motSelectionne = null;
          statut = "${trouvesTexte.length} mot(s) détecté(s)";
        });
        return;
      }

      setState(() => statut = "Page scannée détectée, analyse OCR en cours...");
      await _analyserParOcr(doc, page);
    } catch (e) {
      setState(() => statut = "Erreur d'analyse : $e");
    }
  }

  Future<void> _analyserParOcr(PdfDocument doc, PdfPage page) async {
    const dpi = 200.0;
    TextRecognizer? recognizer;
    try {
      final octetsDoc = Uint8List.fromList(await doc.save());

      PdfRaster? raster;
      await for (final r in Printing.raster(octetsDoc, pages: const [0], dpi: dpi)) {
        raster = r;
        break;
      }
      if (raster == null) {
        throw Exception("Impossible de générer l'image de la page");
      }

      final pngOctets = await raster.toPng();
      final dossier = await getTemporaryDirectory();
      final fichierImage = File(
          '${dossier.path}/page_ocr_${DateTime.now().millisecondsSinceEpoch}.png');
      await fichierImage.writeAsBytes(pngOctets, flush: true);

      recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final texteReconnu = await recognizer.processImage(
        InputImage.fromFilePath(fichierImage.path),
      );

      final echelle = dpi / 72.0;
      final trouves = <MotDetecte>[];
      for (final bloc in texteReconnu.blocks) {
        for (final ligne in bloc.lines) {
          for (final element in ligne.elements) {
            final b = element.boundingBox;
            trouves.add(MotDetecte(
              element.text,
              Rect.fromLTWH(
                b.left / echelle,
                b.top / echelle,
                b.width / echelle,
                b.height / echelle,
              ),
            ));
          }
        }
      }

      setState(() {
        document = doc;
        mots = trouves;
        taillePage = Size(page.size.width, page.size.height);
        imageDeFond = pngOctets;
        imageDecodee = img.decodePng(pngOctets);
        echelleOcr = echelle;
        motSelectionne = null;
        statut = "${trouves.length} mot(s) détecté(s) (OCR)";
      });
    } catch (e) {
      setState(() => statut = "Erreur OCR : $e");
    } finally {
      await recognizer?.close();
    }
  }

  PdfColor _couleurDeFond(MotDetecte mot) {
    final image = imageDecodee;
    if (image == null) return PdfColor(255, 255, 255);

    final x = ((mot.zone.left + mot.zone.width / 2) * echelleOcr)
        .round()
        .clamp(0, image.width - 1);
    final y = ((mot.zone.top * echelleOcr) - 4).round().clamp(0, image.height - 1);
    final pixel = image.getPixel(x, y);
    return PdfColor(pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt());
  }

  Future<void> _modifierMot(MotDetecte mot) async {
    final controleur = TextEditingController(text: mot.texte);
    final nouveauTexte = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Modifier le mot"),
        content: TextField(controller: controleur, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Annuler"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controleur.text),
            child: const Text("Valider"),
          ),
        ],
      ),
    );

    if (nouveauTexte == null) return;
    final texteNettoye = nouveauTexte.trim();
    if (texteNettoye.isEmpty || texteNettoye == mot.texte) return;

    final doc = document;
    if (doc == null) return;

    final page = doc.pages[0];
    final zoneCouverture = Rect.fromLTWH(
      mot.zone.left - 1,
      mot.zone.top - 1,
      mot.zone.width + 2,
      mot.zone.height + 2,
    );

    page.graphics.drawRectangle(
      brush: PdfSolidBrush(_couleurDeFond(mot)),
      bounds: zoneCouverture,
    );

    page.graphics.drawString(
      texteNettoye,
      PdfStandardFont(PdfFontFamily.helvetica, mot.zone.height * 0.75),
      bounds: mot.zone,
      brush: PdfSolidBrush(PdfColor(0, 0, 0)),
      format: PdfStringFormat(
        alignment: PdfTextAlignment.left,
        lineAlignment: PdfVerticalAlignment.middle,
      ),
    );

    setState(() {
      mot.texte = texteNettoye;
      motSelectionne = mot;
    });
  }

  Future<void> _enregistrer() async {
    final doc = document;
    if (doc == null) return;

    setState(() => enregistrementEnCours = true);
    try {
      final List<int> octets = await doc.save();
      final dossier = await getTemporaryDirectory();
      final horodatage = DateTime.now().millisecondsSinceEpoch;
      final fichier = File('${dossier.path}/pdf_modifie_$horodatage.pdf');
      await fichier.writeAsBytes(octets, flush: true);
      await Share.shareXFiles([XFile(fichier.path)], text: "PDF modifié");
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erreur d'enregistrement : $e")),
        );
      }
    } finally {
      if (mounted) setState(() => enregistrementEnCours = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Mon éditeur PDF"),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: "Importer un document",
            onPressed: _importerDocument,
          ),
          IconButton(
            icon: enregistrementEnCours
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            tooltip: "Enregistrer et partager",
            onPressed: (document == null || enregistrementEnCours)
                ? null
                : _enregistrer,
          ),
        ],
      ),
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
                              SizedBox.expand(
                                child: imageDeFond != null
                                    ? Image.memory(imageDeFond!, fit: BoxFit.fill)
                                    : Container(color: Colors.white),
                              ),
                              for (final mot in mots)
                                Positioned(
                                  left: mot.zone.left * echelle,
                                  top: mot.zone.top * echelle,
                                  width: mot.zone.width * echelle,
                                  height: mot.zone.height * echelle,
                                  child: GestureDetector(
                                    onTap: () => _modifierMot(mot),
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
