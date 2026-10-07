import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Word-style ribbon: a strip of tabs over one row of labelled groups.
///
/// Tabs marked [RibbonTab.contextual] (for example the document and picture
/// tools) are tinted like Office's contextual tabs and only appear while their
/// subject is selected.
class RibbonTab {
  const RibbonTab({
    required this.id,
    required this.label,
    required this.groups,
    this.contextual = false,
  });

  final String id;
  final String label;
  final List<Widget> groups;
  final bool contextual;
}

class Ribbon extends StatefulWidget {
  const Ribbon({
    required this.tabs,
    this.selectedTab,
    this.onTabSelected,
    this.trailing = const [],
    super.key,
  });

  final List<RibbonTab> tabs;

  /// Id of the selected tab; unknown or null selects the first tab.
  final String? selectedTab;
  final ValueChanged<String>? onTabSelected;

  /// Widgets at the end of the tab strip (e.g. a help button).
  final List<Widget> trailing;

  /// Height of the group row, matching a compact Office ribbon.
  static const bodyHeight = 100.0;

  @override
  State<Ribbon> createState() => _RibbonState();
}

class _RibbonState extends State<Ribbon> {
  bool _collapsed = false;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  RibbonTab get _current => widget.tabs.firstWhere(
    (tab) => tab.id == widget.selectedTab,
    orElse: () => widget.tabs.first,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = _current;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.1,
      child: Material(
        color: scheme.surfaceContainerLow,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 34,
              child: Row(
                children: [
                  Expanded(
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      children: [
                        for (final tab in widget.tabs)
                          _TabHeader(
                            key: Key('ribbon-tab-${tab.id}'),
                            tab: tab,
                            selected: tab.id == current.id,
                            onTap: () {
                              if (_collapsed) {
                                setState(() => _collapsed = false);
                              }
                              widget.onTabSelected?.call(tab.id);
                            },
                          ),
                      ],
                    ),
                  ),
                  ...widget.trailing,
                  IconButton(
                    key: const Key('ribbon-collapse'),
                    tooltip: _collapsed ? 'إظهار الشريط' : 'طي الشريط',
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    onPressed: () => setState(() => _collapsed = !_collapsed),
                    icon: Icon(
                      _collapsed ? Icons.expand_more : Icons.expand_less,
                    ),
                  ),
                ],
              ),
            ),
            if (!_collapsed)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border(
                    top: BorderSide(color: scheme.outlineVariant),
                    bottom: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
                child: SizedBox(
                  height: Ribbon.bodyHeight,
                  child: Scrollbar(
                    controller: _scroll,
                    child: ListView(
                      key: Key('ribbon-body-${current.id}'),
                      controller: _scroll,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      children: [
                        for (var i = 0; i < current.groups.length; i++) ...[
                          if (i > 0)
                            VerticalDivider(
                              width: 9,
                              indent: 6,
                              endIndent: 6,
                              color: scheme.outlineVariant,
                            ),
                          current.groups[i],
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TabHeader extends StatelessWidget {
  const _TabHeader({
    required this.tab,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final RibbonTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = tab.contextual ? scheme.tertiary : scheme.primary;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: tab.contextual
                ? scheme.tertiaryContainer.withValues(alpha: .45)
                : null,
            border: Border(
              bottom: BorderSide(
                color: selected ? accent : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Text(
            tab.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? accent : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled cluster of commands, captioned underneath like Office.
class RibbonGroup extends StatelessWidget {
  const RibbonGroup({required this.label, required this.children, super.key});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
      child: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(width: 2),
                  children[i],
                ],
              ],
            ),
          ),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Up to three small commands stacked in one column of a group.
class RibbonStack extends StatelessWidget {
  const RibbonStack({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: children,
  );
}

/// A ribbon command. Large buttons put a big icon above a two-line caption;
/// small ones put a small icon beside a one-line caption.
class RibbonButton extends StatelessWidget {
  const RibbonButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.large = false,
    this.selected = false,
    this.tooltip,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool large;

  /// Pressed state of a toggle command.
  final bool selected;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip ?? label,
    waitDuration: const Duration(milliseconds: 600),
    child: Semantics(
      button: true,
      toggled: selected ? true : null,
      enabled: onPressed != null,
      label: label,
      excludeSemantics: true,
      child: _RibbonFace(
        icon: icon,
        label: label,
        large: large,
        selected: selected,
        enabled: onPressed != null,
        onTap: onPressed,
      ),
    ),
  );
}

class _RibbonFace extends StatelessWidget {
  const _RibbonFace({
    required this.icon,
    required this.label,
    required this.large,
    required this.selected,
    required this.enabled,
    required this.onTap,
    this.dropdown = false,
  });

  final IconData icon;
  final String label;
  final bool large;
  final bool selected;
  final bool enabled;
  final bool dropdown;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = enabled
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: .38);
    final iconColor = enabled
        ? (selected ? scheme.onPrimaryContainer : scheme.primary)
        : color;
    final caption = Text(
      label,
      textAlign: large ? TextAlign.center : TextAlign.start,
      maxLines: large && !dropdown ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: large ? 11.5 : 12, color: color, height: 1.15),
    );
    final arrow = Icon(Icons.arrow_drop_down, size: 16, color: color);
    final body = large
        ? SizedBox(
            width: 66,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 26, color: iconColor),
                const SizedBox(height: 3),
                caption,
                if (dropdown) arrow,
              ],
            ),
          )
        : SizedBox(
            height: 24,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: iconColor),
                const SizedBox(width: 5),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: caption,
                ),
                if (dropdown) arrow,
              ],
            ),
          );
    return Material(
      color: selected ? scheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: large ? 2 : 6,
            vertical: large ? 2 : 0,
          ),
          child: body,
        ),
      ),
    );
  }
}

