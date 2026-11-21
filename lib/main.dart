import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const StudyMindApp());
}

const Color systemBlue = Color(0xFF36BFFF);
const Color deepBlue = Color(0xFF071321);
const Color panelBlue = Color(0xFF0D2033);

class StudyMindApp extends StatefulWidget {
  const StudyMindApp({super.key});

  @override
  State<StudyMindApp> createState() => _StudyMindAppState();
}

class _StudyMindAppState extends State<StudyMindApp> {
  int _points = 0;
  int _tab = 0;
  bool _secretQuestDone = false;
  bool _dailyQuestDone = false;
  String _dailyQuestDate = '';
  bool _loading = true;
  String? _cloudUid;

  Set<String> _completedExercises = {};
  String _assistantName = 'KING';
  String _assistantStyle = 'Mentor';
  String _assistantIdentity = 'KING';
  String _customAssistantName = 'Mon assistant';

  List<Course> _courses = [
    Course(name: 'Comptabilité générale', detail: 'SYSCOHADA • 4 chapitres', icon: Icons.calculate_outlined),
    Course(name: 'Mathématiques', detail: 'Algèbre • Fonctions', icon: Icons.functions),
    Course(name: 'Histoire', detail: 'Histoire contemporaine', icon: Icons.account_balance_outlined),
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();

    final now = DateTime.now();
    final todayKey = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final savedDailyDate = prefs.getString('dailyQuestDate') ?? '';

    final savedCourses = prefs.getString('courses');
    List<Course> loadedCourses = _courses;

    if (savedCourses != null) {
      try {
        final decoded = jsonDecode(savedCourses) as List<dynamic>;
        loadedCourses = decoded
            .map((item) => Course.fromJson(item as Map<String, dynamic>))
            .toList();
      } catch (_) {
        loadedCourses = _courses;
      }
    }

    if (!mounted) return;
    setState(() {
      _points = prefs.getInt('points') ?? 0;
      _tab = (prefs.getInt('tab') ?? 0).clamp(0, 3).toInt();
      _secretQuestDone = prefs.getBool('secretQuestDone') ?? false;
      _dailyQuestDone = savedDailyDate == todayKey ? (prefs.getBool('dailyQuestDone') ?? false) : false;
      _dailyQuestDate = todayKey;
      _completedExercises =
          (prefs.getStringList('completedExercises') ?? <String>[]).toSet();
      final storedIdentity = prefs.getString('assistantIdentity') ?? 'KING';
      _assistantIdentity = storedIdentity == 'Garçon' ? 'KING' : storedIdentity == 'Fille' ? 'QUEEN' : storedIdentity;
      _customAssistantName = prefs.getString('customAssistantName') ?? 'Mon assistant';
      _assistantName = prefs.getString('assistantName') ??
          (_assistantIdentity == 'QUEEN' ? 'QUEEN' : _assistantIdentity == 'PERSONNALISÉ' ? _customAssistantName : 'KING');
      _assistantStyle = prefs.getString('assistantStyle') ?? 'Mentor';
      _courses = loadedCourses;
      _loading = false;
    });
    await prefs.setString('dailyQuestDate', todayKey);
    if (savedDailyDate != todayKey) await prefs.setBool('dailyQuestDone', false);
  }

