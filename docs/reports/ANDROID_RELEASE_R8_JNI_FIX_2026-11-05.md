# إصلاح توقف التحليل في Android Release الموقّع — 2026-11-05

## النوع والمطلوب ومعيار القبول

- **النوع:** إصلاح عطل بناء/تشغيل مرتبط بـ Release، وليس تغييراً في سياسة القص أو التصنيف.
- **المطلوب:** ألا يتوقف التطبيق عند «تحليل الصور» في الحزمة الموقّعَة بينما يكمل البناء غير الموقّع/Debug لنفس المدخل. إذا لم توجد أدلة كافية يجب أن تبقى النتيجة الصادقة `unknown` مع إمكانية القص اليدوي، لا أن يُختلق قصّ أو نوع.
- **معيار القبول:**
  1. عقد أسماء ONNX Runtime JNI محفوظ في حزمة Android المصغّرة بـ R8.
  2. اختبار Android أصلي يبني Release موقّعًا فعليًا بمفتاح اختبار مؤقت، ويثبّته ويشغّل النماذج الأصلية عبر الاستيراد الحقيقي وإعادة الفتح/retry على المحاكي، ولا يكتفي بنجاح التوقيع أو باكتمال العداد مع fallback صامت.
  3. الأصل لا يتغير، ولا يتكرر العنصر عند إعادة المعالجة.
  4. حارس يمنع حذف قاعدة الحماية مستقبلاً، وبوابات المشروع والبناء على SHA التغيير.

## الوضع الحالي والمتوقع

- **المبلغ عنه:** النسخة الموقّعة تتوقف عند التحليل؛ بعد إعادة الفتح تظهر ملفات الأصل محفوظة دون قصّ. النسخة غير الموقّعة تكمل وتعرض الورقة/الصورة ولو بقي النوع غير معروف.
- **المتوقع:** النسخة الموقّعة تكمل مسار التحليل مثل Debug. بقاء النوع `unknown` أو بقاء القص يدوياً عند عدم كفاية الدليل سلوك أمان قائم، وليس فشلاً يُعالج باختراع نتيجة.

## السبب الجذري والأدلة

### ما ثبت من الشيفرة والتغليف

