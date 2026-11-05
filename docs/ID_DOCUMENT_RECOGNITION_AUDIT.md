# تدقيق التعرف على المستمسكات والقياسات — 2026-11-05

## النتيجة وحدودها

نُفذت إصلاحات في مسارات المقاس والخصوصية وأضيفت اختبارات انحدار، **لكن القبول النهائي غير مثبت**: لا يتوفر Flutter أو Dart أو بيئة بناء Android/Windows هنا، وأوزان OCR وDocAligner غير موجودة. لم تُشغّل اختبارات Dart المضافة أو السابقة، ولم يُبن التطبيق. لا توجد في البيئة مجموعة صور حقيقية مقاسة ومرخصة لإثبات دقة الحدود أو OCR أو التصنيف. لا يدّعي هذا التقرير نجاحها أو عدم وجود انحدارات.

## الحالة المرجعية والمعمارية

بدأ العمل من `3374fd7ee422237d3decd416f0f14a4a987d6044`، على الفرع `arena/1dc907ec-scan-id`، وشجرة نظيفة. `main.dart` يحقن `LocalImageEditor` مع `BoundaryProposalCascade` (DocQuadNet ثم DocAligner)، و`PaddleOcrEngine`، ويفعّل smart recognition. تقسيم الصور متعدد المستمسكات معطّل مستقلاً (`multi_document_segmentation_flag.dart`). يفصل التصميم بين اقتراح الحدود وفحصها (`boundary_decision.dart` و`quad_assessment.dart`)، وOCR، ودليل نوع المستند (`ocr_evidence.dart` و`recognition_classifier.dart`)، ثم الأهلية والتخطيط (`document_edits.dart` و`arrangement.dart` و`page_layout.dart`). المقترح ليس اعتماداً؛ تتوفر مراجعة وقص يدوي. للمرشح ذي حدود غير محسومة حالة منفصلة عن `unknown` للنوع (`recognition_routing.dart`).

OCR المحلي المقصود هو PP-OCRv5 detection وArabic recognition مع قاموس وONNX Runtime، دون رفع الصورة لخدمة OCR. ملفات الأوزان تُجهّز قبل البناء بواسطة سكربتات مثبتة المصدر والهاش؛ المصدر وترخيص Apache-2.0 في `ocr_model_assets.dart` و`docs/OCR_ENGINE.md`. الاستثناء أو غياب النموذج ينتج unavailable لا نجاحاً بنص فارغ. في هذه النسخة من checkout لا يوجد ملفا PP-OCRv5 ولا DocAligner، لذا لا يمكن حتى الادعاء بأن أصول بناء هذه البيئة مكتملة. لا تُفهم صياغة الوثائق السابقة عن نموذج «مشحون» على أنها تحقق من هذا الـcheckout.

التصنيف قواعد نصية فعلية لكنها غير معايرة: عنوان ومجموعة مرساة أخرى على سطر مختلف، ودرجة أضعف السطرين. تسجَّل الأدلة المشتقة دون النص؛ النسبة أو اسم الملف لا يصنفان. التعارض وانخفاض الثقة يوجهان للمراجعة، وOCR وحده لا يحقق شرط المصدر المستقل غير النصي لتأكيد المقاس الآلي. لا يعني ذلك إثبات دقة التصنيف لأي نوع؛ يبقى `unknown` أو الاقتراح بانتظار الإنسان. لم يُضف نموذج أو اعتماد جديد.

## المقاسات والمصادر

- ID-1: ‏85.60 × 53.98 مم وفق ISO/IEC 7810:2019. ربطه بالبطاقة الوطنية العراقية **افتراض معياري غير مثبت بوثيقة جهة الإصدار** وليس قياس بطاقة فعلية.
- TD3: ‏125 × 88 مم وفق ICAO Doc 9303 Part 3، صيغة معيارية وليست إثباتاً لكل جواز فعلي.
- السكن 92.4 × 62.8 والتموينية 52 × 287 مم تقديران غير موثقين، والأخير مشكوك فيه. الأحوال المدنية وأخرى لا تملكان مقاساً موثقاً. التفاصيل وحدود المصادر في `docs/PHYSICAL_SIZES.md` و`documentSizeRecords`. لم تُراجع المصادر خارجياً في هذه الجلسة بسبب قيود الشبكة.
- حتى المقاسات المعيارية ليست قياسات فيزيائية مستنتجة من الصورة؛ المستخدم مسؤول عن التحقق من نسخته. سياسة اختيار نوع موثق مع قص معتمد كانت موجودة ولا تزال تتيح اعتماد المقاس المعياري يدوياً، مع بقاء افتراض ID-1 أعلاه مخاطرة مهمة.

## المشكلات والإصلاحات

1. `DocumentEdits.setKind` كان يؤكد أي مقاس كتالوج بمجرد وجود قص معتمد، بما فيه التقديري. هذا يسمح بوضع قيمة غير مقاسة على A4 بمجرد اختيار النوع. أصبح المقاس التقديري غير مؤكد، والنسخة المسجلة تحمل `estimated`؛ يظل القياس اليدوي عند إعادة اختيار النوع، وإعادة ضبط الكتالوج تعيده إلى غير مؤكد.
2. `validateManualBoundary` كان يقبل المقاس التقديري دون إدخال أبعاد، فيما محرر القص لم يعرض حقولها. أصبح المجال يرفض ذلك دون `customSizeMm`، وتعرض الواجهة حقلي قياس فارغين للمقاسات التقديرية وتعرض ملاحظة الكتالوج؛ يمكن إدخال أبعاد المستخدم صراحة. بقي اعتماد القص مستقلاً عن ادعاء قياس تلقائي. تغيير السلوك مقصود لحماية إدراج A4.
3. `DocumentEdits.applyCatalog` كان يغير أبعاد العناصر المؤكدة وحتى المثبتة دون تحديث snapshot، فيخالف حفظ قياسات المستخدم. أصبح يحدّث العناصر غير المؤكدة وغير المثبتة فقط، مع تحديث snapshot المؤقت. لا يغير العناصر المؤكدة القديمة أو المثبتة.
4. `PaddleOcrEngine.recognize` كان يرسل كائن الاستثناء إلى سجل المطور ويضع `toString()` في التشخيص رغم التعهد بعدم تسجيل البيانات. أزيلت رسالة الاستثناء وكائنه، وبقي اسم المرحلة ونوع الخطأ فقط. لا يضمن ذلك سلامة سجلات إضافات الطرف الثالث الأصلية التي لم تُختبر هنا.

## الملفات والمواضع والاختبارات

أرقام الأسطر تقريبية في شجرة العمل الحالية:

- `lib/domain/document_edits.dart:36,207`: اختيار النوع وتحديث الكتالوج.
- `lib/domain/manual_boundary.dart:98,252`: تحقق المقاس في تأكيد القص اليدوي.
- `lib/presentation/crop_screen.dart:274,805,826,1802`: حقول المقاس والملاحظة ومسار الاختيار.
- `lib/application/paddle_ocr_engine.dart:305-319`: تشخيص آمن.
- `lib/domain/recognition_overrides.dart:79`: تصحيح تعليق سياسة المراجعة.
- `test/domain/document_edits_test.dart:121,383`: عدم إدراج التقدير، إعادة التعيين، حفظ المقاس المقاس والمثبت. `test/domain/manual_boundary_validation_test.dart:44`: رفض التقدير غير المؤكد وقبول القياس الصريح. `test/presentation/crop_civil_status_size_test.dart:12`: حقول مقاس السكن والتموينية. `test/application/paddle_ocr_engine_test.dart:147`: عدم تضمين نص الاستثناء. **هذه الاختبارات أضيفت ولم تُنفذ**.
- اختبارات الحدود وOCR وتصنيف وأبعاد وA4 والتكامل كانت موجودة في `test/imaging`, `test/domain`, `test/application` و`integration_test`؛ وجودها لا يعني اجتيازها.

