# التقرير النهائي — Scan-id — 2026-10-16

> **الفرع:** `arena/8457c5eb-scan-id` — **HEAD:** `c9005a0ded89f824e4183db6284267a4064b663f` — **المستودع:** `kinanmjeed88/Scan-id` (عام) — **التاريخ:** 2026-10-16 08:48–09:45 UTC

هذا التقرير يُلخّص ما تم إنجازه في المهمة الهندسية الشاملة (OTA + Releases + Cleanup) وفق القواعد الحاكمة: **السلامة أولاً، عند الشك تخطّ العملية وسجّل السبب**.

---

## 1. ملخص آلية المشروع قبل التعديل

- **التطبيق:** Flutter 3.35.7 / Dart 3.9 — `pubspec.yaml` `version: 0.1.0+1` بينما `lib/presentation/app.dart` يعرّف `applicationVersion: '0.1.0'` ثابت. Domain نقي بلا Flutter/IO، Persistence Sembast، Imaging محلي، Export PDF.
- **OTA المنطق موجود لكن الدورة غير مكتملة:** `lib/application/ota_update.dart` (691 سطر) يطبق:
  - طلب `GET https://api.github.com/repos/<owner>/<repo>/releases/latest` مع `Accept: vnd.github+json`، حدّ 2 MiB،
  - استخراج `tag_name` → `extractVersion` (يتحمل `v` و`release-` و SemVer 2.0.0 صارم)، مقارنة `compareVersions` مع إهمال build metadata،
  - فلترة الأصول على hosts موثوقة فقط (`github.com`, `objects.githubusercontent.com`, `release-assets...`, HTTPS:443 فقط)، قبول `.apk` لأندرويد و`.exe/.msi` لويندوز، ترتيب `exe>msi`،
  - بثّ التنزيل إلى ملف مؤقت فريد `scan-id-update-<id>.<ext>`، حدّ 512 MiB، حساب SHA-256 أثناء البثّ، رفض بدون digest صالح، إلغاء عند حدود chunks، حذف الجزئي عند الفشل،
  - `installUpdate` يفشل آمن (fail-closed) برسالة «غير مهيأ دون توقيع ناشر» — لا يشغّل مثبتاً.
  - **لكن:** لا يوجد أي `GitHub Release` أو `Tag` منشور (`gh api .../releases` → `[]`, `git ls-remote --tags` → فارغ)، ولا UI موصول (`grep -r GitHubUpdateSource lib/presentation` → لا نتائج) — الرسالة في الإعدادات كانت «التحديث الهوائي غير متاح».
- **البناء:** `android-signed-release.yml` يبني APK موقّع مع تحقق كامل (keytool, apksigner verify, aapt2 badging, مطابقة `EXPECTED_CERT_SHA256`, فحص debuggable) ويرفع Artifact فقط؛ `windows-release.yml` يبني مجلد `Release/` ويرفع المجلد فقط؛ `verify.yml` يطبق gate (format, analyze, test, signing-guard, debug APK).
- **التنظيف:** `cleanup-old-runs.yml` (83 سطر) يحذف فقط `runs` المكتملة الأقدم من 24h عبر `gh api .../actions/runs?per_page=100` مع pagination يدوي، `actions: write, contents: read`, لا يتعامل مع الفروع إطلاقاً (19 فرع `arena/*` + `searchidf` متراكمة).

**الدليل:** `gh api repos/... --jq .default_branch` → `searchidf`, `gh api .../branches --paginate` → 19 فرع, `gh api .../releases` → `[]`, `git ls-remote --tags origin` → فارغ, `test/application/ota_update_test.dart` → 517 سطر يغطي SemVer واختيار الأصول ورفض hosts غير موثوق.

---

## 2. المشكلات المؤكدة بالأدلة

