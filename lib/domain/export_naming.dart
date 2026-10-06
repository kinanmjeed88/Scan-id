import 'export_plan.dart';
import 'validation.dart';

/// Readable, deterministic and platform-safe file names for one export.
///
/// The project name is the only user-controlled part of a name, and it may hold
/// path separators, control characters, trailing dots or spaces (all forbidden
/// by at least one supported platform) or a reserved Windows device name, so it
/// is sanitised instead of being trusted. The same plan always produces the same
/// names, which keeps repeat exports and tests predictable.
class ExportNames {
  ExportNames({required this.document, required List<String> pages})
    : pages = List.unmodifiable(pages);
  /// Name of the multipage PDF, or null when the plan exports raster pages.
  final String? document;
  final List<String> pages;
  List<String> get files => [if (document != null) document!, ...pages];
}

/// Longest base name kept before the page suffix; short enough for the Android
/// document provider and for Windows path-length limits.
const _maximumBase = 60;

/// Strips everything a file name cannot safely carry and returns a usable stem.
String exportBaseName(String projectName) {
  final buffer = StringBuffer();
  for (final rune in projectName.runes) {
    final forbidden =
        rune < 0x20 || rune == 0x7f || r'<>:"/\|?*'.contains(String.fromCharCode(rune));
    buffer.write(forbidden ? ' ' : String.fromCharCode(rune));
  }
  var name = buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  // A Windows name may not end with a dot or a space.
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  if (name.length > _maximumBase) {
    name = name.substring(0, _maximumBase);
    // Never cut a surrogate pair in half.
    if (name.isNotEmpty && _isHighSurrogate(name.codeUnitAt(name.length - 1))) {
      name = name.substring(0, name.length - 1);
    }
    name = name.replaceAll(RegExp(r'[. ]+$'), '').trim();
  }
  if (name.isEmpty) {
    name = 'مستمسكات';
  }
  // A project named "con" or "nul" must still produce a writable file.
  if (isReservedWindowsName(name)) {
    name = '_$name';
  }
  return name;
}

ExportNames exportNames(ExportPlan plan) {
  final base = exportBaseName(plan.project.name);
  if (plan.profile.format == ExportFormat.pdf) {
    return ExportNames(document: '$base.pdf', pages: const []);
  }
  final extension = plan.profile.format == ExportFormat.png ? 'png' : 'jpg';
  return ExportNames(
    document: null,
    pages: [
      for (final page in plan.pages) '$base-صفحة-${page + 1}.$extension',
    ],
  );
}

bool _isHighSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;
