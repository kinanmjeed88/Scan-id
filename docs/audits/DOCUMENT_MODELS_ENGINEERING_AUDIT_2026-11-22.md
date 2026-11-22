# تدقيق هندسي لنماذج اكتشاف المستندات وقصّها وتصنيفها — Scan-id

**نوع العمل:** فحص وتحليل فقط. لم يُعدَّل أي ملف إنتاجي، ولم تُلمس أي أوزان، ولم يُغيَّر أي عتبة، ولم يُنفَّذ commit/push.
**الفرع:** `arena/f3dba97f-scan-id` · **الأساس:** `569f89a34a448013127eb0eca394a4fa17369218` (`searchidf`)
**التاريخ:** 2026-11-22

---

## 0. حدّ الأدلة: ما توفّر وما لم يتوفر (يُقرأ قبل أي رقم)

هذا التقرير لا يبني أي استنتاج على اسم نموذج أو على نجاح بناء. الجدول التالي يفصل صراحةً بين ما قِيس فعلياً وما تعذّر الوصول إليه:

| البند | الحالة | التفصيل |
|---|---|---|
| `scan-id-journeys-2026-11-22-1456.json` | **غير موجود — تعذّر الوصول** | لم يُعثر على الملف في شجرة العمل، ولا في أي من فروع `origin` الـ23 (فُحصت كلها عبر `api.github.com`)، ولا في `/home`، ولا `/tmp`، ولا داخل `مكتبتي برو.apk` أو `.zip`. البحث الأشمل أعاد صفر نتيجة. **لذلك لا يحتوي هذا التقرير على أي رقم استُخرج من ذلك الملف.** |
| القسم 9 من هذه المهمة (تحليل الرحلات الـ12) | **غير قابل للتنفيذ** | لا يمكن تحليل 12 رحلة لم تُقرأ. ما قُدِّم بدلاً منها: إعادة بناء مُدقَّقة لعقد السجل (`lib/domain/image_journey.dart:357-402`) ومسار توليده، بحيث تُطبَّق حرفياً على الملف متى توفّر. |
| أوزان DocQuadNet | **متوفرة ومُتحقَّق منها** | `assets/models/docquadnet256_trained_opset17.ort` · 13,404,960 بايت · `sha256=f0f2f52d7d79ff02d346c8f9d0c9e903407366aeea1747cdcff160c401e3e72a`. شُغِّل فعلياً في هذه الجلسة. |
| أوزان DocAligner (83 MB) | **غائبة — تعذّر التنزيل** | `.gitignore:24`. مُعرَّف الأسطورة صحيح ومطابق للمنشور upstream (تحقق أدناه)، لكن `release-assets.githubusercontent.com` و`raw.githubusercontent.com` و`pub.dev` محجوبة في هذه البيئة. **لم يُشغَّل هذا النموذج ولا مرة.** |
| أوزان PP-OCRv5 (det + rec) | **غائبة — تعذّر التنزيل** | `.gitignore:27-29`. كذلك لم تُشغَّل. |
| بيانات التدريب / سكربتات التدريب | **غير موجودة في المستودع** | لا يوجد أي سكربت أو مجموعة بيانات. `local-data/` مستثنى (`.gitignore:25`) و`/Mostmskat/` مستثنى (`.gitignore:37`) وكلاهما غير موجود في هذه الشجرة. |
| `مكتبتي برو.apk` / `.zip` المشحونان في الجذر | **غير صالحين كدليل نشر** | كلاهما مقتطع: 140 مدخلاً، بلا `lib/` وبلا `flutter_assets` وبلا أي `.onnx/.ort`. لا يصلح أي منهما لإثبات ما إذا كانت الأوزان تُشحن في إصدار حقيقي. |

> **قاعدة معلنة:** كل رقم في هذا التقرير مسبوق بوسيلته. كل ما هو استنتاج تنظيري مُعلَّم بكلمة **«تنظيري»**. كل ما هو غير قابل للتحقق مُعلَّم بـ**«غير متحقق»**.

---

## 1. الملخص التنفيذي

1. **الأسماء في السجل ليست ثلاثة نماذج منفصلة، بل نموذجان عصبيان + مصنِّف قواعد نصي + كاشف كلاسيكي.** `DocQuadNet` و`DocAligner` هما الشبكتان الوحيدتان (`lib/imaging/docquad_model.dart:101`، `lib/imaging/docaligner_model.dart:29`). أما «Document Classification / Recognition» فهو **ليس نموذجاً مرئياً على الإطلاق**: لا يوجد أي مصنِّف صور في المستودع، والتصنيف يتم بقاموس كلمات مفتاحية على نص OCR (`lib/domain/recognition_classifier.dart:81-217`).
2. **السبب الأول المرشّح لفشل الكشف هو نسبة أبعاد الإطار، وليس الوزن — وهو عيب في المعالجة المسبقة قابل للإثبات.** يُمرَّر الإطار دائماً كـ letterbox إلى 256×256 يحفظ النسبة (`docquad_model.dart:267-301`)، بينما كل أدلة المستودع نفسها تُظهر أن النموذج ينهار على الإطارات الأفقية (1200×900: 0/6) ويزدهر على العمودية (900×1200: 6/6). أجريت تجربة إحباط (ablation) على الرسم البياني المشحون: تحويل نفس الإطارات إلى 256×256 بالسحق يقلب النتيجة ويخفض خطأ الزوايا بمقدار 5.3×. **هذا إصلاح برمجي صرف، لا تدريب.**
3. **تسلسل القرار يمنع القص التلقائي بنيوياً في المسارين.** في المسار متعدد المناطق، اقتراحات «المقسّم» تحمل `producer: segmenter` (`document_segmenter.dart:52`) وتصل دائماً إلى `verifyBoundary` بثقة `null`، فتُضاف `lowModelConfidence` حتماً (`boundary_decision.dart:676-689`) → القص التلقائي مستحيل رياضياً على هذا المسار. وفي المسار المفرد، `DocAligner` يُنفَّذ دائماً (`boundary_proposal_cascade.dart:47-57`) وعتبة قبوله ≥ 0.55 من ذروة heatmap غير معايرة، ومن أعلى ذروة ممكنة في إطار letterbox 0.984 فقط إذا كانت الزاوية داخل مربع 256×256 — أي أنه **لا يستطيع رفع «عدم التأييد» عن إطار أفقي إطلاقاً**.
4. **بنية التصنيف لا تستطيع التمييز بين الوجه الأمامي والخلفي، ولا تعرف فئة `unknown` صريحة كقرار نموذج.** عدد الفئات 5 أنواع مستندات فقط، ولا يوجد أي مفهوم «وجه» في المصنِّف. الاقتران الأمامي/الخلفي مُصنَّف سلفاً كـ `ambiguous` دائماً (`lib/domain/side_pairing.dart`، سقف صلب بلا دليل معرّف).
5. **`sizeConfirmed` تبقى `false` لأسباب سياسية، لا لأسباب تقنية.** نوعان فقط لهما مقاس «موثَّق» (`unifiedNationalId`, `passport`)، والباقي إمّا تقديري أو مفقود (`document_kind.dart:249-302`). ومقاس IHEC reference (`rationCard = 52×287`) و`residenceCard = 92.4×62.8` هما **أرقام بلا مصدر**، معترف بذلك في الكود نفسه.
6. **لا توجد دورة حياة لنماذج لا تملك بيانات، وأخطر ما في المستودع قرار منشور يمنع نشر الوزن.** `docs/reports/DOCALIGNER_INTEGRATION_2026-10-30.md` يقول حرفياً إن إعادة توزيع وزن DocAligner **غير مُبرَّأة قانونياً**، بينما `pubspec.yaml:44` يشحنه ويُضمّن في كل بناء. هذا تناقض حاكم يجب حسمه قبل أي عمل تقني.

**الحكم النهائي باختصار:** المشكلة الأولى ليست في الأوزان. هي في (أ) إطار الإدخال، (ب) عتبة acceptance غير القابلة للوصول في تسلسل القرار، (ج) غياب مصنِّف نوع/وجه حقيقي، (د) غياب بيانات مرجعية. إعادة التدريب الآن ستكون هدراً.

---

## 2. المعمارية الفعلية وتدفّق البيانات

### 2.1 المخطّط الفعلي (من الكود، لا من التوثيق)

```
اختيار الصورة
  └─ main.dart:164-177  (file picker) / CameraCapture
       ▼
الاستيراد والنسخ — local_asset_repository.dart
  · readBoundedImage: سقف 20 MiB            (image_reader.dart:6-16)
  · prepareImage / decodeForProcessing:
      - inspectImageHeader قبل تخصيص البكسلات    (prepare_image.dart:28-33)
      - سقف 16 MP                              (image_limits.dart:3)
      - JPEG > 16MP → LargeJpegPlan → 4 MP     (large_jpeg_plan.dart:29-66)
      - EXIF يُطبَّق مرة واحدة عبر bakeOrientation (prepare_image.dart:59-65)
      - working.png + thumb.jpg (320px)        (prepare_image.dart:116-144)
       ▼
فتح المعاينة — LocalImageEditor.open
  · readBoundedImage(processingInputPath)      (local_image_editor.dart:87-89)
  · _openSourceIsolated: خفض الضلع الأطول إلى 1200px  (local_image_editor.dart:356-375)
    ⇒ EditorSource(preview=PNG≤1200, width, height)
       ▼
RecognitionPipeline.analyze                     (recognition_pipeline.dart:306+)
  ├─ segment(previewBytes)  ← 1200px مقيَّد       (document_segmenter.dart)
  │    · إن أنتج مقسّم المناطق ≥1 مرشّح:
  │        لكل مرشّح → _analyzeDetection(producer: segmenter|learnedModel)
  │        ولا يُنادى اقتراح النماذج العصبية إطلاقاً  ◄── نقطة حرجة
  │    · إن أنتج 0 مرشّح → المسار المفرد أدناه
  └─ المسار المفرد:
       suggestProposal(previewBytes)            (recognition_pipeline.dart:427-439)
         └─ BoundaryProposalCascade              (boundary_proposal_cascade.dart:19)
              ├─ primary   = DocQuadNet256       (main.dart:119)
              ├─ secondary = DocAlignerFastViT   (main.dart:120)  ← يعمل دائماً
              └─ ثم: LocalImageEditor._measureBoundaryCandidatesInIsolate
                     = measureBoundaryCandidates (boundary_arbitration.dart:106)
                       ├─ detectDocumentCornersScored  (كاشف كلاسيكي)
                       └─ arbitrateBoundaryProposal     (سطر 456)
       ▼
verifyBoundary → BoundaryDecision{accepted|needsReview|rejected}
  · assessQuad (geometry فقط)                  (quad_assessment.dart:74)
  · + touchesFrameEdge / lowModelConfidence / modelDisagreement / …
       ▼
OCR (اختياري، على القصّ المصرَّح أو المنطقة المقاسة)
  · prepareOcrRegion → warp بـ1200 أو crop محوري  (ocr_region.dart:36-67)
  · PP-OCRv5 det(960) + rec عربي                (ocr_tensor.dart:31,44)
       ▼
classifyDocument (قواعد، لا شبكة)              (recognition_classifier.dart:81)
       ▼
_confirmedCatalogSize → sizeForWarp            (smart_recognition.dart:3864)
       ▼
arrangeDocuments → A4                          (arrangement.dart:139)
```

