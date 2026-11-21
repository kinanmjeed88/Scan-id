/// The screen behind Settings that shows what actually happened to every image
/// in an operation: every stage, in pipeline order, with its status, its
/// measured duration, the reason it succeeded/was bypassed/failed, the inputs
/// that mattered, the result it produced, the evidence that the result is real,
/// and the action taken after it.
///
/// The screen renders ONLY what the journal stored. It never re-derives a
/// decision and never shows recognized text: a stage names the decision and its
/// measurements, never the document's content.
library;

import 'package:flutter/material.dart';

import '../application/processing_ledger.dart';
import '../domain/document_kind.dart' show DocumentKindDetails;
import '../domain/intake_options.dart';
import '../domain/processing_record.dart';
import '../domain/recognition.dart' show SideKind;

class ProcessingReportScreen extends StatefulWidget {
  const ProcessingReportScreen({required this.journal, super.key});

  final ProcessingJournal journal;

  @override
  State<ProcessingReportScreen> createState() => _ProcessingReportScreenState();
}

class _ProcessingReportScreenState extends State<ProcessingReportScreen> {
  List<ProcessingReport>? _reports;
  String? _selected;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final reports = await widget.journal.reports();
      if (!mounted) return;
      setState(() {
        _reports = reports;
        _failed = false;
        final selectionStillExists = reports.any(
          (report) => report.batchId == _selected,
        );
        if (!selectionStillExists) {
          _selected = reports.isEmpty ? null : reports.first.batchId;
        }
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _reports = const [];
        _failed = true;
      });
    }
  }

  ProcessingReport? get _current {
    for (final report in _reports ?? const <ProcessingReport>[]) {
      if (report.batchId == _selected) return report;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final reports = _reports;
    return Scaffold(
      appBar: AppBar(
        title: const Text('تقرير المعالجة التفصيلي'),
        leading: IconButton(
          tooltip: 'رجوع',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: reports == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: reports.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(24),
                          children: [
                            Text(
                              _failed
                                  ? 'تعذر قراءة سجل المعالجة. تحقق من مساحة التخزين.'
                                  : 'لا توجد عمليات مسجلة بعد. سيُكتب التقرير '
                                        'تلقائياً مع الاستيراد التالي.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        )
                      : ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                          children: [
                            _selector(reports),
                            const SizedBox(height: 8),
                            if (_current case final report?) _report(report),
                          ],
                        ),
                ),
              ),
            ),
    );
  }

  Widget _selector(List<ProcessingReport> reports) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final report in reports.take(8))
          ChoiceChip(
            selected: report.batchId == _selected,
            onSelected: (_) => setState(() => _selected = report.batchId),
            label: Text(
              '${_date(report.startedAt)} · ${report.headline}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  Widget _report(ProcessingReport report) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        report.projectName.isEmpty
                            ? 'مشروع غير معروف'
                            : report.projectName,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    _StatusPill(
                      label: report.verdict.label,
                      status: _verdictStatus(report.verdict),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${_date(report.startedAt)} · '
                  'المدة الكلية: ${_duration(report.totalDurationMs)}'
                  '${report.recovered ? ' · تقرير مُستعاد بعد انقطاع' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(report.headline, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 12),
                SelectableText(
                  'الصور: ${report.images.length} · '
                  'المستمسكات: ${report.documentsMeasured} · '
                  'قُصّ: ${report.documentsCropped} · '
                  'حُفظ: ${report.documentsSaved} · '
                  'أُضيف وتُحقّق: ${report.documentsAdded} · '
                  'على الورقة: ${report.documentsPlaced} · '
                  'خارجها: ${report.documentsNotPlaced} · '
                  'وضع غير مؤكد: ${report.documentsPlacementUnverified} · '
                  'فشل: ${report.documentsFailed}\n'
                  'المراحل — ناجحة: ${report.stagesSucceeded} · '
                  'تحتاج مراجعة: ${report.stagesReviewRequired} · '
                  'فاشلة: ${report.stagesFailed} · '
                  'متجاوزة: ${report.stagesOverridden} · '
                  'غير مطلوبة: ${report.stagesNotApplicable} · '
                  'متوقفة: ${report.stagesStopped} · '
                  'لم تُنفّذ: ${report.stagesNotReached} · '
                  'ملغاة: ${report.stagesCancelled}',
                  style: theme.textTheme.bodySmall,
                ),
                if (report.optionCodes.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text('الخيارات المختارة', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  Text(
                    report.options == null
                        ? 'رموز محفوظة: ${report.optionCodes.join(' · ')}'
                        : _optionsText(report.options!),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (report.warnings.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text('تحذيرات العملية', style: theme.textTheme.labelLarge),
                  for (final warning in report.warnings)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '• $warning',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final image in report.images) _image(image),
      ],
    );
  }

  Widget _image(ImageProcessingLog image) {
    final theme = Theme.of(context);
    final stages = image.filledStages();
    final shown = stages
        .where(
          (stage) =>
              stage.status != StageStatus.notReached &&
              stage.status != StageStatus.stopped,
        )
        .toList();
    final skipped = stages
        .where(
          (stage) =>
              stage.status == StageStatus.notReached ||
              stage.status == StageStatus.stopped,
        )
        .toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        key: Key('processing-image-${image.imageId}'),
        initiallyExpanded: image.outcome.needsAttention,
        title: Text(
          image.imageName.isEmpty ? 'صورة بلا اسم' : image.imageName,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${image.outcome.label} · ${stages.length} مرحلة'
          '${image.documents.isEmpty ? '' : ' · ${image.documents.length} مستند'}',
          style: theme.textTheme.bodySmall,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          if (image.warnings.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                'تحذيرات: ${image.warnings.join(' · ')}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          for (final stage in shown) _stageRow(stage),
          if (skipped.isNotEmpty) ...[
            const Divider(height: 16),
            Text(
              'مراحل لم تكتمل أو لم يصلها المسار (${skipped.length})',
              style: theme.textTheme.labelLarge,
            ),
            for (final stage in skipped) _stageRow(stage),
          ],
          if (image.documents.isNotEmpty) ...[
            const Divider(height: 16),
            Text('المستمسكات', style: theme.textTheme.labelLarge),
            for (final document in image.documents)
              _documentCard(image, document),
          ],
          if (image.recordingGaps.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'ثغرات تسجيل: '
                '${image.recordingGaps.map((stage) => stage.label).join('، ')}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _stageRow(StageRecord stage) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  stage.stage.label,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (stage.durationMs != null)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: Text(
                    _duration(stage.durationMs!),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              _StatusPill(label: stage.status.label, status: stage.status),
              if (stage.attempt > 1)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 4),
                  child: Text(
                    'محاولة ${stage.attempt}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
          Text(stage.reason, style: theme.textTheme.bodySmall),
          if (stage.evidence case final evidence?) _evidence(evidence, theme),
          if (stage.inputs.isNotEmpty)
            Text(
              'المدخلات: ${_pairs(stage.inputs)}',
              style: theme.textTheme.bodySmall,
            ),
          if (stage.results.isNotEmpty)
            Text(
              'النتائج: ${_pairs(stage.results)}',
              style: theme.textTheme.bodySmall,
            ),
          if (stage.itemCount != null)
            Text(
              'العناصر المعالجة: ${stage.itemCount}',
              style: theme.textTheme.bodySmall,
            ),
          if (stage.errorType != null || stage.errorCode != null)
            Text(
              'الخطأ: ${stage.errorType ?? ''}'
              '${stage.errorCode == null ? '' : ' · ${stage.errorCode}'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          for (final line in stage.diagnostics)
            Text('تشخيص: $line', style: theme.textTheme.bodySmall),
          if (stage.actionTaken.isNotEmpty)
            Text(
              'الإجراء: ${stage.actionTaken}',
              style: theme.textTheme.bodySmall,
            ),
          const Divider(height: 10),
        ],
      ),
    );
  }

  Widget _evidence(StageEvidence evidence, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            evidence.verified
                ? 'الدليل: النتيجة متحققة'
                : 'الدليل: النتيجة غير متحققة',
            style: theme.textTheme.bodySmall?.copyWith(
              color: evidence.verified
                  ? theme.colorScheme.primary
                  : theme.colorScheme.error,
            ),
          ),
          for (final check in evidence.checks)
            Text(
              '${check.passed ? '✓' : '✗'} ${check.name}'
              '${check.detail.isEmpty ? '' : ' (${check.detail})'}',
              style: theme.textTheme.bodySmall,
            ),
          if (evidence.counts.isNotEmpty)
            Text(
              'قياسات: ${_pairs(evidence.counts)}',
              style: theme.textTheme.bodySmall,
            ),
          if (evidence.note.isNotEmpty)
            Text(evidence.note, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _documentCard(
    ImageProcessingLog image,
    DocumentProcessingLog document,
  ) {
    final theme = Theme.of(context);
    final stages = document.filledStages();
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ExpansionTile(
        key: Key('processing-document-${image.imageId}-${document.id}'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        initiallyExpanded: document.needsAttention,
        title: Text(
          document.label.isEmpty
              ? 'مستند ${document.selectionIndex}'
              : document.label,
          style: theme.textTheme.bodyMedium,
        ),
        subtitle: Text(
          '${document.kind.label} · ${_sideLabel(document.side)} · '
          '${document.statusOf(ProcessingStage.crop) == StageStatus.succeeded ? 'القص ناجح' : 'القص غير مكتمل'} · '
          '${document.placed
              ? 'موضوع على الورقة'
              : document.placementStatus == StageStatus.reviewRequired
              ? 'بقي خارج الورقة'
              : 'الوضع غير مؤكد'} · '
          '${document.saved ? 'محفوظ' : 'الحفظ غير مؤكد'} · '
          '${document.added ? 'مضاف ومتحقق' : 'الإضافة غير مؤكدة'}',
          style: theme.textTheme.bodySmall,
        ),
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: SelectableText(
              'معرّف سجل المعالجة: ${document.id} · '
              'رقم التحديد: ${document.selectionIndex} · '
              'مصدر النوع: ${document.kindSource.label} · '
              'مصدر الوجه: ${document.sideSource.label}',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (document.layoutItemId != null ||
              document.documentRecordId != null ||
              document.derivedAssetId != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: SelectableText(
                [
                  if (document.layoutItemId != null)
                    'عنصر الورقة: ${document.layoutItemId}',
                  if (document.documentRecordId != null)
                    'سجل المستند: ${document.documentRecordId}',
                  if (document.derivedAssetId != null)
                    'الأصل المشتق: ${document.derivedAssetId}',
                ].join(' · '),
                style: theme.textTheme.bodySmall,
              ),
            ),
          for (final stage in stages)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          stage.stage.label,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      if (stage.durationMs != null)
                        Text(
                          _duration(stage.durationMs!),
                          style: theme.textTheme.bodySmall,
                        ),
                      const SizedBox(width: 6),
                      _StatusPill(
                        label: stage.status.label,
                        status: stage.status,
                      ),
                    ],
                  ),
                  Text(stage.reason, style: theme.textTheme.bodySmall),
                  if (stage.evidence case final evidence?)
                    _evidence(evidence, theme),
                  if (stage.inputs.isNotEmpty)
                    Text(
                      'المدخلات: ${_pairs(stage.inputs)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  if (stage.results.isNotEmpty)
                    Text(
                      'النتائج: ${_pairs(stage.results)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  if (stage.errorType != null || stage.errorCode != null)
                    Text(
                      'الخطأ: ${stage.errorType ?? ''}'
                      '${stage.errorCode == null ? '' : ' · ${stage.errorCode}'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  for (final line in stage.diagnostics)
                    Text('تشخيص: $line', style: theme.textTheme.bodySmall),
                  if (stage.actionTaken.isNotEmpty)
                    Text(
                      'الإجراء: ${stage.actionTaken}',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          if (document.recordingGaps.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                'ثغرات تسجيل: '
                '${document.recordingGaps.map((stage) => stage.label).join('، ')}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (document.outcome.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                'النتيجة: ${document.outcome}',
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  String _optionsText(IntakeOptions options) {
    final parts = <String>[
      'الوجه: ${_sideLabel(options.side)}',
      'النوع: ${options.kind.label}',
      'اعتماد الحدود المقترحة: ${options.acceptSuggestedBoundary ? 'نعم' : 'لا'}',
      'التوسيط: ${options.centerDocuments ? 'مفعّل' : 'معطّل'}',
      'تحديد متعدد: ${options.multiDocument ? 'نعم' : 'لا'}',
    ];
    if (options.confirmed.isNotEmpty) {
      parts.add(
        'مؤكَّد صراحةً: '
        '${options.confirmed.map((key) => key.name).join('، ')}',
      );
    }
    return parts.join(' · ');
  }

  static String _sideLabel(SideKind side) => switch (side) {
    SideKind.front => 'وجه أول',
    SideKind.back => 'وجه ثانٍ',
    SideKind.unknown => 'غير محدد',
  };

  static String _pairs(Map<String, Object?> values) =>
      values.entries.map((entry) => '${entry.key}=${entry.value}').join(' · ');

  static String _duration(int ms) {
    if (ms < 1000) return '$ms م.ث';
    final seconds = ms / 1000;
    return '${seconds.toStringAsFixed(seconds >= 10 ? 0 : 1)} ث';
  }

  static String _date(DateTime value) {
    final local = value.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  static StageStatus _verdictStatus(ProcessingVerdict verdict) =>
      switch (verdict) {
        ProcessingVerdict.completed => StageStatus.succeeded,
        ProcessingVerdict.completedWithReview => StageStatus.reviewRequired,
        ProcessingVerdict.partial => StageStatus.failed,
        ProcessingVerdict.failed => StageStatus.failed,
        ProcessingVerdict.cancelled => StageStatus.cancelled,
        ProcessingVerdict.interrupted => StageStatus.stopped,
        ProcessingVerdict.stopped => StageStatus.stopped,
        ProcessingVerdict.running => StageStatus.running,
      };
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.status});

  final String label;
  final StageStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (background, foreground) = switch (status) {
      StageStatus.succeeded => (
        theme.colorScheme.primaryContainer,
        theme.colorScheme.onPrimaryContainer,
      ),
      StageStatus.reviewRequired => (
        theme.colorScheme.tertiaryContainer,
        theme.colorScheme.onTertiaryContainer,
      ),
      StageStatus.failed => (
        theme.colorScheme.errorContainer,
        theme.colorScheme.onErrorContainer,
      ),
      StageStatus.cancelled || StageStatus.stopped => (
        theme.colorScheme.errorContainer,
        theme.colorScheme.onErrorContainer,
      ),
      StageStatus.running => (
        theme.colorScheme.secondaryContainer,
        theme.colorScheme.onSecondaryContainer,
      ),
      StageStatus.overridden || StageStatus.notApplicable => (
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurfaceVariant,
      ),
      StageStatus.notReached => (
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurfaceVariant,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}
