import 'package:flutter/material.dart';

import '../services/firebase_service.dart';
import '../services/native_bridge_service.dart';
import 'chats_screen.dart';
import '../widgets/messaging_style.dart';

/// Pure calculator state machine with default (`1997`) and custom secret-code detection.
class CalculatorEngine {
  static const String secretCode = '1997';
  static const int _maxBufferLength = 8;

  CalculatorEngine({String? customCode})
    : _customCode = (customCode != null && customCode.length >= 4)
          ? customCode
          : secretCode;

  String _customCode;
  String _output = '0';
  String _currentInput = '';
  String _operand = '';
  double _num1 = 0;
  double _num2 = 0;
  bool _shouldResetInput = false;
  String _secretBuffer = '';

  String get output => _output;
  String get customCode => _customCode;

  set customCode(String code) {
    final trimmed = code.trim();
    if (trimmed.length >= 4 && trimmed.length <= _maxBufferLength) {
      _customCode = trimmed;
    }
  }

  /// Processes a calculator button [value].
  /// Returns `true` when either the custom passcode or the master code (`1997`) is entered.
  bool press(String value) {
    _secretBuffer += value;
    if (_secretBuffer.length > _maxBufferLength) {
      _secretBuffer = _secretBuffer.substring(
        _secretBuffer.length - _maxBufferLength,
      );
    }
    if (_secretBuffer.endsWith(_customCode) ||
        _secretBuffer.endsWith(secretCode)) {
      _secretBuffer = '';
      return true;
    }

    if (value == 'C') {
      clear();
    } else if (value == '⌫') {
      backspace();
    } else if (value == '+' || value == '-' || value == '×' || value == '÷') {
      setOperand(value);
    } else if (value == '=') {
      calculate();
    } else if (value == '%') {
      percentage();
    } else if (value == '.') {
      addDecimal();
    } else {
      addDigit(value);
    }
    return false;
  }

  void clear() {
    _output = '0';
    _currentInput = '';
    _operand = '';
    _num1 = 0;
    _num2 = 0;
    _shouldResetInput = false;
  }

  void backspace() {
    if (_currentInput.isNotEmpty) {
      _currentInput = _currentInput.substring(0, _currentInput.length - 1);
      _output = _currentInput.isEmpty ? '0' : _currentInput;
    }
  }

  void setOperand(String op) {
    final parsed = double.tryParse(_currentInput);
    if (parsed != null) {
      _num1 = parsed;
      _operand = op;
      _shouldResetInput = true;
    }
  }

  void calculate() {
    if (_operand.isEmpty || _currentInput.isEmpty) return;
    final parsed = double.tryParse(_currentInput);
    if (parsed == null) return;

    _num2 = parsed;
    double result = 0;

    switch (_operand) {
      case '+':
        result = _num1 + _num2;
        break;
      case '-':
        result = _num1 - _num2;
        break;
      case '×':
        result = _num1 * _num2;
        break;
      case '÷':
        if (_num2 != 0) {
          result = _num1 / _num2;
        } else {
          _output = 'Error';
          _currentInput = '';
          _operand = '';
          return;
        }
        break;
    }

    _output = _formatNumber(result);
    _currentInput = _output;
    _operand = '';
    _shouldResetInput = true;
  }

  void percentage() {
    final parsed = double.tryParse(_currentInput);
    if (parsed != null) {
      final value = parsed / 100;
      _output = _formatNumber(value);
      _currentInput = _output;
    }
  }

  void addDecimal() {
    if (_shouldResetInput) {
      _currentInput = '0';
      _shouldResetInput = false;
    }
    if (!_currentInput.contains('.')) {
      _currentInput += _currentInput.isEmpty ? '0.' : '.';
      _output = _currentInput;
    }
  }

  void addDigit(String digit) {
    if (_shouldResetInput) {
      _currentInput = '';
      _shouldResetInput = false;
    }
    if (_currentInput == '0' && digit != '.') {
      _currentInput = digit;
    } else {
      _currentInput += digit;
    }
    _output = _currentInput;
  }

  static String _formatNumber(double value) {
    if (value == value.roundToDouble()) {
      return value.round().toString();
    }
    return value
        .toStringAsFixed(8)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
  }
}

class CalculatorScreen extends StatefulWidget {
  const CalculatorScreen({super.key});

  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> {
  final CalculatorEngine _engine = CalculatorEngine();
  final FirebaseService _firebase = FirebaseService();
  final NativeBridgeService _native = NativeBridgeService();

  Future<void> _onButtonPressed(String value) async {
    _engine.customCode = _firebase.customPasscode;
    var shouldNavigate = false;
    setState(() {
      shouldNavigate = _engine.press(value);
    });
    if (shouldNavigate) {
      await _navigateToChat();
    }
  }

  Future<void> _navigateToChat() async {
    if (_firebase.biometricEnabled) {
      final verified = await _native.authenticateDevice();
      if (!verified || !mounted) return;
    }
    if (!mounted) return;
    Navigator.push(context, messagingRoute(const ChatsScreen()));
  }

  Widget _buildButton(
    String text, {
    Color? color,
    Color? textColor,
    int flex = 1,
  }) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(4.0),
        child: ElevatedButton(
          onPressed: () => _onButtonPressed(text),
          style: ElevatedButton.styleFrom(
            backgroundColor: color ?? Colors.grey[850],
            foregroundColor: textColor ?? Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.all(20),
            elevation: 2,
          ),
          child: Text(
            text,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w500),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Calculator', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        elevation: 0,
      ),
      body: Column(
        children: [
          // Display
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(24),
              alignment: Alignment.bottomRight,
              child: Text(
                _engine.output,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 64,
                  fontWeight: FontWeight.w300,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          // Buttons
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: [
                Row(
                  children: [
                    _buildButton('C', color: Colors.grey[700]),
                    _buildButton('⌫', color: Colors.grey[700]),
                    _buildButton('%', color: Colors.grey[700]),
                    _buildButton('÷', color: Colors.orange),
                  ],
                ),
                Row(
                  children: [
                    _buildButton('7'),
                    _buildButton('8'),
                    _buildButton('9'),
                    _buildButton('×', color: Colors.orange),
                  ],
                ),
                Row(
                  children: [
                    _buildButton('4'),
                    _buildButton('5'),
                    _buildButton('6'),
                    _buildButton('-', color: Colors.orange),
                  ],
                ),
                Row(
                  children: [
                    _buildButton('1'),
                    _buildButton('2'),
                    _buildButton('3'),
                    _buildButton('+', color: Colors.orange),
                  ],
                ),
                Row(
                  children: [
                    _buildButton('0', flex: 2),
                    _buildButton('.'),
                    _buildButton('=', color: Colors.orange),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
