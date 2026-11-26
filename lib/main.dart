import 'dart:convert';
import 'file_bytes_stub.dart' if (dart.library.io) 'file_bytes_io.dart';
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';
import 'package:printing/printing.dart';

import 'package:file_picker/file_picker.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'firebase_web_options.dart';
import 'firebase_web_config_missing_app.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb && !hasFirebaseWebConfig) {
    runApp(const FirebaseWebConfigMissingApp());
    return;
  }
  await Firebase.initializeApp(options: kIsWeb ? firebaseWebOptions : null);
  runApp(const KavelyntApp());
}

const Color systemBlue = Color(0xFFB45CFF);
const Color deepBlue = Color(0xFF070311);
const Color panelBlue = Color(0xFF140A2A);
const Color kavelyntGold = Color(0xFFFFC83D);
const Color kavelyntPurple = Color(0xFF8B2CFF);

bool _hasPositiveAiVerdict(String output) {
  final matches = RegExp(
    r'^\s*RESULTAT\s*:\s*(BONNE|A_REVOIR)\s*$',
    multiLine: true,
    caseSensitive: false,
  ).allMatches(output).toList();
  if (matches.length != 1) return false;
  final match = matches.single;
  final lastLine = output.trimRight().split('\n').last.trim();
  return match.group(1)?.toUpperCase() == 'BONNE' &&
      lastLine.toUpperCase() == 'RESULTAT: BONNE';
}

// Kavelynt — application éducative personnalisée.
class KavelyntApp extends StatefulWidget {
  const KavelyntApp({super.key});

  @override
  State<KavelyntApp> createState() => _KavelyntAppState();
}

