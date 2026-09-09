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

/// Couleur de la sélection de texte et de ses poignées. Le bleu par défaut
/// se confondait avec le cadre bleu de la ligne choisie : on ne savait plus
/// ce qui était sélectionné dans le texte et ce qui l'était sur la page.
const Color _brunSelection = Color(0xFF8B5A3C);

void main() => runApp(MaterialApp(
      home: const Accueil(),
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blueGrey,
        scaffoldBackgroundColor: Colors.white,
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: _brunSelection,
          selectionColor: Color(0x668B5A3C),
          selectionHandleColor: _brunSelection,
        ),
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

  /// Vrai pour une ligne trouvée par reconnaissance de caractères sur une
  /// page scannée. On ne connaît alors ni sa police ni sa taille réelles :
  /// la déplacer se fait en photographiant ses pixels. Une ligne venue du
  /// texte d'un PDF, elle, est réécrite — c'est net à tous les zooms, et
  /// sans perte à chaque déplacement.
  bool depuisOcr;

  /// Photo des pixels d'origine d'une ligne scannée, prise au premier
  /// déplacement et reposée telle quelle à tous les suivants, avec la place
  /// qu'elle occupe (taille, et décalage par rapport au cadre de la ligne).
  /// La reprendre à chaque fois repartait de l'image du déplacement
  /// précédent : le texte perdait un cran de netteté par appui, et finissait
  /// gris et hachuré.
  Uint8List? pixelsSource;
  Size? tailleSource;
  Offset? decalageSource;

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
      this.traitsSignature,
      this.ratioSignature = 0.4,
      this.depuisOcr = false,
      this.pixelsSource,
      this.tailleSource,
      this.decalageSource});
}

class Etat {
  final Uint8List octetsDocument;
  final List<MotDetecte> mots;
  final Uint8List? image;

  /// Nombre de pixels d'[image] par point PDF. L'aperçu n'est pas toujours
  /// rendu à la même finesse ; sans retenir la sienne, un retour en arrière
  /// relisait l'ancienne image avec l'échelle de la nouvelle, et les
  /// couleurs et découpes étaient prises au mauvais endroit.
  final double echelleImage;
  Etat(this.octetsDocument, this.mots, this.image, this.echelleImage);
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
/// choisie, trait plein bleu et fond légèrement teinté.
///
/// Un groupe de plusieurs lignes s'affichait auparavant en rouge. Or il se
/// manipule exactement comme une ligne seule — on pose le doigt sur
/// n'importe laquelle et tout suit —, et la barre du haut annonce déjà
/// combien d'éléments sont choisis : le rouge n'ajoutait rien, sinon une
/// couleur d'alerte sur une opération parfaitement ordinaire.
class _CadreLigne extends CustomPainter {
  final bool selectionne;
  const _CadreLigne({required this.selectionne});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (selectionne) {
      canvas.drawRect(rect, Paint()..color = Colors.blue.withOpacity(0.08));
      canvas.drawRect(
        rect,
        Paint()
          ..color = Colors.blue
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
      return;
    }

    // Assez visible pour dire « ceci est modifiable », assez pâle pour ne
    // pas concurrencer le document : c'est le document qu'on vient lire.
    final pinceau = Paint()
      ..color = Colors.blueGrey.withOpacity(0.32)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const tiret = 3.0;
    const trou = 4.0;
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
      ancien.selectionne != selectionne;
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

/// Hauteur d'un tracé normalisé, en fraction de sa largeur. Les traits sont
/// normalisés par leur largeur (x de 0 à 1), leur y monte donc jusqu'à ce
/// rapport. Le relire du tracé lui-même évite de dépendre d'un rapport
/// mémorisé ailleurs, qui pourrait ne plus correspondre.
double _hauteurTraits(List<List<Offset>> traits) {
  var maxi = 0.0;
  for (final trait in traits) {
    for (final p in trait) {
      if (p.dy > maxi) maxi = p.dy;
    }
  }
  return maxi;
}

/// Échelle à appliquer aux traits pour qu'ils tiennent exactement dans un
/// cadre, sans jamais en déborder. La largeur commande, sauf si le cadre est
/// trop plat pour la hauteur du tracé — auquel cas c'est la hauteur qui
/// commande. Sans cette seconde condition, un cadre écrasé contre le bord de
/// la page laissait la signature dépasser par le bas.
double _echelleTraits(List<List<Offset>> traits, Size cadre) {
  final rapport = _hauteurTraits(traits);
  if (rapport <= 0) return cadre.width;
  final parHauteur = cadre.height / rapport;
  return parHauteur < cadre.width ? parHauteur : cadre.width;
}

/// Dessine à l'écran une signature posée sur la page, à la même échelle que
/// celle avec laquelle elle sera écrite dans le PDF.
class _PeintreSignaturePosee extends CustomPainter {
  final List<List<Offset>> traits;
  _PeintreSignaturePosee(this.traits);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0) return;
    final k = _echelleTraits(traits, size);
    final epaisseur = k * 0.006;
    final pinceau = Paint()
      ..color = Colors.black
      ..strokeWidth = epaisseur < 1.2 ? 1.2 : epaisseur
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final trait in traits) {
      if (trait.isEmpty) continue;
      Offset place(Offset p) => Offset(p.dx * k, p.dy * k);
      if (trait.length == 1) {
        canvas.drawLine(
            place(trait.first), place(trait.first).translate(0.1, 0), pinceau);
        continue;
      }
      final chemin = Path()..moveTo(place(trait.first).dx, place(trait.first).dy);
      for (var i = 1; i < trait.length; i++) {
        chemin.lineTo(place(trait[i]).dx, place(trait[i]).dy);
      }
      canvas.drawPath(chemin, pinceau);
    }
  }

  @override
  bool shouldRepaint(_PeintreSignaturePosee ancien) => ancien.traits != traits;
}

/// Une ligne mise de côté par « copier », avec tout ce qu'il faut pour la
/// reposer à l'identique et sa place dans le bloc copié. Copier plusieurs
/// lignes ne retenait auparavant que la dernière : chaque ligne garde donc
/// ici son décalage par rapport au coin haut-gauche du bloc, ce qui permet
/// de reposer l'ensemble en conservant les interlignes.
class _LigneCopiee {
  final String texte;
  final Offset decalage;
  final Size taille;
  final bool gras;
  final bool italique;
  final PdfFontFamily famille;
  final PdfColor? couleur;
  final double? tailleManuelle;
  final double? tailleAuto;

  /// Pixels réels de la ligne (page scannée uniquement) : coller pose cette
  /// image telle quelle plutôt que de réécrire le texte, pour garder
  /// exactement la police du scan, qu'on ne saurait pas reproduire.
  final Uint8List? image;

  const _LigneCopiee({
    required this.texte,
    required this.decalage,
    required this.taille,
    required this.gras,
    required this.italique,
    required this.famille,
    required this.couleur,
    required this.tailleManuelle,
    required this.tailleAuto,
    required this.image,
  });
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

  final List<Etat> historique = [];
  final List<Etat> futur = [];

  /// Lignes mises de côté par « copier », dans l'ordre de lecture, avec la
  /// taille du bloc qu'elles formaient. Coller les repose toutes d'un coup,
  /// en gardant leurs écarts : deux lignes copiées restent deux lignes.
  final List<_LigneCopiee> lignesCopiees = [];
  Size tailleBlocCopie = Size.zero;

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

  /// Finesse du rendu de la page rafraîchi après chaque modification. Bien
  /// plus basse que celle de la reconnaissance de texte : à 300 dpi, une A4
  /// fait près de neuf millions de pixels, dont le décodage bloquait
  /// l'application assez longtemps pour qu'Android affiche « ne répond
  /// pas ». À 150 dpi l'image reste nette sur un écran de téléphone pour un
  /// quart du travail.
  static const double _dpiApercu = 150.0;

  bool _occupe = false;

  /// Ligne d'où est parti un balayage de sélection (glisser du doigt en
  /// travers de plusieurs lignes). Tant qu'il dure, le glissement choisit
  /// des lignes au lieu de déplacer la sélection.
  MotDetecte? balayageDepart;

  /// Étend la sélection à toutes les lignes comprises entre celle d'où est
  /// parti le doigt et la hauteur qu'il a atteinte. Choisir plusieurs lignes
  /// demandait jusqu'ici un double-appui sur chacune : pour un paragraphe
  /// entier, c'était intenable.
  void _etendreBalayage(double yPage) {
    final depart = balayageDepart;
    if (depart == null) return;
    final origine = depart.zone.center.dy;
    final haut = origine < yPage ? origine : yPage;
    final bas = origine < yPage ? yPage : origine;

    // Bornée à la colonne où l'on a commencé : sur un document en deux
    // colonnes, un balayage vertical aurait sinon emporté les lignes d'en
    // face, à la même hauteur mais sans rapport.
    const marge = 20.0;
    final choisies = <MotDetecte>{depart};
    for (final m in mots) {
      if (m.texte.isEmpty || m.traitsSignature != null) continue;
      final milieu = m.zone.center.dy;
      if (milieu < haut || milieu > bas) continue;
      if (m.zone.left > depart.zone.right + marge) continue;
      if (m.zone.right < depart.zone.left - marge) continue;
      choisies.add(m);
    }

    if (choisies.length == selection.length &&
        selection.containsAll(choisies)) {
      return;
    }
    setState(() {
      selection
        ..clear()
        ..addAll(choisies);
    });
  }

  /// Les outils du bord droit sont repliés par défaut derrière un seul
  /// bouton : en colonne, ils recouvraient le bord droit de la page.
  bool outilsOuverts = false;

  /// Referme l'éventail des outils après avoir lancé l'un d'eux : on a
  /// choisi, la page peut redevenir dégagée.
  VoidCallback? _outil(VoidCallback? action) {
    if (action == null) return null;
    return () {
      setState(() => outilsOuverts = false);
      action();
    };
  }

  final TransformationController _transformation = TransformationController();

  /// Page telle qu'elle était à l'ouverture, et son échelle pixels/point.
  /// Elle est gardée en réserve pour pouvoir remettre une zone abîmée dans
  /// son état d'origine sans avoir à annuler tout le travail fait depuis.
  /// Elle n'est calculée qu'à la première demande.
  img.Image? imageOrigine;
  double echelleOrigine = 1;

  /// Taille de la zone d'affichage et échelle page → écran, relevées au
  /// dernier rendu : elles disent quelle partie de la page est réellement
  /// sous les yeux, pour y poser ce qu'on ajoute plutôt qu'au petit bonheur.
  Size _tailleVue = Size.zero;
  double _echelleVue = 0;

  /// En mode navigation, le doigt fait glisser la page et les lignes ne
  /// réagissent plus ; en mode édition, le doigt sélectionne / modifie et le
  /// déplacement de la page se fait à deux doigts. Sans cette séparation, le
  /// glissement de page et les appuis sur les lignes se disputaient le geste
  /// et les appuis (dont « Supprimer ») passaient à la trappe.
  bool modeNavigation = false;

