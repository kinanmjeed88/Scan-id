/// Shared validation. Invariants are checked in release builds, not asserts.
class ValidationException implements Exception {
  const ValidationException(this.message);
  final String message;
  @override
  String toString() => message;
}

void require(bool condition, String message) {
  if (!condition) {
    throw ValidationException(message);
  }
}

double finiteNumber(Object? value, String field) {
  if (value is! num || !value.isFinite) {
    throw ValidationException('قيمة غير صالحة: $field');
  }
  return value.toDouble();
}

int integer(Object? value, String field) {
  if (value is! int) {
    throw ValidationException('عدد غير صالح: $field');
  }
  return value;
}

String text(Object? value, String field) {
  if (value is! String) {
    throw ValidationException('نص غير صالح: $field');
  }
  return value;
}

bool boolean(Object? value, String field) {
  if (value is! bool) {
    throw ValidationException('قيمة منطقية غير صالحة: $field');
  }
  return value;
}

/// Reads an enum by its stable `name`, rejecting unknown values instead of
/// silently defaulting. Shared by the project and recognition deserializers.
T readEnum<T extends Enum>(List<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) {
      return value;
    }
  }
  throw const ValidationException('خيار غير معروف في بيانات المشروع.');
}

Map<String, Object?> objectMap(Object? value) {
  if (value is! Map<Object?, Object?> ||
      value.keys.any((key) => key is! String)) {
    throw const ValidationException('بيانات المشروع ليست كائناً صالحاً.');
  }
  return Map<String, Object?>.from(value);
}

List<Object?> objectList(Object? value) {
  if (value is! List<Object?>) {
    throw const ValidationException('قائمة بيانات غير صالحة.');
  }
  return List<Object?>.from(value);
}

/// Device names Windows refuses, with or without an extension. One definition
/// serves backup extraction and export naming so the two can never disagree.
final _reservedWindowsNames = RegExp(
  r'^(con|prn|aux|nul|clock\$|com[1-9]|lpt[1-9])(?:\..*)?$',
  caseSensitive: false,
);
bool isReservedWindowsName(String name) => _reservedWindowsNames.hasMatch(name);

void validId(String id) =>
    require(RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id), 'معرّف غير صالح.');

void validName(String name) => require(
  name.trim().isNotEmpty && name.length <= 160 && !name.contains('\u0000'),
  'يجب أن يكون الاسم بين 1 و160 حرفاً.',
);

/// Platform-independent, intentionally restrictive app-owned path format.
void validAssetPath(String path) {
  require(
    path.isNotEmpty &&
        path.length < 500 &&
        !path.startsWith('/') &&
        !path.contains('\\') &&
        !path.contains(':') &&
        !path.contains('\u0000') &&
        path
            .split('/')
            .every(
              (part) =>
                  part.isNotEmpty &&
                  part != '.' &&
                  part != '..' &&
                  RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(part),
            ),
    'مسار أصل غير آمن.',
  );
}