  Future<void> _syncCloudCourses() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _cloudUid == user.uid) return;
    _cloudUid = user.uid;
    try {
      final ref = FirebaseFirestore.instance.collection('users').doc(user.uid).collection('appData').doc('main');
      final snapshot = await ref.get();
      final cloudCourses = snapshot.data()?['courses'];
      if (cloudCourses is List && cloudCourses.isNotEmpty) {
        final restored = cloudCourses.whereType<Map>().map((item) => Course.fromJson(Map<String, dynamic>.from(item))).toList();
        if (mounted && restored.isNotEmpty) {
          setState(() => _courses = restored);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('courses', jsonEncode(_courses.map((c) => c.toJson()).toList()));
        }
      } else {
        await ref.set({'courses': _courses.map((c) => c.toJson()).toList(), 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      }
    } catch (error) { _cloudUid = null; debugPrint('StudyMind cloud sync failed: $error'); }
  }

  Future<void> _saveStudyArtifact(String type, Course course, String content) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Connexion Firebase requise pour enregistrer.');
    await FirebaseFirestore.instance.collection('users').doc(user.uid).collection('studyArtifacts').add({
      'type': type, 'course': course.name, 'content': content, 'createdAt': FieldValue.serverTimestamp(),
    });
  }
  Future<String> _generateStudyContent({required String task, required Course course, String answer = '', String difficulty = 'Moyen'}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Connecte-toi à ton compte Firebase.');
    if (course.content.trim().length < 20) throw Exception('Ajoute le contenu du cours avant de générer une fiche ou un exercice.');
    final token = await user.getIdToken(true);
    final response = await http.post(Uri.parse('https://studymind-assistant-2026.kayumbagradel05.workers.dev/api/generate'),
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
      body: jsonEncode({'task': task, 'course': course.name, 'text': course.content, 'answer': answer, 'difficulty': difficulty}),
    ).timeout(const Duration(seconds: 90));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) throw Exception(data['error']?.toString() ?? 'Erreur IA (${response.statusCode})');
    final content = data['content']?.toString() ?? '';
    if (content.isEmpty) throw Exception('L’IA n’a renvoyé aucun contenu.');
    return content;
  }
  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('points', _points);
    await prefs.setInt('tab', _tab);
    await prefs.setBool('secretQuestDone', _secretQuestDone);
    await prefs.setBool('dailyQuestDone', _dailyQuestDone);
    await prefs.setString('dailyQuestDate', _dailyQuestDate);
    await prefs.setStringList('completedExercises', _completedExercises.toList());
    await prefs.setString('assistantIdentity', _assistantIdentity);
    await prefs.setString('customAssistantName', _customAssistantName);
    await prefs.setString('assistantName', _assistantName);
    await prefs.setString('assistantStyle', _assistantStyle);
    await prefs.setString(
      'courses',
      jsonEncode(_courses.map((course) => course.toJson()).toList()),
    );
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        await FirebaseFirestore.instance.collection('users').doc(user.uid).collection('appData').doc('main').set({
          'courses': _courses.map((course) => course.toJson()).toList(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (error) { debugPrint('StudyMind cloud save failed: $error'); }
    }
  }

  String get _rank {
    if (_points >= 5000) return 'SSS';
    if (_points >= 3000) return 'SS';
    if (_points >= 1500) return 'S';
    if (_points >= 750) return 'A';
    if (_points >= 350) return 'B';
    if (_points >= 150) return 'C';
    if (_points >= 50) return 'D';
    return 'E';
  }

  int get _nextRankAt {
    if (_points < 50) return 50;
    if (_points < 150) return 150;
    if (_points < 350) return 350;
    if (_points < 750) return 750;
    if (_points < 1500) return 1500;
    if (_points < 3000) return 3000;
    if (_points < 5000) return 5000;
    return 5000;
  }

  void _award(int points, String label) {
    if (points <= 0) return;
    setState(() => _points += points);
    _saveData();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label : +$points PR'),
        backgroundColor: const Color(0xFF126B91),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null && _cloudUid != uid) { Future.microtask(_syncCloudCourses); }
    final scheme = ColorScheme.fromSeed(
      seedColor: systemBlue,
      brightness: Brightness.dark,
      surface: deepBlue,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'StudyMind',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor:
            deepBlue,
        appBarTheme: AppBarTheme(
          backgroundColor: deepBlue,
          elevation: 0,
        ),
      ),
      home: AuthGate(onAuthenticated: _syncCloudCourses, child: Scaffold(
        body: SafeArea(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: systemBlue),
                )
              : IndexedStack(
                  index: _tab,
                  children: [
                    _Dashboard(
                      points: _points,
                      rank: _rank,
                      nextRankAt: _nextRankAt,
                      courses: _courses,
                      onOpenCourses: () => _changeTab(1),
                      onOpenQuests: () => _changeTab(2),
                    ),
                    _CoursesPage(
                      courses: _courses,
                      onAdd: _addCourse,
                      onExercise: _openExercise,
                      onImport: _importCourse,
                      onSummary: _showSummary,
                    ),
                    _QuestsPage(
                      onAward: _award,
                      dailyDone: _dailyQuestDone,
                      secretDone: _secretQuestDone,
                      onSecretComplete: _completeSecretQuest,
                    ),
                    _ProfilePage(
                      points: _points,
                      rank: _rank,
                      assistantName: _assistantName,
                      assistantStyle: _assistantStyle,
                      assistantIdentity: _assistantIdentity,
                      onAssistantChanged: _changeAssistant,
                    ),
                  ],
                ),
        ),
        floatingActionButton: _loading ? null : FloatingActionButton.extended(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AssistantChatPage(mode: _assistantIdentity, style: _assistantStyle, course: _courses.isNotEmpty ? _courses.first.name : '', courseContext: _courses.isNotEmpty ? _courses.first.content : '', assistantName: _assistantName))),
          icon: const Icon(Icons.auto_awesome), label: const Text('IA'),
        ),
        bottomNavigationBar: _loading
            ? null
            : NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: _changeTab,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.grid_view_rounded),
                    label: 'Système',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.menu_book_rounded),
                    label: 'Cours',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.assignment_turned_in_outlined),
                    label: 'Quêtes',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.person_outline),
                    label: 'Profil',
                  ),
                ],
              ),
      )),
    );
  }

  void _changeTab(int index) {
    setState(() => _tab = index);
    _saveData();
  }

  void _changeAssistant(String identity, String style, [String? customName]) {
    setState(() {
      _assistantIdentity = identity;
      if (customName != null && customName.trim().isNotEmpty) _customAssistantName = customName.trim();
      _assistantName = identity == 'QUEEN' ? 'QUEEN' : identity == 'PERSONNALISÉ' ? _customAssistantName : 'KING';
      _assistantStyle = style;
    });
    _saveData();
  }

  void _completeSecretQuest() {
    if (_secretQuestDone) return;
    setState(() => _secretQuestDone = true);
    _saveData();
    _award(2, 'Quête secrète RH terminée');
  }

  void _addCourse() {
    final nameController = TextEditingController();
    final contentController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Créer une matière'),
        content: SizedBox(width: double.maxFinite, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nameController, autofocus: true, decoration: const InputDecoration(labelText: 'Nom de la matière', hintText: 'Ex. : Comptabilité générale')),
          const SizedBox(height: 12),
          TextField(controller: contentController, minLines: 3, maxLines: 7, decoration: const InputDecoration(labelText: 'Contenu du cours (facultatif)', hintText: 'Colle ici ton cours pour permettre à KING de créer des fiches et exercices IA.', border: OutlineInputBorder())),
        ]))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isEmpty) return;
              final content = contentController.text.trim();
              setState(() => _courses.add(Course(name: name, detail: content.isEmpty ? 'Nouvel espace de cours' : 'Cours ajouté • ${content.length} caractères', icon: Icons.auto_stories, content: content)));
              _saveData();
              Navigator.pop(ctx);
            },
            child: const Text('Créer'),
          ),
        ],
      ),
    ).then((_) { nameController.dispose(); contentController.dispose(); });
  }
  Future<void> _importCourse() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'txt', 'md'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes ?? (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) throw Exception('Fichier inaccessible.');
      String extracted;
      final extension = (file.extension ?? '').toLowerCase();
      if (extension == 'pdf') {
        final document = PdfDocument(inputBytes: bytes);
        try {
          extracted = PdfTextExtractor(document).extractText();
        } finally {
          document.dispose();
        }
      } else {
        extracted = utf8.decode(bytes, allowMalformed: true);
      }
      if (extracted.trim().isEmpty) {
        throw Exception('Aucun texte détecté. Pour un PDF scanné ou une photo, une fonction OCR sera nécessaire.');
      }
      final title = file.name.replaceAll(RegExp(r'\.(pdf|txt|md)$', caseSensitive: false), '');
      final course = Course(
        name: title.isEmpty ? 'Cours importé' : title,
        detail: 'Document importé • ${extracted.length} caractères',
        icon: Icons.description_outlined,
        content: extracted,
      );
      setState(() => _courses.add(course));
      await _saveData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cours importé et enregistré sur cet appareil.')));
      _showSummary(course);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import impossible : $error')));
    }
  }

  Future<void> _showSummary(Course course) async {
    if (course.content.trim().length < 20) {
      _comingSoon(context, 'Ajoute le contenu de cette matière avec Importer un cours pour créer une fiche IA.');
      return;
    }
    showDialog(context: context, barrierDismissible: false, builder: (ctx) => const AlertDialog(content: Row(children: [CircularProgressIndicator(), SizedBox(width: 16), Expanded(child: Text('KING prépare ta fiche de révision…'))])));
    try {
      final generated = await _generateStudyContent(task: 'revision', course: course);
      await _saveStudyArtifact('revision', course, generated);
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      showDialog(context: context, builder: (ctx) => AlertDialog(title: Text('Fiche IA • ${course.name}'), content: SizedBox(width: double.maxFinite, child: SingleChildScrollView(child: SelectableText(generated))), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer'))]));
    } catch (error) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Création de fiche impossible : $error')));
    }
  }
  void _openExercise(Course course) {
    final exerciseId = course.name;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ExercisePage(
          course: course,
          alreadySubmitted: _completedExercises.contains(exerciseId),
          onAward: _award,
          onSubmitted: () {
            if (_completedExercises.contains(exerciseId)) return;
            setState(() => _completedExercises.add(exerciseId));
            _saveData();

            if (!_dailyQuestDone) {
              setState(() => _dailyQuestDone = true);
              _saveData();
              _award(1, 'Mission quotidienne terminée');
            }
          },
        ),
      ),
    );
  }
}