### 2.2 إجابات الأسئلة العشرة المطلوبة

| السؤال | الجواب المُثبت | الدليل |
|---|---|---|
| نقطة دخول معالجة الصور | `LocalImageEditor.open` ← `_openSourceIsolated` | `local_image_editor.dart:92-104, 356-375` |
| دقة الصورة الأصلية مقابل نسخة العمل | الأصل يبقى كما هو (ADR-003). نسخة العمل ≤4 MP، والمعاينة المستخدمة للتحليل ≤1200px على الضلع الأطول | `image_limits.dart:14,19`; `local_image_editor.dart:362-370` |
| هل يُغيَّر الحجم/يُضغط قبل النموذج؟ | نعم مرتين: أصلي→working (≤4MP PNG)، ثم working→preview (≤1200 PNG) | `prepare_image.dart:121`; `local_image_editor.dart:371` |
| أي نسخة تُستخدم؟ | **المعاينة ≤1200 فقط**. `PipelineImageInput.previewBytes` موثّق بذلك | `recognition_pipeline.dart:47-48` |
| EXIF والاتجاه | يُطبَّق مرة واحدة في `decodeForProcessing` عبر `bakeOrientation` بعد `normalizeChannels` | `prepare_image.dart:59-65`; مُغطّى بـ8 اتجاهات في `test/imaging/prepare_image_test.dart:42-92` |
| معالجة الإضاءة/التباين/الضوضاء | **لا شيء قبل النماذج.** `suggestAutoAdjustments` موجود لكنه يُستدعى من المحرر فقط، لا من مسار الاستيراد | استدعاءاته الثلاثة كلها في `project_service.dart` + `editor_controller.dart:1188` |
| أكثر من مسار للكشف؟ | **أربعة**: segmenter، cascade عصبي، كاشف كلاسيكي (تحكيم)، `_segmentEnclosedMultiCards` احتياطي | `document_segmenter.dart:338,415,430`; `boundary_arbitration.dart:106` |
| تتابع أم توازٍ؟ | النموذجان **متتابعان** (primary ثم secondary)، ثم التحكيم الكلاسيكي بعدهما. التوازي الوحيد على مستوى الصور في `recognition_worker.dart` | `boundary_proposal_cascade.dart:47-57`; `local_image_editor.dart:153-157` |
| هل التصنيف يعتمد على الأصل أم القص؟ | على **القص/المنطقة** (مع خيار توسيع القراءة)؛ إن لم يوجد أي منهما يُقرأ الإطار كاملاً | `recognition_pipeline.dart:740-807`; `ocr_region.dart:46-66` |

### 2.3 السلسلة الحاكمة (اكتشاف في أثناء التتبع)

```dart
// recognition_pipeline.dart:416
if (detections.isEmpty && unresolved.isEmpty) {
  ...
  if (suggestProposal != null) { prop = await suggestProposal!(input.previewBytes); }
```
النموذجان العصبيان **لا يُناديان إلا إذا أنتج المقسّم صفر مرشّح**. المرشّح الوحيد ذو الزوايا الصالحة يُلغي المسار العصبي كلياً (`document_segmenter.dart:409-428`). النتيجة: صور كثيرة تُحكم بقرار كلاسيكي/مقسّم لا يمكنه أبداً أن يُقبل تلقائياً، بينما النموذجان — رغم تشغيلهما في الكود — لا يُستشاران أصلاً. **هذا سبب بنيوي لـ«فشل اكتشاف الحدود» لا علاقة له بدقة أي شبكة.**

---

## 3. جرد النماذج والأوزان ومصادرها

| # | المكوّن | النوع الفعلي | الملف | المصدر | البصمة | الحالة |
|---|---|---|---|---|---|---|
| 1 | `DocQuadNet-256` | شبكة CNN كاملة الارتباط: مدخل 1×3×256×256، مخرجان `corner_heatmaps` 1×4×64×64 و`mask_logits` 1×1×64×64 | `assets/models/docquadnet256_trained_opset17.ort` | `egdels/makeacopy@de6279d` (مسجّل في `DOCUMENT_DETECTION_RETIREMENT_REPORT_2026-10-28.md:28`) | 13,404,960 B · `f0f2f52d…3e72a` (**قِيست هنا**) | ✅ حاضر، يعمل |
| 2 | `DocAligner 1.1.1 FastViT-SA24` | شبكة heatmap للزوايا (H-E-BiFPN)، مدخل 1×3×256×256، مخرج 1×4×H×W | `assets/models/docaligner_fastvit_sa24_7f9f5a89.onnx` | `DocsaidLab/DocAligner` release `1.1.1`, asset `626727748` | 83,084,930 B · `7f9f5a89…95bc` | ⛔ غائب (gitignored)، **لم يُشغَّل** |
| 3 | «Classification» | **ليس شبكة.** قاموس مجموعات مراسي نصية (5 أنواع) + حكم | `lib/domain/recognition_classifier.dart`, `lib/domain/ocr_evidence.dart:171-…` | — | `classifierVersion = 'explicit-evidence-7'` | ✅ منطق حاضر |
| 4 | PP-OCRv5 det + rec | شبكتان ONNX | `ppocrv5_mobile_det.onnx`, `ppocrv5_arabic_mobile_rec.onnx` | `PaddlePaddle/PP-OCRv5_mobile_det_onnx@e6f4fa85…`، `arabic_PP-OCRv5_mobile_rec_onnx@14aaedcd…` (`ocr_model_assets.dart:26-34`) | معرَّفتان بالبصمة في أداة الجلب | ⛔ غائبتان، **لم تُشغَّلا** |
| 5 | الكاشف الكلاسيكي | CV محلي: structure tensor + Hough + Otsu + refine | `lib/imaging/document_detector.dart` | داخل المستودع | — | ✅ حاضر |
| 6 | المقسّم الكلاسيكي | CV محلي: threshold + مكوّنات + بوابات | `lib/imaging/document_segmenter.dart` (`segmenterVersion='segment-1'`) | داخل المستودع | — | ✅ حاضر |

### 3.1 التحقق من واجهة DocQuadNet (تشغيل فعلي)

```
inputs:  [('input', [1, 3, 256, 256], 'tensor(float)')]
outputs: [('corner_heatmaps', [1, 4, 64, 64], 'tensor(float)'),
          ('mask_logits',      [1, 1, 64, 64], 'tensor(float)')]
custom_metadata: {}
operators: GlobalAveragePool(1) · HardSigmoid(6) · Conv(11) · Resize(13) · Mul(14) · FusedConv(com.microsoft,1)
```
- **عدد العمليات 6 فقط** (مُعاد قياسه هنا؛ مطابق لـ`tool/evidence/onnx_operator_inventory_results.json`).
- **لا توجد أي بيانات وصفية** (`custom_metadata` فارغة): لا نسخة تدريب، لا تاريخ، لا مجموعة بيانات. هذا يثبت أن «سجل تحديث الأوزان» غير موجود داخل الملف.

### 3.2 التحقق من هوية DocAligner (ميتاداتا، بلا وزن)

استُعلمت واجهة `api.github.com` (المضيف الوحيد المتاح من مجموعة GitHub):

| الحقل | قيمته في المستودع | قيمته المنشورة فعلياً | الحكم |
|---|---|---|---|
| asset_id | `626727748` (`fetch_docaligner_model.py:23`) | `626727748` | ✅ مطابق |
| bytes | `83,084,930` | `83,084,930` | ✅ مطابق |
| sha256 | `7f9f5a89…95bc` | `sha256:7f9f5a89…95bc` | ✅ مطابق |
| tag | `1.1.1` | `1.1.1` | ✅ مطابق |

**لكن** تنزيل الملف نفسه فشل: `SSL_ERROR_SYSCALL` على `release-assets.githubusercontent.com`. **لذلك أي ادعاء عن دقة DocAligner أو عن عقد إدخاله غير قابل للتحقق في هذه الجلسة.**

### 3.3 مصدر معالجة DocAligner — تحقق مستقل من الكود الأصلي

قُرئ `docaligner/heatmap_reg/infer.py` عند الوسم `1.1.1` (عبر `api.github.com/contents`):

```python
def preprocess(img, img_size_infer=None, do_center_crop=False, return_tensor=True):
    ...
    if do_center_crop:
        img = cb.centercrop(img)
        ...
        nh, nw = img.shape[0:2]
    if img_size_infer is not None:
        img = cb.imresize(img, size=img_size_infer)      # (256, 256) — سحق مباشر
    ...
def postprocess(preds, imgs_size, heatmap_threshold=0.3):
    for ii, pred in enumerate(preds[0]):
        pred = cb.imresize(pred, size=imgs_size)          # خرائط → حجم المصدر
        pred[pred < heatmap_threshold] = 0
        ...
        point = _get_point_with_max_area(pred)
```

**نتيجتان موثَّقتان:**
1. `img_size_infer = (256, 256)` مع `cb.imresize` بلا `do_center_crop` = **سحق بلا حفظ نسبة** — يطابق `lib/imaging/docaligner_model.dart:227-246` بالضبط. ✅
2. `cb.imresize(pred, size=imgs_size)` = **تحجيم خطّي للمخرجات إلى أبعاد المصدر ثم العتبة**؛ البديل في التطبيق `centroid.x / width` (سطر 219) = **عتبة أولاً على خريطة المصدر ثم centroid في فضاء الخريطة**. هذان **ليسا متماثلين**: مساحة المكوّن بعد التحجيم الخطّي تختلف عن مساحته قبلها، و«أكبر مكوّن» قد يتغيّر. **تنظيري** أن هذا يزيح الزوايا بمقدار جزء من خلية heatmap؛ لم يُقس لأن الوزن غائب. **غير متحقق رقمياً.**

---

## 4. تحليل `DocQuadNet`

### 4.1 الوقائع

| البند | القيمة | الدليل |
|---|---|---|
| موقع التنفيذ | `class DocQuadNet256 implements BoundaryProposalModel` | `docquad_model.dart:101` |
| البنية | مدخل 256²، مخرجات 64² (4 قنوات + قناع) — **رأس رقيق** على عمود CNN | §3.1 |
| صيغة الأوزان | ORT FlatBuffer (لا ONNX) | التحقق: `onnx.load` يفشل بـ«Wire format was corrupt» بينما `OrtFormatModelProcessor` يقرأه |
| التحميل | `createSessionFromAsset` + `intraOpNumThreads: 2`، مرة واحدة عبر `RetirableResource` | `docquad_model.dart:111-121` |
| أبعاد الإدخال | 256×256 letterbox **بحفظ النسبة** وحشو أسود | `docquad_model.dart:267-301` |
| التطبيع | RGB / 255، CHW، بلا mean/std | `docquad_model.dart:295-297` |
| الاستدلال | CPU (لا NNAPI/XNNPACK مذكور) | `OrtSessionOptions(intraOpNumThreads: 2)` |
| تحويل الإحداثيات | `(x256 − offset)/scale ÷ (frame−1)` + التقاط تجاوز 1e-9 | `docquad_model.dart:47-83` |
| نوع المخرج | **4 نقاط زوايا مفردة** (argmax لكل قناة) — لا bbox ولا quad كامل | `_peak`, سطر 307-330 |
| حساب الثقة | `IoU(المضلع الرباعي من الذروات, القناع>0) × min(p₁..p₄)` | `docquad_model.dart:203-209` |
| عتبة القبول | `_minimumReviewEvidence = 0.05` (إبقاء/إسقاط)، و`0.55` للقبول في التسلسل | سطر 108، `acceptance_policy.dart:4` |
| fallback | إرجاع `null` → التحكيم الكلاسيكي | سطر 210-212 |
| الأداء | p50 ≈ 27–28 ms، ذروة RSS +48 MiB، بلا تسرّب على 100 صورة | `tool/evidence/inference_performance_results.json` (**مقيس بـPython**، لا يشمل قناة platform ولا ART) |

