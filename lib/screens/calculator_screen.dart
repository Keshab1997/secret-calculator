import 'package:flutter/material.dart';
import 'dart:math';
import 'chat_screen.dart';

class CalculatorScreen extends StatefulWidget {
  const CalculatorScreen({super.key});

  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> {
  String _output = '0';
  String _currentInput = '';
  String _operand = '';
  double _num1 = 0;
  double _num2 = 0;
  bool _shouldResetInput = false;
  final String _secretCode = '1997';
  String _secretBuffer = '';

  void _onButtonPressed(String value) {
    setState(() {
      // Check for secret code
      _secretBuffer += value;
      if (_secretBuffer.length > 4) {
        _secretBuffer = _secretBuffer.substring(_secretBuffer.length - 4);
      }
      if (_secretBuffer == _secretCode) {
        _secretBuffer = '';
        _navigateToChat();
        return;
      }

      if (value == 'C') {
        _clear();
      } else if (value == '⌫') {
        _backspace();
      } else if (value == '+' || value == '-' || value == '×' || value == '÷') {
        _setOperand(value);
      } else if (value == '=') {
        _calculate();
      } else if (value == '%') {
        _percentage();
      } else if (value == '.') {
        _addDecimal();
      } else {
        _addDigit(value);
      }
    });
  }

  void _clear() {
    _output = '0';
    _currentInput = '';
    _operand = '';
    _num1 = 0;
    _num2 = 0;
    _shouldResetInput = false;
  }

  void _backspace() {
    if (_currentInput.isNotEmpty) {
      _currentInput = _currentInput.substring(0, _currentInput.length - 1);
      _output = _currentInput.isEmpty ? '0' : _currentInput;
    }
  }

  void _setOperand(String op) {
    if (_currentInput.isNotEmpty) {
      _num1 = double.parse(_currentInput);
      _operand = op;
      _shouldResetInput = true;
    }
  }

  void _calculate() {
    if (_operand.isEmpty || _currentInput.isEmpty) return;

    _num2 = double.parse(_currentInput);
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

    _output = result == result.roundToDouble() 
        ? result.round().toString() 
        : result.toStringAsFixed(8).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    _currentInput = _output;
    _operand = '';
    _shouldResetInput = true;
  }

  void _percentage() {
    if (_currentInput.isNotEmpty) {
      double value = double.parse(_currentInput);
      value = value / 100;
      _output = value.toStringAsFixed(8).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
      _currentInput = _output;
    }
  }

  void _addDecimal() {
    if (_shouldResetInput) {
      _currentInput = '0';
      _shouldResetInput = false;
    }
    if (!_currentInput.contains('.')) {
      _currentInput += _currentInput.isEmpty ? '0.' : '.';
      _output = _currentInput;
    }
  }

  void _addDigit(String digit) {
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

  void _navigateToChat() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ChatScreen()),
    );
  }

  Widget _buildButton(String text, {Color? color, Color? textColor, int flex = 1}) {
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
                _output,
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