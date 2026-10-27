import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:scan_id/reference_annotation/main.dart';
import 'package:scan_id/reference_annotation/store.dart';

void main() {
  testWidgets(
    'opens the standalone offline annotator without platform channels',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'scan-id-reference-ui-',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });
      final store = await ReferenceAnnotationStore.open(root);

      await tester.pumpWidget(ReferenceAnnotatorApp(store: store));
      await tester.pumpAndSettle();

      expect(find.text('الوسوم المرجعية · v2.0.0'), findsOneWidget);
      expect(find.text('اختيار صور من الهاتف'), findsOneWidget);
      expect(find.text('حفظ JSON محلياً'), findsOneWidget);
      expect(find.textContaining('لا توجد صور بعد'), findsOneWidget);
    },
  );
}
