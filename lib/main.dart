import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
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

  /// Taille de police choisie à la main, en points. Reste null tant que
  /// l'utilisateur n'a pas touché au réglage : la taille est alors estimée
  /// automatiquement — une estimation qui ne peut qu'approcher la police
  /// d'origine (inconnue), d'où ce réglage pour compenser à l'œil.
  double? tailleManuelle;

  /// Vrai pour une zone de texte libre créée avec l'outil « + » : sa largeur
  /// reste fixe (elle ne s'ajuste pas au contenu comme une ligne OCR) et son
  /// alignement peut être choisi. Faux pour une ligne issue de la détection,
  /// dont le comportement reste celui d'origine.
  bool boiteLibre;
  PdfTextAlignment alignement;

  /// Italique. Comme le gras, il vient des informations du PDF quand le
  /// document a du vrai texte ; sur un scan il reste faux, faute de pouvoir
  /// le deviner de façon fiable sur des pixels.
  bool italique;

  /// Famille de police approchée, déduite du nom de police du PDF : sans
  /// elle, une ligne d'un document en Times revenait en Helvetica dès la
  /// première modification, et la ligne modifiée se voyait au premier coup
  /// d'œil.
  PdfFontFamily famille;

  /// Couleur de l'encre relevée sur la page. Le texte était jusqu'ici
  /// toujours redessiné en noir : un titre orange ou un texte blanc sur
  /// bandeau sombre changeait donc de couleur dès qu'on y touchait.
  PdfColor? couleurTexte;

  /// Taille de police calibrée une fois pour toutes à la détection, de façon
  /// que le texte redessiné occupe la même largeur que le texte d'origine.
  /// La hauteur d'un cadre OCR est un mauvais repère (elle inclut marge,
  /// accents et jambages, d'où un texte redessiné nettement plus gros que
  /// l'original) ; sa largeur, elle, correspond exactement à l'étendue du
  /// texte.
  double? tailleAuto;

  /// Traits d'une signature posée (coordonnées normalisées, comme dans le
  /// répertoire) et son rapport hauteur/largeur. Les garder permet de la
  /// redessiner à une autre taille : l'encre déjà posée dans la page est du
  /// tracé vectoriel, impossible à agrandir ou réduire sans la refaire.
  List<List<Offset>>? traitsSignature;
  double ratioSignature;

  /// Zone de la page que l'application a repeinte (effacée puis redessinée)
  /// dans le PDF. L'image d'aperçu n'étant plus rafraîchie après chaque
  /// modification, elle y montre encore les pixels d'avant : l'écran doit
  /// donc recouvrir cette zone. C'est ce qui manquait à une ligne dont on
  /// supprime le texte — sans texte à afficher, plus rien ne masquait
  /// l'ancien, qui semblait « revenir ».
  Rect? zoneMasque;

  /// Couleur de fond à peindre derrière le texte affiché à l'écran quand la
  /// ligne a été redessinée (voir [redessine]) : rafraîchir tout l'aperçu de
  /// la page à chaque modification (un rendu complet de la page scannée,
  /// coûteux) n'est alors plus nécessaire — la ligne s'affiche directement en
  /// texte natif, sur ce fond, par-dessus les pixels d'origine désormais
  /// obsolètes.
  Color? fondEcran;

  MotDetecte(this.texte, this.zone,
      {this.gras = false,
      this.redessine = false,
      this.tailleManuelle,
      this.boiteLibre = false,
      this.alignement = PdfTextAlignment.left,
      this.italique = false,
      this.famille = PdfFontFamily.helvetica,
      this.couleurTexte,
      this.tailleAuto,
      this.fondEcran,
      this.zoneMasque,
      this.traitsSignature,
      this.ratioSignature = 0.4});
}

class Etat {
  final Uint8List octetsDocument;
  final List<MotDetecte> mots;
  final Uint8List? image;
  Etat(this.octetsDocument, this.mots, this.image);
}

/// Un champ de formulaire du PDF (AcroForm). Il est repéré par sa position
/// dans la liste des champs du document et non par l'objet Syncfusion
/// lui-même : celui-ci ne survit pas à un annuler/rétablir, qui recharge le
/// document entier, alors que l'ordre des champs, lui, ne change pas.
class ChampFormulaire {
  final int index;
  final String nom;
  final Rect zone;
  final bool estCase;
  String valeur;
  bool coche;

  ChampFormulaire(
    this.index,
    this.nom,
    this.zone, {
    this.estCase = false,
    this.valeur = '',
    this.coche = false,
  });
}

/// Cadre d'une ligne détectée. Tant qu'elle n'est pas choisie, de simples
/// pointillés gris : comme dans les éditeurs PDF courants, les cadres
/// signalent ce qui est modifiable sans concurrencer le document. Une fois
/// choisie, trait plein et fond légèrement teinté — bleu pour une ligne
/// seule, rouge quand plusieurs lignes forment un groupe à déplacer.
class _CadreLigne extends CustomPainter {
  final bool selectionne;
  final bool groupe;
  const _CadreLigne({required this.selectionne, required this.groupe});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (selectionne) {
      final couleur = groupe ? Colors.red : Colors.blue;
      canvas.drawRect(rect, Paint()..color = couleur.withOpacity(0.10));
      canvas.drawRect(
        rect,
        Paint()
          ..color = couleur
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      return;
    }

    final pinceau = Paint()
      ..color = Colors.blueGrey.withOpacity(0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const tiret = 4.0;
    const trou = 3.0;
    for (var x = 0.0; x < size.width; x += tiret + trou) {
      final fin = (x + tiret) > size.width ? size.width : x + tiret;
      canvas.drawLine(Offset(x, 0), Offset(fin, 0), pinceau);
      canvas.drawLine(
          Offset(x, size.height), Offset(fin, size.height), pinceau);
    }
    for (var y = 0.0; y < size.height; y += tiret + trou) {
      final fin = (y + tiret) > size.height ? size.height : y + tiret;
      canvas.drawLine(Offset(0, y), Offset(0, fin), pinceau);
      canvas.drawLine(
          Offset(size.width, y), Offset(size.width, fin), pinceau);
    }
  }

  @override
  bool shouldRepaint(_CadreLigne ancien) =>
      ancien.selectionne != selectionne || ancien.groupe != groupe;
}

/// Une signature enregistrée dans le répertoire : ses traits normalisés
/// (mêmes coordonnées 0..1 que [signatureNormalisee]) et son nom, pour
/// pouvoir la reposer plusieurs fois sans la retracer à chaque fois.
class _SignatureEnregistree {
  String nom;
  final List<List<Offset>> traits;
  final double ratio;
  _SignatureEnregistree(this.nom, this.traits, this.ratio);
}

/// Dessine la signature en cours de tracé dans la boîte de signature.
/// Masque les poignées et la bulle « Copier/Coller » natives d'Android sur
/// le champ d'écriture directe. Ces poignées se dessinent dans la couche
/// d'overlay globale de l'application, indépendamment du zoom/déplacement de
/// la page : positionnées pour une page à l'échelle 1, elles atterrissaient
/// n'importe où sur l'écran dès que la page était zoomée ou déplacée — vues
/// comme une goutte flottante sur une autre ligne. Le bouton « tout
/// sélectionner » de la barre du haut reste le moyen fiable de sélectionner.
class _AucunePoignee extends TextSelectionControls {
  @override
  Widget buildHandle(BuildContext context, TextSelectionHandleType type,
          double textLineHeight,
          [VoidCallback? onTap]) =>
      const SizedBox.shrink();

  @override
  Widget buildToolbar(
          BuildContext context,
          Rect globalEditableRegion,
          double textLineHeight,
          Offset selectionMidpoint,
          List<TextSelectionPoint> endpoints,
          TextSelectionDelegate delegate,
          ValueListenable<ClipboardStatus>? clipboardStatus,
          Offset? lastSecondaryTapDownPosition) =>
      const SizedBox.shrink();

  @override
  Size getHandleSize(double textLineHeight) => Size.zero;

  @override
  Offset getHandleAnchor(TextSelectionHandleType type, double textLineHeight) =>
      Offset.zero;
}

class _PeintreSignature extends CustomPainter {
  final List<List<Offset>> traits;
  _PeintreSignature(this.traits);

  @override
  void paint(Canvas canvas, Size size) {
    final pinceau = Paint()
      ..color = Colors.black
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final trait in traits) {
      if (trait.length == 1) {
        canvas.drawLine(trait.first, trait.first.translate(0.1, 0), pinceau);
        continue;
      }
      for (var i = 0; i + 1 < trait.length; i++) {
        canvas.drawLine(trait[i], trait[i + 1], pinceau);
      }
    }
  }

  @override
  bool shouldRepaint(_PeintreSignature ancien) => true;
}

class Accueil extends StatefulWidget {
  const Accueil({super.key});

  @override
  State<Accueil> createState() => _AccueilState();
}

class _AccueilState extends State<Accueil> {
  PdfDocument? document;

  /// Octets bruts du document ouvert, conservés même en lecture seule (où
  /// aucune analyse n'a encore eu lieu) pour pouvoir lancer l'analyse
  /// (extraction de texte / OCR) seulement quand l'utilisateur choisit
  /// explicitement de modifier.
  Uint8List? octetsDocument;

  /// Image de la page affichée en lecture seule, avant toute analyse.
  Uint8List? apercuLecture;

  /// Au premier affichage (ouverture depuis un autre appli, import, ou
  /// lancement direct), l'application montre d'abord une simple lecture du
  /// PDF, sans détection de lignes ni OCR : l'analyse — potentiellement
  /// longue sur une page scannée — ne démarre que si l'utilisateur choisit
  /// explicitement de modifier le document.
  bool modeLecture = true;

  List<MotDetecte> mots = [];
  Size taillePage = const Size(595, 842);
  String statut = "Chargement...";
  /// Sélection courante : un tap ajoute/retire une ligne du groupe (rouge),
  /// les flèches ou le glisser déplacent tout le groupe ensemble. Un seul
  /// élément sélectionné reste le cas normal ; en avoir plusieurs permet de
  /// déplacer plusieurs lignes à la fois sans les reprendre une par une.
  final Set<MotDetecte> selection = {};
  bool enregistrementEnCours = false;

  Uint8List? imageDeFond;
  img.Image? imageDecodee;
  double echelleOcr = 1;
  PdfColor couleurPage = PdfColor(255, 255, 255);

  final List<Etat> historique = [];
  final List<Etat> futur = [];

  String? texteCopie;
  bool grasCopie = false;
  bool italiqueCopie = false;
  double? tailleAutoCopiee;
  PdfFontFamily familleCopiee = PdfFontFamily.helvetica;
  PdfColor? couleurCopiee;
  double largeurCopiee = 100;
  double hauteurCopiee = 14;
  double? tailleCopiee;

  /// Pixels réels de la ligne copiée (page scannée uniquement) : coller pose
  /// cette image telle quelle plutôt que de réécrire le texte en Helvetica,
  /// pour garder exactement la même police que « Monsieur » a partout
  /// ailleurs sur la page.
  Uint8List? imageCopiee;

  bool enCollage = false;

  /// Prochain appui sur la page = poser une nouvelle zone de texte libre à
  /// cet endroit et ouvrir directement sa modification, plutôt que le geste
  /// à deux temps (appui long puis toucher) qui n'était pas évident.
  bool enAjoutTexte = false;

  Offset deplacementGroupeEnCours = Offset.zero;
  bool groupeEnDeplacement = false;

  /// Redimensionnement en cours par une poignée de coin : le rectangle suivi
  /// du doigt, appliqué seulement au relâchement.
  MotDetecte? motRedimensionne;
  Rect? rectRedimension;

  /// Ligne en cours d'écriture directement sur la page : le texte se tape
  /// dans un champ posé exactement sur la ligne, à sa place et à sa taille,
  /// au lieu de passer par la boîte « Modifier la ligne » qui masque la page.
  MotDetecte? motEnEditionDirecte;
  final TextEditingController controleurDirect = TextEditingController();
  final FocusNode focusDirect = FocusNode();
  bool grasDirect = false;
  double? tailleDirecte;

  /// Champs de formulaire du PDF (AcroForm) et champ en cours de saisie.
  List<ChampFormulaire> champsFormulaire = [];
  ChampFormulaire? champEnEdition;
  bool modeRemplissage = false;

  /// Signature tracée au doigt, en coordonnées normalisées par sa largeur
  /// (x de 0 à 1, y de 0 à [signatureRatio]) : elle est reposée à l'échelle
  /// voulue à l'endroit touché, en traits vectoriels (donc nets à tout zoom,
  /// et sans rectangle blanc autour comme le serait une image).
  List<List<Offset>>? signatureNormalisee;
  double signatureRatio = 0.4;
  bool enPoseSignature = false;

  /// Répertoire des signatures tracées, pour les reposer sans les retracer.
  /// Gardé pour la session en cours ; retracer après avoir fermé et rouvert
  /// l'application reste nécessaire pour l'instant.
  final List<_SignatureEnregistree> signaturesEnregistrees = [];

  static const double _pasDeplacement = 3.0;

