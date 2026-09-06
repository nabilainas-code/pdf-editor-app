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
  Rect zone;
  bool gras;
  MotDetecte(this.texte, this.zone, {this.gras = false});
}

class Etat {
  final Uint8List octetsDocument;
  final List<MotDetecte> mots;
  final Uint8List? image;
  Etat(this.octetsDocument, this.mots, this.image);
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

  final List<Etat> historique = [];
  final List<Etat> futur = [];

  MotDetecte? ligneEnDeplacement;
  Offset deplacementEnCours = Offset.zero;

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
      final resultat = await FilePicker.platform.pickFiles(
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
    historique.clear();
    futur.clear();
    try {
      final doc = PdfDocument(inputBytes: octets);
      final extracteur = PdfTextExtractor(doc);
      final lignes = extracteur.extractTextLines(startPageIndex: 0, endPageIndex: 0);

      final page = doc.pages[0];
      final trouvesTexte = <MotDetecte>[];

      for (final ligne in lignes) {
        if (ligne.text.trim().isEmpty) continue;
        trouvesTexte.add(MotDetecte(
          ligne.text,
          Rect.fromLTWH(
            ligne.bounds.left,
            ligne.bounds.top,
            ligne.bounds.width,
            ligne.bounds.height,
          ),
          gras: ligne.fontStyle.contains(PdfFontStyle.bold),
        ));
      }

      if (trouvesTexte.isNotEmpty) {
        setState(() {
          document = doc;
          mots = trouvesTexte;
          taillePage = Size(page.size.width, page.size.height);
          imageDeFond = null;
          imageDecodee = null;
          motSelectionne = null;
          statut = "${trouvesTexte.length} ligne(s) détectée(s)";
        });
        return;
      }

      setState(() => statut = "Page scannée détectée, analyse OCR en cours...");
      await _analyserParOcr(doc, page);
    } catch (e) {
      setState(() => statut = "Erreur d'analyse : $e");
    }
  }

  /// Regroupe les fragments de ligne détectés par l'OCR qui appartiennent à
  /// la même rangée horizontale (ex : une puce "-" séparée du texte qui suit).
  List<MotDetecte> _fusionnerParRangee(List<MotDetecte> brutes) {
    if (brutes.isEmpty) return brutes;
    final triees = [...brutes]..sort((a, b) => a.zone.top.compareTo(b.zone.top));
    final rangees = <List<MotDetecte>>[];

    for (final ligne in triees) {
      final centre = ligne.zone.top + ligne.zone.height / 2;
      List<MotDetecte>? cible;
      for (final rangee in rangees) {
        final refCentre = rangee.first.zone.top + rangee.first.zone.height / 2;
        final tolerance =
            (rangee.first.zone.height + ligne.zone.height) / 2 * 0.6;
        if ((centre - refCentre).abs() < tolerance) {
          cible = rangee;
          break;
        }
      }
      if (cible != null) {
        cible.add(ligne);
      } else {
        rangees.add([ligne]);
      }
    }

    final resultat = <MotDetecte>[];
    for (final rangee in rangees) {
      rangee.sort((a, b) => a.zone.left.compareTo(b.zone.left));
      final texte = rangee.map((l) => l.texte).join(' ');
      var gauche = rangee.first.zone.left;
      var haut = rangee.first.zone.top;
      var droite = rangee.first.zone.left + rangee.first.zone.width;
      var bas = rangee.first.zone.top + rangee.first.zone.height;
      for (final l in rangee.skip(1)) {
        if (l.zone.left < gauche) gauche = l.zone.left;
        if (l.zone.top < haut) haut = l.zone.top;
        final d = l.zone.left + l.zone.width;
        final b = l.zone.top + l.zone.height;
        if (d > droite) droite = d;
        if (b > bas) bas = b;
      }
      resultat.add(MotDetecte(
        texte,
        Rect.fromLTWH(gauche, haut, droite - gauche, bas - haut),
      ));
    }
    return resultat;
  }

