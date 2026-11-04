# تدقيق وإصلاح توقف استيراد الصور على Android

**التاريخ:** 2026-11-04 · **الفرع:** `arena/ded7f232-scan-id` · **المرجع (base):** `7330def` (دمج PR #41 في `searchidf`)

## 1. وصف المشكلة كما وردت

على Android APK، عند اختيار صورة واحدة أو عدة صور يصل التطبيق إلى مرحلة «تحليل الصور» ثم يتوقف: نافذة «جارٍ الاستيراد» تبقى ظاهرة، والعداد يبقى `0 / 1`، ولا تُكمل العملية ولا تُحفظ نتيجة.

**ملاحظة على الأدلة:** الحزمتان المذكورتان في الطلب (`scan-id-android-signature-report.zip`، `scan-id-windows (2).zip`) وصورة التوقف **ليست مرفقة في مساحة العمل** التي يعمل فيها هذا التدقيق، ولم يكن ممكنًا فتحها. لذلك:

- لم يُتحقَّق من تقارير التوقيع/Gradle داخل الـ zip، ولا من محتويات الـ APK/ABI في الملف المرفق.
- لم يُختبر الجهاز الفعلي ولا نسخة Release على هاتف: **لا ادعاء بذلك في هذا المستند**.
- SHA المرجعي هو SHA الفرع (الكود) الذي بُني منه أي APK لاحق، وليس SHA مستخرجًا من الـ APK المرفق — لأن الملف غير متاح.

## 2. مسار التنفيذ الفعلي (تتبّع الاستدعاءات)

```
main.dart  _openStorage()
  └ LocalImageEditor(boundaryProposer: BoundaryProposalCascade(DocQuadNet256, DocAlignerFastViT))
  └ ProjectService(smartRecognitionEnabled: appSmartRecognitionEnabled /* true */, ocr: PaddleOcrEngine())
        ↓  (اختيار الصور)
presentation/intake.dart  runIntakeWithProgress → IntakeRunner.run(onProgress:)
  └ ProjectService.importImages            (نسخ الأصول: يحدّث العدّاد لكل صورة)
  └ ProjectService.arrangeImportedImages(onProgress:)
        └ SmartIntake.run
             ├ Phase A: _analyzeImages → RecognitionBatchWorker.run(concurrency: 1)
             │     report()  ← «0 / 1» يُطبَع هنا قبل بدء العنصر
             │     task: editor.open(asset)  ← runCancellableIsolate (فك الصورة)
             │           RecognitionPipeline.analyze
             │             ├ segment (defaultSegment → فارغ)
             │             ├ suggestProposal  ← ONNX: DocQuadNet + DocAligner
             │             │     (ثم fallback: detectDocumentCornersScored داخل isolate)
             │             ├ prepareOcrRegion (تزامني، محدود)
             │             └ ocr.recognize → PaddleOcrEngine
             │                   ├ Isolate.run(prepareOcrDetection)
             │                   ├ OrtPpocrRuntime.runDetection  ← ONNX (channel)
             │                   ├ Isolate.run(locateOcrLines)
             │                   ├ rootBundle.loadString(dictionary)
             │                   ├ Isolate.run(prepareOcrLineInputs)
             │                   └ per line: OrtPpocrRuntime.runRecognition ← ONNX (channel)
             └ Phase B: _applyImage (قص/منظور، ثم حفظ واحد)
```

`RecognitionBatchWorker` يبلّغ عن التقدّم **قبل** العنصر وبعده فقط ([recognition_worker.dart](../lib/application/recognition_worker.dart) — `report()` في السطر 136 ثم داخل `lane()` بعد كل عنصر). لذلك أي انتظار لا ينتهي داخل `pipeline.analyze` يجمّد العدّاد عند `0 / 1` بالضبط، وتبقى النافذة مفتوحة، وهو العرض المُبلَّغ عنه حرفيًا.

## 3. آخر مرحلة تنجح وأول مرحلة يمكن أن تعلق

- آخر مرحلة ثبت أنها تنجح: نسخ الأصول وتقرير التقدّم (`importImages`) — لأن العدّاد يظهر `0 / 1` لمجموعة من صورة واحدة، أي أن مرحلة النسخ انتهت ودخلنا مرحلة التحليل.
- مرحلة التحليل هي التي لا تنتهي. داخلها هناك **ثلاث** نقاط تنتظر كودًا أصليًا/قنوات لا يضمن هذا التطبيق ردّها:
  1. `editor.open` → `runCancellableIsolate` (spawn isolate + فك الصورة).
  2. `BoundaryProposalCascade` → `flutter_onnxruntime` (DocQuadNet 256 + DocAligner 83 MB).
  3. `PaddleOcrEngine` → `flutter_onnxruntime` (PP-OCRv5 det + rec).

## 4. السبب الجذري

**لا يوجد في المسار أي حدّ أعلى لأي مرحلة، ولا أي تحويل لحالة «استدعاء أصلي لا يرد» إلى نتيجة.** هذا هو العيب البنيوي المثبت من الكود:

1. `RecognitionPipeline._runOcr` كان ينفّذ `await ocr.recognize(...)` مباشرة، بلا مهلة.
2. `PaddleOcrEngine.recognize` كان يطبّق `timeBudget` **على حلقة التعرف فقط**، بينما إنشاء الجلسة (`createSessionFromAsset`) واستدلال الكشف (`runDetection`) وقراءة القاموس خارج أي حدّ.
3. `LocalImageEditor.suggestProposal` كان ينتظر سلسلة ONNX بلا حدّ (الأخطاء مُلتقطة، لكن *التعليق* ليس خطأً يُلتقط).
4. `SmartIntake._analyzeImages` / Phase B لم تكن محاطة بمهلة، فلا يوجد ضمان أن الدفعة تتقدّم.

متى يحدث ذلك عمليًا على Android: عندما يفشل استدعاء أصلي **داخل خيط المنصة** دون أن يرسل ردًّا (فشل تحميل مكتبة/رمز، ضغط ذاكرة عند تحميل نموذج 83 MB، أو خطأ غير مُعالج داخل الـ plugin). في Dart يبقى `Future` معلّقًا إلى الأبد: لا استثناء، لا timeout، لا سجل. على Windows لم يظهر ذلك لأن النماذج تُحمّل بنجاح؛ **وعلى Android لم يكن هذا المسار يعمل إطلاقًا قبل PR #41** (كان `smartRecognitionEnabled = false`)، لذا كانت أول تجربة حقيقية له على الهاتف هي التي ظهرت فيها المشكلة.

**ما لم يُثبت:** لم أُثبت أيّهما بالتحديد (DocQuad، DocAligner، OCR det، OCR rec) هو الاستدعاء الذي علّق على جهاز المستخدم، لأن ذلك يحتاج سجلًّا من الجهاز أو إعادة إنتاج على جهاز/محاكي. ما أُثبت هو أن أيًّا منها كان **قادرًا** على تجميد الاستيراد إلى الأبد، وأن ذلك لم يعد ممكنًا بعد الإصلاح.

## 5. الإصلاحات المنفَّذة

| # | الملف | التغيير | السبب |
|---|---|---|---|
| 1 | `lib/application/stage_budget.dart` (جديد) | `runStageWithin` / `requireStageWithin`: كل مرحلة تنتهي بـ completed / failed / timedOut / cancelled؛ القيمة المتأخرة تُسلَّم لـ `onLateValue` لتحرير المورد، والخطأ المتأخر يُلاحَظ ولا يُرمى | ضمان «لكل عملية نتيجة نهائية» وتحويل التعليق إلى نتيجة صريحة |
| 2 | `lib/application/paddle_ocr_engine.dart` | الميزانية تغطي **كل** مرحلة أصلية (det، القاموس، rec) وليس حلقة التعرف فقط؛ عند الانتهاء تُعاد `unavailable('time-budget-exceeded')` ويُسقَط الجلسة العالقة | إزالة الانتظار غير المحدود داخل المحرك |
| 3 | `lib/application/paddle_ocr_runtime.dart` | `abandonStalledSessions()`: إسقاط المراجع دون انتظار النداء العالق، وإغلاق أي جلسة تصل بعد فوات الأوان | لا يبقى `Future` ميت مُخزَّن يعلق كل محاولة تالية، ولا تتسرّب جلسة |
| 4 | `lib/application/recognition_pipeline.dart` | `ocrBudget` (40 ث) يحيط بـ `ocr.recognize`؛ الانتهاء يُسجّل `ocrFailure` ويكمل التحليل بلا نص → النوع `unknown` | OCR دليل لا شرط؛ لا يوقف الاستيراد |
| 5 | `lib/persistence/local_image_editor.dart` | `boundaryBudget` (45 ث) حول سلسلة النماذج، ثم السقوط إلى الكاشف الكلاسيكي المستقل | نفس المبدأ لمرحلة الحدود |
| 6 | `lib/application/smart_recognition.dart` | `analysisBudget` (دقيقتان) حول `open + analyze` لكل صورة و حول `_applyImage`؛ `StageTimeout` يُترجم إلى `resourceLimit` مع رسالة صريحة + إبقاء الصورة كمستند يدوي | ضمان أن الدفعة تتقدّم دائمًا وأن العدّاد يصل إلى النهاية |
| 7 | `lib/presentation/intake.dart` | عرض الزمن المنقضي وملاحظة الإلغاء | التمييز بين «بطيء» و«عالق» دون إخفاء الحالة |

**ما لم يُفعل عن قصد:** لم تُرفع أي مهلة «لتمرير» الاختبار، ولم تُخفَ نافذة الانتظار، ولم يُغيَّر معنى العدّاد، ولم يُستبدل أي محرك بمحاكاة. الفشل يظهر للمستخدم بسببه، والنتيجة الناقصة تبقى ناقصة (`unknown`, بلا نص).

## 6. سلوك ما بعد الإصلاح

- صورة لا ينتهي تحليلها: تُحفظ كأصل، تُضاف كمستند يدوي (`documentKind = unknown`, `crop = null`)، وتظهر ملاحظة «تجاوزت المعالجة المهلة الزمنية على هذا الجهاز؛ بقيت الصورة الأصلية ويمكن قصّها يدوياً». العدّاد يتقدّم.
- فشل/تعليق OCR فقط: التحليل يكتمل، التصنيف يبقى `unknown`، وتُسجَّل ملاحظة `ocrFailure`؛ بقية المسار (حدود، قص، A4) يعمل.
- تعليق نموذج الحدود: يُستخدم الكاشف الكلاسيكي المحلي (مرحلة مستقلة، وما زالت مراجعة يدوية فقط).
- زر الإلغاء يعمل حتى أثناء استدعاء أصلي عالق (الإلغاء ينهي الانتظار).

## 7. الاختبارات المضافة

| الملف | ما يثبته |
|---|---|
| `test/application/stage_budget_test.dart` (8) | قيمة في الوقت، انتهاء عند التعليق، خطأ يمر كخطأ، إلغاء ينهي الانتظار، قيمة/خطأ متأخران يُلاحَظان ويُحرَّر المورد |
| `test/application/paddle_ocr_engine_test.dart` (+2) | كشف معلّق ⇒ `unavailable('time-budget-exceeded')` وإسقاط الجلسة؛ تعرّف معلّق ⇒ إبقاء الأسطر المفكوكة |
| `test/application/recognition_pipeline_timeout_test.dart` (2) | محرك OCR لا يرد أو يرمي ⇒ التحليل ينتهي، النوع `unknown`، والملاحظة `ocrFailure` |
| `test/application/smart_intake_stall_test.dart` (3) | صورة واحدة معلّقة ⇒ استيراد يكتمل + مستند يدوي + عدّاد 1/1؛ صورتان مع تعليق الأولى ⇒ تُعالج الثانية والعدّاد 2/2؛ الإلغاء أثناء التعليق ⇒ رجوع بلا تعليق |

## 8. حالة المنصات والبوابات (آخر تحديث: `9f72a69`)

- **Android على جهاز حقيقي: لم يُختبر هنا** (لا يوجد جهاز/محاكي في بيئة العمل). الاختبار المطلوب ميدانيًا: بناء Release APK وتنفيذ استيراد صورة واحدة ثم مجموعة صور — **غير مثبت**.
- **Windows:** الاختبارات الجديدة تعمل على مضيف الاختبار (Dart VM)، وبناء Windows يجري في CI.
- بوابات CI على `9f72a69` (تشغيل 41890797505): **نجحت كلها** — `android` (format + analyze + 1054 اختبارًا + تدقيق تصدير)،
  `windows` (بما فيه استدلال PP-OCRv5 الحقيقي على ONNX Runtime)، `Android debug/diagnostic differential`،
  `Android 16 startup evidence`.
- **معنى نجاح خطوة Windows للـ OCR:** التعرّف الحقيقي ما زال يقرأ نصًا لاتينيًا وعربيًا من صفحة مرسومة فعليًا،
  أي أن إحاطة المراحل لم تُسقط الوظيفة الأساسية. هذا دليل على أن المحرّك سليم، وليس دليلًا على نجاح الاستيراد على Android.

## 8.1 نتيجة CI الأولى (تشغيل 41886170937 على `5eeef7e`) وما كشفته

- `android`: التحليل الثابت نجح، و**1054 اختبارًا جرت فعليًا** بـ 5 إخفاقات، منها ثلاثة اختبارات محرك
  كانت ناجحة قبل التغيير.
- `windows`: كل استدعاء تعرّف رجع `engine-failure`، والسبب المطبوع من التشخيص:
  `stage=ocr-detection type=ArgumentError Invalid argument(s): Illegal ...` أي
  **`Illegal argument in isolate message`**.
- **السبب:** إضافة دالة محلية للميزانية (`remaining()` مع `Stopwatch`) في نطاق `recognize` جعلت
  closures الخاصة بـ `Isolate.run` تُرسَل مع سياق يحمل كائنًا غير قابل للإرسال، ففشل إنشاء الرسالة
  قبل أي استدعاء ONNX. هذا عيب في الإصلاح نفسه وليس في التطبيق الأصلي، وقد صُحّح بنقل تسليمات
  الـ isolate إلى دوال مستقلة، وبفصل استدعاء سلسلة الحدود عن مسار `runCancellableIsolate`.
- **الدروس المثبتة:** أي closure يُرسَل إلى isolate يجب ألا يشارك نطاقًا يحتوي `Stopwatch` أو كائنات
  المنصة؛ و`developer.log` لا يظهر في تعليقات CI، لذا صار التشخيص يُمرَّر في نص سبب الفشل
  (`lastFailureDiagnostic`) ليكون مرئيًا في أي تقرير ميداني.

## 8.2 طلب السحب

PR [#42](https://github.com/kinanmjeed88/Scan-id/pull/42) — مفتوح، بلا دمج، بلا Release. آخر SHA للكود `9f72a69`،
وطبقتا التحقق (`push` و`pull_request`) نجحتا على `9e875c8`.

## 9. ما لم يُحل / الخطوة التالية الدقيقة

1. **تحديد الاستدعاء الأصلي العالق بدقة** يحتاج سجلًّا من الجهاز:
   - `adb logcat -s flutter scan_id.stage scan_id.boundary` أثناء الاستيراد؛ الرسائل تحمل أسماء المراحل فقط (`ocr-detection`, `ocr-recognition`, `boundary-cascade`, `image-analysis`) بلا أي محتوى مستند.
2. إن ثبت أن DocAligner (83 MB) هو ما يعلق على أجهزة ضعيفة الذاكرة، فالخطوة التالية قرار منتج: تحميله فقط عند الحاجة بدلًا من كل استيراد، أو إسقاطه على الأجهزة منخفضة الذاكرة — **لم يُنفَّذ لأنه تغيير سلوك بلا دليل بعد**.
3. اختبار Release APK على جهاز واحد على الأقل مع صور كبيرة/متعددة، وتسجيل النتيجة هنا.