## نتائج الأوامر المنفذة

| الأمر | النتيجة الفعلية |
|---|---|
| `python3 -m pip install --user --break-system-packages -r tool/requirements-annotation-test.txt` | نجح محلياً؛ Pillow وNumPy خارج المستودع، بلا تعديل dependencies للمشروع. |
| `python3 -m unittest discover -s test/tool -p '*test*.py'` | أول محاولة فشلت لغياب Pillow؛ بعد تثبيت الاعتماديات نجحت: 48 اختباراً. تحذير 403 جزء من محاكاة اختبار حذف الفروع، وليس عملية حذف فعلية. |
| `python3 tool/check_source.py` | نجح فحص بنيوي للـimports وسياسات Android، وأحصى 1047 اختبار Dart معلناً؛ لا ينفذها ولا يحل محل analyzer. |
| `python3 tool/check_detector_retirement.py` و`python3 tool/check_workflow_permissions.py` | نجحا. |
| `python3 tool/fetch_ocr_models.py --verify` | فشل: أوزان OCR مفقودة؛ تحقق القاموس نجح. |
| `python3 tool/fetch_docaligner_model.py --verify` | فشل باتصال TLS؛ السكربت لا يدعم وضع تحقق مستقل بهذا الخيار ويطلب metadata أولاً. الوزن مفقود. تنزيل OCR من Hugging Face غير متاح ضمن المضيفين المسموحين. |
| `dart format --output=none --set-exit-if-changed lib test` | لم ينفذ، exit 127: Dart غير مثبت. التنسيق لم يُثبت. |
| `flutter analyze` و`flutter test` | لم ينفذا، exit 127: Flutter غير مثبت. |
| `flutter test test/imaging/document_detector_test.dart test/domain/ocr_evidence_test.dart test/domain/recognition_classifier_test.dart test/domain/document_edits_test.dart test/domain/manual_boundary_validation_test.dart test/domain/arrangement_test.dart` | لم ينفذ، exit 127. |
| `flutter test integration_test/ocr_inference_test.dart integration_test/docquad_inference_test.dart` | لم ينفذ، exit 127؛ لا جهاز موصول مثبت ولا أوزان OCR/DocAligner. |
| `flutter build apk --debug` و`flutter build windows --debug` | لم ينفذا، exit 127؛ النظام Linux ولا تتوفر أدوات Windows، وSDK Android/Java غير ظاهرين. لا يوجد APK أو Windows build جديد. |
| Release | لم يُحاول: متطلبات البناء والتوقيع غير متوفرة ولم يُطلب إصدار. |
| `git diff --check` | نجح وقت الفحص؛ لا يغطي التنسيق أو صحة Dart. |

## الأمان والموارد والمخاطر المتبقية

الصور والأدلة معالجة محلياً حسب المسارات المراجَعة؛ يوجد اتصال شبكة مستقل لميزة تحديث التطبيق، لذلك لا يعني «OCR دون شبكة» أن التطبيق لا يملك إذن إنترنت. لا صور شخصية أُرسلت أثناء التدقيق. تجهيز OCR يحدد عدد الأسطر، ويستخدم مراحل ذات مهلة وتحقق إلغاء؛ التحويلات مرتبطة ببكسلات الصورة والأسطر، والدليل النصي تقريباً خطي في طول الأسطر مضروباً في عدد عبارات القاموس الثابت. لا توجد هنا قياسات أداء فعلية أو حد أقصى مثبت للذاكرة على جهاز. المهلات لا تضمن قتل استدعاء native معلّق؛ إنشاء جلسات OCR كسول، وتُتخلص tensors في `finally` وتوجد آلية إغلاق/ترك جلسات متأخرة. لم يثبت تدقيق دورة حياة الخدمة أن جميع الجلسات تغلق عند إعادة إنشاء التخزين أو الخروج؛ ينبغي اختبار ملكيتها والتزامن والمهلات على الجهاز قبل الإنتاج. تنظيف resources الفعلية وOOM للصور الكبيرة لم يُتحققا تشغيلـياً.

توصيات إلزامية قبل اعتبار المهمة مكتملة: تجهيز Flutter 3.35.7 وAndroid SDK وJava وWindows runner وأوزان الأصول المثبتة هاشاً من المصادر الموثقة؛ تنفيذ `dart format`, `flutter analyze`, كامل `flutter test`, اختبارات integration على Android وWindows، وبناء debug لكليهما؛ ثم إصلاح أي تعارض مع الاختبارات السابقة. تقييم الحدود وOCR وقواعد التصنيف على صور حقيقية مأذون بها مع وسوم وقياسات وأخطاء وثقة، دون إرسال بيانات شخصية. مراجعة دورة حياة جلسات ONNX والتزامن وإلغاء العمليات. مراجعة جميع المسارات القديمة للعناصر المؤكدة والمشاريع المهاجرة وعدم ترحيل قياس سابق أو حذفه تلقائياً. التدقيق الحالي لم يثبت خلو كل مسار من الانحدار أو صلاحية المقاسات التاريخية.


## التحقق النهائي لهذه المرحلة

### مصفوفة النتائج والأدلة

| النتيجة | المستوى والأدلة | اختبار الانحدار وحالته |
|---|---|---|
| علامة المراجعة وسببها | **مثبتة بالكود فقط:** `BoundaryProposalCascade.suggestProposal` يولّد `modelDisagreement`، و`RecognitionPipeline.analyze` في `recognition_pipeline.dart:353-399` ينقل العلامة والسبب، و`_analyzeDetection` في `:415-501` يعيدهما إلى `verifyBoundary`. | `test/application/recognition_pipeline_test.dart:163` و`test/imaging/boundary_proposal_cascade_test.dart`؛ لم ينفذا. |
| إعادة محاولة إنشاء جلسة حدود | **مثبتة بالكود فقط:** `RetirableResource.run` في `retirable_resource.dart:15-35` ينزع الجيل الفاشل دون المساس بجيل أحدث؛ يستدعيه `DocQuadNet256.suggestProposal` (`docquad_model.dart:62`) و`DocAlignerFastViT.suggestProposal` (`docaligner_model.dart:57`). | `test/application/retirable_resource_test.dart` لحالة الفشل والجيل القديم؛ لم ينفذ. اختبارات `retryable_future_test.dart` تخص المساعد السابق لا توصيل الإنتاج الحالي. |
| المقاسات المقدرة | **مثبتة بالكود فقط:** `DocumentEdits.setKind` (`document_edits.dart:36`) و`validateManualBoundary` (`manual_boundary.dart:98`) يبقيان التقدير دون اعتماد حتى إدخال قياس؛ `applyCatalog` (`document_edits.dart:207`) يحفظ قياسات مؤكدة/مثبتة. | `document_edits_test.dart` و`manual_boundary_validation_test.dart` و`crop_civil_status_size_test.dart`؛ لم تنفذ. لا يُعاد تغيير بيانات قديمة كانت مؤكدة بالفعل تلقائياً. |
| الخصوصية | **مثبتة بالكود فقط:** `PaddleOcrEngine.recognize` (`paddle_ocr_engine.dart:305-318`) وسجلات خطأ الحدود لا تدرج كائن الاستثناء الخام؛ لم تُراجع كل سجلات النظام أو الإضافة الأصلية. | `test/application/paddle_ocr_engine_test.dart:147`؛ لم ينفذ. |
| عمر ONNX وإعادة التحرير | **مثبتة بالكود فقط وليس اختباراً أصلياً:** `RetirableResource.run/retire` (`retirable_resource.dart:15-65`) تعدّ المستخدمين وتفصل الجيل ثم تبدأ تحريره مرة واحدة بعد توقفهم؛ `OrtPpocrRuntime.runDetection/runRecognition/abandonStalledSessions/close` (`paddle_ocr_runtime.dart:103-159`) وكاشفا الحدود يستعملونها. `finally` في كل استدلال يحرر tensors قبل انتهاء الاستخدام. | `test/application/retirable_resource_test.dart` يختبر بالموارد الوهمية التزامن، انتهاء الإنشاء المتأخر، إعادة المحاولة وفشل الجيل القديم؛ لم ينفذ ولا يثبت سلوك native. اختبارات OCR السابقة تستخدم runtime وهمياً ولم تنفذ. |
| عرض النوع | **مثبتة بالكود فقط:** `review_screen.dart:153-157` يصف نتيجة غير معتمدة كاقتراح يحتاج التأكيد؛ `intake.dart:149` و`editor_controller.dart:767` لم يعودا يصفان عداد الأنواع بأنه «معروف» بينما عداده يعتمد وجود مقاس كتالوج. | `test/presentation/review_screen_test.dart` و`test/presentation/rejection_feedback_ui_test.dart`؛ لم ينفذا. النتيجة قد تظهر كاقتراح في المراجعة، لا كدقة مقاسة. |