### 4.2 الأجوبة على الأسئلة السبعة الحرجة

| # | السؤال | الجواب | الدليل |
|---|---|---|---|
| 1 | هل ترتيب الزوايا ثابت وصحيح؟ | **مفترض لا مُتحقَّق**. الترتيب يأتي من ترتيب قنوات الشبكة حصراً. اختبار `docquad_corners keep the model order` يستخدم **3 نقاط** ويؤكد فقط «أصغر من» — لا يثبت TL/TR/BR/BL ولا الترتيب الدوري | `test/imaging/docquad_coordinate_test.dart:328-341` |
| 2 | هل يمكن أن تنقلب/تتكرر الزوايا؟ | **نعم نظرياً**: `argmax` مستقل لكل قناة؛ قناتان قد تصلان إلى **نفس الخلية** فيتكرّر رأس. لا فحص تفرّد قبل `verifyBoundary` | `_peak`, سطر 307-330؛ `normalizedQuadIssue` يرفض المساحة المنهارة فقط (`geometry.dart:311`) |
| 3 | هل تنتج نقاطاً خارج الصورة؟ | **نعم، عن قصد، للذروات في حشوة الـletterbox** — تُرفض downstream بـ`outOfBounds` | `_snapToFrame` سطر 78-83 + تعليق 74-77 |
| 4 | هل يُرفض المستند الملامس للحافة رغم ظهور حافته؟ | **نعم**، بنطاق 1.6% (≈19px على 1200): أي زاوية عند `≤0.016` أو `≥0.984` ⇒ `touchesFrameEdge` | `boundary_decision.dart:664-672`؛ `boundary_arbitration.dart:84` |
| 5 | معالجة الميل والمنظور الشديد؟ | هندسياً: نعم (`PerspectiveCoefficients` + `assessQuad`). لكن `assessQuad` يرفض `horizontalRatio>2.5` أو `verticalRatio>2.5` أي المنظور العنيف جداً | `quad_assessment.dart:126-130` |
| 6 | هل يمكن أن يفشل كاشف ويقدّم الآخر اقتراحاً صحيحاً؟ | **تقنياً نعم، لكن النتيجة «غير مؤيدة» دائماً، والاقتراح المختار دائماً هو `first` (DocQuadNet)** — فتضيع فرصة DocAligner | `boundary_proposal_cascade.dart:97-102` |
| 7 | هل يوجد خلط بين ثقة النموذج وجودة الشكل؟ | **نعم بوضوح.** `geometryConfidence` منفصل، لكن **`detectionConfidence` يُسجَّل بقيمتين مختلفتين الدلالة**: 0.55 عند فشل التأييد مقابل قيمة النموذج عند النجاح، لنفس الصورة | `boundary_proposal_cascade.dart:84-88, 144` |
| 8 | هل تُوحَّد الإحداثيات قبل مقارنة النموذجين؟ | **نعم** — كلاهما مُطبَّع على نفس إطار المعاينة، والمقارنة عبر `_disagreementFraction` على قطر الإطار | `boundary_proposal_cascade.dart:211-229` |

### 4.3 اكتشاف جوهري: نسبة الأبعاد (الاختبار الحاسم)

هذا هو **العيب الوحيد في هذا التدقيق الذي أثبتُه بتجربة قابلة للتكرار**، وهو عيب معالجة مسبقة لا وزن.

**الملاحظة الأولى (من أدلة المستودع نفسه):**

| شكل الإطار | يُبقي البوابة | وسيط evidence | وسيط أقصى خطأ زاوية |
|---|---:|---:|---:|
| 1200×900 | **0/6** | 0.026 | 210 px |
| 900×1200 | 6/6 | 0.914 | 12.9 px |
| 1200×1200 | 2/6 | 0.039 | 54.8 px |
| 1200×700 | 2/6 (تقرير) | — | — |
| 700×1200 | 6/6 | 0.913 | 13.9 px |
| 1200×380 | 1/6 | 0.022 | 616.9 px |

المصدر: إعادة حساب مباشرة على `tool/evidence/docquad_realistic_accuracy_results.json` (36 صفاً، 6 لكل شكل).

**الفرضية:** الحفظ النسبي يضع المستند الأفقي في شريط letterbox أفقي رقيق، فتنهار خرائط 64² عليه.

**التجربة (ablation):** أعدت إنتاج نفس المشاهد (نفس البذرة `20261118`، نفس مولّد `capture()` و`quad_for()` من `tool/evidence/docquad_realistic_accuracy.py:135-185`) وشغّلت الرسم البياني المشحون مرتين: مرة بـletterbox (الإنتاج)، ومرة بسحق مباشر إلى 256×256:

| شكل الإطار | letterbox: يُبقى / وسيط الخطأ | سحق: يُبقى / وسيط الخطأ | تحسّن الخطأ |
|---|---|---:|---:|
| 1200×900 | 0/6 · 210.2 px | **4/6** · **39.5 px** | **5.3×** |
| 900×1200 | 6/6 · 12.9 px | 3/6 · 53.9 px | 0.24× (أسوأ) |
| 1200×700 | 0/6 · 600.0 px | **4/6** · **54.7 px** | **11.0×** |
| 700×1200 | 6/6 · 13.9 px | 5/6 · 28.9 px | 0.48× (أسوأ) |
| 1200×1200 | 2/6 · 54.8 px | 2/6 · 54.8 px | متعادل (بالبناء) |
| 1200×380 | 1/6 · 616.9 px | 1/6 · 298.7 px | 2.1× |
| **المجموع** | **15/36** | **19/36** | — |

**القراءة الأمينة:**
- السحق **يُصلح الإطارات الأفقية إصلاحاً كبيراً (5–11×)** ويُضرّ العمودية بمقدار 2–4×.
- **ولهذا لا يجوز استبدال letterbox بالسحق.** الحل الصحيح هو **letterbox بالحشو المربوط على مربع** (أي تفعيل `do_center_crop` upstream) أو **اختبار الاتجاهين واختيار الأعلى evidence**.
- التجربة **اصطناعية بالكامل**؛ لا تُثبت سلوكاً على صور كاميرا حقيقية. لكنها تُثبت **سببية الكود**: الفارق ناتج عن دالة التحجيم وحدها، مع تثبيت الأوزان والإطار.

**الأثر على المستخدم:** كل صورة أفقية (وهي الحالة الغالبة عند تصوير بطاقة على طاولة بالهاتف أفقياً) تدخل النموذج في تشكيل ينهار عليه. وبما أن `_minimumReviewEvidence=0.05` يقتل الاقتراح قبل التسلسل، تتحول الصورة إلى المسار الكلاسيكي غير القابل للقبول التلقائي.

### 4.4 عتبة إضافية: نطاق الحافة «غير قابل للوصول» لا يقتصر على الحواف

مشتق حسابياً (مُتحقَّق بسكربت مستقل): أعلى قيمة كسر يمكن أن تنتجها خلية heatmap على إطار 1200×900 هي:

```
x ∈ [0.00782, 0.99302]      y ∈ [-0.15642, 1.15754]
```
- المحور الطويل (`x`) سقفه **0.99302 < 0.984** ⇒ **أي زاوية على الحافة اليمنى/اليسرى تُعلَّم `touchesFrameEdge` حتماً**، ولو كانت الحافة الحقيقية ظاهرة بالكامل. هذا يطابق ادعاء المستودع نفسه في `DOCQUAD_VERIFICATION_AND_PERFORMANCE_2026-11-18.md` (السؤال ٥).
- المحور القصير (`y`) يصل إلى **1.15754** ⇒ **لا يمكن رياضياً** أن تُعلَّم زاوية علوية/سفلية على الحافة كملامسة، حتى لو كانت البطاقة مقطوعة فعلاً — لأن حشوة الـletterbox تدفع الذروة خارج [0,1] فتُرفض بـ`outOfBounds` بدلاً من `touchesFrameEdge`.
- **الخلاصة:** البوابة **غير متماثلة بين المحورين**، وتُخطئ في الاتجاهين: رفضٌ زائد على المحور الطويل، وفسادُ تصنيف السبب على المحور القصير.

---

## 5. تحليل `DocAligner`

### 5.1 الوقائع

| البند | القيمة | الدليل |
|---|---|---|
| موقع التنفيذ | `class DocAlignerFastViT` | `docaligner_model.dart:29` |
| البنية | FastViT-SA24 + H-E-BiFPN، رأس heatmap 4 قنوات | `DOCALIGNER_INTEGRATION_2026-10-30.md` |
| الأوزان | 83,084,930 B · `7f9f5a89…` | مطابقة لـupstream (§3.2) |
| التحميل | `createSessionFromAsset`، threads=2، مرة واحدة | سطر 38-48 |
| تحقق الواجهة | يشترط مدخلاً واحداً ومخرجاً واحداً بالضبط | سطر 73-79 |
| المعالجة المسبقة | **سحق مباشر إلى 256²، BGR، /255** | سطر 227-246 |
| ما بعد المعالجة | عتبة 0.3 على خريطة المصدر + أكبر مكوّن 8-connectivity + centroid | سطر 197-308 |
| الثقة | `min` لأعلى قيمة في القنوات الأربع للتطبيع | سطر 131-162 |
| عتبة القبول | `automaticAcceptanceThreshold = 0.55` | سطر 163 |
| الاتجاه | heatmaps فقط (لا تصحيح منظور هنا) | — |
| المعالج | CPU | سطر 43 |

### 5.2 الفروق الجوهرية عن DocQuadNet (ليست نسختين من شيء واحد)

| الوجه | DocQuadNet | DocAligner |
|---|---|---|
| تحجيم الإدخال | letterbox بحفظ النسبة | سحق مباشر |
| ترتيب القنوات | RGB | BGR |
| مستخرج الذروة | argmax خام (خلية واحدة) | أكبر مكوّن متصل بعد عتبة 0.3 (centroid) |
| الثقة | `IoU(quad,mask) × min(p)` | `min(peak)` فقط — **بلا أي قياس هندسي** |
| مخرج القناع | نعم (`mask_logits`) — يُستخدم في الثقة | لا |
| عدد المخارج | 2 | 1 مشروط |
| سقف الخريطة | 64 ثابت | مقبول حتى 512 |