class _KavelyntAppState extends State<KavelyntApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<ScaffoldMessengerState> _messengerKey = GlobalKey<ScaffoldMessengerState>();
  int _points = 0;
  int _tab = 0;
  Set<String> _completedSecretCourseNames = {};
  int _questGenerationsThisWeek = 0;
  String _questGenerationWeek = '';
  bool _dailyQuestDone = false;
  String _dailyQuestDate = '';
  bool _loading = true;
  bool _localDataLoaded = false;
  String? _cloudUid;

  Set<String> _completedExercises = {};
  String _assistantName = 'KING';
  String _assistantStyle = 'Mentor';
  String _assistantIdentity = 'KING';
  String _customAssistantName = 'Mon assistant';

  List<Course> _courses = [];
  List<Map<String, String>> _aiQuests = [];
  Set<String> _completedQuestIds = {};
  String _questCycle = '';
  bool _questsLoading = false;

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
        loadedCourses = decoded.map((item) => Course.fromJson(item as Map<String, dynamic>)).where((course) => !{'Comptabilité générale','Mathématiques','Histoire'}.contains(course.name.trim())).toList();
      } catch (_) {
        loadedCourses = _courses;
      }
    }

    if (!mounted) return;
    setState(() {
      _points = prefs.getInt('points') ?? 0;
      _tab = (prefs.getInt('tab') ?? 0).clamp(0, 3).toInt();
      _completedSecretCourseNames = (prefs.getStringList('completedSecretCourseNames') ?? <String>[]).toSet();
      _questGenerationWeek = prefs.getString('questGenerationWeek') ?? _weekKey(DateTime.now());
      _questGenerationsThisWeek = _questGenerationWeek == _weekKey(DateTime.now()) ? (prefs.getInt('questGenerationsThisWeek') ?? 0) : 0;
      _dailyQuestDone = savedDailyDate == todayKey ? (prefs.getBool('dailyQuestDone') ?? false) : false;
      _dailyQuestDate = todayKey;
      _completedExercises =
          (prefs.getStringList('completedExercises') ?? <String>[]).toSet();
      final storedIdentity = prefs.getString('assistantIdentity') ?? 'KING';
      final legacyBestFriend = storedIdentity == 'MEILLEUR AMI';
      _assistantIdentity = storedIdentity == 'Garçon' || legacyBestFriend ? 'KING' : storedIdentity == 'Fille' ? 'QUEEN' : storedIdentity;
      _customAssistantName = prefs.getString('customAssistantName') ?? 'Mon assistant';
      _assistantName = prefs.getString('assistantName') ??
          (_assistantIdentity == 'QUEEN' ? 'QUEEN' : _assistantIdentity == 'PERSONNALISÉ' ? _customAssistantName : 'KING');
      _assistantStyle = legacyBestFriend ? 'Meilleur ami' : (prefs.getString('assistantStyle') ?? 'Mentor');
      _courses = loadedCourses;
      _aiQuests = prefs.getString('aiQuests') == null ? <Map<String,String>>[] : (jsonDecode(prefs.getString('aiQuests')!) as List).whereType<Map>().map((e) => Map<String,String>.from(e)).toList();
      _completedQuestIds = (prefs.getStringList('completedQuestIds') ?? <String>[]).toSet();
      _questCycle = prefs.getString('questCycle') ?? '';
      _loading = false;
    });
    _localDataLoaded = true;
    await prefs.setString('dailyQuestDate', todayKey);
    if (savedDailyDate != todayKey) await prefs.setBool('dailyQuestDone', false);
  }

  Future<void> _syncCloudCourses() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !_localDataLoaded || _cloudUid == user.uid) return;
    _cloudUid = user.uid;
    try {
      final ref = FirebaseFirestore.instance.collection('users').doc(user.uid).collection('appData').doc('main');
      final snapshot = await ref.get();
      final cloudData = snapshot.data() ?? {};
      final cloudCourses = cloudData['courses'];
      if (cloudCourses is List && cloudCourses.isNotEmpty) {
        final restored = cloudCourses
            .whereType<Map>()
            .map((item) => Course.fromJson(Map<String, dynamic>.from(item)))
            .toList();
        // Keep courses created locally while the first cloud sync was still running.
        final merged = <String, Course>{
          for (final course in restored) course.name.trim().toLowerCase(): course,
          for (final course in _courses) course.name.trim().toLowerCase(): course,
        }.values.toList();
        if (mounted) {
          setState(() {
            _courses = merged;
            _points = (cloudData['points'] as num?)?.toInt() ?? _points;
            _completedExercises = cloudData['completedExercises'] is List ? (cloudData['completedExercises'] as List).map((e)=>e.toString()).toSet() : _completedExercises;
            _dailyQuestDone = cloudData['dailyQuestDone'] as bool? ?? _dailyQuestDone;
            _dailyQuestDate = cloudData['dailyQuestDate']?.toString() ?? _dailyQuestDate;
            _completedSecretCourseNames = cloudData['completedSecretCourseNames'] is List ? (cloudData['completedSecretCourseNames'] as List).map((e)=>e.toString()).toSet() : _completedSecretCourseNames;
            final cloudWeek = cloudData['questGenerationWeek']?.toString() ?? _questGenerationWeek;
            _questGenerationWeek = cloudWeek;
            _questGenerationsThisWeek = cloudWeek == _weekKey(DateTime.now()) ? ((cloudData['questGenerationsThisWeek'] as num?)?.toInt() ?? _questGenerationsThisWeek) : 0;
            final cloudIdentity = cloudData['assistantIdentity']?.toString() ?? _assistantIdentity;
            final legacyBestFriend = cloudIdentity == 'MEILLEUR AMI';
            _assistantIdentity = legacyBestFriend ? 'KING' : cloudIdentity;
            _assistantName = cloudData['assistantName']?.toString() ?? (legacyBestFriend ? 'KING' : _assistantName);
            _assistantStyle = legacyBestFriend ? 'Meilleur ami' : (cloudData['assistantStyle']?.toString() ?? _assistantStyle);
            _customAssistantName = cloudData['customAssistantName']?.toString() ?? _customAssistantName;
            _aiQuests = cloudData['aiQuests'] is List ? (cloudData['aiQuests'] as List).whereType<Map>().map((e) => Map<String,String>.from(e)).toList() : _aiQuests;
            _completedQuestIds = cloudData['completedQuestIds'] is List ? (cloudData['completedQuestIds'] as List).map((e)=>e.toString()).toSet() : _completedQuestIds;
            _questCycle = cloudData['questCycle']?.toString() ?? _questCycle;
          });
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('courses', jsonEncode(_courses.map((c) => c.toJson()).toList()));
          await ref.set(_cloudState(), SetOptions(merge: true));
        }
      } else {
        await ref.set(_cloudState(), SetOptions(merge: true));
      }
      await _ensureAiQuests();
    } catch (error) { _cloudUid = null; debugPrint('Kavelynt cloud sync failed: $error'); }
  }

  Map<String, dynamic> _cloudState() => {
    'courses': _courses.map((course) => course.toJson()).toList(), 'points': _points,
    'completedExercises': _completedExercises.toList(), 'dailyQuestDone': _dailyQuestDone,
    'dailyQuestDate': _dailyQuestDate, 'completedSecretCourseNames': _completedSecretCourseNames.toList(),
    'aiQuests': _aiQuests, 'completedQuestIds': _completedQuestIds.toList(), 'questCycle': _questCycle,
    'questGenerationsThisWeek': _questGenerationsThisWeek, 'questGenerationWeek': _questGenerationWeek,
    'assistantIdentity': _assistantIdentity, 'assistantName': _assistantName,
    'assistantStyle': _assistantStyle, 'customAssistantName': _customAssistantName,
    'updatedAt': FieldValue.serverTimestamp(),
  };

  Future<void> _saveStudyArtifact(String type, Course course, String content) async {
    final prefs = await SharedPreferences.getInstance();
    List<dynamic> saved = [];
    try {
      final raw = prefs.getString('studyArtifacts');
      if (raw != null) saved = jsonDecode(raw) as List<dynamic>;
    } catch (_) {}
    final artifactId = 'artifact-${DateTime.now().microsecondsSinceEpoch}';
    saved.insert(0, {
      'id': artifactId,
      'type': type, 'course': course.name, 'content': content,
      'createdAt': DateTime.now().toIso8601String(),
    });
    if (saved.length > 100) saved = saved.take(100).toList();
    await prefs.setString('studyArtifacts', jsonEncode(saved));

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).collection('studyArtifacts').doc(artifactId).set({
        'id': artifactId, 'type': type, 'course': course.name, 'content': content, 'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (error) {
      debugPrint('Kavelynt archive cloud save failed; local copy kept: $error');
    }
  }
  Future<String> _generateStudyContent({required String task, required Course course, String answer = '', String difficulty = 'Moyen'}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Connecte-toi à ton compte Firebase.');
    if (course.content.trim().length < 20) throw Exception('Ajoute le contenu du cours avant de générer une fiche ou un exercice.');
    final token = await user.getIdToken(true);
    final response = await http.post(Uri.parse('https://studymind-assistant-2026.kayumbagradel05.workers.dev/api/generate'),
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
      body: jsonEncode({'task': task, 'course': course.name, 'text': course.content, 'answer': answer, 'difficulty': difficulty}),
    ).timeout(const Duration(seconds: 100));
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(response.body);
      data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      throw Exception('Le serveur IA a renvoyé une réponse illisible (HTTP ${response.statusCode}).');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(data['error']?.toString() ?? 'Service IA indisponible (HTTP ${response.statusCode}).');
    }
    final content = data['content']?.toString() ?? '';
    if (content.isEmpty) throw Exception('L’IA n’a renvoyé aucun contenu.');
    return content;
  }
  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('points', _points);
    await prefs.setInt('tab', _tab);
    await prefs.setStringList('completedSecretCourseNames', _completedSecretCourseNames.toList());
    await prefs.setInt('questGenerationsThisWeek', _questGenerationsThisWeek);
    await prefs.setString('questGenerationWeek', _questGenerationWeek);
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
    await prefs.setString('aiQuests', jsonEncode(_aiQuests));
    await prefs.setStringList('completedQuestIds', _completedQuestIds.toList());
    await prefs.setString('questCycle', _questCycle);
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        await FirebaseFirestore.instance.collection('users').doc(user.uid).collection('appData').doc('main').set({
          ..._cloudState(),
        }, SetOptions(merge: true));
      } catch (error) { debugPrint('Kavelynt cloud save failed: $error'); }
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
    final previousRank = _rank;
    setState(() => _points += points);
    final promotedRank = _rank;
    _saveData();
    if (promotedRank != previousRank) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final context = _navigatorKey.currentContext;
        if (context == null) return;
        showGeneralDialog<void>(
          context: context,
          barrierDismissible: true,
          barrierLabel: 'Promotion de rang',
          barrierColor: Colors.black.withValues(alpha: 0.82),
          transitionDuration: const Duration(milliseconds: 420),
          pageBuilder: (dialogContext, animation, secondaryAnimation) =>
              _RankPromotionDialog(previousRank: previousRank, rank: promotedRank),
          transitionBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutBack);
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(scale: curved, child: child),
            );
          },
        );
      });
    } else {
      _messengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text('$label : +$points PR'),
          backgroundColor: const Color(0xFF126B91),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null && _cloudUid != uid) { Future.microtask(_syncCloudCourses); }
    final scheme = ColorScheme.fromSeed(
      seedColor: kavelyntPurple,
      brightness: Brightness.dark,
      surface: deepBlue,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Kavelynt',
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
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
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
                      onTakePhoto: _takeCoursePhoto,
                      onWorksheet: _generateExerciseWorksheet,
                      onSummary: _showSummary,
                      onSecretQuest: _openCourseSecretQuest,
                      onDeleteCourses: _deleteCourses,
                      onArchive: () => _navigatorKey.currentState!.push(MaterialPageRoute(builder: (_) => const StudyArtifactArchivePage())),
                    ),
                    _QuestsPage(
                      dailyDone: _dailyQuestDone, quests: _aiQuests,
                      completedQuestIds: _completedQuestIds, loading: _questsLoading,
                      generationsUsed: _questGenerationsThisWeek,
                      onRefresh: _generateAiQuests, onVerifyQuest: _verifyAiQuest,
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
          onPressed: () => _navigatorKey.currentState!.push(MaterialPageRoute(builder: (_) => AssistantChatPage(mode: _assistantIdentity, style: _assistantStyle, course: _courses.isNotEmpty ? _courses.first.name : '', courseContext: _courses.isNotEmpty ? _courses.first.content : '', assistantName: _assistantName))),
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


  String _weekKey(DateTime date) {
    final thursday = date.add(Duration(days: 4 - date.weekday));
    final year = thursday.year;
    final januaryFourth = DateTime(year, 1, 4);
    final firstMonday = januaryFourth.subtract(Duration(days: januaryFourth.weekday - 1));
    final week = thursday.difference(firstMonday).inDays ~/ 7 + 1;
    return '$year-W${week.toString().padLeft(2, '0')}';
  }

  Future<void> _generateAiQuests() async {
    if (_questsLoading || _courses.isEmpty) return;
    final currentWeek = _weekKey(DateTime.now());
    if (_questGenerationWeek != currentWeek) {
      _questGenerationWeek = currentWeek;
      _questGenerationsThisWeek = 0;
    }
    if (_questGenerationsThisWeek >= 3) {
      _messengerKey.currentState?.showSnackBar(const SnackBar(content: Text('Limite atteinte : 3 générations de quêtes IA par semaine.')));
      await _saveData();
      return;
    }
    final source = _courses
        .where((course) => course.content.trim().length >= 20)
        .map((course) => 'MATIÈRE: ${course.name}\n${course.content}')
        .join('\n\n')
        .trim();
    if (source.length < 20) {
      _messengerKey.currentState?.showSnackBar(const SnackBar(content: Text('Ajoute le contenu de tes cours pour générer des quêtes.')));
      return;
    }
    setState(() => _questsLoading = true);
    try {
      final raw = await _generateStudyContent(
        task: 'quests',
        course: Course(name: 'Toutes les matières', detail: 'Quêtes Kavelynt', icon: Icons.assignment, content: source),
      );
      final cleaned = raw.replaceFirst(RegExp(r'^\s*\x60\x60\x60(?:json)?\s*'), '').replaceFirst(RegExp(r'\s*\x60\x60\x60\s*$'), '').trim();
      final decoded = jsonDecode(cleaned);
      final dynamic quests = decoded is Map<String, dynamic> ? decoded['quests'] : decoded;
      if (quests is! List) throw Exception('Format de quêtes invalide.');
      final generationId = DateTime.now().microsecondsSinceEpoch;
      final items = <Map<String,String>>[];
      for (final quest in quests.whereType<Map>()) {
        final title = quest['title']?.toString() ?? 'Mission Kavelynt';
        final parsedReward = int.tryParse(quest['reward']?.toString() ?? '') ?? 5;
        items.add({
          'id': 'quest-$generationId-${items.length}',
          'title': title,
          'description': quest['description']?.toString() ?? '',
          'course': quest['course']?.toString() ?? 'Toutes matières',
          'type': quest['type']?.toString() ?? 'Principale',
          'reward': parsedReward.clamp(1, 20).toString(),
        });
      }
      if (items.length < 2) throw Exception('Le modèle a renvoyé trop peu de quêtes.');
      if (!mounted) return;
      setState(() {
        _aiQuests = items;
        _questCycle = DateTime.now().toUtc().toIso8601String();
        _completedQuestIds = <String>{};
        _questGenerationWeek = currentWeek;
        _questGenerationsThisWeek += 1;
      });
      await _saveData();
    } catch (error) {
      if (mounted) _messengerKey.currentState?.showSnackBar(SnackBar(content: Text('Quêtes IA : $error')));
    } finally {
      if (mounted) setState(() => _questsLoading = false);
    }
  }

  Future<void> _ensureAiQuests() async {
    final date = DateTime.tryParse(_questCycle);
    final expired = date == null || DateTime.now().toUtc().difference(date).inDays >= 14;
    if ((_aiQuests.isEmpty || expired) && _questGenerationsThisWeek < 3) {
      await _generateAiQuests();
    }
  }

  Future<void> _verifyAiQuest(Map<String, String> quest) async {
    final id = quest['id'] ?? '';
    if (id.isEmpty || _completedQuestIds.contains(id) || _courses.isEmpty) return;
    final answerController = TextEditingController();
    bool checking = false;
    String feedback = '';
    await showDialog<void>(
      context: _navigatorKey.currentContext!,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(quest['title'] ?? 'Quête IA'),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(quest['description'] ?? ''),
            const SizedBox(height: 10),
            Text('Matière : ${quest['course'] ?? 'Cours'}', style: const TextStyle(color: systemBlue)),
            const SizedBox(height: 12),
            TextField(controller: answerController, maxLines: 5, enabled: !checking, onChanged: (_) => setDialogState(() {}), decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Explique ce que tu as fait ou réponds à la consigne…')),
            if (feedback.isNotEmpty) ...[const SizedBox(height: 10), Text(feedback, style: const TextStyle(color: Colors.orangeAccent))],
            if (checking) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
          ])),
          actions: [
            TextButton(onPressed: checking ? null : () => Navigator.pop(dialogContext), child: const Text('Fermer')),
            FilledButton(
              onPressed: checking || answerController.text.trim().length < 12 ? null : () async {
                setDialogState(() { checking = true; feedback = 'KING vérifie ta réalisation…'; });
                try {
                  final courseName = (quest['course'] ?? '').toLowerCase();
                  final matching = _courses.where((c) => c.name.toLowerCase() == courseName && c.content.trim().length >= 20);
                  final available = _courses.where((c) => c.content.trim().length >= 20).toList();
                  if (available.isEmpty) throw Exception('Ajoute le contenu du cours avant de faire vérifier cette quête.');
                  final course = matching.isNotEmpty ? matching.first : available.first;
                  final verdict = await _generateStudyContent(
                    task: 'quest_validation',
                    course: course,
                    answer: 'TITRE DE LA QUÊTE : ${quest['title']}\nOBJECTIF : ${quest['description']}\nRÉPONSE / PREUVE FOURNIE PAR L’ÉLÈVE : ${answerController.text.trim()}',
                  );
                  final valid = _hasPositiveAiVerdict(verdict);
                  if (!valid) {
                    setDialogState(() { checking = false; feedback = verdict; });
                    return;
                  }
                  if (mounted && !_completedQuestIds.contains(id)) {
                    setState(() => _completedQuestIds.add(id));
                    await _saveData();
                    _award(int.tryParse(quest['reward'] ?? '5') ?? 5, 'Quête accomplie');
                  }
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } catch (error) {
                  setDialogState(() { checking = false; feedback = 'Validation impossible : $error'; });
                }
              },
              child: const Text('Soumettre pour vérification'),
            ),
          ],
        ),
      ),
    );
    answerController.dispose();
  }

  Future<void> _openCourseSecretQuest(Course course) async {
    final alreadyDone = _completedSecretCourseNames.contains(course.name);
    await _navigatorKey.currentState!.push(MaterialPageRoute(
      builder: (_) => CourseSecretQuestPage(
        course: course,
        alreadyCompleted: alreadyDone,
        onCompleted: () {
          if (_completedSecretCourseNames.contains(course.name)) return;
          setState(() => _completedSecretCourseNames.add(course.name));
          _saveData();
          _award(2, 'Quête secrète de ${course.name} terminée');
        },
      ),
    ));
  }

  Future<void> _deleteCourses(List<Course> selected) async {
    if (selected.isEmpty) return;
    final names = selected.map((c) => c.name).toSet();
    setState(() {
      _courses.removeWhere((c) => names.contains(c.name));
      _completedSecretCourseNames.removeAll(names);
    });
    await _saveData();
    if (mounted) _messengerKey.currentState?.showSnackBar(SnackBar(content: Text('${names.length} matière(s) supprimée(s).')));
  }


  void _addCourse() {
    final nameController = TextEditingController();
    final contentController = TextEditingController();
    showDialog(
      context: _navigatorKey.currentContext!,
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
            onPressed: () async {
              final name = nameController.text.trim();              if (name.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Donne un nom à cette matière.')),
                );
                return;
              }
              final normalized = name.toLowerCase();
              if (_courses.any((course) => course.name.trim().toLowerCase() == normalized)) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Cette matière existe déjà.')),
                );
                return;
              }
              final content = contentController.text.trim();
              final course = Course(
                name: name,
                detail: content.isEmpty
                    ? 'Nouvel espace de cours'
                    : 'Cours ajouté • ${content.length} caractères',
                icon: Icons.auto_stories,
                content: content,
              );
              setState(() => _courses.add(course));
              Navigator.pop(ctx);
              try {
                await _saveData();
                if (mounted) {
                  _messengerKey.currentState!.showSnackBar(
                    SnackBar(content: Text('Matière « $name » créée et enregistrée.')),
                  );
                }
              } catch (error) {
                if (mounted) {
                  _messengerKey.currentState!.showSnackBar(
                    SnackBar(content: Text('Matière créée sur cet appareil ; synchronisation à réessayer : $error')),
                  );
                }
              }
            },
            child: const Text('Créer'),
          ),
        ],
      ),
    ).then((_) { nameController.dispose(); contentController.dispose(); });
  }
  Future<void> _takeCoursePhoto() async {
    try {
      final photo = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 82, maxWidth: 2200);
      if (photo == null) return;
      final bytes = await photo.readAsBytes();
      if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
        throw Exception('La photo doit faire moins de 8 Mo. Reprends-la avec une résolution plus faible.');
      }
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Connecte-toi à ton compte Firebase.');
      final token = await user.getIdToken(true);
      final response = await http.post(
        Uri.parse('https://studymind-assistant-2026.kayumbagradel05.workers.dev/api/generate'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
        body: jsonEncode({'task': 'extract_course', 'course': 'Cours photographié', 'imageBase64': base64Encode(bytes), 'mimeType': photo.mimeType ?? 'image/jpeg'}),
      ).timeout(const Duration(seconds: 100));
      final decoded = jsonDecode(response.body);
      final data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(data['error']?.toString() ?? 'Extraction impossible (HTTP ${response.statusCode}).');
      }
      final extracted = data['content']?.toString().trim() ?? '';
      if (extracted.length < 30) throw Exception('Le texte de la photo est trop court ou illisible. Reprends la photo avec une bonne lumière.');
      final extractedLines = extracted.split('\n');
      final titleLine = extractedLines.isNotEmpty ? extractedLines.first.trim() : '';
      final title = titleLine.toUpperCase().startsWith('TITRE:')
          ? titleLine.substring(6).trim()
          : 'Cours photographié';
      final content = title == 'Cours photographié' ? extracted : extractedLines.skip(1).join('\n').trim();
      if (_courses.any((c) => c.name.trim().toLowerCase() == title.toLowerCase())) {
        throw Exception('Une matière portant ce nom existe déjà.');
      }
      final course = Course(name: title, detail: 'Cours photographié • ${content.length} caractères', icon: Icons.camera_alt_outlined, content: content.isEmpty ? extracted : content);
      setState(() => _courses.add(course));
      await _saveData();
      if (!mounted) return;
      _messengerKey.currentState?.showSnackBar(SnackBar(content: Text('Matière « $title » créée à partir de la photo.')));
      _showSummary(course);
    } catch (error) {
      if (!mounted) return;
      _messengerKey.currentState?.showSnackBar(SnackBar(content: Text('Photo du cours impossible : $error')));
    }
  }

  Future<void> _generateExerciseWorksheet(Course course) async {
    if (course.content.trim().length < 20) {
      _messengerKey.currentState?.showSnackBar(const SnackBar(content: Text('Ajoute le contenu du cours avant de créer une feuille d’exercices.')));
      return;
    }
    showDialog(context: _navigatorKey.currentContext!, barrierDismissible: false, builder: (_) => const AlertDialog(content: Row(children: [CircularProgressIndicator(), SizedBox(width: 14), Expanded(child: Text('KING prépare ta feuille d’exercices…'))])));
    try {
      final content = await _generateStudyContent(task: 'worksheet', course: course, difficulty: 'Progressif');
      try { await _saveStudyArtifact('worksheet', course, content); } catch (e) { debugPrint('Worksheet archive failed: $e'); }
      if (!mounted) return;
      _navigatorKey.currentState?.pop();
      final document = PdfDocument();
      try {
        final page = document.pages.add();
        final printable = 'Kavelynt • ${course.name}\nFEUILLE D’EXERCICES\n\n$content\n\nNom : __________________________    Date : ______________';
        PdfTextElement(text: printable, font: PdfStandardFont(PdfFontFamily.helvetica, 11)).draw(
          page: page,
          bounds: Rect.fromLTWH(36, 36, page.getClientSize().width - 72, page.getClientSize().height - 72),
          format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
        );
        final bytes = Uint8List.fromList(await document.save());
        await Printing.layoutPdf(name: 'Kavelynt-exercices.pdf', onLayout: (_) async => bytes);
      } finally {
        document.dispose();
      }
    } catch (error) {
      if (!mounted) return;
      _navigatorKey.currentState?.pop();
      _messengerKey.currentState?.showSnackBar(SnackBar(content: Text('Feuille d’exercices impossible : $error')));
    }
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
      final bytes = file.bytes ?? (file.path != null ? await readLocalFileBytes(file.path!) : null);
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
      _messengerKey.currentState!.showSnackBar(const SnackBar(content: Text('Cours importé et enregistré sur cet appareil.')));
      _showSummary(course);
    } catch (error) {
      if (!mounted) return;
      _messengerKey.currentState!.showSnackBar(SnackBar(content: Text('Import impossible : $error')));
    }
  }

  Future<void> _showSummary(Course course) async {
    if (course.content.trim().length < 20) {
      _comingSoon(_navigatorKey.currentContext!, 'Ajoute le contenu de cette matière avec Importer un cours pour créer une fiche IA.');
      return;
    }
    showDialog(context: _navigatorKey.currentContext!, barrierDismissible: false, builder: (ctx) => const AlertDialog(content: Row(children: [CircularProgressIndicator(), SizedBox(width: 16), Expanded(child: Text('KING prépare ta fiche de révision…'))])));
    try {
      final generated = await _generateStudyContent(task: 'revision', course: course);
      // L'affichage ne dépend pas des règles Firestore : conserver la fiche même
      // si son archivage cloud échoue.
      try { await _saveStudyArtifact('revision', course, generated); }
      catch (saveError) { debugPrint('Kavelynt fiche non archivée : $saveError'); }
      if (!mounted) return;
      _navigatorKey.currentState?.pop();
      showDialog(context: _navigatorKey.currentContext!, builder: (ctx) => AlertDialog(title: Text('Fiche IA • ${course.name}'), content: SizedBox(width: double.maxFinite, child: SingleChildScrollView(child: SelectableText(generated))), actions: [TextButton(onPressed: () { Navigator.pop(ctx); _navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => const StudyArtifactArchivePage())); }, child: const Text('Mes documents')), TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer'))]));
    } catch (error) {
      if (!mounted) return;
      _navigatorKey.currentState?.pop();
      _messengerKey.currentState!.showSnackBar(SnackBar(content: Text('Création de fiche impossible : $error')));
    }
  }
  void _openExercise(Course course) {
    final exerciseId = course.name;
    Navigator.push(
      _navigatorKey.currentContext!,
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

class _RankPromotionDialog extends StatefulWidget {
  const _RankPromotionDialog({required this.previousRank, required this.rank});

  final String previousRank;
  final String rank;

  @override
  State<_RankPromotionDialog> createState() => _RankPromotionDialogState();
}

class _RankPromotionDialogState extends State<_RankPromotionDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..forward();

  Color get _accent {
    switch (widget.rank) {
      case 'SSS': return const Color(0xFFFFD76A);
      case 'SS': return const Color(0xFFCF9BFF);
      case 'S': return const Color(0xFFFFB65C);
      case 'A': return const Color(0xFF69D8FF);
      case 'B': return const Color(0xFF70E0B0);
      case 'C': return const Color(0xFF8DB7FF);
      case 'D': return const Color(0xFFB5C7D8);
      default: return const Color(0xFF72CFFF);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final pulse = 0.88 + (_controller.value * 0.12);
          return Transform.scale(
            scale: pulse,
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 30, 24, 24),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF142C48), Color(0xFF071321), Color(0xFF102B45)],
                ),
                border: Border.all(color: _accent.withValues(alpha: 0.8), width: 1.8),
                boxShadow: [
                  BoxShadow(color: _accent.withValues(alpha: 0.32 * _controller.value), blurRadius: 38, spreadRadius: 5),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Opacity(
                    opacity: Curves.easeOut.transform(_controller.value.clamp(0.0, 1.0)),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Icon(Icons.auto_awesome, color: _accent, size: 25),
                        Icon(Icons.stars_rounded, color: _accent, size: 38),
                        Icon(Icons.auto_awesome, color: _accent, size: 25),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text('PROMOTION !', style: TextStyle(color: _accent, fontSize: 17, fontWeight: FontWeight.w900, letterSpacing: 3)),
                  const SizedBox(height: 8),
                  const Text('NOUVEAU RANG DÉBLOQUÉ', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 1.4, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 18),
                  Text(
                    widget.rank,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 76,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 4,
                      shadows: [Shadow(color: _accent.withValues(alpha: 0.9), blurRadius: 28)],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Rang ${widget.previousRank}  →  ${widget.rank}', style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 22),
                  Text('Ton travail porte ses fruits.', textAlign: TextAlign.center, style: TextStyle(color: _accent, fontSize: 15, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: _accent, foregroundColor: const Color(0xFF071321), padding: const EdgeInsets.symmetric(vertical: 14)),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('CONTINUER', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Dashboard extends StatelessWidget {
  const _Dashboard({required this.points, required this.rank, required this.nextRankAt, required this.courses, required this.onOpenCourses, required this.onOpenQuests});
  final int points, nextRankAt;
  final String rank;
  final List<Course> courses;
  final VoidCallback onOpenCourses, onOpenQuests;

  @override
  Widget build(BuildContext context) {
    final previous = _previousThreshold(points);
    final progress = points >= 5000 ? 1.0 : ((points - previous) / (nextRankAt - previous)).clamp(0.0, 1.0);
    final remaining = points >= 5000 ? 0 : nextRankAt - points;
    return Container(
      decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter,end: Alignment.bottomCenter,colors:[Color(0xFF100522),Color(0xFF070311),Color(0xFF030109)])),
      child: Stack(children:[
        Positioned(top:20,right:-60,child:_orb(200,kavelyntPurple)),
        Positioned(top:360,left:-70,child:_orb(190,const Color(0xFF5B16D6))),
        ListView(padding:const EdgeInsets.fromLTRB(18,14,18,30),children:[
          Row(children:[
            Container(width:48,height:48,decoration:BoxDecoration(borderRadius:BorderRadius.circular(15),gradient:const LinearGradient(colors:[Color(0xFF4A00C8),Color(0xFFB000FF)]),boxShadow:[BoxShadow(color:kavelyntPurple.withOpacity(.5),blurRadius:20)]),child:const Icon(Icons.auto_awesome,color:Colors.white,size:29)),
            const SizedBox(width:12),
            const Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('Kavelynt',style:TextStyle(fontSize:22,fontWeight:FontWeight.w900,color:Colors.white)),Text('Apprendre • Réviser • Réussir',style:TextStyle(color:Color(0xFFB98BFF),fontSize:11,fontWeight:FontWeight.w600))])),
            _pill(Icons.workspace_premium,'Rang $rank',kavelyntPurple),
            const SizedBox(width:6),
            _pill(Icons.star_rounded,'$points XP',kavelyntGold),
          ]),
          const SizedBox(height:22),
          Container(padding:const EdgeInsets.all(20),decoration:BoxDecoration(borderRadius:BorderRadius.circular(28),gradient:const LinearGradient(begin:Alignment.topLeft,end:Alignment.bottomRight,colors:[Color(0xFF241044),Color(0xFF10051F),Color(0xFF090313)]),border:Border.all(color:kavelyntPurple.withOpacity(.8)),boxShadow:[BoxShadow(color:kavelyntPurple.withOpacity(.22),blurRadius:28),BoxShadow(color:kavelyntGold.withOpacity(.08),blurRadius:35)]),
            child:Column(children:[
              Row(children:[
                Container(width:62,height:62,decoration:BoxDecoration(shape:BoxShape.circle,color:kavelyntPurple.withOpacity(.18),border:Border.all(color:kavelyntGold,width:1.5)),child:const Icon(Icons.workspace_premium,color:kavelyntGold,size:36)),
                const SizedBox(width:14),
                Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  const Text('TON RANG ACTUEL',style:TextStyle(color:Color(0xFFC49AFF),fontSize:11,letterSpacing:1.5,fontWeight:FontWeight.bold)),
                  Text('Rang $rank',style:const TextStyle(color:Colors.white,fontSize:23,fontWeight:FontWeight.w900)),
                  Text(points>=5000?'Rang maximal atteint':'Encore $remaining XP pour progresser',style:const TextStyle(color:Color(0xFFBDA8D7),fontSize:11)),
                ])),
                const Icon(Icons.auto_awesome,color:kavelyntGold,size:30),
              ]),
              const SizedBox(height:20),
              Container(width:116,height:116,decoration:BoxDecoration(shape:BoxShape.circle,gradient:const LinearGradient(colors:[Color(0xFFFFE28A),Color(0xFFFFA900),Color(0xFFB95B00)]),border:Border.all(color:const Color(0xFFFFF0B8),width:2),boxShadow:[BoxShadow(color:kavelyntGold.withOpacity(.65),blurRadius:28,spreadRadius:3),BoxShadow(color:kavelyntPurple.withOpacity(.7),blurRadius:35,spreadRadius:8)]),child:Center(child:Text(rank,style:const TextStyle(color:Color(0xFF35104F),fontSize:58,fontWeight:FontWeight.w900,shadows:[Shadow(color:Colors.white54,blurRadius:8)])))),
              const SizedBox(height:12),
              const Text('TON RANG • TON ASCENSION',style:TextStyle(color:kavelyntGold,fontSize:12,fontWeight:FontWeight.w900,letterSpacing:1.8)),
              const SizedBox(height:18),
              ClipRRect(borderRadius:BorderRadius.circular(30),child:Stack(children:[
                Container(height:13,color:Colors.white.withOpacity(.09)),
                FractionallySizedBox(widthFactor:progress,child:Container(height:13,decoration:const BoxDecoration(gradient:LinearGradient(colors:[Color(0xFF8B2CFF),Color(0xFFE04DFF),Color(0xFFFFC83D)])))),
              ])),
              const SizedBox(height:8),
              Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Text('$points XP',style:const TextStyle(color:Color(0xFFE6D5FF),fontSize:12,fontWeight:FontWeight.bold)),Text(points>=5000?'MAX':'$nextRankAt XP',style:const TextStyle(color:kavelyntGold,fontSize:12,fontWeight:FontWeight.bold))]),
              const SizedBox(height:17),
              Container(padding:const EdgeInsets.symmetric(horizontal:14,vertical:11),decoration:BoxDecoration(color:const Color(0xFF170A2B),borderRadius:BorderRadius.circular(16),border:Border.all(color:kavelyntGold.withOpacity(.8))),child:Row(mainAxisAlignment:MainAxisAlignment.center,children:[const Icon(Icons.bolt,color:kavelyntGold,size:20),const SizedBox(width:7),Text(points>=5000?'RANG SUPRÊME ATTEINT':'PROCHAIN OBJECTIF : $nextRankAt XP',style:const TextStyle(color:kavelyntGold,fontSize:11,fontWeight:FontWeight.w900,letterSpacing:.6))])),
            ]),
          ),
          const SizedBox(height:18),
          Row(children:[
            Expanded(child:_stat(Icons.menu_book_rounded,'${courses.length}','Matières',const Color(0xFFB76BFF))),
            const SizedBox(width:9),
            Expanded(child:_stat(Icons.star_rounded,'$points','XP gagnés',kavelyntGold)),
            const SizedBox(width:9),
            Expanded(child:_stat(Icons.local_fire_department_rounded,'∞','Progression',const Color(0xFFFF8B5B))),
          ]),
          const SizedBox(height:22),
          const Text('TON PARCOURS',style:TextStyle(color:Color(0xFFC49AFF),fontSize:12,fontWeight:FontWeight.w900,letterSpacing:1.8)),
          const SizedBox(height:12),
          Row(children:[
            Expanded(child:_feature(Icons.menu_book_rounded,'Mes cours','Apprendre et réviser',onOpenCourses)),
            const SizedBox(width:12),
            Expanded(child:_feature(Icons.flag_rounded,'Quêtes','Défis et récompenses',onOpenQuests)),
          ]),
          const SizedBox(height:20),
          Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('MES MATIÈRES',style:TextStyle(color:Color(0xFFC49AFF),fontSize:12,fontWeight:FontWeight.w900,letterSpacing:1.8)),TextButton(onPressed:onOpenCourses,child:const Text('Tout voir',style:TextStyle(color:kavelyntGold)))]),
          if(courses.isEmpty)_feature(Icons.add_circle_outline,'Ajouter une matière','Commence ton parcours',onOpenCourses)
          else ...courses.take(3).map((course)=>Container(margin:const EdgeInsets.only(bottom:9),decoration:BoxDecoration(color:const Color(0xFF120822),borderRadius:BorderRadius.circular(17),border:Border.all(color:kavelyntPurple.withOpacity(.35))),child:ListTile(leading:Icon(course.icon,color:const Color(0xFFC18AFF)),title:Text(course.name,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.bold)),subtitle:Text(course.detail,style:const TextStyle(color:Color(0xFFB6A5C9))),trailing:const Icon(Icons.chevron_right,color:kavelyntGold),onTap:onOpenCourses))),
        ]),
      ]),
    );
  }

  Widget _pill(IconData icon,String label,Color color)=>Container(padding:const EdgeInsets.symmetric(horizontal:8,vertical:8),decoration:BoxDecoration(color:color.withOpacity(.13),borderRadius:BorderRadius.circular(24),border:Border.all(color:color.withOpacity(.65))),child:Row(mainAxisSize:MainAxisSize.min,children:[Icon(icon,size:14,color:color),const SizedBox(width:4),Text(label,style:TextStyle(color:color,fontSize:10,fontWeight:FontWeight.w900))]));
  Widget _stat(IconData icon,String value,String label,Color color)=>Container(padding:const EdgeInsets.symmetric(vertical:14,horizontal:5),decoration:BoxDecoration(color:const Color(0xFF120822),borderRadius:BorderRadius.circular(16),border:Border.all(color:color.withOpacity(.35))),child:Column(children:[Icon(icon,color:color,size:22),const SizedBox(height:6),Text(value,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w900,fontSize:16)),Text(label,textAlign:TextAlign.center,style:const TextStyle(color:Color(0xFFB6A5C9),fontSize:10))]));
  Widget _feature(IconData icon,String title,String subtitle,VoidCallback action)=>InkWell(onTap:action,borderRadius:BorderRadius.circular(18),child:Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:const Color(0xFF16092A),borderRadius:BorderRadius.circular(18),border:Border.all(color:kavelyntPurple.withOpacity(.55)),boxShadow:[BoxShadow(color:kavelyntPurple.withOpacity(.10),blurRadius:16)]),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Icon(icon,color:kavelyntGold,size:25),const SizedBox(height:12),Text(title,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w900,fontSize:14)),const SizedBox(height:4),Text(subtitle,style:const TextStyle(color:Color(0xFFB6A5C9),fontSize:11))])));
  Widget _orb(double size,Color color)=>IgnorePointer(child:Container(width:size,height:size,decoration:BoxDecoration(shape:BoxShape.circle,gradient:RadialGradient(colors:[color.withOpacity(.18),color.withOpacity(.04),Colors.transparent]))));
}

