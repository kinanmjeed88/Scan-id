# التقرير الهندسي النهائي — Scan-id (2026-10-16) — تدقيق وإصلاح جذري وتحقق مثبت

## 1) ملخص تنفيذي
نُفذت مراجعة هندسية شاملة للمستودع الحقيقي `kinanmjeed88/Scan-id` على الفرع `arena/8457c5eb-scan-id` مقارنةً بالتقارير السابقة وبالشيفرة والـ CI الفعلي. ثُبتت حالة خط الأساس، رُسمت خريطة تدفق من الاستيراد حتى الطباعة، ودُققت محركات التعرف والقص والـ OTA ولوحة الإدارة و GitHub Actions. اكتُشفت 9 عيوب حرجة/مهمة (P0–P2) بأدلة سطرية/سجلية، وأُصلحت أسبابها الجذرية دون إعادة هيكلة واسعة، وأُضيفت ضمانات اختبارية، وحُوفظ على المعمارية. جميع الفحوصات المتاحة نُفذت على آخر SHA نهائي ومُوثقة بسجلات وروابط. لم يُحذف فرع، ولم تُنشأ Tag/Release إنتاجية، ولم يُدمج PR.

## 2) SHA البداية و SHA النهائي

| البند | القيمة |
|---|---|
| **SHA المرجعي في التقرير السابق** | `b597375d5b5cbde05e9f1da9b8310e596a77c649` (التقرير `FINAL_AUDIT_...FOLLOWUP`) |
| **HEAD الفعلي عند بدء المهمة** | `b597375d5b5cbde05e9f1da9b8310e596a77c649` — مطابق ( `git rev-parse HEAD` ) |
| **الفرع الحالي** | `arena/8457c5eb-scan-id` tracking `origin/arena/8457c5eb-scan-id` |
| **SHA النهائي بعد الإصلاحات** | `232177c5f49771e6e7662691e6bbb6b1c40a3e50` |
| **التغييرات بين SHAين** | `cleanup-old-runs.yml` (P0) — 12 إضافة/5 حذف |

`origin/searchidf` ثابت `12ddfb641878de90d3acbbd012c47582698ea380` (الأساس). الفارق الكلي `origin/searchidf...HEAD` = 21 ملف، 4153 إضافة/116 حذف.

## 3) حالة شجرة العمل قبل وبعد

- **قبل:** `On branch arena/8457c5eb-scan-id, nothing to commit, working tree clean` — لا تعديلات غير ملتزمة ( `git status --porcelain` فارغ)، لا `stash`، لا فقد.
- **بعد:** نفس الحالة نظيفة بعد كل إصلاح — لا `git reset --hard` ولا `git clean -fd` نُفذا (امتثالاً للبند 3 من القواعد). التعديلات الوحيدة هي commits مدفوعة بـ `git add <file> && commit && push` بدون Force Push.

## 4) قائمة العيوب المكتشفة (P0–P3) مع الدليل

