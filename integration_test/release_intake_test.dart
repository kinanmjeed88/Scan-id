import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'release_intake_probe.dart';

/// Host-driven counterpart for local debugging. CI's Release proof uses
/// release_intake_main.dart plus Android instrumentation, because Release has
/// no VM service and Flutter strips integration_test from Release plugins.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'intake, reopen and retry preserve honest safe continuation',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      final evidence = await runReleaseIntakeProbe();
      expect(evidence['importedCount'], 1);
      expect(evidence['assetCount'], 1);
      expect(evidence['itemCount'], 1);
      expect(evidence['originalUnchanged'], isTrue);
      expect(evidence['retryOriginalUnchanged'], isTrue);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