int _previousThreshold(int points) {
  if (points >= 5000) return 5000;
  if (points >= 3000) return 3000;
  if (points >= 1500) return 1500;
  if (points >= 750) return 750;
  if (points >= 350) return 350;
  if (points >= 150) return 150;
  if (points >= 50) return 50;
  return 0;
}


class _CoursesPage extends StatefulWidget {
  const _CoursesPage({
    required this.courses, required this.onAdd, required this.onExercise,
    required this.onImport, required this.onTakePhoto, required this.onWorksheet,
    required this.onSummary, required this.onSecretQuest,
    required this.onDeleteCourses, required this.onArchive,
  });
  final List<Course> courses;
  final VoidCallback onAdd;
  final void Function(Course) onExercise;
  final VoidCallback onImport;
  final VoidCallback onTakePhoto;
  final void Function(Course) onWorksheet;
  final void Function(Course) onSummary;
  final void Function(Course) onSecretQuest;
  final void Function(List<Course>) onDeleteCourses;
  final VoidCallback onArchive;
  @override
  State<_CoursesPage> createState() => _CoursesPageState();
}

class _CoursesPageState extends State<_CoursesPage> {
  final Set<String> _selected = {};

  Future<void> _confirmDelete() async {
    final chosen = widget.courses.where((c) => _selected.contains(c.name)).toList();
    if (chosen.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer les matières ?'),
        content: Text('Supprimer ${chosen.length} matière(s) sélectionnée(s) ? Cette action ne peut pas être annulée.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Supprimer')),
        ],
      ),
    );
    if (confirmed == true) {
      widget.onDeleteCourses(chosen);
      setState(() => _selected.clear());
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(18),
    children: [
      _pageHeader('BIBLIOTHÈQUE', 'Tes espaces de connaissances'),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: FilledButton.icon(onPressed: widget.onAdd, icon: const Icon(Icons.add), label: const Text('Créer une matière'))),
        const SizedBox(width: 8),
        IconButton(
          tooltip: _selected.isEmpty ? 'Tout sélectionner' : 'Supprimer les matières sélectionnées',
          onPressed: _selected.isEmpty ? () => setState(() => _selected.addAll(widget.courses.map((c) => c.name))) : _confirmDelete,
          icon: Icon(_selected.isEmpty ? Icons.checklist : Icons.delete_outline, color: _selected.isEmpty ? systemBlue : Colors.redAccent),
        ),
        if (_selected.isNotEmpty) IconButton(tooltip: 'Annuler la sélection', onPressed: () => setState(() => _selected.clear()), icon: const Icon(Icons.close)),
      ]),
      if (_selected.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('${_selected.length} matière(s) sélectionnée(s)', style: const TextStyle(color: systemBlue))),
      const SizedBox(height: 12),
      OutlinedButton.icon(onPressed: widget.onImport, icon: const Icon(Icons.upload_file), label: const Text('Importer un cours (PDF, TXT, MD)')),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: widget.onTakePhoto, icon: const Icon(Icons.photo_camera_outlined), label: const Text('Photographier un cours et créer une matière')),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: widget.onArchive, icon: const Icon(Icons.inventory_2_outlined), label: const Text('Mes fiches et exercices enregistrés')),
      const SizedBox(height: 14),
      ...widget.courses.map((course) => Card(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(children: [
            ListTile(
              leading: Checkbox(value: _selected.contains(course.name), onChanged: (value) => setState(() { if (value == true) { _selected.add(course.name); } else { _selected.remove(course.name); } })),
              title: Text(course.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(course.detail),
            ),
            Row(children: [
              Expanded(child: TextButton.icon(onPressed: () => widget.onSummary(course), icon: const Icon(Icons.summarize_outlined), label: const Text('Fiche'))),
              Expanded(child: TextButton.icon(onPressed: () => widget.onSecretQuest(course), icon: const Icon(Icons.visibility_off_outlined), label: const Text('Quête secrète'))),
              Expanded(child: FilledButton.tonalIcon(onPressed: () => widget.onExercise(course), icon: const Icon(Icons.play_arrow), label: const Text('Exercices'))),
            ]),
            Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: () => widget.onWorksheet(course), icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('Créer une feuille PDF à imprimer'))),
          ]),
        ),
      )),
      const SizedBox(height: 12),
      const Text('Astuce : crée une matière pour organiser tes révisions par cours.', style: TextStyle(color: Colors.white60)),
    ],
  );
}


