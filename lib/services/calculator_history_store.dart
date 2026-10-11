import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/calculator_engine.dart';

class CalculationEntry {
  final String id;
  final String expression;
  final String result;
  final DateTime createdAt;
  const CalculationEntry({
    required this.id,
    required this.expression,
    required this.result,
    required this.createdAt,
  });
  factory CalculationEntry.fromCalculation(CompletedCalculation value) {
    final now = DateTime.now();
    return CalculationEntry(
      id: now.microsecondsSinceEpoch.toString(),
      expression: value.expression,
      result: value.result,
      createdAt: now,
    );
  }
  Map<String, Object> toJson() => {
    'id': id,
    'expression': expression,
    'result': result,
    'createdAt': createdAt.toIso8601String(),
  };
  static CalculationEntry? fromJson(Object? raw) {
    if (raw is! Map ||
        raw['id'] is! String ||
        raw['expression'] is! String ||
        raw['result'] is! String ||
        raw['createdAt'] is! String) {
      return null;
    }
    final time = DateTime.tryParse(raw['createdAt']);
    final result = double.tryParse(raw['result']);
    if (time == null || result == null || !result.isFinite) return null;
    try {
      CalculatorEngine().restoreExpression(raw['expression']);
    } on FormatException {
      return null;
    }
    return CalculationEntry(
      id: raw['id'],
      expression: raw['expression'],
      result: raw['result'],
      createdAt: time,
    );
  }
}

/// Local application-support storage, separate from pairing/profile data.
/// Atomic replacement and serialized writes protect rapid successive results.
class CalculatorHistoryStore {
  static const maxEntries = 200;
  final File? fileOverride;
  CalculatorHistoryStore({this.fileOverride});
  Future<void> _pending = Future.value();
  Future<File> _file() async {
    if (fileOverride != null) return fileOverride!;
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File('${directory.path}/calculator_history.json');
  }

  Future<List<CalculationEntry>> load() async {
    await _pending;
    final file = await _file();
    if (!await file.exists()) return [];
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map || raw['version'] != 1 || raw['entries'] is! List) {
      throw const FormatException('Invalid history file');
    }
    return (raw['entries'] as List)
        .map(CalculationEntry.fromJson)
        .whereType<CalculationEntry>()
        .take(maxEntries)
        .toList();
  }

  Future<void> save(List<CalculationEntry> entries) {
    final content = jsonEncode({
      'version': 1,
      'entries': entries
          .take(maxEntries)
          .map((entry) => entry.toJson())
          .toList(),
    });
    final operation = _pending.then((_) async {
      final file = await _file();
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(content, flush: true);
      await temporary.rename(file.path);
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }
}