class Course {
  Course({required this.name, required this.detail, required this.icon, this.content = ''});

  final String name;
  final String detail;
  final IconData icon;
  final String content;

  Map<String, dynamic> toJson() => {
        'name': name,
        'detail': detail,
        'iconCodePoint': icon.codePoint,
        'fontFamily': icon.fontFamily,
        'fontPackage': icon.fontPackage,
        'content': content,
      };

  factory Course.fromJson(Map<String, dynamic> json) {
    return Course(
      name: json['name'] as String? ?? 'Matière',
      detail: json['detail'] as String? ?? '',
      content: json['content'] as String? ?? '',
      icon: IconData(
        json['iconCodePoint'] as int? ?? Icons.auto_stories.codePoint,
        fontFamily: json['fontFamily'] as String? ?? 'MaterialIcons',
        fontPackage: json['fontPackage'] as String?,
      ),
    );
  }
}

class _Dashboard extends StatelessWidget {
  const _Dashboard({
    required this.points,
    required this.rank,
    required this.nextRankAt,
    required this.courses,
    required this.onOpenCourses,
    required this.onOpenQuests,
  });

  final int points;
  final int nextRankAt;
  final String rank;
  final List<Course> courses;
  final VoidCallback onOpenCourses;
  final VoidCallback onOpenQuests;