**حد الأمان:** إذا لم يُنهِ استدعاء native عمله إطلاقاً تُحتفظ موارده ولا يمكن تحريرها بأمان دون إلغاء native مضمون؛ لذلك لا يمكن إثبات انعدام التسرب أو استهلاك الذاكرة عند التعليق المتكرر. أيضاً `main.dart:195` يغلق قاعدة البيانات أثناء الاستعادة فقط ولا يملك إغلاقاً شاملاً لخدمات النماذج عند انتهاء التطبيق؛ وإغلاق tensor قد يفشل قبل تحرير بقية المخرجات. لا يُدّعى استيفاء معيار عدم التسرب أو التحرير المزدوج ميدانياً. مهلة انتظار `close` خمس ثوانٍ ولا تعني انتهاء العملية الأصلية. وقد تؤدي مهل متزامنة لجلسة قديمة إلى تقاعد الجيل الحالي أيضاً، وإن كان محمياً من التحرير قبل اكتمال مستخدميه؛ يلزم اختبار والتعامل مع هوية المحاولة في المتابعة.

### أنواع المستمسكات والأوجه

| النوع | آلية النوع المثبتة بالكود | الأمامي والخلفي |
|---|---|---|
| الوطنية | قواعد عنوان + قرينة نصية على سطر آخر، `ocr_evidence.dart:114-129` | لا يوجد مصنف وجه؛ `smart_recognition.dart:2026` ينشئ `SideKind.unknown`. |
| الأحوال المدنية | قواعد نصية `ocr_evidence.dart:130-144` | لا يوجد مصنف وجه أو بيانات تثبت دعم وجه معين؛ `unknown` ومراجعة يدوية. |
| السكن | قواعد نصية `ocr_evidence.dart:145-160` | لا يوجد مصنف وجه؛ `unknown` ومراجعة يدوية. |
| الجواز | قواعد نصية `ocr_evidence.dart:175-185` | لا يوجد تصنيف أمامي/خلفي أو نموذج بيانات صفحات موثوق؛ `unknown`. |
| التموينية | قواعد نصية إضافية `ocr_evidence.dart:161-174` | لا يوجد مصنف وجه؛ `unknown`. |

لا نموذج مدرّب لتصنيف النوع أو الوجه، ولا مطابقة قالب بصري، ولا استخراج موثوق لحقول شخصية؛ OCR ليس مصنفاً بحد ذاته. `side_pairing.dart` يقترح اقتراناً بحسب النوع والشكل وتجاور الاستيراد، و`smart_recognition.dart:2147-2192` لا يمرر دليل تطابق معرّف، لذا الاقتراح يبقى ملتبساً طبق العتبات الافتراضية. الاقتران ليس تصنيفاً للوجه. `recognition_overrides.dart:163` يدعم تصحيح الوجه يدوياً. لا توجد بيانات حقيقية تسمح بدعوى دقة أو تغطية لأي نوع أو وجه.

### أوامر أعيدت فعلياً في هذه المرحلة

- `dart test`: exit 127، لا يوجد Dart تنفيذي.
- Flutter 3.35.7 من نسخة GitHub الرسمية: `flutter analyze`، `flutter test`، `flutter build apk --flavor scanid --debug` و`flutter build windows --debug`: كل أمر exit 1 قبل بدء التحليل/الاختبارات/البناء، فشل تنزيل Dart SDK من `storage.googleapis.com` بسبب SSL/حظر المضيف. Windows مستحيل كذلك على نظام Linux؛ Android SDK وJava 17 غير ظاهرين. لا نجاح بناء لأي منصة.
- `python3 tool/fetch_ocr_models.py --verify`: exit 1، النموذج مفقود والقاموس اجتاز هاشه. `python3 tool/fetch_docaligner_model.py`: exit 1، تعذر TLS والوزن غير موجود. لا تشغيل للنماذج.
- `python3 -m unittest discover -s test/tool -p '*test*.py'`: **48 نجحت**؛ تحذير 403 محاكاة اختبار. `check_source.py`, `check_detector_retirement.py`, `check_workflow_permissions.py`, `check_private_ci_checkout.py`: نجحت فحوص بنيوية فقط. `git diff --check`: نجح. جرى فحص توقيع `OrtSession.close` في نسخة إضافة ONNX المثبتة `2f0fc6c102652965004b89512b7187e6621dddf7`: يعيد `Future<void>`؛ ليس اختبار native.

### Git Diff وHEAD

`git diff --stat` للتغييرات المتتبعة يسرد 21 ملفاً، ويتضمن تغيير دورة حياة ONNX، ومسار الحدود والقياسات والخصوصية، وتسميات الواجهة والاختبارات. الملفات الجديدة غير المتتبعة التي لا يشملها stat هي `docs/ID_DOCUMENT_RECOGNITION_AUDIT.md`, `lib/application/retirable_resource.dart`, `lib/application/retryable_future.dart`, `test/application/retirable_resource_test.dart`, `test/application/retryable_future_test.dart`. القائمة المفصلة الفعلية تُستخرج بـ `git status --short`؛ لا تغييرات على `pubspec.yaml` أو `pubspec.lock` ولا مخطط البيانات. HEAD هو `3374fd7ee422237d3decd416f0f14a4a987d6044` والشجرة غير نظيفة عمداً. لم يُنفذ commit أو push أو merge أو release.

## متابعة التدقيق الساكن والإصلاحات الإضافية

### مستويات الإثبات

| المستوى | ما ثبت في هذه الجلسة |
|---|---|
| **مثبت بالكود فقط** | المسارات والبوابات المذكورة أدناه، وجود قواعد التصنيف وآليات إعادة المحاولة والإصلاحات؛ لا يثبت ذلك سلامة التنفيذ أو ترخيص البيانات أو جودة النموذج. |
| **مثبت باختبار منفذ** | 48 اختبار Python للأدوات وفحوص بنيوية مسماة أدناه فقط. لم تُنفذ أي اختبارات Dart، سواء القديمة أو الجديدة. |
| **مثبت ببناء** | لا شيء: لم ينجح بناء Android أو Windows في هذه البيئة. |
| **غير مثبت ميدانياً** | دقة كشف الحدود، OCR، تصنيف المستمسكات، دورة حياة ONNX، الأداء والطباعة؛ يلزم صور حقيقية مرخصة وقياسات وأجهزة مناسبة. |
| **متعذر هنا** | Flutter/Dart وAndroid SDK وJava 17 وWindows runner ونماذج OCR وDocAligner. غياب جهاز حقيقي لم يمنع مراجعة الكود أو إصلاحاته. |

### تتبع فعلي للمسارات