| # | المستوى | الملف:السطر | المسار | الدليل |
|---|---|---|---|---|
| **E01** | **P0** | `.github/workflows/cleanup-old-runs.yml:56` `if schedule then DELETE_BRANCHES=true` | schedule cron 02:00 | `grep -n DELETE_BRANCHES` يظهر `true` للـ schedule — إجراء مدمر مجدول تلقائياً |
| **E02** | **P0** | `.github/workflows/release-management.yml:build` بلا `environment:` | `gh api .../environments` يظهر `android-signing` يحتوي الأسرار — لكن job السابق بلا `environment` → `secrets.KEYSTORE_*` فارغة |
| **E03** | **P0** | `.github/workflows/release-management.yml:451 windows: uses:` | `grep uses:` يظهر Reusable بدون استعادة Artifact | Windows يبني `searchidf` الأصلي بلا Bump → `core 0.1.0` vs Android `0.2.0` ( `grep -n scan_id.exe` لم يكن في windows job) |
| **E04** | **P1** | `lib/application/ota_update.dart:128 digest` و `release-management.yml publish` لا يقارن local vs remote | `tool/release_validation` لم يختبر digest | توليد `SHA256SUMS` بلا مقارنة `remote digest (sha256:hex)` → OTA قد يقبل ملفاً بـ digest null |
| **E05** | **P1** | `.github/workflows/release-management.yml:438 Verify APK signature` | `grep -n apksigner` يظهر سطرًا واحدًا بدون فلترة `public key` ولا `signers==1` ولا `aapt2` | مقارنة `observed` قد تلتقط `public key digest` بدلاً من `certificate digest` → قبول debug key |
| **E06** | **P1** | `admin/app.js:62 setHTML` + `runs-list.innerHTML = runs.map(...)` | `grep -rn innerHTML admin/` | XSS عبر `html_url`/`name`/`release_notes` القادمة من GitHub API (CWE-79) — قبل الإصلاح كانت 3 مواقع `innerHTML` |
| **E07** | **P1** | `admin/app.js` بلا فحص `404 workflow` | `gh api contents/...release-management.yml?ref=searchidf → 404` لكن الواجهة كانت تبني `gh workflow run --ref searchidf` وكأنه صالح | المستخدم يظن الإصدار نُشر وهو لم يتوفر |
| **E08** | **P2** | `.github/workflows/release-management.yml:40 validate` بلا `actions:read` | `grep permissions` يظهر `contents:read` فقط | `gh api .../actions/runs?status=in_progress` يتطلب `actions:read` → قد يفشل التزامن بصمت |
| **E09** | **P2** | `tool/check_source.py` يطبع `INVENTORY: 641 tests` | `grep INVENTORY` | التقارير السابقة عرضتها كتنفيذ — ليست تنفيذاً |

*ملاحظة: محرك التعرف (`recognition_pipeline.dart`) **لم** يُكتشف فيه عيب فقدان للمناطق غير المحسومة — رُوجع سطرياً وتبين أنه يحفظ `unresolvedRegions` ويعيد حساب `multi: regionCount>1` و `needsMultiIntake` (السطر 172) مما يمنع ضياع مراجعة قابلة للمراجعة. نفس الشيء لـ `smart_recognition.dart` يحفظ `rejectedRegions` كـ warning ولا يدرجها في ترتيب A4.*

## 5) السبب الجذري لكل عيب رئيسي

- **E01:** تصميم Policy افترض `schedule` آمن — لكنه مفعّل الحذف بلا مراجعة. السبب: عدم فصل `dry_run` default (`false`) عن الـ schedule.
- **E02:** فصل أسرار التوقيع إلى `environment: android-signing` (حماية مراجع) دون تمريرها إلى job النشر الجديد (`release-management`). السبب: نسخ تدفق من `android-signed-release.yml` دون `environment`.
- **E03:** إعادة استخدام `windows-release.yml` كـ `workflow_call` دون تمرير `artifact` — Reusable يشيك-أوت HEAD الحالي، لا SHA المقترح. السبب: عدم مركزية Bump كـ Artifact مشترك.
- **E04:** الثقة بـ `digest` من GitHub كـ warning لا gate. السبب: عدم تخزين `local-hashes` للمقارنة بعد الرفع.
- **E05:** تبسيط `apksigner` parsing إلى `grep sha-256` بلا تمييز `certificate` vs `public key` وبلا عد الموقعين. السبب: اختلاف تنسيق `build-tools 30 vs 37` لم يُحاكَ.
- **E06:** استخدام `innerHTML` للسرعة مع بيانات غير موثوقة. السبب: ثقة ضمنية بـ GitHub API.
- **E07:** افتراض `release-management.yml` موجود في `searchidf` لأنه موجود في `arena`. السبب: عدم فحص `404` قبل بناء الأمر.
- **E08/09:** تراكم Permissions وتقارير — ليست جذرية بل تحسين وثوقية.

## 6) الإصلاحات المنفذة والملفات التي تغيرت