  /// Résolution de rastérisation de la page scannée. Les zones déplacées ou
  /// collées sont des images découpées dans cette rastérisation : à 200dpi
  /// elles étaient nettement moins nettes que le reste du scan (souvent
  /// numérisé à 300dpi ou plus), ce qui rendait la zone modifiée visible au
  /// zoom — flou, traits plus épais qu'autour.
  static const double _dpiOcr = 300.0;

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
    controleurDirect.dispose();
    focusDirect.dispose();
    document?.dispose();
    super.dispose();
  }

  /// Ouvre l'écriture directement sur la ligne, dans la page.
  void _ecrireSurLaLigne(MotDetecte mot) {
    setState(() {
      // Écrire et poser un repère à effacer sont deux gestes contraires :
      // se retrouver dans les deux à la fois (barre d'écriture affichée et
      // message « repère posé ») ne pouvait qu'embrouiller.
      enAjoutTexte = false;
      enCollage = false;
      enPoseSignature = false;
      motEnEditionDirecte = mot;
      controleurDirect.text = mot.texte;
      controleurDirect.selection =
          TextSelection.collapsed(offset: mot.texte.length);
      grasDirect = mot.gras;
      tailleDirecte = mot.tailleManuelle;
      statut = "Écrivez directement sur la ligne, puis validez";
    });
    // La vue reste exactement où vous l'avez laissée : la faire sauter
    // automatiquement déplaçait la ligne hors de son cadre à l'écran,
    // obligeant à la retrouver en glissant la page. Si le clavier couvre la
    // ligne, un geste de pincement/glisser (comme pour naviguer la page)
    // la ramène en vue.
    focusDirect.requestFocus();
  }

  void _annulerEditionDirecte() {
    focusDirect.unfocus();
    setState(() {
      motEnEditionDirecte = null;
      statut = "Modification annulée";
    });
  }

  Future<void> _validerEditionDirecte() async {
    final mot = motEnEditionDirecte;
    if (mot == null) return;
    final texte = controleurDirect.text;
    final gras = grasDirect;
    final taille = tailleDirecte;
    focusDirect.unfocus();
    setState(() => motEnEditionDirecte = null);
    await _appliquerModification(mot, texte: texte, gras: gras, taille: taille);
    _nettoyerBoitesLibresVides();
  }

  /// Supprime la ligne en cours d'écriture, au clavier : plus besoin de
  /// rectangle ni de passer par une boîte de réglages séparée. Un cadre déjà
  /// vide (simple repère) disparaît entièrement ; une ligne avec du texte
  /// voit son encre effacée du PDF, en gardant son cadre (pour pouvoir y
  /// réécrire ensuite), exactement comme le bouton « Supprimer » de la
  /// boîte de réglages.
  Future<void> _supprimerEditionDirecte() async {
    final mot = motEnEditionDirecte;
    if (mot == null || _occupe) return;
    focusDirect.unfocus();
    setState(() => motEnEditionDirecte = null);
    if (mot.texte.isEmpty) {
      _retirerRepere(mot);
      return;
    }
    await _appliquerModification(mot,
        texte: '', gras: mot.gras, taille: mot.tailleManuelle);
    _nettoyerBoitesLibresVides();
  }

  /// Retire les zones de texte libres restées vides : une boîte ouverte puis
  /// abandonnée ne laisse plus un cadre fantôme derrière elle. Les repères
  /// de gomme, eux, sont vides par nature et posés exprès : on n'y touche
  /// pas (c'est le bouton « tout nettoyer » qui s'en charge).
  void _nettoyerBoitesLibresVides() {
    final aRetirer =
        mots.where((m) => m.boiteLibre && m.texte.isEmpty).toList();
    if (aRetirer.isEmpty) return;
    setState(() {
      mots = mots.where((m) => !aRetirer.contains(m)).toList();
      selection.removeAll(aRetirer);
    });
  }

  /// Entrée : on valide la ligne et on en ouvre une nouvelle juste dessous,
  /// comme dans un traitement de texte. Un PDF n'a pas de flux de texte —
  /// rien ne « recoule » tout seul —, alors ce qui se trouve à la place de
  /// la nouvelle ligne est écarté vers le bas, en gardant les interlignes.
  Future<void> _ligneSuivante() async {
    final mot = motEnEditionDirecte;
    if (mot == null || _occupe) return;

    await _validerEditionDirecte();
    if (!mounted) return;

    final hauteur = mot.zone.height <= 0 ? 14.0 : mot.zone.height;
    final interligne = hauteur * 1.35;
    final zone = Rect.fromLTWH(
      mot.zone.left,
      mot.zone.top + interligne,
      mot.zone.width <= 0 ? 200.0 : mot.zone.width,
      hauteur,
    );
    if (zone.bottom > taillePage.height) {
      setState(() => statut = "Pas de place en bas de page pour une ligne de plus");
      return;
    }

    // Ce que la nouvelle ligne viendrait recouvrir s'écarte d'abord, de
    // proche en proche (la mécanique éprouvée du déplacement, avec son
    // annulation complète en cas d'échec).
    final genees = mots
        .where((m) =>
            m != mot && m.texte.isNotEmpty && m.zone.overlaps(zone.inflate(2)))
        .toList();
    if (genees.isNotEmpty) {
      await _deplacerGroupe(genees, 0, interligne);
      if (!mounted) return;
    }

    final nouvelleLigne = MotDetecte("", zone,
        gras: mot.gras,
        tailleManuelle: mot.tailleManuelle,
        boiteLibre: true,
        italique: mot.italique,
        famille: mot.famille,
        couleurTexte: mot.couleurTexte,
        tailleAuto: mot.tailleAuto);
    setState(() {
      mots = [...mots, nouvelleLigne];
      selection
        ..clear()
        ..add(nouvelleLigne);
    });
    _ecrireSurLaLigne(nouvelleLigne);
  }

  /// Taille de police actuellement utilisée pour l'écriture directe (celle
  /// choisie à la main, sinon celle estimée automatiquement).
  double _tailleEditionDirecte(MotDetecte mot) =>
      tailleDirecte ?? _dessinTexte(mot, mot.zone).police.size;

  /// Champs remplissables du PDF. Seuls les champs texte et les cases à
  /// cocher sont proposés : ce sont ceux d'un formulaire administratif
  /// courant, et les seuls qu'on sache remplir sans ambiguïté.
  List<ChampFormulaire> _lireChampsFormulaire(PdfDocument doc) {
    final champs = <ChampFormulaire>[];
    try {
      final liste = doc.form.fields;
      for (var i = 0; i < liste.count; i++) {
        final champ = liste[i];
        final nom = champ.name ?? "Champ ${i + 1}";
        if (champ is PdfTextBoxField) {
          champs.add(ChampFormulaire(i, nom, champ.bounds, valeur: champ.text));
        } else if (champ is PdfCheckBoxField) {
          champs.add(ChampFormulaire(i, nom, champ.bounds,
              estCase: true, coche: champ.isChecked));
        }
      }
    } catch (_) {
      // Document sans formulaire, ou formulaire illisible : on n'en propose
      // simplement aucun plutôt que d'empêcher l'ouverture du document.
    }
    return champs;
  }

  /// Rastérise la page pour l'afficher telle qu'elle sera imprimée. Un PDF
  /// texte s'affichait jusque-là comme une page blanche avec des cadres :
  /// ce qu'on écrit dans un champ de formulaire y serait invisible.
  Future<void> _activerApercuImage(PdfDocument doc) async {
    const dpi = _dpiOcr;
    final octetsDoc = Uint8List.fromList(await doc.save());
    PdfRaster? raster;
    await for (final r in Printing.raster(octetsDoc, pages: const [0], dpi: dpi)) {
      raster = r;
      break;
    }
    if (raster == null) return;
    final png = await raster.toPng();
    final decodee = img.decodePng(png);
    if (!mounted) return;
    setState(() {
      imageDeFond = png;
      imageDecodee = decodee;
      echelleOcr = dpi / 72.0;
      if (decodee != null) couleurPage = _calculerCouleurPage(decodee);
    });
  }

  Future<void> _basculerRemplissage() async {
    if (modeRemplissage) {
      setState(() {
        modeRemplissage = false;
        champEnEdition = null;
        statut = "Remplissage terminé";
      });
      return;
    }
    final doc = document;
    if (doc == null || _occupe) return;
    setState(() => _occupe = true);
    try {
      if (imageDeFond == null) await _activerApercuImage(doc);
      final champs = _lireChampsFormulaire(doc);
      setState(() {
        champsFormulaire = champs;
        modeRemplissage = champs.isNotEmpty;
        selection.clear();
        statut = champs.isEmpty
            ? "Ce PDF n'a pas de champs de formulaire : utilisez « + » pour écrire où vous voulez"
            : "${champs.length} champ(s) à remplir : touchez-en un";
      });
    } catch (e) {
      setState(() => statut = "Lecture du formulaire impossible : $e");
    } finally {
      setState(() => _occupe = false);
    }
  }

  /// Écrit la valeur saisie dans le champ du PDF, avec le même filet de
  /// sécurité que les autres modifications : en cas d'échec, le document
  /// revient exactement à son état d'avant.
  Future<void> _appliquerChamp(ChampFormulaire champ,
      {String? texte, bool? coche}) async {
    final doc = document;
    if (doc == null || _occupe) return;
    setState(() => _occupe = true);
    final avant = await _etatActuel(doc);
    try {
      historique.add(avant);
      futur.clear();

      final field = doc.form.fields[champ.index];
      if (field is PdfTextBoxField && texte != null) {
        field.text = texte;
      } else if (field is PdfCheckBoxField && coche != null) {
        field.isChecked = coche;
      }
      // Sans ça, la valeur saisie n'est visible que dans les lecteurs qui
      // regénèrent eux-mêmes l'apparence des champs.
      doc.form.setDefaultAppearance(false);

      setState(() {
        if (texte != null) champ.valeur = texte;
        if (coche != null) champ.coche = coche;
        champEnEdition = null;
        statut = "Champ « ${champ.nom} » rempli";
      });
      await _rafraichirApercuOcr(doc);
    } catch (e) {
      historique.removeLast();
      await _restaurerEtat(avant);
      setState(() => statut = "Remplissage annulé (rien n'a été perdu) : $e");
    } finally {
      setState(() => _occupe = false);
    }
  }

  /// Recueille une signature tracée au doigt, puis attend qu'on touche la
  /// page pour la poser à cet endroit.
  Future<void> _dessinerSignature() async {
    final traits = <List<Offset>>[];

    final valide = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text("Signature"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Signez avec le doigt dans le cadre, puis choisissez où la poser.",
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (ctx, contraintes) {
                  final largeur = contraintes.maxWidth;
                  return Container(
                    width: largeur,
                    height: 160,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: Colors.grey),
                    ),
                    child: GestureDetector(
                      onPanStart: (d) =>
                          setDialogState(() => traits.add([d.localPosition])),
                      onPanUpdate: (d) => setDialogState(() {
                        if (traits.isNotEmpty) traits.last.add(d.localPosition);
                      }),
                      child: CustomPaint(
                        painter: _PeintreSignature(traits),
                        size: Size(largeur, 160),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Annuler"),
            ),
            TextButton(
              onPressed: () => setDialogState(() => traits.clear()),
              child: const Text("Effacer"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("Placer"),
            ),
          ],
        ),
      ),
    );

    if (valide != true || traits.isEmpty) return;

    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    for (final trait in traits) {
      for (final p in trait) {
        if (p.dx < minX) minX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy > maxY) maxY = p.dy;
      }
    }
    final largeurTrace = maxX - minX;
    final hauteurTrace = maxY - minY;
    if (largeurTrace < 1 && hauteurTrace < 1) return;
    final base = largeurTrace < 1 ? 1.0 : largeurTrace;

    final normalises = [
      for (final trait in traits)
        [for (final p in trait) Offset((p.dx - minX) / base, (p.dy - minY) / base)]
    ];
    final ratio = hauteurTrace <= 0 ? 0.1 : hauteurTrace / base;

    setState(() {
      signaturesEnregistrees.add(_SignatureEnregistree(
        "Signature ${signaturesEnregistrees.length + 1}",
        normalises,
        ratio,
      ));
      _preparerPoseSignature(normalises, ratio);
    });
  }

  /// Arme la pose : la prochaine touche sur la page pose ces traits-là.
  void _preparerPoseSignature(List<List<Offset>> traits, double ratio) {
    signatureNormalisee = traits;
    signatureRatio = ratio;
    enPoseSignature = true;
    enCollage = false;
    enAjoutTexte = false;
    statut = "Touchez la page à l'endroit où poser la signature";
  }

  /// Répertoire des signatures : en choisir une à poser, en tracer une
  /// nouvelle, ou en supprimer une du répertoire (celles déjà posées dans le
  /// document ne sont pas touchées — pour les retirer, on les sélectionne
  /// sur la page comme n'importe quel cadre, puis « Effacer »).
  Future<void> _choisirSignature() async {
    if (signaturesEnregistrees.isEmpty) {
      await _dessinerSignature();
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text("Mes signatures",
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
              for (final sig in List.of(signaturesEnregistrees))
                ListTile(
                  leading: Container(
                    width: 64,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: CustomPaint(
                      painter: _PeintreSignature([
                        for (final trait in sig.traits)
                          [for (final p in trait) Offset(p.dx * 64, p.dy * 64)]
                      ]),
                    ),
                  ),
                  title: Text(sig.nom),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() =>
                        _preparerPoseSignature(sig.traits, sig.ratio));
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: "Retirer du répertoire",
                    onPressed: () {
                      setSheetState(
                          () => signaturesEnregistrees.remove(sig));
                      setState(() {});
                    },
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text("Nouvelle signature"),
                onTap: () {
                  Navigator.pop(ctx);
                  _dessinerSignature();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// Dessine les traits d'une signature dans le rectangle donné. Les
  /// coordonnées des traits sont normalisées par leur largeur, l'épaisseur du
  /// stylo suit donc la taille pour rester proportionnée.
  void _tracerSignature(PdfPage page, List<List<Offset>> traits, Rect zone) {
    final stylo = PdfPen(PdfColor(0, 0, 0), width: zone.width * 0.006);
    for (final trait in traits) {
      for (var i = 0; i + 1 < trait.length; i++) {
        page.graphics.drawLine(
          stylo,
          Offset(zone.left + trait[i].dx * zone.width,
              zone.top + trait[i].dy * zone.width),
          Offset(zone.left + trait[i + 1].dx * zone.width,
              zone.top + trait[i + 1].dy * zone.width),
        );
      }
    }
  }

  /// Redessine une signature posée à une autre taille : son encre est du
  /// tracé vectoriel déjà dans la page, on efface donc sa place et on la
  /// refait à partir de ses traits, gardés avec elle.
  /// Redimensionne une zone à un rectangle donné (poignées des coins, ou
  /// boutons du menu). Trois cas :
  ///  - une signature : son encre est du tracé vectoriel déjà écrit dans la
  ///    page, on efface sa place et on la refait à la nouvelle taille, en
  ///    gardant ses proportions ;
  ///  - une ligne de texte : on l'efface et on la redessine, la taille de
  ///    police suivant l'agrandissement ;
  ///  - un simple repère (vide) : rien n'est écrit dans la page, seul son
  ///    cadre change.
  Future<void> _redimensionnerZone(MotDetecte mot, Rect demande) async {
    final doc = document;
    if (doc == null || _occupe) return;

    // Bornes : jamais plus petit qu'une vignette, jamais hors de la page.
    const mini = 12.0;
    var gauche = demande.left < 0 ? 0.0 : demande.left;
    var haut = demande.top < 0 ? 0.0 : demande.top;
    var largeur = demande.width < mini ? mini : demande.width;
    var hauteur = demande.height < mini ? mini : demande.height;
    final traits = mot.traitsSignature;
    if (traits != null) {
      // Une signature garde ses proportions : la largeur commande.
      hauteur = largeur * mot.ratioSignature;
    }
    if (gauche + largeur > taillePage.width) {
      largeur = taillePage.width - gauche;
    }
    if (haut + hauteur > taillePage.height) {
      hauteur = taillePage.height - haut;
    }
    if (largeur < mini || hauteur < mini) return;

    final nouvelle = Rect.fromLTWH(gauche, haut, largeur, hauteur);
    if ((nouvelle.width - mot.zone.width).abs() < 0.5 &&
        (nouvelle.height - mot.zone.height).abs() < 0.5 &&
        (nouvelle.left - mot.zone.left).abs() < 0.5 &&
        (nouvelle.top - mot.zone.top).abs() < 0.5) {
      return;
    }

    // Un repère vide n'a rien dans la page : son cadre seul change.
    if (traits == null && mot.texte.isEmpty) {
      setState(() {
        mot.zone = nouvelle;
        statut = "Cadre redimensionné";
      });
      return;
    }

    setState(() => _occupe = true);
    final avant = await _etatActuel(doc);
    try {
      historique.add(avant);
      futur.clear();

      final page = doc.pages[0];
      // On efface l'ancienne place : en agrandissant, l'ancien tracé serait
      // recouvert, mais en réduisant il faut nettoyer ce qui dépasse.
      final aEffacer = _rectEffacement(mot).expandToInclude(nouvelle);
      _effacerRect(page, aEffacer, mot);

      if (traits != null) {
        _tracerSignature(page, traits, nouvelle);
        setState(() {
          mot.zone = nouvelle;
          statut = "Signature redimensionnée";
        });
        await _rafraichirApercuOcr(doc);
      } else {
        final tailleActuelle = _dessinTexte(mot, mot.zone).police.size;
        final facteur = mot.zone.width <= 0
            ? 1.0
            : nouvelle.width / mot.zone.width;
        mot.zone = nouvelle;
        mot.tailleManuelle = (tailleActuelle * facteur).clamp(4.0, 96.0);
        _ecrire(page, mot, mot.zone);

        if (imageDeFond != null) {
          final fond = _couleurLocale(mot.zone);
          mot.fondEcran = Color.fromARGB(255, fond.r, fond.g, fond.b);
          mot.zoneMasque = aEffacer.expandToInclude(_rectContenu(mot));
        }
        setState(() => statut = "Ligne redimensionnée");
      }
    } catch (e) {
      historique.removeLast();
      await _restaurerEtat(avant);
      setState(
          () => statut = "Redimensionnement annulé (rien n'a été perdu) : $e");
    } finally {
      setState(() => _occupe = false);
    }
  }

  /// Réduit ou agrandit d'un cran depuis le menu, autour du coin haut-gauche.
  Future<void> _redimensionnerDUnCran(MotDetecte mot, double facteur) =>
      _redimensionnerZone(
        mot,
        Rect.fromLTWH(
          mot.zone.left,
          mot.zone.top,
          mot.zone.width * facteur,
          mot.zone.height * facteur,
        ),
      );

  Future<void> _poserSignature(double x, double y) async {
    final traits = signatureNormalisee;
    final doc = document;
    if (traits == null || doc == null || _occupe) return;
    setState(() => _occupe = true);
    final avant = await _etatActuel(doc);
    try {
      historique.add(avant);
      futur.clear();

      final largeur = taillePage.width * 0.28;
      final hauteur = largeur * signatureRatio;
      var gauche = x - largeur / 2;
      var haut = y - hauteur / 2;
      if (gauche < 0) gauche = 0;
      if (haut < 0) haut = 0;
      if (gauche + largeur > taillePage.width) {
        gauche = taillePage.width - largeur;
      }
      if (haut + hauteur > taillePage.height) {
        haut = taillePage.height - hauteur;
      }

      final page = doc.pages[0];
      _tracerSignature(page, traits, Rect.fromLTWH(gauche, haut, largeur, hauteur));

      // Un repère (sans texte) sur la signature : elle devient sélectionnable
      // et déplaçable comme le reste, sans traitement particulier.
      final zone = Rect.fromLTWH(gauche, haut, largeur, hauteur);
      setState(() {
        mots.add(MotDetecte("", zone,
            traitsSignature: traits, ratioSignature: signatureRatio));
        enPoseSignature = false;
        statut = "Signature posée — double-tapez dessus pour la redimensionner";
      });

      if (imageDeFond == null) {
        await _activerApercuImage(doc);
      } else {
        await _rafraichirApercuOcr(doc);
      }
    } catch (e) {
      historique.removeLast();
      await _restaurerEtat(avant);
      setState(() => statut = "Signature annulée (rien n'a été perdu) : $e");
    } finally {
      setState(() => _occupe = false);
    }
  }

  Future<void> _init() async {
    try {
      final path = await _channel.invokeMethod<String>("getInitialPdfPath");
      if (path != null) {
        await _chargerPourLecture(File(path).readAsBytesSync());
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
      await _chargerPourLecture(builder.toBytes());
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
      await _chargerPourLecture(File(chemin).readAsBytesSync());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erreur d'importation : $e")),
        );
      }
    }
  }

  /// Ouvre le document en simple lecture : juste une image de la page, sans
  /// détecter la moindre ligne ni lancer d'OCR. L'analyse complète (qui peut
  /// prendre plusieurs secondes sur une page scannée) n'a lieu que lorsque
  /// l'utilisateur appuie sur « Modifier ».
  Future<void> _chargerPourLecture(Uint8List octets) async {
    document?.dispose();
    document = null;
    historique.clear();
    futur.clear();
    setState(() {
      mots = [];
      selection.clear();
      imageDeFond = null;
      imageDecodee = null;
      apercuLecture = null;
      octetsDocument = null;
      modeLecture = true;
      statut = "Chargement...";
    });
    try {
      final doc = PdfDocument(inputBytes: octets);
      final taille = doc.pages[0].size;
      doc.dispose();

      PdfRaster? raster;
      await for (final r in Printing.raster(octets, pages: const [0], dpi: 150)) {
        raster = r;
        break;
      }
      final png = raster == null ? null : await raster.toPng();

      if (!mounted) return;
      setState(() {
        octetsDocument = octets;
        taillePage = Size(taille.width, taille.height);
        apercuLecture = png;
        statut = "Lecture seule — appuyez sur le crayon pour modifier";
      });
    } catch (e) {
      setState(() => statut = "Erreur d'ouverture : $e");
    }
  }

  /// Quitte la lecture seule et lance l'analyse (extraction de texte, ou OCR
  /// sur une page scannée) : c'est seulement à partir de là que les lignes
  /// deviennent sélectionnables et modifiables.
  Future<void> _passerEnModification() async {
    final octets = octetsDocument;
    if (octets == null || _occupe) return;
    setState(() => _occupe = true);
    await _analyser(octets);
    if (!mounted) return;
    setState(() {
      modeLecture = false;
      _occupe = false;
    });
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
          italique: ligne.fontStyle.contains(PdfFontStyle.italic),
          famille: _familleDepuisNom(ligne.fontName),
          // Taille réelle indiquée par le document : bien plus fidèle que
          // celle qu'on déduisait de la hauteur du cadre, qui faisait
          // changer de taille une ligne au premier passage.
          tailleManuelle: ligne.fontSize > 0 ? ligne.fontSize : null,
        ));
      }

      if (trouvesTexte.isNotEmpty) {
        setState(() {
          document = doc;
          mots = trouvesTexte;
          taillePage = Size(page.size.width, page.size.height);
          imageDeFond = null;
          imageDecodee = null;
          selection.clear();
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

  /// Regroupe les mots détectés par l'OCR qui appartiennent à la même
  /// rangée horizontale (ex : une puce "-" séparée du texte qui suit), puis,
  /// à l'intérieur d'une rangée, ne fusionne que les mots consécutifs ayant
  /// le même gras. Sans cette seconde étape, une rangée mêlant du texte
  /// gras et normal (ex : une étiquette en gras suivie d'une date en
  /// normal) n'aurait qu'un seul bloc avec un seul gras estimé pour toute
  /// la ligne — correct tant que la ligne garde ses pixels d'origine, mais
  /// dès qu'on la modifie et qu'elle est redessinée, tout le texte devient
  /// uniformément gras ou non, en plus de s'élargir (le gras est plus
  /// large) et de déborder de son cadre.
  List<MotDetecte> _fusionnerParRangee(List<MotDetecte> brutes) {
    if (brutes.isEmpty) return brutes;
    final triees = [...brutes]..sort((a, b) => a.zone.top.compareTo(b.zone.top));
    final rangees = <List<MotDetecte>>[];

    for (final mot in triees) {
      final motHaut = mot.zone.top;
      final motBas = mot.zone.top + mot.zone.height;
      List<MotDetecte>? cible;
      for (final rangee in rangees) {
        var rangeeHaut = rangee.first.zone.top;
        var rangeeBas = rangee.first.zone.top + rangee.first.zone.height;
        for (final l in rangee.skip(1)) {
          if (l.zone.top < rangeeHaut) rangeeHaut = l.zone.top;
          final b = l.zone.top + l.zone.height;
          if (b > rangeeBas) rangeeBas = b;
        }
        final chevauchement = (rangeeBas < motBas ? rangeeBas : motBas) -
            (rangeeHaut > motHaut ? rangeeHaut : motHaut);
        final hauteurMin = (rangeeBas - rangeeHaut) < mot.zone.height
            ? (rangeeBas - rangeeHaut)
            : mot.zone.height;
        if (hauteurMin > 0 && chevauchement > hauteurMin * 0.3) {
          cible = rangee;
          break;
        }
      }
      if (cible != null) {
        cible.add(mot);
      } else {
        rangees.add([mot]);
      }
    }

    final resultat = <MotDetecte>[];
    for (final rangee in rangees) {
      rangee.sort((a, b) => a.zone.left.compareTo(b.zone.left));

      // La ponctuation seule (":", ";", "-"...) est trop petite pour que
      // l'estimation de densité soit fiable : elle hérite du gras du mot
      // voisin plutôt que de risquer de couper un run en trois pour rien.
      for (var i = 0; i < rangee.length; i++) {
        final t = rangee[i].texte.trim();
        final estPonctuation =
            t.isNotEmpty && !RegExp(r'[a-zA-Z0-9À-ÿ]').hasMatch(t);
        if (!estPonctuation) continue;
        if (i > 0) {
          rangee[i].gras = rangee[i - 1].gras;
        } else if (rangee.length > 1) {
          rangee[i].gras = rangee[1].gras;
        }
      }

      MotDetecte? courant;
      for (final mot in rangee) {
        // Deux morceaux qui se touchent appartiennent au même mot : un vrai
        // changement de style est toujours séparé par une espace. Sans cette
        // règle, une estimation de gras hésitante coupait « inclus » en
        // « in » + « clus », chacun dans son cadre.
        final colles = courant != null &&
            (mot.zone.left - (courant.zone.left + courant.zone.width)) <
                mot.zone.height * 0.3;
        // Un morceau d'un ou deux caractères n'offre pas assez de pixels
        // pour juger du gras de façon fiable : il rejoint son voisin plutôt
        // que de former un cadre minuscule à lui tout seul.
        final tropCourt = mot.texte.trim().length <= 2 ||
            (courant != null && courant.texte.trim().length <= 2);
        if (courant != null &&
            (courant.gras == mot.gras || colles || tropCourt)) {
          final gauche =
              courant.zone.left < mot.zone.left ? courant.zone.left : mot.zone.left;
          final haut =
              courant.zone.top < mot.zone.top ? courant.zone.top : mot.zone.top;
          final droite = (courant.zone.left + courant.zone.width) >
                  (mot.zone.left + mot.zone.width)
              ? courant.zone.left + courant.zone.width
              : mot.zone.left + mot.zone.width;
          final bas = (courant.zone.top + courant.zone.height) >
                  (mot.zone.top + mot.zone.height)
              ? courant.zone.top + courant.zone.height
              : mot.zone.top + mot.zone.height;
          courant.texte = '${courant.texte} ${mot.texte}';
          courant.zone = Rect.fromLTWH(gauche, haut, droite - gauche, bas - haut);
        } else {
          courant = MotDetecte(mot.texte, mot.zone,
              gras: mot.gras, couleurTexte: mot.couleurTexte);
          resultat.add(courant);
        }
      }
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

  /// Fraction de pixels sombres sur un échantillonnage grossier de la page :
  /// sert à repérer un rendu qui aurait perdu l'essentiel du contenu (voir
  /// _aplatirPage).
  double _densiteEncre(img.Image image) {
    var sombres = 0, total = 0;
    for (var y = 0; y < image.height; y += 15) {
      for (var x = 0; x < image.width; x += 15) {
        final p = image.getPixel(x, y);
        final luminance = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        if (luminance < 200) sombres++;
        total++;
      }
    }
    return total == 0 ? 0 : sombres / total;
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
    const dpi = _dpiOcr;
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
      // Un mot par entrée (et non une ligne ML Kit entière) : c'est ce qui
      // permet d'estimer le gras finement et de ne pas l'appliquer en bloc à
      // toute une rangée qui mélangerait du gras et du normal.
      final brutes = <MotDetecte>[];
      for (final bloc in texteReconnu.blocks) {
        for (final ligne in bloc.lines) {
          for (final element in ligne.elements) {
            if (element.text.trim().isEmpty) continue;
            final b = element.boundingBox;
            brutes.add(MotDetecte(
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

      final imageAnalysee = img.decodePng(pngOctets);
      if (imageAnalysee != null) {
        // La couleur d'encre a besoin de l'image et de son échelle : on les
        // pose avant de parcourir les mots.
        imageDecodee = imageAnalysee;
        echelleOcr = echelle;
        for (final mot in brutes) {
          mot.gras = _detecterGras(imageAnalysee, mot.zone, echelle);
          mot.couleurTexte = _couleurEncre(mot.zone);
        }
      }
      final fusionnees = _fusionnerParRangee(brutes);
      // Calibre chaque ligne sur la largeur de son cadre, tant que son texte
      // est encore celui d'origine : c'est le seul moment où la
      // correspondance texte ↔ cadre est garantie.
      for (final ligne in fusionnees) {
        ligne.tailleAuto = _tailleParLargeur(ligne);
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
        selection.clear();
        statut = "${fusionnees.length} ligne(s) détectée(s) (OCR)";
      });
    } catch (e) {
      setState(() => statut = "Erreur OCR : $e");
    } finally {
      await recognizer?.close();
    }
  }

  Future<void> _rafraichirApercuOcr(PdfDocument doc) async {
    const dpi = _dpiOcr;
    try {
      final octetsDoc = Uint8List.fromList(await doc.save());
      PdfRaster? raster;
      await for (final r in Printing.raster(octetsDoc, pages: const [0], dpi: dpi)) {
        raster = r;
        break;
      }
      if (raster == null) return;
      final pngOctets = await raster.toPng();
      final nouvelle = img.decodePng(pngOctets);
      if (nouvelle == null) return;

      // Même garde-fou que l'aplatissement : la rastérisation perd parfois
      // l'essentiel du contenu sans lever d'erreur. On gardait alors cette
      // page presque blanche comme nouvel aperçu, d'où le document qui
      // devenait gris/vide d'un coup. On préfère garder l'aperçu précédent.
      final ancienne = imageDecodee;
      if (ancienne != null) {
        final avant = _densiteEncre(ancienne);
        final apres = _densiteEncre(nouvelle);
        if (avant > 0.01 && apres < avant * 0.3) {
          if (mounted) {
            setState(() => statut =
                "Aperçu non rafraîchi (rendu incomplet) — la page est intacte, "
                "annulez si le résultat vous surprend");
          }
          return;
        }
      }

      if (!mounted) return;
      setState(() {
        imageDeFond = pngOctets;
        imageDecodee = nouvelle;
      });
    } catch (_) {}
  }

  /// Couleur utilisée pour "effacer" une ligne. On échantillonne d'abord
  /// juste autour de la zone (en ignorant les pixels sombres, donc l'encre)
  /// pour coller aux petites variations locales du fond (scan pas
  /// parfaitement uniforme), et on se rabat sur la couleur dominante de
  /// toute la page si l'entourage est trop couvert d'encre pour être fiable.
  PdfColor _couleurDeFond(MotDetecte mot) => _couleurLocale(mot.zone);

  /// Fond réel autour d'une zone, lu dans l'image de la page, en [r, g, b].
  ///
  /// Deux passes : d'abord la teinte claire la plus fréquente (le papier),
  /// puis, si l'entourage n'a rien de clair — une ligne posée sur un bandeau
  /// sombre, comme la colonne d'un CV —, la teinte la plus fréquente tout
  /// court, qui est alors le vrai fond. On ne se rabat plus sur la couleur
  /// dominante de la page entière : sur un document à large bandeau sombre
  /// elle pouvait être sombre, et peignait une barre noire en travers de la
  /// ligne.
  List<int>? _fondAutour(Rect zonePdf) {
    final image = imageDecodee;
    if (image == null) return null;
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

    // On retient la teinte la plus fréquente, et non la moyenne : autour
    // d'une ligne dense, la moyenne est tirée vers le gris par les pixels de
    // bord de lettres et donne un aplat grisâtre.
    final clairs = <int, int>{};
    final tous = <int, int>{};
    var totalClairs = 0;
    var totalTous = 0;
    for (var y = haut; y <= bas; y += 3) {
      for (var x = gauche; x <= droite; x += 3) {
        final dansZone = x >= zoneGaucheIm &&
            x <= zoneDroiteIm &&
            y >= zoneHautIm &&
            y <= zoneBasIm;
        if (dansZone) continue;
        final pixel = image.getPixel(x, y);
        if (pixel.a == 0) {
          // Fond transparent du rendu : c'est du papier blanc à l'écran.
          const cleBlanc = (63 << 16) | (63 << 8) | 63;
          tous[cleBlanc] = (tous[cleBlanc] ?? 0) + 1;
          clairs[cleBlanc] = (clairs[cleBlanc] ?? 0) + 1;
          totalTous++;
          totalClairs++;
          continue;
        }
        final cle = ((pixel.r.toInt() ~/ 4) << 16) |
            ((pixel.g.toInt() ~/ 4) << 8) |
            (pixel.b.toInt() ~/ 4);
        tous[cle] = (tous[cle] ?? 0) + 1;
        totalTous++;
        final luminance =
            0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;
        if (luminance < 200) continue;
        clairs[cle] = (clairs[cle] ?? 0) + 1;
        totalClairs++;
      }
    }

    final compteur = totalClairs >= 8 ? clairs : tous;
    if (compteur.isEmpty || totalTous < 4) return null;
    var cleFrequente = compteur.keys.first;
    var maxCompte = compteur[cleFrequente]!;
    for (final entree in compteur.entries) {
      if (entree.value > maxCompte) {
        maxCompte = entree.value;
        cleFrequente = entree.key;
      }
    }
    final r = ((cleFrequente >> 16) & 0xFF) * 4;
    final g = ((cleFrequente >> 8) & 0xFF) * 4;
    final b = (cleFrequente & 0xFF) * 4;
    // Un papier blanc ressort à 252 après quantification : on le ramène au
    // blanc franc, sinon le rectangle posé par-dessus se voit légèrement.
    if (r >= 248 && g >= 248 && b >= 248) return const [255, 255, 255];
    return [r, g, b];
  }

  PdfColor _couleurLocale(Rect zonePdf) {
    final fond = _fondAutour(zonePdf);
    if (fond == null) return couleurPage;
    return PdfColor(fond[0], fond[1], fond[2]);
  }

  /// Couleur à peindre derrière le champ d'écriture directe : celle du papier
  /// autour de la ligne, donc invisible sur fond blanc. L'aspect du document
  /// ne change pas quand on passe en modification.
  Color _couleurPapierEcran(Rect zonePdf) {
    final fond = _fondAutour(zonePdf);
    if (fond == null) return Colors.white;
    return Color.fromARGB(255, fond[0], fond[1], fond[2]);
  }

  PdfStandardFont _police(MotDetecte mot, [double? taille]) {
    // Un seul style à la fois : le gras l'emporte sur l'italique quand les
    // deux sont détectés, ce qui reste plus proche de l'original que de
    // perdre les deux.
    final style = mot.gras
        ? PdfFontStyle.bold
        : (mot.italique ? PdfFontStyle.italic : PdfFontStyle.regular);
    return PdfStandardFont(
      mot.famille,
      taille ?? mot.zone.height * 0.75,
      style: style,
    );
  }

  /// Famille de police approchée à partir du nom trouvé dans le PDF. Les
  /// polices d'un document sont innombrables, les familles dessinables ici
  /// sont trois : on choisit la plus proche par sa nature (à empattements,
  /// sans empattements, chasse fixe) plutôt que de tout ramener à Helvetica.
  PdfFontFamily _familleDepuisNom(String? nom) {
    final n = (nom ?? '').toLowerCase();
    if (n.contains('times') ||
        n.contains('serif') && !n.contains('sans') ||
        n.contains('georgia') ||
        n.contains('garamond') ||
        n.contains('book') ||
        n.contains('roman') ||
        n.contains('cambria') ||
        n.contains('minion')) {
      return PdfFontFamily.timesRoman;
    }
    if (n.contains('courier') || n.contains('mono') || n.contains('consol')) {
      return PdfFontFamily.courier;
    }
    return PdfFontFamily.helvetica;
  }

  /// Couleur de l'encre d'une ligne, relevée sur l'image de la page : la
  /// teinte dominante parmi les pixels qui tranchent nettement sur le fond
  /// local. Marche donc aussi bien pour du noir sur blanc que pour du blanc
  /// sur un bandeau sombre ou un titre en couleur.
  PdfColor? _couleurEncre(Rect zonePdf) {
    final image = imageDecodee;
    if (image == null) return null;
    final fond = _fondAutour(zonePdf);
    if (fond == null) return null;
    final echelle = echelleOcr;

    final gauche = (zonePdf.left * echelle).round().clamp(0, image.width - 1);
    final droite = (zonePdf.right * echelle).round().clamp(0, image.width - 1);
    final haut = (zonePdf.top * echelle).round().clamp(0, image.height - 1);
    final bas = (zonePdf.bottom * echelle).round().clamp(0, image.height - 1);

    final compteur = <int, int>{};
    var total = 0;
    for (var y = haut; y <= bas; y += 2) {
      for (var x = gauche; x <= droite; x += 2) {
        final pixel = image.getPixel(x, y);
        if (pixel.a == 0) continue;
        final dr = pixel.r.toDouble() - fond[0];
        final dg = pixel.g.toDouble() - fond[1];
        final db = pixel.b.toDouble() - fond[2];
        // Assez loin du fond pour être de l'encre, et pas un pixel de bord
        // de lettre à mi-chemin entre les deux.
        if (dr * dr + dg * dg + db * db < 80 * 80) continue;
        final cle = ((pixel.r.toInt() ~/ 8) << 16) |
            ((pixel.g.toInt() ~/ 8) << 8) |
            (pixel.b.toInt() ~/ 8);
        compteur[cle] = (compteur[cle] ?? 0) + 1;
        total++;
      }
    }
    if (total < 12) return null;

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
    // Une encre quasi noire est ramenée au noir franc : 248 au lieu de 0
    // donnerait un gris très légèrement délavé à côté du texte d'origine.
    if (r <= 24 && g <= 24 && b <= 24) return PdfColor(0, 0, 0);
    return PdfColor(r, g, b);
  }

  /// Taille de police et rectangle de dessin pour un texte replacé dans sa
  /// zone. Si l'utilisateur a réglé une taille à la main (mot.tailleManuelle),
  /// elle prime toujours. Sinon, la taille est estimée à partir de la
  /// hauteur du cadre détecté par l'OCR, en corrigeant l'écart entre cette
  /// hauteur (qui inclut marge, accents, jambages) et la hauteur réellement
  /// mesurée du texte en Helvetica — un ratio empirique (1.15) rapproche le
  /// résultat de la taille apparente d'origine, sans jamais la reproduire
  /// exactement puisque la police d'origine du scan est inconnue.
  /// Taille de police pour laquelle le texte d'une ligne occuperait
  /// exactement la largeur de son cadre détecté. C'est la calibration la
  /// plus fiable dont on dispose : le cadre OCR épouse l'étendue horizontale
  /// du texte, alors que sa hauteur inclut marge, accents et jambages.
  double? _tailleParLargeur(MotDetecte mot) {
    if (mot.texte.trim().isEmpty || mot.zone.width <= 0) return null;
    const reference = 20.0;
    final largeur = _police(mot, reference).measureString(mot.texte).width;
    if (largeur <= 0) return null;
    final taille = reference * mot.zone.width / largeur;
    if (taille < 4 || taille > 96) return null;
    return taille;
  }

  ({Rect rect, PdfStandardFont police}) _dessinTexte(MotDetecte mot, Rect zone) {
    // La taille calibrée sur la largeur du cadre (voir mot.tailleAuto) prime
    // sur l'estimation par la hauteur, qui donnait un texte trop gros.
    final tailleDepart = mot.tailleManuelle ?? mot.tailleAuto;
    var police = _police(mot, tailleDepart ?? zone.height * 0.75);
    var mesure = police.measureString(mot.texte);

    if (tailleDepart == null && mesure.height > 0 && zone.height > 0) {
      var taille = police.size * zone.height / mesure.height * 1.15;
      // Garde-fou : un calcul aberrant (mesure dégénérée) donnerait sinon
      // une police gigantesque, qui a déjà fait échouer le dessin en
      // silence, laissant un cadre effacé sans texte.
      if (taille < 4) taille = 4;
      if (taille > 96) taille = 96;
      police = _police(mot, taille);
      mesure = police.measureString(mot.texte);
    }

    // Largeur disponible pour ne pas déborder : le bord de la page pour une
    // ligne normale ; la largeur fixe de la boîte pour une zone libre, dont
    // le cadre ne s'agrandit jamais au contenu (c'est ce qui permet de
    // centrer ou d'aligner à droite dedans).
    final largeurDispo =
        mot.boiteLibre ? zone.width - 4 : taillePage.width - zone.left - 2;
    if (largeurDispo > 0 && mesure.width > largeurDispo) {
      var taille = police.size * largeurDispo / mesure.width;
      if (taille < 4) taille = 4;
      police = _police(mot, taille);
      mesure = police.measureString(mot.texte);
    }

    final largeur = mot.boiteLibre
        ? zone.width
        : (mesure.width > zone.width ? mesure.width : zone.width) + 2;
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

  /// Rectangle occupé à l'écran par une ligne. Le texte que l'application
  /// redessine est souvent plus large que le texte scanné d'origine (la
  /// police de substitution est moins condensée) : s'en tenir au cadre
  /// détecté coupait la fin de la ligne à l'écran — « FRANCILITE GRAND
  /// PROVINOIS depuis » devenait « FRANCILITE GRAND P » — alors que le PDF,
  /// lui, contenait bien tout le texte. Le cadre suit donc le texte
  /// réellement dessiné, sans dépasser le bord de la page.
  Rect _rectAffichage(MotDetecte mot, double echelle) {
    final enEcriture = motEnEditionDirecte == mot;
    // La zone repeinte doit toujours être recouverte, même sans texte.
    final masque = mot.zoneMasque;
    if (!enEcriture && !mot.redessine) {
      return masque == null ? mot.zone : mot.zone.expandToInclude(masque);
    }

    final texte = enEcriture ? controleurDirect.text : mot.texte;
    if (texte.isEmpty || echelle <= 0) {
      return masque == null ? mot.zone : mot.zone.expandToInclude(masque);
    }

    // Mesure avec la police d'écran (celle du téléphone), et non celle du
    // PDF : les deux n'ont pas les mêmes largeurs de caractères, et se fier
    // à celle du PDF laissait la fin de la ligne dépasser du cadre, donc
    // coupée à l'affichage.
    final taille = enEcriture
        ? _tailleEditionDirecte(mot)
        : _dessinTexte(mot, mot.zone).police.size;
    final gras = enEcriture ? grasDirect : mot.gras;
    final peintre = TextPainter(
      text: TextSpan(
        text: texte,
        style: TextStyle(
          fontSize: taille * echelle,
          height: 1.0,
          fontWeight: gras ? FontWeight.bold : FontWeight.normal,
          fontStyle: mot.italique ? FontStyle.italic : FontStyle.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    // Un peu d'air à droite pour le curseur.
    var largeur = peintre.width / echelle + 4;
    if (largeur < mot.zone.width) largeur = mot.zone.width;
    final maxi = taillePage.width - mot.zone.left - 2;
    if (maxi > 0 && largeur > maxi) largeur = maxi;
    if (largeur < 1) largeur = mot.zone.width;

    // Le cadre reste centré sur la ligne d'origine s'il doit grandir en
    // hauteur : sinon le texte semblerait descendre d'un cran.
    var hauteur = mot.zone.height;
    final hauteurTexte = peintre.height / echelle;
    if (hauteurTexte > hauteur) hauteur = hauteurTexte;

    final rect = Rect.fromLTWH(
      mot.zone.left,
      mot.zone.center.dy - hauteur / 2,
      largeur,
      hauteur,
    );
    return masque == null ? rect : rect.expandToInclude(masque);
  }

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
  /// qu'il est réellement imprimé (octets PNG, à envelopper dans un
  /// PdfBitmap au moment de le dessiner). Déplacer ou coller cette image
  /// plutôt que de réécrire le texte conserve exactement la police, la
  /// graisse et la taille d'origine — impossible à reproduire en Helvetica.
  /// Aplatit une image sur du blanc au lieu de simplement jeter son canal
  /// alpha. Le rendu de page peut avoir un fond transparent : à l'écran il
  /// paraît blanc (le blanc de l'application est dessous), mais une fois le
  /// canal alpha retiré, ces pixels valent 0,0,0 — du noir franc. C'est ce
  /// qui posait un rectangle noir à la place du contenu déplacé ou collé.
  img.Image _surFondBlanc(img.Image source) {
    if (source.numChannels < 4) return source;
    final fond = img.Image(
      width: source.width,
      height: source.height,
      numChannels: 3,
    );
    img.fill(fond, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(fond, source);
    return fond;
  }

  Uint8List? _capturerZone(Rect zone) {
    final image = imageDecodee;
    if (image == null) return null;
    final e = echelleOcr;

    final x = (zone.left * e).round().clamp(0, image.width - 1);
    final y = (zone.top * e).round().clamp(0, image.height - 1);
    final largeur = (zone.width * e).round().clamp(1, image.width - x);
    final hauteur = (zone.height * e).round().clamp(1, image.height - y);
    if (largeur < 2 || hauteur < 2) return null;

    try {
      final morceau = img.copyCrop(image,
          x: x, y: y, width: largeur, height: hauteur);
      // Aplati sur du blanc : sans canal alpha, c'est le format le plus
      // sûrement relu par le moteur PDF, et le fond transparent du rendu ne
      // se transforme pas en noir.
      final octets = img.encodePng(_surFondBlanc(morceau));

      // Vérification par aller-retour : un PNG mal formé n'échoue pas
      // toujours au moment de l'encoder, seulement plus tard quand le
      // moteur PDF essaie de le lire — trop tard pour être rattrapé, ça
      // laissait une zone effacée sans rien dessiné à la place. On préfère
      // ici basculer sur le texte redessiné (moins fidèle, mais fiable)
      // plutôt que risquer une capture illisible.
      final relu = img.decodePng(octets);
      if (relu == null || relu.width != largeur || relu.height != hauteur) {
        return null;
      }
      return octets;
    } catch (_) {
      return null;
    }
  }

  /// Cherche une bande de papier vierge au-dessus ou en dessous de [zone],
  /// sur la même largeur, pour s'en servir de gomme. Couvrir avec du vrai
  /// papier se fond bien mieux qu'un aplat de couleur : le fond d'un scan
  /// n'est jamais parfaitement uniforme, et l'aplat se voyait comme un
  /// rectangle plus clair.
  PdfBitmap? _papierProche(Rect zone) {
    final image = imageDecodee;
    if (image == null) return null;
    final e = echelleOcr;

    final x = (zone.left * e).round().clamp(0, image.width - 1);
    final largeur = (zone.width * e).round().clamp(1, image.width - x);
    final hauteurBande = (6 * e).round();
    if (largeur < 2 || hauteurBande < 2) return null;

    bool estVierge(int y) {
      if (y < 0 || y + hauteurBande >= image.height) return false;
      for (var yi = y; yi < y + hauteurBande; yi += 2) {
        for (var xi = x; xi < x + largeur; xi += 2) {
          final p = image.getPixel(xi, yi);
          // Un pixel entièrement transparent est du fond, pas de l'encre :
          // sans ça, un rendu à fond transparent ne trouvait jamais de
          // papier et retombait toujours sur l'aplat de couleur.
          if (p.a == 0) continue;
          if (0.299 * p.r + 0.587 * p.g + 0.114 * p.b < 170) return false;
        }
      }
      return true;
    }

    final haut = (zone.top * e).round();
    final bas = (zone.bottom * e).round();
    for (var ecart = (2 * e).round(); ecart < (50 * e).round(); ecart += 2) {
      for (final y in [haut - ecart - hauteurBande, bas + ecart]) {
        if (!estVierge(y)) continue;
        try {
          final bande = img.copyCrop(image,
              x: x, y: y, width: largeur, height: hauteurBande);
          return PdfBitmap(img.encodePng(_surFondBlanc(bande)));
        } catch (_) {
          return null;
        }
      }
    }
    return null;
  }

  /// Efface une zone : avec du papier prélevé à côté si on en trouve, sinon
  /// avec la couleur de fond estimée.
  void _effacerRect(PdfPage page, Rect rect, MotDetecte mot) {
    final papier = _papierProche(rect);
    if (papier != null) {
      page.graphics.drawImage(papier, rect);
    } else {
      page.graphics.drawRectangle(
        brush: PdfSolidBrush(_couleurDeFond(mot)),
        bounds: rect,
      );
    }
  }

  /// Élargit un rectangle vers la gauche pour attraper ce qui appartient
  /// visiblement à la ligne sans avoir été détecté avec elle : un tiret, une
  /// puce. On avance tant qu'on retrouve de l'encre sur la même rangée, et on
  /// s'arrête au premier blanc franc, qui sépare deux contenus distincts.
  Rect _etendreVersPuce(Rect rect) {
    final image = imageDecodee;
    if (image == null) return rect;
    final e = echelleOcr;

    final yHaut = (rect.top * e).round().clamp(0, image.height - 1);
    final yBas = (rect.bottom * e).round().clamp(0, image.height - 1);
    if (yBas <= yHaut) return rect;

    const portee = 60.0; // on ne remonte pas plus loin vers la marge
    const blancSeparateur = 12.0;

    var gauche = rect.left;
    var blanc = 0.0;
    for (var x = rect.left - 1; x >= rect.left - portee && x >= 1; x -= 1) {
      final xi = (x * e).round().clamp(0, image.width - 1);
      var encre = false;
      for (var yi = yHaut; yi <= yBas; yi += 2) {
        final p = image.getPixel(xi, yi);
        if (0.299 * p.r + 0.587 * p.g + 0.114 * p.b < 140) {
          encre = true;
          break;
        }
      }
      if (encre) {
        gauche = x - 1;
        blanc = 0;
      } else {
        blanc += 1;
        if (blanc >= blancSeparateur) break;
      }
    }
    return Rect.fromLTRB(gauche, rect.top, rect.right, rect.bottom);
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
      brush: PdfSolidBrush(mot.couleurTexte ?? PdfColor(0, 0, 0)),
      format: PdfStringFormat(
        alignment: mot.boiteLibre ? mot.alignement : PdfTextAlignment.left,
        lineAlignment: PdfVerticalAlignment.middle,
      ),
    );
    mot.redessine = true;
  }

  Future<Etat> _etatActuel(PdfDocument doc) async {
    final octetsDocument = Uint8List.fromList(await doc.save());
    final motsCopie = mots
        .map((m) => MotDetecte(m.texte, m.zone,
            gras: m.gras,
            redessine: m.redessine,
            tailleManuelle: m.tailleManuelle,
            boiteLibre: m.boiteLibre,
            alignement: m.alignement,
            italique: m.italique,
            famille: m.famille,
            couleurTexte: m.couleurTexte,
            tailleAuto: m.tailleAuto,
            fondEcran: m.fondEcran,
            zoneMasque: m.zoneMasque,
            traitsSignature: m.traitsSignature,
            ratioSignature: m.ratioSignature))
        .toList();
    return Etat(octetsDocument, motsCopie, imageDeFond);
  }

  Future<void> _restaurerEtat(Etat etat) async {
    document?.dispose();
    final doc = PdfDocument(inputBytes: etat.octetsDocument);
    setState(() {
      document = doc;
      mots = etat.mots
          .map((m) => MotDetecte(m.texte, m.zone,
              gras: m.gras,
              redessine: m.redessine,
              tailleManuelle: m.tailleManuelle,
              boiteLibre: m.boiteLibre,
              alignement: m.alignement,
              italique: m.italique,
              famille: m.famille,
              couleurTexte: m.couleurTexte,
              tailleAuto: m.tailleAuto,
              fondEcran: m.fondEcran,
              zoneMasque: m.zoneMasque,
              traitsSignature: m.traitsSignature,
              ratioSignature: m.ratioSignature))
          .toList();
      imageDeFond = etat.image;
      imageDecodee = etat.image != null ? img.decodePng(etat.image!) : null;
      selection.clear();
      // Le document vient d'être rechargé : les champs lus dans l'ancien
      // n'existent plus, il faut les relire dans le nouveau.
      champEnEdition = null;
      if (modeRemplissage) champsFormulaire = _lireChampsFormulaire(doc);
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

  /// Aplatit la page en une seule image : contrairement au reste de l'app,
  /// qui ne fait que peindre par-dessus (le contenu d'origine reste présent
  /// dans le fichier, juste recouvert), ici la page entière est rastérisée
  /// et le document est reconstruit avec cette seule image comme contenu.
  /// Ce qui était sous une zone effacée ne peut alors plus être retrouvé,
  /// même en inspectant le fichier — comme la rédaction définitive d'Adobe.
  /// Les positions des lignes ne changent pas, l'édition peut continuer
  /// après coup.
  Future<void> _aplatirPage() async {
    final doc = document;
    if (doc == null || _occupe) return;

    if (doc.pages.count > 1) {
      setState(() => statut =
          "Aplatissement impossible : ce document a plusieurs pages, "
          "seule la première serait conservée pour l'instant.");
      return;
    }

    setState(() => _occupe = true);
    try {
      historique.add(await _etatActuel(doc));
      futur.clear();

      const dpi = _dpiOcr;
      final octetsDoc = Uint8List.fromList(await doc.save());
      PdfRaster? raster;
      await for (final r in Printing.raster(octetsDoc, pages: const [0], dpi: dpi)) {
        raster = r;
        break;
      }
      if (raster == null) {
        throw Exception("impossible de générer l'image de la page");
      }
      final pngOctets = await raster.toPng();

      // Garde-fou : de temps en temps, cette rastérisation perd le contenu
      // scanné d'origine (seul le texte redessiné en vectoriel survit) sans
      // lever d'erreur — la page aplatie se retrouve alors quasi blanche.
      // On compare la densité d'encre avant/après et on refuse de continuer
      // si l'essentiel du contenu a disparu, plutôt que de le perdre pour de
      // bon.
      final avantImage = imageDecodee;
      if (avantImage != null) {
        final apresImage = img.decodePng(pngOctets);
        final densiteAvant = _densiteEncre(avantImage);
        final densiteApres =
            apresImage == null ? 0.0 : _densiteEncre(apresImage);
        if (densiteAvant > 0.01 && densiteApres < densiteAvant * 0.3) {
          throw Exception(
              "le rendu a perdu la majorité du contenu (sécurité activée, "
              "rien n'a été modifié) — réessaie, ou évite l'aplatissement "
              "sur ce document pour l'instant");
        }
      }

      final nouveauDoc = PdfDocument();
      nouveauDoc.pageSettings.margins.all = 0;
      nouveauDoc.pageSettings.size = taillePage;
      final nouvellePage = nouveauDoc.pages.add();
      nouvellePage.graphics.drawImage(
        PdfBitmap(pngOctets),
        Rect.fromLTWH(0, 0, taillePage.width, taillePage.height),
      );

      doc.dispose();

      setState(() {
        document = nouveauDoc;
        imageDeFond = pngOctets;
        imageDecodee = img.decodePng(pngOctets);
        echelleOcr = dpi / 72.0;
        for (final m in mots) {
          m.redessine = false;
        }
        statut =
            "Page aplatie : les zones effacées sont maintenant supprimées "
            "du fichier, pas seulement recouvertes";
      });
    } catch (e) {
      historique.removeLast();
      setState(() => statut = "Échec de l'aplatissement : $e");
    } finally {
      setState(() => _occupe = false);
    }
  }

  Future<void> _confirmerAplatissement() async {
    if (document == null || _occupe) return;
    final confirme = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Rédaction définitive"),
        content: const Text(
          "Ce qui a été effacé ou déplacé sera définitivement retiré du "
          "fichier (impossible à récupérer, même en inspectant le PDF), "
          "au lieu d'être seulement recouvert visuellement comme jusqu'ici. "
          "À faire juste avant de partager le document.\n\n"
          "Vérifie la page juste après : si elle apparaît vide ou "
          "incomplète, touche « Annuler » immédiatement avant de "
          "poursuivre — ce cas est normalement bloqué automatiquement, "
          "mais mieux vaut vérifier.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Annuler"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Aplatir"),
          ),
        ],
      ),
    );
    if (confirme == true) await _aplatirPage();
  }

  /// Retire un cadre de la liste. Ce n'est qu'un repère d'affichage : rien
  /// n'est modifié dans le PDF, seul le rectangle bleu disparaît.
  void _retirerRepere(MotDetecte mot) {
    setState(() {
      mots = mots.where((m) => m != mot).toList();
      selection.clear();
      statut = "Cadre retiré (le PDF n'a pas changé)";
    });
  }

  /// Retire d'un coup tous les cadres vides (repères posés par appui long,
  /// ajouts de texte annulés...) : ils n'affectent jamais le PDF, mais
  /// s'accumulent vite et deviennent pénibles à retirer un par un.
  void _nettoyerReperesVides() {
    final avant = mots.length;
    setState(() {
      mots = mots.where((m) => m.texte.isNotEmpty).toList();
      selection.clear();
      final retires = avant - mots.length;
      statut = retires > 0
          ? "$retires cadre(s) vide(s) retiré(s) (le PDF n'a pas changé)"
          : "Aucun cadre vide à retirer";
    });
  }

  Future<void> _modifierMot(MotDetecte mot) async {
    final controleur = TextEditingController(text: mot.texte);
    var grasChoisi = mot.gras;
    // null = taille automatique. Le point de départ quand on touche au
    // réglage est la taille actuellement utilisée (manuelle ou estimée), pour
    // ajuster à partir de ce qui est affiché plutôt que de repartir de zéro.
    double? tailleChoisie = mot.tailleManuelle;
    var alignementChoisi = mot.alignement;
    // Position de la boîte à l'écran : elle cache souvent la page pile là où
    // on aurait besoin de regarder, d'où la poignée pour la glisser ailleurs.
    var positionBoite = Offset.zero;

    final resultat = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Transform.translate(
          offset: positionBoite,
          child: AlertDialog(
          title: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanUpdate: (details) =>
                setDialogState(() => positionBoite += details.delta),
            child: const Row(
              children: [
                Icon(Icons.drag_indicator, size: 20),
                SizedBox(width: 6),
                Text("Modifier la ligne"),
              ],
            ),
          ),
          contentPadding:
              const EdgeInsets.fromLTRB(24, 16, 24, 8),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controleur,
                autofocus: true,
                // Redessine l'aperçu ci-dessous à chaque frappe.
                onChanged: (_) => setDialogState(() {}),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  SizedBox(
                    height: 32,
                    width: 32,
                    child: Checkbox(
                      value: grasChoisi,
                      onChanged: (v) =>
                          setDialogState(() => grasChoisi = v ?? false),
                    ),
                  ),
                  const Text("Gras", style: TextStyle(fontSize: 13)),
                  const Spacer(),
                  const Text("Taille", style: TextStyle(fontSize: 13)),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: const Icon(Icons.remove, size: 20),
                    tooltip: "Réduire",
                    onPressed: () => setDialogState(() {
                      final actuelle = tailleChoisie ??
                          _dessinTexte(mot, mot.zone).police.size;
                      tailleChoisie = (actuelle - 1).clamp(4, 200);
                    }),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      tailleChoisie?.round().toString() ?? "Auto",
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: const Icon(Icons.add, size: 20),
                    tooltip: "Agrandir",
                    onPressed: () => setDialogState(() {
                      final actuelle = tailleChoisie ??
                          _dessinTexte(mot, mot.zone).police.size;
                      tailleChoisie = (actuelle + 1).clamp(4, 200);
                    }),
                  ),
                  if (tailleChoisie != null)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: const Icon(Icons.restart_alt, size: 20),
                      tooltip: "Revenir à l'automatique",
                      onPressed: () =>
                          setDialogState(() => tailleChoisie = null),
                    ),
                ],
              ),
              // Aperçu mis à jour instantanément à chaque réglage (taille,
              // gras, texte tapé) — sans attendre « Valider », puisque la
              // page reste cachée derrière cette boîte tant qu'elle est
              // ouverte.
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    controleur.text.isEmpty ? "Aperçu" : controleur.text,
                    style: TextStyle(
                      fontSize: (tailleChoisie ??
                              _dessinTexte(mot, mot.zone).police.size)
                          .clamp(4, 40),
                      fontWeight:
                          grasChoisi ? FontWeight.bold : FontWeight.normal,
                      color: controleur.text.isEmpty
                          ? Theme.of(ctx).colorScheme.outline
                          : null,
                    ),
                  ),
                ),
              ),
              if (mot.boiteLibre)
                Row(
                  children: [
                    const Text("Alignement", style: TextStyle(fontSize: 13)),
                    const Spacer(),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.format_align_left, size: 20),
                      isSelected: alignementChoisi == PdfTextAlignment.left,
                      tooltip: "Aligner à gauche",
                      onPressed: () => setDialogState(
                          () => alignementChoisi = PdfTextAlignment.left),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.format_align_center, size: 20),
                      isSelected: alignementChoisi == PdfTextAlignment.center,
                      tooltip: "Centrer",
                      onPressed: () => setDialogState(
                          () => alignementChoisi = PdfTextAlignment.center),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.format_align_right, size: 20),
                      isSelected: alignementChoisi == PdfTextAlignment.right,
                      tooltip: "Aligner à droite",
                      onPressed: () => setDialogState(
                          () => alignementChoisi = PdfTextAlignment.right),
                    ),
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
              onPressed: () => Navigator.pop(ctx, {
                "texte": "",
                "gras": grasChoisi,
                "taille": tailleChoisie,
                "supprimer": true,
              }),
              child: Text(mot.texte.isEmpty ? "Retirer le cadre" : "Supprimer"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, {
                "texte": controleur.text,
                "gras": grasChoisi,
                "taille": tailleChoisie,
                "alignement": alignementChoisi,
              }),
              child: const Text("Valider"),
            ),
          ],
          ),
        ),
      ),
    );

    if (resultat == null) return;
    final texteNettoye = (resultat["texte"] as String).trim();
    final grasFinal = resultat["gras"] as bool;
    final tailleFinale = resultat["taille"] as double?;
    final alignementFinal =
        resultat["alignement"] as PdfTextAlignment? ?? mot.alignement;

    // « Supprimer » sur une ligne déjà vide : il ne reste que le cadre bleu,
    // simple repère d'affichage absent du PDF. On le retire de la liste.
    if (resultat["supprimer"] == true && mot.texte.isEmpty) {
      _retirerRepere(mot);
      return;
    }

    await _appliquerModification(
      mot,
      texte: texteNettoye,
      gras: grasFinal,
      taille: tailleFinale,
      alignement: alignementFinal,
    );
  }

  /// Applique un changement de texte / gras / taille sur une ligne : efface
  /// la zone puis la redessine, avec retour en arrière complet si quoi que ce
  /// soit échoue. Partagé par la boîte « Modifier la ligne » et par l'écriture
  /// directement sur la page.
  Future<void> _appliquerModification(
    MotDetecte mot, {
    required String texte,
    required bool gras,
    double? taille,
    PdfTextAlignment? alignement,
  }) async {
    final texteNettoye = texte.trim();
    final grasFinal = gras;
    final tailleFinale = taille;
    final alignementFinal = alignement ?? mot.alignement;

    if (texteNettoye == mot.texte &&
        grasFinal == mot.gras &&
        tailleFinale == mot.tailleManuelle &&
        alignementFinal == mot.alignement) {
      return;
    }

    final doc = document;
    if (doc == null || _occupe) return;
    setState(() => _occupe = true);
    final avant = await _etatActuel(doc);
    try {
      historique.add(avant);
      futur.clear();

      final page = doc.pages[0];
      final rectEfface = _rectEffacement(mot);
      _effacerRect(page, rectEfface, mot);

      mot.gras = grasFinal;
      mot.texte = texteNettoye;
      mot.tailleManuelle = tailleFinale;
      mot.alignement = alignementFinal;
      if (texteNettoye.isEmpty) mot.redessine = false;
      _ecrire(page, mot, mot.zone);

      // La ligne s'affiche désormais en texte natif à l'écran, par-dessus le
      // fond relevé ici : plus besoin de rafraîchir tout l'aperçu de la page
      // — un rendu complet à 300dpi, assez lourd pour geler l'appli (« ne
      // répond pas ») ou laisser voir un instant la ligne à moitié dessinée.
      // On retient la zone repeinte pour la recouvrir à l'écran, y compris
      // quand il n'y a plus de texte du tout à afficher par-dessus.
      if (imageDeFond != null) {
        final fond = _couleurLocale(mot.zone);
        mot.fondEcran = Color.fromARGB(255, fond.r, fond.g, fond.b);
        mot.zoneMasque = rectEfface.expandToInclude(_rectContenu(mot));
      }

      setState(() {
        if (texteNettoye.isEmpty) selection.remove(mot);
      });
    } catch (e) {
      // La zone a déjà été effacée à cet instant : sans ce retour en
      // arrière, un échec du dessin laisserait un cadre vide sans texte.
      historique.removeLast();
      await _restaurerEtat(avant);
      setState(() => statut = "Modification annulée (rien n'a été perdu) : $e");
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

  Future<void> _deplacerLigne(MotDetecte mot, double dx, double dy) =>
      _deplacerGroupe([mot], dx, dy);

  /// Déplace ensemble une ou plusieurs lignes choisies (sélection multiple),
  /// avec exactement la même logique que le déplacement d'une seule ligne :
  /// chacune emmène ce qui est sur sa rangée, pousse les voisines gênantes,
  /// et tout est annulé si quoi que ce soit échoue.
  Future<void> _deplacerGroupe(
      List<MotDetecte> lignesPrincipales, double dx, double dy) async {
    if (dx == 0 && dy == 0 || lignesPrincipales.isEmpty) return;
    final doc = document;
    if (doc == null || _occupe) return;
    // Chaque ligne emmène avec elle ce qui est sur sa rangée : un tiret ou
    // une puce détectés à part restaient sinon en arrière.
    final groupe = <MotDetecte>{
      ...lignesPrincipales,
      for (final principal in lignesPrincipales)
        ...mots.where(
            (m) => m != principal && _memeRangee(m.zone, principal.zone)),
    }.toList();

    final deplacements = <MotDetecte, Offset>{
      for (final m in groupe) m: Offset(dx, dy),
      for (final m in _lignesPoussees(groupe, dx, dy)) m: Offset(0, dy),
    };

    // Un seul rectangle par ligne, calculé une fois : photographie,
    // effacement et repose doivent porter exactement sur le même, sinon on
    // efface plus qu'on n'emporte. Il est élargi vers la gauche pour
    // embarquer un tiret ou une puce que l'OCR n'a pas rattachés à la ligne.
    final rects = <MotDetecte, Rect>{
      for (final m in deplacements.keys)
        m: _etendreVersPuce(_rectDeplacement(m)),
    };

    // Rien ne doit finir hors de la page : c'est ce qui faisait disparaître
    // des lignes bousculées vers le bas.
    final sortDeLaPage = deplacements.entries.any((e) {
      final r = rects[e.key]!.shift(e.value);
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
    final avant = await _etatActuel(doc);
    try {
      historique.add(avant);
      futur.clear();

      final page = doc.pages[0];

      // On photographie chaque contenu avant de toucher à la page : déplacer
      // l'image imprimée conserve la police et la graisse d'origine, qu'on ne
      // saurait pas reproduire en Helvetica. Une zone vide (gomme, ligne
      // supprimée) n'a rien à déplacer ni à effacer.
      final captures = <MotDetecte, Uint8List?>{};
      for (final m in deplacements.keys) {
        // Une ligne redessinée (texte modifié) n'a plus ses pixels
        // d'origine à jour dans l'image de la page (l'aperçu n'est plus
        // rafraîchi après une modification, pour rester réactif) : on la
        // redessine en texte plutôt que de photographier des pixels
        // devenus obsolètes.
        captures[m] = (m.texte.isEmpty || m.redessine)
            ? null
            : _capturerZone(rects[m]!);
      }

      for (final m in deplacements.keys) {
        if (m.texte.isEmpty) continue;
        _effacerRect(page, rects[m]!, m);
      }

      for (final entree in deplacements.entries) {
        final m = entree.key;
        if (m.texte.isEmpty) continue;
        final capture = captures[m];
        if (capture != null) {
          page.graphics
              .drawImage(PdfBitmap(capture), rects[m]!.shift(entree.value));
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
    } catch (e) {
      // La page a déjà été effacée à cet instant : sans ce retour en arrière,
      // un échec de la repose laisserait la ligne effacée pour de bon.
      historique.removeLast();
      await _restaurerEtat(avant);
      setState(() => statut = "Déplacement annulé (rien n'a été perdu) : $e");
    } finally {
      setState(() => _occupe = false);
    }
  }

  /// Pose une zone de texte libre à l'endroit touché et ouvre directement sa
  /// modification : un seul geste pour écrire n'importe où, avec largeur
  /// fixe et alignement au choix (gauche/centre/droite), contrairement aux
  /// lignes détectées dont le cadre s'ajuste toujours au contenu.
  Future<void> _ajouterTexte(double xPage, double yPage) async {
    if (document == null || _occupe) return;

    // Presque toute la largeur de la page, comme une vraie règle : sans
    // ça, « centrer » ne centrait qu'à l'intérieur d'une petite boîte
    // posée là où l'on a touché, pas sur la page comme on l'attendrait.
    const marge = 24.0;
    const hauteur = 18.0;
    final zone = Rect.fromLTWH(
      marge,
      yPage - hauteur / 2,
      taillePage.width - marge * 2,
      hauteur,
    );
    final nouvelleLigne = MotDetecte("", zone, boiteLibre: true);

    setState(() {
      mots = [...mots, nouvelleLigne];
      selection
            ..clear()
            ..add(nouvelleLigne);
      enAjoutTexte = false;
    });

    await _modifierMot(nouvelleLigne);

    // Rien écrit et rien saisi dans la boîte : on retire le cadre vide au
    // lieu de laisser un repère fantôme après un appui accidentel.
    if (nouvelleLigne.texte.isEmpty && mots.contains(nouvelleLigne)) {
      _retirerRepere(nouvelleLigne);
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
      selection
            ..clear()
            ..add(nouvelleLigne);
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
      _effacerRect(page, _rectEffacement(mot), mot);

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
    if (selection.length != 1) return;
    final mot = selection.first;
    if (mot.texte.isEmpty) return;
    // Même rectangle que pour un déplacement (marge + tiret/puce embarqués),
    // pour que l'image capturée corresponde exactement à ce qui est copié.
    final rectCapture = _etendreVersPuce(_rectDeplacement(mot));
    setState(() {
      texteCopie = mot.texte;
      grasCopie = mot.gras;
      italiqueCopie = mot.italique;
      tailleAutoCopiee = mot.tailleAuto;
      familleCopiee = mot.famille;
      couleurCopiee = mot.couleurTexte;
      largeurCopiee = rectCapture.width;
      hauteurCopiee = rectCapture.height;
      tailleCopiee = mot.tailleManuelle;
      // Idem : une ligne redessinée n'a plus ses pixels à jour dans l'image
      // de la page, on colle donc son texte plutôt qu'une capture obsolète.
      imageCopiee = mot.redessine ? null : _capturerZone(rectCapture);
      statut = "Texte copié : collez-le ici ou dans n'importe quelle autre "
          "application";
    });
    // Aussi dans le presse-papiers d'Android : le texte est alors collable
    // partout ailleurs (SMS, mail, autre application), avec le collage
    // habituel du téléphone, et pas seulement dans ce document.
    Clipboard.setData(ClipboardData(text: mot.texte));
  }

  void _activerModeCollage() {
    if (texteCopie == null) return;
    setState(() {
      enCollage = true;
      enAjoutTexte = false;
      statut = "Touchez l'endroit de la page où coller le texte";
    });
  }

  /// Colle le texte copié à l'endroit touché sur la page, comme une
  /// nouvelle ligne indépendante qu'on peut ensuite déplacer/modifier.
  Future<void> _collerA(double xPage, double yPage) async {
    final doc = document;
    final texte = texteCopie;
    if (doc == null || texte == null || _occupe) return;

    final zoneVisee = Rect.fromLTWH(
      xPage - largeurCopiee / 2,
      yPage - hauteurCopiee / 2,
      largeurCopiee,
      hauteurCopiee,
    );

    // Coller ne fait qu'ajouter du texte à l'endroit touché : ça ne repeint
    // pas la destination, donc coller sur une ligne existante empile le
    // texte collé par-dessus au lieu de le remplacer, illisible. On demande
    // un autre endroit plutôt que de produire ce chevauchement.
    final surLigneExistante = mots.any(
      (m) => m.texte.isNotEmpty && zoneVisee.inflate(3).overlaps(m.zone),
    );
    if (surLigneExistante) {
      const message =
          "Cet endroit chevauche une ligne existante : touchez un espace "
          "libre pour coller";
      setState(() => statut = message);
      // En plus du texte de statut, facile à manquer : un message visible
      // pour ne pas laisser croire que le collage n'a « rien fait ».
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text(message)));
      }
      return;
    }

    setState(() => _occupe = true);
    final avant = await _etatActuel(doc);
    try {
      historique.add(avant);
      futur.clear();

      final zone = zoneVisee;

      final page = doc.pages[0];
      final nouvelleLigne = MotDetecte(texte, zone,
          gras: grasCopie,
          tailleManuelle: tailleCopiee,
          italique: italiqueCopie,
          famille: familleCopiee,
          couleurTexte: couleurCopiee,
          tailleAuto: tailleAutoCopiee);
      final image = imageCopiee;
      if (image != null) {
        page.graphics.drawImage(PdfBitmap(image), zone);
      } else {
        _ecrire(page, nouvelleLigne, zone);
      }

      setState(() {
        mots = [...mots, nouvelleLigne];
        selection
            ..clear()
            ..add(nouvelleLigne);
        enCollage = false;
        statut = "Texte collé";
      });

      if (imageDeFond != null) {
        await _rafraichirApercuOcr(doc);
      }
    } catch (e) {
      historique.removeLast();
      await _restaurerEtat(avant);
      setState(() => statut = "Collage annulé (rien n'a été perdu) : $e");
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
    return modeLecture ? _buildLecture(context) : _buildEdition(context);
  }

  /// Une entrée du menu contextuel : icône + libellé, sur fond sombre.
  /// Le libellé évite d'avoir à deviner ce que fait une icône seule.
  Widget _entreeMenu(IconData icone, String libelle, VoidCallback? action) {
    final actif = action != null;
    final couleur = actif ? Colors.white : Colors.white38;
    return InkWell(
      onTap: action,
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            const SizedBox(width: 14),
            Icon(icone, size: 20, color: couleur),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                libelle,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: couleur, fontSize: 14),
              ),
            ),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }

  Widget _buildLecture(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Mon éditeur PDF"),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: "Importer un document",
            onPressed: _importerDocument,
          ),
        ],
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
            child: apercuLecture == null
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final echelle = constraints.maxWidth / taillePage.width;
                      return ClipRect(
                        child: InteractiveViewer(
                          constrained: false,
                          boundaryMargin: const EdgeInsets.all(double.infinity),
                          minScale: 0.5,
                          maxScale: 8,
                          child: SizedBox(
                            width: constraints.maxWidth,
                            height: taillePage.height * echelle,
                            child: Image.memory(apercuLecture!, fit: BoxFit.fill),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: apercuLecture == null || _occupe
          ? null
          : FloatingActionButton.extended(
              heroTag: "modifier",
              onPressed: _passerEnModification,
              icon: const Icon(Icons.edit),
              label: const Text("Modifier"),
            ),
    );
  }

  Widget _buildEdition(BuildContext context) {
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
        bottom: champEnEdition != null
            ? PreferredSize(
                preferredSize: const Size.fromHeight(40),
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          champEnEdition!.nom,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        tooltip: "Annuler",
                        onPressed: () {
                          focusDirect.unfocus();
                          setState(() => champEnEdition = null);
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.check, size: 22),
                        tooltip: "Valider",
                        onPressed: _occupe
                            ? null
                            : () {
                                focusDirect.unfocus();
                                _appliquerChamp(champEnEdition!,
                                    texte: controleurDirect.text);
                              },
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
              )
            : motEnEditionDirecte != null
            ? PreferredSize(
                preferredSize: const Size.fromHeight(40),
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Row(
                    children: [
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 32,
                        width: 32,
                        child: Checkbox(
                          value: grasDirect,
                          onChanged: (v) =>
                              setState(() => grasDirect = v ?? false),
                        ),
                      ),
                      const Text("Gras", style: TextStyle(fontSize: 13)),
                      IconButton(
                        icon: const Icon(Icons.select_all, size: 20),
                        tooltip: "Tout sélectionner (pour copier ou remplacer)",
                        onPressed: () {
                          controleurDirect.selection = TextSelection(
                            baseOffset: 0,
                            extentOffset: controleurDirect.text.length,
                          );
                          focusDirect.requestFocus();
                        },
                      ),
                      const Spacer(),
                      const Text("Taille", style: TextStyle(fontSize: 13)),
                      IconButton(
                        icon: const Icon(Icons.remove, size: 20),
                        tooltip: "Réduire",
                        onPressed: () => setState(() {
                          tailleDirecte =
                              (_tailleEditionDirecte(motEnEditionDirecte!) - 1)
                                  .clamp(4, 200);
                        }),
                      ),
                      SizedBox(
                        width: 34,
                        child: Text(
                          tailleDirecte?.round().toString() ?? "Auto",
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add, size: 20),
                        tooltip: "Agrandir",
                        onPressed: () => setState(() {
                          tailleDirecte =
                              (_tailleEditionDirecte(motEnEditionDirecte!) + 1)
                                  .clamp(4, 200);
                        }),
                      ),
                      const Spacer(),
                      // Supprimer juste ici, là où l'on tape déjà : plus
                      // besoin de rectangle ni de passer par les réglages
                      // pour retirer une ligne.
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        tooltip: "Supprimer cette ligne",
                        onPressed: _occupe ? null : _supprimerEditionDirecte,
                      ),
                      IconButton(
                        icon: const Icon(Icons.keyboard_return, size: 20),
                        tooltip: "Ligne suivante (écarte ce qui gêne)",
                        onPressed: _occupe ? null : _ligneSuivante,
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        tooltip: "Annuler",
                        onPressed: _annulerEditionDirecte,
                      ),
                      IconButton(
                        icon: const Icon(Icons.check, size: 22),
                        tooltip: "Valider",
                        onPressed: _occupe ? null : _validerEditionDirecte,
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
              )
            : selection.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(40),
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Row(
                    children: [
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.edit, size: 20),
                        tooltip: "Écrire directement sur la ligne",
                        onPressed: selection.length == 1
                            ? () => _ecrireSurLaLigne(selection.first)
                            : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.tune, size: 20),
                        tooltip: "Réglages de la ligne (boîte)",
                        onPressed: selection.length == 1
                            ? () => _modifierMot(selection.first)
                            : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.content_copy, size: 20),
                        tooltip: "Copier cette ligne",
                        onPressed: selection.length == 1 &&
                                selection.first.texte.isNotEmpty
                            ? _copierLigne
                            : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.cleaning_services, size: 20),
                        tooltip: "Effacer ici (gomme)",
                        onPressed: _occupe || selection.length != 1
                            ? null
                            : () => _effacerZone(selection.first),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        tooltip: "Retirer ce cadre (n'efface rien dans le PDF)",
                        onPressed: selection.length == 1 &&
                                selection.first.texte.isEmpty
                            ? () => _retirerRepere(selection.first)
                            : null,
                      ),
                      Expanded(
                        child: Text(
                          selection.length > 1
                              ? "${selection.length} éléments sélectionnés"
                              : (selection.first.texte.isEmpty
                                  ? "(ligne vide)"
                                  : selection.first.texte),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_back, size: 20),
                        tooltip: "Déplacer à gauche",
                        onPressed: _occupe
                            ? null
                            : () => _deplacerGroupe(
                                selection.toList(), -_pasDeplacement, 0),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_upward, size: 20),
                        tooltip: "Déplacer vers le haut",
                        onPressed: _occupe
                            ? null
                            : () => _deplacerGroupe(
                                selection.toList(), 0, -_pasDeplacement),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_downward, size: 20),
                        tooltip: "Déplacer vers le bas",
                        onPressed: _occupe
                            ? null
                            : () => _deplacerGroupe(
                                selection.toList(), 0, _pasDeplacement),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_forward, size: 20),
                        tooltip: "Déplacer à droite",
                        onPressed: _occupe
                            ? null
                            : () => _deplacerGroupe(
                                selection.toList(), _pasDeplacement, 0),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        tooltip: "Désélectionner",
                        onPressed: () => setState(() => selection.clear()),
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
                        child: Stack(children: [
                        InteractiveViewer(
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
                                            } else if (enAjoutTexte) {
                                              _ajouterTexte(
                                                details.localPosition.dx /
                                                    echelle,
                                                details.localPosition.dy /
                                                    echelle,
                                              );
                                            } else if (enPoseSignature) {
                                              _poserSignature(
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
                              // Pendant un collage ou un ajout de texte, les
                              // cadres laissent passer l'appui : sinon toucher
                              // une zone occupée par une ligne la sélectionnait
                              // au lieu de déposer le texte à cet endroit.
                              if (!modeNavigation &&
                                  !enCollage &&
                                  !enAjoutTexte &&
                                  !enPoseSignature &&
                                  !modeRemplissage)
                                for (final mot in mots)
                                Positioned(
                                  left: _rectAffichage(mot, echelle).left *
                                          echelle +
                                      (groupeEnDeplacement &&
                                              selection.contains(mot)
                                          ? deplacementGroupeEnCours.dx
                                          : 0),
                                  top: _rectAffichage(mot, echelle).top *
                                          echelle +
                                      (groupeEnDeplacement &&
                                              selection.contains(mot)
                                          ? deplacementGroupeEnCours.dy
                                          : 0),
                                  width:
                                      _rectAffichage(mot, echelle).width *
                                          echelle,
                                  height:
                                      _rectAffichage(mot, echelle).height *
                                          echelle,
                                  child: motEnEditionDirecte == mot
                                      // Écriture directement sur la page : le
                                      // champ occupe la place de la ligne, à
                                      // sa taille, par-dessus un fond de la
                                      // couleur du papier pour masquer le
                                      // texte d'origine pendant la frappe.
                                      ? Container(
                                          color:
                                              _couleurPapierEcran(mot.zone),
                                          // Le cadre d'une ligne est souvent
                                          // juste à la hauteur du texte : sans
                                          // ça, le champ (un peu plus haut)
                                          // déborderait de sa case.
                                          child: OverflowBox(
                                            alignment: Alignment.centerLeft,
                                            maxHeight: double.infinity,
                                            child: TextField(
                                              controller: controleurDirect,
                                              focusNode: focusDirect,
                                              autofocus: true,
                                              maxLines: 1,
                                              cursorWidth: 2,
                                              cursorColor: Colors.blue,
                                              selectionControls:
                                                  _AucunePoignee(),
                                              textAlignVertical:
                                                  TextAlignVertical.center,
                                              style: TextStyle(
                                                fontSize:
                                                    _tailleEditionDirecte(mot) *
                                                        echelle,
                                                height: 1.0,
                                                fontWeight: grasDirect
                                                    ? FontWeight.bold
                                                    : FontWeight.normal,
                                                color: Colors.black,
                                              ),
                                              decoration: const InputDecoration(
                                                isDense: true,
                                                border: InputBorder.none,
                                                contentPadding: EdgeInsets.zero,
                                              ),
                                              // Le cadre s'élargit au fil de
                                              // la frappe : sans ça, la fin
                                              // du texte sortirait du cadre
                                              // détecté et serait coupée.
                                              onChanged: (_) => setState(() {}),
                                              // Entrée = ligne suivante, comme
                                              // dans un traitement de texte ;
                                              // le ✓ de la barre termine.
                                              textInputAction:
                                                  TextInputAction.next,
                                              onSubmitted: (_) =>
                                                  _ligneSuivante(),
                                            ),
                                          ),
                                        )
                                      : GestureDetector(
                                    // Un tap simple écrit directement sur la
                                    // ligne, sans étape intermédiaire : c'est
                                    // le geste le plus courant, il doit être
                                    // le plus court.
                                    onTap: _occupe
                                        ? null
                                        : () => _ecrireSurLaLigne(mot),
                                    // Le double-tap sert à sélectionner
                                    // (ajoute/retire du groupe rouge, pour
                                    // copier, effacer, ou déplacer plusieurs
                                    // lignes ensemble) sans déclencher
                                    // l'écriture.
                                    onDoubleTap: () => setState(() {
                                      if (!selection.remove(mot)) {
                                        selection.add(mot);
                                      }
                                    }),
                                    // Appui long : identique au tap simple,
                                    // et ça empêche l'appui long de la page
                                    // (qui pose un repère à effacer) de se
                                    // déclencher par-dessus une ligne.
                                    onLongPress: _occupe
                                        ? null
                                        : () => _ecrireSurLaLigne(mot),
                                    // Le glisser ne déplace que si la ligne
                                    // fait partie de la sélection ; sinon le
                                    // geste passe à la page (défilement/zoom).
                                    onPanStart: !selection.contains(mot)
                                        ? null
                                        : (_) => setState(() {
                                              groupeEnDeplacement = true;
                                              deplacementGroupeEnCours =
                                                  Offset.zero;
                                            }),
                                    onPanUpdate: !selection.contains(mot)
                                        ? null
                                        : (details) => setState(() {
                                              deplacementGroupeEnCours +=
                                                  details.delta;
                                            }),
                                    onPanEnd: !selection.contains(mot)
                                        ? null
                                        : (_) async {
                                            final dx =
                                                deplacementGroupeEnCours.dx /
                                                    echelle;
                                            final dy =
                                                deplacementGroupeEnCours.dy /
                                                    echelle;
                                            setState(() {
                                              groupeEnDeplacement = false;
                                              deplacementGroupeEnCours =
                                                  Offset.zero;
                                            });
                                            await _deplacerGroupe(
                                                selection.toList(), dx, dy);
                                          },
                                    child: CustomPaint(
                                      painter: _CadreLigne(
                                        selectionne: selection.contains(mot),
                                        groupe: selection.length > 1,
                                      ),
                                      // Sur une page scannée, une ligne pas
                                      // encore modifiée montre les pixels du
                                      // scan tels quels (le cadre est
                                      // transparent). Une ligne modifiée
                                      // (mot.redessine) s'affiche en texte
                                      // natif sur son fond relevé : c'est ce
                                      // qui permet d'afficher la modification
                                      // sans redessiner toute la page.
                                      child: (imageDeFond != null &&
                                              mot.zoneMasque == null)
                                          ? null
                                          : Container(
                                              color: imageDeFond != null
                                                  ? (mot.fondEcran ??
                                                      Colors.white)
                                                  : null,
                                              child: mot.texte.isEmpty
                                                  ? null
                                                  : FittedBox(
                                                fit: BoxFit.contain,
                                                alignment:
                                                    Alignment.centerLeft,
                                                child: Text(
                                                  mot.texte,
                                                  style: TextStyle(
                                                    fontWeight: mot.gras
                                                        ? FontWeight.bold
                                                        : FontWeight.normal,
                                                    fontStyle: mot.italique
                                                        ? FontStyle.italic
                                                        : FontStyle.normal,
                                                    color: mot.couleurTexte !=
                                                            null
                                                        ? Color.fromARGB(
                                                            255,
                                                            mot.couleurTexte!
                                                                .r,
                                                            mot.couleurTexte!
                                                                .g,
                                                            mot.couleurTexte!
                                                                .b)
                                                        : null,
                                                  ),
                                                ),
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                              // Poignées rondes aux quatre coins de la
                              // sélection : pour réduire ou agrandir le cadre
                              // au doigt, signature comprise.
                              if (selection.length == 1 &&
                                  motEnEditionDirecte == null &&
                                  champEnEdition == null &&
                                  !modeRemplissage &&
                                  !modeNavigation &&
                                  !enCollage &&
                                  !enAjoutTexte &&
                                  !enPoseSignature &&
                                  !groupeEnDeplacement)
                                for (final coin in const [
                                  Alignment.topLeft,
                                  Alignment.topRight,
                                  Alignment.bottomLeft,
                                  Alignment.bottomRight,
                                ])
                                  () {
                                    final mot = selection.first;
                                    final rect = (motRedimensionne == mot
                                            ? rectRedimension
                                            : null) ??
                                        _rectAffichage(mot, echelle);
                                    const rayon = 11.0;
                                    final x =
                                        (coin.x < 0 ? rect.left : rect.right) *
                                            echelle;
                                    final y =
                                        (coin.y < 0 ? rect.top : rect.bottom) *
                                            echelle;
                                    return Positioned(
                                      left: x - rayon,
                                      top: y - rayon,
                                      width: rayon * 2,
                                      height: rayon * 2,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onPanStart: (_) => setState(() {
                                          motRedimensionne = mot;
                                          rectRedimension = rect;
                                        }),
                                        onPanUpdate: (details) =>
                                            setState(() {
                                          final base =
                                              rectRedimension ?? mot.zone;
                                          final dx =
                                              details.delta.dx / echelle;
                                          final dy =
                                              details.delta.dy / echelle;
                                          rectRedimension = Rect.fromLTRB(
                                            coin.x < 0
                                                ? base.left + dx
                                                : base.left,
                                            coin.y < 0
                                                ? base.top + dy
                                                : base.top,
                                            coin.x < 0
                                                ? base.right
                                                : base.right + dx,
                                            coin.y < 0
                                                ? base.bottom
                                                : base.bottom + dy,
                                          );
                                        }),
                                        onPanEnd: (_) async {
                                          final vise = rectRedimension;
                                          setState(() {
                                            motRedimensionne = null;
                                            rectRedimension = null;
                                          });
                                          if (vise != null) {
                                            await _redimensionnerZone(
                                                mot, vise);
                                          }
                                        },
                                        child: Center(
                                          child: Container(
                                            width: rayon * 1.4,
                                            height: rayon * 1.4,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: Colors.white,
                                              border: Border.all(
                                                  color: Colors.blue,
                                                  width: 2),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }(),
                              // Champs de formulaire : cadres verts posés à
                              // l'emplacement exact des cases du PDF.
                              if (modeRemplissage)
                                for (final champ in champsFormulaire)
                                  Positioned(
                                    left: champ.zone.left * echelle,
                                    top: champ.zone.top * echelle,
                                    width: champ.zone.width * echelle,
                                    height: champ.zone.height * echelle,
                                    child: champEnEdition == champ
                                        ? Container(
                                            color: Colors.white,
                                            child: OverflowBox(
                                              alignment: Alignment.centerLeft,
                                              maxHeight: double.infinity,
                                              child: TextField(
                                                controller: controleurDirect,
                                                focusNode: focusDirect,
                                                autofocus: true,
                                                maxLines: 1,
                                                style: TextStyle(
                                                  fontSize: (champ.zone.height *
                                                          echelle *
                                                          0.7)
                                                      .clamp(8, 40),
                                                  height: 1.0,
                                                  color: Colors.black,
                                                ),
                                                decoration:
                                                    const InputDecoration(
                                                  isDense: true,
                                                  border: InputBorder.none,
                                                  contentPadding:
                                                      EdgeInsets.zero,
                                                ),
                                                onSubmitted: (valeur) =>
                                                    _appliquerChamp(champ,
                                                        texte: valeur),
                                              ),
                                            ),
                                          )
                                        : GestureDetector(
                                            onTap: _occupe
                                                ? null
                                                : () {
                                                    if (champ.estCase) {
                                                      _appliquerChamp(champ,
                                                          coche: !champ.coche);
                                                      return;
                                                    }
                                                    setState(() {
                                                      champEnEdition = champ;
                                                      controleurDirect.text =
                                                          champ.valeur;
                                                      controleurDirect
                                                              .selection =
                                                          TextSelection
                                                              .collapsed(
                                                        offset: champ
                                                            .valeur.length,
                                                      );
                                                      statut =
                                                          "Champ « ${champ.nom} »";
                                                    });
                                                    focusDirect.requestFocus();
                                                  },
                                            child: Container(
                                              decoration: BoxDecoration(
                                                color: Colors.green
                                                    .withOpacity(0.12),
                                                border: Border.all(
                                                    color: Colors.green,
                                                    width: 1),
                                              ),
                                              child: champ.estCase &&
                                                      champ.coche
                                                  ? const FittedBox(
                                                      child: Icon(Icons.check,
                                                          color: Colors.green),
                                                    )
                                                  : null,
                                            ),
                                          ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        // Menu posé à côté de la ligne sélectionnée, plutôt
                        // qu'en haut de l'écran : les actions sont là où est
                        // le doigt, comme dans les visionneuses PDF
                        // courantes. Il est hors du zoom (sinon il grossirait
                        // avec la page) et suit la ligne à chaque
                        // déplacement de la vue.
                        if (selection.length == 1 &&
                            motEnEditionDirecte == null &&
                            champEnEdition == null &&
                            !modeRemplissage &&
                            !modeNavigation &&
                            !enCollage &&
                            !enAjoutTexte &&
                            !enPoseSignature)
                          Positioned.fill(
                            child: AnimatedBuilder(
                              animation: _transformation,
                              builder: (context, _) {
                                final mot = selection.first;
                                final matrice = _transformation.value;
                                // La vue ne fait que zoomer et translater
                                // (pas de rotation) : la position à l'écran
                                // se calcule directement.
                                final zoom = matrice.getMaxScaleOnAxis();
                                final decalage = matrice.getTranslation();
                                final coin = Offset(
                                  mot.zone.left * echelle * zoom + decalage.x,
                                  mot.zone.top * echelle * zoom + decalage.y,
                                );
                                final bas = Offset(
                                  mot.zone.right * echelle * zoom + decalage.x,
                                  mot.zone.bottom * echelle * zoom +
                                      decalage.y,
                                );
                                const largeurMenu = 252.0;
                                // Le menu s'allonge selon ce que la
                                // sélection permet de faire.
                                final estVide =
                                    mot.texte.isEmpty && mot.traitsSignature == null;
                                final nbEntrees = estVide ? 7 : 6;
                                final hauteurMenu = 46.0 * nbEntrees;
                                var gauche = coin.dx;
                                if (gauche + largeurMenu >
                                    constraints.maxWidth) {
                                  gauche = constraints.maxWidth - largeurMenu;
                                }
                                if (gauche < 4) gauche = 4;
                                // Au-dessus de la ligne, sauf si elle est
                                // trop haut : le menu passe alors dessous.
                                var haut = coin.dy - hauteurMenu - 6;
                                if (haut < 4) haut = bas.dy + 6;
                                if (haut >
                                    constraints.maxHeight - hauteurMenu - 4) {
                                  haut =
                                      constraints.maxHeight - hauteurMenu - 4;
                                }
                                if (haut < 4) haut = 4;
                                return Stack(
                                  children: [
                                    Positioned(
                                      left: gauche,
                                      top: haut,
                                      width: largeurMenu,
                                      height: hauteurMenu,
                                      child: Material(
                                        color: const Color(0xFF2C2C2E),
                                        borderRadius:
                                            BorderRadius.circular(10),
                                        elevation: 8,
                                        clipBehavior: Clip.antiAlias,
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            _entreeMenu(
                                              Icons.edit,
                                              "Écrire sur la ligne",
                                              _occupe
                                                  ? null
                                                  : () =>
                                                      _ecrireSurLaLigne(mot),
                                            ),
                                            _entreeMenu(
                                              Icons.content_copy,
                                              "Copier le texte",
                                              _occupe || mot.texte.isEmpty
                                                  ? null
                                                  : _copierLigne,
                                            ),
                                            _entreeMenu(
                                              Icons.cleaning_services,
                                              "Effacer (gomme)",
                                              _occupe
                                                  ? null
                                                  : () => _effacerZone(mot),
                                            ),
                                            _entreeMenu(
                                              Icons.tune,
                                              "Mettre en forme",
                                              _occupe
                                                  ? null
                                                  : () => _modifierMot(mot),
                                            ),
                                            _entreeMenu(
                                              Icons.close_fullscreen,
                                              "Réduire",
                                              _occupe
                                                  ? null
                                                  : () =>
                                                      _redimensionnerDUnCran(
                                                          mot, 0.8),
                                            ),
                                            _entreeMenu(
                                              Icons.open_in_full,
                                              "Agrandir",
                                              _occupe
                                                  ? null
                                                  : () =>
                                                      _redimensionnerDUnCran(
                                                          mot, 1.25),
                                            ),
                                            if (estVide)
                                              _entreeMenu(
                                                Icons.delete_outline,
                                                "Retirer ce cadre",
                                                _occupe
                                                    ? null
                                                    : () =>
                                                        _retirerRepere(mot),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ]),
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
                  heroTag: "ajoutTexte",
                  tooltip: enAjoutTexte
                      ? "Touchez la page pour écrire à cet endroit"
                      : "Ajouter du texte n'importe où",
                  backgroundColor:
                      enAjoutTexte ? Theme.of(context).colorScheme.primary : null,
                  foregroundColor: enAjoutTexte
                      ? Theme.of(context).colorScheme.onPrimary
                      : null,
                  onPressed: _occupe
                      ? null
                      : () => setState(() {
                            enAjoutTexte = !enAjoutTexte;
                            if (enAjoutTexte) enCollage = false;
                            statut = enAjoutTexte
                                ? "Touchez la page pour écrire à cet endroit"
                                : "Ajout de texte annulé";
                          }),
                  child: const Icon(Icons.add),
                ),
                const SizedBox(height: 8),
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
                  heroTag: "signature",
                  tooltip: enPoseSignature
                      ? "Touchez la page où poser la signature"
                      : "Signature (mes signatures / en tracer une)",
                  backgroundColor: enPoseSignature
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  foregroundColor: enPoseSignature
                      ? Theme.of(context).colorScheme.onPrimary
                      : null,
                  onPressed: _occupe
                      ? null
                      : (enPoseSignature
                          ? () => setState(() {
                                enPoseSignature = false;
                                statut = "Signature annulée";
                              })
                          : _choisirSignature),
                  child: const Icon(Icons.draw),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: "remplir",
                  tooltip: modeRemplissage
                      ? "Quitter le remplissage du formulaire"
                      : "Remplir le formulaire du PDF",
                  backgroundColor: modeRemplissage
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  foregroundColor: modeRemplissage
                      ? Theme.of(context).colorScheme.onPrimary
                      : null,
                  onPressed: _occupe ? null : _basculerRemplissage,
                  child: const Icon(Icons.edit_note),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: "recentrer",
                  tooltip: "Recentrer / réinitialiser le zoom",
                  onPressed: () => _transformation.value = Matrix4.identity(),
                  child: const Icon(Icons.zoom_out_map),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: "aplatir",
                  tooltip: "Rédaction définitive (avant de partager)",
                  onPressed: _occupe ? null : _confirmerAplatissement,
                  child: const Icon(Icons.security),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: "nettoyer",
                  tooltip: "Retirer tous les cadres vides",
                  onPressed: _occupe ? null : _nettoyerReperesVides,
                  child: const Icon(Icons.clear_all),
                ),
              ],
            ),
    );
  }
}