- اختيار الملفات من `lib/main.dart` ثم `IntakeRunner.run` (`lib/presentation/intake.dart:83-130`) يحفظ الأصل بـ `ProjectService.importImages` (`project_service.dart:315-395`)، ثم يستدعي `arrangeImportedImages` (`:409-451`) و`SmartIntake._analyzeImages` (`smart_recognition.dart:380-455`) عند تفعيل العلم الإنتاجي. الفشل بعد الحفظ لا يلغي الأصل. `CameraCapture.accept` (`camera_capture.dart:37-60`) يحفظ الالتقاط؛ مسارا الالتقاط واستعادة الالتقاط في `project_screen.dart:163-290` لا يستدعيان `IntakeRunner` ولا ينفذان OCR تلقائياً: يظلان متاحين للقص/المعالجة اللاحقة. هذا فرق سلوكي، وليس ادعاء تعرّف للكاميرا.
- `LocalImageEditor.open` (`local_image_editor.dart:76-105`) يعد نسخة معاينة، و`suggestProposal` (`:114-170`) يشغّل سلسلة نموذجين ثم احتياطياً كاشفاً كلاسيكياً للمراجعة. `BoundaryProposalCascade.suggestProposal` (`boundary_proposal_cascade.dart:37-83`) يشغّل النموذجين ويشير لاختلاف الزوايا؛ `RecognitionPipeline.analyze` (`recognition_pipeline.dart:262-412`) يمرر الاقتراح إلى `verifyBoundary` (`boundary_decision.dart:277`)، بينما `defaultSegment` فارغ وميزة التقسيم المتعدد معطلة. معيار `assessQuad` هندسي لا يحدد النوع. القص والتحويل المنظوري في `crop_draft.dart` و`imaging/perspective.dart` لا يستنتجان مم من البكسل؛ القص اليدوي يخضع للتحقق في `manual_boundary.dart:98`.
- `PaddleOcrEngine.recognize` (`paddle_ocr_engine.dart:160-320`) يجهز المدخل، يحدد صناديق أسطر DB، يقتطع ويشغل CTC، ثم يعيد أسطراً وثقة وحدوداً في الذاكرة. `recognition_pipeline.dart:527-602` يولد من النص أدلة قواعد، وليس حقولاً شخصية منظمة. **لا يظهر في مسار الإنتاج مستخرج حقول مثل الاسم أو الرقم أو تاريخ الميلاد**؛ لا يُدّعى تنفيذه لمجرد وجود نماذج بيانات عامة. OCR للمنطقة المعزولة بلا حدود آمنة يتخطى القراءة، لكن في مسار الصورة المفردة قد تستخدم المعاينة كلها؛ للمستندات المتعددة غير المفصولة قد تتداخل أدلة نصوصها، لذا يلزم مراجعة بشرية.
- **يوجد مصنف قواعد فعلي وليس نموذج تصنيف بصري**: `ocr_evidence.dart:111-205,247` يحدد عناوين ومرتكزات للبطاقة الوطنية، الأحوال المدنية، السكن، التموينية والجواز؛ `recognition_classifier.dart:58` يرتب الأصناف ويطبق عتبة وتعارضاً، و`recognition_routing.dart:104` يمنع القبول الآلي بالأدلة النصية وحدها. هذه الأنواع مدعومة بالقواعد في الكود فقط، لا بدليل أداء حقيقي. `other` اختيار يدوي؛ `unknown` حالة مختلفة عن فشل الحدود. `smart_recognition.dart:1878` يربط المقاس المعياري بشروط صارمة، و`arrangement.dart:46,145` و`page_layout.dart` يمنعان وضع عنصر غير مؤكد. لا توجد قياسات فيزيائية من الصورة وحدها.
- `Project.fromJson` (`project.dart:976-1023`) يقبل نسخ المخطط 1–5، و`local_project_repository.dart:145-176` يحتفظ بلقطة سابقة للترحيل؛ لا تغيير في المخطط أو ترحيل البيانات في هذا التعديل. العناصر القديمة المؤكدة لا يُعاد تصنيفها آلياً كغير مؤكدة، وصدق مقاساتها التاريخية غير مثبت. اختبارات الترحيل موجودة ولم تُنفذ.

### الإصلاحات الإضافية في المتابعة

- `recognition_pipeline.dart:353-399,415-501`: كان مسار المستند المفرد يفكك `BoundaryProposal` دون تمرير `forceReview` أو `forceReviewReason`، فيفقد سبب اختلاف النموذجين، وقد يسمح باعتماد اقتراح لمصدر آخر بعتبة تسمح به. أعيد تمريرهما لبوابة التحقق. النماذج الحالية نفسها تستخدم عتبة مراجعة فقط، لذلك لا يُدّعى إثبات وقوع قص تلقائي في الإنتاج الحالي. اختبار الانحدار `test/application/recognition_pipeline_test.dart:163` يغطي سبب الاختلاف وغياب تصريح القص؛ لم يُنفذ.
- `lib/application/retryable_future.dart` كان إصلاحاً سابقاً لفشل إنشاء الجلسة، لكنه لم يحمِ استخدام الجلسة المتزامن مع إغلاقها. بعد مراجعة هذه المرحلة صار كاشفا الحدود يستخدمان `RetirableResource` بدلاً منه، حفاظاً على إعادة المحاولة مع تتبع المستخدمين؛ بقي الملف واختباراه السابقان في الشجرة كما كانا، لكنهما لم يعودا يغطيان المسار الإنتاجي. التغطية الحالية المقترحة في `test/application/retirable_resource_test.dart`، ولم تُنفذ.
- `lib/imaging/boundary_proposal_cascade.dart:92-105` و`lib/persistence/local_image_editor.dart:132-144`: لم تعد رسائل الاستثناء الخام تدخل سجلات مسار الحدود، وتُسجل فئة الخطأ بدلاً منها. لم تُراجع جميع سجلات الإضافات الأصلية أو بقية التطبيق، ولذلك لا يُدّعى انعدام التسرب نهائياً.

### الأوزان والتراخيص والأدوات

- `sha256sum` الفعلي لـ DocQuadNet الموجود: `f0f2f52d7d79ff02d346c8f9d0c9e903407366aeea1747cdcff160c401e3e72a`، يطابق الثابت في `tool/check_detector_retirement.py:182`. مطابقة الهاش تثبت هوية الملف نسبةً للثابت لا نجاح inference ولا كفاية الحقوق. تقرير `docs/reports/DOCUMENT_DETECTION_RETIREMENT_REPORT_2026-10-28.md` يسجل غموض حقوق DTD ضمن سلسلة بيانات تدريبه وحقوق بيانات تدريب DocAligner؛ وجود ملفات ترخيص البرنامج أو الوزن وحده لا يحسم حق التدريب/التوزيع. يلزم تدقيق قانوني ومصدر بيانات قبل النشر.
- DocAligner مثبّت إلى GitHub release 1.1.1 بوزن 83,084,930 بايت والهاش `7f9f5a8935b2eb22b3ee0245d34996063f54562df390d34714af2d76928695bc` في `tool/fetch_docaligner_model.py`. حاولنا تشغيل سكربت الجلب فعلياً وفشل TLS قبل توفر الوزن. OCR: تحقق القاموس نجح، وحاولنا تنزيل الوزن المثبت من Hugging Face وفشل TLS بسبب قيود المضيفين؛ لم تُصنع أوزان بديلة. عدم توفر هذه الأصول المدرجة في `pubspec.yaml` يعيق البناء أيضاً.
- نُسخ مصدر Flutter الرسمي بالإصدار المحدد في CI، **3.35.7**، داخل ذاكرة مؤقتة خارج المستودع من GitHub؛ ثبت أن commit هو `adc901062556672b4138e18a4dc62a4be8f4b3c2`. لكن `flutter --version` فشل عند تنزيل Dart SDK لمحرك `035316565ad77281a75305515e4682e6c4c6f7ca` من `storage.googleapis.com` بسبب SSL/تقييد الشبكة. لا يوجد Dart قابل للتنفيذ؛ المشروع يشترط Dart `>=3.9.0 <4.0.0`. لم تُغيّر الإصدارات أو الاعتماديات. CI يطلب Java 17، وهو غير مثبت هنا. التشغيل على Windows يتطلب Windows runner لا يتوفر على Linux هذا.
- نجح `python3 -m compileall -q tool test/tool`؛ وأعيدت فحوص `check_source.py` و`check_detector_retirement.py` و`check_workflow_permissions.py` و`check_private_ci_checkout.py` واجتازت؛ `python3 -m unittest discover -s test/tool -p '*test*.py'` أعاد 48 ناجحة. `git diff --check` نجح. تشغيل `check_annotator_manifest.py` بلا وسيط فشل usage لأن فحصه يتطلب manifest مبنياً؛ لم يكن هناك manifest بناء. لا تُعد هذه النتائج بديلاً عن Flutter analyze/test أو اختبارات Android/Windows.