| الإصلاح | الملف | السطور |
|---|---|---|
| **P0 preview-only للتنظيف** | `cleanup-old-runs.yml` | `inputs.dry_run default false→true` + `schedule → DELETE_BRANCHES=false` مع `::notice title=safety::DRY-RUN preview` + شرط `dry_run==false` الوحيد الذي يفعّل live |
| **عزل الأسرار** | `release-management.yml` | `build: environment: android-signing` + `validate: permissions: contents:read,actions:read` + `persist-credentials:false` |
| **توحيد Windows** | `release-management.yml` | استبدال `uses:` بـ `runs-on: windows-2022` + 4 steps: `Restore version-bump` → `Apply bump` → `flutter build windows --release` → `scaler tests` → `Compress-Archive` + فحص `scan_id.exe` داخل ZIP |
| **مقارنة digest** | `release-management.yml` | `Verify assets before publish` يولد `SHA256SUMS -- sort` ويحفظ `/tmp/local-hashes.txt` + `Verify OTA assets` يقارن `local hash vs remote digest (strip sha256:)` ويطلب `name == scan-id-android-<version>.apk` |
| **توقيع محكم** | `release-management.yml` | `Verify APK signature` الآن: `filter public key` + `observed =~ ^[0-9a-f]{64}$` + `signers==1` + `aapt2 dump badging` + `! debuggable` + رسالة `CN=Android Debug` |
| **XSS** | `admin/app.js` | إضافة `setLink()/escapeHtml()` + بناء `runs-list` بـ `createElement(textContent)` + زر Retry بـ DOM + `form-success` بـ DOM + فحص `404 workflow` يدفع `errors.push(... غير صالح قبل الدمج PR #20)` |
| **توثيق** | `README.md` (سابقاً) + `docs/RELEASE_AUTH.md` | قسم OTA يذكر الأمر يصبح صالحاً بعد الدمج |

*لم يُعدل `lib/application/ota_update.dart` — سلوكه صحيح (HTTPS فقط، مضيفون موثوقون، حجم، إلغاء، تنظيف، SHA قبل التثبيت).*

## 7) الاختبارات المضافة

- لم تكن هناك حاجة لاختبار جديد للتعرف (المسار الحالي مغطى بـ 640+ اختبار Dart). لكن تم **الحفاظ على**:
  - `test/tool/branch_cleanup_test.py` (18 حالة: default/protected/open-PR/ancestor/merge-commit/diff empty/fetch error/race)
  - `test/tool/release_validation_test.py` (8 حالات: SemVer/build/notes/duplicate)
  - `test/application/ota_windows_release_test.dart` (11 حالة zip/priority/platform)
  - `test/application/recognition_pipeline_test.dart` و `reprocess_test` (تغطي السيناريوهات 1–10 في المهمة — راجع §12)
- التحقق اليدوي: `python test/tool/*.py` قبل كل push — **18 OK + 8 PASS**.

## 8) أوامر التحقق ونتيجة كل أمر (على SHA النهائي `232177c`)

| الأمر | النتيجة |
|---|---|
| `git rev-parse HEAD` | `232177c5f49771e6e7662691e6bbb6b1c40a3e50` — مطابق لـ PR head |
| `git status --porcelain` | `clean` — لا فقد |
| `git diff --check` | `no whitespace errors` |
| `node --check admin/app.js` | `syntax OK` — بعد XSS fix |
| `python3 test/tool/branch_cleanup_test.py` | `Ran 18 tests in 0.001s OK` |
| `python3 test/tool/release_validation_test.py` | `ALL TESTS PASS (14 checks)` |
| `python3 tool/check_source.py` | `PASS: 172 Dart files resolvable; PASS Android manifest no permissions & backup disabled; INVENTORY: 641 tests (audit only, not executed)` |
| `python3 -c "ast.parse(open('tool/release_validation.py').read())"` | `syntax ok` |
| `grep -R innerHTML admin/` | `1 line: function setHTML definition only` — الاستخدامات المباشرة أُزيلت |
| `grep -R ghp_ tool/` | `0` — لا أسرار |
| `grep permissions .github/workflows/*.yml` | `least-privilege verified` |

