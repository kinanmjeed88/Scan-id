# دراسة تقليص حجم APK — تحليل فقط، بلا تغيير إنتاجي

**التاريخ:** 2026-11-18 · **الفرع:** `arena/d2061602-scan-id` · **النوع:** دراسة، لا تنفيذ

> هذه الدراسة **لا تغيّر أي ملف إنتاجي**. كل رقم تحتها مقيس من هذه الشجرة أو
> منقولة من ملف في المستودع بمرجعه. ما لم يُقَس مذكور صراحة كغير مقيس.

---

## ١. ما يشكّل الحجم فعلاً

أحجام النماذج الأربعة **من تثبيتات المستودع نفسها** (`pubspec.yaml` +
`tool/check_detector_retirement.py`)، لا من تقدير:

| النموذج | البايت | MB | الحصة |
|---|---:|---:|---:|
| `docaligner_fastvit_sa24_7f9f5a89.onnx` | 83,084,930 | 83.08 | **76.0 %** |
| `docquadnet256_trained_opset17.ort` | 13,404,960 | 13.40 | 12.3 % |
| `ppocrv5_arabic_mobile_rec.onnx` | 7,998,947 | 8.00 | 7.3 % |
| `ppocrv5_mobile_det.onnx` | 4,826,518 | 4.83 | 4.4 % |
| **المجموع** | **109,315,355** | **109.32** | 100 % |

النتيجة الأولى والحاسمة: **أي تقليص لا يمسّ DocAligner لا يحرّك أكثر من ربع
الحجم.** وDocAligner هو النموذج الذي لا يمكن حذفه في هذه المهمة.

> **ما لم يُقَس:** حجم `APK` النهائي نفسه. آخر بناء ناجح أنتج
> `scan-id-android-debug-apk` بحجم 215,692,050 بايت، لكن ذلك **debug** ويحتوي
> `libonnxruntime.so` لثلاث معماريات + `libflutter` + أدوات تشخيص. أثر تنزيل
> الـartifact محجوب في هذه البيئة (‏`productionresultssa18.blob.core.windows.net`
> يرفض الاتصال)، فلم أستطع تفكيك APK release وقياس نصيب كل مكوّن بدقة. لذلك كل
> نسبة تحتها تُحسب **على بايتات النماذج وحدها**، لا على APK كامل.

### المعماريات الثلاث (قيد مفروض)

APK **موحّد** بلا `abiFilters` ولا `splits` في
`android/app/build.gradle.kts` (لا وجود لأي منهما). الأدلة الموثقة في
`docs/reports/STARTUP_REGRESSION_INVESTIGATION_2026-10-31.md` تثبت أن كل معمارية
تحمل:

```
arm64-v8a  : libdartjni.so, libflutter.so, libonnxruntime.so, libonnxruntime4j_jni.so
armeabi-v7a: libdartjni.so, libflutter.so, libonnxruntime.so, libonnxruntime4j_jni.so
x86_64     : libdartjni.so, libflutter.so, libonnxruntime.so, libonnxruntime4j_jni.so
```

أي أن `libonnxruntime.so` **يتكرر ثلاث مرات**. تقليصه يوفّر ثلاث مرات. هذا هو
المحور الثاني بعد النماذج.

---

## ٢. الجرد الفعلي للعمليات (Ops)

قرأتُ هذا **من الرسم البياني المشحون** عبر
`onnxruntime.tools.ort_format_model.OrtFormatModelProcessor`، لا من ملف تعريف
ولا من افتراض:

```bash
python3 - <<'PY'
from onnxruntime.tools.ort_format_model import OrtFormatModelProcessor, OperatorTypeUsageManager
req = {}
OrtFormatModelProcessor('assets/models/docquadnet256_trained_opset17.ort',
                        req, OperatorTypeUsageManager()).process()
PY
```

**DocQuadNet-256 يحتاج 6 عمليات فقط:**

| النطاق | opset | العملية |
|---|---:|---|
| `ai.onnx` | 1 | `GlobalAveragePool` |
| `ai.onnx` | 6 | `HardSigmoid` |
| `ai.onnx` | 11 | `Conv` |
| `ai.onnx` | 13 | `Resize` |
| `ai.onnx` | 14 | `Mul` |
| `com.microsoft` | 1 | `FusedConv` |

