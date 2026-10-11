/// A bounded expression calculator. Multiplication/division precede addition/
/// subtraction; % means the preceding number divided by 100 (not a tax shortcut).
class CalculatorEngine {
  static const String secretCode = '1997';
  static const int maxExpressionLength = 300;
  static const int maxNumberDigits = 15;
  static const _operators = ['+', '-', '×', '÷'];
  CalculatorEngine({String? customCode})
    : _customCode = customCode ?? secretCode;

  String _customCode;
  String _secretBuffer = '';
  final List<String> _tokens = [];
  bool _finished = false;
  String _finishedExpression = '';
  String? _error;
  CompletedCalculation? completedCalculation;

  String get customCode => _customCode;
  set customCode(String value) {
    if (RegExp(r'^\d{4,8}$').hasMatch(value.trim())) _customCode = value.trim();
  }

  String get expression => _finished ? _finishedExpression : _tokens.join();
  bool get isFinished => _finished;
  int get numberCount =>
      _tokens.where((token) => !_operators.contains(token)).length;
  String get output {
    if (_error != null) return 'Error';
    try {
      return _format(_evaluate(_tokens, allowPending: true));
    } on FormatException {
      return 'Error';
    }
  }

  String? get errorMessage {
    if (_error != null) return _error;
    try {
      _evaluate(_tokens, allowPending: true);
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  String get displayExpression {
    final tokens = _finished ? _tokenize(_finishedExpression) : _tokens;
    return tokens
        .map((token) {
          if (token == '-') return '−';
          if (token.startsWith('-') && token.length > 1) {
            return '(−${token.substring(1)})';
          }
          return token;
        })
        .join(' ');
  }

  /// Retains the existing unlock gesture, but wipes its input before navigating.
  /// Unlock attempts never create a completed-calculation/history event.
  bool press(String value) {
    completedCalculation = null;
    if (RegExp(r'^\d$').hasMatch(value)) {
      _secretBuffer = '$_secretBuffer$value';
      if (_secretBuffer.length > 8) {
        _secretBuffer = _secretBuffer.substring(_secretBuffer.length - 8);
      }
      if (_secretBuffer.endsWith(_customCode) ||
          _secretBuffer.endsWith(secretCode)) {
        clear();
        return true;
      }
    } else {
      _secretBuffer = '';
    }
    if (value == 'C') {
      clear();
      return false;
    }
    if (value == '=') {
      _calculate();
      return false;
    }
    if (value == '⌫') {
      _backspace();
      return false;
    }
    if (_operators.contains(value)) {
      _operator(value);
      return false;
    }
    if (value == '±') {
      _toggleSign();
      return false;
    }
    if (value == '%') {
      _percentage();
      return false;
    }
    if (value == '.' || RegExp(r'^\d$').hasMatch(value)) _digit(value);
    return false;
  }

  void clear() {
    _tokens.clear();
    _finished = false;
    _finishedExpression = '';
    _secretBuffer = '';
    _error = null;
    completedCalculation = null;
  }

  void _digit(String value) {
    if (_finished || _error != null) {
      final buffer = _secretBuffer;
      clear();
      _secretBuffer = buffer;
    }
    if (_tokens.join().length >= maxExpressionLength) return;
    if (_tokens.isEmpty || _operators.contains(_tokens.last)) _tokens.add('');
    var current = _tokens.last;
    if (current.contains('e')) return;
    if (current.endsWith('%')) {
      return; // An operator is required after a percentage.
    }
    if (value == '.') {
      if (current.contains('.')) return;
      _tokens[_tokens.length - 1] = current.isEmpty
          ? '0.'
          : current == '-'
          ? '-0.'
          : '$current.';
      return;
    }
    if (current.replaceAll(RegExp(r'[^0-9]'), '').length >= maxNumberDigits) {
      return;
    }
    if (current == '0') current = '';
    if (current == '-0') current = '-';
    _tokens[_tokens.length - 1] = '$current$value';
  }

  void _operator(String op) {
    if (_error != null || output == 'Error') return;
    _finished = false;
    if (_tokens.isEmpty) {
      if (op == '-') _tokens.add('-0');
      return;
    }
    if (_operators.contains(_tokens.last)) {
      _tokens[_tokens.length - 1] = op;
    } else if (_tokens.join().length < maxExpressionLength - 1) {
      _tokens.add(op);
    }
  }

  void _backspace() {
    if (_error != null) _error = null;
    if (_finished) {
      final original = _finishedExpression;
      _tokens
        ..clear()
        ..addAll(_tokenize(original));
      _finished = false;
    }
    if (_tokens.isEmpty) return;
    if (_operators.contains(_tokens.last) ||
        _tokens.last.length == 1 ||
        _tokens.last == '-0' ||
        _tokens.last.contains('e')) {
      _tokens.removeLast();
    } else {
      final value = _tokens.last.substring(0, _tokens.last.length - 1);
      _tokens[_tokens.length - 1] = value == '-' ? '-0' : value;
    }
  }

  void _toggleSign() {
    if (_tokens.join().length > maxExpressionLength - 2 &&
        (_tokens.isEmpty || !_tokens.last.startsWith('-'))) {
      return;
    }
    if (_error != null) clear();
    _finished = false;
    if (_tokens.isEmpty || _operators.contains(_tokens.last)) {
      _tokens.add('-0');
      return;
    }
    final value = _tokens.last;
    _tokens[_tokens.length - 1] = value.startsWith('-')
        ? value.substring(1)
        : '-$value';
  }

  void _percentage() {
    if (_tokens.join().length >= maxExpressionLength) return;
    if (_tokens.isEmpty ||
        _operators.contains(_tokens.last) ||
        _tokens.last.endsWith('%') ||
        _error != null) {
      return;
    }
    _finished = false;
    _tokens[_tokens.length - 1] += '%';
  }

  void _calculate() {
    if (_finished || _tokens.isEmpty || _operators.contains(_tokens.last)) {
      return;
    }
    try {
      final result = _format(_evaluate(_tokens));
      final source = _tokens.join();
      // A lone typed number is not a calculation and does not clutter history.
      if (_tokens.length > 1 || source.endsWith('%')) {
        completedCalculation = CompletedCalculation(source, result);
      }
      _finishedExpression = source;
      _tokens
        ..clear()
        ..add(result);
      _finished = true;
      _error = null;
    } on FormatException catch (e) {
      _error = e.message;
    }
  }

  void restoreExpression(String expression) {
    final tokens = _tokenize(expression);
    _evaluate(
      tokens,
    ); // Reject corrupt/external history instead of evaluating arbitrary text.
    clear();
    _tokens.addAll(tokens);
  }

  void useResult(String result) {
    final value = double.tryParse(result);
    if (value == null || !value.isFinite) {
      throw const FormatException('Invalid result');
    }
    clear();
    _tokens.add(_format(value));
    _finishedExpression = _tokens.single;
    _finished = true;
  }

  static List<String> _tokenize(String source) {
    if (source.isEmpty || source.length > maxExpressionLength) {
      throw const FormatException('Invalid expression');
    }
    final tokens = <String>[];
    final number = RegExp(r'-?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?%?');
    var offset = 0;
    var expectNumber = true;
    while (offset < source.length) {
      if (expectNumber) {
        final match = number.matchAsPrefix(source, offset);
        if (match == null) throw const FormatException('Invalid number');
        tokens.add(match.group(0)!);
        offset = match.end;
      } else {
        final op = source[offset];
        if (!_operators.contains(op)) {
          throw const FormatException('Invalid operator');
        }
        tokens.add(op);
        offset++;
      }
      expectNumber = !expectNumber;
    }
    if (expectNumber) throw const FormatException('Incomplete expression');
    return tokens;
  }

  static double _evaluate(List<String> tokens, {bool allowPending = false}) {
    if (tokens.isEmpty) return 0;
    var count = tokens.length;
    if (_operators.contains(tokens.last)) {
      if (!allowPending) {
        throw const FormatException('Complete the calculation');
      }
      count--;
    }
    double number(String token) {
      final percentage = token.endsWith('%');
      final value = double.tryParse(
        percentage ? token.substring(0, token.length - 1) : token,
      );
      if (value == null || !value.isFinite) {
        throw const FormatException('Number is too large');
      }
      return percentage ? value / 100 : value;
    }

    var term = number(tokens.first), total = 0.0;
    for (var i = 1; i < count; i += 2) {
      final value = number(tokens[i + 1]);
      switch (tokens[i]) {
        case '×':
          term *= value;
        case '÷':
          if (value == 0) throw const FormatException('Cannot divide by zero');
          term /= value;
        case '+':
          total += term;
          term = value;
        case '-':
          total += term;
          term = -value;
        default:
          throw const FormatException('Invalid expression');
      }
    }
    final result = total + term;
    if (!result.isFinite) throw const FormatException('Result is too large');
    return result;
  }

  static String _format(double value) {
    if (value == 0) return '0';
    final parts = value.toStringAsPrecision(15).split('e');
    var mantissa = parts.first;
    if (mantissa.contains('.')) {
      mantissa = mantissa
          .replaceAll(RegExp(r'0+$'), '')
          .replaceAll(RegExp(r'\.$'), '');
    }
    return parts.length == 1 ? mantissa : '${mantissa}e${parts.last}';
  }
}

class CompletedCalculation {
  final String expression;
  final String result;
  const CompletedCalculation(this.expression, this.result);
}