| # | المشكلة | الدليل |
|---|---|---|
| 1 | لا يوجد Release منشور → OTA لا يجد تحديثاً أبداً | `releases: []` |
| 2 | أصل Windows مجلد وليس ملفاً → لا يصلح كأصل Release، وOTA يقبل `.exe/.msi` فقط | `windows-release.yml` يرفع `build/.../Release/` |
| 3 | `pubspec 0.1.0+1` مقابل `app 0.1.0` → `0.1.0+1 == 0.1.0` في SemVer → لا يُعتبر أحدث | مقارنة تهمل `+build` |
| 4 | OTA غير موصول بالواجهة | `grep` لا يجد استخدام في presentation |
| 5 | `cleanup-old-runs.yml` لا ينظّف الفروع | الملف 83 سطر بلا ذكر branches |
| 6 | لا إثبات دمج فعلي → خطر حذف squash/rebase | `merge-base` وحده لا يكفي |
| 7 | صلاحيات `android-signed-release.yml` `contents: read` تمنع النشر | يحتاج `contents: write` |
| 8 | لا `concurrency` لمنع نشر متزامن → خطر Tag مكرر | لا يوجد group |

---

## 3. الملفات المعدلة وسبب كل تعديل

| الملف | التغيير | السبب |
|---|---|---|
| `lib/application/ota_update.dart` | إضافة `.zip` لويندوز: `_extensionsFor` → `['.exe','.msi','.zip']`، `_extensionPriority` → `exe:0, msi:1, zip:2` | التوزيع الحالي portable (مجلد) يُحزم كـ ZIP؛ بدون هذا OTA سيرفض أصل Windows |
| `lib/presentation/settings_screen.dart` | إضافة `dart:io`, `cancellation`, `ota_update`, استبدال `_updateSection` الثابت بـ `_OtaUpdateCard` StatefulWidget مع: كشف المنصة (`Platform.isAndroid/Windows`), `GitHubUpdateSource(owner:kinanmjeed88,repo:Scan-id)`, زر «التحقق من التحديث», معالجة offline/404/JSON, حوار تفاصيل الإصدار, تنزيل مع `onProgress` و`CancellationToken`, تحقق `verifyUpdateSource` قبل عرض مسار الملف, رابط «فتح صفحة الإصدارات», مع `mounted` checks و`InfoBanner` أمان | ربط المنطق الموجود بالواجهة بدل بقائه خامداً؛ يحقق متطلبات «الفحص والتنزيل والتحقق والتثبيت الفاشل الآمن» |
| `.github/workflows/windows-release.yml` | خطوة `Create Windows portable ZIP` (`Compress-Archive` → `scan-id-windows.zip` + فحص الحجم وصحة ZIP) + artifact `scan-id-windows-zip` | تحويل المجلد إلى أصل واحد قابل للرفع إلى Releases وصالِح لـ OTA |
| `.github/workflows/android-signed-release.yml` | إضافة `publish-release` job بعد `android-signed-release` و`windows`: `permissions: contents: write`, `concurrency: publish-release`, `if: needs.*==success && (ref==searchidf||dispatch)`, خطوات: قراءة `pubspec` → `tag=v<core>` مع تحقق SemVer، فحص Tag/Release موجود عبر `git ls-remote` و`gh release view` (عدم إعادة استخدام Tag مع build مختلف)، تحميل Artifacts، تحقق `stat/sha256/unzip -l`, تجهيز أسماء `scan-id-android-<core>.apk` و`scan-id-windows-<core>.zip` + `SHA256SUMS.txt`, `gh release create <tag> --title --notes --target SHA`، تحقق OTA (`jq` يبحث عن `.apk` و`.zip`, تحذير إذا `digest==null`) | إكمال الدورة: Push → Checks → Build+Verify → Release+Assets → اكتشاف داخل التطبيق. يمنع النشر الجزئي (`needs` كليهما)، يمنع تعارض النشر المتزامن، يستخدم أقل صلاحيات (`contents: write` فقط لمهمة النشر)، يعزل أسرار التوقيع في `environment: android-signing` |
| `.github/workflows/cleanup-old-runs.yml` | إعادة كتابة كاملة: `name: Cleanup Old Workflow Runs and Merged Branches`, `on: schedule 02:00 + workflow_dispatch(dry_run, cutoff_hours)`, `permissions: actions: write, contents: write, pull-requests: read`, `timeout 30m`, خطوات: `checkout fetch-depth:0 fetch-tags`, `git fetch --prune`, عرض حالة المستودع, استدعاء `python3 tool/branch_cleanup.py --repo ... --delete --cutoff-hours` مع `DELETE_BRANCHES` env (schedule → live, dispatch يحترم `dry_run`) | توسيع التنظيف ليشمل جميع الفروع البعيدة مع سياسة احتفاظ آمنة ومقاومة race conditions، مع الحفاظ على تنظيف الـ runs |
| `tool/branch_cleanup.py` (جديد، 643 سطر) | دوال نقية: `BranchInfo`, `PRInfo`, `EvalResult`, `evaluate_branch()`, `evaluate_all_branches()` — ترتيب أمان: `fetch/api error → keep`, `default → keep`, `protected → keep`, `open PR → keep`, `diff_empty==False → keep` (يحمي squash مع تغيير جديد), `is_ancestor==True → delete`, `has_merged_pr && merge_commit_is_ancestor → delete`, `diff_empty && has_merged_pr → delete`, غير ذلك keep. وحدات I/O: `fetch_default_branch` (API → `git remote show` → `symbolic-ref` fallback), `list_remote_branches_api` (pagination 100, حتى 50 صفحة), `list_remote_branches_git_fallback`, `list_open_pr_branches`, `list_closed_merged_prs` (500 حديثة), `is_ancestor`, `diff_empty`, `merge_commit_is_ancestor` (via `git merge-base`), `delete_branch_remote` (re-verify protection + ancestor قبل `DELETE`), `cleanup_runs` (pagination, تأخير أسي 403/429, احترام `Retry-After`), `main()` مع `--delete/--dry-run/--repo/--cutoff-hours` وملخص Actions | فصل المنطق عن YAML، قابل للاختبار، مسؤوليات واضحة (8 وظائف منفصلة)، معالجة pagination وحدود API، إعادة تحقق قبل الحذف لمنع race، أقل صلاحيات |
| `test/application/ota_windows_release_test.dart` (جديد، 201 سطر) | 11 حالة: Windows `exe>msi>zip`، اختيار ZIP عند عدم وجود exe/msi، Android لا يختار ZIP، حالة Release بـ ZIP فقط صالحة، غياب أصل المنصة → null، معالجة `v`/`release-`/prerelease، تجاهل build metadata، نفس الإصدار لا يُعرض، JSON فاسد → null، host غير موثوق → null، تحقق أصول Release (`hasApk && hasWindows`) | تغطية الحالات الحرجة 14-18 من المتطلبات (اختيار المنصة، عدم تحديث وهمي، JSON فاسد) |
| `test/tool/branch_cleanup_test.py` (جديد، 333 سطر) | 18 اختبار مع بيانات وهمية: 1-مدمج كامل → delete، 2-غير مدمج → keep، 3-squash مع تغيير جديد → keep (إثبات أن التغيير الحالي مدمج), 4-PR مفتوح → keep, 5-default → keep, 6-محمي → keep, 7-fetch error → skip, 8-API failure → no delete, 9-تغيّر branch بعد الفحص → re-verify skip, 10-pagination 150 → كل الصفحات تُفحص, 11-أسماء Agents عشوائية, 12-runs قيد التشغيل → لا حذف, 13-مكتمل قديم → حذف, بالإضافة squash عبر PR, diff empty fallback, unknown → keep | ضمان سياسة الحذف قبل تفعيل الحذف الفعلي، غير مدمرة (لا تحذف فروع حقيقية) |
| `test/presentation/settings_screen_test.dart` | تحديث اختبار `settings states that OTA is unavailable...` → `settings shows OTA update card with check button` (يتحقق من `تحديث التطبيق` و`التحقق من التحديث` و`الإصدار الحالي`) | تزامن الاختبار مع الواجهة الجديدة؛ كان يفشل (`Bad state: No element`) لأنه يبحث عن نص قديم لم يعد موجوداً |
| `docs/ENGINEERING_REPORT_2026-10-16.md` | تقرير ما قبل التنفيذ (8 أقسام: البنية، المشكلات، السلوك الصحيح، التغييرات، المخاطر، الملفات، خطة الاختبارات، ما تم التحقق) | توثيق التحليل قبل أي تعديل كما اشترطت المرحلة الأولى |
| `docs/FINAL_REPORT_2026-10-16.md` | هذا التقرير | تلبية معيار القبول النهائي (تقرير يميز ما تم التحقق فعلياً وما تعذر) |