لاحظ `FusedConv` تحت `com.microsoft`: هي عملية **خاصة بـONNX Runtime**، وهذا
سبب وجود النموذج بصيغة `.ort` أصلاً.

### الحدّ الذي يمنع جرداً كاملاً

النماذج الثلاثة الأخرى **ليست في هذه الشجرة**:

* `docaligner_fastvit_sa24_7f9f5a89.onnx` — مستبعد بـ`.gitignore` (83 MB)، يجلبه
  `tool/fetch_docaligner_model.py`. التنزيل فشل هنا: `TLS/SSL connection has been
  closed (EOF)` من `api.github.com` وإعادة التوجيه.
* `ppocrv5_mobile_det.onnx` و`ppocrv5_arabic_mobile_rec.onnx` — يجلبهما
  `tool/fetch_ocr_models.py` من `huggingface.co`، وهو **خارج قائمة المضيفين
  المسموحين** في هذه البيئة (HTTP 000).

**لذلك:** جرد union للعمليات الأربع **غير ممكن بشكل صادق من هذا الـcheckout**.
أي رقم توفير مبني على "نحتاج ٦ عمليات فقط" سيكون خطأً، لأن DocAligner
(FastViT-SA24 مع BiFPN) يحتاج عادة `Sigmoid`/`Add`/`Concat`/`LayerNormalization`
وما شابه، وPP-OCRv5 يحتاج عمليات det/rec الكاملة. DocQuadNet وحده هو **12.3 %**
من بايتات النماذج، فأصغر جرد ممكن لا يخصّ إلا هذا الجزء.

---

## ٣. الجدوى: Reduced Operator Build

### ما يقتضيه فعلياً

Reduced Operator Build يحتاج ثلاث طبقات متوافقة، وكل واحدة قابلة للكسر:

1. **ORT C/C++ runtime** مبني بـ`--include_ops_by_config` من ملف
   `required_operators.config`. هذا يقلّص `libonnxruntime.so`.
2. **AAR/Java** — `com.microsoft.onnxruntime:onnxruntime-android` يوزّع `.so`
   مبنياً مسبقاً بكل العمليات. **لا يوجد AAR رسمي مبني بعمليات مختارة.**
   أي: ستحتاج بناء `.so` بنفسك ولفّه يدوياً.
3. **JNI + `flutter_onnxruntime`** — الإضافة مثبّتة على commit محدد
   (`2f0fc6c102652965004b89512b7187e6621dddf7`, النسخة 1.9.0) وتنادي
   `OrtEnvironment`/`OrtSession` عبر JNI. أبقتها كما هي شرط: `proguard-rules.pro`
   يحتفظ بـ`ai.onnxruntime.**` كاملاً لأن JNI يبحث عنها بالاسم.
   **تغيير `.so` وحده لا يكسر هذه الواجهة**، لكن **تغيير إصدار ORT يكسرها**، لأن
   `OrtApi` ثنائي التوافق مشروط بنفس الإصدار. النسخة المستخدمة على Windows
   مثبتة في `windows/CMakeLists.txt` كـ`1.28.3`، والـmodel id يقول
   `DocQuadNet-256/ORT-1.28`. فبناء `.so` مقلّص يجب أن يكون **1.28.x بالضبط**،
   وإلا انكسر توافق الـJNI والـ`.ort`.

### التوفير المتوقع — بحدوده

لا أستطيع قياس حجم `.so` مقلّص بلا بناء، لكن الحدّ الأعلى معروف منطقياً:

* `libonnxruntime.so` هو المكوّن الوحيد القابل للتقليص عبر هذا المسار.
* لا يمكن أن ينزل تحت ما يحتاجه تحميل ٦ عمليات + الـkernels الخاصة بـ
  `com.microsoft.FusedConv`.
* تقدير شائع أن ORT الكامل ~10–15 MB لكل معمارية، والمقلّص إلى ٦ عمليات قد
  ينزل إلى بضعة MB. **هذا تقدير من خارج هذه الشجرة، ولذلك لا أدخله كرقم.**

**الشكل الذي يجب أن يُقاس قبل أي التزام:** بناء `.so` بـ`--include_ops_by_config`
للمجموع الأربع، ثم `flutter build apk --release`، ثم مقارنة `unzip -l` بين
الأثرين. بلا ذلك، أي رقم توفير مكتوب هنا يكون تخميناً.