  @override
  void initState() {
    super.initState();
    _chargerPolices();
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

  /// Actions de texte pendant l'écriture sur une ligne : tout sélectionner,
  /// couper, copier, coller. Android en propose déjà, mais ses poignées et
  /// sa bulle « Copier/Coller » se dessinent dans la couche d'overlay de
  /// l'application, sans tenir compte du zoom de la page : elles
  /// atterrissaient n'importe où dès qu'on avait zoomé ou déplacé la vue, et
  /// ont donc été masquées. Elles reviennent ici, dans la barre de
  /// l'application, où leur position ne dépend de rien.
  ///
  /// Sans sélection, l'action porte sur toute la ligne — c'est ce qu'on
  /// attend quand on n'a rien surligné.
  Future<void> _actionTexte(String choix) async {
    final texte = controleurDirect.text;
    var etendue = controleurDirect.selection;
    if (!etendue.isValid) {
      etendue = TextSelection.collapsed(offset: texte.length);
    }

    if (choix == "tout") {
      setState(() {
        // Le curseur (l'extrémité mobile) est laissé au début : un champ
        // d'une seule ligne fait défiler son contenu pour montrer le
        // curseur, et le placer à la fin cachait le début de la ligne — on
        // croyait alors avoir perdu ses premiers mots.
        controleurDirect.selection =
            TextSelection(baseOffset: texte.length, extentOffset: 0);
      });
      focusDirect.requestFocus();
      return;
    }

    if (choix == "coller") {
      final donnees = await Clipboard.getData(Clipboard.kTextPlain);
      // Une ligne de PDF tient sur une seule ligne : un texte copié sur
      // plusieurs lignes ailleurs est mis bout à bout plutôt que tronqué.
      final aColler =
          (donnees?.text ?? '').replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
      if (aColler.isEmpty) {
        setState(() => statut = "Rien à coller dans le presse-papiers");
        return;
      }
      final nouveau = texte.replaceRange(etendue.start, etendue.end, aColler);
      setState(() {
        controleurDirect.value = TextEditingValue(
          text: nouveau,
          selection:
              TextSelection.collapsed(offset: etendue.start + aColler.length),
        );
      });
      focusDirect.requestFocus();
      return;
    }

    // Copier et couper : sur la sélection, ou sur toute la ligne à défaut.
    final debut = etendue.isCollapsed ? 0 : etendue.start;
    final fin = etendue.isCollapsed ? texte.length : etendue.end;
    final morceau = texte.substring(debut, fin);
    if (morceau.isEmpty) {
      setState(() => statut = "Rien à copier sur cette ligne");
      return;
    }
    await Clipboard.setData(ClipboardData(text: morceau));

    if (choix == "couper") {
      setState(() {
        controleurDirect.value = TextEditingValue(
          text: texte.replaceRange(debut, fin, ''),
          selection: TextSelection.collapsed(offset: debut),
        );
        statut = "Coupé — collez où vous voulez";
      });
    } else {
      setState(() => statut = "Copié — collez où vous voulez");
    }
    focusDirect.requestFocus();
  }

  /// Bouton d'une bulle de sélection : une icône claire sur fond sombre.
  Widget _boutonBulle(IconData icone, String infobulle, VoidCallback action) {
    return IconButton(
      icon: Icon(icone, size: 20),
      color: Colors.white,
      tooltip: infobulle,
      visualDensity: VisualDensity.compact,
      onPressed: action,
    );
  }

  /// Bulle qui apparaît sur une sélection de texte, à la place de celle
  /// d'Android. Celle du téléphone occupait toute la largeur de l'écran,
  /// en anglais, avec des entrées qui n'ont rien à faire ici (« Share »,
  /// « Demander à Copilot », « Lire à voix haute »). Celle-ci tient en cinq
  /// icônes sur un fond sombre, comme la barre d'actions d'une ligne
  /// sélectionnée : même langage visuel d'un bout à l'autre de
  /// l'application.
  Widget _bulleSelection(BuildContext context, EditableTextState champ) {
    final reperes = champ.contextMenuAnchors;
    return TextSelectionToolbar(
      anchorAbove: reperes.primaryAnchor,
      anchorBelow: reperes.secondaryAnchor ?? reperes.primaryAnchor,
      toolbarBuilder: (context, contenu) => Material(
        color: const Color(0xFF2E2E2E),
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        elevation: 4,
        child: contenu,
      ),
      children: [
        _boutonBulle(Icons.content_copy, "Copier", () {
          champ.copySelection(SelectionChangedCause.toolbar);
        }),
        _boutonBulle(Icons.content_cut, "Couper", () {
          champ.cutSelection(SelectionChangedCause.toolbar);
        }),
        _boutonBulle(Icons.content_paste, "Coller", () {
          champ.pasteText(SelectionChangedCause.toolbar);
        }),
        _boutonBulle(Icons.select_all, "Tout sélectionner", () {
          champ.selectAll(SelectionChangedCause.toolbar);
        }),
        _boutonBulle(Icons.delete_outline, "Supprimer", () {
          final texte = controleurDirect.text;
          final etendue = controleurDirect.selection;
          // Rien de surligné : la corbeille vide toute la ligne, comme
          // celle de la barre du haut.
          final debut =
              (etendue.isValid && !etendue.isCollapsed) ? etendue.start : 0;
          final fin = (etendue.isValid && !etendue.isCollapsed)
              ? etendue.end
              : texte.length;
          setState(() {
            controleurDirect.value = TextEditingValue(
              text: texte.replaceRange(debut, fin, ''),
              selection: TextSelection.collapsed(offset: debut),
            );
          });
          champ.hideToolbar();
        }),
      ],
    );
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
    // Une zone de texte qu'on a soi-même ajoutée disparaît entièrement
    // quand on la supprime : il n'y a pas de ligne du document en dessous
    // à laquelle son cadre servirait encore.
    if (mot.boiteLibre && mounted) _retirerRepere(mot);
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
    const dpi = _dpiApercu;
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
    });
    await _poserSignatureChoisie(normalises, ratio);
  }

  /// Pose la signature choisie immédiatement, au milieu de ce qu'on a sous
  /// les yeux, et la sélectionne : elle apparaît dans le document dès qu'on
  /// l'a choisie, déjà entourée de ses quatre poignées, prête à être tirée
  /// où l'on veut. Il fallait auparavant la choisir puis viser un endroit de
  /// la page — un geste de plus, que rien n'annonçait, et qui donnait
  /// l'impression que le choix n'avait pas été pris en compte.
  Future<void> _poserSignatureChoisie(
      List<List<Offset>> traits, double ratio) async {
    setState(() {
      signatureNormalisee = traits;
      signatureRatio = ratio;
      enCollage = false;
      enAjoutTexte = false;
    });
    final centre = _centreVisible();
    await _poserSignature(centre.dx, centre.dy);
  }

  /// Milieu de la partie de la page réellement visible, en points PDF : si
  /// la page est zoomée ou défilée, ce qu'on ajoute doit apparaître là où
  /// l'on regarde, pas en haut d'une page qu'il faudrait aller rechercher.
  Offset _centreVisible() {
    final milieuPage = Offset(taillePage.width / 2, taillePage.height / 2);
    final echelle = _echelleVue;
    if (echelle <= 0 || _tailleVue.isEmpty) return milieuPage;
    final matrice = _transformation.value;
    final zoom = matrice.getMaxScaleOnAxis();
    if (zoom <= 0) return milieuPage;
    final x = (_tailleVue.width / 2 - matrice.storage[12]) / (zoom * echelle);
    final y = (_tailleVue.height / 2 - matrice.storage[13]) / (zoom * echelle);
    if (x.isNaN || y.isNaN) return milieuPage;
    return Offset(
      x.clamp(0.0, taillePage.width),
      y.clamp(0.0, taillePage.height),
    );
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
                    _poserSignatureChoisie(sig.traits, sig.ratio);
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
    final k = _echelleTraits(traits, zone.size);
    final stylo = PdfPen(PdfColor(0, 0, 0), width: k * 0.006);
    for (final trait in traits) {
      for (var i = 0; i + 1 < trait.length; i++) {
        page.graphics.drawLine(
          stylo,
          Offset(zone.left + trait[i].dx * k, zone.top + trait[i].dy * k),
          Offset(
              zone.left + trait[i + 1].dx * k, zone.top + trait[i + 1].dy * k),
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
      if (traits != null) hauteur = largeur * mot.ratioSignature;
    }
    if (haut + hauteur > taillePage.height) {
      hauteur = taillePage.height - haut;
      // Une signature garde ses proportions même contre le bord : sans ça,
      // le cadre s'écrasait et le tracé en débordait.
      if (traits != null && mot.ratioSignature > 0) {
        largeur = hauteur / mot.ratioSignature;
      }
    }
    if (largeur < mini || hauteur < mini) return;

    final nouvelle = Rect.fromLTWH(gauche, haut, largeur, hauteur);
    if ((nouvelle.width - mot.zone.width).abs() < 0.5 &&
        (nouvelle.height - mot.zone.height).abs() < 0.5 &&
        (nouvelle.left - mot.zone.left).abs() < 0.5 &&
        (nouvelle.top - mot.zone.top).abs() < 0.5) {
      return;
    }

    // Une signature flotte au-dessus de la page jusqu'à l'enregistrement :
    // la redimensionner ne fait que changer son cadre. C'est instantané, et
    // surtout ça n'efface rien. Quand elle était écrite dans le PDF dès sa
    // pose, il fallait repeindre l'ancienne place à chaque geste, et ce coup
    // de blanc emportait tout ce qui se trouvait entre les deux tailles —
    // titres et débuts de lignes du document disparaissaient pour de bon.
    if (traits != null) {
      final avant = await _etatActuel(doc);
      setState(() {
        historique.add(avant);
        futur.clear();
        mot.zone = nouvelle;
        statut = "Signature redimensionnée";
      });
      return;
    }

    // Un repère vide n'a rien dans la page : son cadre seul change.
    if (mot.texte.isEmpty) {
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
      // On efface l'ancienne place, et elle seule : le nouveau texte est
      // dessiné par-dessus ce qui reste. Effacer aussi la nouvelle place,
      // comme on le faisait, revenait à repeindre tout l'espace entre les
      // deux — et à emporter le contenu du document qui s'y trouvait.
      _effacerRect(page, _rectEffacement(mot), mot);

      final tailleActuelle = _dessinTexte(mot, mot.zone).police.size;
      final facteur =
          mot.zone.width <= 0 ? 1.0 : nouvelle.width / mot.zone.width;
      mot.zone = nouvelle;
      mot.tailleManuelle = (tailleActuelle * facteur).clamp(4.0, 96.0);
      _ecrire(page, mot, mot.zone);

      setState(() => statut = "Ligne redimensionnée");
      if (imageDeFond != null) await _rafraichirApercuOcr(doc);
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

  /// Pose la signature sur la page. Elle n'est pas écrite dans le PDF :
  /// elle y flotte au-dessus jusqu'à l'enregistrement. C'est ce qui permet
  /// de la déplacer et de la redimensionner autant qu'on veut sans jamais
  /// rien abîmer — l'écrire tout de suite obligeait, à chaque geste, à
  /// repeindre sa place d'avant, et ce coup de blanc emportait le texte du
  /// document qui se trouvait dessous ou entre les deux positions.
  Future<void> _poserSignature(double x, double y) async {
    final traits = signatureNormalisee;
    final doc = document;
    if (traits == null || doc == null || _occupe) return;
    setState(() => _occupe = true);
    final avant = await _etatActuel(doc);
    try {
      historique.add(avant);
      futur.clear();

      var largeur = taillePage.width * 0.28;
      var hauteur = largeur * signatureRatio;
      // Une signature ne doit pas manger la page. Un paraphe haut et étroit
      // donnait, à 28 % de la largeur, un cadre de près d'un tiers de la
      // hauteur de la feuille, posé par-dessus le texte. Sa hauteur est donc
      // bornée au dixième de la page, et la largeur suit pour garder les
      // proportions du tracé.
      final hauteurMax = taillePage.height * 0.10;
      if (hauteur > hauteurMax && signatureRatio > 0) {
        hauteur = hauteurMax;
        largeur = hauteur / signatureRatio;
      }
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

      final zone = Rect.fromLTWH(gauche, haut, largeur, hauteur);
      final posee = MotDetecte("", zone,
          traitsSignature: traits, ratioSignature: signatureRatio);
      setState(() {
        mots.add(posee);
        // Sélectionnée d'emblée : ses poignées et sa barre d'actions sont
        // là tout de suite, sans avoir à deviner qu'il faut d'abord la
        // toucher pour pouvoir la déplacer ou la redimensionner.
        selection
          ..clear()
          ..add(posee);
        statut = "Signature posée — tirez-la où vous voulez, les coins pour la taille";
      });

      // Rien n'a été écrit dans la page : inutile d'en refaire le rendu.
      if (imageDeFond == null) await _activerApercuImage(doc);
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
      imageOrigine = null;
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
      // On ne quitte la lecture que si l'analyse a bien trouvé des lignes :
      // sinon il n'y aurait rien à modifier, et l'écran resterait vide.
      modeLecture = mots.isEmpty;
      _occupe = false;
    });
  }

  Future<void> _analyser(Uint8List octets) async {
    // Les polices embarquées doivent être là avant la calibration des
    // lignes : c'est avec elles qu'on mesure la place que prendra un texte
    // réécrit, et les mesurer avec une autre fausserait tous les cadres.
    await _chargerPolices();
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
        // Même un document au vrai texte a besoin de l'image de sa page :
        // c'est elle qui dit de quelle couleur est le papier juste à côté
        // d'une ligne, donc avec quoi l'effacer. Sans elle, l'application
        // devait deviner, et se trompait — d'où le rectangle noir à la
        // place d'une ligne supprimée. Elle sert aussi à afficher la page
        // telle qu'elle est vraiment, couleurs et photos comprises.
        await _activerApercuImage(doc);
        // L'extraction de texte donne la police, la taille et le gras, mais
        // pas la couleur de l'encre. On la relève sur l'image de la page,
        // comme pour un scan : sans elle, une ligne grise ou orange
        // repassait en noir dès la première modification, ce qui se voyait
        // immédiatement dans un document mis en forme.
        if (imageDecodee != null) {
          // Hors setState : l'affichage d'une ligne intacte vient de l'image
          // de la page, pas de cette couleur — elle ne servira qu'au moment
          // de la réécrire. Inutile de reconstruire l'écran pour chacune.
          for (final ligne in mots) {
            ligne.couleurTexte ??= _couleurEncre(ligne.zone);
          }
        }
        return;
      }

      setState(() => statut = "Page scannée détectée, analyse OCR en cours...");
      await _analyserParOcr(doc, page);
    } catch (e) {
      // Aucune analyse ne doit laisser l'application sur un rond qui tourne
      // sans fin : on revient à la lecture, où le document reste consultable
      // et où le bouton « modifier » permet de réessayer.
      setState(() {
        modeLecture = true;
        statut = "Analyse impossible ($e) — document ouvert en lecture seule";
      });
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
        ligne.depuisOcr = true;
      }

      setState(() {
        document = doc;
        mots = fusionnees;
        taillePage = Size(page.size.width, page.size.height);
        imageDeFond = pngOctets;
        imageDecodee = imageAnalysee;
        echelleOcr = echelle;
        selection.clear();
        statut = "${fusionnees.length} ligne(s) détectée(s) (OCR)";
      });
    } catch (_) {
      // Remontée à l'appelant, qui remet le document en lecture plutôt que
      // de laisser un écran de chargement sans fin.
      rethrow;
    } finally {
      await recognizer?.close();
    }
  }

  Future<void> _rafraichirApercuOcr(PdfDocument doc) async {
    const dpi = _dpiApercu;
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
        echelleOcr = dpi / 72.0;
      });
    } catch (e) {
      // Ne plus avaler l'erreur en silence : refaire l'image de la page
      // passe par un enregistrement du document, si bien qu'un échec ici
      // annonce un échec à l'enregistrement. Le taire faisait découvrir le
      // problème beaucoup trop tard, au moment de partager le fichier.
      if (mounted) {
        setState(() => statut = "Aperçu non rafraîchi : $e");
      }
    }
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

  /// Couleur du papier autour d'une zone. À défaut, du blanc — et non la
  /// couleur dominante de la page : sur un document à large bandeau de
  /// couleur, cette dominante est celle du bandeau, et « effacer » une ligne
  /// posait une barre sombre en travers du texte.
  PdfColor _couleurLocale(Rect zonePdf) {
    final fond = _fondAutour(zonePdf);
    if (fond == null) return PdfColor(255, 255, 255);
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

  /// Fichiers des polices embarquées, chargés une fois au démarrage. Les
  /// polices standard d'un PDF (Helvetica, Times, Courier) ne connaissent
  /// que le jeu latin de Windows : un tiret cadratin, une puce ronde ou une
  /// apostrophe typographique — ce qu'un traitement de texte met tout seul —
  /// n'y existent pas. Les Liberation, elles, les ont, et sont dessinées aux
  /// mêmes largeurs qu'Arial, Times New Roman et Courier New : une ligne
  /// réécrite garde donc ses caractères et occupe la même place qu'avant.
  static const Map<PdfFontFamily, Map<PdfFontStyle, String>> _fichiersPolice = {
    PdfFontFamily.helvetica: {
      PdfFontStyle.regular: 'assets/fonts/LiberationSans-Regular.ttf',
      PdfFontStyle.bold: 'assets/fonts/LiberationSans-Bold.ttf',
      PdfFontStyle.italic: 'assets/fonts/LiberationSans-Italic.ttf',
    },
    PdfFontFamily.timesRoman: {
      PdfFontStyle.regular: 'assets/fonts/LiberationSerif-Regular.ttf',
      PdfFontStyle.bold: 'assets/fonts/LiberationSerif-Bold.ttf',
      PdfFontStyle.italic: 'assets/fonts/LiberationSerif-Italic.ttf',
    },
    PdfFontFamily.courier: {
      PdfFontStyle.regular: 'assets/fonts/LiberationMono-Regular.ttf',
      PdfFontStyle.bold: 'assets/fonts/LiberationMono-Bold.ttf',
      PdfFontStyle.italic: 'assets/fonts/LiberationMono-Italic.ttf',
    },
  };

  /// Octets des polices, une fois lus. Vide tant que le chargement n'a pas
  /// eu lieu (ou s'il a échoué) : on retombe alors sur les polices standard,
  /// et l'application marche comme avant.
  final Map<String, Uint8List> _octetsPolice = {};

  /// Polices déjà construites, par fichier et par taille : construire une
  /// police TrueType relit tout le fichier, et une seule ligne en demande
  /// plusieurs (mesure, ajustement, dessin).
  final Map<String, PdfFont> _policesPretes = {};

  /// Document auquel appartiennent les polices déjà construites. Une police
  /// embarquée s'attache au document dans lequel on l'a d'abord dessinée :
  /// la réutiliser dans un autre (après un annuler, qui recharge le
  /// document entier) produisait un fichier bancal, et l'enregistrement
  /// échouait sur « Null check operator used on a null value ».
  PdfDocument? _documentDesPolices;

  bool _policesChargees = false;

  Future<void> _chargerPolices() async {
    if (_policesChargees) return;
    _policesChargees = true;
    for (final famille in _fichiersPolice.values) {
      for (final chemin in famille.values) {
        if (_octetsPolice.containsKey(chemin)) continue;
        try {
          final donnees = await rootBundle.load(chemin);
          _octetsPolice[chemin] = donnees.buffer.asUint8List();
        } catch (_) {
          // Police absente ou illisible : on s'en passe pour celle-là.
        }
      }
    }
  }

  PdfFont _police(MotDetecte mot, [double? taille]) {
    // Un seul style à la fois : le gras l'emporte sur l'italique quand les
    // deux sont détectés, ce qui reste plus proche de l'original que de
    // perdre les deux.
    final style = mot.gras
        ? PdfFontStyle.bold
        : (mot.italique ? PdfFontStyle.italic : PdfFontStyle.regular);
    var corps = taille ?? mot.zone.height * 0.75;
    if (corps <= 0 || corps.isNaN) corps = 12;
    // Arrondi au dixième de point : construire une police TrueType relit
    // tout son fichier, et les tailles calculées tombent sinon sur des
    // valeurs toutes différentes qui ne se réutiliseraient jamais. Un
    // vingtième de point ne se voit pas.
    corps = (corps * 10).roundToDouble() / 10;

    if (!identical(_documentDesPolices, document)) {
      _policesPretes.clear();
      _documentDesPolices = document;
    }

    final chemin = _fichiersPolice[mot.famille]?[style];
    final octets = chemin == null ? null : _octetsPolice[chemin];
    if (octets != null) {
      final cle = "$chemin|$corps";
      final deja = _policesPretes[cle];
      if (deja != null) return deja;
      try {
        final police = PdfTrueTypeFont(octets, corps);
        // Un document long finirait par en accumuler des centaines : on
        // repart de zéro plutôt que de laisser la mémoire enfler.
        if (_policesPretes.length > 400) _policesPretes.clear();
        _policesPretes[cle] = police;
        return police;
      } catch (_) {
        // Police refusée par le moteur PDF : on continue avec la standard.
      }
    }
    return PdfStandardFont(mot.famille, corps, style: style);
  }

  /// Texte à écrire avec cette police-là. Une police embarquée sait tout
  /// écrire ; une police standard non, et il faut alors remplacer ce qu'elle
  /// ne connaît pas plutôt que de la laisser échouer.
  String _texteSelonPolice(PdfFont police, String texte) =>
      police is PdfTrueTypeFont ? texte : _texteEcrivable(texte);

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
  /// Équivalents pour les caractères que les polices standard d'un PDF ne
  /// savent pas écrire. Elles se limitent au jeu latin de Windows :
  /// apostrophe typographique, tiret cadratin, puce ronde, points de
  /// suspension — tout ce qu'un traitement de texte met sans qu'on le
  /// demande — les faisaient lever « The character is not supported by the
  /// font ». Cette erreur interrompait l'analyse entière du document et
  /// laissait l'application sur un écran de chargement sans fin.
  static const Map<int, String> _equivalentsPolice = {
    0x2018: "'", 0x2019: "'", 0x201A: "'", 0x201B: "'", 0x2032: "'",
    0x201C: '"', 0x201D: '"', 0x201E: '"', 0x201F: '"', 0x2033: '"',
    0x2010: '-', 0x2011: '-', 0x2012: '-', 0x2013: '-', 0x2014: '-',
    0x2015: '-', 0x2212: '-', 0x00AD: '-',
    0x2022: '-', 0x2023: '-', 0x25AA: '-', 0x25CF: '-', 0x25E6: '-',
    0x00B7: '.', 0x2026: '...', 0x2044: '/',
    0x00A0: ' ', 0x2007: ' ', 0x2009: ' ', 0x202F: ' ', 0x2060: '',
    0x200B: '', 0xFEFF: '',
    0x20AC: 'EUR', 0x2122: 'TM', 0x2039: '<', 0x203A: '>',
    0x0152: 'OE', 0x0153: 'oe', 0x0178: 'Y', 0x0160: 'S', 0x0161: 's',
    0x017D: 'Z', 0x017E: 'z', 0x0192: 'f', 0x02C6: '^', 0x02DC: '~',
    0x2020: '+', 0x2021: '+', 0x2030: '%%', 0x2116: 'No',
  };

  /// Texte tel qu'on peut l'écrire dans le PDF avec une police standard.
  /// Ce qui n'a pas d'équivalent connu et sort du jeu latin est retiré :
  /// mieux vaut une ligne à laquelle il manque un signe rare qu'un document
  /// entier qu'on ne peut plus ouvrir.
  String _texteEcrivable(String texte) {
    if (texte.codeUnits.every((c) => c >= 0x20 && c <= 0x7E)) return texte;
    final tampon = StringBuffer();
    for (final rune in texte.runes) {
      final equivalent = _equivalentsPolice[rune];
      if (equivalent != null) {
        tampon.write(equivalent);
      } else if (rune == 0x09 || rune == 0x0A || rune == 0x0D) {
        tampon.write(' ');
      } else if (rune >= 0x20 && rune <= 0xFF && rune != 0x7F) {
        tampon.writeCharCode(rune);
      }
    }
    return tampon.toString();
  }

  double? _tailleParLargeur(MotDetecte mot) {
    if (mot.texte.trim().isEmpty || mot.zone.width <= 0) return null;
    const reference = 20.0;
    // Une mesure ne doit jamais faire échouer l'ouverture d'un document :
    // au pire on se passe de la calibration pour cette ligne.
    double largeur;
    try {
      final police = _police(mot, reference);
      largeur = police.measureString(_texteSelonPolice(police, mot.texte)).width;
    } catch (_) {
      return null;
    }
    if (largeur <= 0) return null;
    final taille = reference * mot.zone.width / largeur;
    if (taille < 4 || taille > 96) return null;
    return taille;
  }

  ({Rect rect, PdfFont police}) _dessinTexte(MotDetecte mot, Rect zone) {
    // La taille calibrée sur la largeur du cadre (voir mot.tailleAuto) prime
    // sur l'estimation par la hauteur, qui donnait un texte trop gros.
    final tailleDepart = mot.tailleManuelle ?? mot.tailleAuto;
    var police = _police(mot, tailleDepart ?? zone.height * 0.75);
    // Mesuré sur le texte tel qu'il sera écrit dans le PDF : avec une police
    // embarquée c'est le texte tel quel, avec une police standard c'est sa
    // version dépouillée des caractères qu'elle ne sait pas écrire.
    var texte = _texteSelonPolice(police, mot.texte);
    var mesure = police.measureString(texte);

    if (tailleDepart == null && mesure.height > 0 && zone.height > 0) {
      var taille = police.size * zone.height / mesure.height * 1.15;
      // Garde-fou : un calcul aberrant (mesure dégénérée) donnerait sinon
      // une police gigantesque, qui a déjà fait échouer le dessin en
      // silence, laissant un cadre effacé sans texte.
      if (taille < 4) taille = 4;
      if (taille > 96) taille = 96;
      police = _police(mot, taille);
      texte = _texteSelonPolice(police, mot.texte);
      mesure = police.measureString(texte);
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
      texte = _texteSelonPolice(police, mot.texte);
      mesure = police.measureString(texte);
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

  /// Rectangle occupé à l'écran par une ligne. Au repos, c'est exactement la
  /// place qu'elle occupe dans le PDF : l'aperçu de la page étant rafraîchi
  /// après chaque modification, l'écran n'a plus rien à deviner ni à
  /// recouvrir, et le cadre ne s'allonge donc plus tout seul dès qu'on
  /// touche une ligne. Pendant la frappe, en revanche, il suit le texte
  /// tapé : sans ça la fin de la ligne sortirait du champ et serait coupée.
  Rect _rectAffichage(MotDetecte mot, double echelle) {
    // Pendant qu'on tire une poignée, le cadre (et donc ce qu'il contient)
    // suit le doigt : on voit la taille qu'on obtiendra avant de lâcher.
    final vise = motRedimensionne == mot ? rectRedimension : null;
    if (vise != null) return vise;
    if (motEnEditionDirecte != mot) return _rectContenu(mot);

    final texte = controleurDirect.text;
    if (texte.isEmpty || echelle <= 0) return _rectContenu(mot);

    // Mesure avec la police d'écran (celle du téléphone), et non celle du
    // PDF : les deux n'ont pas les mêmes largeurs de caractères, et se fier
    // à celle du PDF laissait la fin de la ligne dépasser du cadre, donc
    // coupée à l'affichage.
    final peintre = TextPainter(
      text: TextSpan(
        text: texte,
        style: TextStyle(
          fontSize: _tailleEditionDirecte(mot) * echelle,
          height: 1.0,
          fontWeight: grasDirect ? FontWeight.bold : FontWeight.normal,
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

    return Rect.fromLTWH(
      mot.zone.left,
      mot.zone.center.dy - hauteur / 2,
      largeur,
      hauteur,
    );
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

  /// Rectangle exactement couvert par la découpe de [zone] dans l'image de
  /// la page. Une découpe se fait en pixels entiers, alors que le rectangle
  /// demandé, lui, tombe entre deux pixels : reposer l'un dans l'autre
  /// agrandissait le contenu d'une fraction de pour cent. Invisible une
  /// fois — mais chaque déplacement repart de l'image du déplacement
  /// précédent, et l'erreur se multipliait à chaque appui sur une flèche,
  /// jusqu'à ce que la ligne sorte de son cadre. En calant le rectangle sur
  /// les pixels avant tout le reste, la repose est exacte.
  Rect? _zoneAlignee(Rect zone) {
    final image = imageDecodee;
    final e = echelleOcr;
    if (image == null || e <= 0) return null;
    final x = (zone.left * e).round().clamp(0, image.width - 1);
    final y = (zone.top * e).round().clamp(0, image.height - 1);
    final largeur = (zone.width * e).round().clamp(1, image.width - x);
    final hauteur = (zone.height * e).round().clamp(1, image.height - y);
    return Rect.fromLTWH(x / e, y / e, largeur / e, hauteur / e);
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
          final octets = img.encodePng(_surFondBlanc(bande));
          // Relecture de contrôle, comme pour une capture : un PNG que le
          // moteur PDF n'accepte pas ne se signale qu'au moment du dessin,
          // trop tard pour être rattrapé — et laisse un rectangle noir à la
          // place de la ligne effacée. On préfère alors l'aplat de couleur.
          final relu = img.decodePng(octets);
          if (relu == null ||
              relu.width != largeur ||
              relu.height != hauteurBande) {
            return null;
          }
          return PdfBitmap(octets);
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
      _texteSelonPolice(dessin.police, mot.texte),
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
            traitsSignature: m.traitsSignature,
            ratioSignature: m.ratioSignature,
            depuisOcr: m.depuisOcr,
            pixelsSource: m.pixelsSource,
            tailleSource: m.tailleSource,
            decalageSource: m.decalageSource))
        .toList();
    return Etat(octetsDocument, motsCopie, imageDeFond, echelleOcr);
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
              traitsSignature: m.traitsSignature,
              ratioSignature: m.ratioSignature,
              depuisOcr: m.depuisOcr,
              pixelsSource: m.pixelsSource,
              tailleSource: m.tailleSource,
              decalageSource: m.decalageSource))
          .toList();
      imageDeFond = etat.image;
      imageDecodee = etat.image != null ? img.decodePng(etat.image!) : null;
      echelleOcr = etat.echelleImage;
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
      // Les signatures posées font partie de la page qu'on fige : elles
      // entrent donc dans l'image, et leurs cadres flottants disparaissent.
      final octetsDoc = Uint8List.fromList(await _octetsAvecSignatures(doc));
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
        mots = mots.where((m) => m.traitsSignature == null).toList();
        selection.removeWhere((m) => m.traitsSignature != null);
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
      // Son texte a changé : la photo gardée de ses pixels d'origine ne lui
      // correspond plus, elle sera réécrite désormais.
      mot.pixelsSource = null;
      mot.tailleSource = null;
      mot.decalageSource = null;
      mot.tailleManuelle = tailleFinale;
      mot.alignement = alignementFinal;
      if (texteNettoye.isEmpty) mot.redessine = false;
      _ecrire(page, mot, mot.zone);

      setState(() {
        if (texteNettoye.isEmpty) selection.remove(mot);
      });

      // La page affichée est réellement celle du PDF : on la redemande après
      // chaque modification. La recouvrir à l'écran d'un rectangle de la
      // couleur du papier avec le texte par-dessus, comme on le faisait pour
      // éviter ce rendu, cachait ce qui dépassait du rectangle — d'où des
      // fins de lignes qui « disparaissaient » à l'écran alors qu'elles
      // étaient bien dans le document. Le rendu est maintenant assez léger
      // (voir _dpiApercu) pour être refait à chaque fois.
      if (imageDeFond != null) await _rafraichirApercuOcr(doc);
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

  Rect _aligner(Rect rect) => _zoneAlignee(rect) ?? rect;

  /// Place qu'occupe dans la page la photo gardée d'une ligne scannée.
  Rect _placeSource(MotDetecte mot) {
    final taille = mot.tailleSource;
    final decalage = mot.decalageSource;
    if (taille == null || decalage == null) return mot.zone;
    return Rect.fromLTWH(
      mot.zone.left + decalage.dx,
      mot.zone.top + decalage.dy,
      taille.width,
      taille.height,
    );
  }

  /// Déplace une signature posée. Elle flotte au-dessus de la page jusqu'à
  /// l'enregistrement : la déplacer ne fait donc que changer son cadre —
  /// instantané, et sans rien effacer sur son passage. Elle glisse librement
  /// et s'arrête au bord de la page.
  Future<void> _deplacerSignature(
      MotDetecte mot, double dx, double dy) async {
    final traits = mot.traitsSignature;
    final doc = document;
    if (traits == null || doc == null || _occupe) return;

    final ancienne = mot.zone;
    var gauche = ancienne.left + dx;
    var haut = ancienne.top + dy;
    if (gauche < 0) gauche = 0;
    if (haut < 0) haut = 0;
    if (gauche + ancienne.width > taillePage.width) {
      gauche = taillePage.width - ancienne.width;
    }
    if (haut + ancienne.height > taillePage.height) {
      haut = taillePage.height - ancienne.height;
    }
    final nouvelle =
        Rect.fromLTWH(gauche, haut, ancienne.width, ancienne.height);
    if ((nouvelle.left - ancienne.left).abs() < 0.5 &&
        (nouvelle.top - ancienne.top).abs() < 0.5) {
      setState(() => statut = "C'est déjà le bord de la page");
      return;
    }

    final avant = await _etatActuel(doc);
    setState(() {
      historique.add(avant);
      futur.clear();
      mot.zone = nouvelle;
      statut = "Signature déplacée";
    });
  }

  /// Déplace ensemble une ou plusieurs lignes choisies (sélection multiple),
  /// avec exactement la même logique que le déplacement d'une seule ligne :
  /// chacune emmène ce qui est sur sa rangée, pousse les voisines gênantes,
  /// et tout est annulé si quoi que ce soit échoue.
  Future<void> _deplacerGroupe(
      List<MotDetecte> lignesPrincipales, double dx, double dy) async {
    if (dx == 0 && dy == 0 || lignesPrincipales.isEmpty) return;
    final doc = document;
    if (doc == null || _occupe) return;
    // Une signature n'est pas une ligne de texte : elle n'a pas de voisines
    // à bousculer ni de puce à emmener, et son encre est du tracé qu'on
    // refait plutôt que de la photographier. Elle a donc son propre
    // déplacement, bien plus simple — et surtout qui aboutit.
    if (lignesPrincipales.length == 1 &&
        lignesPrincipales.first.traitsSignature != null) {
      return _deplacerSignature(lignesPrincipales.first, dx, dy);
    }
    // Chaque ligne emmène avec elle ce qui est sur sa rangée : un tiret ou
    // une puce détectés à part restaient sinon en arrière.
    final groupe = <MotDetecte>{
      ...lignesPrincipales,
      for (final principal in lignesPrincipales)
        ...mots.where(
            (m) => m != principal && _memeRangee(m.zone, principal.zone)),
    }.toList();

    final vises = <MotDetecte, Offset>{
      for (final m in groupe) m: Offset(dx, dy),
      for (final m in _lignesPoussees(groupe, dx, dy)) m: Offset(0, dy),
    };

    // Un seul rectangle par ligne, calculé une fois : photographie,
    // effacement et repose doivent porter exactement sur le même, sinon on
    // efface plus qu'on n'emporte. Il est élargi vers la gauche pour
    // embarquer un tiret ou une puce que l'OCR n'a pas rattachés à la ligne.
    // Calé sur les pixels de l'image : photographie, effacement et repose
    // portent alors sur exactement le même rectangle, et le contenu revient
    // à sa taille d'origine au lieu de grandir d'un poil à chaque appui.
    final rects = <MotDetecte, Rect>{
      for (final m in vises.keys)
        m: _aligner(_etendreVersPuce(_rectDeplacement(m))),
    };

    // Rien ne doit finir hors de la page. Plutôt que de refuser tout le
    // déplacement — au doigt, on ne comprenait pas pourquoi la sélection
    // refusait de bouger —, on le raccourcit juste assez : le doigt glisse
    // et l'objet s'arrête au bord, comme partout ailleurs.
    var dxOk = dx;
    var dyOk = dy;
    for (final entree in vises.entries) {
      final r = rects[entree.key]!;
      if (entree.value.dx != 0) {
        if (r.left + dxOk < 0) dxOk = -r.left;
        if (r.right + dxOk > taillePage.width) {
          dxOk = taillePage.width - r.right;
        }
      }
      if (r.top + dyOk < 0) dyOk = -r.top;
      if (r.bottom + dyOk > taillePage.height) {
        dyOk = taillePage.height - r.bottom;
      }
    }
    // Une ligne plus grande que la page ferait repartir la correction dans
    // l'autre sens : mieux vaut alors ne pas bouger de cet axe.
    if (dxOk.sign != dx.sign) dxOk = 0;
    if (dyOk.sign != dy.sign) dyOk = 0;
    if (dxOk == 0 && dyOk == 0) {
      setState(() => statut = "C'est déjà le bord de la page");
      return;
    }

    final deplacements = <MotDetecte, Offset>{
      for (final entree in vises.entries)
        entree.key: Offset(entree.value.dx == 0 ? 0.0 : dxOk, dyOk),
    };

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
      // Seule une ligne scannée est déplacée en photo : d'elle, on ne
      // connaît ni la police ni la taille réelles. Une ligne venue du texte
      // du PDF est réécrite — on en connaît la police, le corps, la graisse
      // et la couleur —, ce qui reste net à tous les zooms au lieu de pâlir
      // à chaque déplacement.
      final captures = <MotDetecte, Uint8List?>{};
      for (final m in deplacements.keys) {
        if (m.texte.isEmpty || m.redessine || !m.depuisOcr) {
          captures[m] = null;
          continue;
        }
        // La photo n'est prise qu'une fois, au premier déplacement, et
        // reposée telle quelle ensuite : la reprendre à chaque fois
        // repartait de l'image du déplacement précédent, et le texte
        // perdait un cran de netteté par appui.
        if (m.pixelsSource == null) {
          final photo = _capturerZone(rects[m]!);
          if (photo != null) {
            m.pixelsSource = photo;
            m.tailleSource = rects[m]!.size;
            m.decalageSource = rects[m]!.topLeft - m.zone.topLeft;
          }
        }
        captures[m] = m.pixelsSource;
      }

      // La place occupée par la photo, relevée avant de bouger les cadres.
      final places = <MotDetecte, Rect>{
        for (final m in deplacements.keys) m: _placeSource(m),
      };

      for (final m in deplacements.keys) {
        if (m.texte.isEmpty) continue;
        var aEffacer = rects[m]!;
        if (captures[m] != null) {
          aEffacer = aEffacer.expandToInclude(places[m]!);
        }
        _effacerRect(page, aEffacer, m);
      }

      for (final entree in deplacements.entries) {
        final m = entree.key;
        if (m.texte.isEmpty) continue;
        final capture = captures[m];
        if (capture != null) {
          page.graphics
              .drawImage(PdfBitmap(capture), places[m]!.shift(entree.value));
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

  /// Pose une zone de texte libre là où l'on a touché et ouvre directement
  /// sa modification. Le cadre est posé autour du doigt et le texte y est
  /// centré : ce qu'on écrit apparaît donc à l'endroit visé. Il gardait
  /// auparavant toute la largeur de la page, si bien qu'un texte centré
  /// atterrissait au milieu de la page et non sous le doigt.
  ///
  /// Le cadre reste ensuite en place tant qu'on ne le retire pas soi-même
  /// (corbeille de la barre, ou « Retirer tous les cadres vides ») : on peut
  /// le déplacer, l'étirer par ses coins, et y écrire plus tard.
  Future<void> _ajouterTexte(double xPage, double yPage) async {
    if (document == null || _occupe) return;

    const marge = 24.0;
    const hauteur = 18.0;
    final utile = taillePage.width - marge * 2;
    // La moitié de la largeur utile : assez large pour une phrase, assez
    // étroit pour qu'on voie où elle va se poser. Les poignées des coins
    // permettent de l'ajuster ensuite.
    var largeur = utile / 2;
    if (largeur < 40) largeur = utile;
    var gauche = xPage - largeur / 2;
    if (gauche < marge) gauche = marge;
    if (gauche + largeur > taillePage.width - marge) {
      gauche = taillePage.width - marge - largeur;
    }
    var haut = yPage - hauteur / 2;
    if (haut < 0) haut = 0;
    if (haut + hauteur > taillePage.height) {
      haut = taillePage.height - hauteur;
    }

    final nouvelleLigne = MotDetecte(
      "",
      Rect.fromLTWH(gauche, haut, largeur, hauteur),
      boiteLibre: true,
      alignement: PdfTextAlignment.center,
    );

    setState(() {
      mots = [...mots, nouvelleLigne];
      selection
            ..clear()
            ..add(nouvelleLigne);
      enAjoutTexte = false;
    });

    await _modifierMot(nouvelleLigne);
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
  ///
  /// Un cadre étiré à la main peut couvrir un quart de la page. Passer la
  /// gomme dessus recouvrait alors tout ce qui s'y trouvait — plusieurs
  /// paragraphes d'un coup — sans rien demander, et il n'y paraissait plus
  /// qu'un grand blanc. Au-delà d'une zone de la taille de quelques lignes,
  /// on demande donc confirmation.
  Future<void> _effacerZone(MotDetecte mot) async {
    final doc = document;
    if (doc == null || _occupe) return;

    // Une signature n'est pas écrite dans la page : la gomme n'effacerait
    // que le document en dessous, ce que personne ne demande en visant une
    // signature. C'est la corbeille qui la retire.
    if (mot.traitsSignature != null) {
      setState(() => statut =
          "La gomme efface la page, pas la signature — utilisez la corbeille");
      return;
    }

    final zone = _rectEffacement(mot);
    final partPage = (taillePage.width * taillePage.height) <= 0
        ? 0.0
        : (zone.width * zone.height) /
            (taillePage.width * taillePage.height);
    if (partPage > 0.03) {
      final confirme = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("Effacer toute cette zone ?"),
          content: Text(
              "Le cadre couvre environ ${(partPage * 100).round()} % de la "
              "page. Tout ce qui s'y trouve — texte, tampon, signature du "
              "document — sera recouvert.\n\n"
              "Vous pourrez revenir en arrière avec ↶, ou avec « Récupérer "
              "l'original de cette zone »."),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Annuler"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("Effacer"),
            ),
          ],
        ),
      );
      if (confirme != true) return;
    }

    setState(() => _occupe = true);
    try {
      historique.add(await _etatActuel(doc));
      futur.clear();

      final page = doc.pages[0];
      _effacerRect(page, zone, mot);

      setState(() {
        mot.texte = "";
        mot.redessine = false;
        statut = "Zone effacée — ↶ pour revenir en arrière";
      });

      if (imageDeFond != null) {
        await _rafraichirApercuOcr(doc);
      }
    } finally {
      setState(() => _occupe = false);
    }
  }

  /// Copie toute la sélection, d'une ligne à autant qu'on veut. Chaque ligne
  /// garde sa place dans le bloc, si bien que le collage restitue les
  /// interlignes au lieu d'empiler les lignes au même endroit.
  void _copier() {
    final choisies = selection.where((m) => m.texte.isNotEmpty).toList()
      ..sort((a, b) {
        final vertical = a.zone.top.compareTo(b.zone.top);
        return vertical != 0 ? vertical : a.zone.left.compareTo(b.zone.left);
      });
    if (choisies.isEmpty) return;

    // Même rectangle que pour un déplacement (marge + tiret/puce embarqués),
    // pour que l'image capturée corresponde exactement à ce qui est copié.
    final rects = <MotDetecte, Rect>{
      for (final m in choisies)
        m: _aligner(_etendreVersPuce(_rectDeplacement(m))),
    };
    var bloc = rects[choisies.first]!;
    for (final r in rects.values) {
      bloc = bloc.expandToInclude(r);
    }

    setState(() {
      lignesCopiees
        ..clear()
        ..addAll([
          for (final m in choisies)
            _LigneCopiee(
              texte: m.texte,
              decalage: rects[m]!.topLeft - bloc.topLeft,
              taille: rects[m]!.size,
              gras: m.gras,
              italique: m.italique,
              famille: m.famille,
              couleur: m.couleurTexte,
              tailleManuelle: m.tailleManuelle,
              tailleAuto: m.tailleAuto,
              // Même règle qu'au déplacement : on ne garde une photo que
              // d'une ligne scannée. Une ligne dont on connaît la police est
              // réécrite, ce qui reste net ; une ligne déjà redessinée n'a
              // de toute façon plus ses pixels à jour dans l'image.
              image: (m.redessine || !m.depuisOcr)
                  ? null
                  : _capturerZone(rects[m]!),
            )
        ]);
      tailleBlocCopie = bloc.size;
      statut = choisies.length == 1
          ? "Texte copié : collez-le ici ou dans n'importe quelle autre "
              "application"
          : "${choisies.length} lignes copiées : touchez l'endroit où les "
              "coller";
    });

    // Aussi dans le presse-papiers d'Android : le texte est alors collable
    // partout ailleurs (SMS, mail, autre application), avec le collage
    // habituel du téléphone, et pas seulement dans ce document.
    Clipboard.setData(
        ClipboardData(text: choisies.map((m) => m.texte).join('\n')));
  }

  void _activerModeCollage() {
    if (lignesCopiees.isEmpty) return;
    setState(() {
      enCollage = true;
      enAjoutTexte = false;
      statut = lignesCopiees.length == 1
          ? "Touchez l'endroit de la page où coller le texte"
          : "Touchez l'endroit où coller les ${lignesCopiees.length} lignes";
    });
  }

  /// Colle les lignes copiées à l'endroit touché, le bloc centré sur le
  /// doigt, chacune gardant sa place dans l'ensemble. Ce sont de nouvelles
  /// lignes indépendantes, qu'on peut ensuite déplacer ou modifier.
  Future<void> _collerA(double xPage, double yPage) async {
    final doc = document;
    if (doc == null || lignesCopiees.isEmpty || _occupe) return;

    final coin = Offset(
      xPage - tailleBlocCopie.width / 2,
      yPage - tailleBlocCopie.height / 2,
    );
    final zones = [
      for (final ligne in lignesCopiees)
        Rect.fromLTWH(
          coin.dx + ligne.decalage.dx,
          coin.dy + ligne.decalage.dy,
          ligne.taille.width,
          ligne.taille.height,
        )
    ];

    // Coller ne fait qu'ajouter du texte à l'endroit touché : ça ne repeint
    // pas la destination, donc coller sur une ligne existante empile le
    // texte collé par-dessus au lieu de le remplacer, illisible. On demande
    // un autre endroit plutôt que de produire ce chevauchement. La
    // vérification porte sur tout le bloc, pas sur sa première ligne.
    final surLigneExistante = mots.any((m) =>
        m.texte.isNotEmpty &&
        zones.any((z) => z.inflate(3).overlaps(m.zone)));
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

      final page = doc.pages[0];
      final nouvelles = <MotDetecte>[];
      for (var i = 0; i < lignesCopiees.length; i++) {
        final ligne = lignesCopiees[i];
        final zone = zones[i];
        final posee = MotDetecte(
          ligne.texte,
          zone,
          gras: ligne.gras,
          tailleManuelle: ligne.tailleManuelle,
          italique: ligne.italique,
          famille: ligne.famille,
          couleurTexte: ligne.couleur,
          tailleAuto: ligne.tailleAuto,
          // Une ligne posée en image vient d'un scan : la redéplacer devra
          // repasser par la photo, pas par une réécriture.
          depuisOcr: ligne.image != null,
        );
        final image = ligne.image;
        if (image != null) {
          page.graphics.drawImage(PdfBitmap(image), zone);
        } else {
          _ecrire(page, posee, zone);
        }
        nouvelles.add(posee);
      }

      setState(() {
        mots = [...mots, ...nouvelles];
        selection
            ..clear()
            ..addAll(nouvelles);
        enCollage = false;
        statut = nouvelles.length == 1
            ? "Texte collé"
            : "${nouvelles.length} lignes collées";
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

  /// Octets du PDF, signatures comprises. Elles sont écrites ici et
  /// nulle part ailleurs, sur une copie : le document en cours d'édition
  /// reste vierge de leur encre, si bien qu'après un enregistrement on peut
  /// encore les déplacer, les redimensionner ou les retirer.
  Future<List<int>> _octetsAvecSignatures(PdfDocument doc) async {
    final signatures = mots.where((m) => m.traitsSignature != null).toList();
    final octets = await doc.save();
    if (signatures.isEmpty) return octets;
    final copie = PdfDocument(inputBytes: Uint8List.fromList(octets));
    try {
      final page = copie.pages[0];
      for (final signature in signatures) {
        _tracerSignature(page, signature.traitsSignature!, signature.zone);
      }
      return await copie.save();
    } finally {
      copie.dispose();
    }
  }

  Future<void> _enregistrer() async {
    final doc = document;
    if (doc == null) return;

    setState(() => enregistrementEnCours = true);
    try {
      final List<int> octets = await _octetsAvecSignatures(doc);
      final dossier = await getTemporaryDirectory();
      final horodatage = DateTime.now().millisecondsSinceEpoch;
      final fichier = File('${dossier.path}/pdf_modifie_$horodatage.pdf');
      await fichier.writeAsBytes(octets, flush: true);
      await Share.shareXFiles([XFile(fichier.path)], text: "PDF modifié");
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 8),
            content: Text("Erreur d'enregistrement : $e\n"
                "Annulez la dernière action (↶) puis réessayez. Le document "
                "ouvert sur le téléphone n'a pas été touché."),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => enregistrementEnCours = false);
    }
  }

  /// Bouton de la barre compacte : une icône, pas de libellé, pour tenir
  /// côte à côte au-dessus de la sélection.
  Widget _boutonMenu(IconData icone, String infobulle, VoidCallback? action) {
    return IconButton(
      icon: Icon(icone, size: 19),
      color: Colors.white.withOpacity(0.92),
      disabledColor: Colors.white30,
      tooltip: infobulle,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      onPressed: action,
    );
  }

  /// Supprime pour de bon ce qui est sélectionné : l'encre est effacée de la
  /// page et le cadre disparaît avec. Auparavant il fallait deux gestes (la
  /// gomme, puis retirer le cadre resté à l'écran), ce qui laissait croire
  /// que la suppression n'avait pas marché.
  Future<void> _supprimerObjet(MotDetecte mot) async {
    final doc = document;
    if (doc == null || _occupe) return;

    // Une signature n'est pas encore écrite dans la page : la retirer de la
    // liste suffit, sans coup de blanc là où elle se trouvait.
    if (mot.traitsSignature != null) {
      final avant = await _etatActuel(doc);
      setState(() {
        historique.add(avant);
        futur.clear();
        mots = mots.where((m) => m != mot).toList();
        selection.remove(mot);
        statut = "Signature retirée";
      });
      return;
    }

    // Rien d'écrit dans la page pour un simple repère : le cadre suffit.
    if (mot.texte.isEmpty) {
      _retirerRepere(mot);
      return;
    }

    setState(() => _occupe = true);
    final avant = await _etatActuel(doc);
    try {
      historique.add(avant);
      futur.clear();

      final page = doc.pages[0];
      _effacerRect(page, _rectEffacement(mot), mot);

      setState(() {
        mots = mots.where((m) => m != mot).toList();
        selection.remove(mot);
        statut = "Supprimé";
      });

      if (imageDeFond != null) await _rafraichirApercuOcr(doc);
    } catch (e) {
      historique.removeLast();
      await _restaurerEtat(avant);
      setState(() => statut = "Suppression annulée (rien n'a été perdu) : $e");
    } finally {
      setState(() => _occupe = false);
    }
  }

  /// Repose la même signature un peu plus loin : signer à deux endroits
  /// d'un document ne doit pas obliger à ressortir le répertoire.
  Future<void> _dupliquerSignature(MotDetecte mot) async {
    final traits = mot.traitsSignature;
    final doc = document;
    if (traits == null || doc == null || _occupe) return;

    const decalage = 16.0;
    var gauche = mot.zone.left + decalage;
    var haut = mot.zone.top + decalage;
    if (gauche + mot.zone.width > taillePage.width) {
      gauche = taillePage.width - mot.zone.width;
    }
    if (haut + mot.zone.height > taillePage.height) {
      haut = taillePage.height - mot.zone.height;
    }
    final copie = MotDetecte(
      "",
      Rect.fromLTWH(gauche, haut, mot.zone.width, mot.zone.height),
      traitsSignature: traits,
      ratioSignature: mot.ratioSignature,
    );

    final avant = await _etatActuel(doc);
    setState(() {
      historique.add(avant);
      futur.clear();
      mots = [...mots, copie];
      selection
        ..clear()
        ..add(copie);
      statut = "Signature dupliquée — tirez-la à sa place";
    });
  }

  /// Image de la page telle qu'elle était à l'ouverture du fichier,
  /// calculée à la première demande et gardée ensuite.
  Future<img.Image?> _pageOrigine() async {
    final deja = imageOrigine;
    if (deja != null) return deja;
    final octets = octetsDocument;
    if (octets == null) return null;
    PdfRaster? raster;
    await for (final r
        in Printing.raster(octets, pages: const [0], dpi: _dpiApercu)) {
      raster = r;
      break;
    }
    if (raster == null) return null;
    final decodee = img.decodePng(await raster.toPng());
    if (decodee == null) return null;
    imageOrigine = decodee;
    echelleOrigine = _dpiApercu / 72.0;
    return decodee;
  }

  /// Remet dans la page ce que le document contenait à son ouverture, sur
  /// la zone du cadre choisi. Rien n'est jamais supprimé d'un PDF par cette
  /// application : effacer, c'est peindre par-dessus. Ce qui a été recouvert
  /// par erreur est donc toujours dans le fichier d'origine, et il suffit de
  /// le remettre — sans annuler, une par une, toutes les modifications
  /// faites depuis. Pour récupérer plusieurs lignes d'un coup, on pose un
  /// cadre (appui long), on l'étire aux quatre coins sur toute la zone
  /// abîmée, puis on récupère.
  Future<void> _recupererOrigine(MotDetecte mot) async {
    final doc = document;
    if (doc == null || _occupe) return;
    setState(() => _occupe = true);
    Etat? avant;
    try {
      final origine = await _pageOrigine();
      if (origine == null) {
        setState(() => statut =
            "Impossible de relire le document d'origine pour cette zone");
        return;
      }

      final zone = mot.zone;
      final e = echelleOrigine;
      final x = (zone.left * e).round().clamp(0, origine.width - 1);
      final y = (zone.top * e).round().clamp(0, origine.height - 1);
      final largeur = (zone.width * e).round().clamp(1, origine.width - x);
      final hauteur = (zone.height * e).round().clamp(1, origine.height - y);
      if (largeur < 2 || hauteur < 2) {
        setState(() => statut = "Cadre trop petit pour être récupéré");
        return;
      }

      final morceau = img.copyCrop(origine,
          x: x, y: y, width: largeur, height: hauteur);
      final octets = Uint8List.fromList(img.encodePng(_surFondBlanc(morceau)));

      avant = await _etatActuel(doc);
      historique.add(avant);
      futur.clear();
      doc.pages[0].graphics.drawImage(PdfBitmap(octets), zone);
      // Les pixels de la page ont changé sous ce cadre : la photo gardée de
      // la ligne n'a plus lieu d'être, elle sera reprise au besoin.
      mot.pixelsSource = null;
      mot.tailleSource = null;
      mot.decalageSource = null;
      setState(() => statut = "Zone remise dans son état d'origine");
      if (imageDeFond != null) await _rafraichirApercuOcr(doc);
    } catch (e) {
      if (avant != null) {
        historique.removeLast();
        await _restaurerEtat(avant);
      }
      setState(() => statut = "Récupération annulée (rien n'a été perdu) : $e");
    } finally {
      setState(() => _occupe = false);
    }
  }

  /// Repart du fichier tel qu'il a été ouvert : toutes les modifications de
  /// la session sont abandonnées, le fichier sur le téléphone n'ayant lui
  /// jamais été touché (l'enregistrement crée toujours un nouveau document).
  Future<void> _revenirAuDocumentOrigine() async {
    final octets = octetsDocument;
    if (octets == null || _occupe) return;
    final confirme = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Revenir au document d'origine"),
        content: const Text(
            "Tout ce qui a été modifié depuis l'ouverture sera abandonné, "
            "et le document redeviendra exactement celui que vous avez "
            "ouvert. Le fichier d'origine sur le téléphone n'a jamais été "
            "touché."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Annuler"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Revenir au document d'origine"),
          ),
        ],
      ),
    );
    if (confirme != true) return;

    setState(() {
      _occupe = true;
      historique.clear();
      futur.clear();
      selection.clear();
      motEnEditionDirecte = null;
    });
    await _analyser(octets);
    if (!mounted) return;
    setState(() {
      _occupe = false;
      // L'analyse dit elle-même ce qui s'est passé quand elle échoue : on
      // ne recouvre pas son message par une confirmation trompeuse.
      if (mots.isNotEmpty) statut = "Document revenu à son état d'ouverture";
    });
  }

  /// Referme le document et revient à l'écran d'accueil. Sert de sortie de
  /// secours : quoi qu'il arrive, on peut toujours repartir de zéro sans
  /// avoir à tuer l'application depuis Android.
  void _fermerDocument() {
    document?.dispose();
    setState(() {
      document = null;
      mots = [];
      selection.clear();
      historique.clear();
      futur.clear();
      imageDeFond = null;
      imageDecodee = null;
      imageOrigine = null;
      apercuLecture = null;
      octetsDocument = null;
      motEnEditionDirecte = null;
      champEnEdition = null;
      champsFormulaire = [];
      modeRemplissage = false;
      modeLecture = true;
      _occupe = false;
      enregistrementEnCours = false;
      statut = "Aucun document — ouvrez-en un";
    });
  }

  /// Menu de la barre du haut, identique en lecture et en modification.
  /// Il reste actif même quand l'application est occupée : c'est justement
  /// dans ces moments-là qu'il faut pouvoir en sortir.
  Widget _menuGeneral(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: "Autres actions",
      onSelected: (choix) {
        switch (choix) {
          case "debloquer":
            setState(() {
              _occupe = false;
              enregistrementEnCours = false;
              statut = "Débloqué — reprenez où vous en étiez";
            });
            break;
          case "lecture":
            setState(() {
              motEnEditionDirecte = null;
              selection.clear();
              modeLecture = true;
              statut = "Lecture seule — appuyez sur le crayon pour modifier";
            });
            break;
          case "origine":
            _revenirAuDocumentOrigine();
            break;
          case "ouvrir":
            _importerDocument();
            break;
          case "fermer":
            _fermerDocument();
            break;
          case "quitter":
            SystemNavigator.pop();
            break;
        }
      },
      itemBuilder: (ctx) => [
        if (_occupe || enregistrementEnCours)
          const PopupMenuItem(
            value: "debloquer",
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.lock_open),
              title: Text("Débloquer l'application"),
              subtitle: Text("Si elle reste occupée sans avancer"),
            ),
          ),
        if (!modeLecture && apercuLecture != null)
          const PopupMenuItem(
            value: "lecture",
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.menu_book),
              title: Text("Revenir à la lecture"),
            ),
          ),
        if (!modeLecture && octetsDocument != null)
          const PopupMenuItem(
            value: "origine",
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.restore),
              title: Text("Revenir au document d'origine"),
              subtitle: Text("Abandonne toutes les modifications"),
            ),
          ),
        const PopupMenuItem(
          value: "ouvrir",
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.folder_open),
            title: Text("Ouvrir un autre document"),
          ),
        ),
        const PopupMenuItem(
          value: "fermer",
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.close),
            title: Text("Fermer le document"),
          ),
        ),
        const PopupMenuItem(
          value: "quitter",
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.exit_to_app),
            title: Text("Quitter l'application"),
          ),
        ),
      ],
    );
  }

  /// Supprime tout ce qui est sélectionné d'un seul geste : l'encre est
  /// effacée de la page et les cadres disparaissent. Une seule opération,
  /// qu'un seul « annuler » défait — supprimer ligne par ligne obligeait
  /// sinon à annuler autant de fois.
  Future<void> _supprimerSelection() async {
    final doc = document;
    if (doc == null || _occupe) return;
    final choisis = selection.toList();
    if (choisis.isEmpty) return;
    if (choisis.length == 1) return _supprimerObjet(choisis.first);

    setState(() => _occupe = true);
    final avant = await _etatActuel(doc);
    try {
      historique.add(avant);
      futur.clear();

      final page = doc.pages[0];
      for (final mot in choisis) {
        // Une signature n'est pas écrite dans la page tant qu'on n'a pas
        // enregistré, et un cadre vide n'a rien sous lui : dans les deux
        // cas il n'y a rien à effacer, seulement un cadre à retirer.
        if (mot.traitsSignature == null && mot.texte.isNotEmpty) {
          _effacerRect(page, _rectEffacement(mot), mot);
        }
      }

      setState(() {
        mots = mots.where((m) => !choisis.contains(m)).toList();
        selection.clear();
        statut = "${choisis.length} éléments supprimés";
      });

      if (imageDeFond != null) await _rafraichirApercuOcr(doc);
    } catch (e) {
      historique.removeLast();
      await _restaurerEtat(avant);
      setState(() => statut = "Suppression annulée (rien n'a été perdu) : $e");
    } finally {
      setState(() => _occupe = false);
    }
  }

  /// Actions moins courantes, rangées derrière « … » pour garder la barre
  /// principale courte.
  Future<void> _plusDActions(MotDetecte mot) async {
    final estSignature = mot.traitsSignature != null;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Une signature n'a ni texte à copier, ni encre à gommer dans la
            // page (elle flotte au-dessus jusqu'à l'enregistrement), et la
            // corbeille de la barre la retire déjà : la seule chose qui lui
            // manque, c'est de pouvoir se reposer ailleurs.
            if (estSignature)
              ListTile(
                leading: const Icon(Icons.content_copy),
                title: const Text("Dupliquer la signature"),
                subtitle: const Text("Pour signer à un deuxième endroit"),
                onTap: () {
                  Navigator.pop(ctx);
                  _dupliquerSignature(mot);
                },
              ),
            if (mot.texte.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.content_copy),
                title: const Text("Copier le texte"),
                onTap: () {
                  Navigator.pop(ctx);
                  _copier();
                },
              ),
            if (!estSignature)
              ListTile(
                leading: const Icon(Icons.cleaning_services),
                title: const Text("Effacer le fond (gomme)"),
                subtitle:
                    const Text("Efface l'encre, garde le cadre en place"),
                onTap: () {
                  Navigator.pop(ctx);
                  _effacerZone(mot);
                },
              ),
            if (mot.traitsSignature == null)
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text("Mettre en forme"),
                subtitle: const Text("Gras, taille, alignement"),
                onTap: () {
                  Navigator.pop(ctx);
                  _modifierMot(mot);
                },
              ),
            if (!estSignature)
              ListTile(
                leading: const Icon(Icons.restore_page),
                title: const Text("Récupérer l'original de cette zone"),
                subtitle: const Text(
                    "Remet ce que le document contenait à l'ouverture"),
                onTap: () {
                  Navigator.pop(ctx);
                  _recupererOrigine(mot);
                },
              ),
            if (!estSignature)
              ListTile(
                leading: const Icon(Icons.crop_free),
                title: const Text("Retirer le cadre seulement"),
                subtitle: const Text("Ne touche pas à la page"),
                onTap: () {
                  Navigator.pop(ctx);
                  _retirerRepere(mot);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return modeLecture ? _buildLecture(context) : _buildEdition(context);
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
          _menuGeneral(context),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              statut,
              // Une indication, pas une alarme : le document reste la seule
              // chose en gras à l'écran.
              style: TextStyle(
                fontSize: 13,
                color: Colors.black.withOpacity(0.62),
              ),
            ),
          ),
          // Un trait qui avance pendant que la page est refaite : sans lui,
          // l'application semblait figée le temps du rendu, et on appuyait
          // une deuxième fois en croyant que rien ne s'était passé.
          SizedBox(
            height: 3,
            child: _occupe ? const LinearProgressIndicator(minHeight: 3) : null,
          ),
          Expanded(
            child: apercuLecture == null
                // Pas de rond qui tourne indéfiniment quand il n'y a
                // simplement rien à afficher : on dit quoi faire.
                ? (_occupe
                    ? const Center(child: CircularProgressIndicator())
                    : Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.picture_as_pdf,
                                  size: 64, color: Colors.grey),
                              const SizedBox(height: 16),
                              const Text(
                                "Aucun document ouvert",
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 16),
                              ),
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                onPressed: _importerDocument,
                                icon: const Icon(Icons.folder_open),
                                label: const Text("Ouvrir un document"),
                              ),
                            ],
                          ),
                        ),
                      ))
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final echelle = constraints.maxWidth / taillePage.width;
                      _echelleVue = echelle;
                      _tailleVue = constraints.biggest;
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
                : (lignesCopiees.length > 1
                    ? "Coller les ${lignesCopiees.length} lignes copiées"
                    : "Coller le texte copié"),
            onPressed: (lignesCopiees.isEmpty || _occupe)
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
          _menuGeneral(context),
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
                      // Un seul bouton pour toutes les actions de texte : la
                      // barre est déjà pleine, et les quatre tiennent dans un
                      // menu sans rien en chasser.
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.select_all, size: 20),
                        tooltip: "Sélectionner, couper, copier, coller",
                        onSelected: _actionTexte,
                        itemBuilder: (ctx) => const [
                          PopupMenuItem(
                            value: "tout",
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.select_all),
                              title: Text("Tout sélectionner"),
                            ),
                          ),
                          PopupMenuItem(
                            value: "copier",
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.content_copy),
                              title: Text("Copier"),
                              subtitle: Text("La sélection, sinon la ligne"),
                            ),
                          ),
                          PopupMenuItem(
                            value: "couper",
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.content_cut),
                              title: Text("Couper"),
                              subtitle: Text("La sélection, sinon la ligne"),
                            ),
                          ),
                          PopupMenuItem(
                            value: "coller",
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.content_paste),
                              title: Text("Coller ici"),
                              subtitle: Text("À l'endroit du curseur"),
                            ),
                          ),
                        ],
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
                        tooltip: selection.length > 1
                            ? "Copier les ${selection.length} lignes"
                            : "Copier cette ligne",
                        onPressed: selection.any((m) => m.texte.isNotEmpty)
                            ? _copier
                            : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.cleaning_services, size: 20),
                        tooltip: "Effacer ici (gomme)",
                        onPressed: _occupe ||
                                selection.length != 1 ||
                                selection.first.traitsSignature != null
                            ? null
                            : () => _effacerZone(selection.first),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        tooltip: selection.length > 1
                            ? "Supprimer les ${selection.length} éléments"
                            : "Retirer ce cadre (n'efface rien dans le PDF)",
                        onPressed: _occupe
                            ? null
                            : (selection.length > 1
                                ? _supprimerSelection
                                : (selection.length == 1 &&
                                        selection.first.texte.isEmpty
                                    ? () => _retirerRepere(selection.first)
                                    : null)),
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
              // Une indication, pas une alarme : le document reste la seule
              // chose en gras à l'écran.
              style: TextStyle(
                fontSize: 13,
                color: Colors.black.withOpacity(0.62),
              ),
            ),
          ),
          // Un trait qui avance pendant que la page est refaite : sans lui,
          // l'application semblait figée le temps du rendu, et on appuyait
          // une deuxième fois en croyant que rien ne s'était passé.
          SizedBox(
            height: 3,
            child: _occupe ? const LinearProgressIndicator(minHeight: 3) : null,
          ),
          Expanded(
            child: mots.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final echelle = constraints.maxWidth / taillePage.width;
                      _echelleVue = echelle;
                      _tailleVue = constraints.biggest;
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
                                              cursorColor: _brunSelection,
                                              contextMenuBuilder:
                                                  _bulleSelection,
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
                                    // le plus court. Sur une signature, où
                                    // écrire n'aurait aucun sens, il la
                                    // sélectionne pour la déplacer ou la
                                    // redimensionner tout de suite.
                                    onTap: _occupe
                                        ? null
                                        : () {
                                            if (mot.traitsSignature != null) {
                                              setState(() => selection
                                                ..clear()
                                                ..add(mot));
                                              return;
                                            }
                                            _ecrireSurLaLigne(mot);
                                          },
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
                                    // Le glisser fait deux choses selon
                                    // l'état de la ligne : sur une ligne
                                    // déjà choisie il déplace toute la
                                    // sélection ; sur une ligne qui ne l'est
                                    // pas, il balaie — on part d'une ligne et
                                    // on descend, toutes celles traversées
                                    // sont prises. Choisir un paragraphe
                                    // demandait sinon un double-appui ligne
                                    // par ligne.
                                    onPanStart: (_) {
                                      if (selection.contains(mot)) {
                                        setState(() {
                                          groupeEnDeplacement = true;
                                          deplacementGroupeEnCours =
                                              Offset.zero;
                                        });
                                        return;
                                      }
                                      setState(() {
                                        balayageDepart = mot;
                                        selection
                                          ..clear()
                                          ..add(mot);
                                        statut = "Glissez pour prendre les "
                                            "lignes voisines";
                                      });
                                    },
                                    onPanUpdate: (details) {
                                      if (balayageDepart != null) {
                                        final rect =
                                            _rectAffichage(mot, echelle);
                                        _etendreBalayage(rect.top +
                                            details.localPosition.dy /
                                                echelle);
                                        return;
                                      }
                                      if (!groupeEnDeplacement) return;
                                      setState(() {
                                        deplacementGroupeEnCours +=
                                            details.delta;
                                      });
                                    },
                                    onPanEnd: (_) async {
                                      if (balayageDepart != null) {
                                        setState(() {
                                          balayageDepart = null;
                                          statut = selection.length > 1
                                              ? "${selection.length} lignes "
                                                  "choisies"
                                              : "Ligne choisie";
                                        });
                                        return;
                                      }
                                      if (!groupeEnDeplacement) return;
                                      final dx =
                                          deplacementGroupeEnCours.dx / echelle;
                                      final dy =
                                          deplacementGroupeEnCours.dy / echelle;
                                      setState(() {
                                        groupeEnDeplacement = false;
                                        deplacementGroupeEnCours = Offset.zero;
                                      });
                                      await _deplacerGroupe(
                                          selection.toList(), dx, dy);
                                    },
                                    child: CustomPaint(
                                      painter: _CadreLigne(
                                        selectionne: selection.contains(mot),
                                      ),
                                      // Une signature n'est pas dans le
                                      // fichier tant qu'on n'a pas
                                      // enregistré : c'est son cadre qui la
                                      // dessine, ce qui la rend libre de se
                                      // déplacer et de changer de taille.
                                      // Pour le reste, la page à l'écran est
                                      // l'image du PDF, refaite après chaque
                                      // modification : le cadre est alors
                                      // transparent et ne cache jamais rien.
                                      // Seul un document sans image de page
                                      // (texte vectoriel, non scanné) fait
                                      // afficher le texte par le cadre.
                                      child: mot.traitsSignature != null
                                          ? CustomPaint(
                                              painter: _PeintreSignaturePosee(
                                                  mot.traitsSignature!),
                                            )
                                          : (imageDeFond != null ||
                                              mot.texte.isEmpty)
                                          ? null
                                          : Align(
                                              alignment: Alignment.centerLeft,
                                              child: FittedBox(
                                                fit: BoxFit.scaleDown,
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
                                    // Assez large pour un doigt : des
                                    // poignées trop fines se laissaient
                                    // difficilement attraper.
                                    const rayon = 15.0;
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
                                                contextMenuBuilder:
                                                    _bulleSelection,
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
                            // Pendant qu'on fait glisser la sélection, la
                            // barre disparaît : elle suivrait le doigt en
                            // masquant justement l'endroit visé.
                            !groupeEnDeplacement)
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
                                // Barre compacte d'icônes, comme dans les
                                // applications de référence : les gestes
                                // courants d'un seul coup d'œil, le reste
                                // derrière « … ».
                                final estSignature =
                                    mot.traitsSignature != null;
                                final nbBoutons = estSignature ? 4 : 5;
                                final largeurMenu = 44.0 * nbBoutons + 10;
                                const hauteurMenu = 44.0;
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
                                        // Pastille arrondie, presque noire :
                                        // elle se pose sur la page sans y
                                        // faire un bloc.
                                        color: const Color(0xF01C1C1E),
                                        borderRadius:
                                            BorderRadius.circular(22),
                                        elevation: 4,
                                        clipBehavior: Clip.antiAlias,
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceEvenly,
                                          children: [
                                            if (!estSignature)
                                              _boutonMenu(
                                                Icons.edit,
                                                "Écrire",
                                                _occupe
                                                    ? null
                                                    : () =>
                                                        _ecrireSurLaLigne(mot),
                                              ),
                                            _boutonMenu(
                                              Icons.text_decrease,
                                              "Réduire",
                                              _occupe
                                                  ? null
                                                  : () =>
                                                      _redimensionnerDUnCran(
                                                          mot, 0.8),
                                            ),
                                            _boutonMenu(
                                              Icons.text_increase,
                                              "Agrandir",
                                              _occupe
                                                  ? null
                                                  : () =>
                                                      _redimensionnerDUnCran(
                                                          mot, 1.25),
                                            ),
                                            _boutonMenu(
                                              Icons.delete_outline,
                                              "Supprimer",
                                              _occupe
                                                  ? null
                                                  : () =>
                                                      _supprimerObjet(mot),
                                            ),
                                            _boutonMenu(
                                              Icons.more_horiz,
                                              "Plus d'actions",
                                              _occupe
                                                  ? null
                                                  : () =>
                                                      _plusDActions(mot),
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
      // Les outils se replient derrière un seul bouton. En colonne, les six
      // recouvraient tout le bord droit de la page — sur un document dont le
      // contenu va jusqu'au bord, ils mangeaient le cachet et la signature.
      floatingActionButton: mots.isEmpty
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.bottomCenter,
                  child: !outilsOuverts
                      ? const SizedBox(width: 40)
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FloatingActionButton.small(
                              heroTag: "ajoutTexte",
                              elevation: 2,
                              tooltip: enAjoutTexte
                                  ? "Touchez la page pour écrire à cet endroit"
                                  : "Ajouter du texte n'importe où",
                              backgroundColor: enAjoutTexte
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                              foregroundColor: enAjoutTexte
                                  ? Theme.of(context).colorScheme.onPrimary
                                  : null,
                              onPressed: _outil(_occupe
                                  ? null
                                  : () => setState(() {
                                        enAjoutTexte = !enAjoutTexte;
                                        if (enAjoutTexte) enCollage = false;
                                        statut = enAjoutTexte
                                            ? "Touchez la page pour écrire à cet endroit"
                                            : "Ajout de texte annulé";
                                      })),
                              child: const Icon(Icons.add),
                            ),
                            const SizedBox(height: 8),
                            FloatingActionButton.small(
                              heroTag: "mode",
                              elevation: 2,
                              tooltip: modeNavigation
                                  ? "Mode navigation : doigt = déplacer la page"
                                  : "Mode édition : doigt = sélectionner une ligne",
                              backgroundColor: modeNavigation
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                              foregroundColor: modeNavigation
                                  ? Theme.of(context).colorScheme.onPrimary
                                  : null,
                              onPressed: _outil(() => setState(() {
                                    modeNavigation = !modeNavigation;
                                    statut = modeNavigation
                                        ? "Mode navigation : faites glisser la page"
                                        : "Mode édition : touchez une ligne";
                                  })),
                              child: Icon(modeNavigation
                                  ? Icons.pan_tool
                                  : Icons.touch_app),
                            ),
                            const SizedBox(height: 8),
                            FloatingActionButton.small(
                              heroTag: "signature",
                              elevation: 2,
                              tooltip:
                                  "Signature (mes signatures / en tracer une)",
                              onPressed:
                                  _outil(_occupe ? null : _choisirSignature),
                              child: const Icon(Icons.draw),
                            ),
                            const SizedBox(height: 8),
                            FloatingActionButton.small(
                              heroTag: "remplir",
                              elevation: 2,
                              tooltip: modeRemplissage
                                  ? "Quitter le remplissage du formulaire"
                                  : "Remplir le formulaire du PDF",
                              backgroundColor: modeRemplissage
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                              foregroundColor: modeRemplissage
                                  ? Theme.of(context).colorScheme.onPrimary
                                  : null,
                              onPressed:
                                  _outil(_occupe ? null : _basculerRemplissage),
                              child: const Icon(Icons.edit_note),
                            ),
                            const SizedBox(height: 8),
                            FloatingActionButton.small(
                              heroTag: "recentrer",
                              elevation: 2,
                              tooltip: "Recentrer / réinitialiser le zoom",
                              onPressed: _outil(() =>
                                  _transformation.value = Matrix4.identity()),
                              child: const Icon(Icons.zoom_out_map),
                            ),
                            const SizedBox(height: 8),
                            FloatingActionButton.small(
                              heroTag: "aplatir",
                              elevation: 2,
                              tooltip:
                                  "Rédaction définitive (avant de partager)",
                              onPressed: _outil(
                                  _occupe ? null : _confirmerAplatissement),
                              child: const Icon(Icons.security),
                            ),
                            const SizedBox(height: 8),
                            FloatingActionButton.small(
                              heroTag: "nettoyer",
                              elevation: 2,
                              tooltip: "Retirer tous les cadres vides",
                              onPressed: _outil(
                                  _occupe ? null : _nettoyerReperesVides),
                              child: const Icon(Icons.clear_all),
                            ),
                            const SizedBox(height: 10),
                          ],
                        ),
                ),
                FloatingActionButton.small(
                  heroTag: "outils",
                  elevation: 2,
                  tooltip: outilsOuverts ? "Fermer les outils" : "Outils",
                  onPressed: () =>
                      setState(() => outilsOuverts = !outilsOuverts),
                  child: Icon(
                      outilsOuverts ? Icons.close : Icons.more_horiz),
                ),
              ],
            ),
    );
  }
}
