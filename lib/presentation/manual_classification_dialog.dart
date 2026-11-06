import 'package:flutter/material.dart';

import '../domain/document_kind.dart';
import '../domain/manual_classification.dart';
import '../domain/project.dart';
import '../domain/recognition.dart';
import '../domain/recognition_overrides.dart' as rec;
import 'editor_controller.dart';
import 'review_screen.dart' show reviewKindChoices;
import 'project_screen.dart' show LocalImage;

/// One explicit user choice, with an optional, explicitly selected partner.
class ManualClassificationChoice {
  const ManualClassificationChoice({
    required this.kind,
    required this.side,
    this.partnerItemId,
  });
  final DocumentKind kind;
  final SideKind side;
  final String? partnerItemId;
}

Future<ManualClassificationChoice?> showManualClassificationDialog(
  BuildContext context,
  LayoutEditorController controller,
  DocumentItem item, {
  bool editingExisting = false,
}) => showDialog<ManualClassificationChoice>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _ManualClassificationDialog(
    controller: controller,
    item: item,
    editingExisting: editingExisting,
  ),
);

class _ManualClassificationDialog extends StatefulWidget {
  const _ManualClassificationDialog({
    required this.controller,
    required this.item,
    required this.editingExisting,
  });
  final LayoutEditorController controller;
  final DocumentItem item;
  final bool editingExisting;

  @override
  State<_ManualClassificationDialog> createState() =>
      _ManualClassificationDialogState();
}

class _ManualClassificationDialogState
    extends State<_ManualClassificationDialog> {
  DocumentKind? _kind;
  SideKind? _side;
  String? _partnerId;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    if (item.documentKind != DocumentKind.unknown) _kind = item.documentKind;
    final record = widget.controller.project.documents
        .where((entry) => entry.id == item.documentId)
        .firstOrNull;
    if (record != null &&
        record.sides.length == 1 &&
        (widget.editingExisting ||
            record.overrides.any((entry) => entry.side != null))) {
      _side = rec.effectiveSide(record, record.sides.single);
    }
  }

  String _score(double? value) =>
      value == null ? 'غير متاحة' : '${(value * 100).toStringAsFixed(1)}٪';

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final project = controller.project;
    final item = widget.item;
    final asset = project.assets.firstWhere((a) => a.id == item.assetId);
    final record = project.documents
        .where((entry) => entry.id == item.documentId)
        .firstOrNull;
    final boundaryScore =
        record?.sides.firstOrNull?.detection?.detectionConfidence?.value;
    final kindScore = record?.recognition?.confidences.classification?.value;
    final finalScore = record?.recognition?.confidences.finalConfidence?.value;
    final kind = _kind;
    final side = _side;
    final partners = kind == null || side == null
        ? <DocumentItem>[]
        : matchingManualSidePartners(
            project,
            itemId: item.id,
            kind: kind,
            side: side,
          );

    return AlertDialog(
      key: const Key('manual-classification-dialog'),
      title: Text(
        widget.editingExisting ? 'تعديل تصنيف المستمسك' : 'اختر تصنيف المستمسك',
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 72,
                    height: 64,
                    child: LocalImage(
                      repository: controller.service.assets,
                      path: asset.thumbnailPath,
                      cacheWidth: 144,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      asset.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                widget.editingExisting
                    ? 'يمكن تعديل النوع والوجه. تغيير أحدهما في مستمسك مرتبط يفصل الربط الحالي؛ الصور تبقى محفوظة.'
                    : 'تعذرت الإضافة التلقائية. اختر النوع والوجه، ثم راجع القص أو المقاس عند الحاجة. الأصل محفوظ.',
              ),
              const SizedBox(height: 8),
              Text(
                'درجة الحدود: ${_score(boundaryScore)} · درجة التصنيف: ${_score(kindScore)} · '
                'الدرجة الإجمالية: ${_score(finalScore)}. حد القبول ٧٠٪؛ هذه الدرجات ليست ضماناً للدقة.',
                key: const Key('manual-classification-confidence'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<DocumentKind>(
                key: const Key('manual-classification-kind'),
                initialValue: _kind,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'نوع المستمسك'),
                items: [
                  for (final choice in reviewKindChoices)
                    DropdownMenuItem(value: choice, child: Text(choice.label)),
                ],
                onChanged: (value) => setState(() {
                  _kind = value;
                  _partnerId = null;
                }),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<SideKind>(
                key: const Key('manual-classification-side'),
                initialValue: _side,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'وجه المستمسك'),
                items: const [
                  DropdownMenuItem(
                    value: SideKind.front,
                    child: Text('الوجه الأول (أمامي)'),
                  ),
                  DropdownMenuItem(
                    value: SideKind.back,
                    child: Text('الوجه الثاني (خلفي)'),
                  ),
                  DropdownMenuItem(
                    value: SideKind.unknown,
                    child: Text('وجه واحد / غير محدد'),
                  ),
                ],
                onChanged: (value) => setState(() {
                  _side = value;
                  _partnerId = null;
                }),
              ),
              if (partners.isNotEmpty) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  key: const Key('manual-classification-partner'),
                  initialValue: _partnerId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'اربط بالوجه الآخر (اختياري)',
                  ),
                  hint: const Text('دون ربط حالياً'),
                  items: [
                    for (final partner in partners)
                      DropdownMenuItem(
                        value: partner.id,
                        child: Text(
                          '${project.assets.firstWhere((a) => a.id == partner.assetId).name} — صورة ${project.items.indexOf(partner) + 1} ',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() => _partnerId = value),
                ),
                if (_partnerId != null)
                  TextButton(
                    onPressed: () => setState(() => _partnerId = null),
                    child: const Text('إلغاء اختيار الوجه الآخر'),
                  ),
                const Text(
                  'الربط يضع الوجهين متجاورين؛ اختر صورة الوجه المطابق فقط.',
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('manual-classification-later'),
          onPressed: () => Navigator.pop(context),
          child: const Text('لاحقاً'),
        ),
        FilledButton(
          key: const Key('manual-classification-continue'),
          onPressed: kind == null || side == null
              ? null
              : () => Navigator.pop(
                  context,
                  ManualClassificationChoice(
                    kind: kind,
                    side: side,
                    partnerItemId: _partnerId,
                  ),
                ),
          child: const Text('متابعة'),
        ),
      ],
    );
  }
}