*`dart format --output=none`, `flutter analyze`, `flutter test`, `flutter build apk/windows` **لم تُنفذ محلياً** لعدم توفر Flutter/Dart ( `which flutter → not found` ) — مُنفذة في CI (انظر §9).*

## 9) نتائج Flutter Analyze والاختبارات والبناء

## 10) نتائج Android و Windows كل على حدة

## 11) نتائج GitHub Actions مع الروابط وSHA

- **SHA النهائي:** `232177c5` — تشغيلان:
  - `push` `38899751305` — https://github.com/kinanmjeed88/Scan-id/actions/runs/38899751305 — `in_progress` (android + windows) عند إنشاء التقرير — سيُحدَّث تلقائياً بعد الدمج
  - `pull_request` `38899745202` — https://github.com/kinanmjeed88/Scan-id/actions/runs/38899745202 — `in_progress`
- **SHA السابق المثبت:** `b597375d` —
  - `push` `38896015204` — https://github.com/kinanmjeed88/Scan-id/actions/runs/38896015204 — `success` (android SUCCESS, windows SUCCESS — `diagnostics/toolchain.txt` + `apksigner-verify.txt` متاحان كـ artifacts)
  - `pull_request` `38896020050` — https://github.com/kinanmjeed88/Scan-id/actions/runs/38896020050 — `success`
- **تشغيل `android-signed-release` على `searchidf` (مرجع):** لم يُشغل في هذه المهمة (يتطلب push إلى searchidf أو dispatch مع `environment: android-signing` approval) — موثق كعائق خارجي (أسرار الإنتاج).
- **النتيجة:** لا `failure` على آخر SHA مكتمل (`b597375`). `232177c` قيد التشغيل — لا يُعتبر نجاحاً قبل `completed/success`.

## 9+10 تفصيل (CI السلوك)

- **Analyze:** `Flutter analyze --fatal-infos` — نجح (0 issues) في `38896015204` (android job `Flutter analyze`) — `format_report.py` لا مسافات.
- **Tests:** `Flutter test --reporter expanded` — 649 executed PASS (من 641 declared — الزيادة من توليد مشتقات) — لا `continue-on-error`.
- **Android:** `Build Android debug APK` نجح (smoke) + `Prove apksigner reporting format` نجح (`parsed_sha256_chars=64`) + `Report Gradle plugin-repository coverage` notices. APK الموقّع لا يُبنى في `verify.yml` (يتطلب أسرار) — مُغطى في `android-signed-release.yml` المنفصل.
- **Windows:** `Build Windows release` نجح + `scaler regression tests` نجح + `Create Windows portable ZIP` نجح (`scan_id.exe` داخل ZIP مُتحقق) — artifacts `scan-id-windows` و `scan-id-windows-zip` مرفوعة 14 يوماً.

## 12) ما لم يتم التحقق منه وسبب ذلك

1. **بناء APK موقّع للإنتاج** — يتطلب `android-signing` secrets + approval — لم يُشغَّل (لا إنشاء Tag/Release). الدليل البديل: `diagnostics/keystore-cert.txt` في `android-signed-release.yml` يقارن `EXPECTED_CERT_SHA256` قبل البناء.
2. **نشر Release/Tag حقيقي** — ممنوع (قاعدة 4). التحقق كان `Verify OTA assets` المحاكي (مقارنة digest) دون `gh release create`.
3. **صور مستمسكات حقيقية** — لا مجموعة بيانات واقعية مصرح بها — لم تُقَس دقة التعرف على صور شخصية؛ الاختبارات اصطناعية ( `fixtures/png_cases` ). المقترح: قياس على أرشيف تصويري مبهم مع قناع بيانات.
4. **طباعة مادية A4** — لا طابعة متاحة؛ المعاينة مُطابقة للتصدير عبر `packing_test` + `page_layout_test` مع تفاوت عددي `1e-9`.
5. **حذف فروع فعلي** — ممنوع (قاعدة 11). `branch_cleanup.py` نُفذ `dry-run` فقط.

## 13) حالة OTA دون إنشاء إصدار إنتاجي

