import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/processing_ledger.dart';
import 'package:scan_id/domain/processing_record.dart';
import 'package:scan_id/presentation/processing_report_screen.dart';

class _FixtureJournal implements ProcessingJournal {
  _FixtureJournal(this.report);

  final ProcessingReport report;

  @override
  void add(Map<String, Object?> event) {}

  @override
  Future<void> clear() async {}

  @override
  Future<ProcessingReport?> latest() async => report;

  @override
  Future<ProcessingReport?> reportFor(String operationId) async =>
      operationId == report.batchId ? report : null;

  @override
  Future<List<ProcessingReport>> reports() async => [report];
}

void main() {
  testWidgets('shows the stable item id and per-selection review reasons', (
    tester,
  ) async {
    final report = ProcessingReport.fromJson(
      jsonDecode(
        File(
          'test/fixtures/manual_multi_selection_review_report.json',
        ).readAsStringSync(),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(home: ProcessingReportScreen(journal: _FixtureJournal(report))),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('item-test-02'), findsWidgets);
    expect(find.textContaining('لا يتوفر مقاس موثق'), findsOneWidget);
    expect(find.textContaining('القياس غير مؤكّد'), findsOneWidget);
    expect(find.textContaining('size_definition_missing'), findsOneWidget);
    expect(find.textContaining('placement_size_unconfirmed'), findsOneWidget);
    expect(find.text('تحتاج مراجعة'), findsWidgets);
  });
}
