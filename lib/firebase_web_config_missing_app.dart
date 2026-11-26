import 'package:flutter/material.dart';

class FirebaseWebConfigMissingApp extends StatelessWidget {
  const FirebaseWebConfigMissingApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(
    title: 'Kavelynt',
    home: Scaffold(
      backgroundColor: Color(0xFF070311),
      body: Center(child: Padding(padding: EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.auto_awesome, color: Color(0xFFB45CFF), size: 54),
        SizedBox(height: 16), Text('KAVELYNT', style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
        SizedBox(height: 12), Text('La version Web est compilée, mais Firebase Web doit encore être configuré pour activer la connexion et la synchronisation.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)),
      ]))),
    ),
  );
}