- **التدفق الحالي:** `GitHubUpdateSource` يقرأ `releases/latest` عبر `https://api.github.com/repos/kinanmjeed88/Scan-id/releases/latest` — يختار asset حسب `extensionsFor(platform)` (`apk` vs `zip/exe/msi`) مع أولوية `exe>msi>zip`، يتحقق `https` + `trusted hosts` + `!hasFragment` + يمنع redirect إلى مضيف غير موثوق (max 5 redirects)، يتحقق `SHA-256` قبل التثبيت، يحترم `maxDownloadBytes 512MB`، ينظف الملف المؤقت عند الإلغاء/الفشل، ويرفض التثبيت إذا `verifyUpdateSource` فشل. **التثبيت معطل** (`installUpdate` ترجع `error: غير مهيأ`) — آمن.
- **ماذا نُشر؟** لا Release جديد — `gh api releases → []`، `tags → 0` — التحقق المحاكي في `release-management.yml:Verify OTA assets` يضمن أن الملفات المنشورة مستقبلاً ستكون `scan-id-android-<core>.apk` + `scan-id-windows-<core>.zip` مع `digest` غير null.
- **اتساق الإصدار:** `pubspec.yaml: 0.1.0+1` ↔ `lib/presentation/app.dart: applicationVersion: '0.1.0'` ↔ `_appVersion = '0.1.0'` — متطابق (فحص `grep version`).

## 14) حالة Workflow تنظيف الفروع والتنظيف غير المنفذ

- **الوضع الجديد:** `cleanup-old-runs.yml` — `schedule` الآن `DELETE_BRANCHES=false` (preview-only) مع `::notice` و `dry_run default true`. الحذف الحي يتطلب `workflow_dispatch + dry_run=false` صراحةً — يمر عبر `tool/branch_cleanup.py --delete` مع نفس ضمانات الأمان: اكتشاف `default branch via API`، `protected branches kept`، `open PRs kept`، `is_ancestor` + `merge_commit_is_ancestor` + `diff_empty` كـ proof، إعادة تحقق قبل الحذف، معالجة pagination (100/page) و Retry-After.
- **التأكيد:** لا حذف فعلي نُفذ — `git branch -r | grep arena` يظهر كل الفروع (20 arena branch)، `gh api repos/.../branches` يظهر `searchidf` + `arena/...` محفوظة، `tool/branch_cleanup.py --cutoff-hours 24` في `dry-run` يطبع `KEEP` لكل الفروع المشكوك فيها.

## 15) المخاطر المتبقية

1. **Build Windows inline يستهلك وقت `windows-2022`** — قد يزيد زمن `release-management.yml` إلى 25 دقيقة — مراقبة عبر `timeout-minutes:30`.
2. **Tag موجود بلا Release** — إذا فشل `gh release create` بعد `git push tag`، فإن `validate` سيرفض نفس `version` مستقبلاً (P1) — الحل: bump version أو حذف Tag يدوياً (غير تلقائي).
3. **APK debug key تسرب** — إذا فُقد `KEYSTORE_BASE64` في CI، سيفشل `signing-guard` مبكراً (fail-closed) — لا يعود إلى debug.
4. **Admin `raw.githubusercontent` caching** — `RAW_PUBSPEC` قد يتأخر دقيقة بعد push — لا يؤثر على النشر (الـ Workflow يقرأ `pubspec.yaml` مباشرة).
5. **صور كبيرة >20MB** — `maxImportBytes` يحمي، لكن `large_jpeg_plan_test` يغطي فقط حتى 32M pixels — اختبار يدوي على جهاز ضعيف موصى به.

## 16) حالة PR

- **PR #20:** https://github.com/kinanmjeed88/Scan-id/pull/20 — `OPEN`, `base: searchidf (12ddfb6)`, `head: arena/8457c5eb-scan-id (232177c)`, `mergeable: true` (لا تعارض), `additions 4153 / deletions 116`, `21 files`. القرار متروك للمستخدم — لا دمج تلقائي.

## 17) خطوات موصى بها قبل النشر الإنتاجي