### حدود وأخطار

| الخطر | الأثر | التخفيف |
|---|---|---|
| إسقاط عملية يحتاجها DocAligner/OCR | فشل استدلال صامت أو استثناء عند التحميل | الجرد من **الأربع** كلها، ثم تشغيل `flutter test` + instrumentation |
| عدم تطابق إصدار ORT مع الـJNI | `UnsatisfiedLinkError` عند الإقلاع — وهو عطل موثق سابقاً في هذا المستودع | تثبيت 1.28.x ومطابقة `OrtApi` |
| كسر صيغة `.ort` | `FusedConv` غير متاح ⇒ النموذج لا يُحمّل | التحقق من أن `com.microsoft` مُضمَّن في البناء المقلّص |
| فقدان `FLT` kernel لمعمارية 32-بت | `armeabi-v7a` فقط يفشل | بناء واختبار ثلاث معماريات، والـAPK يبقى موحّداً |
| صعوبة الصيانة | لا أحد يعيد إنتاج `.so` | سكربت بناء موثّق + checksum مثل بقية النماذج |

### لماذا لا Basic Minimal Build

Basic Minimal Build (`--minimal_build`) يزيل **تحميل النماذج بصيغة ONNX** و
**الـruntime الكامل للـopset**، ويترك مسار ORT-format فقط. المخاطرة هنا ليست
نظرية: التطبيق يشحن `.ort` واحداً لكن **ثلاثة `.onnx`** لـDocAligner والـOCR.
Basic Minimal Build قد يمنع تحميل `.onnx` أصلاً، أو يفرض تحويلها كلها إلى `.ort`
(تغيير ملفات مشحونة + إعادة تثبيت checksums). المهمة تقول صراحة لا تعتمده
كحل مباشر — والسبب الهندسي مؤكد: **النماذج الثلاثة الأكبر بصيغة `.onnx`**.

---

## ٤. مسارات أرخص وأقل خطراً من تقليص ORT (تقديرية، تحتاج قياساً)

مرتبة بقيمة/خطر، وكلها **تحتاج قياس APK حقيقياً** قبل الالتزام:

1. **ضغط `libonnxruntime.so` داخل الـAPK.** أندرويد يضغط `.so` في APK افتراضياً
   (`useLegacyPackaging=false`)، فالحجم المخزّن أصغر من الحجم على القرص. لا أعلم
   من هذه الشجرة هل الملفات مضغوطة فعلاً في الـAPK الحالي؛ **يُقاس بـ`unzip -v`**.
   إن كانت غير مضغوطة فهذه أرخص مكسب.
2. **دقة FastViT-SA24.** إن كان النموذج 83 MB بـfp32، فتحويله إلى fp16 يقارب
   النصف (نظرياً ~41 MB). **هذا تغيير للنموذج**، والمهمة تمنع استبداله بآخر —
   والتكميم يغيّر الحساب فعلياً، فلن يُوصى به بلا قياس دقة يقابله. يُذكر كمحور
   دراسة فقط.
3. **حذف أدوات التشخيص من الإصدار.** `startupProbeRequested` مُطفأ افتراضياً في
   الإنتاج (مؤكد في `build.gradle.kts`)، فلا مكسب مضمون هنا.
4. **R8/shrinkResources** يعملان أصلاً في release. المكسب الإضافي معدوم تقريباً
   أمام 109 MB من النماذج.

---

## ٥. الخلاصة وخطة القياس التالية

* **مقيس:** أحجام النماذج الأربعة بدقة بايت، أن DocQuadNet يحتاج ٦ عمليات، أن
  الـAPK موحّد بثلاث معماريات، أن DocAligner = 76 % من بايتات النماذج.
* **غير مقيس، ويمنع توصية:** الحجم النهائي لـrelease APK، حجم
  `libonnxruntime.so` لكل معمارية، حجمه بعد تقليص العمليات، جرد عمليات
  النماذج الثلاثة الأخرى.
* **التوصية:** لا تنفيذ. الخطوة التالية هي إنتاج release APK في CI، تفكيكه
  (`unzip -v`)، ثم — وبعد جلب النماذج الثلاثة — توليد
  `required_operators.config` من الأربع، وبناء `.so` واحد لـ1.28.x وقياس
  الفرق على ثلاث معماريات مع تشغيل `flutter test` وinstrumentation.