### موارد وتزامن

الكود يحدد 20 MiB للملف و16 مليون بكسل لفك الترميز العادي، و32 مليوناً لمدخل JPEG المكبّر و4 ملايين لنسخة العمل، وحافة معاينة 1200 (`image_limits.dart:1-31`). عامل الدفعة الافتراضي واحد (`recognition_worker.dart:63`)، ومهلة سلسلة الحدود 45 ثانية وOCR 25 ثانية ومرحلة OCR الخارجية 40 ثانية وتحليل الصورة دقيقتان. لا تغطي المهلة الداخلية كل عمليات `Isolate.run` بصرامة، ولا تقتل timeout عملية native المستمرة؛ قد تستمر عملية قديمة وتتداخل مع محاولة لاحقة. الجلسات والجداول/الصورة تتطلب ذاكرة خطية في عدد البكسلات وخرائط النموذج، دون قياسات جهاز. إغلاق OCR وDocQuad وDocAligner متاح في الكود لكن تركيب `main.dart` لا يربط إغلاقها بدورة خدمة عامة؛ `_recover` يغلق قاعدة البيانات فقط. التحقق من الإغلاق والتسرب والتزامن على الأجهزة ما زال مطلوباً، ولم يتم اختراع ضمان لا يثبته الكود.

## Git

HEAD النهائي غير المتغير: `3374fd7ee422237d3decd416f0f14a4a987d6044`؛ لم يُنشأ commit أو merge أو release. التغييرات المذكورة والتقرير غير ملتزمة في شجرة العمل؛ راجع `git status --short` و`git diff` للحصول على الحالة الفعلية، لأن التقرير نفسه جزء من الشجرة غير الملتزمة.


## Recurring Single-Image Import Hang — Root Cause and Resolution

**Status: investigation and partial hardening, not a verified resolution of the reported incident.** HEAD remains `3374fd7ee422237d3decd416f0f14a4a987d6044`; the worktree includes earlier audit changes and the additions below, with no commit or push. The screenshot shows the UI state, not the stack, OS, input, active build flags, elapsed time, or native operation. No device reproduction, before/after trace, Dart execution, ONNX inference, or performance measurement was available. Consequently the actual incident's root cause remains **unknown**.

### Proven code-level failure mechanisms (not proof of this incident)

* The shipped `main.dart` explicitly enables Smart Recognition and injects the OCR engine; service defaults differ. `RecognitionBatchWorker` reports `تحليل الصور` 0/1 before awaiting an entire image, and increments only after its task returns. Thus any blocked substage looks the same at 0/1. Before these changes, several image decodes/preprocessing operations (`BoundaryProposalCascade`, both boundary models, OCR region preparation) ran synchronously on the Dart isolate. A slow or stuck computation there can block UI frames, timers and cancellation; a Dart timeout cannot rescue a blocked event loop. This is an actual architectural blockage, not evidence that it caused the pictured event.
* `runStageWithin` formerly checked a cancellation token only before starting; cancellation while a future was pending did not end its wait. `_analyzeImages` also failed to pass its token to `editor.open` and the proposal capability. Timeout abandoned analysis without cancelling its read-only isolate work. These are demonstrable code-path defects, not measured causes of the screenshot.
* `runCancellableIsolate` formerly sent its result and exit notification to different receive ports. Their independent delivery can let the exit be observed before a result; it also completed the cancellation future while `Isolate.spawn` was still awaited, before an error listener was attached. These are potential false-failure/unhandled-error races, not proven indefinite native stalls.
* `_IntakeProgressDialog._start` is launched unawaited and the dialog is not dismissible. An exception escaping `runner.run` formerly escaped `_start` without popping the dialog. This is a concrete path to a permanently open dialog after an error; it does not establish that the observed dialog entered that path.
* The fixed plugin revision in `pubspec.yaml` registers Android ONNX calls on a background task queue and wraps the handler in a common lock; long-running native calls can serialize and delay later calls. Windows registers a normal method channel and invokes `HandleCreateSession`/`HandleRunInference` synchronously in its handler, without an explicit background queue in that source. Depending on Flutter embedding dispatch, a long call may block the Windows platform thread. Neither source inspection proves which platform or call was responsible here. A Dart timeout does not cancel inference or create a second native execution lane.

### Traced lifecycle and transitions

1. Picker supplies `ImportSource` streams and optional cleanup; `IntakeRunner.run` calls `ProjectService.importImages`. Each bounded byte stream goes through `AssetRepository.importImage` (decode/preparation and local files) and `projects.save` before the import progress increments. Failed sources are reported; picker-cache cleanup is awaited. A blocked read, filesystem operation, cleanup or save remains an unbounded wait. Committed source assets survive later failure.
2. New asset IDs are passed to `arrangeImportedImages`; shipped configuration selects `SmartIntake.run`. `_analyzeImages` constructs a `RecognitionPipeline`, then `RecognitionBatchWorker.run` uses bounded concurrency (default 1). `LocalImageEditor.open` reads a saved source, and a read-only isolate decodes and creates the bounded preview. The pipeline awaits segmentation (the production default returns no candidates), boundary proposal/cascade, boundary geometry verification, optional OCR region preparation and OCR, then classification, orientation and size evidence. OCR/type and boundary decisions remain independent; uncertain sizes are not confirmed physical measurements.
3. Learned boundary adapters create/acquire ONNX sessions, create tensors, call `session.run`, decode outputs and dispose tensors; OCR likewise runs detection and recognition sessions. The native plugin's `Future`s complete only when the platform replies. `RetirableResource` leases generations so a timed-out consumer cannot close a session still in use; a call that never returns can retain its generation indefinitely. A timeout cannot force native release or prove later attempts can run.
4. Analysis outcomes return in input order. `_applyImage` stages derived files, document records and items; pairing and layout follow. A single project save commits the staged metadata. A failed/expired image can become a manual item; files written but not referenced can be orphans. Save failures propagate to `IntakeRunner`, which tries to reload committed state. The project screen adopts the returned project and then opens the layout; the editor controller adopts a later saved revision. These UI adoption steps are separate from merely finishing analysis.
5. The dialog pops only after the runner returns. The analysis count is phase progress, not proof of successful inference, persistence, UI adoption or document classification. Logs must be interpreted accordingly.

### Changes and why previous mitigation was insufficient

Previous budgets only bound waits while the Dart event loop is responsive; they do not interrupt native work, solve stalled native queues, cover every read/save, or explain the screenshot. This patch isolates cascade preview decode, both boundary preprocessors and OCR region preparation; wires a per-image cancellation token into preview, boundary and pipeline and cancels abandoned read-only work; lets bounded waits respond to cancellation while observing late outcomes; and uses one isolate port for result/exit while observing cancellation during spawn. Applying an image uses local staging/warnings and a child token so late work does not mutate the completed batch's collections. Writes remain cooperative; a timeout can still leave orphan files. The dialog now propagates unexpected errors instead of being stranded, and the runner attempts to reload committed imports after a batch-level exception. A second simultaneous call on the same runner is rejected. Phase progress switches to preparation/save instead of presenting the final analysis count as final import success; completion follows `arrangeImportedImages` returning. Task logs contain a process-local task number, fixed stage/state, elapsed milliseconds and error type, not images, file names, OCR text or exception messages. These coarse logs do not yet identify each native operation, individual item, platform dispatch thread or project-screen adoption; coverage is incomplete.

