import 'package:flutter/material.dart';

import '../domain/document_kind.dart';
import '../domain/intake_options.dart';
import '../domain/recognition.dart';

/// Opens the floating options sheet the person sees AFTER picking images and
/// BEFORE they are processed.
///
/// The sheet is a decision surface, not a form: each option carries a visible
/// check when the person confirmed it, and closing it accepts the current
/// choices. Nothing here is inferred — an unchecked option keeps its documented
/// default, and [IntakeOptions.confirmed] records only what was actually ticked,
/// so the journey log can tell «chosen» from «defaulted».
Future<IntakeOptions?> showIntakeOptionsSheet(
  BuildContext context, {
  IntakeOptions initial = IntakeOptions.defaults,
  int imageCount = 1,
}) => showModalBottomSheet<IntakeOptions>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _IntakeOptionsSheet(initial: initial, imageCount: imageCount),
);

class _IntakeOptionsSheet extends StatefulWidget {
  const _IntakeOptionsSheet({required this.initial, required this.imageCount});

  final IntakeOptions initial;
  final int imageCount;

  @override
  State<_IntakeOptionsSheet> createState() => _IntakeOptionsSheetState();
}

class _IntakeOptionsSheetState extends State<_IntakeOptionsSheet> {
  late IntakeOptions _options = widget.initial;

  /// Ticks an option and records that the person confirmed it.
  void _confirm(IntakeOptionKey key, IntakeOptions next) {
    setState(() => _options = next.withConfirmed(key));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = widget.imageCount;
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
                    : 'بدون تحديد يُعتبر وجه واحد',
                child: Wrap(
                  spacing: 8,
                  children: [
                    _ChoiceChip(
                      label: 'وجه واحد (افتراضي)',
                      selected: _options.side == SideKind.unknown,
                      onSelected: () => _confirm(
                        IntakeOptionKey.side,
                        _options.withSide(SideKind.unknown),
                      ),
                    ),
                    _ChoiceChip(
                      label: 'وجه أول',
                      selected: _options.side == SideKind.front,
                      onSelected: () => _confirm(
                        IntakeOptionKey.side,
                        _options.withSide(SideKind.front),
                      ),
                    ),
                    _ChoiceChip(
                      label: 'وجه ثانٍ',
                      selected: _options.side == SideKind.back,
                      onSelected: () => _confirm(
                        IntakeOptionKey.side,
                        _options.withSide(SideKind.back),
                      ),
                    ),
                  ],
                ),
              ),

              // 2) kind
              _OptionTile(
                optionKey: IntakeOptionKey.kind,
                confirmed: _options.confirmed.contains(IntakeOptionKey.kind),
                title: 'نوع المستمسك',
                subtitle: _options.assertsKind
                    ? 'المحدَّد: ${_options.kind.label}'
                    : 'بدون تحديد يعمل التعرّف التلقائي',
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _ChoiceChip(
                      label: 'تعرّف تلقائي (افتراضي)',
                      selected: _options.kind == DocumentKind.unknown,
                      onSelected: () => _confirm(
                        IntakeOptionKey.kind,
                        _options.withKind(DocumentKind.unknown),
                      ),
                    ),
                    for (final kind in _selectableKinds)
                      _ChoiceChip(
                        label: kind.label,
                        selected: _options.kind == kind,
                        onSelected: () => _confirm(
                          IntakeOptionKey.kind,
                          _options.withKind(kind),
                        ),
                      ),
                  ],
                ),
              ),

              // 3) accept suggested boundary
              _OptionTile(
                optionKey: IntakeOptionKey.acceptSuggestedBoundary,
                confirmed: _options.confirmed.contains(
                  IntakeOptionKey.acceptSuggestedBoundary,
                ),
                title: 'موافقة على القص المقترح',
                subtitle: _options.acceptSuggestedBoundary
                    ? 'تُقبل الحدود المقترحة مباشرةً مهما كانت نسبتها'
                    : 'تُعرض الحدود للمراجعة قبل القص',
                trailing: Switch(
                  value: _options.acceptSuggestedBoundary,
                  onChanged: (value) => _confirm(
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
              Row(
                children: [
                  TextButton(
                    onPressed: () =>
                        setState(() => _options = IntakeOptions.defaults),
                    child: const Text('إعادة الافتراضي'),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    key: const Key('intake-options-confirm'),
                    onPressed: () => Navigator.of(context).pop(_options),
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
    // Automatic segmentation stays unavailable, and saying otherwise would be a
    // lie. What IS available is the manual workspace: the person outlines each
    // document themselves. The two are stated together so nobody expects the
    // detector to find documents for them.
    return 'مطلوب: تحدد أنت كل مستند يدوياً في مساحة العمل؛ '
        'الكشف التلقائي للمناطق غير مفعّل في هذه النسخة';
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
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 6),
              child: child,
            ),
        ],
      ),
    );
  }
}

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
    label: Text(label),
    selected: selected,
    onSelected: (_) => onSelected(),
  );
}