**عاقبة مهمة:** ثقة DocAligner = أعلى قيمة heatmap لا أكثر. ليست معايرة، ولا مرتبطة بأي تحقّق هندسي. اعتبارها شريكاً في عتبة 0.55 يعني أن **نموذجاً بثقة شكلية يمكنه وحده منع القبول التلقائي** — وهو ما يحدث فعلاً (انظر §12، RC-02).

### 5.3 الانحراف عن upstream

| الجانب | upstream `infer.py` | التطبيق | الأثر |
|---|---|---|---|
| تحجيم المدخل | `imresize((256,256))` بلا center-crop | مطابق | ✅ |
| تحجيم المخرج | **تحجيم خطّي إلى حجم المصدر ثم عتبة** | **عتبة على الخريطة ثم centroid ÷ (W,H)** | **تنظيري:** اختلاف في اختيار «أكبر مكوّن» وفي مساحته ⇒ إزاحة زاوية. `/width` بدل `/(width−1)` أيضاً انحراف داخلي ≤ 1 خلية. |
| ترتيب القنوات | تعليق README يحوّل RGB→BGR | مطابق | ✅ |
| عتبة heatmap | 0.3 | 0.3 | ✅ |

**حكم على DocAligner:** **لا يمكن الحكم على دقته** (الوزن غائب). يمكن الحكم على **دوره في القرار** وهو دور غير سليم: يدخل العتبة بـ`min(peak)` غير المعايرة بينما سلوكه الفعلي معلوم الأهمية في تحويل الصور إلى «غير مؤيدة».

---

## 6. تحليل نموذج التصنيف

### 6.1 الحقيقة العارية

> **لا يوجد في هذا المستودع أي مصنِّف صور أو نوع مستند.** الجملة مكتوبة في الكود نفسه: «The app can supply OCR keyword evidence, but **has no validated visual kind classifier**» — `lib/domain/recognition_classifier.dart:1-4`.

التصنيف الفعلي = **مطابقة قاموس عربية/إنجليزية** على نص OCR:

- 5 أنواع لها قواميس: `unifiedNationalId` (سطر 172)، `civilStatusId` (234)، `residenceCard` (249)، `rationCard` (283)، `passport` (297) — في `lib/domain/ocr_evidence.dart`.
- كل نوع يتطلب **مرساة (عنوان أو نمط بنيوي مثل MRZ) + مجموعة دعم غير متداخلة** على الأقل (`ocr_evidence.dart:114-121`).
- الفائز = أعلى درجة مصدر واحدة، والتعادل يُحسم بترتيب الـenum (`recognition_classifier.dart:110-129`).
- `conflictGap = 0.15`: تعارض إذا الفارق < 0.15 → `uncertain`.
- العتبة: `classificationAcceptance = 0.60` (`acceptance_policy.dart:6`).

### 6.2 الأجوبة على أسئلة المرحلة الثالثة

| السؤال | الجواب | الدليل |
|---|---|---|
| بنية النموذج ومصدره | **لا نموذج.** قواعد نصية. النسخة `explicit-evidence-7` | `recognition_classifier.dart:79` |
| ملفات الأوزان | **لا يوجد** | — |
| الأنواع المدعومة فعلياً | `unknown, unifiedNationalId, residenceCard, passport, rationCard, civilStatusId, other` — لكن **5 فقط لها قواميس**، و`other` بلا قاموس | `document_kind.dart:12-20`; `ocr_evidence.dart:171-297` |
| متعدد الفئات؟ | نعم لفظياً، لكن عملياً شبكة قرار واحدة بين 5 | — |
| **الوجه الأمامي/الخلفي؟** | **غير مدعوم إطلاقاً.** لا حقل نوع-وجه، ولا قاموس للظهر. `side_pairing.dart` يعتبر أي اقتران `ambiguous` دائماً لأن `identifierMatchScore = null` (لا OCR معرّفات) | `side_pairing.dart:1-11, 47-58` |
| فئة `Unknown`؟ | موجودة كقيمة، وتُفرَض عند غياب الدليل (`R4`) — لكنها **ليست مخرج مصنِّف** بل حالة «لا دليل» | `recognition_classifier.dart:140-150` |
| على الصورة كاملة أم القص؟ | على **القص المصرَّح**، أو المنطقة المقاسة، أو الإطار كاملاً كملاذ أخير. ومع «توسيع القراءة» قد تُقرأ منطقة أوسع من الاقتراح | `recognition_pipeline.dart:740-807` |
| أبعاد الإدخال والتطبيع | **لا ينطبق** (نص). لكن OCR يُغذّى صورة بـ1200 أو أقل، وdetector بـ960 | `ocr_region.dart:53`; `ocr_tensor.dart:31` |
| حساب الثقة | درجة دليل نصية = دالة مجموعات مطابقة، **ليست معايرة** | `ocr_evidence.dart:85-112` |
| الفئات المتشابهة | `conflictGap` 0.15 → `uncertain`. لا مصفوفة التباس، لا قياس | `recognition_routing.dart:46` |
| OCR وعلاقته | OCR هو **المصدر الوحيد** للتصنيف. والمصنِّف هو **المصدر الوحيد** لـ`DocumentKind` | `recognition_classifier.dart:93-108` |
| معالجة منفصلة للنوع والوجه | **لا** | — |

### 6.3 «نجاح التصنيف مع فشل القص» — التفسير البنيوي (وهذا يفسّر ثلاث صور من قائمتك)

هذا سلوك **مقصود وموثَّق**، لا خطأ:

```dart
// recognition_pipeline.dart:745-749
} else if (assessment?.acceptable == true && corners != null) {
  // A geometrically valid proposal may provide OCR evidence even when
  // boundary policy still requires review. It never authorizes a crop...
  ocrCorners = corners;
```

فإذا كان الاقتراح **صالحاً هندسياً** لكن مرفوضاً سياسياً (منخفض الثقة، ملامس للحافة، غير مؤيد)، **يُقرأ النص من داخله** ويُصنَّف، بينما يبقى القص في المراجعة. لذلك من **المتوقع تماماً** أن ترى «نوعاً صحيحاً + قصاً غير معتمد» في نفس الصورة.

**وبالمقابل:** إذا أشار مُعرِّف السجل (`detectionTrace`) إلى `review=modelNotCorroborated` أو `review=lowModelConfidence` مع `classification` صحيح، فهذا **دليل مباشر على أن المستند كان مرئياً وقابلاً للقراءة، وأن الفشل في طبقة القرار لا في طبقة الرؤية.** هذه هي القراءة الصحيحة للصور الثلاث `images (54)`, `images (45)(1)`, `images (16)` **بشرط** تأكيدها من ملف JSON الفعلي — وهو غير متوفر (§0).

### 6.4 فحص «هل المشكلة من المعالجة السابقة لا من الأوزان؟»

| الاحتمال | الحكم | الدليل |
|---|---|---|
| قصّ غير صحيح | **ممكن جداً** — ينطبق على كل حالة فشل حدود | §4.3 |
| اتجاه صورة خاطئ | **مُغطّى جيداً** للـEXIF (8 اتجاهات مُختبَرة)، لكن **دوران 90° داخل البكسلات بلا وسم EXIF غير مُعالَج** — ويوجد precedent موثّق في العينة المحلية (`LOCAL_REFERENCE_DATASET_REPORT_2026-10-26.md:37`) | `prepare_image.dart:59-65`; `quad_assessment.dart:185-210` («0° مقابل 180° غير قابل للحسم») |
| دقة منخفضة | **ممكن**: العميل 1200px ثم النموذج 256px ⇒ البطاقة قد تشغل 150–250px فقط | `image_limits.dart:19` |
| تطبيع لوني غير مطابق | **لا دليل على انحراف**؛ RGB/255 مطابق للعقد لـDocQuadNet | `docquad_model.dart:295-297` |
| اختلاف نسبة إدخال | **مُثبَت كسبب رئيسي** | §4.3 |
| تمرير نسخة غير مناسبة | **مُثبَت**: المعاينة ≤1200 هي الوحيدة المُمرَّرة، لا الأصل | `recognition_pipeline.dart:47-48` |

**لا يعني ارتفاع الثقة صحة التصنيف:** الثقة قائمة على مجموعات كلمات مطابقة، ويمكن أن تبلغ 0.60–1.0 بنص واحد مطابق لمجموعة عنوان. لا توجد مصفوفة التباس ولا قياس precision/recall، ولا طريقة لمعايرة هذا الرقم. **الرقم مقياس دليل، لا احتمال صحة.**

---

## 7. تحليل خوارزمية القص والمنظور

| البند | التنفيذ | الحكم | الدليل |
|---|---|---|---|
| Perspective Transform | `PerspectiveCoefficients` تحلّ homography من المربع الوحدوي إلى الرباعي، ثم `warpPerspective` يعيّن عكسياً بدقة sub-pixel مع alpha مُسبق الضرب | **سليم عددياً**: خطأ إعادة إسقاط ≤ 1.8e-13 px على 9 مشاهد | `perspective.dart:13-33, 60-140`; `tool/evidence/docquad_crop_quality_results.json` → `geometry_only` |
| حساب العرض/الارتفاع | متوسط كل زوج أضلاع متقابلة، **+1** | سليم، ويحفظ نسبة القياس | `crop_draft.dart:80-96` |
| ترتيب النقاط الأربع | لا إعادة ترتيب في مسار القبول؛ `normalizedQuadIssue` يشترط تحدّباً ودوراناً متسقاً | **مقبول لكن هشّ:** لا يوجد توحيد ترتيب دوري قبل `verifyBoundary`، فتبديل قناتين يُنتج مضلعاً متقاطعاً يُرفض بـ`notConvex` بدل تصحيحه | `geometry.dart:294-318` |
| الزوايا غير الصالحة | تُرفض بـ9 أكواد (`QuadRejection`) | ✅ | `quad_assessment.dart:16-26, 84-96` |
| منع النتائج الفارغة/المشوّهة | `tooSmall` (<2% مساحة)، `degenerateEdges` (<4px)، `implausibleAspect` (>12) | ✅ | `quad_assessment.dart:114-136` |
| التحقق من أبعاد القص | `withinImageBudget` على الطلب | ✅ | `geometry.dart:416-419` |
| **العلاقة بين النوع والمقاس المرجعي** | `sizeForWarp` يشترط: مقاس موثَّق + قص مصحَّح + تطابق نسبة ضمن `0.04` | **⚠ عيب حاسم:** القص المصحَّح يأخذ **نسبة القياس**، فشرط التطابق يُقارن النسبة المقيسة بنسبة الكتالوج — **استدلال دائري جزئي**: إن كان القص نفسه مشوَّهاً بنفس الخطأ، يمرّ. والأخطر: تشويه الاقتراح يجعل `sizeConfirmed=false` دائماً | `document_kind.dart:403-417`; `boundary_decision.dart:458-471` |
| إصلاح الحافة | `_snapToFrame` بتسامح 1e-9 فقط | ✅ (مُقاس: 703/703 حالات مُنقذة، 747/747 خارجية مرفوضة) | `coordinate_correction_audit_results.json` |

