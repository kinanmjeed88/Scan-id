# تقرير هندسي شامل — Scan-id — 2026-10-16

> **الفرع:** `arena/8457c5eb-scan-id` | **الأساس:** `searchidf` (12ddfb6) | **المستودع:** `kinanmjeed88/Scan-id` — عام

---

## 1. البنية والآلية الحالية (قبل التعديل)

### 1.1 بنية Flutter
- **pubspec.yaml:** `name: scan_id` — `version: 0.1.0+1` — SDK `>=3.9.0 <4.0.0`, Flutter `>=3.35.7` — تبعيات: flutter_localizations, file_selector 1.0.3, image 4.5.4, path, path_provider, sembast 3.7.2, pdf, printing, crypto, url_launcher — dev: flutter_test, flutter_lints 5.0.0.
- **lib/**: `application/` (خدمات: ota_update, project_service, recognition_pipeline, layout_session…), `domain/` (نماذج نقية بلا Flutter/IO: project, arrangement, packing, document_kind…), `imaging/` (كاشف الحدود، المنظور، معالجة الصور), `persistence/` (Sembast, checkpoints), `presentation/` (app, layout_screen, ribbon, settings_screen…), `export/` (PDF), `main.dart`.
- **android/**: `build.gradle.kts` بمنطق توقيع Release صارم — لا رجوع إلى debug إذا `REQUIRE_RELEASE_SIGNING=true` أو task release مطلوب — يقرأ `KEYSTORE_BASE64` أو `storeFile` المحلي، يحقق Base64 وكلمة مرور المتجر والاسم المستعار وكلمة مرور المفتاح، يكتب keystore مؤقت تحت `build/` فقط، fingerprint المتوقع `3e9c...74a` (RSA-4096) في env `EXPECTED_CERT_SHA256`.
- **windows/**: `CMakeLists.txt` — منتج `scan_id.exe` مع `flutter_wrapper_app`, معايير Flutter, large_jpeg_scaler_test.
- **test/**: ~60 ملف اختبار — تغطي arrangement, packing, project schema v1-v5, imaging, presentation, integration. اختبارات OTA موجودة: `test/application/ota_update_test.dart` (517 سطر, 18+ حالة).
- **.github/workflows/**: `verify.yml` (gate: format, analyze, test, export-audit, signing-guard, debug APK, windows build), `android-signed-release.yml` (بناء APK موقّع + توثيق سلسلة الشهادات + windows reusable), `windows-release.yml` (reusable), `cleanup-old-runs.yml` (حذف runs فقط).
- **tool/**: `check_source.py`, `ci_gate.py`, `gradle/plugin-repositories.init.gradle`, `install_gradle_init.sh`, `report_gradle_plugin_repositories.sh`, `verify_exports.py`.

### 1.2 دورة التحديث الهوائي (OTA) — المسار الحالي

**داخل التطبيق (`lib/application/ota_update.dart`, 691 سطر):**

1. **رقم الإصدار المثبت:** `lib/presentation/app.dart:360` → `applicationVersion: '0.1.0'` ثابت (لا يقرأ pubspec ديناميكياً). `UpdateService(currentVersion)` يتحقق أنه SemVer صالح.
2. **طلب بيانات أحدث إصدار:** `GitHubUpdateSource.checkForUpdate()` → `GET https://api.github.com/repos/$owner/$repo/releases/latest` مع headers `Accept: application/vnd.github+json`, `User-Agent: Scan-id-update-check`، يحدّ حجم الاستجابة بـ 2 MiB، يفشل على `status != 200`.
3. **المصدر:** GitHub Releases API فقط. لا مصدر بديل.
4. **اختيار الملف حسب المنصة:** `selectUpdate()` يقرأ `tag_name`, يستخرج SemVer عبر `extractVersion` (يتعامل مع `v` و`release-`), يقارن `UpdateInfo.compareVersions(version, currentVersion) > 0`, يرشّح assets على `browser_download_url` ضمن hosts الموثوقة فقط (`github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com`, https:443 فقط, لا userInfo/fragment), ويقبل `.apk` لأندرويد, `.exe/.msi` لويندوز, مع ترتيب تفضيلي `.exe` أولاً لويندوز. لا يدعم `.zip` حالياً.
5. **مقارنة الإصدارات:** `UpdateInfo.compareVersions` — SemVer 2.0.0 صارم (Core 3 أرقام, prerelease يسبق stable, build metadata يُهمل). يرفض `01.0.0`, `1.0`, `1.0.0-alpha.01`.
6. **عرض الإشعار:** لا يوجد UI موصول حالياً — `UpdateService.checkForUpdate()` موجود لكن غير مستدعى من `settings_screen.dart` أو `app.dart`. الاختبارات تغطي المنطق فقط.
7. **التنزيل والتحقق:** `UpdateService.downloadUpdate()` يبثّ إلى ملف مؤقت فريد `scan-id-update-<id>.<ext>` عبر `UpdateTransport` (HttpClient مع متابعة redirect حتى 5, تحقق host موثوق كل خطوة), يحدّ الحجم بـ 512 MiB افتراضياً, يرفض بدون `SHA-256` صالح (64 hex) أو إذا `size` لا يطابق `Content-Length`, يحسب SHA256 أثناء البثّ, يقارن بالـ digest المعلن (`asset.digest` أو `sha256` مع بادئة `sha256:`), يحذف الجزئي عند الفشل, يدعم إلغاء `CancellationToken` عند حدود chunks.
8. **التثبيت:** `installUpdate()` يتحقق من `verifyUpdateSource()` ثم يرجع خطأ «غير مهيأ» — البناء الحالي بلا هوية ناشر/مثبّت أصلي, لذلك لا يشغّل أي مثبت (آمن fail-closed).
9. **الأخطاء:** استثناءات `HttpException`, `FormatException` للحجم/JSON غير الصالح, رسائل عربية للمستخدم. الاختبارات تغطي: انقطاع, 404, JSON فاسد, حجم زائد, digest مفقود/خاطئ, إلغاء, فراغ, إصدار غير SemVer.
10. **الاختبارات:** `ota_update_test.dart` تغطي 8 مجموعات — مقارنة SemVer, اختيار أصول GitHub, التحقق من host غير موثوق, بثّ وتدقيق SHA256, إلغاء, حدود الحجم, URLs غير HTTPS, install غير مهيأ.

**البناء والنشر الحالي:**

- `android-signed-release.yml`: يبني `flutter build apk --release` مع توثيق التوقيع (keytool, apksigner verify, aapt2 badging, فحص debuggable, مطابقة SHA256 مع المتوقّع). يرفع `scan-id-android-signed-apk` + `scan-id-android-signature-report`. لا ينشئ Tag/Release.
- `windows-release.yml`: يبني `flutter build windows --release` ويرفع مجلد `build/windows/.../Release/` كـ artifact. لا ينشئ مُثبّت/zip منفصل.
- **Releases/Tags الفعلية:** `gh api repos/.../releases` → `[]` — صفر Releases. `git ls-remote --tags` → لا شيء. لذلك OTA لن يجد إصداراً أبداً — الدورة غير مكتملة رغم وجود منطق الفحص.

### 1.3 GitHub Actions والتنظيف الحالي

- **cleanup-old-runs.yml** (83 سطر): يحذف runs المكتملة الأقدم من 24h عبر `gh api repos/.../actions/runs?per_page=100` مع pagination يدوي, يتخطى `CURRENT_RUN_ID`, لا يحذف إلا `status==completed`. صلاحيات `actions: write, contents: read`, concurrency `cleanup-old-workflow-runs`. لا يتعامل مع الفروع إطلاقاً.
- **الفروع البعيدة:** `gh api .../branches` → 19 فرعًا (`arena/*` + `searchidf`); لا PRs مفتوحة; الفرع الافتراضي الحقيقي `searchidf` (عبر `gh api repos/...` → `default_branch`). الفروع المحمية غير قابلة للقراءة عبر API الحالي (403).
- **verify.yml**: تشغيله محصور على `pull_request`, `push: [searchidf, arena/**]`, `workflow_dispatch`.
- **android-signed-release.yml**: `push: searchidf` فقط + `workflow_dispatch`, بيئة `android-signing`, صلاحيات `contents: read` (لا يستطيع كتابة Release).

---

## 2. المشكلات المؤكدة بالأدلة

| # | المشكلة | الدليل | الأثر |
|---|---|---|---|
| 1 | الدورة OTA غير مكتملة — لا يوجد Release منشور | `gh releases` فارغ, `android-signed-release.yml` بلا خطوة Release, فقط Artifacts | التطبيق لا يكتشف تحديثاً أبداً رغم منطق الفحص السليم |
| 2 | مصدر OTA يعتمد على `digest` غير مضمون قديماً | قبل 2025-06 كانت GitHub لا ترد `digest`; الأصول القديمة `digest: null` | إذا اعتمدنا digest وحده بدون fallback، تحديثات قديمة تُرفض؛ الكود الحالي يرفض بدون digest (fail-closed) — آمن لكن يمنع التحديث إذا فقدت GitHub الحقل |
| 3 | أصل Windows غير قابل للنشر كملف منفرد | `windows-release.yml` يرفع مجلداً كاملاً, OTA يقبل `.exe/.msi` فقط, لا `.zip` | Release سيحتوي مجلداً لا يمكن تحميله كأصل واحد؛ مستخدم Windows لا يحصل على ملف تحديث صالح |
| 4 | `pubspec version 0.1.0+1` لا تطابق `app.applicationVersion 0.1.0` | `pubspec.yaml: version: 0.1.0+1` vs `app.dart: applicationVersion: '0.1.0'` | Build metadata `+1` يُهمل في SemVer → `0.1.0+1 == 0.1.0` → لا يُعتبر أحدث → لا تحديث يُعرض إذا Tag `v0.1.0+1` |
| 5 | OTA غير موصول بالواجهة | `grep -r GitHubUpdateSource lib/presentation` → لا نتائج | المستخدم لا يرى زر فحص/تنزيل — الميزة خامدة |
| 6 | `cleanup-old-runs.yml` لا ينظف الفروع | الملف 83 سطر، حلقة runs فقط, لا ذكر لـ branches | الفروع `arena/*` تتراكم (19 حالياً) دون تنظيف |
| 7 | `cleanup-old-runs.yml` لا يحمي الفروع المحمية/المفتوحة/غير المدمجة | لا فحص default branch ديناميكي ولا PRs ولا protected | خطر حذف فرع نشط إذا أُضيف منطق حذف ساذج |
| 8 | لا إثبات دمج فعلي — لو أُضيف حذف بالاسم فسيكسر squash/rebase | `git merge-base` وحده لا يثبت squash merge | حذف فرع سكواتش يفقد commits فريدة |
| 9 | `android-signed-release.yml` صلاحياتها `contents: read` تمنع النشر | `permissions: contents: read` على مستوى workflow | لا يمكن إنشاء Tag/Release بدون `contents: write` |
| 10 | لا استخدام لأقل صلاحيات ولا عزل secrets | secrets التوقيع في `environment: android-signing` جيد لكن Release يحتاج صلاحية كتابة منفصلة | يجب حصر `contents: write` بمهمة النشر فقط |

---

## 3. السلوك الصحيح الذي يجب الحفاظ عليه

- توقيع Android Release لا يرجع إلى debug أبداً — حتى لو فشل حل الإضافات — ويُعاد حله مرة واحدة فقط على أخطاء الشبكة.
- مقارنة SemVer صارمة (رفض leading zeros, prerelease numeric zeros) وإهمال build metadata.
- فلترة hosts موثوقة فقط, HTTPS:443 فقط, لا userInfo/fragment, السماح بـ 5 redirects موثوقة فقط.
- حدّ حجم metadata 2 MiB وdownload 512 MiB, ملف مؤقت فريد, حساب SHA256 أثناء البثّ, حذف الجزئي عند الفشل/الإلغاء, إشعار إلغاء مرة واحدة.
- حفظ Artifacts قصير الأمد (debug 7 أيام, signed 30 يوم) لمنع استنفاد حصة التخزين (430 artifacts/5.5GB في 2026-10).
- `check_source.py` يمنع domain من استيراد Flutter/IO, يتحقق من manifest/Android backup rules, أيقونات كل الكثافات.

---

## 4. التغييرات المطلوبة وأسبابها

### المحور 1 — OTA والنشر

| الملف | التغيير | السبب |
|---|---|---|
| `lib/application/ota_update.dart` | إضافة `.zip` لويندوز, ترتيب `exe(0) > msi(1) > zip(2)`, تحديث `_isAllowedUpdateUri` ليشمل `objects.githubusercontent.com` كباث redirect | Windows portable يوزع كـ zip — بدون هذا لا يقبل OTA أصل Windows |
| `lib/application/ota_update.dart` | إبقاء `digest` إلزامي (fail-closed) لكن تحسين رسالة الخطأ وتوثيق fallback TLS-only في التعليق | الأمان: دون digest لا نثبت ملفاً قابلاً للتنفيذ |
| `lib/presentation/settings_screen.dart` + `app.dart` | ربط `GitHubUpdateSource(owner: kinanmjeed88, repo: Scan-id)` وزر «التحقق من التحديث» مع معالجة أخطاء (offline, لا يوجد إصدار, JSON غير صالح) | إظهار الميزة للمستخدم بدل بقائها خامدة |
| `.github/workflows/android-signed-release.yml` | إضافة job `publish-release` يعتمد على `android-signed-release` و`windows`, صلاحيات `contents: write`, concurrency `publish-release`, خطوات: قراءة version من pubspec, حساب tag `v<core>`, التحقق من عدم إعادة استخدام tag, إنشاء Release, رفع APK + Windows zip مع digest تلقائي من GitHub, إدخال `concurrency` لمنع النشر المتزامن | إكمال الدورة: push → checks → build → verify → Release |
| `.github/workflows/windows-release.yml` | إضافة خطوة `zip` لإنشاء `scan-id-windows-<version>.zip` من `build/windows/.../Release/` | تحويل المجلد إلى أصل واحد قابل للرفع |
| `.github/workflows/release.yml` (اختياري) | إذا فُصل النشر المتداخل, إنشاء workflow منفصل `release.yml` يُستدعى من `android-signed-release.yml` | عزل صلاحيات الكتابة |

### المحور 2 — cleanup

| الملف | التغيير | السبب |
|---|---|---|
| `tool/branch_cleanup.py` (جديد) | سكربت Python مستقل: دوال `get_default_branch()`, `list_remote_branches()`, `list_open_pr_branches()`, `list_protected_branches()`, `is_branch_merged()`, `evaluate_branch()`, `delete_branch()`, `cleanup_runs()` — معالجة pagination, rate-limit 403/429, إعادة التحقق قبل الحذف | فصل المنطق عن YAML, قابل للاختبار, مسؤوليات واضحة |
| `.github/workflows/cleanup-old-runs.yml` | إعادة كتابة لاستدعاء `tool/branch_cleanup.py`, إضافة permissions `contents: write, pull-requests: read`, checkout بعمق كامل, تمرير `GITHUB_TOKEN`, إضافة dry-run افتراضي مع `DELETE_BRANCHES=true` للحذف الفعلي, تسجيل قرار كل فرع | تنفيذ سياسة الاحتفاظ/الحذف الآمن الموثقة |
| `tool/branch_cleanup.py` | منطق إثبات الدمج: 1) `git merge-base --is-ancestor branch default` كافٍ لـ fast-forward/merge, 2) إذا فشل, فحص PRs المدمجة عبر API (`state=closed && merged_at != null && head.ref==branch`) مع مقارنة `merge_commit_sha` ancestor, 3) إذا فشل, مقارنة diff فارغ عبر `git diff default...branch` — إذا كلاهما فشل → تخطٍ | يغطي squash/rebase دون الاعتماد على أسماء |
| `test/tool/branch_cleanup_test.py` (جديد) | 14+ حالة اختبار ببيانات وهمية لـ API وgit | ضمان السياسة قبل التفعيل |

---

## 5. المخاطر وطرق منعها

| الخطر | الوقاية |
|---|---|
| حذف فرع غير مدمج / squash | إثبات ثلاثي (ancestor + PR merged + diff فارغ) — أي فشل → تخطٍ + تسجيل |
| حذف الفرع الافتراضي | جلب `default_branch` من API, مقارنته case-sensitive, تخطٍ دائم |
| حذف فرع محمي | جلب محميات عبر `/branches/{branch}/protection` (إن 403 → تخطٍ), أو `/repos/.../branches` مع `protected=true` |
| حذف فرع بPR مفتوح | جلب `pulls?state=open` وجمع `head.ref` كقائمة سوداء |
| race condition (تغيّر الفرع بين الفحص والحذف) | إعادة فحص `git rev-parse branch` + `API ETag` قبل `push --delete` |
| استنفاد rate limit | تأخير أسي 1s→2s→4s على 403/429, احترام `Retry-After`, تخطي الصفحة مع warning |
| نشر Release جزئي | `needs: [android-signed-release, windows]` + `if: success()` — لا نشر إذا فشل أي بناء أو توقيع |
| إعادة استخدام Tag | `git ls-remote --tags` قبل الإنشاء — إذا موجود → خطأ واضح, لا overwrite |
| تسريب secrets | لا طباعة قيم `KEYSTORE_*` أو `GITHUB_TOKEN` — فقط أسماء/presence, تنظيف keystore المؤقت |
| تنفيذ حذف أثناء اختبار | متغير `DRY_RUN=true` افتراضي, `DELETE_BRANCHES=true` صريح للحذف — الاختبارات لا تحذف أبداً |

---

## 6. الملفات التي ستتغير والتي يجب أن تبقى

**ستتغير:**
- `lib/application/ota_update.dart` (إضافة zip)
- `lib/presentation/settings_screen.dart`, `lib/presentation/app.dart` (ربط OTA)
- `.github/workflows/android-signed-release.yml` (إضافة publish job)
- `.github/workflows/windows-release.yml` (خطوة zip)
- `.github/workflows/cleanup-old-runs.yml` (إعادة كتابة)
- `tool/branch_cleanup.py` (جديد)
- `test/application/ota_update_test.dart` (توسيع حالات Windows zip)
- `test/tool/branch_cleanup_test.py` (جديد)

**يجب أن تبقى دون تغيير:**
- `pubspec.yaml`, `pubspec.lock` (إلا bump مقصود), `android/app/build.gradle.kts` (توقيع), `android/app/src/main/AndroidManifest.xml`, `analysis_options.yaml`, `lib/domain/*` (النموذج), `lib/imaging/*`, `lib/persistence/*`, `lib/export/*`, `tool/check_source.py` (سياسة domain).

---

## 7. خطة الاختبارات والتحقق

### اختبارات OTA (توسيع موجود)

- Android APK فقط, Windows exe/msi/zip, رفض host غير موثوق, لا تحديث إذا `tag <= current`, إهمال build metadata, tags `v` و`release-` وprerelease, لا ملف مناسب → null, JSON فاسد → null, 404 → exception, offline → exception, حجم >512MiB → رفض, digest مفقود → رفض, re-download بعد فشل digest → حذف جزئي.

### اختبارات branch_cleanup (12 حالة إلزامية + 5 runs)

1. فرع مدمج بالكامل (ancestor) → مؤهل للحذف
2. فرع بcommit غير مدمج → احتفاظ
3. squash merge سابق مع تغيير غير مدمج حالياً → احتفاظ
4. PR مفتوح → احتفاظ
5. default branch → احتفاظ
6. محمي → احتفاظ
7. لا يمكن جلب بياناته → تخطٍ
8. فشل API/rate limit → لا حذف
9. تغيّر branch بين الفحص والحذف → إعادة فحص → تخطٍ
10. pagination (150 فرع) → كل الصفحات تُفحص
11. أسماء Agents عشوائية → نفس السياسة
12. runs قيد التشغيل → لا حذف, completed+قديم → حذف
13. فشل بناء Android → لا Release
14. غياب APK/exe → لا Release
15. نجاح Release → أصوله تطابق ما يتوقعه التطبيق (apk + zip)
16. لا يوجد إصدار أحدث → لا تحديث وهمي
17. JSON غير صالح → معالجة دون تعطّل
18. digest مفقود → رفض التنزيل

### تحقق نهائي

- `dart format --output=none --set-exit-if-changed .` — نظيف
- `flutter analyze --fatal-infos` — صفر أخطاء جديدة
- `flutter test --reporter expanded` — كل الاختبارات خضراء (626+ موجودة + جديدة)
- `flutter build apk --debug` — نجاح (بدون secrets)
- `flutter build windows --release` (إن توفرت الأدوات) — أو توثيق العائق
- `yamllint` / `actionlint` لصحة YAML
- `gh workflow run` — فحص سجلات آخر commit, إصلاح أي فشل حتى خضرة كاملة
- `git diff --stat` — فقط الملفات المطلوبة

---

## 8. ما تم التحقق منه فعليّاً وما تعذّر

| البند | الحالة |
|---|---|
| قراءة بنية المشروع وworkflows | مكتمل — 2026-10-16 08:48 UTC |
| `gh api repos/...` default_branch=searchidf, 0 releases, 19 branch | مكتمل |
| وجود `ota_update.dart` ومنطقها | مكتمل |
| انعدام Releases كسبب عدم اكتشاف التحديث | مؤكد |
| توفر `digest` في Releases الجديدة (2025-06) | موثّق من changelog GitHub, غير مختبر على هذا المستودع لعدم وجود Release |
| بناء APK موقّع بدون secrets يفشل كما يجب | موثّق في verify.yml signing-guard, غير منفذ محلياً لعدم توفر secrets |
| حذف فروع حقيقي أثناء الاختبار | لم يُنفذ — سياسة DRY_RUN |

---

*هذا التقرير يسبق أي تعديل كودي — التالي: تنفيذ المحورين مع احترام القواعد الحاكمة (السلامة أولاً, تخطّ عند الشك).*
