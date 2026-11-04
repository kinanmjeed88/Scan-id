# سجل تقدّم العمل

> ملف حيّ: يُحدَّث بعد كل وحدة عمل. الحقول: التاريخ، الفرع، SHA، الحالة، الملفات، الاختبارات، الخطوة التالية.

## 2026-11-04 — وحدة العمل 1: تأسيس الفرع وتتبّع المسار

- **الفرع:** `arena/ded7f232-scan-id` (من `searchidf` @ `7330def`، أي بعد دمج PR #41).
- **SHA عند البدء:** `7330def` (لم يُدفع شيء بعد).
- **الحالة:** مكتملة تحليلًا — تم تتبّع مسار الاستيراد كاملًا من `main.dart` إلى `PaddleOcrEngine`، وتحديد السبب الجذري البنيوي (لا حدّ أعلى لأي مرحلة، ولا تحويل للتعليق إلى نتيجة).
- **الملفات المقروءة (بلا تعديل):** `lib/main.dart`، `lib/presentation/intake.dart`، `lib/application/{project_service,smart_recognition,recognition_pipeline,recognition_worker,cancellation,paddle_ocr_engine,paddle_ocr_runtime,ocr_engine}.dart`، `lib/persistence/local_image_editor.dart`، `lib/imaging/{ocr_region,boundary_proposal_cascade}.dart`، `android/app/src/main/AndroidManifest.xml`.
- **التوثيق:** `docs/ANDROID_IMPORT_FAILURE_AUDIT.md` (§1–§4).
- **الخطوة التالية:** تنفيذ الإصلاح (حدود المراحل) واختباراته.

## 2026-11-04 — وحدة العمل 2: حدود المراحل والاختبارات

- **الحالة:** مكتملة محليًا (بانتظار CI).
- **الملفات المعدّلة:** `lib/application/stage_budget.dart` (جديد)، `paddle_ocr_engine.dart`، `paddle_ocr_runtime.dart`، `recognition_pipeline.dart`، `smart_recognition.dart`، `lib/persistence/local_image_editor.dart`، `lib/presentation/intake.dart`، `test/application/paddle_ocr_engine_test.dart`.
- **الملفات المضافة (اختبارات):** `test/application/stage_budget_test.dart`، `recognition_pipeline_timeout_test.dart`، `smart_intake_stall_test.dart`.
- **الوثائق:** `docs/ANDROID_IMPORT_FAILURE_AUDIT.md` (§5–§9)،而这个 الملف.
- **الحالة المطلوبة بعد الدفع:** تشغيل `format` + `analyze` + كل الاختبارات + بناء Android/Windows على SHA الجديد، ثم تسجيل النتيجة هنا.

## 2026-11-04 — وحدة العمل 3: الدفع وتشغيل البوابات

- **الفرع:** `arena/ded7f232-scan-id`.
- **SHA المدقوع:** `a011b88` (فوق `7330def`).
- **فحوص محلية قبل الدفع:** `tool/check_source.py` (1032 اختبارًا مصرّحًا)، `tool/check_detector_retirement.py` PASS، `tool/check_workflow_permissions.py` PASS، اختبارات أدوات CI (`test.tool.*`) OK.
- **حالة CI:** في قائمة الانتظار (queued) على `a011b88` — لم تبدأ بعد؛ لا نتيجة.
- **الخطوة التالية:** متابعة Actions حتى النجاح، ثم تسجيل النتيجة النهائية هنا.

## 2026-11-04 — وحدة العمل 4: أول نتيجة CI حقيقية وإصلاح السبب الذي كشفته

- **SHA المدفوع:** `5eeef7e` (بعد `99aa2ad`، `1fd0bf8`، `2b1c9e9`، `a011b88`).
- **نتائج التشغيل 41886170937 على `5eeef7e` (فشل):**
  - `android`: `Flutter analyze` نجح هذه المرة، والاختبارات جرت فعليًا: **1054 اختبارًا، 5 إخفاقات**:
    `smart_intake_stall_test: one stalled image still completes the import`، وأربعة من `paddle_ocr_engine_test`
    (منها ثلاثة كانت ناجحة قبل هذا التغيير).
  - `windows`: خطوة `Run bundled PP-OCRv5 inference on Windows` فشلت في كل استدعاء، والسبب المطبوع:
    `unavailable: engine-failure stage=ocr-detection type=ArgumentError Invalid argument(s): Illegal ...`
  - `Android debug/diagnostic differential` و`android` و`windows` كلها فاشلة، `Android 16 startup evidence` متخطّى.
- **السبب الجذري المكتشف (مثبت من رسالة CI، لا تخمين):** إضافة `remaining()` (دالة محلية) والالتفافات
  حول المراحل داخل `recognize` أدخلت `Stopwatch` وكائنات غير قابلة للإرسال في نطاق الدالة نفسه الذي
  تُنشأ فيه closures الخاصة بـ `Isolate.run`. `Isolate.run` يرسل الـ closure مع سياق نطاقه، فصار
  إرسال الرسالة يفشل بـ `ArgumentError: Illegal argument in isolate message`، فيرجع كل استدعاء
  `engine-failure` بلا أي تعرّف. لم يكن هذا العيب خاصًا بـ Android: أسقط أيضًا اختبارات المحرك الأربعة على المضيف.
- **الإصلاح:** نقل تسليمات الـ isolate إلى دوال عليا مستقلة (`prepareOcrDetectionIsolated`,
  `locateOcrLinesIsolated`, `prepareOcrLineInputsIsolated`) بحيث لا يحمل سياقها إلا البايتات
  والتنسورات؛ ونقل استدعاء سلسلة الحدود المعلّمة إلى `_boundedCascade` في `local_image_editor.dart`
  لأن نطاقها نفسه فيه `runCancellableIsolate` (الكاشف الكلاسيكي).

## 2026-11-04 — وحدة العمل 5: تشغيل CI أخضر على آخر SHA

- **SHA:** `9f72a69` (وسابقاته في الفرع: `739cca2`, `5eeef7e`, `99aa2ad`, `1fd0bf8`, `2b1c9e9`, `a011b88`, كلها فوق `7330def`).
- **التشغيل:** 41890797505 — **النتيجة: success** لكل المهام:
  - `android`: success (بوابة `dart format`، `flutter analyze`، **1054 اختبارًا** بلا إخفاق، تدقيق التصدير).
  - `windows / windows`: success، **بما فيه `Run bundled PP-OCRv5 inference on Windows`** — أي أن التعرّف الحقيقي
    على ONNX ما زال يقرأ نصًا فعليًا بعد إحاطة المراحل بميزانية.
  - `Android debug/diagnostic differential`: success.
  - `Android 16 startup evidence`: success.
- **الاختبارات الجديدة التي جرت فعليًا في هذه البوابة:** `stage_budget_test` (8)، `recognition_pipeline_timeout_test` (2)،
  `smart_intake_stall_test` (3)، واختباران جديدان في `paddle_ocr_engine_test` — أي 15 اختبارًا جديدًا كلها ضمن الـ1054.
- **ما تبقّى:** اختبار الاستيراد على **Android Release وجهاز حقيقي** — غير ممكن في هذه البيئة (لا جهاز ولا Flutter/Java)،
  ولم يُنفَّذ، ولا يوجد ادعاء بنجاحه.

## 2026-11-04 — وحدة العمل 6: طلب السحب والسجل النهائي للبوابات

- **PR:** [#42](https://github.com/kinanmjeed88/Scan-id/pull/42) — `arena/ded7f232-scan-id` → `searchidf`، **بلا دمج وبلا إصدار**.
- **آخر SHA للكود:** `9f72a69` (و`9e875c8` يضيف الوثائق فقط).
- **تشغيلان أخضران على `9e875c8`** (وهو نفس شجرة الكود):
  - push: 41895243161 — success (`android`, `windows`, `Android debug/diagnostic differential`, `Android 16 startup evidence`).
  - pull_request: 41895267684 — success، و`gh pr checks 42` يظهر **pass** للمهام الأربع.
- **ما جرى فعليًا:** `dart format` (قراءة فقط) + `flutter analyze` + **1054 اختبارًا** + تدقيق التصدير المستقل،
  واستدلال PP-OCRv5 الحقيقي على Windows (نص لاتيني وعربي فعلي من صفحة مرسومة)، وبناء Android debug وWindows.
- **ما لم يُجرَّب:** استيراد صورة/مجموعة صور على **Android Release وجهاز حقيقي** — لا جهاز ولا Flutter/Java في البيئة.

## الخطوة التالية الدقيقة

1. `python3 tool/check_source.py` و`tool/check_detector_retirement.py` و`tool/check_workflow_permissions.py` (فحوص المستودع المحلية).
2. الدفع إلى `arena/ded7f232-scan-id` ومتابعة Actions حتى تنجح كل البوابات على آخر SHA.
3. تسجيل نتائج CI هنا + حالة اختبار Release APK (غير منفّذ بلا جهاز).