  @override
  Widget build(BuildContext context) {
    final previousRankAt = _previousThreshold(points);
    final progress = points >= 5000
        ? 1.0
        : ((points - previousRankAt) / (nextRankAt - previousRankAt))
            .clamp(0.0, 1.0);

    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Row(
          children: [
            const Icon(Icons.blur_on, color: systemBlue, size: 30),
            const SizedBox(width: 8),
            const Text(
              'STUDYMIND',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
                fontSize: 19,
              ),
            ),
            const Spacer(),
            _tag('SYSTEM ONLINE'),
          ],
        ),
        const SizedBox(height: 22),
        _panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'STATUT DU CHASSEUR',
                style: TextStyle(
                  color: systemBlue,
                  letterSpacing: 1.5,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'RANG $rank',
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '$points PR',
                    style: const TextStyle(
                      color: systemBlue,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 9,
                  backgroundColor: Colors.white12,
                  color: systemBlue,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                points >= 5000
                    ? 'Rang maximal atteint'
                    : '${nextRankAt - points} PR avant le prochain rang',
                style: const TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'NOTIFICATION DU SYSTÈME',
                style: TextStyle(
                  color: systemBlue,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 9),
              const Text(
                'Bienvenue, chasseur.',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const SizedBox(height: 4),
              const Text(
                'Ton aventure commence maintenant. Termine des exercices, accomplis des quêtes et fais évoluer ton rang.',
                style: TextStyle(color: Colors.white70, height: 1.4),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _sectionTitle('ACCÈS RAPIDE'),
        Row(
          children: [
            Expanded(
              child: _actionCard(
                Icons.menu_book,
                'Mes cours',
                onOpenCourses,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _actionCard(
                Icons.lock_open,
                'Quêtes',
                onOpenQuests,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _sectionTitle('MES MATIÈRES'),
        ...courses.take(3).map(
              (course) => Card(
                child: ListTile(
                  leading: Icon(course.icon, color: systemBlue),
                  title: Text(course.name),
                  subtitle: Text(course.detail),
                  trailing: const Icon(Icons.chevron_right),
                ),
              ),
            ),
      ],
    );
  }
}

int _previousThreshold(int points) {
  if (points >= 5000) return 5000;
  if (points >= 6000) return 6000;
  if (points >= 3000) return 3000;
  if (points >= 1500) return 1500;
  if (points >= 700) return 700;
  if (points >= 300) return 300;
  if (points >= 100) return 100;
  return 0;
}

class _CoursesPage extends StatelessWidget {
  const _CoursesPage({
    required this.courses,
    required this.onAdd,
    required this.onExercise,
    required this.onImport,
    required this.onSummary,
  });

  final List<Course> courses;
  final VoidCallback onAdd;
  final void Function(Course) onExercise;
  final VoidCallback onImport;
  final void Function(Course) onSummary;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(18),
        children: [
          _pageHeader('BIBLIOTHÈQUE', 'Tes espaces de connaissances'),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Créer une matière'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onImport,
            icon: const Icon(Icons.upload_file),
            label: const Text('Importer un cours (PDF, TXT, MD)'),
          ),
          const SizedBox(height: 14),
          ...courses.map(
            (course) => Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: systemBlue.withOpacity(.15),
                        child: Icon(course.icon, color: systemBlue),
                      ),
                      title: Text(
                        course.name,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(course.detail),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton.icon(
                            onPressed: () => onSummary(course),
                            icon: const Icon(Icons.summarize_outlined),
                            label: const Text('Fiche'),
                          ),
                        ),
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: () => onExercise(course),
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Exercices'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Astuce : crée une matière pour organiser tes révisions par cours.',
            style: TextStyle(color: Colors.white60),
          ),
        ],
      );
}

class ExercisePage extends StatefulWidget {
  const ExercisePage({
    super.key,
    required this.course,
    required this.onAward,
    required this.alreadySubmitted,
    required this.onSubmitted,
  });

  final Course course;
  final void Function(int, String) onAward;
  final bool alreadySubmitted;
  final VoidCallback onSubmitted;

  @override
  State<ExercisePage> createState() => _ExercisePageState();
}

class _ExercisePageState extends State<ExercisePage> {
  String _difficulty = 'Facile';
  late bool _submitted = widget.alreadySubmitted;
  final TextEditingController _answer = TextEditingController();
  String _feedback = '';
  String? _generatedQuestion;
  bool _aiBusy = false;
  String? _aiCorrection;

  @override
  void initState() {
    super.initState();
    if (widget.course.content.trim().length >= 20) _generateAiExercise();
  }

  Future<String> _callStudyAi(String task, {String answer = ''}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Connexion Firebase requise.');
    final token = await user.getIdToken(true);
    final response = await http.post(
      Uri.parse('https://studymind-assistant-2026.kayumbagradel05.workers.dev/api/generate'),
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
      body: jsonEncode({'task': task, 'course': widget.course.name, 'text': widget.course.content, 'answer': answer, 'difficulty': _difficulty}),
    ).timeout(const Duration(seconds: 90));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) throw Exception(data['error']?.toString() ?? 'Erreur IA (${response.statusCode})');
    return data['content']?.toString() ?? '';
  }

  Future<void> _saveGeneratedExercise(String content) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Connexion Firebase requise pour enregistrer l’exercice.');
    await FirebaseFirestore.instance.collection('users').doc(user.uid).collection('studyArtifacts').add({
      'type': 'exercise', 'course': widget.course.name, 'content': content, 'difficulty': _difficulty, 'createdAt': FieldValue.serverTimestamp(),
    });
  }
  Future<void> _generateAiExercise() async {
    if (_aiBusy || _submitted) return;
    setState(() { _aiBusy = true; _feedback = ''; });
    try {
      final generated = await _callStudyAi('exercise');
      await _saveGeneratedExercise(generated);
      final marker = RegExp(r'(?im)^\s*(?:#+\s*)?CORRECTION\s*:?').firstMatch(generated);
      final question = marker == null ? generated : generated.substring(0, marker.start).trim();
      if (mounted && question.isNotEmpty) setState(() { _generatedQuestion = question; _aiCorrection = generated; });
    } catch (error) {
      if (mounted) setState(() => _feedback = 'Exercice IA indisponible : $error');
    } finally { if (mounted) setState(() => _aiBusy = false); }
  }

  int get _reward =>
      _difficulty == 'Facile' ? 1 : _difficulty == 'Moyen' ? 2 : 5;

  String get _question {
    final name = widget.course.name.toLowerCase();
    if (name.contains('comptabil')) {
      return 'Une entreprise achète des marchandises pour 100 000 FC à crédit. Quels éléments faut-il débiter et créditer dans l’écriture ?';
    }
    if (name.contains('math')) {
      return 'Résous l’équation suivante et explique brièvement ton calcul : 2x + 4 = 10.';
    }
    if (name.contains('histoire')) {
      return 'Cite une cause majeure de la Première Guerre mondiale et explique brièvement son rôle.';
    }
    return 'Présente une notion importante de cette matière, donne sa définition et ajoute un exemple concret.';
  }

  bool _isCorrect(String rawAnswer) {
    final answer = _normalize(rawAnswer);
    final name = widget.course.name.toLowerCase();

    if (name.contains('comptabil')) {
      final hasDebit = answer.contains('debit');
      final hasCredit = answer.contains('credit');
      final hasSupplier = answer.contains('fournisseur');
      final hasPurchase =
          answer.contains('achat') || answer.contains('marchandise');
      return hasDebit && hasCredit && hasSupplier && hasPurchase;
    }

    if (name.contains('math')) {
      return RegExp(r'\b3\b').hasMatch(answer) ||
          answer.contains('x=3') ||
          answer.contains('x = 3');
    }

    if (name.contains('histoire')) {
      return answer.contains('assassinat') ||
          answer.contains('nationalisme') ||
          answer.contains('alliance') ||
          answer.contains('imperialisme') ||
          answer.contains('rivalite');
    }

    return answer.length >= 80 && answer.contains('exemple');
  }

  String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll('é', 'e')
        .replaceAll('è', 'e')
        .replaceAll('ê', 'e')
        .replaceAll('ë', 'e')
        .replaceAll('à', 'a')
        .replaceAll('â', 'a')
        .replaceAll('î', 'i')
        .replaceAll('ï', 'i')
        .replaceAll('ô', 'o')
        .replaceAll('ù', 'u')
        .replaceAll('û', 'u')
        .replaceAll('ç', 'c')
        .trim();
  }

  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('ENTRAÎNEMENT')),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Text(
              widget.course.name,
              style: const TextStyle(
                color: systemBlue,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            _panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'CHOISIS TA DIFFICULTÉ',
                    style: TextStyle(
                      color: systemBlue,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: ['Facile', 'Moyen', 'Difficile']
                        .map(
                          (difficulty) => ChoiceChip(
                            label: Text(difficulty),
                            selected: _difficulty == difficulty,
                            onSelected: _submitted
                                ? null
                                : (_) => setState(() {
                                      _difficulty = difficulty;
                                      _feedback = '';
                                    }),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Récompense : +$_reward PR',
                    style: const TextStyle(
                      color: systemBlue,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'EXERCICE',
                    style: TextStyle(
                      color: systemBlue,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _generatedQuestion ?? _question,
                    style: const TextStyle(fontSize: 16, height: 1.4),
                  ),
                  const SizedBox(height: 14),
                  if (_aiBusy) const LinearProgressIndicator(),
                  if (widget.course.content.trim().length >= 20 && !_submitted)
                    Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: _aiBusy ? null : _generateAiExercise, icon: const Icon(Icons.auto_awesome), label: const Text('Nouvel exercice IA'))),
                  TextField(
                    controller: _answer,
                    enabled: !_submitted,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Écris ta réponse ici…',
                    ),
                    onChanged: (_) => setState(() => _feedback = ''),
                  ),
                ],
              ),
            ),
            if (_feedback.isNotEmpty) ...[
              const SizedBox(height: 12),
              _panel(
                child: Text(
                  _feedback,
                  style: TextStyle(
                    color: _feedback.startsWith('Bonne')
                        ? systemBlue
                        : Colors.orangeAccent,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _submitted || _aiBusy || _answer.text.trim().isEmpty
                  ? null
                  : _submitAnswer,
              icon: const Icon(Icons.check_circle_outline),
              label: Text(
                _submitted ? 'Exercice déjà soumis' : 'Vérifier ma réponse',
              ),
            ),
            if (_submitted)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _panel(
                  child: const Text(
                    'Réponse validée et enregistrée. Tu ne peux recevoir les PR de cet exercice qu’une seule fois.',
                    style: TextStyle(color: systemBlue),
                  ),
                ),
              ),
            const SizedBox(height: 10),
            const Text(
              widget.course.content.trim().length >= 20 ? 'Exercice et correction générés à partir de ton cours par l’IA.' : 'Importe le cours dans cette matière pour générer des exercices personnalisés par l’IA.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      );

  Future<void> _submitAnswer() async {
    if (_aiBusy || _answer.text.trim().isEmpty) return;
    if (widget.course.content.trim().length >= 20) {
      setState(() { _aiBusy = true; _feedback = 'KING corrige ta réponse…'; });
      try {
        final correction = await _callStudyAi('correction', answer: 'Consigne : ${_generatedQuestion ?? _question}\nRéponse : ${_answer.text}');
        final correct = RegExp(r'RESULTAT\s*:\s*BONNE', caseSensitive: false).hasMatch(correction);
        if (!mounted) return;
        setState(() { _aiCorrection = correction; _feedback = correction; _submitted = correct; });
        if (correct) { widget.onSubmitted(); widget.onAward(_reward, 'Exercice réussi'); }
      } catch (error) {
        if (mounted) setState(() => _feedback = 'Correction IA indisponible : $error. Réessaie.');
      } finally { if (mounted) setState(() => _aiBusy = false); }
      return;
    }
    if (!_isCorrect(_answer.text)) {
      setState(() { _feedback = 'Réponse non validée. Relis la consigne et essaie encore.'; });
      return;
    }
    setState(() { _submitted = true; _feedback = 'Bonne réponse ! Ton exercice est validé.'; });
    widget.onSubmitted();
    widget.onAward(_reward, 'Exercice réussi');
  }
}

class _QuestsPage extends StatelessWidget {
  const _QuestsPage({
    required this.onAward,
    required this.dailyDone,
    required this.secretDone,
    required this.onSecretComplete,
  });

  final void Function(int, String) onAward;
  final bool dailyDone;
  final bool secretDone;
  final VoidCallback onSecretComplete;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(18),
        children: [
          _pageHeader('JOURNAL DES QUÊTES', 'Accomplis les missions du système'),
          const SizedBox(height: 14),
          _questCard(
            'MISSION QUOTIDIENNE',
            'Échauffement intellectuel',
            dailyDone
                ? 'Mission accomplie. Récompense déjà attribuée.'
                : 'Termine correctement un exercice pour accomplir cette mission.',
            dailyDone ? 'TERMINÉE' : '+1 PR',
            Icons.task_alt,
            () {
              if (!dailyDone) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Réussis un exercice pour terminer cette mission.',
                    ),
                  ),
                );
              }
            },
          ),
          const SizedBox(height: 12),
          _questCard(
            'QUÊTE SECRÈTE',
            'L’urgence du département RH',
            secretDone
                ? 'Mission accomplie. Cette quête ne peut être récompensée qu’une seule fois.'
                : 'Une assistante demande une vérification comptable urgente. Vérifie les pièces, trouve les erreurs et prépare le dossier.',
            secretDone ? 'TERMINÉE' : '+2 PR',
            Icons.visibility_off_outlined,
            secretDone
                ? () {}
                : () => _showSecret(context, onSecretComplete),
          ),
          const SizedBox(height: 12),
          _questCard(
            'QUÊTE SECRÈTE',
            'Le dossier confidentiel',
            'Une mission spéciale apparaîtra lorsque les conditions seront réunies.',
            'x3 PR',
            Icons.lock_outline,
            () => _comingSoon(context, 'Cette quête est encore verrouillée'),
          ),
          const SizedBox(height: 12),
          _panel(
            child: const Text(
              'Les quêtes secrètes sont des défis bonus. Les récompenses sont attribuées après validation et ne peuvent être obtenues qu’une seule fois.',
              style: TextStyle(color: Colors.white70, height: 1.4),
            ),
          ),
        ],
      );
}

