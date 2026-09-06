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

void main() => runApp(MaterialApp(
      home: const Accueil(),
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blueGrey,
        scaffoldBackgroundColor: Colors.white,
      ),
    ));

class MotDetecte {
  String texte;
  Rect zone;
  bool gras;

  /// Vrai dès que l'application a elle-même dessiné ce texte : on sait alors
  /// qu'il occupe le rectangle mesuré en Helvetica (souvent plus large que la
  /// zone détectée), et donc quoi repeindre pour l'effacer.
  bool redessine;

  MotDetecte(this.texte, this.zone, {this.gras = false, this.redessine = false});
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
  PdfColor couleurPage = PdfColor(255, 255, 255);

  final List<Etat> historique = [];
  final List<Etat> futur = [];

  MotDetecte? ligneEnDeplacement;
  Offset deplacementEnCours = Offset.zero;

  String? texteCopie;
  bool grasCopie = false;
  double largeurCopiee = 100;
  double hauteurCopiee = 14;
  bool enCollage = false;

  static const double _pasDeplacement = 3.0;

  bool _occupe = false;

  final TransformationController _transformation = TransformationController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _transformation.dispose();
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
      final ligneHaut = ligne.zone.top;
      final ligneBas = ligne.zone.top + ligne.zone.height;
      List<MotDetecte>? cible;
      for (final rangee in rangees) {
        var rangeeHaut = rangee.first.zone.top;
        var rangeeBas = rangee.first.zone.top + rangee.first.zone.height;
        for (final l in rangee.skip(1)) {
          if (l.zone.top < rangeeHaut) rangeeHaut = l.zone.top;
          final b = l.zone.top + l.zone.height;
          if (b > rangeeBas) rangeeBas = b;
        }
        final chevauchement = (rangeeBas < ligneBas ? rangeeBas : ligneBas) -
            (rangeeHaut > ligneHaut ? rangeeHaut : ligneHaut);
        final hauteurMin = (rangeeBas - rangeeHaut) < ligne.zone.height
            ? (rangeeBas - rangeeHaut)
            : ligne.zone.height;
        if (hauteurMin > 0 && chevauchement > hauteurMin * 0.3) {
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

  /// Calcule la couleur dominante de toute la page (en principe le blanc du
  /// papier) en quantifiant les pixels d'une grille régulière et en gardant
  /// le groupe le plus fréquent. Comme le texte ne couvre qu'une petite
  /// partie de la page, cette couleur est beaucoup plus fiable pour
  /// "effacer" une ligne qu'un échantillon local qui peut tomber sur de
  /// l'encre selon l'endroit de la page.
  PdfColor _calculerCouleurPage(img.Image image) {
    final compteur = <int, int>{};
    for (var y = 0; y < image.height; y += 15) {
      for (var x = 0; x < image.width; x += 15) {
        final pixel = image.getPixel(x, y);
        final cle = ((pixel.r.toInt() ~/ 8) << 16) |
            ((pixel.g.toInt() ~/ 8) << 8) |
            (pixel.b.toInt() ~/ 8);
        compteur[cle] = (compteur[cle] ?? 0) + 1;
      }
    }
    if (compteur.isEmpty) return PdfColor(255, 255, 255);
    var cleFrequente = compteur.keys.first;
    var maxCompte = compteur[cleFrequente]!;
    for (final entree in compteur.entries) {
      if (entree.value > maxCompte) {
        maxCompte = entree.value;
        cleFrequente = entree.key;
      }
    }
    final r = ((cleFrequente >> 16) & 0xFF) * 8;
    final g = ((cleFrequente >> 8) & 0xFF) * 8;
    final b = (cleFrequente & 0xFF) * 8;
    return PdfColor(r, g, b);
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
        couleurPage = imageAnalysee != null
            ? _calculerCouleurPage(imageAnalysee)
            : PdfColor(255, 255, 255);
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

  /// Couleur utilisée pour "effacer" une ligne. On échantillonne d'abord
  /// juste autour de la zone (en ignorant les pixels sombres, donc l'encre)
  /// pour coller aux petites variations locales du fond (scan pas
  /// parfaitement uniforme), et on se rabat sur la couleur dominante de
  /// toute la page si l'entourage est trop couvert d'encre pour être fiable.
  PdfColor _couleurDeFond(MotDetecte mot) => _couleurLocale(mot.zone);

  PdfColor _couleurLocale(Rect zonePdf) {
    final image = imageDecodee;
    if (image == null) return couleurPage;
    final echelle = echelleOcr;

    const marge = 12.0;
    final gauche = ((zonePdf.left - marge) * echelle)
        .round()
        .clamp(0, image.width - 1);
    final droite = ((zonePdf.right + marge) * echelle)
        .round()
        .clamp(0, image.width - 1);
    final haut = ((zonePdf.top - marge) * echelle)
        .round()
        .clamp(0, image.height - 1);
    final bas = ((zonePdf.bottom + marge) * echelle)
        .round()
        .clamp(0, image.height - 1);

    final zoneGaucheIm = (zonePdf.left * echelle).round();
    final zoneDroiteIm = (zonePdf.right * echelle).round();
    final zoneHautIm = (zonePdf.top * echelle).round();
    final zoneBasIm = (zonePdf.bottom * echelle).round();

    var sommeR = 0, sommeG = 0, sommeB = 0, total = 0;
    for (var y = haut; y <= bas; y += 3) {
      for (var x = gauche; x <= droite; x += 3) {
        final dansZone = x >= zoneGaucheIm &&
            x <= zoneDroiteIm &&
            y >= zoneHautIm &&
            y <= zoneBasIm;
        if (dansZone) continue;
        final pixel = image.getPixel(x, y);
        final luminance =
            0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;
        if (luminance < 180) continue;
        sommeR += pixel.r.toInt();
        sommeG += pixel.g.toInt();
        sommeB += pixel.b.toInt();
        total++;
      }
    }

    if (total < 8) return couleurPage;
    return PdfColor(sommeR ~/ total, sommeG ~/ total, sommeB ~/ total);
  }

  PdfStandardFont _police(MotDetecte mot, [double? taille]) {
    return PdfStandardFont(
      PdfFontFamily.helvetica,
      taille ?? mot.zone.height * 0.75,
      style: mot.gras ? PdfFontStyle.bold : PdfFontStyle.regular,
    );
  }

  /// Rectangle réellement occupé par le texte une fois dessiné. La zone
  /// détectée par l'OCR est calée sur la police d'origine : en Helvetica le
  /// même texte est souvent plus large, et s'il déborde du rectangle passé à
  /// drawString il part à la ligne puis se fait couper — c'est ce qui faisait
  /// « bouger le cadre sans l'écriture ». On élargit donc le rectangle de
  /// dessin à la largeur réellement mesurée (et on ne réduit la police que si
  /// ça dépasserait le bord de la page).
  ({Rect rect, PdfStandardFont police}) _dessinTexte(MotDetecte mot, Rect zone) {
    var police = _police(mot);
    var mesure = police.measureString(mot.texte);
    final largeurDispo = taillePage.width - zone.left - 2;

    if (mesure.width > largeurDispo && mesure.width > 0 && largeurDispo > 0) {
      final reduite = police.size * largeurDispo / mesure.width;
      police = _police(mot, reduite < 4 ? 4 : reduite);
      mesure = police.measureString(mot.texte);
    }

    final largeur = mesure.width > zone.width ? mesure.width + 1 : zone.width;
    final hauteur = mesure.height > zone.height ? mesure.height : zone.height;
    return (
      rect: Rect.fromLTWH(
        zone.left,
        zone.center.dy - hauteur / 2,
        largeur,
        hauteur,
      ),
      police: police,
    );
  }

  /// Rectangle à repeindre pour effacer une ligne : la zone détectée (l'encre
  /// d'origine) plus, le cas échéant, le débordement du texte qu'on a
  /// nous-mêmes dessiné à cet endroit.
  Rect _rectEffacement(MotDetecte mot) {
    var rect = mot.zone;
    // Uniquement pour le texte qu'on a redessiné : celui d'origine tient dans
    // sa zone détectée, et élargir l'effacement effacerait ses voisins.
    if (mot.redessine && mot.texte.isNotEmpty) {
      rect = rect.expandToInclude(_dessinTexte(mot, mot.zone).rect);
    }
    return rect.inflate(3);
  }

  void _ecrire(PdfPage page, MotDetecte mot, Rect zone) {
    if (mot.texte.isEmpty) return;
    final dessin = _dessinTexte(mot, zone);
    page.graphics.drawString(
      mot.texte,
      dessin.police,
      bounds: dessin.rect,
      brush: PdfSolidBrush(PdfColor(0, 0, 0)),
      format: PdfStringFormat(
        alignment: PdfTextAlignment.left,
        lineAlignment: PdfVerticalAlignment.middle,
      ),
    );
    mot.redessine = true;
  }

  Future<Etat> _etatActuel(PdfDocument doc) async {
    final octetsDocument = Uint8List.fromList(await doc.save());
    final motsCopie = mots
        .map((m) => MotDetecte(m.texte, m.zone,
            gras: m.gras, redessine: m.redessine))
        .toList();
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
    if (doc == null || historique.isEmpty || _occupe) return;
    setState(() => _occupe = true);
    try {
      final etatActuel = await _etatActuel(doc);
      final precedent = historique.removeLast();
      setState(() => futur.add(etatActuel));
      await _restaurerEtat(precedent);
    } finally {
      setState(() => _occupe = false);
    }
  }

  Future<void> _retablir() async {
    final doc = document;
    if (doc == null || futur.isEmpty || _occupe) return;
    setState(() => _occupe = true);
    try {
      final etatActuel = await _etatActuel(doc);
      final suivant = futur.removeLast();
      setState(() => historique.add(etatActuel));
      await _restaurerEtat(suivant);
    } finally {
      setState(() => _occupe = false);
    }
  }

  Future<void> _modifierMot(MotDetecte mot) async {
    final controleur = TextEditingController(text: mot.texte);
    var grasChoisi = mot.gras;

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
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Annuler"),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, {"texte": "", "gras": grasChoisi}),
              child: const Text("Supprimer"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                  ctx, {"texte": controleur.text, "gras": grasChoisi}),
              child: const Text("Valider"),
            ),
          ],
        ),
      ),
    );

    if (resultat == null) return;
    final texteNettoye = (resultat["texte"] as String).trim();
    final grasFinal = resultat["gras"] as bool;
    if (texteNettoye == mot.texte && grasFinal == mot.gras) return;

    final doc = document;
    if (doc == null || _occupe) return;
    setState(() => _occupe = true);
    try {
      historique.add(await _etatActuel(doc));
      futur.clear();

      final page = doc.pages[0];
      page.graphics.drawRectangle(
        brush: PdfSolidBrush(_couleurDeFond(mot)),
        bounds: _rectEffacement(mot),
      );

      mot.gras = grasFinal;
      final ancienTexte = mot.texte;
      mot.texte = texteNettoye;
      _ecrire(page, mot, mot.zone);
      mot.texte = ancienTexte;

      setState(() {
        mot.texte = texteNettoye;
        motSelectionne = texteNettoye.isEmpty ? null : mot;
      });

      if (imageDeFond != null) {
        await _rafraichirApercuOcr(doc);
      }
    } finally {
      setState(() => _occupe = false);
    }
  }

  Future<void> _deplacerLigne(MotDetecte mot, double dx, double dy) async {
    if (dx == 0 && dy == 0) return;
    final doc = document;
    if (doc == null || _occupe) return;
    setState(() => _occupe = true);
    try {
      historique.add(await _etatActuel(doc));
      futur.clear();

      final page = doc.pages[0];
      final ancienneZone = mot.zone;

      page.graphics.drawRectangle(
        brush: PdfSolidBrush(_couleurDeFond(mot)),
        bounds: _rectEffacement(mot),
      );

      final nouvelleZone = Rect.fromLTWH(
        ancienneZone.left + dx,
        ancienneZone.top + dy,
        ancienneZone.width,
        ancienneZone.height,
      );

      _ecrire(page, mot, nouvelleZone);

      setState(() => mot.zone = nouvelleZone);

      if (imageDeFond != null) {
        await _rafraichirApercuOcr(doc);
      }
    } finally {
      setState(() => _occupe = false);
    }
  }

  /// Crée une petite zone effaçable à l'endroit d'un appui long, pour
  /// nettoyer un résidu (trait, tache) que l'OCR n'a pas détecté comme
  /// ligne de texte et qui n'est donc pas sélectionnable autrement.
  Future<void> _ajouterZoneEffacee(double xPage, double yPage) async {
    final doc = document;
    if (doc == null || _occupe) return;

    // Si l'appui long tombe sur une ligne déjà détectée, on ne crée pas de
    // zone d'effacement par-dessus (ça effacerait de la vraie écriture) :
    // l'appui long ne sert qu'à nettoyer les résidus hors de toute ligne.
    const tolerance = 4.0;
    final surLigneExistante = mots.any(
      (m) => m.zone.inflate(tolerance).contains(Offset(xPage, yPage)),
    );
    if (surLigneExistante) return;

    setState(() => _occupe = true);
    try {
      historique.add(await _etatActuel(doc));
      futur.clear();

      const largeur = 30.0;
      const hauteur = 14.0;
      final zone = Rect.fromLTWH(
        xPage - largeur / 2,
        yPage - hauteur / 2,
        largeur,
        hauteur,
      );

      final page = doc.pages[0];
      page.graphics.drawRectangle(
        brush: PdfSolidBrush(_couleurLocale(zone)),
        bounds: Rect.fromLTWH(
          zone.left - 2,
          zone.top - 2,
          zone.width + 4,
          zone.height + 4,
        ),
      );

      final nouvelleLigne = MotDetecte("", zone);
      setState(() {
        mots = [...mots, nouvelleLigne];
        motSelectionne = nouvelleLigne;
      });

      if (imageDeFond != null) {
        await _rafraichirApercuOcr(doc);
      }
    } finally {
      setState(() => _occupe = false);
    }
  }

  void _copierLigne() {
    final mot = motSelectionne;
    if (mot == null || mot.texte.isEmpty) return;
    setState(() {
      texteCopie = mot.texte;
      grasCopie = mot.gras;
      largeurCopiee = mot.zone.width;
      hauteurCopiee = mot.zone.height;
      statut = "Texte copié : touchez « Coller » puis un endroit de la page";
    });
  }

  void _activerModeCollage() {
    if (texteCopie == null) return;
    setState(() {
      enCollage = true;
      statut = "Touchez l'endroit de la page où coller le texte";
    });
  }

  /// Colle le texte copié à l'endroit touché sur la page, comme une
  /// nouvelle ligne indépendante qu'on peut ensuite déplacer/modifier.
  Future<void> _collerA(double xPage, double yPage) async {
    final doc = document;
    final texte = texteCopie;
    if (doc == null || texte == null || _occupe) return;
    setState(() => _occupe = true);
    try {
      historique.add(await _etatActuel(doc));
      futur.clear();

      final zone = Rect.fromLTWH(
        xPage - largeurCopiee / 2,
        yPage - hauteurCopiee / 2,
        largeurCopiee,
        hauteurCopiee,
      );

      final page = doc.pages[0];
      final nouvelleLigne = MotDetecte(texte, zone, gras: grasCopie);
      _ecrire(page, nouvelleLigne, zone);

      setState(() {
        mots = [...mots, nouvelleLigne];
        motSelectionne = nouvelleLigne;
        enCollage = false;
        statut = "Texte collé";
      });

      if (imageDeFond != null) {
        await _rafraichirApercuOcr(doc);
      }
    } finally {
      setState(() => _occupe = false);
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
            onPressed: (historique.isEmpty || _occupe) ? null : _annuler,
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            tooltip: "Rétablir",
            onPressed: (futur.isEmpty || _occupe) ? null : _retablir,
          ),
          IconButton(
            icon: Icon(
              Icons.content_paste,
              color: enCollage ? Theme.of(context).colorScheme.primary : null,
            ),
            tooltip: enCollage
                ? "Touchez la page pour coller"
                : "Coller le texte copié",
            onPressed: (texteCopie == null || _occupe)
                ? null
                : (enCollage
                    ? () => setState(() {
                          enCollage = false;
                          statut = "Collage annulé";
                        })
                    : _activerModeCollage),
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
        bottom: motSelectionne == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(40),
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Row(
                    children: [
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.content_copy, size: 20),
                        tooltip: "Copier cette ligne",
                        onPressed: motSelectionne!.texte.isEmpty
                            ? null
                            : _copierLigne,
                      ),
                      Expanded(
                        child: Text(
                          motSelectionne!.texte.isEmpty
                              ? "(ligne vide)"
                              : motSelectionne!.texte,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_back, size: 20),
                        tooltip: "Déplacer à gauche",
                        onPressed: _occupe
                            ? null
                            : () => _deplacerLigne(
                                motSelectionne!, -_pasDeplacement, 0),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_upward, size: 20),
                        tooltip: "Déplacer vers le haut",
                        onPressed: _occupe
                            ? null
                            : () => _deplacerLigne(
                                motSelectionne!, 0, -_pasDeplacement),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_downward, size: 20),
                        tooltip: "Déplacer vers le bas",
                        onPressed: _occupe
                            ? null
                            : () => _deplacerLigne(
                                motSelectionne!, 0, _pasDeplacement),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_forward, size: 20),
                        tooltip: "Déplacer à droite",
                        onPressed: _occupe
                            ? null
                            : () => _deplacerLigne(
                                motSelectionne!, _pasDeplacement, 0),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        tooltip: "Désélectionner",
                        onPressed: () => setState(() => motSelectionne = null),
                      ),
                    ],
                  ),
                ),
              ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              statut,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: mots.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final echelle = constraints.maxWidth / taillePage.width;
                      return ClipRect(
                        child: InteractiveViewer(
                          // Navigation façon visionneuse : pincement à deux
                          // doigts pour zoomer, doigt posé sur la page pour
                          // la faire glisser. Le déplacement d'une ligne se
                          // fait au doigt une fois la ligne sélectionnée,
                          // donc les deux gestes ne se marchent pas dessus.
                          transformationController: _transformation,
                          constrained: false,
                          boundaryMargin: const EdgeInsets.all(double.infinity),
                          minScale: 0.5,
                          maxScale: 8,
                          child: SizedBox(
                            width: constraints.maxWidth,
                            height: taillePage.height * echelle,
                            child: Stack(
                              children: [
                                SizedBox.expand(
                                  child: GestureDetector(
                                  onLongPressStart: (details) {
                                    _ajouterZoneEffacee(
                                      details.localPosition.dx / echelle,
                                      details.localPosition.dy / echelle,
                                    );
                                  },
                                  onTapUp: (details) {
                                    if (enCollage) {
                                      _collerA(
                                        details.localPosition.dx / echelle,
                                        details.localPosition.dy / echelle,
                                      );
                                    }
                                  },
                                  child: imageDeFond != null
                                      ? Image.memory(imageDeFond!, fit: BoxFit.fill)
                                      : Container(color: Colors.white),
                                ),
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
                                    onTap: () {
                                      if (motSelectionne == mot) {
                                        _modifierMot(mot);
                                      } else {
                                        setState(() => motSelectionne = mot);
                                      }
                                    },
                                    // Le glisser ne déplace la ligne que si
                                    // elle est déjà sélectionnée ; sinon le
                                    // geste passe à la page (défilement/zoom).
                                    onPanStart: motSelectionne != mot
                                        ? null
                                        : (_) => setState(() {
                                              ligneEnDeplacement = mot;
                                              deplacementEnCours = Offset.zero;
                                            }),
                                    onPanUpdate: motSelectionne != mot
                                        ? null
                                        : (details) => setState(() {
                                              deplacementEnCours +=
                                                  details.delta;
                                            }),
                                    onPanEnd: motSelectionne != mot
                                        ? null
                                        : (_) async {
                                            final dx =
                                                deplacementEnCours.dx / echelle;
                                            final dy =
                                                deplacementEnCours.dy / echelle;
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
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: mots.isEmpty
          ? null
          : FloatingActionButton.small(
              tooltip: "Recentrer / réinitialiser le zoom",
              onPressed: () => _transformation.value = Matrix4.identity(),
              child: const Icon(Icons.zoom_out_map),
            ),
    );
  }
}