### Validation and remaining risks

* Earlier baseline: 48 Python tests and repository source/CI checks passed; **no Dart/Flutter test ran**. After this patch, `python3 -m unittest discover -s test/tool -p 'test_*.py'` passed 29 tests (including 21 annotation-validator tests); source, detector-retirement, permissions and private-checkout checks and `git diff --check` passed. One initial incorrect unittest pattern discovered zero tests and is not counted. These Python/static checks do not execute the changed Dart code.
* Added but **not run**: cancellation/late-value test, isolate result/exit and cancellation tests, isolated OCR region test, and committed-import recovery test. Existing simulated hanging-future tests are not device reproduction. No before/after functional or performance comparison exists. Full end-to-end coverage of ONNX creation failure/retry, hung inference and late results, every cancellation phase, OCR and persistence failures, sequential/concurrent imports, lease lifetime, counters and dialog closure remains outstanding.
* Flutter 3.35.7 source checkout exists, but its matching engine Dart SDK download from `storage.googleapis.com` fails TLS (`SSL_ERROR_SYSCALL`). Therefore format, analyze, all Dart/Flutter tests and Android/Windows builds were not run. Host is Linux without the required Android toolchain or Windows host. OCR model verification still reports missing detector weights; the pinned dictionary is present and matches its hash; DocAligner and OCR weights are not available locally. No device, visual or native runtime claim is made.
* Important unresolved risks: Windows plugin synchronous handlers and Android serialized native handler; stuck creation/inference and concurrent timeout retirement can still prevent retry or retain resources; bounded waits do not guarantee native cancellation; source reads, picker cleanup and persistence may hang; concurrent runners/project edits are not serialized globally, and the recovery count based on reloaded asset IDs is not a per-task attribution under concurrent edits. A timed-out apply can still finish a write and leave an orphan; tensor cleanup may stop early if disposal throws. Project adoption is not included in the task's completion trace. Full task-state ownership, per-stage diagnostics, safe native cancellation/isolation, globally coordinated imports, complete late-result cleanup and real-device end-to-end regression remain necessary before calling this resolved.
* At the time of this section, `git diff --stat` for tracked changes reports 28 files, 772 insertions and 441 deletions; untracked audit/resource/test files are excluded from that Git statistic. The exact final worktree is available via `git status --short` and `git diff`; counts can change as this report is updated.

### Follow-up: evidence-first investigation of the recurring 0 / 1 state

**Conclusion:** the observed incident has not been reproduced and its root cause remains **unproven**. No execution trace for that incident is available, so its last completed stage is **unknown**. The screenshot alone proves only that the progress display showed analysis 0/1. The previous section's code-level failure mechanisms are not proof of the cause of this incident. No additional timeout or new native/resource ownership workaround was introduced in this follow-up.

#### Trace implementation and interpretation

`lib/application/import_trace.dart` creates a cryptographically random per-run ID, monotonic elapsed time and per-operation sequence numbers; `IntakeRunner.run` establishes its context in a Dart Zone. Async descendants inherit the ID, while the code outside an isolate/platform call records dispatch and completion. The trace is observational, uses `dart:developer` under `scan_id.import_trace`, does not log images, document text, filenames, paths, exception messages or API keys, and isolates exceptions from the optional diagnostic observer. It requires an attached/debug-capable VM log consumer; availability in production release/logcat has not been established. Logs are not persisted by this change. Obtain a trace on the affected build/device without exporting document data.

Events emitted at actual call boundaries include `import_started`, `decode_started`/`decode_completed` and `image_decoded`, `preprocessing_started`/`preprocessing_completed` (phase distinguishes boundary-preview, model inputs, OCR region and OCR detector input), `detection_started`/`detection_completed` (segmentation versus boundary), `ocr_started`/`ocr_completed` or `ocr_unavailable`, `recognition_started`/`recognition_completed`, `persistence_started`/`persistence_completed` (source versus arrangement), and `import_completed`. Fixed-phase `native_started`/`native_completed` records session creation, detector/recognizer operation and inference. Failure/cancellation/timeouts are emitted as appropriate, including `stage_timeout`, `stage_cancelled`, `source_failed`, `ocr_failed`, `ocr_unavailable`, `ocr_timeout`, `import_failed` and `import_cancelled`. Operation IDs pair start and completion; `late=true` means the event occurred after the runner's terminal event, not that it was necessarily ignored. Check unmatched operations, not simply the final line: operations may overlap and an earlier native call can finish after a timeout. `ocr_completed` means the engine returned an available result, not that text was accurate. `recognition_completed` means analysis returned, possibly with issue/fallback records. `import_completed` marks **runner return**, not display or guaranteed recognition; `ui_state_applied` follows when project screen calls `setState` or editor adopts the returned project. It is normally logged after runner termination and therefore has `late=true`; it is not proof that a frame was rendered or that the image is visible. Disabled OCR or paths that do not perform a stage have no corresponding started/completed pair; no event is invented.

Key locations: `lib/presentation/intake.dart` (runner context, terminal event, dialog error propagation); `lib/application/project_service.dart` (`importImages`: source read, asset import, source save); `lib/application/smart_recognition.dart` (`_analyzeImages`: preview and recognition; `run`: apply and final project save); `lib/application/recognition_pipeline.dart` (segmentation, boundary, region and OCR events); `lib/imaging/boundary_proposal_cascade.dart`, `docquad_model.dart`, `docaligner_model.dart` (preprocessing and session/inference dispatch); `lib/application/paddle_ocr_runtime.dart` (OCR session/inference); `lib/application/stage_budget.dart` (existing budget cancellation/timeout); `lib/presentation/project_screen.dart` and `editor_controller.dart` (state adoption). Trace does not currently instrument every tensor release, every filesystem read, all platform channel calls or the Flutter frame/render pipeline. An event blocked before the Dart dispatch, a permanently blocked Dart event loop, dropped VM-service events, and a native hang can all prevent further trace output. A trace therefore narrows the wait, but by itself does not establish the native thread stack or prove why a reply was absent.

#### Independently reviewed hypotheses and limits

| Hypothesis | Source evidence | What is not established |
|---|---|---|
| Dart main isolate blocked | Previous work moved several decode/preprocessing operations into `runCancellableIsolate` (`boundary_proposal_cascade.dart`, `docquad_model.dart`, `docaligner_model.dart`, `ocr_region.dart`); pairing/layout and other Dart work remain synchronous. | No profiling or event-loop heartbeat from the affected device; responsiveness and performance after changes unmeasured. |
| Android UI thread blocked | Pinned ONNX plugin `2f0fc6c102652965004b89512b7187e6621dddf7`, Android source lines 169 and 185 uses a background task queue plus one synchronized lock; calls to create and run occur at lines 314 and 437–439. Local `NativeLargeJpegScaler.kt` starts threads at lines 43 and 92 and posts results to the UI thread. | No actual Android thread dump; other channel dispatch/replies can still wait. Source alone does not show this incident blocked Android's main thread. |
| Platform channel/native future or ONNX does not reply | Dart `Future` waits and native stage/operation traces identify dispatch boundaries. Android's common lock can serialize operations. Windows pinned plugin `flutter_onnxruntime_plugin.cpp` lines 51, 97, 103, 411, 656, 774 registers and calls handlers synchronously with no explicit background queue in this source. | No platform stack, inference test or platform-channel response trace. Timeout cannot stop a native call; source does not prove the precise embedding thread or a missing response. |
| Isolate message lost, closed listener, or spawn/cancel race | `cancellation.dart` now uses one port for result and exit and installs an early error observer; its result handler closes ports on finish and kills the worker. This changed behavior has only unexecuted regression tests. | No observed lost message or device-level proof that the message/exit ordering holds in the affected runtime. Unexpected malformed messages or unsendable error objects are not exhaustively tested. |
| Future or error path does not settle | Existing code can await source stream, source cleanup, persistence/reload, native calls, or a user-provided callback. The previous dialog patch forwards an escaped `_start` exception instead of leaving its `PopScope` dialog open. `recognition_pipeline.dart` and cascade intentionally convert some failures into fallback/issues; traces identify several but not all internal failure paths. | No runtime demonstration that this patch closes the actual affected dialog; no blanket guarantee all Futures end. No assumption that an unavailable OCR or fallback equals a successful recognition. |
| Save or database wait | Source and final arrangement `projects.save` are now distinguished in trace; source import can have committed before arrangement. `_cleanupSource` and recovery `projects.get` are still awaited without independent trace coverage. | No storage trace for the affected instance; no evidence which save, if any, waited. Partial saves and orphan files remain possible. |
| Cancellation/completion and stale task result | Each runner gets a distinct ID; late events keep the old ID. Prior per-image tokens and staged lists reduce some stale mutations; retained native sessions protect in-use resources. | No device concurrency test or global cross-run serialization. `late=true` is diagnostic only, not a guard proving no stale application state. Timed-out apply can still write orphan files; the import-recovery asset-difference count can include unrelated concurrent edits. |