void _showSecret(BuildContext context, VoidCallback onComplete) {
  final answerController = TextEditingController();
  String error = '';

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('QUÊTE SECRÈTE — DÉPARTEMENT RH'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Le département RH reçoit une facture d’achat de marchandises à crédit. Indique le principe de l’écriture : quel type de compte débiter et quel type de compte créditer ?',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: answerController,
                maxLines: 4,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Explique ta réponse…',
                ),
              ),
              if (error.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  error,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Plus tard'),
          ),
          FilledButton(
            onPressed: () {
              final answer = answerController.text
                  .toLowerCase()
                  .replaceAll('é', 'e')
                  .replaceAll('è', 'e')
                  .replaceAll('ê', 'e')
                  .replaceAll('à', 'a')
                  .replaceAll('ç', 'c');

              final valid = answer.contains('debit') &&
                  answer.contains('credit') &&
                  answer.contains('fournisseur') &&
                  (answer.contains('achat') || answer.contains('marchandise'));

              if (!valid) {
                setLocal(() {
                  error =
                      'Ce n’est pas encore validé. Pense au compte d’achat et au fournisseur.';
                });
                return;
              }

              Navigator.pop(ctx);
              onComplete();
            },
            child: const Text('Vérifier le dossier'),
          ),
        ],
      ),
    ),
  ).then((_) => answerController.dispose());
}