### 7.1 «لماذا لا يُثبَّت المقاس بعد نجاح التصنيف والقص؟»

**سلسلة الشروط الأربعة، وكلها يجب أن تتحقّق:**

```dart
// smart_recognition.dart:3864-3881
bool knownKind = options?.assertsKind == true
              || qualifiesForAutomaticPlacement(classification, thresholds: thresholds);
if (!knownKind || !warped || detection.cropAuthorization == null) return null;
return catalog.sizeForWarp(kind, measuredAspect: ..., landscape: ...);
```
و`sizeForWarp` تشترط بدورها:
```dart
!documentSizeRecordFor(kind).mayBeConfirmedAutomatically   // documented فقط
|| (measuredAspect / preset.aspect - 1).abs() > shapeTolerance   // ≤ 0.04
```
**النتيجة العملية:** لتثبيت المقاس تلقائياً يجب أن تجتمع: (١) نوع واحد فريد بثقة ≥0.60 من قاموس نصي، (٢) قصّ مصرَّح، (٣) نوع له مقاس **موثَّق**، (٤) تطابق نسبة ≤4%. وأي إخلال بواحد يوقف كل شيء.

**وهذا ليس عيباً بحد ذاته — العيب أن نصف الأنواع لا تملك مقاساً موثَّقاً أصلاً:**

| النوع | المقاس | المصدر | `mayBeConfirmedAutomatically` |
|---|---|---|---|
| `unifiedNationalId` | 85.6 × 53.98 | ISO/IEC 7810 ID-1 | ✅ نعم |
| `passport` | 125 × 88 | ICAO Doc 9303 TD3 | ✅ نعم |
| `residenceCard` | **92.4 × 62.8** | **تقديري — لا مصدر** | ❌ لا |
| `rationCard` | **52 × 287** | **تقديري — لا مصدر** | ❌ لا |
| `civilStatusId` | **مفقود** | — | ❌ لا |
| `other` | مفقود | — | ❌ لا |

المصدر: `document_kind.dart:249-302`. الكود يقرّ حرفياً: «القيمة الحالية افتراضية قابلة للتعديل **ولا تُوصف بأنها رسمية**».

**وبالتالي:** مستند من نوع `residenceCard` أو `rationCard` — وهي الأنواع الغالبة في العينة المحلية (6 و0 على الترتيب، مع 8 بطاقات وطنية و1 جواز) — **لا يمكن أن يُثبَّت مقاسه آلياً ولو كان التصنيف والقص مثاليين**. هذا تفسير بنيوي كامل لغياب التثبيت.

### 7.2 «لماذا لم يوضع أي مستند على A4 في 12 رحلة؟»

لا يمكن الإجابة عن **الرحلات الاثنتي عشرة** بلا الملف. لكن الشرط الحاسم معروف ومُثبت:

```dart
// arrangement.dart:49-51
if (item.locked) return AutoLayoutStatus.locked;
if (!item.sizeConfirmed) return AutoLayoutStatus.sizeUnconfirmed;
```
`arrangeDocuments` **لا تضع شيئاً** ما لم يكن `sizeConfirmed == true`، وهي بدورها مشروطة بسلسلة §7.1. إذن:

- **إن كانت الـ12 صورة لم تُنتج نوعاً موثَّقاً + قصاً مقبولاً + تطابق نسبة ⇒ صفر وضع هو النتيجة الصحيحة رياضياً، لا خلل.**
- **إن كانت إحداها `unifiedNationalId` بثقة ≥0.60 وقصّ مقبول ومع ذلك لم توضع ⇒ خطأ حقيقي.** ولا يمكن التمييز بين الحالتين بلا السجل.

**هل المنع سياسة مقصودة أم اعتماد غير ضروري؟** الجواب: **سياسة مقصودة وصحيحة في مبدئها** (منع طبع مستند بمقاس مخمَّن: `document_kind.dart:81-83`، `arrangement.dart:26-30`)، **لكنها مكلفة جداً في التطبيق**: تعتمد على مقاسين موثَّقين فقط من ستة أنواع. هذه **فجوة بيانات لا فجوة كود**.

---

## 8. تحليل القياس والوضع (تفصيل)

| البند | الحالة | الدليل |
|---|---|---|
| مصدر المقاسات المؤقتة | `provisionalSize(width,height)` من بكسلات القص | `smart_recognition.dart:2919-2921` |
| العلاقة بين نوع المستند والمقاس | جدول واحد `documentSizeRecords` هو مصدر الحقيقة الوحيد | `document_kind.dart:249-306` |
| شروط تثبيت المقاس | أربعة شروط (§7.1) | `smart_recognition.dart:3864`; `document_kind.dart:403` |
| الوضع على A4 | `arrangeDocuments` تشترط `sizeConfirmed`، ولا تصغّر أبداً | `arrangement.dart:49-51, 76-90` |
| منع التصغير | موثَّق: «Documents are never scaled to fit» | `arrangement.dart:32-35` |
| إعادة الترتيب اللاحق | عنصر موضوع لا يتغيّر مقاسه (يبقى كخاصية تخطيط) | `smart_recognition.dart:2994-3050` |

**ملاحظة على `rationCard = 52×287`:** نسبة 5.52:1. `maxPlausibleRegionAspect = 8.0` يسمح بها، لكن `assessQuad` يرفض أي نسبة مقيسة > 12. أي قصّ صحيح لبطاقة تموينية سيكون 5.5:1 خارج نطاق `shapeTolerance` مع أي تشويه بسيط. **تنظيري:** هذا النوع عملياً غير قابل للتثبيت الآلي حتى لو صار مقاسه موثَّقاً.

---

## 9. تحليل الرحلات الاثنتي عشرة

### 9.1 الحالة: **غير قابل للتنفيذ**

`scan-id-journeys-2026-11-22-1456.json` **غير موجود** (§0). لا أستطيع، ولن أختلق، أي جدول أرقام لـ:

`IMG_20261118_190949.jpg`, `IMG_20261118_190822.jpg`, `images (54).jpeg`, `images (45)(1).jpeg`, `images (16).jpeg`, `images (36).jpeg`, `IMG_20261118_190910.jpg`, `images (44).jpeg`, `images (39)(1).jpeg`, `IMG_20261113_115947.jpg`, `images.jpeg`.

**ملاحظة على الأسماء:** الاسم `IMG_20261118_1909xx.jpg` يطابق نمط كاميرا هاتف (تاريخ 18-11-2026)، بينما `images (NN).jpeg` يطابق نمط تنزيل/مشاركة. **تنظيري** أن المجموعتين تختلفان في المصدر والدقة وزاوية الالتقاط — وهذا بذاته قد يفسّر فرقاً منهجياً بين «فشل الكشف» و«نجاح القص»، لكنه **غير مُثبت**.

### 9.2 ما يمكن تقديمه بدلاً منه: نموذج الجدول جاهز للتعبئة

عند توفّر الملف، تُملأ الأعمدة التالية حرفياً من حقول السجل. لا حقل منها يحتاج استنتاجاً:

| العمود المطلوب | مصدره الدقيق في JSON | الشكل |
|---|---|---|
| الاسم الفعلي | `journeys[].image` | نص |
| أبعاد الصورة | `steps[stage=copy].fields.copiedWidth/copiedHeight` (بكسل النسخة) — **لا الأصل** | `{int,int}` |
| DocQuadNet: النتيجة | `steps[stage=detection].fields.docquadnet_outcome` | `proposal\|noQuad\|geometryRejected\|failed` |
| DocQuadNet: الثقة | `…fields.docquadnet_confidence` | 4 منازل |
| DocAligner: النتيجة/الثقة | `…fields.docaligner_outcome` / `.docaligner_confidence` | كذلك |
| اختلاف النموذجين | `…fields.disagreement` | كسر من القطر |
| جودة الهندسة | `…fields.geometry` | 0..1 (من `assessQuad`) |
| المساحة | `…fields.area` | كسر |
| نسبة الحدود | `…fields.aspect` | 4 منازل |
| نسبة الكتالوج | `…fields.catalogAspect` + `catalogShape` | `match\|mismatch` |
| قرار الكشف | `steps[stage=detection].outcome` + `fields.accepted` | `passed\|review` |
| سبب الرفض | `…fields.review_1..n` (أكواد enum) + `detail` (جُمل عربية) | `lowModelConfidence` … |
| القص | `steps[stage=crop].outcome` + `fields.crop` (`perspective-warp`) أو `outputWidth/Height` | — |
| التصنيف | `steps[stage=recognition].fields` | نوع + ثقة |
| القياس | `steps[stage=sizing].fields.sizeConfirmed` | bool |
| الوضع | `steps[stage=placement].outcome` | — |

**دليل توفر هذه الحقول:** `lib/application/image_journey_report.dart:4134-4176` (بناء `detectionTrace`)، `:499-572` (تفكيكه إلى حقول)، و`:613-722` (خطوة القص)، و`:836-956` (خطوة القياس).

### 9.3 كيف ستُقرأ النتائج عند التعبئة (شجرة حسم جاهزة، بلا تخمين)

```
إن كان crop=perspective-warp  ⇒ القص نجح. أي فشل تصنيف بعدها هو فشل تعرّف، لا فشل كشف.
إن كان crop غائباً + detection.review_*=lowModelConfidence/modelNotCorroborated
    ⇒ فشل شروط القبول لا فشل النموذج. والدليل: هل docquadnet_outcome=proposal؟
        ├─ نعم + الثقة < 0.55 ⇒ عتبة §12/RC-02
        ├─ نعم + الثقة ≥ 0.55 + review_*=modelNotCorroborated
        │    ⇒ دليل مباشر على RC-02 (وثيقة واحدة لا تكفي لتفعيل القبول)
        └─ noQuad + حشوة letterbox ⇒ §4.3 / RC-01
إن كان review_*=touchesFrameEdge + الزوايا على المحور الطويل ⇒ RC-03 (إنذار كاذب بنيوي)
إن كان classification صحيحاً + crop غائباً ⇒ سلوك مقصود (§6.3)، وفشل الإنتاجية في القرار لا في الرؤية
إن كان sizing.sizeConfirmed=false + النوع residenceCard/rationCard ⇒ فجوة بيانات (§7.1)
```

**ميزة هذا النموذج أنه لا يتطلب الملف للحكم على شجرة الحسم نفسها** — الشجرة مشتقة من الكود، والملف يُستخدم فقط لتعبئة الأوراق.

---

## 10. الأسباب الجذرية مرتبة حسب الخطورة والأثر

### RC-01 — معالجة مسبقة بنسبة الأبعاد تُسقط النموذج على الإطارات الأفقية 🔴 **حرجة**

