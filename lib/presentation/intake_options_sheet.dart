import 'package:flutter/material.dart';

import '../domain/document_kind.dart';
import '../domain/intake_options.dart';
import '../domain/manual_classification.dart';
import '../domain/project.dart';
import 'side_partner_field.dart';
import '../domain/recognition.dart';

/// Opens the floating options sheet the person sees AFTER picking images and
/// BEFORE they are processed.
///
/// The sheet is a decision surface, not a form: each option carries a visible
/// check when the person confirmed it, and only the continue button accepts the current
/// choices. Nothing here is inferred — an unchecked option keeps its documented
/// default, and [IntakeOptions.confirmed] records only what was actually ticked,
/// so the journey log can tell «chosen» from «defaulted».
Future<IntakeOptions?> showIntakeOptionsSheet(
  BuildContext context, {
  IntakeOptions initial = IntakeOptions.defaults,
  int imageCount = 1,
  Project? project,
}) => showModalBottomSheet<IntakeOptions>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _IntakeOptionsSheet(
    initial: initial,
    imageCount: imageCount,
    project: project,
  ),
);

class _IntakeOptionsSheet extends StatefulWidget {
  const _IntakeOptionsSheet({
    required this.initial,
    required this.imageCount,
    this.project,
  });
  final Project? project;

  final IntakeOptions initial;
  final int imageCount;

  @override
  State<_IntakeOptionsSheet> createState() => _IntakeOptionsSheetState();
}

class _IntakeOptionsSheetState extends State<_IntakeOptionsSheet> {
  late IntakeOptions _options = widget.initial;

  late String? _partnerId = widget.initial.partnerChoice?.itemId;