class _AdministrationPage extends StatelessWidget {
  const _AdministrationPage();

  static const List<Map<String, String>> _modules = [
    {
      'title': 'Module 1 — Identité et valeurs',
      'detail': 'Mission de StudyMind, charte, neutralité, respect et responsabilités.'
    },
    {
      'title': 'Module 2 — Gestion des utilisateurs',
      'detail': 'Assistance, signalements, protection des comptes et traitement équitable.'
    },
    {
      'title': 'Module 3 — Gestion pédagogique',
      'detail': 'Qualité des cours, exercices, résumés et signalement des erreurs.'
    },
    {
      'title': 'Module 4 — Sécurité et confidentialité',
      'detail': 'Données personnelles, accès minimum nécessaire, mots de passe et incidents.'
    },
    {
      'title': 'Module 5 — Outils administratifs',
      'detail': 'Permissions, journal d’activité, modération et procédures d’escalade.'
    },
    {
      'title': 'Module 6 — Cas pratiques',
      'detail': 'Résoudre des situations réelles sans abuser de ses pouvoirs.'
    },
  ];

  Widget _lockedTool(IconData icon, String title, String detail) => Card(
        child: ListTile(
          leading: Icon(icon, color: systemBlue),
          title: Text(title),
          subtitle: Text(detail),
          trailing: const Icon(Icons.lock_outline, size: 18),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('STUDYMIND • ADMINISTRATION')),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            _panel(
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.workspace_premium_outlined, color: systemBlue, size: 38),
                  SizedBox(height: 10),
                  Text('STUDYMIND ACADEMY', style: TextStyle(color: systemBlue, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                  SizedBox(height: 6),
                  Text('Programme officiel de formation des administrateurs'),
                  SizedBox(height: 10),
                  Text('ÉTAT : APERÇU — ACTIVATION SÉCURISÉE À EFFECTUER', style: TextStyle(color: Colors.orangeAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(height: 18),
            _sectionTitle('PARCOURS OBLIGATOIRE'),
            const Text('Chaque candidat doit terminer les six modules avant de passer l’examen.'),
            const SizedBox(height: 8),
            ..._modules.map((module) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.menu_book_outlined, color: systemBlue),
                    title: Text(module['title']!),
                    subtitle: Text(module['detail']!),
                  ),
                )),
            const SizedBox(height: 14),
            _sectionTitle('VALIDATION DES CANDIDATS'),
            _lockedTool(Icons.quiz_outlined, 'Examen final', 'Questionnaire noté après la formation ; seuil de réussite configurable.'),
            _lockedTool(Icons.record_voice_over_outlined, 'Entretien avec la fondatrice', 'Évaluation personnelle de la motivation, du jugement et du sérieux.'),
            _lockedTool(Icons.verified_user_outlined, 'Approbation de la fondatrice', 'Aucune nomination automatique : chaque candidature attend ta décision.'),
            const SizedBox(height: 14),
            _sectionTitle('OUTILS DE SÉCURITÉ PRÉVUS'),
            _lockedTool(Icons.vpn_key_outlined, 'Codes de nomination', 'Codes générés côté serveur, à usage unique, temporaires et révocables.'),
            _lockedTool(Icons.admin_panel_settings_outlined, 'Permissions par rôle', 'Droits limités au strict nécessaire ; aucun droit de nommer d’autres admins.'),
            _lockedTool(Icons.history, 'Journal d’activité', 'Historique horodaté des actions administratives et des changements de droits.'),
            _lockedTool(Icons.person_remove_alt_1_outlined, 'Révocation immédiate', 'Désactivation des accès et des sessions d’un administrateur.'),
            _lockedTool(Icons.phonelink_lock_outlined, 'Protection du compte fondateur', 'Authentification renforcée et protection contre toute rétrogradation.'),
            const SizedBox(height: 14),
            _panel(
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('RÈGLE FONDAMENTALE', style: TextStyle(color: systemBlue, fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  Text('Seule la fondatrice peut approuver une nomination. Les administrateurs ne peuvent ni créer d’autres administrateurs, ni modifier le rôle de la fondatrice.'),
                  SizedBox(height: 10),
                  Text('Sécurité : ces contrôles devront être appliqués par un serveur et une authentification vérifiée. Un écran Flutter ou un code caché dans l’APK ne suffit pas à protéger les privilèges.', style: TextStyle(color: Colors.orangeAccent, height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      );
}

class _ProfilePage extends StatelessWidget {
  const _ProfilePage({
    required this.points,
    required this.rank,
    required this.assistantName,
    required this.assistantStyle,
    required this.assistantIdentity,
    required this.onAssistantChanged,
  });

  final int points;
  final String rank;
  final String assistantName;
  final String assistantStyle;
  final String assistantIdentity;
  final void Function(String, String, [String?]) onAssistantChanged;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(18),
        children: [
          _pageHeader('PROFIL DU CHASSEUR', 'Tes statistiques et préférences'),
          const SizedBox(height: 14),
          _panel(
            child: Row(
              children: [
                const CircleAvatar(
                  radius: 30,
                  backgroundColor: Color(0xFF123B58),
                  child: Icon(Icons.person, color: systemBlue, size: 34),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'CHASSEUR DE RANG $rank',
                        style: const TextStyle(
                          color: systemBlue,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text('$points points de réussite'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined, color: systemBlue),
              title: const Text('Administration StudyMind'),
              subtitle: const Text('Fondateur • Academy • Sécurité'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const _AdministrationPage()),
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(
                Icons.smart_toy_outlined,
                color: systemBlue,
              ),
              title: const Text('Personnaliser mon assistant'),
              subtitle: Text('$assistantName • $assistantStyle'),
              onTap: () => _assistantDialog(
                context,
                assistantIdentity,
                assistantStyle,
                assistantName,
                onAssistantChanged,
              ),
            ),
          ),
          const SizedBox(height: 12),
          _panel(
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'RANGS DU SYSTÈME',
                  style: TextStyle(
                    color: systemBlue,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 10),
                Text(
                  'E — 0 PR\n'
                  'D — 50 PR\n'
                  'C — 150 PR\n'
                  'B — 350 PR\n'
                  'A — 750 PR\n'
                  'S — 1 500 PR\n'
                  'SS — 3 000 PR\n'
                  'SSS — 5 000 PR',
                  style: TextStyle(height: 1.7),
                ),
              ],
            ),
          ),
        ],
      );
}

void _assistantDialog(
  BuildContext context,
  String currentIdentity,
  String currentStyle,
  String currentName,
  void Function(String, String, [String?]) onSave,
) {
  String identity = currentIdentity;
  String style = currentStyle;
  final customNameController = TextEditingController(text: currentIdentity == 'PERSONNALISÉ' ? currentName : '');

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('Personnaliser l’assistant'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: identity,
              decoration: const InputDecoration(labelText: 'Choix'),
              items: const [
                DropdownMenuItem(value: 'KING', child: Text('KING')),
                DropdownMenuItem(value: 'QUEEN', child: Text('QUEEN')),
                DropdownMenuItem(value: 'PERSONNALISÉ', child: Text('Personnalisé')),
              ],
              onChanged: (value) {
                if (value != null) setLocal(() => identity = value);
              },
            ),
            if (identity == 'PERSONNALISÉ') ...[
              const SizedBox(height: 12),
              TextField(controller: customNameController, decoration: const InputDecoration(labelText: 'Nom de l’assistant')),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: style,
              decoration: const InputDecoration(labelText: 'Personnalité'),
              items: ['Mentor', 'Professeur', 'Rival', 'Génie']
                  .map(
                    (item) => DropdownMenuItem(
                      value: item,
                      child: Text(item),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setLocal(() => style = value);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () { customNameController.dispose(); Navigator.pop(ctx); },
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              onSave(identity, style, customNameController.text);
              customNameController.dispose();
              Navigator.pop(ctx);
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    ),
  );
}

Widget _panel({required Widget child}) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: panelBlue,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: systemBlue.withOpacity(.35)),
      ),
      child: child,
    );

Widget _tag(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: systemBlue.withOpacity(.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: systemBlue.withOpacity(.5)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: systemBlue,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
    );

Widget _sectionTitle(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: const TextStyle(
          color: systemBlue,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.3,
          fontSize: 12,
        ),
      ),
    );

Widget _pageHeader(String title, String subtitle) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w900,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 4),
        Text(subtitle, style: const TextStyle(color: Colors.white60)),
      ],
    );

Widget _actionCard(IconData icon, String label, VoidCallback onTap) =>
    InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: _panel(
        child: Column(
          children: [
            Icon(icon, color: systemBlue, size: 28),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );

Widget _questCard(
  String type,
  String title,
  String description,
  String reward,
  IconData icon,
  VoidCallback onTap,
) =>
    Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: systemBlue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      type,
                      style: const TextStyle(
                        color: systemBlue,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  Text(
                    reward,
                    style: const TextStyle(
                      color: systemBlue,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 17,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                description,
                style: const TextStyle(color: Colors.white70, height: 1.35),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onTap,
                  child: const Text('Consulter la quête'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

void _comingSoon(BuildContext context, String feature) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('$feature : prévu dans une prochaine version.')),
  );
}


class AuthGate extends StatelessWidget {
  const AuthGate({super.key, required this.child, required this.onAuthenticated});
  final Widget child;
  final VoidCallback onAuthenticated;
  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
    stream: FirebaseAuth.instance.authStateChanges(),
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (snapshot.data == null) return const FirebaseLoginPage();
      onAuthenticated();
      return child;
    },
  );
}

class FirebaseLoginPage extends StatefulWidget {
  const FirebaseLoginPage({super.key});
  @override
  State<FirebaseLoginPage> createState() => _FirebaseLoginPageState();
}

class _FirebaseLoginPageState extends State<FirebaseLoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _register = false;
  bool _busy = false;
  String? _error;
  Future<void> _submit() async {
    setState(() { _busy = true; _error = null; });
    try {
      final email = _email.text.trim();
      if (_register) {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(email: email, password: _password.text);
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(email: email, password: _password.text);
      }
    } on FirebaseAuthException catch (e) {
      setState(() => _error = e.message ?? e.code);
    } catch (_) { setState(() => _error = 'Connexion impossible. Vérifie Internet et réessaie.'); }
    if (mounted) setState(() => _busy = false);
  }
  @override
  void dispose() { _email.dispose(); _password.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Icon(Icons.auto_awesome, color: systemBlue, size: 54),
        const SizedBox(height: 16), const Text('STUDYMIND', textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 3)),
        const SizedBox(height: 8), Text(_register ? 'Créer ton compte' : 'Connexion Firebase', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 24),
        TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Adresse e-mail', border: OutlineInputBorder())),
        const SizedBox(height: 12), TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Mot de passe', border: OutlineInputBorder())),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
        const SizedBox(height: 18), FilledButton(onPressed: _busy ? null : _submit, child: _busy ? const CircularProgressIndicator() : Text(_register ? 'Créer le compte' : 'Se connecter')),
        TextButton(onPressed: _busy ? null : () => setState(() { _register = !_register; _error = null; }), child: Text(_register ? 'J’ai déjà un compte' : 'Créer un compte')),
      ],
    )))),
  );
}

