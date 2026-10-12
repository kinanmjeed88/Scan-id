import 'package:flutter/material.dart';

/// Tone of an [InfoBanner]. [caution] is for facts the user must know before
/// an irreversible or external step (printing, backups, deletion).
enum BannerTone { info, caution }

/// A contextual message card. Used where a warning belongs to the task it
/// concerns, instead of a permanent banner on every screen.
class InfoBanner extends StatelessWidget {
  const InfoBanner({
    required this.message,
    this.title,
    this.tone = BannerTone.info,
    super.key,
  });

  final String message;
  final String? title;
  final BannerTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final caution = tone == BannerTone.caution;
    final foreground = caution
        ? scheme.onTertiaryContainer
        : scheme.onSecondaryContainer;
    final style = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: caution ? scheme.tertiaryContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            caution ? Icons.warning_amber_outlined : Icons.info_outline,
            color: foreground,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) ...[
                  Text(
                    title!,
                    style: style.titleSmall?.copyWith(color: foreground),
                  ),
                  const SizedBox(height: 4),
                ],
                Text(
                  message,
                  style: style.bodyMedium?.copyWith(color: foreground),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    super.key,
  });
  final IconData icon;
  final String title;
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 20),
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A primary action that keeps its label on wide screens and collapses to an
/// icon button with the same tooltip on phones, so an AppBar action row can
/// never overflow a narrow layout.
class AdaptableAction extends StatelessWidget {
  const AdaptableAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    super.key,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width >= 600) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: FilledButton.icon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
        ),
      );
    }
    return IconButton(tooltip: label, onPressed: onPressed, icon: Icon(icon));
  }
}

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
  );
}

/// Asks before a consequential step. [confirmLabel] names the action itself
/// ("حذف الصورة", "متابعة"), so the button never claims more or less than it
/// does. [destructive] paints the confirm button as an error action.
Future<bool> confirm(
  BuildContext context,
  String title,
  String message, {
  String confirmLabel = 'متابعة',
  bool destructive = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(message)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                    )
                  : null,
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    ) ??
    false;

Future<String?> askName(
  BuildContext context, {
  required String title,
  required String initial,
}) => showDialog<String>(
  context: context,
  builder: (_) => _NameDialog(title: title, initial: initial),
);

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});
  final String title;
  final String initial;
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _form = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.pop(context, _controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 360,
      child: Form(
        key: _form,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          maxLength: 160,
          decoration: const InputDecoration(labelText: 'اسم المشروع'),
          validator: (value) =>
              value == null || value.trim().isEmpty ? 'أدخل اسم المشروع' : null,
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('إلغاء'),
      ),
      FilledButton(onPressed: _submit, child: const Text('حفظ')),
    ],
  );
}
