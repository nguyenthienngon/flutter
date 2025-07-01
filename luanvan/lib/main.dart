import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart'; // Import Firebase
import 'package:luanvan/screens/home_screen.dart';
import 'package:workmanager/workmanager.dart'; // Import WorkManager
import 'screens/welcome_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // Required for async initialization
  await Firebase.initializeApp(); // Initialize Firebase

  // Khởi động WorkManager
  Workmanager().initialize(
    callbackDispatcher, // Hàm callback đã định nghĩa trong HomeScreen.dart
    isInDebugMode: true,
  );
  Workmanager().registerPeriodicTask(
    "checkExpiryTask",
    "checkExpiry",
    frequency: Duration(hours: 24), // Kiểm tra mỗi 24 giờ
    initialDelay: Duration(minutes: 1), // Chạy lần đầu sau 1 phút
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartFri',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const WelcomeScreen(),
    );
  }
}