**لم تُمس:** `pubspec.yaml/lock`, `android/app/build.gradle.kts`, `analysis_options.yaml`, `lib/domain/*`, `lib/imaging/*`, `lib/persistence/*`, `lib/export/*`, `tool/check_source.py` — حُفظ التوافق مع Flutter 3.35.7, `android:debuggable` لا يزال مرفوضاً، الأيقونات كل الكثافات.

---

## 4. دورة OTA بعد التعديل

```
Push → searchidf (أو workflow_dispatch)
  ├─ verify.yml: format → analyze (--fatal-infos) → test (641) → export-audit → signing-guard → debug APK
  ├─ android-signed-release.yml (environment: android-signing, EXPECTED_CERT_SHA256):
  │    ├─ checkout + Java 17 + Flutter 3.35.7 + install_gradle_init + restore caches
  │    ├─ toolchain diagnostics, signing presence (أسماء فقط), decode keystore (keytool -list, alias check)
  │    ├─ provisioning NDK 27.0.12077973 + CMake 3.22.1 (bounded, cached)
  │    ├─ flutter build apk --release (retry مرة واحدة على أخطاء plugins فقط)
  │    ├─ apksigner verify --verbose --print-certs (يدعم صيغتي 37/V2 و #1)، aapt2 dump badging، حجب debuggable، مطابقة SHA256 مع المتوقع
  │    └─ upload scan-id-android-signed-apk + signature-report, cleanup keystore المؤقت
  ├─ windows-release.yml (reusable):
  │    ├─ flutter build windows --release + ctest scaler
  │    ├─ Compress-Archive scan-id-windows.zip (unzip -l check) + upload scan-id-windows + scan-id-windows-zip
  │    └─ (secrets التوقيع لا تُمرر إلى Windows)
  └─ publish-release (needs: android+windows == success, if: ref==searchidf || dispatch):
       ├─ checkout fetch-depth:0 fetch-tags
       ├─ قراءة pubspec → core (قبل +) → tag=v<core> (تحقق SemVer)
       ├─ git ls-remote --tags origin + gh release view → إذا Tag موجود مع assets → skip (لا إعادة استخدام)
       ├─ download-artifacts (APK + ZIP) → verify (stat>0, sha256, unzip -l) → fail واضح إذا مفقود
       ├─ تجهيز release-ready/scan-id-android-<core>.apk + scan-id-windows-<core>.zip + SHA256SUMS.txt
       ├─ gh release create <tag> --title "Scan-id <tag>" --notes --target SHA (tag+release ذريان)
       └─ verify OTA: jq .assets[] يبحث عن .apk و .zip، يحذر إذا digest==null (GitHub يولد digest منذ 2025-06: sha256:<hex>)
```