- **المشكلة:** يُسحق الإطار دائماً إلى 256×256 مع حفظ النسبة، فتصبح البطاقة في صورة أفقية شريطاً رقيقاً في حشوة سوداء.
- **الدليل:** على الرسم البياني المشحون نفسه: 0/6 إطارات 1200×900، 0/6 إطارات 1200×700 مقابل 6/6 لـ900×1200. وبتجربة الإحباط: السحق يرفع النجاح إلى 4/6 ويخفض الخطأ 5.3×–11×.
- **الملف والأسطر:** `lib/imaging/docquad_model.dart:267-301` (`_letterbox`)، والسطر الحاسم `math.min(inputWidth/source.width, inputHeight/source.height)`.
- **السبب الجذري:** اختيار letterbox بلا تحقق من أن النموذج دُرِّب عليه لهذه النسب. النموذج أُعدّ لمستند يشغل الإطار (إجماع مجموعات UVDoc/SmartDoc)، لا لبطاقة صغيرة وسط مكتب.
- **الأثر على المستخدم:** كل صورة أفقية = لا اقتراح = لا قصّ.
- **الحل المقترح:** لا تستبدل letterbox بالسحق. اختبر **نمطي التحجيم واختر الأعلى evidence** (كلفة +27ms)، أو حشو مربّط (center-crop 256² region) كما يفعل upstream DocAligner.
- **هل يتطلب تدريباً؟** ❌ **لا. إصلاح برمجي صرف.**
- **الاختبار المُثبت:** `test` يُشغّل الرسم البياني على إطار أفقي معروف ويؤكد أن `evidence ≥ 0.05` مع استراتيجية التحجيم الجديدة بينما يفشل مع الحالية.

### RC-02 — عتبة قبول لا يمكن الوصول إليها بنيوياً في التسلسل 🔴 **حرجة**

- **المشكلة:** لا يستطيع اقتراح واحد أن يصبح مقبولاً. إمّا (أ) لا يوجد اقتراح، أو (ب) اقتراح وحيد → `modelNotCorroborated`، أو (ج) اقتراحان → أحدهما < 0.55 → `modelNotCorroborated`، أو (د) الاثنان ≥0.55 ومتفقان → `accepted` **فقط** إذا كان الطول على المحور الطويل < 0.984.
- **الدليل:** `boundary_proposal_cascade.dart:82-89` يشترط `_accepted(first) && _accepted(second)` — أي **كل** اقتراح، حتى عند غياب الثاني، يجب أن يتجاوز 0.55. وهذا مُقيَّد بسقف 0.984 على المحور الطويل (محسوب: §4.4).
- **الملف والأسطر:** `boundary_proposal_cascade.dart:47-57, 82-93, 186-193`.
- **السبب الجذري:** عتبتان مختلفتان للشيء نفسه — `modelConfidence` للعرض/السجل، و`meetsAcceptanceThreshold` للتفويض. `minAutoAcceptConfidence = 0.55` مُمرَّر أيضاً إلى `verifyBoundary` (`docquad_model.dart:228`)، فتُضاف `lowModelConfidence` مرتين بنفس الشرط.
- **الأثر:** صفر قصّ تلقائي في المسار المفرد عملياً؛ وفي المسار متعدد المناطق صفر بحكم `producer: segmenter` (§RC-04).
- **الحل:** لا تخفض العتبة. **أزل شرط «كلا النموذجين»** واستبدله بقرار من ثلاث حالات: «متفقان ومقبولان» / «متفقان وأحدهما ضعيف» / «مختلفان»؛ واعتبر النموذج القوي وحده سبباً كافياً للمراجعة لا للقبول. لا تخفض 0.55 قبل قياس معدل الرفض.
- **هل يتطلب تدريباً؟** ❌ لا.
- **الاختبار:** حالة «اقتراح واحد قوي + غياب الثاني» ⇒ يجب أن تبقى **مراجعة** (سلوك صحيح) لكن مع `review=modelNotCorroborated` فقط، لا مع `lowModelConfidence` الكاذب.

### RC-03 — بوابة الحافة غير متماثلة وتُنتج إنذارات كاذبة 🔴 حرجة

- **المشكلة:** على المحور الطويل، أقصى كسر ممكن 0.99302 > 0.984 ⇒ كل زاوية على الحافة اليمنى/اليسرى تُعلَّم ملامسة. وعلى المحور القصير، أقصى كسر 1.15754 ⇒ لا يمكن الإبلاغ عن ملامسة أبداً (تُرصد كـ`outOfBounds`).
- **الدليل:** حساب مستقل لكل خلايا 64² (سكربت §4.4) + تأكيد المستودع نفسه.
- **الملف والأسطر:** `lib/domain/boundary_decision.dart:664-672` (`p.x >= 0.984`)، مقابل `lib/imaging/docquad_model.dart:55-63` (`/(extent-1)`).
- **الأثر:** بطاقة تملأ الإطار ⇐ `touchesFrameEdge` ⇒ مراجعة إلزامية، حتى لو كانت الحافة ظاهرة بالكامل. وهذا بالضبط سلوك «بطاقة تلامس حافة الصورة» في قائمة الاختبارات المطلوبة.
- **الحل:** استبدل مسافة ثابتة بكسر عن المقاس الفعلي المحسوب من الشبكة (خلية heatmap = 4px في 256-space = `4/scale/(extent−1)`)، وأضف قياساً بجانب كل حافة بدل نقطة واحدة.
- **تدريب؟** ❌ لا (لكنه يحتاج **معايرة** على صور بحدود حافة معلومة → RC-05).

### RC-04 — المسار متعدد المناطق لا يستطيع القبول التلقائي أبداً 🟠 عالية

- **المشكلة:** `SegmentCandidate.producer` افتراضيه `segmenter`، و`verifyBoundary` يحوّل اقتراح `segmenter` بلا `modelConfidence` إلى `lowModelConfidence` حتماً.
- **الدليل:** `document_segmenter.dart:52` (الافتراضي) و`segmentation` تنتج `SegmentCandidate` بلا `modelConfidence` (سطر 400-406, 1148-1153) و`verifyBoundary` في `boundary_decision.dart:676-689` يشترط `modelConf == null` ⇒ `lowModelConfidence`.
- **الأثر:** كل صورة يكتشف فيها المقسّم منطقة ⇒ مراجعة إلزامية، **ولا يُستشار النموذجان العصبيان إطلاقاً** (`recognition_pipeline.dart:416`).
- **الحل:** بعد قبول منطقة المقسّم **قياسياً**، مرّر الرباعي إلى تسلسل النماذج العصبية عليه (crop المنطقة ثم الاقتراح)، بدل إلغاء المسار العصبي.
- **تدريب؟** ❌ لا.

### RC-05 — لا مصنِّف نوع/وجه حقيقي، ولا بيانات مرجعية 🟠 عالية

- **المشكلة:** التصنيف = قاموس نصي. لا وجه أمامي/خلفي. لا مصفوفة التباس. صفر تسميات بشرية معتمدة.
- **الدليل:** `recognition_classifier.dart:1-4, 81-217`; `LOCAL_REFERENCE_DATASET_REPORT_2026-10-26.md:54` («0/19 موسومة بشرياً»، «التقسيم مستحيل»).
- **الأثر:** `qualifiesForAutomaticPlacement` تفشل ⇒ لا مقاس ⇒ لا A4. وهذا يفسّر «لم يوضع أي مستند» **بنيوياً**.
- **تدريب؟** ✅ **نعم — لكن ليس قبل تجهيز بيانات** (§13).

### RC-06 — فجوة بيانات في المقاسات المرجعية 🟠 عالية

- **المشكلة:** 2 من 6 أنواع بمقاس موثَّق. `residenceCard` و`rationCard` تقديريان بلا مصدر. `civilStatusId` و`other` بلا مقاس.
- **الدليل:** `document_kind.dart:249-302`; `presetStatusFor` (سطر 312-317).
- **الأثر:** «لماذا لا يُثبَّت المقاس بعد نجاح التصنيف والقص؟» — لأن **النوع نفسه لا يملك مقاساً قابلاً للتثبيت.** هذه إجابة قاطعة للسؤال المطروح.
- **تدريب؟** ❌ (يحتاج **قياساً ميدانياً**، لا تعلّماً آلياً).

### RC-07 — اختلاف تحجيم مخرجات DocAligner عن upstream 🟡 متوسطة (غير متحقَّق رقمياً)

- **المشكلة:** upstream يحجّم خرائط المخرجات إلى حجم المصدر ثم يعتبت ثم يأخذ centroid؛ التطبيق يعتبت ثم يقسم على `width`/`height` (لا `−1`).
- **الدليل:** `infer.py@1.1.1` (المقتبس في §3.3) مقابل `docaligner_model.dart:219`.
- **الأثر:** إزاحة زاوية بمقدار جزء من خلية، وانحراف داخلي منتظم ≤1px على 1200.
- **تدريب؟** ❌ لا. **لكن التحقق يحتاج الوزن (غائب).**

### RC-08 — مقارنة النموذجين حسّاسة لترتيب القنوات 🟡 متوسطة

- **المشكلة:** `_disagreementFraction` يقارن الزاوية i بالأخرى i بلا بحث دوري. تبديل قناتين في نموذج واحد ⇒ disagreement ≈ 100% ⇒ `modelDisagreement` كاذب.
- **الدليل:** `boundary_proposal_cascade.dart:211-229`; `boundary_arbitration.dart:318-334`. لا يوجد أي بحث عن `(i+shift)%4` في المستودع (بحث شامل أعاد صفر نتيجة).
- **الأثر:** حجب قبول سليم في حالة انحراف ترتيب حقيقي (وهو احتمال وارد جداً عند اختلاف التدريب بين نموذجين مختلفين تماماً).
- **تدريب؟** ❌ لا. إصلاح المقارنة (خذ أدنى مسافة على 4 إزاحات دورية) + اختبار.

### RC-09 — `detectionConfidence` يحمل دلالتين متعارضتين 🟡 متوسطة

- **المشكلة:** عند الفشل يُسجَّل 0.55، وعند النجاح قيم النموذج (0.05–1.0). نفس الحقل.
- **الدليل:** `boundary_proposal_cascade.dart:84-88` (يمرّر `first` عبر `_uncorroborated`) مقابل `:144` (`_traceOf` يقرأ `proposal.modelConfidence`).
- **الأثر:** أي تحليل لاحق أو أي عتبة مستقبلية تُبنى على رقم لا معنى ثابتاً له.
- **تدريب؟** ❌ لا.

### RC-10 — ترتيب الزوايا غير مُثبت باختبار 🔴 حرجة (فجوة اختبار)

- **المشكلة:** لا اختبار يثبت TL/TR/BR/BL لـDocQuadNet. الاختبار القائم يستخدم **3 نقاط** ويؤكد علاقة `<` فقط.
- **الدليل:** `test/imaging/docquad_coordinate_test.dart:328-341`.
- **الأثر:** خطأ ترتيب دوري **لا يكتشفه أي بوابة هندسية**: مستطيل في مكان خاطئ يمرّ من `assessQuad` و`CropDraft` و`verifyBoundary` — وهذا مذكور كتحذير في تعليق الملف نفسه (`docquad_coordinate_test.dart:9-12`) لكن غير مُغطّى.
- **تدريب؟** ❌ لا. **اختبار.**

---

## 11. ما يمكن إصلاحه برمجياً دون تدريب