  /// Ticks an option and records that the person confirmed it.
  void _confirm(IntakeOptionKey key, IntakeOptions next) {
    setState(() {
      if (next.kind != _options.kind ||
          next.side != _options.side ||
          next.multiDocument != _options.multiDocument) {
        _partnerId = null;
      }
      _options = next.withConfirmed(key);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = widget.imageCount;
    final project = widget.project;
    final candidates = project != null && count == 1 && !_options.multiDocument
        ? {
            for (final item in matchingManualSidePartners(
              project,
              kind: _options.assertsKind ? _options.kind : null,
              side: _options.side,
            ))
              item.id: _options.assertsKind
                  ? manualPartnerLabel(project, item)
                  : '${manualPartnerLabel(project, item)} · ${item.documentKind.label}',
          }
        : const <String, String>{};
    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                count == 1
                    ? 'خيارات معالجة الصورة'
                    : 'خيارات معالجة $count صور',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 2),
              Text(
                'كل خيار لم تحدّده يبقى على وضعه الافتراضي. العلامة ✓ تعني '
                'أنك اخترته صراحةً.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),

              // 1) side
              _OptionTile(
                optionKey: IntakeOptionKey.side,
                confirmed: _options.confirmed.contains(IntakeOptionKey.side),
                title: 'الوجه',
                subtitle: _options.assertsSide
                    ? 'المحدَّد: ${_sideLabel(_options.side)}'
                    : 'الافتراضي: وجه واحد',
                child: _choiceRow([
                  for (final side in [
                    SideKind.unknown,
                    SideKind.front,
                    SideKind.back,
                  ])
                    _ChoiceChip(
                      label: _sideLabel(side),
                      selected: _options.side == side,
                      onSelected: () => _confirm(
                        IntakeOptionKey.side,
                        _options.withSide(side),
                      ),
                    ),
                ]),
              ),

              // 2) kind
              _OptionTile(
                optionKey: IntakeOptionKey.kind,
                confirmed: _options.confirmed.contains(IntakeOptionKey.kind),
                title: 'نوع المستمسك',
                subtitle: _options.multiDocument
                    ? 'قيمة أولية يمكن تغييرها لكل مستمسك'
                    : _options.assertsKind
                    ? 'المحدَّد: ${_options.kind.label}'
                    : 'بدون تحديد يعمل التعرّف التلقائي',
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final kinds = [DocumentKind.unknown, ..._selectableKinds];
                    // Fall back to fewer columns for large accessibility fonts.
                    final columns =
                        (constraints.maxWidth /
                                MediaQuery.textScalerOf(context).scale(66))
                            .floor()
                            .clamp(1, 4);
                    return Column(
                      children: [
                        for (var i = 0; i < kinds.length; i += columns)
                          _choiceRow([
                            for (final kind in kinds.skip(i).take(columns))
                              _ChoiceChip(
                                label: kind == DocumentKind.unknown
                                    ? (_options.multiDocument
                                          ? 'بلا نوع محدد'
                                          : 'تعرّف تلقائي')
                                    : kind.label,
                                selected: _options.kind == kind,
                                onSelected: () => _confirm(
                                  IntakeOptionKey.kind,
                                  _options.withKind(kind),
                                ),
                              ),
                          ]),
                      ],
                    );
                  },
                ),
              ),

              if (candidates.isNotEmpty)
                SidePartnerField(
                  key: const Key('intake-side-partner'),
                  choices: candidates,
                  value: _partnerId,
                  onChanged: (id) => setState(() => _partnerId = id),
                )
              else if (_options.assertsSide && !_options.multiDocument)
                const Text(
                  'عند توفر وجه مقابل من النوع نفسه يمكنك اختياره لكل مستمسك بعد تأكيد النوع والمقاس.',
                ),
              // 3) accept suggested boundary
              _OptionTile(
                optionKey: IntakeOptionKey.acceptSuggestedBoundary,
                confirmed: _options.confirmed.contains(
                  IntakeOptionKey.acceptSuggestedBoundary,
                ),
                title: 'موافقة على القص المقترح',
                subtitle: _options.multiDocument
                    ? 'غير منطبق على الزوايا المحددة يدوياً'
                    : _options.acceptSuggestedBoundary
                    ? 'تُقبل الحدود الصالحة رغم انخفاض الثقة'
                    : 'تُراجع الحدود عند الحاجة',
                trailing: Switch(
                  value:
                      !_options.multiDocument &&
                      _options.acceptSuggestedBoundary,
                  onChanged: _options.multiDocument
                      ? null
                      : (value) => _confirm(
                          IntakeOptionKey.acceptSuggestedBoundary,
                          _options.copyWith(acceptSuggestedBoundary: value),
                        ),
                ),
              ),

              // 4) centring
              _OptionTile(
                optionKey: IntakeOptionKey.centerDocuments,
                confirmed: _options.confirmed.contains(
                  IntakeOptionKey.centerDocuments,
                ),
                title: 'توسيط المستمسكات',
                subtitle: _options.centerDocuments
                    ? 'يعمل تلقائياً بالطريقة المعتادة'
                    : 'يُترك الترتيب بلا توسيط',
                trailing: Switch(
                  value: _options.centerDocuments,
                  onChanged: (value) => _confirm(
                    IntakeOptionKey.centerDocuments,
                    _options.copyWith(centerDocuments: value),
                  ),
                ),
              ),

              // 5) multi-document
              _OptionTile(
                optionKey: IntakeOptionKey.multiDocument,
                confirmed: _options.confirmed.contains(
                  IntakeOptionKey.multiDocument,
                ),
                title: 'المستندات المتعددة',
                subtitle: _multiSubtitle(),
                trailing: Switch(
                  value: _options.multiDocument,
                  onChanged: (value) => _confirm(
                    IntakeOptionKey.multiDocument,
                    _options.copyWith(multiDocument: value),
                  ),
                ),
              ),

              const SizedBox(height: 8),
              OverflowBar(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('إلغاء'),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _options = IntakeOptions.defaults;
                      _partnerId = null;
                    }),
                    child: const Text('إعادة الافتراضي'),
                  ),
                  FilledButton.icon(
                    key: const Key('intake-options-confirm'),
                    onPressed: () => Navigator.of(context).pop(
                      candidates.isEmpty
                          ? _options
                          : _options.copyWith(
                              partnerChoice: IntakePartnerChoice(_partnerId),
                            ),
                    ),
                    icon: const Icon(Icons.check),
                    label: const Text('متابعة المعالجة'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _multiSubtitle() {
    if (!_options.multiDocument) {
      return 'غير مطلوب؛ تُعالج كل صورة كمستند واحد';
    }
    // The manual workspace never detects or classifies regions.
    return 'حدّد الزوايا والنوع والوجه لكل مستمسك في الصورة.';
  }
}

/// The categories the sheet offers, in the order the rest of the app already
/// uses. Derived from [DocumentKindDetails.order] rather than restated here, so
/// a new category appears in the sheet automatically and the two lists cannot
/// drift. `unknown` is excluded because it IS the «تعرّف تلقائي» choice; `other`
/// is the free/A4 document whose size is entered by hand.
final List<DocumentKind> _selectableKinds = [
  for (final kind in DocumentKind.values)
    if (kind != DocumentKind.unknown) kind,
]..sort((a, b) => a.order.compareTo(b.order));

String _sideLabel(SideKind side) => switch (side) {
  SideKind.front => 'وجه أول',
  SideKind.back => 'وجه ثانٍ',
  SideKind.unknown => 'وجه واحد',
};

/// One option row: a check indicator that reflects CONFIRMATION (not just the
/// value), the title, the explanation of what happens, and its control.
class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.optionKey,
    required this.confirmed,
    required this.title,
    required this.subtitle,
    this.child,
    this.trailing,
  });

  final IntakeOptionKey optionKey;
  final bool confirmed;
  final String title;
  final String subtitle;
  final Widget? child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The ✓ the person asked for: it appears only when this option was
              // explicitly confirmed, so a default is never shown as a choice.
              SizedBox(
                width: 28,
                height: 28,
                child: confirmed
                    ? Icon(
                        Icons.check_circle,
                        color: theme.colorScheme.primary,
                        semanticLabel: 'مؤكَّد',
                      )
                    : Icon(
                        Icons.radio_button_unchecked,
                        color: theme.colorScheme.outlineVariant,
                        semanticLabel: 'غير مؤكَّد',
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          if (child != null)
            Padding(padding: const EdgeInsets.only(top: 4), child: child),
        ],
      ),
    );
  }
}

Widget _choiceRow(List<Widget> choices) => Row(
  children: [
    for (final choice in choices)
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: choice,
        ),
      ),
  ],
);

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Text(
      label,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.labelSmall,
    ),
    labelPadding: const EdgeInsets.symmetric(horizontal: 2),
    padding: EdgeInsets.zero,
    showCheckmark: false,
    selected: selected,
    onSelected: (_) => onSelected(),
  );
}