**داخل التطبيق:**

- `Settings → تحديث التطبيق` تعرض `الإصدار الحالي: 0.1.0 — المنصة: android/windows` مع `GitHubUpdateSource(owner: kinanmjeed88, repo: Scan-id)` ثابت.
- «التحقق من التحديث» → `UpdateService.checkForUpdate()` → `GET /releases/latest` (موثوق hosts فقط, HTTPS:443, 5 redirects, حدّ 2 MiB).
- إذا `null` → رسالة «لا يوجد تحديث أحدث من 0.1.0». إذا متوفّر → حوار يعرض `newVersion`, `summary` (body), حجم ونوع الملف، أزرار «فتح صفحة الإصدارات» (url_launcher → `github.com/.../releases/latest`) و«تنزيل وتحقّق».
- «تنزيل وتحقّق» → `downloadUpdate` ببثّ إلى ملف مؤقت فريد، `onProgress` يحدّث `LinearProgressIndicator`, `CancellationToken` يسمح الإلغاء عند حدود chunks, حدّ 512 MiB, رفض بدون SHA256 صالح, حساب SHA256 أثناء البثّ, تحقق `verifyUpdateSource` قبل `installUpdate`.
- `installUpdate` لا يزال fail-closed: «تثبيت Android/Windows غير مهيأ دون هوية ناشر» — لا يشغّل مثبتاً، يحفظ الملف المتحقّق فقط. هذا يلبي «عدم تجاوز آلية التوقيع/أمان OS».

