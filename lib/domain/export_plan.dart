import 'dart:math' as math;
import 'geometry.dart';
import 'project.dart';
import 'validation.dart';

class ExportPlan {
  ExportPlan(this.project, this.profile, {List<int>? pages})
    : pages = List.unmodifiable(
        pages ?? List.generate(project.pageCount, (i) => i),
      ) {
    require(
      this.pages.isNotEmpty &&
          this.pages.toSet().length == this.pages.length &&
          this.pages.every((i) => i >= 0 && i < project.pageCount),
      'نطاق صفحات التصدير غير صالح.',
    );
    require(
      project.items.any(includes),
      'أضف مستمسكاً إلى الورقة قبل التصدير.',
    );
    for (final item in project.items.where(includes)) {
      require(
        project.paper.printable.contains(item.bounds),
        'عنصر خارج حدود الطباعة؛ أصلح التخطيط قبل التصدير.',
      );
    }
  }
  final Project project;
  final ExportProfile profile;
  final List<int> pages;
  bool includes(DocumentItem e) =>
      e.pageIndex != null && pages.contains(e.pageIndex);
  int get pixelWidth =>
      millimetersToPixels(project.paper.width, profile.dpi).round();
  int get pixelHeight =>
      millimetersToPixels(project.paper.height, profile.dpi).round();
  List<DocumentItem> items(int page) =>
      project.items.where((e) => e.pageIndex == page).toList()
        ..sort((a, b) => a.zIndex.compareTo(b.zIndex));
  List<String> get warnings {
    final result = <String>[];
    final unplaced = project.items.where((e) => e.pageIndex == null).length;
    if (unplaced > 0) result.add('$unplaced عناصر غير موضوعة لن تُصدّر.');
    for (final e in project.items.where(includes)) {
      final a = project.assets.firstWhere((a) => a.id == e.assetId);
      final dpi = math.min(a.width / e.width, a.height / e.height) * 25.4;
      if (dpi < profile.dpi)
        result.add(
          '${a.name}: دقة المصدر الفعلية ${dpi.floor()} DPI؛ التكبير لا يضيف تفاصيل.',
        );
    }
    return result;
  }
}