Review also found that the prior progress wrapper can show a preparation/save phase after analysis outcomes include failures or cancellation; the original analysis count reflects settled items, not successful work. Session retirement is safer than closing an active session, but native operations which never return can retain resources, repeated OCR timeouts can retire a newer generation, tensor disposal can stop at the first thrown cleanup, and boundary session creation may remain pending on retry. No source inspection establishes that these defects caused the screenshot.

#### Test additions and actual verification

* Added `test/application/import_trace_test.dart`: fake single-image boundary path through real local repositories, second import after success, fake boundary failure and retry, fake delayed OCR and cancellation, fake boundary completion after cancellation with task correlation, and a fake source-save failure followed by retry. These are **written but not executed**; even passing them would not exercise real ONNX, a real device, screen rendering, or the actual screenshot. The saved item assertion is repository state, not a UI visibility assertion.
* Added `test/application/import_trace_diagnostic_test.dart`: gates a fake preprocessing future, simulates delayed/failing native work, correlates operation IDs and late events, and checks cancellation versus completion. These are **written but not executed** and simulate the trace contract, not native runtime behavior. Existing `cancellable_isolate_test.dart`, `retirable_resource_test.dart`, and stalled-future tests are likewise unexecuted. Fake ONNX creation failure at the actual plugin boundary, all timeout/cancel races, real native delayed results, widget dialog closure, and an end-to-end visible-image regression remain unverified. No test has reproduced the reported real-world failure before and after the patch.
* Actual commands in this follow-up: `/home/user/.cache/flutter-3.35.7/bin/dart format --output=none --set-exit-if-changed lib test`, `flutter analyze`, `flutter test`, `flutter build apk --flavor scanid --debug`, and `flutter build windows --debug` (the latter four using the same Flutter checkout). Each returned exit 1 **before running its task**: download of matching engine `035316565ad77281a75305515e4682e6c4c6f7ca` Dart SDK failed with `curl: (35) ... SSL_ERROR_SYSCALL` to `storage.googleapis.com`. No dependency/SDK version was changed to bypass this. Linux host cannot establish a Windows build or Android device result. `git diff --check` and `python3 tool/check_source.py` passed; the latter inventories 1061 Dart/Flutter declarations but does not execute or analyze them. They are not substitutes for Dart/Flutter tests.
* Prior tracked and untracked changes were retained. There is no commit, push, merge or release. Because neither the real failure nor a complete single-image-to-visible-UI retry regression has been executed, **acceptance is not met and no resolution is claimed**.
* Additional non-authoritative syntax screening: Python tree-sitter Dart grammar parsed 38 changed/untracked Dart files, reporting one file with four `ERROR` nodes on uses of the identifier `late` (`test/application/stage_budget_test.dart`); three equivalent uses already existed at HEAD. This may be a grammar/contextual-keyword limitation; without the Dart analyzer it cannot be dismissed or treated as a compiler result. The other 37 files had no tree-sitter syntax error nodes. This is not Dart analysis or execution.

### Operational capture follow-up — local debug journal (2026-11-05)

**Incident evidence:** none has been collected from the affected device. The last completed stage and the actual awaited operation for the screenshot remain **unknown**. This work provides a capture mechanism; it does not demonstrate that the incident is fixed or that the proposed journal works on the device. No OCR/boundary algorithm or timeout was added or changed in this follow-up.

#### Mechanism, scope and limitations

`lib/application/import_trace.dart` retains a random per-import ID through its Dart Zone. `ImportTrace.stage` and `syncStage` record start and terminal outcomes with operation IDs and monotonic elapsed times. The import runner records source/analysis/save progress counts; `SmartIntake` additionally marks pairing, layout and apply, and `LocalImageEditor.open` distinguishes reading the preview source from its isolate decode. `project_service.dart` records picker-cache cleanup (whose errors remain nonfatal). Native operation events distinguish model session creation, inference, tensor creation/read/release, and enclosing model operations; OCR preprocessing and cancellable-isolate spawn/result/failure/cancel are also marked. Names are a fixed allowlist; no image pixels, OCR strings, filenames, document contents, paths or exception messages are included. Unrecognized names are redacted, and unrecognized exception classes are reduced to `Other`. Timestamps, random IDs, counters and timings are operational metadata and should still be handled as sensitive diagnostics.

`lib/application/import_trace_store.dart` enables the local JSONL journal **only in a debug build** explicitly compiled with `--dart-define=SCAN_ID_IMPORT_DIAGNOSTICS=true`. It writes one `import_<32-hex-task-id>.jsonl` per task inside `getApplicationSupportDirectory()/import_diagnostics/`; Android normally maps application support to the app's private `files` directory. No server or network transport is added. Storage is not automatically erased: remove only diagnostic files deliberately when no longer needed. The queue is limited to 256 events (plus a one-off drop marker), each task to 2048 records, and snapshots to 64 shown outstanding operations with a truncation flag; `journal_events_dropped` indicates incomplete evidence. Each emitted record includes event, phase, operation ID, elapsed time, measured duration when its matching terminal event was observed, timestamp, `last_started`, `last_completed`, pending observations, error category, late flag and counters where applicable. An open operation means **no terminal observation has been recorded**: it can be actively awaited, abandoned after timeout/cancel, or missing because journal writing lost data. It is not a native stack trace.

The journal is scheduled asynchronously and the import does not await disk; bounded encoding and one flush per record can still affect scheduling/I/O. **No performance benchmark has been run**, so negligible timing impact is not established. If the UI/Dart event loop blocks, the writer cannot advance its queued Dart continuations; if the process dies, storage fails, the path-provider channel stalls, or the queue overflows, the file can be absent or stop before the real blocking point. A successful write is not acknowledged back to the import. File-write failures are only noted through the VM diagnostic log; no result is claimed from a missing/partial file. Do not infer a hang from the final JSON line alone: inspect all unmatched operation IDs, `dropped_events`, `outstanding_truncated`, the task terminal event and the UTC time. Durations of unfinished operations are lower bounds at the last recorded observation; compare `observed_utc` with the phone's own UTC time when extracting. Clock adjustments can invalidate a wall-time comparison; completed-operation `duration_ms` uses monotonic task elapsed time.

The trace ID lives in the **parent Dart zone**, not inside platform plugins or the spawned isolate; isolate and ONNX events are recorded around dispatch/reply in that zone and correlate with the parent operation ID. A task ID is not transmitted into the native inference engine or the isolate payload, and `isolate_spawned`/`isolate_cancelled` only report Dart-side spawn/cancel observations, not OS-thread liveness or confirmed termination. Existing `Isolate.run` sites and platform channels do not all have inner markers. When a future is shared between tasks, the original creation event belongs to the task that initiated it; the enclosing operation event identifies a later waiter. These limits prevent claiming full end-to-end ID propagation or determining exact native blockage without a device trace/thread dump.

