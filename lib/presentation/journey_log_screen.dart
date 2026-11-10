/// The report screen behind Settings: what happened to every imported image,
/// in pipeline order, one card per image.
///
/// The screen only renders what the log stored. It never re-derives a decision
/// and never shows recognized text — a step explains WHICH stage decided and
/// WHY, which is what a person needs to fix a refused image without exposing
/// the document's content.
library;

import 'package:flutter/material.dart';

import '../application/journey_log.dart';
import '../domain/image_journey.dart';
import 'shared.dart';

class JourneyLogScreen extends StatefulWidget {
  const JourneyLogScreen({required this.log, super.key});

  final JourneyLog log;

  @override
  State<JourneyLogScreen> createState() => _JourneyLogScreenState();
}

class _JourneyLogScreenState extends State<JourneyLogScreen> {
  List<ImageJourney>? _journeys;
  JourneyLogStats _stats = JourneyLogStats.empty;
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    try {
      final journeys = await widget.log.read();
      final stats = await widget.log.stats();
      if (!mounted) return;
      setState(() {
        _journeys = journeys;
        _stats = stats;
        _failed = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _journeys = const [];
        _stats = JourneyLogStats.empty;
        _failed = true;
      });
    }
  }

  Future<void> _clear() async {
    if (_busy) return;
    final yes = await confirm(
      context,
      'حذف سجل معالجة الصور؟',
      'يُحذف هذا السجل فقط: لن تُحذف أي صورة، ولن يتغيّر أي مشروع أو ورقة، '
          'ولن تفقد أي مستمسك. التقارير الجديدة تُكتب من جديد عند الاستيراد '
          'التالي.',
      confirmLabel: 'حذف السجل',
      destructive: true,
    );
    if (!yes || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.log.clear();
    } on Object {
      // A failed clear leaves the file intact; the reload below says so.
    }
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final journeys = _journeys;
    return Scaffold(
      appBar: AppBar(
        title: const Text('سجل معالجة الصور'),
        leading: IconButton(
          tooltip: 'رجوع',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          if (journeys != null && journeys.isNotEmpty)
            IconButton(
              tooltip: 'حذف السجل',
              onPressed: _busy ? null : _clear,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: journeys == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 880),
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                    children: [
                      _header(),
                      if (_busy) const LinearProgressIndicator(),
                      if (journeys.isEmpty)
                        _emptyState()
                      else
                        ..._grouped(journeys),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _header() {
    final entries = _stats.entries;
    final summary = entries == 0
        ? 'لا توجد تقارير محفوظة.'
        : 'الصور المسجّلة: $entries · حجم السجل: ${_stats.sizeLabel}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'مسار كل صورة، بترتيب مراحله',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              const Text(
                'يُسجَّل لكل صورة اختيرت: نسخها إلى المشروع، ثم قرار الحدود '
                'والقص، ثم قراءة النص وتحديد النوع، ثم المقاس، ثم وضعها على '
                'ورقة A4، ثم الحفظ. تُقرأ المراحل من الأعلى إلى الأسفل، والمرحلة '
                'التي لم تُنفَّذ تظهر بموضعها مع سبب عدم تنفيذها.',
              ),
              const SizedBox(height: 10),
              InfoBanner(message: summary),
              const SizedBox(height: 10),
              const Text(
                'لا يحتوي هذا السجل على نص مقروء من أي مستند، ولا على بيانات '
                'شخصية أو صور: كل سطر يصف مرحلة وقرارها ودرجتها فقط. وهو محفوظ '
                'داخل مساحة التطبيق على جهازك، ولا يُرسل إلى أي جهة.',
              ),
              if (_failed) ...[
                const SizedBox(height: 10),
                const InfoBanner(
                  tone: BannerTone.caution,
                  message:
                      'تعذر قراءة ملف السجل؛ قد يكون تالفاً أو محذوفاً. '
                      'ستُكتب تقارير جديدة عند الاستيراد التالي.',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyState() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 8),
    child: Column(
      children: [
        Icon(
          Icons.receipt_long_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Text(
          'لم تُستورد أي صورة بعد على هذا الجهاز.',
          style: Theme.of(context).textTheme.titleSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        const Text(
          'أضف صورة إلى مشروع، ثم عُد إلى هنا: ستجد تقريراً مفصلاً لكل صورة '
          'بمراحلها بالترتيب، من اختيارها حتى وضعها في الورقة.',
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );

  /// One section per intake run. Batches are already newest-first in storage,
  /// so the list keeps that order instead of re-sorting by wall clock.
  List<Widget> _grouped(List<ImageJourney> journeys) {
    final widgets = <Widget>[];
    String? currentBatch;
    for (final journey in journeys) {
      if (journey.batchId != currentBatch) {
        currentBatch = journey.batchId;
        widgets.add(_batchHeader(journey));
      }
      widgets.add(_journeyCard(journey));
    }
    return widgets;
  }

  Widget _batchHeader(ImageJourney first) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
    child: Row(
      children: [
        Icon(
          Icons.inventory_2_outlined,
          size: 18,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            first.projectName.isEmpty
                ? 'دفعة استيراد'
                : 'دفعة استيراد · ${first.projectName}',
            style: Theme.of(context).textTheme.titleSmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Text(
          _timestamp(first.startedAt),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );

  Widget _journeyCard(ImageJourney journey) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    child: ExpansionTile(
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      leading: _statusIcon(journey.verdict),
      title: Text(journey.imageName, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        _subtitle(journey),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      children: [
        for (var index = 0; index < journey.steps.length; index++)
          _stepRow(journey.steps[index], isLast: index == journey.steps.length - 1),
      ],
    ),
  );

  String _subtitle(ImageJourney journey) {
    final concern = journey.firstConcern;
    if (concern == null) return journey.conclusion;
    return '${journey.conclusion} · ${concern.stage.label}: ${concern.detail}';
  }

  Widget _stepRow(JourneyStep step, {required bool isLast}) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (step.outcome) {
      JourneyOutcome.passed => scheme.primary,
      JourneyOutcome.review => scheme.tertiary,
      JourneyOutcome.blocked => scheme.error,
      JourneyOutcome.skipped => scheme.outline,
    };
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Icon(_stepIcon(step.outcome), size: 18, color: color),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      color: scheme.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          step.stage.label,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      if (step.durationMs != null)
                        Text(
                          _duration(step.durationMs!),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      const SizedBox(width: 8),
                      _outcomePill(step.outcome, color),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(step.detail, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _outcomePill(JourneyOutcome outcome, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      outcome.label,
      style: Theme.of(
        context,
      ).textTheme.labelSmall?.copyWith(color: color),
    ),
  );

  Widget _statusIcon(JourneyOutcome verdict) {
    final scheme = Theme.of(context).colorScheme;
    return switch (verdict) {
      JourneyOutcome.passed => Icon(
        Icons.check_circle,
        color: scheme.primary,
      ),
      JourneyOutcome.review => Icon(
        Icons.report_problem_outlined,
        color: scheme.tertiary,
      ),
      JourneyOutcome.blocked => Icon(
        Icons.error_outline,
        color: scheme.error,
      ),
      JourneyOutcome.skipped => Icon(
        Icons.remove_circle_outline,
        color: scheme.outline,
      ),
    };
  }

  IconData _stepIcon(JourneyOutcome outcome) => switch (outcome) {
    JourneyOutcome.passed => Icons.check,
    JourneyOutcome.review => Icons.priority_high,
    JourneyOutcome.blocked => Icons.close,
    JourneyOutcome.skipped => Icons.remove,
  };

  static String _duration(int milliseconds) {
    if (milliseconds < 1000) return '$milliseconds م.ث';
    final seconds = milliseconds / 1000;
    if (seconds < 60) return '${seconds.toStringAsFixed(1)} ث';
    final minutes = seconds / 60;
    return '${minutes.toStringAsFixed(1)} د';
  }

  static String _timestamp(DateTime utc) {
    final local = utc.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
