import 'package:flutter/material.dart';
import 'screens/calculator_screen.dart';

void main() {
  runApp(const SecretCalculatorApp());
}

class SecretCalculatorApp extends StatelessWidget {
  const SecretCalculatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Calculator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueGrey,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const CalculatorScreen(),
    );
  }
}