1. Flutter **3.35.7** يفعّل `isMinifyEnabled = true` و`isShrinkResources` لنوع البناء `release`، ويحمّل `android/app/proguard-rules.pro`:
   - [`FlutterPlugin.kt` في وسم 3.35.7](https://github.com/flutter/flutter/blob/3.35.7/packages/flutter_tools/gradle/src/main/kotlin/FlutterPlugin.kt#L264-L283).
2. المشروع عند `719c06c85cab5e3644416a91db7ffb60c53c9158` لم يكن يحتوي `android/app/proguard-rules.pro`، ولا توجد قواعد consumer في إضافة ONNX المثبتة:
   - `pubspec.lock` يثبت `flutter_onnxruntime` عند `2f0fc6c102652965004b89512b7187e6621dddf7`.
   - شجرة `android/` في ذلك الالتزام لا تحتوي ملف القواعد، والإضافة نفسها لا تحتوي `consumerProguardFiles`.
3. وثيقة الإضافة المثبتة تطلب صراحةً إنشاء الملف بالقاعدة:
   - [`README.md` للإضافة](https://github.com/masicai/flutter_onnxruntime/blob/2f0fc6c102652965004b89512b7187e6621dddf7/README.md#android)
   - [`doc/troubleshooting.md`](https://github.com/masicai/flutter_onnxruntime/blob/2f0fc6c102652965004b89512b7187e6621dddf7/doc/troubleshooting.md#android) وتذكر عرض R8: `JNI DETECTED ERROR IN APPLICATION: mid == null`.
   - القاعدة المطلوبة: `-keep class ai.onnxruntime.** { *; }`.
4. مكتبة ONNX الأصلية تبحث عن هذه الأسماء من JNI، وليس عبر استدعاءات Java فقط يمكن لـ R8 تتبعها:
   - [`ai_onnxruntime_OrtSession.c`](https://github.com/microsoft/onnxruntime/blob/v1.28.0/java/src/main/native/ai_onnxruntime_OrtSession.c) يستخدم `FindClass("ai/onnxruntime/NodeInfo")` و`GetMethodID`.
   - [`OrtJniUtil.c`](https://github.com/microsoft/onnxruntime/blob/v1.28.0/java/src/main/native/OrtJniUtil.c) يستخدم أسماء `ai/onnxruntime/OnnxTensor` و`TensorInfo` و`OnnxValue` وغيرها.
5. Debug لا يمر بخط R8 نفسه؛ لذلك يمكن أن يعمل بينما يفشل Release المصغّر. هذا يفسر فرق وضع البناء، وليس التوقيع بحد ذاته: مفتاح التوقيع لا يغيّر أسماء Java/JNI.

**النتيجة الهندسية:** عيب تعبئة Release مثبت: واجهة JNI المطلوبة كانت قابلة للحذف/إعادة التسمية. الإصلاح يعيد العقد الذي تطلبه الإضافة والمنبع.

### حدّ الإثبات الميداني

لا يوجد جهاز المستخدم أو `logcat` من الحزمة التي انهارت في هذه البيئة. لذلك لا يُنسب إلى جهاز المستخدم سجل انهيار لم يُقرأ. الانحدار الجديد يشغّل Release موقّعًا فعليًا على محاكي Android ويتحقق من المسار بعد الإصلاح؛ التأكيد النهائي على هاتف المستخدم يبقى خطوة ميدانية مطلوبة بعد تثبيت حزمة من SHA يحتوي الإصلاح.

## الإصلاح المنفذ

- أضيف `android/app/proguard-rules.pro` بالقاعدة الوثائقية الكاملة:
  ```proguard
  -keep class ai.onnxruntime.** { *; }
  ```
  لا تعطيل لـ R8، ولا `-dontobfuscate` عام، ولا تغيير لمفتاح التوقيع أو أسرار النشر.
- أضيف `tool/check_android_r8.py` ويفحص وجود القاعدة في المسار الذي يحمّله Flutter، مع رفض الملف المفقود/التعليقات فقط/الحزمة الخاطئة/حفظ الأسماء دون الأعضاء.
- أضيف فحص القواعد إلى سير التحقق وسير Android الموقّع قبل البناء.
- أضيف `integration_test/release_intake_test.dart`:
  - يعمل عبر مدخل Release مستقل وعلامة نتيجة في logcat، فلا يحتاج VM service ولا يضيف `integration_test` إلى حزمة Release.
  - يستخدم صورة اصطناعية عامة، لا مستمسك مستخدم.
  - يشغّل `IntakeRunner` الحقيقي مع `LocalImageEditor` وسلسلة DocQuadNet/DocAligner ومحرك PP-OCRv5.
  - يشترط أحداث `native_completed` لمراحل استدلال النماذج و`ocr_completed`، ويرفض `native_failed`/`ocr_failed`/`stage_timeout`؛ باكتمال العداد وحده لا ينجح الاختبار لأن المسار يستطيع السقوط يدوياً عند الفشل.
  - يعيد فتح المشروع ويعيد معالجة الأصل نفسه، ويتحقق من عدم تكرار العنصر ومن ثبات بصمة الأصل.
- أضيف `tool/run_android_release_regression.sh`:
  - ينشئ مفتاح اختبار مؤقتاً ليوم واحد داخل مجلد مؤقت، ويحذفه عند الخروج.
  - لا يقرأ أسرار التوقيع الإنتاجية ولا يغير `EXPECTED_CERT_SHA256` الإنتاجي؛ يمرر بصمة مفتاح الاختبار لأمر الاختبار فقط.
  - يبني Release فعليًا بالمدخل `integration_test/release_intake_main.dart`، يثبّته ويشغّله على المحاكي، ويشترط علامة `SCANID_RELEASE_INTAKE_RESULT` ذات الحالة success.
  - يتحقق من وجود `mapping/scanidRelease/mapping.txt` ومن بقاء أسماء أصناف JNI، تُقيَّد أوامر adb بمهل حتى لا يعلّق التقاط الدليل الوظيفة، ويرفع السجل/الخريطة/ملخص النتيجة كدليل، ولا يرفع APK الاختبار كأثر تطبيق.
  - يعمل بعد خطوة «Ensure release build rejects missing signing credentials»، بحيث يبقى حارس غياب التوقيع الإنتاجي مختبراً كما كان.

## الملفات المضافة أو المعدلة

| الملف | التغيير |
|---|---|
| `android/app/proguard-rules.pro` | جديد: عقد حفظ أسماء/أعضاء ONNX JNI في R8 |
| `tool/check_android_r8.py` | جديد: حارس عقد التعبئة |
| `test/tool/test_android_r8.py` | جديد: اختبارات الحارس وربط خطوة الانحدار الإلزامية |
| `integration_test/release_intake_probe.dart` | جديد: مسبار مشترك للاستيراد/retry وفحوص الأصل/الاستدلال |
| `integration_test/release_intake_main.dart` | جديد: مدخل Dart يطبع نتيجة Release المهيكلة في logcat |
| `integration_test/release_intake_test.dart` | جديد: غلاف اختبار مضيف للمسبار نفسه |
| `tool/run_android_release_regression.sh` | جديد: تشغيل اختبار R8/AOT بمفتاح مؤقت وتحقق mapping ونشر ذيل السجل عند الفشل |
| `.github/workflows/verify.yml` | حارس القواعد، اختبار Python، خطوة محاكي R8 إلزامية، رفع دليل |
| `.github/workflows/android-signed-release.yml` | حارس القواعد قبل بناء الحزمة الموقّعة |
| `docs/STATUS.md` | حالة التنفيذ والقيود |
| `README.md` | ملاحظة بناء Android عن قاعدة R8 |

## الاختبارات والأوامر المنفذة محلياً

- `python -m unittest test.tool.test_android_r8 -v` قبل إضافة القاعدة: **فشل متعمد** في اختبار المستودع لأن الملف كان مفقوداً؛ بعد الإصلاح: **10/10** ضمن المجموعة الموسعة.
- `/home/user/annotation-venv/bin/python -m unittest test.tool.test_android_r8 test.tool.test_ci_gate test.tool.test_format_report test.tool.branch_cleanup_test test.tool.test_local_annotation_validator -v`: **58/58 نجاح**.
- `python tool/check_android_r8.py`: نجاح بعد أن كان يفشل قبل الإصلاح.
- `python tool/check_source.py`: نجاح؛ 255 ملف Dart ذات imports محلية محلولة، و1063 اختبار Dart/Flutter معلناً غير منفذ بهذا التدقيق.
- `python tool/check_detector_retirement.py`: نجاح.
- `python tool/check_workflow_permissions.py`: نجاح.
- `python tool/check_private_ci_checkout.py`: نجاح؛ 12 checkout تستثني البيانات الخاصة.
- `python -m compileall -q tool test/tool`: نجاح.
- `bash -n tool/run_android_release_regression.sh tool/run_android_instrumentation.sh`: نجاح.
- `git diff --check`: نجاح.

### ما تعذر محلياً

- `flutter` و`dart` غير مثبتين، ومضيف تنزيل Dart SDK الرسمي (`storage.googleapis.com`) محجوب في هذه البيئة؛ لذلك لم تُنفذ محلياً:
  - `dart format --output=none --set-exit-if-changed .`
  - `flutter analyze --fatal-infos`
  - `flutter test --reporter expanded`
  - `flutter build apk --release` بالمدخل الاختباري، ثم تثبيت/تشغيل وقراءة logcat وmapping Release
  - بناء Android/Windows.
- البديل المنفذ: حراس Python/بنية محلية، ثم GitHub Actions على SHA الدفع الفعلي. لا يُعلن نجاح بناء لم يُنفذ.

## حالة GitHub Actions

- الفرع المصرح: `arena/ea8f0b7b-scan-id`.
- **التشغيل الأخضر النهائي:** [`42152486961`](https://github.com/kinanmjeed88/Scan-id/actions/runs/42152486961) على SHA `cee2baeef6c5a1c28da628a89f2b40c1556b68a6`، والنتيجة `success`. الوظائف `android` و`Android debug/diagnostic differential` و`windows / windows` و`Android 16 startup evidence` كلها `success`.
- دليل وظيفة `android` (job `127678761098`) من annotations الرسمية:
  - `android-release-intake`: نجح الاستيراد/reopen/retry في Release/AOT موقّع بمفتاح اختبار مؤقت، دون نشر APK.
  - `android-release-intake-summary`: `releaseIntakeResult=success imported=1 assets=1 items=1 docAlignerRuns=1`.
  - `android-r8-rules exit=0`: `PASS: ONNX Runtime JNI classes and members are kept in R8 release builds.`
  - `test exit=0`: `+1091: All tests passed!`.
  - `android-instrumentation-evidence`: `androidTests=4 failures=0 skipped=0; docquadFlutterInferenceExit=0`.
- دليل `Android 16 startup evidence` (job `127687000845`): وصول إلى أول إطار رئيسي على API 36 (`x86_64`)، وتحميل `onnxruntime4j_jni` و`onnxruntime` وإنشاء `OrtEnvironment` في preflight. هذا دليل محاكي `x86_64` وليس دليل جهاز ARM64 فعلي.
- محاولات/مسارات مهجورة قبل النجاح:
  - بوابات تنسيق/تحليل Dart في ملفات الاختبار الجديدة صُححت عبر دفعات لاحقة؛ التشغيل `42145124441` فشل في `dart format` فقط قبل الوصول إلى Release.
  - التشغيل `42145933316` وصل إلى Release فعلياً، وفشل المسبار عند شرط متشدد `inferenceRuns >= 2` لأن retry أعاد استخدام اقتراح الحدود المحتفظ به؛ كما طالت الوظيفة حتى الإلغاء. عُدل الشرط إلى اكتمال retry مع استدلال أصلي سليم، وُقُيّدت أوامر adb بمهل، ثم نجح `cee2bae`.
  - بديل Profile/AOT أُزيل: قيود VM service ثم اعتمادات Gradle/إضافات dev dependency (`42116446348`، `42119881130`).
  - مسار androidTest ضد Release أُزيل: R8 للـ androidTest APK ثم `ClassNotFoundException: androidx.tracing.Trace` رغم قواعد الحفظ والاعتماد الصريح (`42133674388`، `42136149768`، `42138648169`، `42141823917`). أعيد `android/app/build.gradle.kts` إلى أصل `719c06c`، ولا توجد hooks اختبار في بناء الإنتاج؛ المسبار يُبنى كمدخل Dart مستقل ويُثبّت/يُشغّل مباشرة.

## الافتراضات والمخاطر المتبقية

- المقصود بـ«الموقع» في الطلب هو النسخة **الموقّعة**؛ لا يوجد مشروع ويب في هذا المستودع.
- الاختبار الاصطناعي يثبت تشغيل JNI والمسار في Release موقّع على المحاكي، ولا يقيس دقة OCR/الحدود على مستمسكات عراقية حقيقية.
- سياسة المراجعة اليدوية و`unknown` لم تتغير؛ لا يُفرض قصّ تلقائي لإخفاء الفشل.
- مفتاح الاختبار مؤقت وغير إنتاجي؛ الحزمة القابلة للتوزيع ما زالت تُبنى فقط بالأسرار المحمية في سير النشر الموقّع.
- إذا استمر التوقف على هاتف المستخدم بعد حزمة تحتوي هذا الإصلاح، فالمطلوب سجل انهيار/`logcat` من ذلك التثبيت؛ لا يُخفى احتمال وجود سبب جهاز آخر خلف هذا الإصلاح.