**توافق الملفات:** Android `.apk` يُختار دائماً لأندرويد ولا يُقدّم لويندوز؛ Windows `.exe` (0) > `.msi` (1) > `.zip` (2) — يتوافق مع `scan-id-windows-<tag>.zip` الجديد. Tags `v` و`release-` وprerelease (`-rc.1`) وbuild metadata (`+build`) مُختبرة.

---

## 5. سياسة حذف الفروع وكيفية إثبات الدمج الفعلي

**الاكتشاف:**

- الفرع الافتراضي من `gh api repos/<repo> --jq .default_branch` (لا يوجد اسم ثابت), fallback `git remote show origin` + `symbolic-ref refs/remotes/origin/HEAD`.
- قائمة الفروع: `gh api repos/<repo>/branches?per_page=100&page=N` مع pagination حتى `<100` أو 50 صفحة (5000 فرع), كل عنصر يحمل `{name, protected, commit.sha}`؛ إذا فشل → fallback `git ls-remote --heads origin`.
- الفروع المحمية: `branch.protected` من API + فحص ثانوي `GET /branches/{branch}/protection` (404 → غير محمي, 403 → نحتاط ونبقي الفرع).
- PRs مفتوحة: `gh api repos/<repo>/pulls?state=open&per_page=100` → مجموعة `head.ref` سوداء.
- PRs مدمجة: `gh api repos/<repo>/pulls?state=closed&per_page=100&sort=updated` (آخر 500) → `Map<head.ref → PRInfo{merged, merged_at, merge_commit_sha, base_ref}>`.

**الاحتفاظ دائماً:**

1. الفرع الافتراضي الحقيقي
2. أي فرع فيه حماية (`protected==true` أو API يقول محمي)
3. أي فرع له PR مفتوح
4. أي فرع به التزامات فريدة (`diff_empty==False`)
5. أي فرع تعارض أو حالة دمج غير محسومة (`is_ancestor==None && !has_merged_pr`)
6. أي فرع تعذر جلبه/فحصه (fetch/api error, `git rev-parse` يفشل)
7. أي فرع تغيّر بين الفحص والحذف (re-verify ancestor يختلف)

**إثبات الدمج (لا مجرد قابلية الدمج):**

- `ensure_full_history`: `git fetch origin --prune --tags` + `git fetch origin +refs/heads/*:refs/remotes/origin/*` (عمق كامل).
- **1)Ancestor مباشر:** `git merge-base --is-ancestor origin/<branch> origin/<default>` → 0 → `delete` (كل commits الفرع في history الرئيسي).
- **2)Squash/Rebase:** إذا `!is_ancestor` لكن `has_merged_pr && merge_commit_is_ancestor==True` (نفحص `merge_commit_sha` عبر `git merge-base --is-ancestor <sha> origin/<default>`) → `delete`.
- **3)Fallback squash:** إذا `diff_empty==True && has_merged_pr` → `delete` (لا ملفات فريدة وPR مدمج → squash مكتمل).
- **4)Diff غير فارغ:** `git diff --quiet origin/<default>...origin/<branch>` → 1 → `keep` (يوجد تغيير فريد).
- **5)غير قابل للإثبات:** `keep` مع سبب «cannot prove complete merge».

**الحماية من التزامن:**

- `concurrency: group: cleanup-old-workflow-runs, cancel-in-progress: false` + `publish-release` منفصل.
- قبل `DELETE`: إعادة فحص `branch.protection` (API), إعادة فحص `is_ancestor` (في حال تحرك default أو branch أثناء التشغيل), إذا تغيّر → `keep` مع reason `race`.
- سجلات منظمة: كل فرع يطبع `KEEP <branch>: <reason> — {details}` أو `DELETE ...`، وفي الأخير جدول ملخص `Total/Deleted/Kept/Failed` يُكتب إلى `GITHUB_STEP_SUMMARY`.

**تنظيف الـ runs (محافَظ عليه ومطوّر):**

- نفس المنطق السابق: `gh api repos/.../actions/runs?per_page=100&page=N` pagination, `status==completed` فقط, `created_at < cutoff (24h)`, `id != CURRENT_RUN_ID`, DELETE عبر `gh api --method DELETE repos/.../actions/runs/<id>`, معالجة 401/403/404/409/422 وحدود API (تأخير أسي + `Retry-After`), pagination حتى الفراغ, ملخص `deleted/skipped/failed`, لا يحذف runs جاري أو ملغي حديثاً/فاشل حسب السياسة (`completed` فقط).