class StudyArtifactArchivePage extends StatefulWidget {
  const StudyArtifactArchivePage({super.key});
  @override
  State<StudyArtifactArchivePage> createState() => _StudyArtifactArchivePageState();
}

class _StudyArtifactArchivePageState extends State<StudyArtifactArchivePage> {
  List<Map<String, dynamic>> _localArtifacts = [];
  List<Map<String, dynamic>> _visibleDocs = [];
  final Set<String> _selected = {};
  bool _selectionMode = false;

  @override
  void initState() { super.initState(); _loadLocalArtifacts(); }

  Future<void> _loadLocalArtifacts() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = prefs.getString('studyArtifacts');
      final decoded = raw == null ? <dynamic>[] : jsonDecode(raw) as List<dynamic>;
      if (mounted) setState(() => _localArtifacts = decoded.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList());
    } catch (error) { debugPrint('Kavelynt local archive load failed: $error'); }
  }

  Future<void> _deleteOne(Map<String, dynamic> document) async {
    final key = document['_key']?.toString();
    if (key == null || key.isEmpty) return;
    setState(() {
      _selectionMode = true;
      _selected
        ..clear()
        ..add(key);
    });
    await _deleteSelected();
  }

  Future<void> _deleteSelected() async {
    final chosen = _visibleDocs.where((d) => _selected.contains(d['_key']?.toString())).toList();
    if (chosen.isEmpty) return;
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Supprimer les documents ?'),
      content: Text('Supprimer ${chosen.length} document(s) sélectionné(s) ?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Supprimer')),
      ],
    ));
    if (confirmed != true) return;
    final user = FirebaseAuth.instance.currentUser;
    final cloudIds = chosen.where((d) => d['_cloudId'] != null).map((d) => d['_cloudId'].toString()).toSet();
    final localKeys = chosen.where((d) => d['_localKey'] != null).map((d) => d['_localKey'].toString()).toSet();
    if (user != null) {
      final collection = FirebaseFirestore.instance.collection('users').doc(user.uid).collection('studyArtifacts');
      for (final id in cloudIds) { try { await collection.doc(id).delete(); } catch (e) { debugPrint('Artifact cloud delete failed: $e'); } }
    }
    final updated = _localArtifacts.where((item) {
      final id = item['id']?.toString();
      final fallback = 'local:${item['type']}:${item['course']}:${item['createdAt']}:${item['content']}';
      return !(id != null && localKeys.contains(id)) && !localKeys.contains(fallback);
    }).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('studyArtifacts', jsonEncode(updated));
    if (mounted) setState(() { _localArtifacts = updated; _selected.clear(); _selectionMode = false; });
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final stream = user == null ? null : FirebaseFirestore.instance.collection('users').doc(user.uid).collection('studyArtifacts').orderBy('createdAt', descending: true).snapshots();
    return Scaffold(
      appBar: AppBar(
        title: const Text('MES DOCUMENTS ENREGISTRÉS'),
        actions: [
          IconButton(tooltip: _selectionMode ? 'Annuler la sélection' : 'Sélectionner plusieurs documents', onPressed: () => setState(() { _selectionMode = !_selectionMode; _selected.clear(); }), icon: Icon(_selectionMode ? Icons.close : Icons.checklist)),
          if (_selectionMode) IconButton(tooltip: 'Supprimer la sélection', onPressed: _selected.isEmpty ? null : _deleteSelected, icon: const Icon(Icons.delete_outline, color: Colors.redAccent)),
        ],
      ),
      body: user == null ? _buildLocalArtifactList() : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: stream,
        builder: (context, snapshot) {
          final cloud = snapshot.hasData ? snapshot.data!.docs.map((doc) => <String,dynamic>{...doc.data(), '_cloudId':doc.id}).toList() : <Map<String,dynamic>>[];
          final combined = _buildCombined(cloud);
          _visibleDocs = combined;
          if (snapshot.hasError && combined.isEmpty) return const Center(child: Text('Impossible de charger les documents. Réessaie plus tard.'));
          if (!snapshot.hasData && _localArtifacts.isEmpty) return const Center(child: CircularProgressIndicator());
          return _buildArtifactList(combined);
        },
      ),
    );
  }

  Widget _buildLocalArtifactList() {
    final combined = _buildCombined(const []);
    _visibleDocs = combined;
    return _buildArtifactList(combined);
  }

  List<Map<String,dynamic>> _buildCombined(List<Map<String,dynamic>> cloud) {
    final combined = <Map<String,dynamic>>[...cloud];
    for (final local in _localArtifacts) {
      final id = local['id']?.toString();
      final localKey = id ?? 'local:${local['type']}:${local['course']}:${local['createdAt']}:${local['content']}';
      final duplicateIndex = combined.indexWhere((c) => c['type']==local['type'] && c['course']==local['course'] && c['content']==local['content']);
      if (duplicateIndex >= 0) {
        combined[duplicateIndex]['_localKey'] = localKey;
      } else {
        combined.add({...local, '_localKey':localKey, '_key':'local:$localKey'});
      }
    }
    for (var i=0;i<combined.length;i++) {
      combined[i]['_key'] ??= 'cloud:${combined[i]['_cloudId'] ?? combined[i]['id'] ?? i}';
    }
    return combined;
  }

  Widget _buildArtifactList(List<Map<String, dynamic>> docs) {
    if (docs.isEmpty) return const Center(child: Text('Aucune fiche ou aucun exercice enregistré pour le moment.'));
    return ListView.builder(
      padding: const EdgeInsets.all(16), itemCount: docs.length,
      itemBuilder: (context,index) {
        final data=docs[index];
        final revision=data['type']=='revision';
        final title='${revision ? 'Fiche de révision' : 'Exercice'} • ${data['course'] ?? 'Cours'}';
        final createdAt=data['createdAt'];
        final dateLabel=createdAt is Timestamp ? createdAt.toDate().toLocal().toString().substring(0,16) : createdAt is String ? (DateTime.tryParse(createdAt)?.toLocal().toString().substring(0,16) ?? 'Enregistré') : 'Enregistré';
        return Card(child: ListTile(
          leading: _selectionMode ? Checkbox(value:_selected.contains(data['_key']),onChanged:(v)=>setState(()=>v==true?_selected.add(data['_key'].toString()):_selected.remove(data['_key'].toString()))) : Icon(revision?Icons.summarize_outlined:Icons.assignment_outlined,color:systemBlue),
          title:Text(title),subtitle:Text(dateLabel),trailing:_selectionMode?null:IconButton(tooltip:'Supprimer ce document',onPressed:()=>_deleteOne(data),icon:const Icon(Icons.delete_outline,color:Colors.redAccent)),
          onTap: _selectionMode ? ()=>setState(()=>_selected.contains(data['_key'])?_selected.remove(data['_key']):_selected.add(data['_key'].toString())) : ()=>showDialog(context:context,builder:(dialogContext)=>AlertDialog(
            title:Text(title),content:SizedBox(width:double.maxFinite,child:SingleChildScrollView(child:SelectableText(data['content']?.toString()??'Contenu indisponible.'))),
            actions:[TextButton(onPressed:()=>Navigator.pop(dialogContext),child:const Text('Fermer'))],
          )),
        ));
      },
    );
  }
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
  // Une ancienne réussite ne doit pas empêcher de générer un nouvel exercice.
  // Les PR restent protégés contre les doublons dans le parent.
  bool _submitted = false;
  bool _rewardClaimed = false;
  final TextEditingController _answer = TextEditingController();
  String _feedback = '';
  String? _generatedQuestion;
  bool _aiBusy = false;

  @override
  void initState() {
    super.initState();    _rewardClaimed = widget.alreadySubmitted;
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
    ).timeout(const Duration(seconds: 100));
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(response.body);
      data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      throw Exception('Réponse IA illisible (HTTP ${response.statusCode}).');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(data['error']?.toString() ?? 'Service IA indisponible (HTTP ${response.statusCode}).');
    }
    final content = data['content']?.toString() ?? '';
    if (content.trim().isEmpty) throw Exception('Le service IA n’a renvoyé aucun exercice.');
    return content;
  }

  Future<void> _saveGeneratedExercise(String content) async {
    final prefs = await SharedPreferences.getInstance();
    List<dynamic> saved = [];
    try {
      final raw = prefs.getString('studyArtifacts');
      if (raw != null) saved = jsonDecode(raw) as List<dynamic>;
    } catch (_) {}
    final artifactId = 'artifact-${DateTime.now().microsecondsSinceEpoch}';
    saved.insert(0, {
      'id': artifactId,
      'type': 'exercise', 'course': widget.course.name, 'content': content,
      'difficulty': _difficulty, 'createdAt': DateTime.now().toIso8601String(),
    });
    if (saved.length > 100) saved = saved.take(100).toList();
    await prefs.setString('studyArtifacts', jsonEncode(saved));

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        await FirebaseFirestore.instance.collection('users').doc(user.uid).collection('studyArtifacts').doc(artifactId).set({
          'id': artifactId, 'type': 'exercise', 'course': widget.course.name, 'content': content, 'difficulty': _difficulty, 'createdAt': FieldValue.serverTimestamp(),
        });
      } catch (error) {
        debugPrint('Kavelynt exercise cloud archive failed; local copy kept: $error');
      }
    }
  }
  Future<void> _generateAiExercise() async {
    if (_aiBusy) return;
    if (widget.course.content.trim().length < 20) {
      setState(() => _feedback = 'Ajoute le contenu du cours pour générer un exercice personnalisé.');
      return;
    }
    setState(() {
      _aiBusy = true;
      _feedback = 'KING prépare un nouvel exercice…';
      _generatedQuestion = null;
      _answer.clear();
      _submitted = false;
    });
    try {
      final generated = await _callStudyAi('exercise');
      // Ne pas perdre l'exercice généré si l'archivage Firestore échoue.
      try { await _saveGeneratedExercise(generated); }
      catch (saveError) { debugPrint('Kavelynt exercice non archivé : $saveError'); }
      final marker = RegExp(r'^\s*(?:#+\s*)?CORRECTION(?:\s+DÉTAILLÉE)?\s*:?', multiLine: true, caseSensitive: false).firstMatch(generated);
      final question = marker == null ? generated : generated.substring(0, marker.start).trim();
      if (mounted && question.isNotEmpty) setState(() { _generatedQuestion = question; });
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
      final lesson = widget.course.content.toLowerCase();
      if ((lesson.contains('addition') || lesson.contains('somme')) &&
          (lesson.contains('nombre rond') || lesson.contains('nombres ronds') || lesson.contains('centaine') || lesson.contains('dizaine'))) {
        return 'Calcule 300 + 400, puis explique comment tu as additionné ces nombres ronds.';
      }
      return 'À partir de la leçon fournie, résous un calcul portant uniquement sur la notion étudiée et explique brièvement ta méthode.';
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
      final lesson = widget.course.content.toLowerCase();
      if ((lesson.contains('addition') || lesson.contains('somme')) &&
          (lesson.contains('nombre rond') || lesson.contains('nombres ronds') || lesson.contains('centaine') || lesson.contains('dizaine'))) {
        return answer.contains('700') || answer.contains('sept cents') || answer.contains('sept cent');
      }
      return answer.isNotEmpty;
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
                  if (widget.course.content.trim().length >= 20)
                    Align(alignment: Alignment.centerRight, child: TextButton.icon(
                      onPressed: _aiBusy ? null : () {
                        setState(() {
                          _submitted = false;
                          _answer.clear();
                          _feedback = '';
                          _generatedQuestion = null;
                        });
                        _generateAiExercise();
                      },
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Générer un nouvel exercice'),
                    )),
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
            Text(
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
        final correct = _hasPositiveAiVerdict(correction);
        if (!mounted) return;
        setState(() { _feedback = correction; _submitted = correct; });
        if (correct) {
          widget.onSubmitted();
          if (!_rewardClaimed) {
            _rewardClaimed = true;
            widget.onAward(_reward, 'Exercice réussi');
          }
        }
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
    if (!_rewardClaimed) {
      _rewardClaimed = true;
      widget.onAward(_reward, 'Exercice réussi');
    }
  }
}


class _QuestsPage extends StatelessWidget {
  const _QuestsPage({
    required this.dailyDone, required this.quests, required this.completedQuestIds,
    required this.loading, required this.generationsUsed, required this.onRefresh,
    required this.onVerifyQuest,
  });
  final bool dailyDone, loading;
  final List<Map<String,String>> quests;
  final Set<String> completedQuestIds;
  final int generationsUsed;
  final VoidCallback onRefresh;
  final Future<void> Function(Map<String,String>) onVerifyQuest;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(18),
    children: [
      _pageHeader('JOURNAL DES QUÊTES', 'Missions adaptées à tes cours • renouvellement tous les 14 jours'),
      const SizedBox(height:14),
      _questCard('MISSION QUOTIDIENNE','Échauffement intellectuel',dailyDone?'Mission accomplie.':'Termine correctement un exercice.',dailyDone?'TERMINÉE':'+1 PR',Icons.task_alt,(){if(!dailyDone)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Réussis un exercice pour terminer cette mission.')));}),
      const SizedBox(height:18),
      Row(children:[
        const Expanded(child:Text('QUÊTES PERSONNALISÉES PAR IA',style:TextStyle(color:systemBlue,fontWeight:FontWeight.bold))),
        IconButton(onPressed:loading||generationsUsed>=3?null:onRefresh,icon:const Icon(Icons.refresh)),
      ]),
      Text('Générations cette semaine : $generationsUsed / 3',style:const TextStyle(color:Colors.white60,fontSize:12)),
      if(loading)const LinearProgressIndicator(),
      if(quests.isEmpty&&!loading)const Text('Ajoute le contenu de tes cours pour générer des quêtes personnalisées.'),
      ...quests.map((q){
        final id=q['id']??'';
        final done=completedQuestIds.contains(id);
        return Card(child:ListTile(
          leading:Icon((q['type']??'').toLowerCase().contains('second')?Icons.bolt:Icons.flag,color:systemBlue),
          title:Text(q['title']??'Mission'),
          subtitle:Text('${q['type']??'Quête'} • ${q['course']??''}\n${q['description']??''}'),
          isThreeLine:true,
          trailing:done?const Icon(Icons.check_circle,color:Colors.green):TextButton(onPressed:()=>onVerifyQuest(q),child:const Text('Vérifier')),
        ));
      }),
      const SizedBox(height:12),
      _panel(child:const Text('Chaque quête doit être réellement accomplie puis expliquée. KING vérifie ta réponse avant d’attribuer les PR. Tu peux générer au maximum 3 séries de quêtes IA par semaine. Les récompenses ne sont attribuées qu’une seule fois.',style:TextStyle(color:Colors.white70,height:1.4))),
    ],
  );
}

class CourseSecretQuestPage extends StatefulWidget {
  const CourseSecretQuestPage({super.key,required this.course,required this.alreadyCompleted,required this.onCompleted});
  final Course course;
  final bool alreadyCompleted;
  final VoidCallback onCompleted;
  @override
  State<CourseSecretQuestPage> createState()=>_CourseSecretQuestPageState();
}

class _CourseSecretQuestPageState extends State<CourseSecretQuestPage> {
  static const String _workerUrl='https://studymind-assistant-2026.kayumbagradel05.workers.dev/api/generate';
  final TextEditingController _answer=TextEditingController();
  Map<String,dynamic>? _quest;
  bool _busy=false;
  bool _done=false;
  String _feedback='';

  @override
  void initState(){super.initState();_done=widget.alreadyCompleted;if(!_done)_generate();}

  Future<String> _callAi(String task,{String answer=''}) async {
    final user=FirebaseAuth.instance.currentUser;
    if(user==null)throw Exception('Connexion Firebase requise.');
    final token=await user.getIdToken(true);
    final response=await http.post(Uri.parse(_workerUrl),headers:{'Content-Type':'application/json','Authorization':'Bearer $token'},body:jsonEncode({'task':task,'course':widget.course.name,'text':widget.course.content,'answer':answer})).timeout(const Duration(seconds:90));
    Map<String,dynamic> data;
    try{final decoded=jsonDecode(response.body);data=decoded is Map<String,dynamic>?decoded:<String,dynamic>{};}catch(_){throw Exception('Réponse IA illisible.');}
    if(response.statusCode<200||response.statusCode>=300)throw Exception(data['error']?.toString()??'Service IA indisponible.');
    return data['content']?.toString()??'';
  }

  Future<void> _generate() async {
    if(widget.course.content.trim().length<20){setState(()=>_feedback='Ajoute le contenu du cours pour créer une quête secrète liée à cette leçon.');return;}
    setState(()=>_busy=true);
    try{
      final raw=await _callAi('secret_quest');
      final cleaned=raw.replaceFirst(RegExp(r'^\s*\x60\x60\x60(?:json)?\s*'),'').replaceFirst(RegExp(r'\s*\x60\x60\x60\s*$'),'').trim();
      final decoded=jsonDecode(cleaned);
      if(decoded is! Map)throw Exception('Format de quête invalide.');
      if(mounted)setState(()=>_quest=Map<String,dynamic>.from(decoded));
    }catch(error){if(mounted)setState(()=>_feedback='Création impossible : $error');}
    finally{if(mounted)setState(()=>_busy=false);}
  }

  Future<void> _verify() async {
    if(_busy||_answer.text.trim().length<12||_quest==null)return;
    setState(()=>_busy=true);
    try{
      final verdict=await _callAi('quest_validation',answer:'TITRE : ${_quest!['title']}\nOBJECTIF : ${_quest!['description']}\nQUESTION : ${_quest!['question']}\nRÉPONSE DE L’ÉLÈVE : ${_answer.text.trim()}');
      final valid=_hasPositiveAiVerdict(verdict);
      if(!mounted)return;
      setState(()=>_feedback=verdict);
      if(valid&&!_done){setState(()=>_done=true);widget.onCompleted();}
    }catch(error){if(mounted)setState(()=>_feedback='Vérification impossible : $error');}
    finally{if(mounted)setState(()=>_busy=false);}
  }

  @override
  void dispose(){_answer.dispose();super.dispose();}

  @override
  Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:Text('QUÊTE SECRÈTE • ${widget.course.name}')),
    body:ListView(padding:const EdgeInsets.all(18),children:[
      _panel(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        const Text('DÉFI PERSONNALISÉ',style:TextStyle(color:systemBlue,fontWeight:FontWeight.bold,letterSpacing:1)),
        const SizedBox(height:10),
        if(_busy&&_quest==null)const LinearProgressIndicator(),
        if(_done)const Text('Cette quête secrète est déjà accomplie. Les PR ont été attribués une seule fois.',style:TextStyle(color:systemBlue)),
        if(_quest!=null)...[
          Text(_quest!['title']?.toString()??'Défi secret',style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
          const SizedBox(height:8),
          Text(_quest!['description']?.toString()??''),
          const SizedBox(height:14),
          Text(_quest!['question']?.toString()??'',style:const TextStyle(height:1.4)),
          const SizedBox(height:12),
          TextField(controller:_answer,enabled:!_done&&!_busy,maxLines:5,decoration:const InputDecoration(border:OutlineInputBorder(),hintText:'Rédige ta réponse…')),
          const SizedBox(height:12),
          FilledButton.icon(onPressed:_done||_busy?null:_verify,icon:const Icon(Icons.verified_outlined),label:const Text('Vérifier ma réponse')),
        ],
        if(_feedback.isNotEmpty)Padding(padding:const EdgeInsets.only(top:12),child:Text(_feedback,style:TextStyle(color:_done?systemBlue:Colors.orangeAccent))),
      ])),
    ]),
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
            ),            if (identity == 'PERSONNALISÉ') ...[
              const SizedBox(height: 12),
              TextField(controller: customNameController, decoration: const InputDecoration(labelText: 'Nom de l’assistant')),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: style,
              decoration: const InputDecoration(labelText: 'Personnalité'),
              items: ['Mentor', 'Professeur', 'Rival', 'Génie', 'Meilleur ami']
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
        const SizedBox(height: 16), const Text('KAVELYNT', textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 3)),
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
  bool _loadingHistory = true;
  String? _error;

  CollectionReference<Map<String, dynamic>>? get _chatMessages {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    return FirebaseFirestore.instance.collection('users').doc(uid).collection('assistantChats').doc('main').collection('messages');
  }

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final ref = _chatMessages;
      if (ref == null) return;
      final snapshot = await ref.orderBy('createdAt').get();
      if (!mounted) return;
      setState(() {
        _messages..clear()..addAll(snapshot.docs.map((doc) => {
          'role': doc.data()['role']?.toString() ?? 'assistant',
          'text': doc.data()['text']?.toString() ?? '',
        }));
      });
    } catch (error) {
      debugPrint('Kavelynt chat history load failed: $error');
      if (mounted) setState(() => _error = 'Historique non chargé : vérifie ta connexion.');
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  Future<void> _saveChatMessage(String role, String text) async {
    final ref = _chatMessages;
    if (ref == null) throw Exception('Connecte-toi pour sauvegarder cette conversation.');
    await ref.add({'role': role, 'text': text, 'createdAt': FieldValue.serverTimestamp()});
  }

  Future<void> _send() async {
    final question = _controller.text.trim();
    if (question.isEmpty || _sending) return;
    _controller.clear();
    setState(() { _messages.add({'role':'user','text':question}); _sending = true; _error = null; });
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Connecte-toi à ton compte Firebase.');
      try {
        await _saveChatMessage('user', question);
      } catch (error) {
        debugPrint('Kavelynt user chat message not saved to cloud: $error');
      }
      final token = await user.getIdToken(true);
      final response = await http.post(Uri.parse('$workerUrl/api/chat'),
        headers: {'Content-Type':'application/json','Authorization':'Bearer $token'},
        body: jsonEncode({'message':question,'mode':widget.mode,'style':widget.style,'course':widget.course,'assistantName':widget.assistantName,'context':widget.courseContext})).timeout(const Duration(seconds: 70));
      Map<String, dynamic> data;
      try {
        final decoded = jsonDecode(response.body);
        data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      } catch (_) {
        throw Exception('Réponse du serveur illisible (HTTP ${response.statusCode}).');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = data['code']?.toString() ?? '';
        if (code == 'AI_QUOTA_EXCEEDED') {
          throw Exception('KING a atteint temporairement la limite de requêtes IA. Tes messages sont conservés. Réessaie plus tard.');
        }
        if (code == 'AI_PROVIDER_UNAVAILABLE') {
          throw Exception('Le service IA est momentanément indisponible. Réessaie dans quelques instants.');
        }
        throw Exception('Impossible de contacter l’assistant pour le moment. Vérifie ta connexion puis réessaie.');
      }
      final answer = data['answer']?.toString() ?? '';
      if (answer.isEmpty) throw Exception('Gemini a renvoyé une réponse vide.');
      try {
        await _saveChatMessage('assistant', answer);
      } catch (error) {
        debugPrint('Kavelynt assistant chat message not saved to cloud: $error');
      }
      if (mounted) setState(() => _messages.add({'role':'assistant','text':answer}));
    } catch (e) { if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ','')); }
    if (mounted) setState(() => _sending = false);
  }
  @override
  void dispose() { _controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      automaticallyImplyLeading: false,
      leading: IconButton(
        tooltip: 'Retour',
        icon: const Icon(Icons.arrow_back),
        onPressed: () {
          final navigator = Navigator.of(context);
          if (navigator.canPop()) navigator.pop();
        },
      ),
      title: Text('Kavelynt • ${widget.assistantName}'),
      actions: const [],
    ),
    body: Column(children:[
      Expanded(child: _messages.isEmpty ? Center(child: Text('Pose une question à ${widget.assistantName}. Le contenu de ta matière sera transmis si disponible.')) : ListView.builder(padding:const EdgeInsets.all(16), itemCount:_messages.length, itemBuilder:(context,index){ final m=_messages[index]; final mine=m['role']=='user'; return Align(alignment:mine?Alignment.centerRight:Alignment.centerLeft, child: Container(margin:const EdgeInsets.symmetric(vertical:6), padding:const EdgeInsets.all(12), constraints:const BoxConstraints(maxWidth:340), decoration:BoxDecoration(color:mine?const Color(0xFF124A68):panelBlue,borderRadius:BorderRadius.circular(14)), child:Text(m['text']??'')));})),
      if (_error != null) Padding(padding:const EdgeInsets.symmetric(horizontal:12), child:Text(_error!,style:const TextStyle(color:Colors.redAccent))),
      if (_sending) const LinearProgressIndicator(),
      SafeArea(top:false, child:Padding(padding:const EdgeInsets.all(12), child:Row(children:[Expanded(child:TextField(controller:_controller,minLines:1,maxLines:4,enabled:!_sending,onSubmitted:(_)=>_send(),decoration:const InputDecoration(hintText:'Écris ta question…',border:OutlineInputBorder()))),const SizedBox(width:8),IconButton.filled(onPressed:_sending?null:_send,icon:const Icon(Icons.send))]))),
    ]),
  );
}