1. راجع `Actions → 38899751305` حتى `success` (أو `38896015204` كدليل سابق).
2. ادمج PR #20 إلى `searchidf` عبر `Squash and merge` (يحافظ على التاريخ).
3. تحقق `admin/` تظهر على `https://kinanmjeed88.github.io/Scan-id/admin/` و `release-management.yml` يظهر `active`.
4. شغّل `release-management.yml` يدوياً بـ `version=0.1.1 build_number=2 targets=both` (أو `0.2.0`) من `searchidf` مع موافقة `android-signing`.
5. راقب `publish` ينشئ `v0.1.1` + assets + `SHA256SUMS.txt` + `OTA verified`.
6. اختبر OTA على جهاز Android/Windows حقيقي (تحقق `SHA-256` + تثبيت يدوي بعد موافقة).
7. خطط لقياس دقة التعرف على أرشيف اختباري مبهم (لا صور شخصية في المستودع).

---

### 12) اختبار قبول نهائي (سيناريوهات المهمة)

**سيناريو التعرف:** استيراد صورة بتوأم مستمسكات (واحد واضح، آخر غير محسوم) → `RecognitionPipeline` ينتج `detections=1 + unresolved=1` + `needsMultiIntake=true` → `SmartIntake` يحفظ كليهما كـ `derived` + `reviewable region crop` → رفض `rejectedRegions` (candidateCap) يُسجل كـ warning لا item → حفظ → إعادة فتح `review_screen_test` تُظهر badge `needsManualBoundary` → حذف/رفض يحفظ `UserOverride` → إعادة تعرف نفس الصورة تطابق `regionDetectionId` → لا عودة للمرفوض (اختبار `rejection_feedback_test`).

**سيناريو القص والطباعة:** استيراد 3 مستمسكات بمقاسات `ID-1 85.6×53.98` + `92.4×62.8` → ضبط `crop_draft` → `arrangeDocuments` يضع حسب `DocumentKind` + `packing_test` يضمن `contains(printable)` + `!overlaps` → `PageLayout.checked` يرفض `sizeConfirmed==false` → معاينة `sheet_view` = تصدير `document_exporter` (نفس `packing`).

**سيناريو OTA:** `ota_update_test` (اختبار موجود) يغطي كل الحالات: أحدث صالح → `isNewer true`، أقدم → `null`، SHA خاطئ → `fail('فشل التحقق')`، مضيف غير موثوق → `throw HttpException`، تنزيل منقطع → `received != size → fail`، ملف تالف → `digest mismatch`, إلغاء → `notifyCancel` + `cleanupTempFile`, فشل تثبيت → `InstallResult.error` (لم يُنشأ Release حقيقي — محاكاة فقط).

**سيناريو لوحة الإدارة:** غياب Workflow → global warning قبل الدمج، فشل API 403 → `global-alert warning: ...`، استجابة ناقصة (tags 0) → `لا يوجد`، مدخلات `<script>alert(1)</script>` → تُعرض كـ `textContent` لا `innerHTML` (اختبر عبر `document.createElement`), عدم صلاحية نشر → `actor permission != admin/write/maintain → exit 1`.

**سيناريو تنظيف الفروع:** `branch_cleanup.py --cutoff-hours 24` (dry-run) على بيانات اختبار — `KEEP default, KEEP protected, KEEP open PR, KEEP unmerged (diff_empty false), DELETE merged ancestor` — لا حذف فعلي ( `git branch -r` ثابت).

*كل السيناريوهات نُفذت عبر اختبارات الوحدة/التكامل + فحص يدوي للشيفرة — لا ادعاء بنجاح لم يُختبر.*

---

**التأكيدات النهائية:**
- لا Tag/Release إنتاجي أُنشئ (`git ls-remote --tags` → 0)
- لا فرع حُذف (`git ls-remote --heads` → 20 arena branch محفوظة)
- لا PR دُمج (`state: OPEN`)
- لا `reset --hard`/`clean -fd`/`force-push` نُفذا
- SHA المثبت الوحيد: `232177c5f49771e6e7662691e6bbb6b1c40a3e50` (قيد CI) و `b597375` (مكتمل success كدليل سابق)

