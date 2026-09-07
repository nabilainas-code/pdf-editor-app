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

  /// En mode navigation, le doigt fait glisser la page et les lignes ne
  /// réagissent plus ; en mode édition, le doigt sélectionne / modifie et le
  /// déplacement de la page se fait à deux doigts. Sans cette séparation, le
  /// glissement de page et les appuis sur les lignes se disputaient le geste
  /// et les appuis (dont « Supprimer ») passaient à la trappe.
  bool modeNavigation = false;

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

    // On retient la teinte la plus fréquente parmi les pixels clairs, et non
    // leur moyenne : autour d'une ligne dense, la moyenne est tirée vers le
    // gris par les pixels de bord de lettres et donne un aplat grisâtre.
    final compteur = <int, int>{};
    var total = 0;
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
        if (luminance < 200) continue;
        final cle = ((pixel.r.toInt() ~/ 4) << 16) |
            ((pixel.g.toInt() ~/ 4) << 8) |
            (pixel.b.toInt() ~/ 4);
        compteur[cle] = (compteur[cle] ?? 0) + 1;
        total++;
      }
    }

    if (total < 8) return couleurPage;
    var cleFrequente = compteur.keys.first;
    var maxCompte = compteur[cleFrequente]!;
    for (final entree in compteur.entries) {
      if (entree.value > maxCompte) {
        maxCompte = entree.value;
        cleFrequente = entree.key;
      }
    }
    return PdfColor(
      ((cleFrequente >> 16) & 0xFF) * 4,
      ((cleFrequente >> 8) & 0xFF) * 4,
      (cleFrequente & 0xFF) * 4,
    );
  }

  PdfStandardFont _police(MotDetecte mot, [double? taille]) {
    return PdfStandardFont(
      PdfFontFamily.helvetica,
      taille ?? mot.zone.height * 0.75,
      style: mot.gras ? PdfFontStyle.bold : PdfFontStyle.regular,
    );
  }

  /// Taille de police et rectangle de dessin pour un texte replacé dans sa
  /// zone. La hauteur du cadre détecté ne donne qu'une estimation grossière
  /// (elle inclut accents et jambages) ; la largeur, elle, mesure exactement
  /// l'encre d'origine. On ajuste donc la police pour que le texte occupe la
  /// même largeur qu'avant — c'est ce qui garde la même taille apparente au
  /// lieu de rapetisser — et on dessine dans un rectangle assez large pour
  /// qu'il ne parte pas à la ligne et ne se fasse pas couper.
  ({Rect rect, PdfStandardFont police}) _dessinTexte(MotDetecte mot, Rect zone) {
    final base = zone.height * 0.75;
    var police = _police(mot, base);
    var mesure = police.measureString(mot.texte);

    // Taille calée sur la hauteur du cadre détecté : c'est elle qui décide de
    // la taille apparente des lettres. Caler sur la largeur, comme avant,
    // rapetissait le texte dès qu'Helvetica était plus large que la police
    // d'origine.
    if (mesure.height > 0 && zone.height > 0) {
      var taille = base * zone.height / mesure.height;
      if (taille < 4) taille = 4;
      police = _police(mot, taille);
      mesure = police.measureString(mot.texte);
    }

    // Seul garde-fou restant : ne pas déborder du bord de la page.
    final largeurDispo = taillePage.width - zone.left - 2;
    if (largeurDispo > 0 && mesure.width > largeurDispo) {
      var taille = police.size * largeurDispo / mesure.width;
      if (taille < 4) taille = 4;
      police = _police(mot, taille);
      mesure = police.measureString(mot.texte);
    }

    final largeur =
        (mesure.width > zone.width ? mesure.width : zone.width) + 2;
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

  /// Rectangle occupé par le contenu d'une ligne : la zone détectée (l'encre
  /// d'origine) plus, le cas échéant, le débordement du texte qu'on a
  /// nous-mêmes dessiné à cet endroit.
  Rect _rectContenu(MotDetecte mot) {
    var rect = mot.zone;
    // Uniquement pour le texte qu'on a redessiné : celui d'origine tient dans
    // sa zone détectée, et élargir la zone empièterait sur ses voisins.
    if (mot.redessine && mot.texte.isNotEmpty) {
      rect = rect.expandToInclude(_dessinTexte(mot, mot.zone).rect);
    }
    return rect;
  }

  Rect _rectEffacement(MotDetecte mot) => _rectContenu(mot).inflate(2);

  /// Rectangle utilisé pour déplacer une ligne : il sert à la fois à la
  /// photographier et à effacer sa place, si bien que rien ne se perd en
  /// route. La marge est large horizontalement, car le cadre détecté rogne
  /// souvent la première et la dernière lettre, mais fine verticalement pour
  /// ne pas mordre sur les lignes du dessus et du dessous.
  Rect _rectDeplacement(MotDetecte mot) {
    final rect = _rectContenu(mot);
    return Rect.fromLTRB(
      rect.left - 4,
      rect.top - 1.5,
      rect.right + 4,
      rect.bottom + 1.5,
    );
  }

  /// Découpe l'aperçu de la page pour récupérer le contenu d'une zone tel
  /// qu'il est réellement imprimé. Déplacer cette image plutôt que de
  /// réécrire le texte conserve exactement la police, la graisse et la taille
  /// d'origine — impossible à reproduire en Helvetica.
  PdfBitmap? _capturerZone(Rect zone) {
    final image = imageDecodee;
    if (image == null) return null;
    final e = echelleOcr;

    final x = (zone.left * e).round().clamp(0, image.width - 1);
    final y = (zone.top * e).round().clamp(0, image.height - 1);
    final largeur = (zone.width * e).round().clamp(1, image.width - x);
    final hauteur = (zone.height * e).round().clamp(1, image.height - y);

    try {
      final morceau = img.copyCrop(image,
          x: x, y: y, width: largeur, height: hauteur);
      return PdfBitmap(img.encodePng(morceau));
    } catch (_) {
      return null;
    }
  }

  /// Deux zones sont sur la même rangée si elles se recouvrent nettement en
  /// hauteur : c'est ce qui permet à un tiret ou une puce détecté à part de
  /// suivre la ligne à laquelle il appartient.
  bool _memeRangee(Rect a, Rect b) {
    final haut = a.top > b.top ? a.top : b.top;
    final bas = a.bottom < b.bottom ? a.bottom : b.bottom;
    final chevauchement = bas - haut;
    if (chevauchement <= 0) return false;
    final hauteurMin = a.height < b.height ? a.height : b.height;
    return hauteurMin > 0 && chevauchement > hauteurMin * 0.5;
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

  /// Retire un cadre de la liste. Ce n'est qu'un repère d'affichage : rien
  /// n'est modifié dans le PDF, seul le rectangle bleu disparaît.
  void _retirerRepere(MotDetecte mot) {
    setState(() {
      mots = mots.where((m) => m != mot).toList();
      motSelectionne = null;
      statut = "Cadre retiré (le PDF n'a pas changé)";
    });
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
              onPressed: () => Navigator.pop(
                  ctx, {"texte": "", "gras": grasChoisi, "supprimer": true}),
              child: Text(mot.texte.isEmpty ? "Retirer le cadre" : "Supprimer"),
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

    // « Supprimer » sur une ligne déjà vide : il ne reste que le cadre bleu,
    // simple repère d'affichage absent du PDF. On le retire de la liste.
    if (resultat["supprimer"] == true && mot.texte.isEmpty) {
      _retirerRepere(mot);
      return;
    }

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

  /// Lignes que le déplacement bouscule : celles que la nouvelle position
  /// viendrait recouvrir, puis de proche en proche celles que celles-ci
  /// recouvriraient à leur tour. Elles suivent du même pas [dy] que la ligne
  /// déplacée : le bloc glisse en gardant ses interlignes, au lieu de faire
  /// bondir chaque voisine d'une hauteur de ligne entière à chaque appui.
  List<MotDetecte> _lignesPoussees(
    List<MotDetecte> groupe,
    double dx,
    double dy,
  ) {
    if (dy == 0) return const [];

    final concernees = <MotDetecte>{...groupe};
    final aExaminer = <Rect>[
      for (final m in groupe) m.zone.shift(Offset(dx, dy)),
    ];

    // Marge de sécurité : l'effacement et la repose débordent légèrement de
    // la zone, donc une voisine doit s'écarter avant même le contact, sinon
    // la ligne qui passe lui ronge son encre au fil des appuis — c'est ce
    // qui vidait des lignes que personne n'avait supprimées.
    const marge = 3.0;

    while (aExaminer.isNotEmpty) {
      final reference = aExaminer.removeLast().inflate(marge);
      for (final autre in mots) {
        if (concernees.contains(autre) || autre.texte.isEmpty) continue;
        if (!reference.overlaps(autre.zone)) continue;
        concernees.add(autre);
        aExaminer.add(autre.zone.translate(0, dy));
      }
    }

    return concernees.where((m) => !groupe.contains(m)).toList();
  }

  Future<void> _deplacerLigne(MotDetecte mot, double dx, double dy) async {
    if (dx == 0 && dy == 0) return;
    final doc = document;
    if (doc == null || _occupe) return;
    // La ligne emmène avec elle ce qui est sur sa rangée : un tiret ou une
    // puce détectés à part restaient sinon en arrière.
    final groupe = <MotDetecte>[
      mot,
      ...mots.where((m) => m != mot && _memeRangee(m.zone, mot.zone)),
    ];

    final deplacements = <MotDetecte, Offset>{
      for (final m in groupe) m: Offset(dx, dy),
      for (final m in _lignesPoussees(groupe, dx, dy)) m: Offset(0, dy),
    };

    // Rien ne doit finir hors de la page : c'est ce qui faisait disparaître
    // des lignes bousculées vers le bas.
    final sortDeLaPage = deplacements.entries.any((e) {
      final r = _rectDeplacement(e.key).shift(e.value);
      return r.left < 0 ||
          r.top < 0 ||
          r.right > taillePage.width ||
          r.bottom > taillePage.height;
    });
    if (sortDeLaPage) {
      setState(() => statut = "Déplacement refusé : ça sortirait de la page");
      return;
    }

    setState(() => _occupe = true);
    try {
      historique.add(await _etatActuel(doc));
      futur.clear();

      final page = doc.pages[0];

      // On photographie chaque contenu avant de toucher à la page : déplacer
      // l'image imprimée conserve la police et la graisse d'origine, qu'on ne
      // saurait pas reproduire en Helvetica. Une zone vide (gomme, ligne
      // supprimée) n'a rien à déplacer ni à effacer. Photographie, effacement
      // et repose portent sur le même rectangle : effacer plus large que ce
      // qu'on emporte amputait la première et la dernière lettre.
      final captures = <MotDetecte, PdfBitmap?>{};
      for (final m in deplacements.keys) {
        captures[m] =
            m.texte.isEmpty ? null : _capturerZone(_rectDeplacement(m));
      }

      for (final m in deplacements.keys) {
        if (m.texte.isEmpty) continue;
        page.graphics.drawRectangle(
          brush: PdfSolidBrush(_couleurDeFond(m)),
          bounds: _rectDeplacement(m),
        );
      }

      for (final entree in deplacements.entries) {
        final m = entree.key;
        if (m.texte.isEmpty) continue;
        final capture = captures[m];
        if (capture != null) {
          page.graphics.drawImage(
            capture,
            _rectDeplacement(m).shift(entree.value),
          );
        } else {
          _ecrire(page, m, m.zone.shift(entree.value));
        }
      }

      setState(() {
        for (final entree in deplacements.entries) {
          entree.key.zone = entree.key.zone.shift(entree.value);
        }
      });

      if (imageDeFond != null) {
        await _rafraichirApercuOcr(doc);
      }
    } finally {
      setState(() => _occupe = false);
    }
  }

  /// Pose un repère à l'endroit d'un appui long, pour attraper un résidu
  /// (trait, tache) que l'OCR n'a pas détecté comme ligne. Il n'efface rien
  /// tout seul : on le place d'abord (flèches / glisser), et c'est le bouton
  /// gomme qui efface, quand on le décide.
  void _ajouterZoneEffacee(double xPage, double yPage) {
    if (document == null || _occupe) return;

    // Si l'appui long tombe sur une ligne déjà détectée, inutile d'empiler un
    // repère par-dessus : cette ligne est déjà sélectionnable telle quelle.
    const tolerance = 4.0;
    final surLigneExistante = mots.any(
      (m) => m.zone.inflate(tolerance).contains(Offset(xPage, yPage)),
    );
    if (surLigneExistante) return;

    const largeur = 30.0;
    const hauteur = 14.0;
    final nouvelleLigne = MotDetecte(
      "",
      Rect.fromLTWH(
        xPage - largeur / 2,
        yPage - hauteur / 2,
        largeur,
        hauteur,
      ),
    );

    setState(() {
      mots = [...mots, nouvelleLigne];
      motSelectionne = nouvelleLigne;
      statut = "Repère posé : placez-le puis touchez la gomme pour effacer";
    });
  }

  /// Repeint le fond sur la zone sélectionnée : sert de gomme, qu'on peut
  /// donc positionner d'abord (flèches / glisser) puis appliquer.
  Future<void> _effacerZone(MotDetecte mot) async {
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

      setState(() {
        mot.texte = "";
        mot.redessine = false;
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
                      IconButton(
                        icon: const Icon(Icons.cleaning_services, size: 20),
                        tooltip: "Effacer ici (gomme)",
                        onPressed: _occupe
                            ? null
                            : () => _effacerZone(motSelectionne!),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        tooltip: "Retirer ce cadre (n'efface rien dans le PDF)",
                        onPressed: motSelectionne!.texte.isNotEmpty
                            ? null
                            : () => _retirerRepere(motSelectionne!),
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
                          panEnabled: modeNavigation,
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
                                    onLongPressStart: modeNavigation
                                        ? null
                                        : (details) {
                                            _ajouterZoneEffacee(
                                              details.localPosition.dx / echelle,
                                              details.localPosition.dy / echelle,
                                            );
                                          },
                                    onTapUp: modeNavigation
                                        ? null
                                        : (details) {
                                            if (enCollage) {
                                              _collerA(
                                                details.localPosition.dx /
                                                    echelle,
                                                details.localPosition.dy /
                                                    echelle,
                                              );
                                            }
                                          },
                                    child: imageDeFond != null
                                        ? Image.memory(imageDeFond!,
                                            fit: BoxFit.fill)
                                        : Container(color: Colors.white),
                                  ),
                                ),
                              // Pendant un collage, les cadres laissent
                              // passer l'appui : sinon coller sur une zone
                              // occupée par une ligne sélectionnait cette
                              // ligne au lieu de déposer le texte.
                              if (!modeNavigation && !enCollage)
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
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: "mode",
                  tooltip: modeNavigation
                      ? "Mode navigation : doigt = déplacer la page"
                      : "Mode édition : doigt = sélectionner une ligne",
                  backgroundColor: modeNavigation
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  foregroundColor: modeNavigation
                      ? Theme.of(context).colorScheme.onPrimary
                      : null,
                  onPressed: () => setState(() {
                    modeNavigation = !modeNavigation;
                    statut = modeNavigation
                        ? "Mode navigation : faites glisser la page"
                        : "Mode édition : touchez une ligne";
                  }),
                  child: Icon(
                      modeNavigation ? Icons.pan_tool : Icons.touch_app),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: "recentrer",
                  tooltip: "Recentrer / réinitialiser le zoom",
                  onPressed: () => _transformation.value = Matrix4.identity(),
                  child: const Icon(Icons.zoom_out_map),
                ),
              ],
            ),
    );
  }
}
