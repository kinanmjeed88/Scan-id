import 'package:flutter/material.dart';
import '../domain/project.dart';

String manualPartnerLabel(Project project, DocumentItem item) =>
    '${project.assets.firstWhere((a) => a.id == item.assetId).name} — صورة ${project.items.indexOf(item) + 1}';

/// The same explicit, optional choice for a saved item or a draft face.
class SidePartnerField extends StatelessWidget {
  const SidePartnerField({
    super.key,
    required this.choices,
    required this.value,
    required this.onChanged,
  });
  final Map<String, String> choices;
  final String? value;
  final ValueChanged<String?> onChanged;
  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    key: ValueKey(value),
    initialValue: choices.containsKey(value) ? value : null,
    isExpanded: true,
    decoration: const InputDecoration(labelText: 'اربط بالوجه الآخر (اختياري)'),
    hint: const Text('دون ربط حالياً'),
    items: [
      const DropdownMenuItem<String>(child: Text('دون ربط حالياً')),
      for (final entry in choices.entries)
        DropdownMenuItem(
          value: entry.key,
          child: Text(entry.value, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: onChanged,
  );
}