  /// Estime si une zone de l'image scannée correspond à du texte gras, en
  /// mesurant la densité de pixels sombres (une image scannée n'a pas de
  /// métadonnées de police, contrairement à un PDF texte natif).
  bool _detecterGras(img.Image image, Rect zonePdf, double echelle) {
    final gauche = (zonePdf.left * echelle).round().clamp(0, image.width - 1);
    final haut = (zonePdf.top * echelle).round().clamp(0, image.height - 1);
    final droite = ((zonePdf.left + zonePdf.width) * echelle)
        .round()
        .clamp(gauche + 1, image.width);
    final bas = ((zonePdf.top + zonePdf.height) * echelle)
        .round()
        .clamp(haut + 1, image.height);

    var sombres = 0;
    var total = 0;
    for (var y = haut; y < bas; y += 2) {
      for (var x = gauche; x < droite; x += 2) {
        final pixel = image.getPixel(x, y);
        final luminance = (pixel.r + pixel.g + pixel.b) / 3;
        if (luminance < 140) sombres++;
        total++;
      }
    }
    if (total == 0) return false;
    return (sombres / total) > 0.16;
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
      final brutes = <MotDetecte>[];
      for (final bloc in texteReconnu.blocks) {
        for (final ligne in bloc.lines) {
          if (ligne.text.trim().isEmpty) continue;
          final b = ligne.boundingBox;
          brutes.add(MotDetecte(
            ligne.text,
            Rect.fromLTWH(
              b.left / echelle,
              b.top / echelle,
              b.width / echelle,
              b.height / echelle,
            ),
          ));
        }
      }

      final imageAnalysee = img.decodePng(pngOctets);
      final fusionnees = _fusionnerParRangee(brutes);
      if (imageAnalysee != null) {
        for (final ligne in fusionnees) {
          ligne.gras = _detecterGras(imageAnalysee, ligne.zone, echelle);
        }
      }

      setState(() {
        document = doc;
        mots = fusionnees;
        taillePage = Size(page.size.width, page.size.height);
        imageDeFond = pngOctets;
        imageDecodee = imageAnalysee;
        echelleOcr = echelle;
        motSelectionne = null;
        statut = "${fusionnees.length} ligne(s) détectée(s) (OCR)";
      });
    } catch (e) {
      setState(() => statut = "Erreur OCR : $e");
    } finally {
      await recognizer?.close();
    }
  }

  Future<void> _rafraichirApercuOcr(PdfDocument doc) async {
    const dpi = 200.0;
    try {
      final octetsDoc = Uint8List.fromList(await doc.save());
      PdfRaster? raster;
      await for (final r in Printing.raster(octetsDoc, pages: const [0], dpi: dpi)) {
        raster = r;
        break;
      }
      if (raster == null) return;
      final pngOctets = await raster.toPng();
      if (!mounted) return;
      setState(() {
        imageDeFond = pngOctets;
        imageDecodee = img.decodePng(pngOctets);
      });
    } catch (_) {}
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

  PdfStandardFont _police(MotDetecte mot) {
    return PdfStandardFont(
      PdfFontFamily.helvetica,
      mot.zone.height * 0.75,
      style: mot.gras ? PdfFontStyle.bold : PdfFontStyle.regular,
    );
  }

  Future<Etat> _etatActuel(PdfDocument doc) async {
    final octetsDocument = Uint8List.fromList(await doc.save());
    final motsCopie =
        mots.map((m) => MotDetecte(m.texte, m.zone, gras: m.gras)).toList();
    return Etat(octetsDocument, motsCopie, imageDeFond);
  }

  Future<void> _restaurerEtat(Etat etat) async {
    document?.dispose();
    final doc = PdfDocument(inputBytes: etat.octetsDocument);
    setState(() {
      document = doc;
      mots = etat.mots
          .map((m) => MotDetecte(m.texte, m.zone, gras: m.gras))
          .toList();
      imageDeFond = etat.image;
      imageDecodee = etat.image != null ? img.decodePng(etat.image!) : null;
      motSelectionne = null;
    });
  }

  Future<void> _annuler() async {
    final doc = document;
    if (doc == null || historique.isEmpty) return;
    final etatActuel = await _etatActuel(doc);
    final precedent = historique.removeLast();
    setState(() => futur.add(etatActuel));
    await _restaurerEtat(precedent);
  }

  Future<void> _retablir() async {
    final doc = document;
    if (doc == null || futur.isEmpty) return;
    final etatActuel = await _etatActuel(doc);
    final suivant = futur.removeLast();
    setState(() => historique.add(etatActuel));
    await _restaurerEtat(suivant);
  }

  Future<void> _modifierMot(MotDetecte mot) async {
    const pas = 3.0;
    final controleur = TextEditingController(text: mot.texte);
    var grasChoisi = mot.gras;
    var dxChoisi = 0.0;
    var dyChoisi = 0.0;

    final resultat = await showDialog<Map<String, Object>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text("Modifier la ligne"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: controleur, autofocus: true),
              Row(
                children: [
                  Checkbox(
                    value: grasChoisi,
                    onChanged: (v) =>
                        setDialogState(() => grasChoisi = v ?? false),
                  ),
                  const Text("Gras"),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                "Position : ${dxChoisi >= 0 ? '+' : ''}${dxChoisi.toStringAsFixed(0)}, "
                "${dyChoisi >= 0 ? '+' : ''}${dyChoisi.toStringAsFixed(0)}",
              ),
              IconButton(
                icon: const Icon(Icons.arrow_upward),
                onPressed: () => setDialogState(() => dyChoisi -= pas),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => setDialogState(() => dxChoisi -= pas),
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: () => setDialogState(() => dxChoisi += pas),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.arrow_downward),
                onPressed: () => setDialogState(() => dyChoisi += pas),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Annuler"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(
                  ctx, {"texte": "", "gras": grasChoisi, "dx": 0.0, "dy": 0.0}),
              child: const Text("Supprimer"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, {
                "texte": controleur.text,
                "gras": grasChoisi,
                "dx": dxChoisi,
                "dy": dyChoisi,
              }),
              child: const Text("Valider"),
            ),
          ],
        ),
      ),
    );

    if (resultat == null) return;
    final texteNettoye = (resultat["texte"] as String).trim();
    final grasFinal = resultat["gras"] as bool;
    final dx = resultat["dx"] as double;
    final dy = resultat["dy"] as double;
    if (texteNettoye == mot.texte &&
        grasFinal == mot.gras &&
        dx == 0 &&
        dy == 0) {
      return;
    }

    final doc = document;
    if (doc == null) return;

    historique.add(await _etatActuel(doc));
    futur.clear();

    final page = doc.pages[0];
    final ancienneZone = mot.zone;
    final zoneCouverture = Rect.fromLTWH(
      ancienneZone.left - 1,
      ancienneZone.top - 1,
      ancienneZone.width + 2,
      ancienneZone.height + 2,
    );

    page.graphics.drawRectangle(
      brush: PdfSolidBrush(_couleurDeFond(mot)),
      bounds: zoneCouverture,
    );

    mot.gras = grasFinal;
    final nouvelleZone =
        (dx != 0 || dy != 0) ? ancienneZone.translate(dx, dy) : ancienneZone;

    if (texteNettoye.isNotEmpty) {
      page.graphics.drawString(
        texteNettoye,
        _police(mot),
        bounds: nouvelleZone,
        brush: PdfSolidBrush(PdfColor(0, 0, 0)),
        format: PdfStringFormat(
          alignment: PdfTextAlignment.left,
          lineAlignment: PdfVerticalAlignment.middle,
        ),
      );
    }

    setState(() {
      mot.texte = texteNettoye;
      mot.zone = nouvelleZone;
      motSelectionne = texteNettoye.isEmpty ? null : mot;
    });

    if (imageDeFond != null) {
      await _rafraichirApercuOcr(doc);
    }
  }

  Future<void> _deplacerLigne(MotDetecte mot, double dx, double dy) async {
    if (dx == 0 && dy == 0) return;
    final doc = document;
    if (doc == null) return;

    historique.add(await _etatActuel(doc));
    futur.clear();

    final page = doc.pages[0];
    final ancienneZone = mot.zone;
    final zoneCouverture = Rect.fromLTWH(
      ancienneZone.left - 1,
      ancienneZone.top - 1,
      ancienneZone.width + 2,
      ancienneZone.height + 2,
    );

    page.graphics.drawRectangle(
      brush: PdfSolidBrush(_couleurDeFond(mot)),
      bounds: zoneCouverture,
    );

    final nouvelleZone = Rect.fromLTWH(
      ancienneZone.left + dx,
      ancienneZone.top + dy,
      ancienneZone.width,
      ancienneZone.height,
    );

    if (mot.texte.isNotEmpty) {
      page.graphics.drawString(
        mot.texte,
        _police(mot),
        bounds: nouvelleZone,
        brush: PdfSolidBrush(PdfColor(0, 0, 0)),
        format: PdfStringFormat(
          alignment: PdfTextAlignment.left,
          lineAlignment: PdfVerticalAlignment.middle,
        ),
      );
    }

    setState(() => mot.zone = nouvelleZone);

    if (imageDeFond != null) {
      await _rafraichirApercuOcr(doc);
    }
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
            icon: const Icon(Icons.undo),
            tooltip: "Annuler",
            onPressed: historique.isEmpty ? null : _annuler,
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            tooltip: "Rétablir",
            onPressed: futur.isEmpty ? null : _retablir,
          ),
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
              motSelectionne == null ? statut : "Ligne : ${motSelectionne!.texte}",
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
                                  left: mot.zone.left * echelle +
                                      (mot == ligneEnDeplacement
                                          ? deplacementEnCours.dx
                                          : 0),
                                  top: mot.zone.top * echelle +
                                      (mot == ligneEnDeplacement
                                          ? deplacementEnCours.dy
                                          : 0),
                                  width: mot.zone.width * echelle,
                                  height: mot.zone.height * echelle,
                                  child: GestureDetector(
                                    onTap: () => _modifierMot(mot),
                                    onPanStart: (_) => setState(() {
                                      ligneEnDeplacement = mot;
                                      deplacementEnCours = Offset.zero;
                                    }),
                                    onPanUpdate: (details) => setState(() {
                                      deplacementEnCours += details.delta;
                                    }),
                                    onPanEnd: (_) async {
                                      final dx = deplacementEnCours.dx / echelle;
                                      final dy = deplacementEnCours.dy / echelle;
                                      setState(() {
                                        ligneEnDeplacement = null;
                                        deplacementEnCours = Offset.zero;
                                      });
                                      await _deplacerLigne(mot, dx, dy);
                                    },
                                    child: Container(
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: motSelectionne == mot
                                              ? Colors.red
                                              : Colors.blue.withOpacity(0.3),
                                          width: motSelectionne == mot ? 2 : 1,
                                        ),
                                      ),
                                      child: imageDeFond != null
                                          ? null
                                          : FittedBox(
                                              fit: BoxFit.contain,
                                              child: Text(
                                                mot.texte,
                                                style: TextStyle(
                                                  fontWeight: mot.gras
                                                      ? FontWeight.bold
                                                      : FontWeight.normal,
                                                ),
                                              ),
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
