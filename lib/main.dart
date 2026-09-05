import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';

void main() {
  runApp(const PdfEditorApp());
}

class PdfEditorApp extends StatelessWidget {
  const PdfEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mon éditeur PDF',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF8A3B2B),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _pdfPath;

  Future<void> _pickPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (result != null && result.files.single.path != null) {
      setState(() {
        _pdfPath = result.files.single.path;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mon éditeur PDF')),
      body: _pdfPath == null
          ? Center(
              child: ElevatedButton.icon(
                onPressed: _pickPdf,
                icon: const Icon(Icons.file_open),
                label: const Text('Choisir un PDF'),
              ),
            )
          : PDFView(
              filePath: _pdfPath!,
              enableSwipe: true,
              swipeHorizontal: false,
              autoSpacing: true,
              pageFling: true,
            ),
      floatingActionButton: _pdfPath == null
          ? null
          : FloatingActionButton(
              onPressed: () => setState(() => _pdfPath = null),
              child: const Icon(Icons.folder_open),
            ),
    );
  }
}