class RibbonMenuEntry<T> {
  const RibbonMenuEntry(
    this.value,
    this.label, {
    this.icon,
    this.checked = false,
    this.enabled = true,
  });

  final T value;
  final String label;
  final IconData? icon;
  final bool checked;
  final bool enabled;
}

/// A ribbon command that opens a menu (like Word's Margins or Orientation).
class RibbonMenuButton<T> extends StatelessWidget {
  const RibbonMenuButton({
    required this.icon,
    required this.label,
    required this.entries,
    required this.onSelected,
    this.large = false,
    this.enabled = true,
    this.tooltip,
    super.key,
  });

  final IconData icon;
  final String label;
  final List<RibbonMenuEntry<T>> entries;
  final ValueChanged<T> onSelected;
  final bool large;
  final bool enabled;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => PopupMenuButton<T>(
    tooltip: tooltip ?? label,
    enabled: enabled,
    onSelected: onSelected,
    itemBuilder: (_) => [
      for (final entry in entries)
        PopupMenuItem<T>(
          key: Key('menu-${entry.label}'),
          value: entry.value,
          enabled: entry.enabled,
          height: 40,
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: entry.checked
                    ? const Icon(Icons.check, size: 18)
                    : (entry.icon == null ? null : Icon(entry.icon, size: 18)),
              ),
              Flexible(child: Text(entry.label)),
            ],
          ),
        ),
    ],
    child: _RibbonFace(
      icon: icon,
      label: label,
      large: large,
      selected: false,
      enabled: enabled,
      dropdown: true,
      onTap: null,
    ),
  );
}

/// Numeric field with spin buttons, committing on Enter, focus loss or a spin
/// click — the Word "Height/Width" boxes of the picture format tab.
class RibbonNumberField extends StatefulWidget {
  const RibbonNumberField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.step = 1,
    this.min = 0,
    this.max = 1000,
    this.decimals = 1,
    this.suffix = 'مم',
    this.enabled = true,
    this.fieldKey,
    super.key,
  });

  final String label;
  final double? value;
  final ValueChanged<double> onChanged;
  final double step;
  final double min;
  final double max;
  final int decimals;
  final String suffix;
  final bool enabled;

  /// Key of the text field, for tests and automation.
  final Key? fieldKey;

  @override
  State<RibbonNumberField> createState() => _RibbonNumberFieldState();
}

class _RibbonNumberFieldState extends State<RibbonNumberField> {
  late final _controller = TextEditingController(text: _format(widget.value));
  final _focus = FocusNode();

  String _format(double? value) =>
      value == null ? '' : value.toStringAsFixed(widget.decimals);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(RibbonNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && oldWidget.value != widget.value) {
      _controller.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final parsed = parseLocalizedNumber(_controller.text);
    if (parsed == null || !widget.enabled) {
      _controller.text = _format(widget.value);
      return;
    }
    final value = parsed.clamp(widget.min, widget.max).toDouble();
    _controller.text = _format(value);
    if (widget.value == null || (value - widget.value!).abs() > 1e-9) {
      widget.onChanged(value);
    }
  }

  void _spin(double direction) {
    final base = widget.value ?? widget.min;
    final value = (base + direction * widget.step)
        .clamp(widget.min, widget.max)
        .toDouble();
    _controller.text = _format(value);
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && widget.value != null;
    return SizedBox(
      height: 28,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 52,
            child: Text(
              widget.label,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 70,
            child: TextField(
              key: widget.fieldKey,
              controller: _controller,
              focusNode: _focus,
              enabled: enabled,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9٠-٩.,٫]')),
              ],
              decoration: InputDecoration(
                isDense: true,
                suffixText: widget.suffix,
                suffixStyle: const TextStyle(fontSize: 10.5),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 6,
                ),
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _commit(),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Spin(
                key: widget.fieldKey == null
                    ? null
                    : Key('${_keyName(widget.fieldKey!)}-up'),
                icon: Icons.arrow_drop_up,
                tooltip: 'زيادة ${widget.label}',
                onTap: enabled ? () => _spin(1) : null,
              ),
              _Spin(
                key: widget.fieldKey == null
                    ? null
                    : Key('${_keyName(widget.fieldKey!)}-down'),
                icon: Icons.arrow_drop_down,
                tooltip: 'إنقاص ${widget.label}',
                onTap: enabled ? () => _spin(-1) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _keyName(Key key) =>
    key is ValueKey<String> ? key.value : key.toString();

class _Spin extends StatelessWidget {
  const _Spin({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      child: SizedBox(width: 22, height: 14, child: Icon(icon, size: 18)),
    ),
  );
}

/// Compact labelled slider for live picture corrections.
class RibbonSlider extends StatelessWidget {
  const RibbonSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
    this.display,
    this.sliderKey,
    super.key,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final String Function(double)? display;
  final Key? sliderKey;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 28,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 48,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
        SizedBox(
          width: 150,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.5,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              key: sliderKey,
              value: value.clamp(min, max).toDouble(),
              min: min,
              max: max,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ),
        SizedBox(
          width: 38,
          child: Text(
            display?.call(value) ?? value.toStringAsFixed(2),
            style: const TextStyle(fontSize: 11.5),
          ),
        ),
      ],
    ),
  );
}

/// Parses a number typed with Latin or Arabic-Indic digits and either a dot,
/// a comma or the Arabic decimal separator.
double? parseLocalizedNumber(String input) {
  var text = input.trim().replaceAll('٫', '.').replaceAll(',', '.');
  for (var i = 0; i < 10; i++) {
    text = text.replaceAll('٠١٢٣٤٥٦٧٨٩'[i], '$i');
  }
  final value = double.tryParse(text);
  return value != null && value.isFinite ? value : null;
}