`import_completed` means the runner returned; it does not prove recognized content, dialog closure or a rendered image. `progress_update` records the emitted counter and phase, not a database commit. For the project-screen dialog, `dialog_close_requested`, `dialog_pop_returned`, `dialog_route_returned`, and `ui_state_applied` distinguish attempts, route return, and application state adoption. The editor path emits state adoption but uses no such modal dialog. `ui_state_applied` and route events may have `late=true` because they happen after runner termination; this flag alone does not mean a stale-result bug. No event asserts that a frame was actually displayed. A timeout, failure, cancellation, unresponsive native/main thread, blocked cleanup/save or unmounted screen can still prevent a terminal or route event. Static inspection alone cannot prove that **all** paths update the count and close the dialog, and no such guarantee is claimed.

#### Android Debug capture and local export (commands derived from repository)

The `scanid` flavor inherits `applicationId = "iq.scanid.scan_id"` and `MainActivity` from `android/app/build.gradle.kts` and `android/app/src/main/kotlin/iq/scanid/scan_id/MainActivity.kt`. The following POSIX-shell commands require a matching Flutter/Dart SDK (project declares Flutter `>=3.35.7` and Dart `>=3.9.0`), Android SDK/ADB, and an authorized Android device. This is a **debug** capture, not a release. A debug APK may fail to update an installed release signed with a different key. **Do not uninstall the existing app or clear its data** to work around a signing mismatch; preserve user projects and resolve the build/signature situation separately.

From the existing checkout containing these uncommitted changes:

```sh
flutter --version
adb devices -l
flutter pub get --enforce-lockfile
# If the pinned files are not already installed locally, these two scripts
# download public model weights and verify their pinned hashes; no ID images.
python3 tool/fetch_docaligner_model.py
python3 tool/fetch_ocr_models.py
flutter build apk --debug --flavor scanid --dart-define=SCAN_ID_IMPORT_DIAGNOSTICS=true
adb install -r build/app/outputs/flutter-apk/app-scanid-debug.apk
adb shell am start -n iq.scanid.scan_id/.MainActivity
```

Use exactly one authorized device with the commands above; if multiple devices are connected, add `-s DEVICE_SERIAL` to each `adb` command using the serial returned by `adb devices -l`. Reproduce with one **non-sensitive test image** if possible; let it remain at 0/1 if it stalls. Do not force-stop, clear application data or retry before extracting. In a separate shell, list and export the newest journal locally (the trace may need a moment to flush):

```sh
mkdir -p diagnostics
adb shell date -u
adb shell run-as iq.scanid.scan_id ls -lt files/import_diagnostics
TRACE_FILE="$(adb shell run-as iq.scanid.scan_id ls -t files/import_diagnostics | tr -d '\r' | head -n 1)"
case "$TRACE_FILE" in
  import_*.jsonl) adb exec-out run-as iq.scanid.scan_id cat "files/import_diagnostics/$TRACE_FILE" > diagnostics/import-trace.jsonl ;;
  *) echo 'No debug journal found; do not infer success or the blocked stage.' ;;
esac
```

`diagnostics/` is ignored by this repository's `.gitignore`; this command exports locally and sends nothing to a server. Check the task ID, last timestamp, counts, operation IDs and outstanding list in the JSONL. If the journal is absent, `run-as` reports non-debuggable, the support directory differs, or the last record predates the stall, record that failure rather than calling it evidence. `adb shell run-as iq.scanid.scan_id find files -type f -name 'import_*.jsonl'` can locate files within app-private `files`; review paths before copying. Do not capture a broad unfiltered logcat or send source images. For a suspected platform-thread/ONNX hang the safe journal only narrows the dispatch boundary; a separate device thread dump or plugin instrumentation is still necessary and must be reviewed for personal information before sharing.

#### Illustrative format only — not actual results

Synthetic success (omitted other events; these IDs, timestamps and durations are invented):

```json
{"task":"0123456789abcdef0123456789abcdef","event":"native_started","phase":"docquad-inference","operation":7,"elapsed_ms":120,"duration_ms":null,"last_started":"docquad-inference","last_completed":"docquad-session","outstanding":[{"operation":7,"event":"native_started","phase":"docquad-inference","elapsed_ms":0}]}
{"task":"0123456789abcdef0123456789abcdef","event":"native_completed","phase":"docquad-inference","operation":7,"elapsed_ms":310,"duration_ms":190,"last_started":"docquad-inference","last_completed":"docquad-inference","outstanding":[]}
{"task":"0123456789abcdef0123456789abcdef","event":"import_completed","elapsed_ms":800,"outstanding":[]}
{"task":"0123456789abcdef0123456789abcdef","event":"ui_state_applied","elapsed_ms":820,"late":true,"outstanding":[]}
```

Synthetic unresolved wait/failure (not a real device capture):

```json
{"task":"fedcba9876543210fedcba9876543210","event":"native_started","phase":"docquad-inference","operation":12,"elapsed_ms":300,"last_started":"docquad-inference","last_completed":"tensor-create","outstanding":[{"operation":12,"event":"native_started","phase":"docquad-inference","elapsed_ms":0}],"outstanding_truncated":false}
{"task":"fedcba9876543210fedcba9876543210","event":"recognition_timeout","operation":3,"elapsed_ms":120300,"last_started":"docquad-inference","last_completed":"tensor-create","outstanding":[{"operation":12,"event":"native_started","phase":"docquad-inference","elapsed_ms":120000}],"outstanding_truncated":false}
```

This hypothetical trace shows that the caller's existing recognition budget expired while a native call had no recorded completion; it does **not** prove the native call is executing, that the Android main thread is blocked, or that a later reply cannot occur.

#### Execution in this environment

* `dart format --output=none --set-exit-if-changed lib test`, `flutter analyze`, `flutter test`, `flutter build apk --flavor scanid --debug`, and `flutter build windows --debug` each exited 127 (`command not found`) in this turn. `dart`, `flutter`, `adb`, and Java are not in PATH; the earlier cached Flutter checkout is no longer present in this session snapshot. The prior turn's attempt to bootstrap matching Flutter 3.35.7 failed the Dart SDK download with TLS `SSL_ERROR_SYSCALL`. No Flutter SDK/dependency versions were changed. No Android/Windows build, device trace, real ONNX test, Flutter test, analyzer or formatter ran.
* `PYTHONPATH=/home/user/.cache/scanid-python python3 -m unittest discover -s test/tool -p 'test_*.py'`: 29 passed; `... -p '*_test.py'`: 19 passed (one simulated 403 warning). Initial run lacked Pillow/numpy. Installing the declared requirements initially reported a numpy hash mismatch; a separate `--no-cache-dir` install of the same pinned numpy version and the pinned Pillow version into the excluded external cache allowed the tests to run; no repository dependencies were changed. These tests do not validate Dart/native behavior.
* `git diff --check`, `tool/check_source.py`, `check_detector_retirement.py`, `check_workflow_permissions.py`, and `check_private_ci_checkout.py` passed. Tree-sitter Dart grammar inspected 40 changed/untracked Dart files; one existing test file was flagged at uses of contextual identifier `late` (also present at HEAD); this is not Dart analysis. Source inventory: 1062 declared Dart/Flutter tests, not executed. `test/application/import_trace_store_test.dart` was added for local journal pending-operation/redaction behavior but **was not run**.
* No runtime trace, device test or measurable performance result exists. No commit, push, merge or release was made. The acceptance criterion remains unmet until an affected-device capture identifies an actual pending operation or proves the task returned while the UI failed to update, followed by a real before/after regression.
