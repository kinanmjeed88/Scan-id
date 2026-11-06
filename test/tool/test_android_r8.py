from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tool import check_android_r8


class AndroidR8RulesTest(unittest.TestCase):
    def check(self, rules: str | None) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            if rules is not None:
                path = root / check_android_r8.RULES_PATH
                path.parent.mkdir(parents=True)
                path.write_text(rules, encoding="utf-8")
            return check_android_r8.verify(root)

    def test_missing_rules_reproduce_the_release_packaging_defect(self):
        # This is the checkout at 719c06c: Debug has no R8 step, while
        # Flutter enables R8 for Release and looks for this app-level file.
        errors = self.check(None)
        self.assertTrue(any("missing" in error for error in errors))

    def test_comment_only_file_is_not_a_jni_keep_contract(self):
        errors = self.check(
            "# Required by flutter_onnxruntime:\n"
            "# -keep class ai.onnxruntime.** { *; }\n"
        )
        self.assertTrue(errors)

    def test_required_rule_preserves_jni_classes_and_members(self):
        self.assertEqual(
            self.check(
                "# JNI looks these names up from native code.\n"
                "-keep class ai.onnxruntime.** { *; }\n"
            ),
            [],
        )

    def test_name_only_keep_does_not_preserve_constructors_and_fields(self):
        self.assertTrue(self.check("-keep class ai.onnxruntime.**\n"))
        self.assertTrue(
            self.check("-keep class ai.onnxruntime.** { <init>(...); }\n")
        )

    def test_unrelated_package_does_not_protect_onnx_jni(self):
        self.assertTrue(
            self.check("-keep class com.masicai.flutteronnxruntime.** { *; }\n")
        )

    def test_inline_comment_and_whitespace_are_accepted(self):
        self.assertEqual(
            self.check(
                "-keep class ai.onnxruntime.** { *; } # native contract\n"
            ),
            [],
        )

    def test_repository_keeps_the_rule_at_the_path_flutter_loads(self):
        self.assertEqual(check_android_r8.verify(), [])

    def test_release_regression_is_a_required_emulator_step(self):
        workflow = (
            check_android_r8.ROOT / ".github/workflows/verify.yml"
        ).read_text(encoding="utf-8")
        step = workflow.split(
            "- name: Android signed Release R8 intake regression (disposable test key)",
            1,
        )[1].split("- name: Upload Android R8 release evidence", 1)[0]
        self.assertIn("android-emulator-runner@", step)
        self.assertIn("script: bash tool/run_android_release_regression.sh", step)
        self.assertNotIn("continue-on-error", step)

    def test_runtime_regression_uses_actual_release_and_never_uploads_an_apk(self):
        script = (
            check_android_r8.ROOT / "tool/run_android_release_regression.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("integration_test/release_intake_main.dart", script)
        self.assertIn("flutter build apk --release", script)
        self.assertIn("adb -s \"$serial\" install -r \"$apk\"", script)
        self.assertIn("am start -W -n iq.scanid.scan_id/.MainActivity", script)
        self.assertIn("SCANID_RELEASE_INTAKE_RESULT", script)
        self.assertIn("mapping/scanidRelease/mapping.txt", script)
        self.assertIn("releaseIntakeResult=", script)
        self.assertIn("trap 'rm -rf \"$signing_dir\"' EXIT", script)
        self.assertNotIn("--profile", script)
        self.assertNotIn("secrets.KEYSTORE", script)
        self.assertNotIn("upload-artifact", script)

    def test_release_regression_does_not_add_production_test_hooks(self):
        gradle = (
            check_android_r8.ROOT / "android/app/build.gradle.kts"
        ).read_text(encoding="utf-8")
        self.assertNotIn("scanIdReleaseIntakeTest", gradle)
        self.assertNotIn("scanIdR8Profile", gradle)
        self.assertNotIn("testProguardFiles", gradle)
        self.assertNotIn("androidx.tracing", gradle)
        self.assertTrue((
            check_android_r8.ROOT / "integration_test/release_intake_main.dart"
        ).is_file())


if __name__ == "__main__":
    unittest.main()
