import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One keyboard command: the activator, its printed form and its help text.
///
/// A single list drives both the live bindings and the help dialog, so the two
/// can never disagree.
class ShortcutBinding {
  const ShortcutBinding({
    required this.activator,
    required this.keys,
    required this.description,
    this.run,
  });
  final SingleActivator activator;
  final String keys;
  final String description;

  /// Null means the command is documented here but handled closer to the
  /// widget that owns it, so it is never registered as a global binding.
  final VoidCallback? run;
}

/// Keyboard support for desktop and hardware keyboards. Touch and mouse
/// gestures keep working exactly as before; these bindings only add commands.
class ScreenShortcuts extends StatelessWidget {
  const ScreenShortcuts({
    required this.shortcuts,
    required this.child,
    super.key,
  });
  final List<ShortcutBinding> shortcuts;
  final Widget child;
  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      for (final shortcut in shortcuts)
        if (shortcut.run != null) shortcut.activator: shortcut.run!,
    },
    child: Focus(autofocus: true, child: child),
  );
}

Future<void> showShortcuts(
  BuildContext context,
  List<ShortcutBinding> shortcuts,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('اختصارات لوحة المفاتيح'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'تعمل هذه الاختصارات مع لوحة المفاتيح على Windows وأي لوحة متصلة. اللمس والماوس يعملان بالطريقة نفسها.',
            ),
            const SizedBox(height: 12),
            for (final shortcut in shortcuts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        shortcut.keys,
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Expanded(flex: 2, child: Text(shortcut.description)),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('إغلاق'),
      ),
    ],
  ),
);

/// The arrow-key commands of the layout canvas. They live on the canvas focus
/// node, so arrow keys inside lists, menus or fields keep their normal meaning.
KeyEventResult canvasArrowKeys(
  KeyEvent event,
  void Function(double dx, double dy) nudge, {
  required bool enabled,
}) {
  if (!enabled) {
    return KeyEventResult.ignored;
  }
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  final step = HardwareKeyboard.instance.isShiftPressed ? 10.0 : 1.0;
  final delta = switch (event.logicalKey) {
    LogicalKeyboardKey.arrowLeft => const Offset(-1, 0),
    LogicalKeyboardKey.arrowRight => const Offset(1, 0),
    LogicalKeyboardKey.arrowUp => const Offset(0, -1),
    LogicalKeyboardKey.arrowDown => const Offset(0, 1),
    _ => null,
  };
  if (delta == null) {
    return KeyEventResult.ignored;
  }
  nudge(delta.dx * step, delta.dy * step);
  return KeyEventResult.handled;
}