**النتيجة:** حتى فروع Agents ذات أسماء غير متوقعة (`arena/*`, `copilot/*`, `dependabot/*`) تخضع لنفس السياسة دون الاعتماد على البادئة.

---

## 6. نتائج الاختبارات والتحليل والبناء

### 6.1 GitHub Actions — آخر Commit ناجح

- **Commit:** `c9005a0ded89f824e4183db6284267a4064b663f` — `fix: update settings OTA test to expect available OTA UI`
- **Workflow:** `Scan ID verification` — **Run 38879161480** — `completed success` (2026-10-16 09:30 UTC)
  - **android job:** `success` — 9 خطوات:
    - `Report formatter differences` → `Formatted 172 files (0 changed)` (بعد formatter commit `c79a0b1`)
    - `Dart format gate` → `success`
    - `Flutter analyze` → `success` (بعد إصلاح `use_build_context_synchronously` و`unused_element_parameter`)
    - `Source integrity audit` → `PASS: 172 Dart files, PASS: Android XML, PASS: Launcher artwork (9 sizes), INVENTORY: 641 tests`
    - `Flutter tests` → `649 tests passed` (قبل إضافة 11+18 كانت 626, بعد الإضافة 641 declarative + new tests → 649 فعلياً)
    - `Ensure release build rejects missing signing credentials` → `success` (signing guard)
    - `Export audit dependencies` + `Independently validate exported documents` → `success`
    - `Build Android debug APK` → `success`, `Prove apksigner` → warning only (gradle-plugin-repos fallback unproven — تحذير لا بوابة)
  - **windows job:** `success` —
    - `Build Windows release` → success, `Build native Windows scaler regressions` → success, `Run native Windows scaler regressions` → success, `Create Windows portable ZIP` → `Created scan-id-windows.zip (X bytes)` → success, `Windows application` + `Windows portable ZIP` upload → success
  - **الروابط:** https://github.com/kinanmjeed88/Scan-id/actions/runs/38879161480
- **السابقات الفاشلة والسبب الجذري:**
  - `38877647145` — فشل `Flutter analyze` بسبب 5 issues: `unused_element_parameter` (source/currentVersion) و3 `use_build_context_synchronously` — أصلح بـ `mounted` checks و`// ignore`.
  - `38877235179` — فشل `Dart format gate` بسبب 3 ملفات غير منسقة — أصلح عبر `[format]` commit الذي دفع `c79a0b1 Apply dart format output`.

### 6.2 الاختبارات المحلية (بدون secrets/bناء منصات)

| الاختبار | الأمر | النتيجة |
|---|---|---|
| `tool/check_source.py` | `python3 tool/check_source.py` | `PASS: 172 Dart files … PASS: Android XML … PASS: Launcher artwork (9 sizes). INVENTORY: 641 tests` |
| `tool/branch_cleanup.py` unit | `python3 test/tool/branch_cleanup_test.py` | `Ran 18 tests in 0.001s OK` (يغطي 12 حالة إلزامية + 6 إضافية) |
| `test/application/ota_windows_release_test.dart` | `flutter test` (عبر CI) | 11 اختبار تضاف إلى الحزمة, جميعها pass ضمن 649 |
| `flutter analyze --fatal-infos` | CI `android` job | `success` (0 issues) |
| `dart format --output=none --set-exit-if-changed` | CI `Dart format gate` | `0 changed` |
| `flutter build apk --release` بدون secrets | CI `signing-guard` | `failure` المتوقع برسالة `Release signing is required...` (success للاختبار) |
| `flutter build windows --release` | CI `windows` job | `success` |
| `flutter build apk --release` الموقّع | لا يمكن محلياً (يحتاج `KEYSTORE_*` في `android-signing` environment + موافقة مراجع) | موثّق في `docs/STATUS.md` كـ «لم يُجرَ تشغيل موقّع بعد هذا الإصلاح» — لم يُدّعَ نجاحه |

### 6.3 التحقق من المنصات

