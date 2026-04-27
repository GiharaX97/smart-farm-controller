import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Farm Control',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: const Color(0xFF6C5CE7),
        scaffoldBackgroundColor: const Color(0xFF0A0A0F),
        cardColor: const Color(0xFF1A1A24),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6C5CE7),
          secondary: Color(0xFF00B894),
          surface: Color(0xFF1A1A24),
          background: Color(0xFF0A0A0F),
          error: Color(0xFFD63031),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1A1A24),
          elevation: 0,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
