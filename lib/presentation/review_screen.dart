/// Smart Recognition review queue dialog.
///
/// Presents the records that recognition routed to review — derived live
/// from evidence and overrides, never stored — and lets the user confirm,
/// correct the kind or side, or resolve a front/back pairing. Every action
/// is one undoable editor command.
library;

import 'package:flutter/material.dart';

import '../domain/document_kind.dart';
import '../domain/recognition.dart';
import 'editor_controller.dart';

/// Kinds offered by the correction menu (everything but `unknown`, which is
/// what the user is trying to get away from).
const List<DocumentKind> reviewKindChoices = [
  DocumentKind.unifiedNationalId,
  DocumentKind.residenceCard,
  DocumentKind.passport,
  DocumentKind.rationCard,
  DocumentKind.other,
];

String sideLabel(SideKind side) => switch (side) {
  SideKind.front => 'أمامي',
  SideKind.back => 'خلفي',
  SideKind.unknown => 'غير محدد',
};

/// Opens the review queue over the editor. Content tracks the controller,
/// so confirming an entry removes it immediately.
Future<void> showReviewQueue(
  BuildContext context,
  LayoutEditorController controller,
) => showDialog<void>(
  context: context,
  builder: (context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => _ReviewDialog(controller: controller),
  ),
);

class _ReviewDialog extends StatelessWidget {
  const _ReviewDialog({required this.controller});
  final LayoutEditorController controller;

  @override
  Widget build(BuildContext context) {
    final queue = controller.reviewQueue;
    return AlertDialog(
      title: const Text('مراجعة التعرف الذكي (تجريبي)'),
      content: SizedBox(
        width: 560,
        child: queue.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('لا توجد عناصر بانتظار المراجعة.'),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: queue.length,
                separatorBuilder: (context, index) => const Divider(height: 16),
                itemBuilder: (context, index) =>
                    _entry(context, queue[index]),
              ),
      ),
      actions: [
        if (queue.isNotEmpty)
          TextButton(
            key: const Key('review-confirm-all'),
            onPressed: controller.busy
                ? null
                : () => controller.confirmAllRecognition(),
            child: const Text('تأكيد الكل'),
          ),
        TextButton(
          key: const Key('review-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إغلاق'),
        ),
      ],
    );
  }

  Widget _entry(BuildContext context, DocumentRecord record) {
    final c = controller;
    final busy = c.busy;
    final item = c.itemForRecord(record);
    final asset = item == null
        ? null
        : c.project.assets.where((a) => a.id == item.assetId).firstOrNull;
    final kind = c.effectiveKindOf(record);
    final side = c.effectiveSideOf(record);
    final confidence =
        record.recognition?.confidences.finalConfidence?.value;
    final reasons = c.reviewReasonsFor(record);
    final pairProposed =
        record.pairedDocumentId != null &&
        record.pairing != PairingState.paired;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                asset?.name ?? kind.label,
                style: Theme.of(context).textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (confidence != null)
              Text(
                'الثقة ${(confidence * 100).round()}٪',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        if (reasons.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final reason in reasons)
                  Chip(
                    label: Text(reason),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<DocumentKind>(
                key: Key('review-kind-${record.id}'),
                value: reviewKindChoices.contains(kind) ? kind : null,
                hint: Text(kind.label),
                items: [
                  for (final choice in reviewKindChoices)
                    DropdownMenuItem(
                      value: choice,
                      child: Text(choice.label),
                    ),
                ],
                onChanged: busy || item == null
                    ? null
                    : (choice) {
                        if (choice != null && choice != kind) {
                          c.overrideRecordKind(record.id, choice);
                        }
                      },
              ),
              DropdownButton<SideKind>(
                key: Key('review-side-${record.id}'),
                value: side,
                items: [
                  for (final choice in SideKind.values)
                    DropdownMenuItem(
                      value: choice,
                      child: Text(sideLabel(choice)),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (choice) {
                        if (choice != null && choice != side) {
                          c.setRecordSide(record.id, choice);
                        }
                      },
              ),
              if (pairProposed) ...[
                TextButton(
                  key: Key('review-accept-pair-${record.id}'),
                  onPressed: busy
                      ? null
                      : () => c.acceptPairProposal(record.id),
                  child: const Text('قبول الاقتران'),
                ),
                TextButton(
                  key: Key('review-reject-pair-${record.id}'),
                  onPressed: busy
                      ? null
                      : () => c.rejectPairProposal(record.id),
                  child: const Text('رفض الاقتران'),
                ),
              ],
              FilledButton.tonal(
                key: Key('review-confirm-${record.id}'),
                onPressed: busy
                    ? null
                    : () => c.confirmRecognition(record.id),
                child: const Text('تأكيد'),
              ),
              if (item != null)
                IconButton(
                  key: Key('review-reveal-${record.id}'),
                  tooltip: 'إظهار على الورقة',
                  icon: const Icon(Icons.center_focus_strong_outlined),
                  onPressed: () {
                    c.select(item.id, reveal: true);
                    Navigator.of(context).pop();
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}