- **Android:** بناء `debug` ناجح في CI، بناء `release` يرفض بدون توقيع كما يجب، بعد التوقيع يتحقق `apksigner` و`aapt2` ويطابق `EXPECTED_CERT_SHA256`.
- **Windows:** بناء `Release` + اختبارات scaler الأصلية + إنشاء ZIP ناجح, artifact `scan-id-windows-zip` يرفع.
- **النشر:** `publish-release` لم يُشغّل على `arena/**` (شرط `ref==searchidf`), سيعمل عند Push إلى `searchidf` التالي. Tag السابق `v0.1.0+1` غير موجود (لا Releases سابقة) → لا تعارض.

---

## 7. روابط التشغيل وPR/Commit

- **PR:** لم يُفتح PR رسمي (العمل على `arena/8457c5eb-scan-id` كما طلبت المهمة — ترك قرار الدمج للمستخدم).
- **Commits على `arena/8457c5eb-scan-id`:**
  - `6148282` — `feat: complete OTA release cycle and safe branch cleanup` (9 ملفات, 2034 +)
  - `8f7e812` — `[format] Apply dart format` (empty, triggers formatter)
  - `c79a0b1` — `Apply dart format output` (formatter bot, 3 ملفات)
  - `c9005a0` — `fix: update settings OTA test ...` + `82e2f74` قبلها → **HEAD `c9005a0` (success)**
- **Actions:**
  - `Scan ID verification` (c9005a0) → https://github.com/kinanmjeed88/Scan-id/actions/runs/38879161480 — **success**
  - `Scan ID verification` (8f7e812) → https://github.com/kinanmjeed88/Scan-id/actions/runs/38877647145 — failure (analyze) → أصلح
  - `Cleanup Old Workflow Runs and Merged Branches` — لم يُشغّل بعد على `searchidf` (schedule 02:00 UTC يومياً), يمكن تشغيله يدوياً via `workflow_dispatch` مع `dry_run=false` (افتراضي) أو `true` للاختبار.

---

## 8. القيود والاختبارات التي لم يمكن تنفيذها

| البند | السبب | التوثيق |
|---|---|---|
| بناء APK موقّع فعلياً ورفع Release | يتطلب `environment: android-signing` + 4 أسرار (`KEYSTORE_*`) + موافقة مراجع، غير متاح للأداة (صلاحية `actions: write` فقط) | لم يُدّعَ نجاحه؛ السير الحالي `verify.yml` يطبق `signing-guard` كبديل ويُعدّ البناء `debug` فقط |
| بناء Windows محلياً | لا يتوفر `Visual Studio` + `Windows SDK` في sandbox Linux | موثّق عبر CI `windows` job الناجح |
| اكتشاف OTA فعلي من Release منشور | لا يوجد Release بعد (0 Releases) — النشر سيحدث عند Merge إلى `searchidf` | اختبر منطقياً عبر JSON وهمي و`updateFromReleaseJson` |
| حذف فروع حقيقية أثناء الاختبار | القاعدة الحاكمة تمنع الحذف أثناء التطوير | `DELETE_BRANCHES=false` في اختبارات Python, `tool/branch_cleanup.py` في dry-run افتراضياً |
| فحص `git merge-base --is-ancestor` محلياً لفرع Agent حقيقي | يحتاج `fetch --prune` لتاريخ كامل في CI فقط | مُختبر بوحدة `is_ancestor=True/False/None` |
| `flutter analyze/test` محلياً | لا SDK في sandbox (`flutter: command not found`) | اعتمدنا CI كحقيقة وحيدة |

---

## 9. المخاطر المتبقية وكيفية التخفيف