class AssistantChatPage extends StatefulWidget {
  const AssistantChatPage({super.key, required this.mode, required this.style, required this.course, this.courseContext = '', this.assistantName = 'KING'});
  final String mode;
  final String style;
  final String course;
  final String courseContext;
  final String assistantName;
  @override
  State<AssistantChatPage> createState() => _AssistantChatPageState();
}

class _AssistantChatPageState extends State<AssistantChatPage> {
  static const String workerUrl = 'https://studymind-assistant-2026.kayumbagradel05.workers.dev';
  final _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  bool _sending = false;
  String? _error;
  Future<void> _send() async {
    final question = _controller.text.trim();
    if (question.isEmpty || _sending) return;
    _controller.clear();
    setState(() { _messages.add({'role':'user','text':question}); _sending = true; _error = null; });
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Connecte-toi à ton compte Firebase.');
      final token = await user.getIdToken(true);
      final response = await http.post(Uri.parse('$workerUrl/api/chat'),
        headers: {'Content-Type':'application/json','Authorization':'Bearer $token'},
        body: jsonEncode({'message':question,'mode':widget.mode,'style':widget.style,'course':widget.course,'assistantName':widget.assistantName,'context':widget.courseContext})).timeout(const Duration(seconds: 45));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode < 200 || response.statusCode >= 300) throw Exception(data['error']?.toString() ?? 'Erreur Worker (${response.statusCode})');
      final answer = data['answer']?.toString() ?? '';
      if (answer.isEmpty) throw Exception('Gemini a renvoyé une réponse vide.');
      if (mounted) setState(() => _messages.add({'role':'assistant','text':answer}));
    } catch (e) { if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ','')); }
    if (mounted) setState(() => _sending = false);
  }
  @override
  void dispose() { _controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('StudyMind • Assistant IA'), actions:[IconButton(tooltip:'Déconnexion', icon:const Icon(Icons.logout), onPressed:()=>FirebaseAuth.instance.signOut())]),
    body: Column(children:[
      Expanded(child: _messages.isEmpty ? Center(child: Text('Pose une question à ${widget.assistantName}. Le contenu de ta matière sera transmis si disponible.')) : ListView.builder(padding:const EdgeInsets.all(16), itemCount:_messages.length, itemBuilder:(context,index){ final m=_messages[index]; final mine=m['role']=='user'; return Align(alignment:mine?Alignment.centerRight:Alignment.centerLeft, child: Container(margin:const EdgeInsets.symmetric(vertical:6), padding:const EdgeInsets.all(12), constraints:const BoxConstraints(maxWidth:340), decoration:BoxDecoration(color:mine?const Color(0xFF124A68):panelBlue,borderRadius:BorderRadius.circular(14)), child:Text(m['text']??'')));})),
      if (_error != null) Padding(padding:const EdgeInsets.symmetric(horizontal:12), child:Text(_error!,style:const TextStyle(color:Colors.redAccent))),
      if (_sending) const LinearProgressIndicator(),
      SafeArea(top:false, child:Padding(padding:const EdgeInsets.all(12), child:Row(children:[Expanded(child:TextField(controller:_controller,minLines:1,maxLines:4,enabled:!_sending,onSubmitted:(_)=>_send(),decoration:const InputDecoration(hintText:'Écris ta question…',border:OutlineInputBorder()))),const SizedBox(width:8),IconButton.filled(onPressed:_sending?null:_send,icon:const Icon(Icons.send))]))),
    ]),
  );
}