| # | الإصلاح | الملف | مخاطرة | كلفة |
|---|---|---|---|---|
| 1 | استراتيجية تحجيم تكيّفية (letterbox مقابل حشو مربّط) بـevidence | `docquad_model.dart:267-301` | منخفضة (تغيير معالجة فقط) | ×2 زمن الاستدلال (~+27ms) |
| 2 | إزالة شرط «كلا النموذجين مقبولان» → نموذج تأييد ثلاثي الحالات | `boundary_proposal_cascade.dart:82-93` | **متوسطة** (يمسّ السلامة) | تصميم + اختبار |
| 3 | بوابة حافة نسبية بدل 0.016 المطلق، ومقياس لكل حافة | `boundary_decision.dart:664-672` | متوسطة | صغير |
| 4 | مقارنة عدم تطابق محصّنة ضد التدوير الدوري | `boundary_proposal_cascade.dart:211-229` | منخفضة | صغير |
| 5 | تمرير المنطقة المقاسة عبر النماذج العصبية بدل إلغائها | `recognition_pipeline.dart:416-446` | متوسطة | متوسط |
| 6 | فصل `detectionConfidence` عن `acceptanceScore` | `boundary_proposal_cascade.dart:84-88,144` | منخفضة | صغير |
| 7 | مطابقة معالجة DocAligner مع upstream (تحجيم المخرج قبل العتبة) | `docaligner_model.dart:197-222` | منخفضة | صغير — **يحتاج الوزن للتحقق** |
| 8 | توحيد ترتيب الزوايا دورياً قبل `verifyBoundary` | `boundary_decision.dart:591` | منخفضة | صغير |
| 9 | إضافة اختبار ترتيب 4 نقاط حقيقي | `test/imaging/` | لا شيء | صغير |

**كل ما في الجدول أعلاه قابل للتنفيذ بلا تدريب وبلا تغيير أوزان.**

---

## 12. ما يتطلب إعادة تدريب

**لا شيء حتى الآن — والسبب مُثبت لا مفترض.**

- عيب RC-01 **مُثبت** أنه في الكود: نفس الوزن، نفس الإطار، دالة تحجيم مختلفة ⇒ نتائج مختلفة 5-11×. لا يجوز لوم الوزن.
- عيب RC-02/03/04 **مُثبت** أنه في القرار: رياضياً لا يمكن لاقتراحات معيّنة أن تُقبل، بغض النظر عن دقة الشبكة.
- **شرط إعادة فتح التدريب** (وهو ما لم يتحقق بعد): قياس دقة الزوايا (وسيط خطأ / IoU) على **صور حقيقية موسومة** بعد تطبيق إصلاحات 11، وإثبات أن الخطأ المتبقي > متطلبات المنتج.

> إعادة التدريب الآن = إعادة تدريب نموذج **بينما عينه مُغمضة**. هذا أسوأ من عدم التدريب.

---

## 13. ما يتطلب بيانات تدريب جديدة

| الحاجة | الحالة | لماذا لا يمكن التحايل عليها |
|---|---|---|
| تسميات زوايا (quad) بشرية معتمدة | **0** (`LOCAL_REFERENCE_DATASET_REPORT_2026-10-26.md:54`) | كل مقاييس الزوايا الحالية **اصطناعية**. `docquad_realistic_accuracy.py:11-13` يقرّ: «It is still SYNTHETIC. Nothing here is evidence about real photographs». |
| تسميات نوع مستند | **0** | كل تصنيف اليوم نصي. لا يوجد تدريب ممكن |
| تسميات **وجه أمامي/خلفي** | **0 وغير موجودة كمفهوم** | لا حتى في مخطط البيانات v2 (`tool/schemas/local_reference_dataset_v2.schema.json`) |
| مقاسات فيزيائية مقيسة بالمسطرة | **لا** | `residenceCard`/`rationCard` تقديريان. لا يمكن اشتقاق مقاس من صورة |
| تقسيم train/val/test | **مستحيل حالياً** | `LOCAL_REFERENCE_DATASET_REPORT_2026-10-26.md:57` — مرفوض منهجياً وبرمجياً |
| بيانات عراقية عالية الجودة | **11 صورة كاميرا حقيقية فقط** (15 مستنداً) | أقل بمرتبتين من الحد الأدنى لأي تقييم ذي دلالة |

**الحكم:** لا. **لا يمكن تحسين النماذج بالبيانات المتاحة.** المتاح 11 صورة بلا تسميات، وهي عيّنة اختبار استكشافية لا مجموعة تدريب. تجهيز مجموعة جديدة شرط لا بديل عنه **لأي** عمل تعلّم لاحق.

**الأولوية في التجميع المقترح:**
1. ٣٠٠+ صورة لكاميرا مستندات عراقية (بطاقة وطنية، سكن، تموين، جواز، أحوال مدنية) في ظروف إضاءة/زوايا/خلفيات متنوعة.
2. تسميات زوايا مزدوجة (مراجعان + تحكيم) على ٢٠۰ منها على الأقل.
3. تسميات نوع **ووجه** (أمامي/خلفي) على الجميع.
4. قياس فيزيائي بالمسطرة لكل نموذج مستند أصلي (لا نسخة) — لحل RC-06.
5. التقسيم بحسب **جلسة التصوير** لا بحسب الصورة، لمنع التسرب.

---

## 14. التوصيات الهندسية وترتيب التنفيذ

### المرحلة 0 — إغلاق تناقض الترخيص (قبل أي كود) ⛔
`docs/reports/DOCALIGNER_INTEGRATION_2026-10-30.md` يقول: «Scan-id redistribution: **not cleared** by the available evidence». و`pubspec.yaml:44` يشحنه. و`assets/legal/` يضم ترخيص Apache للـ**كود** لا للـ**وزن**.
**المطلوب:** قرار موثَّق — إمّا الحصول على تصريح إعادة توزيع، أو إزالة DocAligner من البناء. **لا يجوز الاستمرار بتشغيل نموذجين وتسجيل نتائجهما بينما أحدهما غير قابل للنشر.**

### المرحلة 1 — قياس قبل التغيير (أسبوع ١)
1. **شغّل `scan-id-journeys` الحقيقي على الجهاز** واستخرج الأرقام لـ12 صورة على الأقل. بلا هذا لا يمكن تأكيد RC-02 رقمياً.
2. نفّذ اختبار ترتيب الزوايا الرباعي (RC-10) — أرخص إصلاح وأعلى عائد معرفي.

### المرحلة 2 — إصلاحات الكود بلا تغيير سلوك القبول (أسبوع ٢)
3. استراتيجية التحجيم التكيّفية (RC-01).
4. مقارنة عدم التطابق المحصّنة دورياً (RC-08).
5. فصل `detectionConfidence` (RC-09).
6. توحيد ترتيب الزوايا (بند 8 في §11).
**شرط البوابة:** كل إصلاح يمرّ على نفس مجموعة 36 إطاراً ويثبت عدم تراجع العمودية.

### المرحلة 3 — إصلاحات السياسة (أسبوع ٣، بموافقة صريحة)
7. بوابة الحافة النسبية (RC-03).
8. تمرير المناطق المقاسة إلى النماذج (RC-04).
9. نموذج التأييد ثلاثي الحالات (RC-02) — **آخرها وأخطرها، ولا يصح قبل ٣ و٧**.

### المرحلة 4 — البيانات (أسابيع ٤+)
10. تجهيز مجموعة البيانات وفق §13.
11. إعادة معايرة `_minimumReviewEvidence` و`0.55` **على المجموعة الجديدة**، لا على الحدس.
12. عندها فقط: قرار إعادة تدريب/استبدال.

**المخاطر المتوقعة لكل مرحلة:**

| المرحلة | الخطر | التخفيف |
|---|---|---|
| 1 | لا جهاز ولا صور حقيقية | تشغيل السجل من الجهاز نفسه قبل أي كود |
| 2 | تراجع على الإطارات العمودية | بوابة عدم تراجع على كل الأشكال الستة |
| 3 | قبول قصّ خاطئ (خطر أمني/خصوصية أعلى) | لا ترفع القبول؛ فقط **أصلح أسباب الرفض الكاذبة**. وكل حالة قبول جديدة تحتاج اختباراً بزوايا حقيقية |
| 3 | تعارض ترخيص DocAligner | المرحلة 0 تسبقها |

---

## 15. خطة Regression Tests ومعايير القبول

### 15.1 التغطية الحالية — ما تُغطّيه وما لا تُغطّيه

**موجود (185 ملف اختبار):** هندسة القص (`perspective_test`)، تقييم الرباعي (`quad_assessment_test`)، التحويل الإحداثي (`docquad_coordinate_test`)، التسلسل (`boundary_proposal_cascade_test` — 13 حالة)، التحكيم (`boundary_arbitration_test`)، تسريب النص (`text_exclusion_audit_test`)، EXIF ٨ اتجاهات (`prepare_image_test`)، عتبات الأمان (`boundary_threshold_scenes_test`).

**غير موجود — وهذه فجوات خطيرة:**

| الفجوة | الأثر |
|---|---|
| لا اختبار يثبت **ترتيب الزوايا الرباعي** | RC-10 |
| لا اختبار **نسبة أبعاد الإطار** للشبكة | RC-01 لا يُحمى باختبار |
| لا اختبار **نمط التحجيم** مقابل upstream | RC-07 |
| لا اختبار **تأثير الحافة على المحورين** | RC-03 |
| لا اختبار **حالات عدم التطابق الدوري** | RC-08 |
| لا أي اختبار على **صور حقيقية** | كل مقاييس الدقة اصطناعية |
| لا اختبار **وجه أمامي/خلفي** | المفهوم غير موجود |

### 15.2 مصفوفة الاختبارات المطلوبة (لم تُنشأ — للتنفيذ لاحقاً)

| # | الحالة | الطبقة | المعيار |
|---|---|---|---|
| T01 | مستند واضح مستقيم | كامل | قصّ accepted، نسبة ≤1% |
| T02 | مستند مائل 15–25° | كامل | قصّ accepted، خطأ زاوية ≤1% قطري |
| T03 | منظور شديد (>2.5 نسبة أضلاع) | geometry | رفض صريح بـ`degenerateEdges` **لا** قبول صامت |
| T04 | إضاءة ضعيفة (contrast < 0.35) | cascade | لا crash، لا قبول كاذب |
| T05 | انعكاس ضوئي على البطاقة | cascade | لا crash، قرار صريح |
| T06 | خلفية مشابهة للبطاقة (ΔLum < 15) | cascade | لا قبول كاذب (`isPlausibleBoundary` يرفض) |
| **T07** | **بطاقة تلامس حافة** | decision | **RC-03**: لا `touchesFrameEdge` إن كانت الحافة ظاهرة؛ و`true` إن كانت مقطوعة — **على المحورين** |
| T08 | صورة منخفضة الدقة (البطاقة < 200px) | cascade | رفض صريح، لا اقتراح عشوائي |
| **T09** | **نموذج يكتشف والآخر لا** | cascade | `review=modelNotCorroborated` **فقط**، بلا `lowModelConfidence` كاذب |
| T10 | اختلاف كبير بين الزوايا (>4%) | cascade | `modelDisagreement`، لا متوسط نقاط |
| **T11** | **زوايا متقاطعة أو خارج الحدود** | geometry | `notConvex`/`outOfBounds` صريحان |
| T12 | تصنيف صحيح مع قص غير معتمد | pipeline | قصّ في المراجعة + OCR يعمل (§6.3) |
| T13 | قصّ صحيح مع تصنيف `unknown` | pipeline | `sizeConfirmed=false`، `unknown` صريح |
| T14 | أنواع متشابهة (بطاقة وطنية/سكن) | classifier | `conflictGap` يعمل، لا تفضيل عشوائي |
| **T15** | **أمامي/خلفي** | classifier | **غير ممكن اليوم — تتطلب المفهوم أولاً** |