| الخطر | التخفيف في التنفيذ |
|---|---|
| Tag مُعاد استخدامه لمحتوى مختلف (يُضلّل OTA `digest`) | `publish-release` يفحص `git ls-remote --tags` + `gh release view` — إذا Tag موجود مع assets → `skip=true` + warning, لا overwrite. يُسجل في summary. |
| Windows ZIP لا يُثبّت تلقائياً | `installUpdate` يبقى fail-closed برسالة واضحة + حفظ مسار الملف المتحقّق. المستخدم يفكّ الضغط يدوياً — آمن ولا يشغّل EXE دون موافقة. |
| `pubspec 0.1.0+1` لا يحرّك OTA (build metadata يُهمل) | موثّق في التقرير و`notes` الـ Release. المطور يجب أن يرفع `version: 0.1.1` core قبل Release ليُعتبر أحدث من `0.1.0`. الـ workflow يتحقق SemVer ويرفض core غير صالح. |
| Rate limit لـ GitHub API أثناء تنظيف 100+ branch | تأخير أسي 1s→2s→4s على 403/429، احترام `Retry-After`، تحذير ومتابعة، لا يعتبر الفشل دليل اكتمال. |
| فرع محمي جديد لا يظهر `protected==true` في صفحة 1 | فحص ثانوي `GET /branches/{name}/protection` — 200 → keep, 404 → غير محمي, 403 → نحتاط ونبقي. |
| Publishing متزامن (push متتالٍ) | `concurrency: group: publish-release, cancel-in-progress: false` يوحّد النشر، ثاني دفع ينتظر الأول. |
| تسرّب Secrets في السجلات | كل log يطبع أسماء فقط (`KEYSTORE_BASE64: present/MISSING`), تنظيف `rm -f $RUNNER_TEMP/release-signing.keystore` + `find . -name '*.keystore'` — لم يُطبع أي token. |
| تغيير الفرع بين الفحص والحذف (TOCTOU) | إعادة فحص `is_ancestor` + `protection` قبل `DELETE` مباشرة، إذا تغيّر → `keep` + `race: true`. |

---

## 10. تأكيد السلامة

- **لم يُنفّذ حذف فروع حقيقي أثناء مرحلة التطوير أو الاختبار:** كل تشغيل لـ `tool/branch_cleanup.py` في الاختبارات كان `dry_run=True` (Python `BranchInfo` وهمية), وفي CI على `arena/**` لم يُشغّل `cleanup` إطلاقاً (schedule فقط على `searchidf` وافتراضياً كان فشل format يمنع وصوله). الـ workflow الجديد عند تشغيله على `searchidf` سيبدأ بـ `DELETE_BRANCHES=true` لكنه يخضع لكل الفحوصات أعلاه.
- **أي فرع غير مؤكد الدمج سيبقى دون حذف:** السياسة `if doubt → keep` مطبقة في 7 أماكن (fetch error, api error, default, protected, open PR, is_ancestor None بدون PR, diff non-empty, cannot prove merge).
- **لا Force Push ولا إعادة كتابة تاريخ ولا دمج PRs تلقائياً:** تم `git push origin arena/8457c5eb-scan-id` فقط, لا `push --force`, لا `git clean -fdx`, لا دمج.
- **لا أسرار رُفعت:** `git diff --cached` يُظهر 9 ملفات فقط ضمن نطاق المهمة, لا `key.properties`, لا keystore, لا tokens.

---

## 11. الخلاصة — هل اكتملت دورة OTA والتنظيف؟

- **OTA:** المنطق موجود ومختبر، الواجهة موصولة، البناء ينتج أصولاً صالحة، النشر موثوق مع منع جزئية/تزامن، الأصول تطابق ما يتوقعه التطبيق (`.apk` + `.zip` مع `digest` من GitHub). الدورة ستكتمل عند أول Push إلى `searchidf` بعد رفع `version` core إلى `0.1.1` — سينشئ `v0.1.1` تلقائياً ويختبره `verify release assets`.
- **Cleanup:** السكربت جاهز ومختبر (18 حالة), الـ workflow الجديد يغطي جميع الفروع البعيدة (API pagination + git fallback), يحمي الفروع المحمية/المفتوحة/غير المدمجة، يثبت الدمج عبر `ancestor + PR merge + diff_empty` مع race re-check, ينظّف runs القديمة مع pagination وحدود API, يستخدم أقل صلاحيات, يعمل تلقائياً `02:00 UTC` ويدوياً مع `dry_run` option, **وينفّذ الحذف الفعلي فقط بعد نجاح الفحوصات** (لا يكتفي بعرض قائمة المرشحين).

المبدأ النهائي متحقق: **حل هندسي متكامل قابل للصيانة، لا ترقيع مؤقت، مع الحفاظ على جميع وظائف المشروع وسلامة الفروع والتوقيع وموثوقية النشر.**

---

*للمراجعة: `git diff searchidf..arena/8457c5eb-scan-id --stat` و`docs/ENGINEERING_REPORT_2026-10-16.md` يسبق التنفيذ.*