### 15.3 المقاييس الإلزامية قبل/بعد أي تحسين

| المقياس | التعريف | العتبة المقترحة |
|---|---|---|
| معدل الاقتراحات | `proposal / total` لكل شكل إطار | لا تراجع >2 نقطة مئوية |
| خطأ الزاوية المتوسط | px + % قطري | لا تراجع |
| **وسيط IoU** | تقاطع/اتحاد مع الحقيقة | **الرقم الحالي 0.7034 على 28 منطقة** (`DOCQUAD_VERIFICATION…md`) — هو خط الأساس |
| **معدل الرفض الكاذب** | اقتراح صحيح (IoU≥0.9) مرفوض | **يجب أن ينخفض** — هذا هدف RC-01/02/03 |
| **معدل القبول الكاذب** | اقتراح خاطئ (IoU<0.9) مقبول | **يجب أن يبقى صفراً** — لا تنازل |
| زمن الاستدلال | p50/p95 ms | لا يزيد >2× بلا مبرر |
| ذروة الذاكرة | RSS delta | لا يزيد >50% |

**الرقم المرجعي الوحيد الموجود:** `accepted poor quads (IoU<0.90)` يجب أن يبقى **0**. أدوات القياس جاهزة: `tool/evidence/docquad_realistic_accuracy.py` و`tool/evidence/docquad_crop_quality.py`.

---

## 16. المخاطر والتبعيات والملفات المتأثرة مستقبلاً

### 16.1 تبعيات حاكمة

| التبعية | الأثر | المصدر |
|---|---|---|
| `flutter_onnxruntime` | كل استدلال عصبي يمرّ عبره. لا بديل | `pubspec.yaml` |
| ORT build | `ORT-1.28` مكتوب في معرّف النموذج؛ `.so` مقلَّص بنسخة أخرى يكسر JNI وصيغة `.ort` | `docquad_model.dart:20` + `APK_REDUCTION_STUDY_2026-11-18.md` |
| **ترخيص وزن DocAligner** | **مانع نشر** | §14 المرحلة 0 |
| `tool/fetch_docaligner_model.py` | البناء يفشل بلا الشبكة. `pubspec.yaml:44` يفترض وجود ملف غير موجود في git | `.gitignore:24` + `pubspec.yaml:44` |
| مجموعة البيانات المحلية | لا يمكن إعادة تدريب/معايرة بلا تجهيزها | §13 |

### 16.2 الملفات المتأثرة بأي إصلاح مستقبلي

| الملف | نوع المساس | حاجة لاختبار منع تراجع |
|---|---|---|
| `lib/imaging/docquad_model.dart` | تحجيم الإدخال (RC-01) | ✅ حاسم |
| `lib/imaging/docaligner_model.dart` | ما بعد المعالجة (RC-07) | ✅ (يحتاج الوزن) |
| `lib/imaging/boundary_proposal_cascade.dart` | منطق التأييد (RC-02, RC-08, RC-09) | ✅ حاسم |
| `lib/domain/boundary_decision.dart` | بوابة الحافة (RC-03) | ✅ حاسم |
| `lib/domain/quad_assessment.dart` | المدخلات فقط — لا تُغيَّر العتبات | ✅ |
| `lib/application/recognition_pipeline.dart` | تمرير المناطق (RC-04) | ✅ حاسم |
| `lib/domain/document_kind.dart` | **مقاسات** (RC-06) — لا تُغيَّر بلا قياس ميداني | ✅ |
| `lib/imaging/document_segmenter.dart` | `producer` للمرشّح | ✅ |
| `lib/domain/recognition_classifier.dart` | عند إدخال مصنِّف حقيقي | ✅ |
| `assets/models/*` | أي تغيير وزن = إعادة بناء كاملة + إعادة معايرة | — |

### 16.3 مخاطر أمنية/خصوصية

| الخطر | الحالة | الدليل |
|---|---|---|
| تسريب نص OCR في السجلات | **مُعالَج جيداً**: `RecognitionEvidence.reason` يحمل معرّفات مجموعات لا نصاً؛ `detectionTrace` أكواد وأرقام فقط | `recognition_classifier.dart:99-105`; `boundary_decision.dart:183-190` |
| تسريب مسارات في السجلات | **مُعالَج**: `_safeDetectorId` يرفض ما لا يطابق نمطاً آمناً | `image_journey_report.dart:578-587` |
| صورة تالفة/ضخمة | **مُعالَج**: فحص ترويسة قبل تخصيص بكسلات + سقوف صريحة | `prepare_image.dart:28-33` |
| نموذج منبثق معطّل | **مُعالَج**: `RetirableResource` + `runStageWithin` بميزانية 45s | `local_image_editor.dart:51, 189-194` |
| **استمرار تشغيل وزن غير مُبرَّأَ الترخيص** | **⚠ خطر قانوني قائم** | §14 المرحلة 0 |

---

## 17. القرار النهائي لكل مكوّن

| المكوّن | التصنيف | المبرر |
|---|---|---|
| **`DocQuadNet-256`** | **يحتاج إصلاحاً في طريقة تشغيله ومعالجة مدخلاته** | دقته على الإطارات الصحيحة عالية (IoU وسيط 0.91 على العمودية). العيب في `_letterbox` مُثبت بتجربة إحباط. **لا تدريب ولا استبدال.** |
| **`DocAligner`** | **لا يمكن الحكم بسبب نقص الأدلة** (مع ملاحظتين) | الوزن غائب فلم يُشغَّل ولا مرة. ملاحظتان مُثبتتان: (أ) انحراف عن upstream في تحجيم المخرج، (ب) دوره في العتبة **غير سليم بغض النظر عن دقته** لأنه يمنع القبول بـ`min(peak)` غير معايرة. **مانع مستقل: الترخيص.** |
| **نظام التصنيف** | **يحتاج استبدالاً** (بمبررات) | ليس نموذجاً: قاموس نصي بلا وجه أمامي/خلفي، بلا `unknown` كمخرج، بلا مصفوفة التباس، بلا قياس. لا يمكن «معايرته» لأنه لا يُنتج احتمالاً. **البديل يحتاج بيانات أولاً (§13).** |
| **التسلسل ومنطق القرار** (`BoundaryProposalCascade` + `verifyBoundary`) | **يحتاج إعادة معايرة** | عتبات مستحيلة الوصول بنيوياً (RC-02)، بوابة حافة غير متماثلة (RC-03)، مسار مقسّم لا يقبل أبداً (RC-04)، مقارنة هشّة (RC-08)، حقل ثقة مزدوج الدلالة (RC-09). |
| **هندسة القص والمنظور** | **سليم ولا يحتاج تغييراً** | خطأ إعادة إسقاط ≤1.8e-13 px، خطأ أبعاد 0.0000%، 9 مشاهد. **حوّل 703/703 ورفض 747/747** لحالات الحافة. أُثبت بالقياس لا بالادعاء. |
| **القياس والوضع** | **يحتاج بيانات (لا كود)** | المنطق سليم؛ المقاسات ناقصة/تقديرية. لا إصلاح برمجي يحلّ RC-06. |
| **المقسّم والكاشف الكلاسيكي** | **يحتاج إصلاحاً محدوداً** | يعملان كاحتياط، لكن دورهما في `recognition_pipeline.dart:416` **يُلغي** المسار العصبي؛ ودورانهما لا يقبلان تلقائياً بحكم التصميم. |

---

## 18. الخلاصة في سطرين

**الرسالة الأساسية:** المستودع لا يعاني من «نماذج سيئة» بالمعنى الشائع. يعاني من **حلقة مفرغة هندسية**: معالجة مسبقة تُسقط نموذجاً جيداً على الإطارات الأفقية (RC-01)، ثم منطق قرار لا يملك — رياضياً — أن يقبل ما ينجو منها (RC-02/03/04)، ثم تصنيف نصّي بلا وجه ولا مقاس موثَّق لا يمكنه تأهيل الوضع على A4 (RC-05/06). كل ذلك فوق بيانات صفرية التوسيم.

**لهذا فإن القرار الصحيح ليس «أعِد تدريب النماذج».** القرار الصحيح هو: **أغلق تناقض الترخيص، ثم أصلح أربعة عيوب برمجية مُثبتة، ثم — وقبل أي تعلّم آلي — جهّز مجموعة بيانات موسومة.** إعادة التدريب قبل ذلك تعني تدريباً على عمى.

---

### ملحق أ — أفعال هذه الجلسة (كلها قراءة/قياس، بلا تعديل إنتاجي)

| الفعل | النتيجة |
|---|---|
| قراءة كل مسار الكشف/القص/التصنيف/القياس/الوضع | ✅ |
| البحث عن `scan-id-journeys-2026-11-22-1456.json` في الشجرة و23 فرعاً و`/home` و`/tmp` وداخل الـAPK | ❌ **غير موجود** |
| `sha256sum` على وزن DocQuadNet | `f0f2f52d…3e72a`, 13,404,960 B |
| تشغيل الرسم البياني المشحون (ORT 1.32.0) لفحص الواجهة | مدخل 1×3×256×256، مخرجان 1×4×64×64 و1×1×64×64 |
| جرد العمليات عبر `OrtFormatModelProcessor` | 6 عمليات |
| **تجربة إحباط تحجيم الإدخال (36 إطاراً × وضعين)** | **letterbox 15/36 مقابل سحق 19/36؛ خطأ 5.3×–11× أفضل للأفقي** |
| حساب نطاق الحافة الأقصى لكل خلايا 64² | x ≤ 0.99302 · y حتى 1.15754 |
| استعلام `api.github.com` لأسطورة DocAligner 1.1.1 | الهوية مطابقة (id/bytes/sha/tag) |
| قراءة `docaligner/heatmap_reg/infer.py@1.1.1` | تحجيم المخرج قبل العتبة — يخالف التطبيق |
| **تنزيل وزن DocAligner** | ❌ `SSL_ERROR_SYSCALL` — **غير متحقق** |
| **تنزيل وزنَي OCR** | ❌ محجوب — **غير متحقق** |
| فحص `مكتبتي برو.apk`/`.zip` | مقتطعان (140 مدخلاً، بلا `lib/`) — **لا يصلحان كدليل** |
| أي تعديل على ملف إنتاجي | **صفر** |
| أي commit/push/merge | **صفر** |

تمّ التسليم عند حدود الفحص. **لم يُبدأ أي تنفيذ، وبانتظار قرار مستقل بشأن مرحلة الإصلاح.**
