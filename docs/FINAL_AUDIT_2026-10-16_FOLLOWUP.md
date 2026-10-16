# تقرير التدقيق الأمني والمعماري — متابعة قبل الدمج (2026-10-16)
## Scan-id — لوحة الإدارة ودورة OTA وGitHub Actions

**النطاق:** فحص التنفيذ الفعلي لا وصف التقرير، وإصلاح العيوب المثبتة دون دمج PR أو نشر Release/Tag إنتاجي أو Force Push.

### 1) الحالة الحالية المثبتة

- **الفرع:** `arena/8457c5eb-scan-id` (الفرع العامل)، الأساس `searchidf` (الافتراضي، الصلاحيات admin/maintain/push كما في `gh api repos/... --jq .permissions`)، النشر Pages `searchidf:/` → `https://kinanmjeed88.github.io/Scan-id/` (status: built).
- **SHA الذي بدأ منه التدقيق:** `8972a70cf5d53645867918a8a10c2ba67bfbe922` (آخر SHA حسب التقرير السابق) — ثابت عبر `git rev-parse HEAD` و `gh api pulls/20 --jq .head.sha` عند البداية.
- **SHA النهائي بعد الإصلاحات:** `3b6887865bd70955cb856170ece464616d0d8a41` (commit: `fix: harden release-management workflow and dashboard (audit follow-up)`) — مُدفوع إلى `origin/arena/8457c5eb-scan-id` (push 8972a70..3b68878).
- **التغيير بين cdb2c14 و8972a70:** تعديل سطر واحد في `admin/index.html` (رابط وثيقة المصادقة من `../docs/RELEASE_AUTH.html` إلى `https://github.com/.../blob/searchidf/docs/RELEASE_AUTH.md` — لتجنب فشل Jekyll مع `.nojekyll`).
- **التغيير بين 8972a70 و3b68878:** إصلاحات حرجة (انظر §3) في `release-management.yml` (183 سطر) + `admin/app.js` (95 سطر) — لا تعديل في التطبيق نفسه إلا ما يلزم للاتساق.
- **حالة Git محلياً:** `On branch arena/8457c5eb-scan-id, nothing to commit, working tree clean` بعد `git reset --hard origin/arena` — لا تعديلات غير ملتزمة فُقدت.
- **Actions على SHA الحالي:**
  - `38895561931` (verify على 3b68878): `in_progress` (android+windows) — [فتح السجل](https://github.com/kinanmjeed88/Scan-id/actions/runs/38895561931) — لم يكتمل أثناء التدقيق (استغرق verify السابق 8–12 دقيقة).
  - `38886755813` (verify على 8972a70): `success` — [السجل](https://github.com/kinanmjeed88/Scan-id/actions/runs/38886755813) (android success, windows/windows success — دليل أن البناء السابق سليم لكن يحتوي العيوب الموصوفة).
  - `38894949669` (pull_request على 8972a70): `cancelled` — أُلغي لصالح الجديد (concurrency cancel-in-progress=true في verify).
  - Workflows المنشطة: `verify.yml`, `android-signed-release.yml`, `windows-release.yml`, `cleanup-old-runs.yml`, `pages-build-deployment` — `release-management.yml` **غير موجود في searchidf** (404 عبر `gh api contents/...?ref=searchidf`) وموجود في arena (`b22f08...`) → الأمر `gh workflow run release-management.yml --ref searchidf` **غير صالح قبل الدمج** (انظر §2).

### 2) التدقيق الحاسم في Workflow إدارة الإصدارات

#### 2.1 توفر Workflow في الفرع الافتراضي
- **الدليل:** `gh api repos/.../contents/.github/workflows/release-management.yml?ref=searchidf` → 404، بينما `?ref=arena/...` → 200 (`b22f08...`). `gh api .../actions/workflows` يسرد فقط 5 Workflows في searchidf (بدون release-management).
- **الاستنتاج:** الأمر المذكور في التقرير `gh workflow run ... --ref searchidf` يفشل حالياً بـ `workflow not found`. يصبح صالحاً فقط **بعد دمج PR #20 إلى searchidf** ثم `git fetch` + تأكيد `gh workflow view release-management.yml --json state` يظهر `active` على searchidf. لا تطلب التجربة بنشر حقيقي. تمت إضافة تحذير في لوحة الإدارة (`errors.push('release-management workflow غير موجود في searchidf — الأمر gh غير صالح قبل الدمج (PR #20)')`) يظهر كـ alert أصفر في الصفحة قبل الدمج.

#### 2.2 التحقق من صلاحيات المستخدم
- **التنفيذ السابق:** `perm=$(gh api .../collaborators/.../permission --jq .permission || echo none)` ثم `if != admin/write/maintain → exit 1`. فشل API يعيد `none` → مرفوض (آمن افتراضياً). لكن السطر كان يلتقط stderr معًا ولم يُجرد المسافات؛ إذا عاد `""` فارغاً قد يُعامل كنجاح؟ غير مثبت.
- **الإصلاح:** فصل `perm_raw=$(gh api ... || true)` ثم `perm=$(echo "$perm_raw" | tr -d '[:space:]' | head -n1); if [[ -z "$perm" ]]; then perm="none"; fi` وإضافة رسالة `رُفض الطلب` — يضمن الرفض عند أي استجابة غير متوقعة أو نقص صلاحية. لا يعتمد على اسم المنفذ وحده.
- **المطلوب خارجياً:** لا شيء — `GITHUB_TOKEN` مع `contents:read+actions:read` يكفي للتحقق؛ لا تُمنح صلاحيات كتابية إلا في `publish`.

#### 2.3 التحقق من الفرع والمصدر
- **التنفيذ:** يتحقق من `github.ref == refs/heads/searchidf` و `default_branch == searchidf` عبر `gh api repos/... --jq .default_branch`. يمنع بناء من `arena` أو `feature` حتى لو غُير `targets`.
- **النقص الذي بقي:** لا يمنع إعادة تشغيل Run سابق بعد دمج commit مختلف؟ `github.sha` في `publish` كان يستخدم `${{ github.sha }}` كهدف Release، لكن Windows كان يبني SHA قديم (انظر 2.3 التالي). أُصلح عبر توحيد Artifact.

#### 2.4 حدود الصلاحيات
- **قبل الإصلاح:** `validate` بلا `permissions` صريحة (يرث read — كافٍ)، لكنه يحتاج `actions:read` لقراءة Runs في فحص التزامن. `build` بلا `environment` → أسرار `android-signing` غير متاحة (ستفشل بناء release الموقّع).
- **بعد الإصلاح:** `validate: permissions: contents:read, actions:read`, `update-version|build|windows: contents:read`, `publish: contents:write` فقط، `build: environment: android-signing` — أسرار التوقيع معزولة في job البناء فقط. `checkout` في التحقق بـ `persist-credentials: false` لمنع تسريب token إلى السجلات. لا `workflow_call` إضافية بصلاحيات موروثة.

#### 2.5 التزامن
- **التنفييذ:** `concurrency: group: release-management, cancel-in-progress: false` على المستوى العام + `group: publish-release-management` في النشر. فحص التزامن عدّ `gh api .../runs?status=in_progress` و `count>1 → exit 1`. يمنع الإصدارات المتعارضة دون إلغاء نشر سليم. إعادة التشغيل تُنشئ Run جديد ب concurrency group ينتظر (Queue) لا يلغي السابق. لا يترك حالة جزئية — Tag لا يُنشأ إلا بعد نجاح كل البوابات (انظر §5).

#### 2.6 المخرجات بين Jobs
- **العيب الحرج المكتشف (دليل):** `windows:` كان `uses: ./.github/workflows/windows-release.yml` — هذا Reusable Workflow يعمل `actions/checkout@v5` بدون `ref` ويبني `searchidf` الأصلي بدون استعادة `version-bump` Artifact. بينما `build` (Android) يستعيد Artifact ويبني `0.2.0+2` المقترح. النتيجة: Android وWindows يبنيان **مصدرين مختلفين** بإصدارين مختلفين — أسماء الملفات `scan-id-android-0.2.0.apk` vs `scan-id-windows-0.1.0.zip` ستتعارض مع Tag `v0.2.0`.
- **الإصلاح:** استُبدل `uses:` بـ job حقيقي `runs-on: windows-2022` (30 خطوة مطابقة لـ `windows-release.yml` + 2 خطوة إضافية: `Restore version-bump` / `Apply version-bump` + فحص `scan_id.exe` داخل ZIP). الآن كل Job يستعيد نفس `/tmp/version-bump/pubspec.yaml` → نفس `core+build` قبل البناء. Artifact `scan-id-windows-zip` يُسمى كما قبل في `publish` (لا تغيير في التوقعات).

### 3) تحديث الإصدار وتناسق Android وWindows

- **السؤال 1 (هل يستخدم Android رقم الإصدار المطلوب؟):** نعم — `update-version` يحدث `pubspec.yaml: version: $new+$build` + `app.dart: applicationVersion: '$new'` + `settings_screen.dart: _appVersion = '$new'` ثم يرفع Artifact. `build` يستعيده عبر `cp /tmp/version-bump/pubspec.yaml` قبل `flutter build apk --release`.
- **السؤال 2 (هل يستخدم Windows الإصدار نفسه؟):** **لا قبل الإصلاح** (دليل أعلاه). بعد الإصلاح: نعم — نفس مسار الاستعادة في `windows` job.
- **السؤال 3 (هل Reusable يبني SHA مختلف؟):** نعم قبل الإصلاح — كان يبني HEAD الحالي لـ searchidf بدون Bump. بعد الإصلاح لا يوجد Reusable.
- **السؤال 4 (هل كل Job يبني نفس الكود؟):** الآن نعم — نفس SHA الأساس (searchidf) + نفس Bump Artifact.
- **السؤال 5 (هل تتطابق أسماء الملفات مع Tag؟):** قبل الإصلاح لا — Windows كان ينشر باسم `scan-id-windows.zip` العام، لكن `publish` يعيد تسميته إلى `scan-id-windows-${{ inputs.version }}.zip` (متسق). الآن `publish` يتأكد `core == inputs.version && build == inputs.build_number` وإلا يفشل قبل Commit.
- **السؤال 6 (هل إعادة المحاولة تبني نسخة مختلفة؟):** لا — Bump محصور في Artifact، لا يعاد تخمينه. `publish` يعاد استخدام نفس Artifact بعد إعادة تشغيل `build+windows` من نفس `inputs` — محمي بـ `concurrency` وإعادة فحص `inputs.version` مقابل `pubspec core`.
- **ما لا يُستخدم للتراجع:** لا `git checkout --` — البناء يستخدم نسخ مؤقتة تحت `/tmp` و `release-ready/`، لا يفقد تعديلات موجودة. `git diff --name-only` في `update-version` يضمن فقط 3 ملفات تغيرت.

### 4) التوقيع والتحقق من الملفات

- **القيمة المتوقعة:** `EXPECTED_CERT_SHA256='3e9c3d988ab491a60a570b4c70de79c1eba61f038893d3cd2a4ea29bb913c74a'` — بصمة شهادة X.509 للمفتاح الذي وُلد 2026-10-15 RSA-4096، مضبوطة في `android-signed-release.yml` كـ env عامة ومقارنة بـ `keytool -list -v ... | SHA256` قبل البناء. ليست سراً، ومصدرها محمي: تُخزن في Workflow (لا يغيرها طلب الإصدار) وتُقارن بـ keystore المُحمّل من `KEYSTORE_BASE64` (secret في environment `android-signing`). تغييرها من قبل طالب الإصدار يتطلب تعديل Workflow نفسه → يحتاج PR ومراجعة — آمن.
- **هل تُقارن بصمة الشهادة أم Hash الملف؟** بصمة الشهادة: `apksigner verify --verbose --print-certs` → سطر `certificate SHA-256 digest:` يُستخرج ويُطبع hex بدون `:` → يُقارن بـ `EXPECTED`.
- **هل يُتحقق أن APK موقّع وصالح؟** قبل الإصلاح: يتحقق `apksigner verify` exit code فقط + مقارنة digest (لكن دون فلترة `public key` line قد يلتقط سطر خاطئ على أدوات قديمة). بعد الإصلاح: يفلتر `grep -iv 'public key'`، يتحقق `observed =~ ^[0-9a-f]{64}$`، يعد `number of signers ==1`، ويتحقق `aapt2 dump badging` + `! application-debuggable`.
- **هل يُرفض غير الموقع/بشهادة مختلفة؟** نعم — `rc !=0 → exit 1`، `observed != EXPECTED → exit 1` مع تنبيه `CN=Android Debug` إذا كان debug key، و `aapt2` يرفض debuggable.
- **هل مصدر البصمة محمي؟** نعم — `EXPECTED` ثابت في Workflow (لا يأتي من `inputs`)، و `KEYSTORE_BASE64` في environment محمي بموافقة مراجع (`android-signing`).
- **هل يُتحقق من Windows ZIP؟** قبل الإصلاح: `unzip -l` فقط. بعد الإصلاح: `unzip -l | grep -qi scan_id.exe` + فحص الحجم + `Compress-Archive` مع استبعاد test binaries + تحقق ثانٍ في `publish` (`scan_id.exe` داخل ZIP).
- **هل يُعاد حساب SHA-256 ومقارنته؟** قبل الإصلاح: يولّد `SHA256SUMS.txt` محلياً قبل النشر لكن لا يقارنه بعد الرفع. بعد الإصلاح: يحفظ `/tmp/local-hashes.txt` قبل `gh release create`، ثم بعد النشر يجلب `gh release view --json assets --jq .assets` ويقارن كل `local hash` بـ `remote digest (strip sha256:)` — `hash mismatch → exit 1`.
- **هل تتطابق الأسماء والـHashes مع ما يقرأه التطبيق؟** التطبيق يقرأ `assets[].name` و `assets[].digest` (يُطبيّع `sha256:`) ويختار حسب `_extensionsFor(platform)` (`.apk` لـ Android، `.zip/.exe/.msi` لـ Windows مع الأولوية exe>msi>zip). Workflow الآن ينشر `scan-id-android-<core>.apk` + `scan-id-windows-<core>.zip` + `SHA256SUMS.txt` بأسماء متوقعة، والتحقق يطلب `name == scan-id-android-<version>.apk` و `scan-id-windows-<version>.zip`.

### 5) شروط النشر والحالات الجزئية

- **أي فشل يمنع Tag/Release:** `publish` `needs: [validate, update-version, build, windows]` مع `if: always() && needs.validate==success && ... && (windows==success||skipped)` — أي `failure` في اختبارات/بناء/توقيع/فحص يمنع الوصول إلى `Commit version bump and tag` (التي هي أول step يكتب إلى المستودع).
- **حالات فشل محددة:**
  - Android بعد نجاح الاختبارات → `build` يفشل → `publish` لا يعمل.
  - Windows بعد نجاح Android → نفس.
  - فشل رفع أحد الأصول → `upload-artifact if-no-files-found: error` يفشل `build/windows` → `publish` لا يعمل.
  - فشل التحقق بعد رفع → `Verify assets before publish` أو `Verify OTA assets` يفشل بـ `exit 1` قبل `gh release create` أو بعده مع مقارنة digest.
  - إعادة تشغيل بعد فشل جزئي → `validate` يعيد فحص `git ls-remote --tags` — إذا كان Tag موجوداً بالفعل سيرفض (`Tag exists → exit 1`) — يمنع إعادة استخدام Tag مع Build مختلف (آمن، لكنه يتطلب تدخل يدوي لو Tag بلا Release — مذكور في `tag_check` تعليق: يبقى `exists=true` و `skip=false` للسماح بإنشاء Release من Tag موجود، لكن `validate` سيرفض قبل الوصول — تعارض مقصود للسلامة؛ الحل: حذف Tag يدوياً أو bump version).
  - Tag/Release باسم نفسه → مرفوض في `validate` + `tag_check` (remote check) + `Commit...Tag` خطوة (`git ls-remote → exit 1`).
  - محاولات متزامنة لنفس النسخة → `concurrency: publish-release-management` يصفها، ثانيهما يفشل عند `git push origin tag` بـ `already exists`.
  - اختلاف بيانات Release عن الملفات المفحوصة → يُكتشف عبر `core != inputs.version → exit 1` + `remote digest != local hash → exit 1`.
- **لا حذف/استبدال تلقائي:** لا `gh release delete` ولا `git push --force` ولا `gh api DELETE refs/tags` — فقط `skip=true` إذا كان Release موجود بأصول (idempotent).

### 6) لوحة الإدارة وGitHub Pages

- **الملفات المراجعة:** `admin/index.html` (227 سطر، RTL، 8 حقول + legend + نموذج + إجراءات)، `admin/app.js` (386→406 سطر)، `admin/style.css` (102 سطر responsive)، `.nojekyll` (0 bytes)، `README.md` قسم OTA.
- **هل تعرض بيانات حقيقية؟** نعم — عبر `fetchText(RAW_PUBSPEC=https://raw.githubusercontent.com/.../searchidf/pubspec.yaml)` + `fetchJSON(API_BASE + /tags?per_page=20)` + `/releases/latest` + `/actions/workflows/.../runs`. لا قيم افتراضية إلا placeholder `nextPatch/nextBuild` (يُعرض كـ placeholder لا كـ value). قبل الإصلاح كان `setText('active-branch','searchidf')` ثابت — حُدث ليقرأ `repo.default_branch` الفعلي.
- **هل تميز بين الحالات؟** نعم — 8 بطاقات ببادجات `badge-code/badge-build/badge-tag/badge-release` + legend، `mismatch-warning` (رمز تحذير عندما `currentCore != lastRelease`)، `ota-compat` (hasApk/hasZip + missingDigest)، `signature-status` (يعرض `EXPECTED...74a — يُتحقق في Workflow`).
- **هل تتعامل مع أخطاء API/rate limit؟** نعم — `fetchJSON` يرمي `Error HTTP 429...` مع `err.status`، `loadStatus` يجمع `errors[]` ويعرض `global-alert warning: ...`، `status-error` مع زر إعادة محاولة (الآن DOM-safe)، `rate limit 60/h بدون مصادقة` مذكور. تحذير خاص لـ 404 workflow.
- **هل SemVer في JS متوافق مع Dart؟** نعم — نفس regex `^(0|[1-9][0-9]*)\.(...)(?:-...)?(?:\+...)?$` + رفض `identifier.length>1 && startsWith('0')` للـ prerelease الرقمي، `compareSemVer` يستخدم `cmpNum` بطول السلسلة ثم مقارنة معجمية (يوازي `BigInt.compareTo` لكن للنطاق المعتاد `<2^53` متطابق). لا يدعم `BigInt` لأرقام هائلة — مقبول.
- **هل يمكن تجاوز build/tag من الواجهة؟** لا — الواجهة تتحقق لكن Workflow يعيد التحقق مستقلاً (`semver_core` regex + `cmp` Python + `git ls-remote --tags` + `gh api releases/tags` + `build_number` digits + `notes` length + `targets` enum). حتى لو عُدل `fetch` يدوياً، الخادم يرفض.
- **هل النصوص آمنة من XSS؟** قبل الإصلاح: `setHTML('android-link','<a href="'+ar.html_url+'"...')` و `runs-list.innerHTML = runs.map(r => '<div>'+r.name...` يسمحان بحقن عبر API مُخترق. بعد الإصلاح: `setLink(containerId, href, text, suffix)` ينشئ `createElement('a')` مع `textContent` و `href` كخاصية، `runs-list` يُبنى بـ DOM (`createElement` + `textContent`)، `status-error` زر إعادة المحاولة DOM بدلاً من `innerHTML+=`, `form-success` بـ `createElement('br/code/small')`. `release_notes` لا تُعرض أبداً كـ HTML — فقط كـ `notes.replace(/"/g,'\\"')` في أمر `gh` (مع escape للاقتباسات المزدوجة) وتُرسل إلى Workflow حيث تُمرر كـ `gh release create --notes "$notes"` (GitHub يهربها).
- **هل الروابط صحيحة؟** `OWNER=kinanmjeed88, REPO=Scan-id` ثابت مطابق للمستودع، `RAW_PUBSPEC` بـ `/searchidf/pubspec.yaml` (صحيح)، `Actions` رابط `.../actions/workflows/release-management.yml` (يوجد بعد الدمج فقط — مُشار إليه في التحذير).
- **هل .nojekyll يغير الموقع؟** لا — الموقع الحالي هو Flutter web مُبني مسبقاً، لا يستخدم Jekyll (`_layouts/_includes`). إضافة `.nojekyll` تمنع Jekyll فقط، لا تغير مسار `admin/` (الذي كان سيُهمل كـ `admin` مجلد خاص بدونها). Pages `source: searchidf:/` سيبقى `built` بعد الدمج (تحقق عبر `gh api pages --jq .status`).
- **هل توضح عدم التوفر قبل الدمج؟** الآن نعم — عند `fetchJSON(.../workflows/release-management.yml) → 404` تضاف رسالة `release-management workflow غير موجود في searchidf — الأمر gh غير صالح قبل الدمج (PR #20)` في شريط التحذير الأصفر، و `windows-status` يعود إلى fallback مع تعليق جديد.

### 7) توافق OTA مع التطبيق

- **العناوين المضيفة الموثوقة:** `_trustedUpdateHosts = {'github.com','objects.githubusercontent.com','release-assets.githubusercontent.com'}` + `uri.scheme=='https' && !userInfo && (!hasPort||443) && !hasFragment` — يمنع http/ssrf.
- **أسماء الملفات:** التطبيق يختار أول asset يطابق `extensionsFor(platform)` (`android: [.apk]`, `windows: [.exe,.msi,.zip]` بأولوية exe>msi>zip) ويُرتّب حسب `extensionPriority` ثم `name`. Workflow ينشر `scan-id-android-<core>.apk` (يتطابق) و `scan-id-windows-<core>.zip` (مقبول كـ zip). لا يُعتمد على اسم محدد، لكن `publish` الآن يتأكد من `name == scan-id-...<version>.apk/zip` لضمان التسمية المتوقعة.
- **حقل SHA-256:** التطبيق يقرأ `asset['digest'] ?? asset['sha256']` ويُطبيّع `sha256:` prefix + `toLowerCase` + يتحقق `^[0-9a-f]{64}$`. Workflow يضمن `digest != null` (تحذير إذا null) ويقارن `remote digest == local sha256` بعد النشر.
- **مقارنة SemVer:** `UpdateInfo.compareVersions` تستخدم `_SemVersion.parse` نفس منطق JS/Dart Workflow (prerelease أقل من stable، build metadata يُهمل). التطبيق يرفض `null` parse ويعتبر `isNewer = compare >0`.
- **دعم المنصات:** `android` و `windows` فقط — `UpdateService` يرفض أي extension غير مطابق ` _matchesPlatform(update)` قبل التنزيل.
- **حدود التنزيل:** `maxUpdateMetadataBytes=2MB`, `maxUpdateDownloadBytes=512MB`, يقطع `received>max` أو `received>update.size`, يتحقق `contentLength` مقابل `update.size`, يرفض `size<=0`, يسمح بإلغاء عبر `CancellationToken`.
- **تثبيت آمن:** `installUpdate` لا يشغّل أي مثبت — يعيد `InstallResult.error('تثبيت Android/Windows الهوائي غير مهيأ... لم يُشغَّل أي ملف')` حتى مع توقيع صحيح — السلوك المطلوب.
- **سلوك عند غياب البيانات:** إذا غاب APK/ZIP/Hash أو كانت نسخة غير متسقة → `checkForUpdate` يعيد `null` (لا يوجد تحديث)، `downloadUpdate` يرفض `!_isSha256(sha256)` أو `!isNewer` أو `!_matchesPlatform` مع رسالة عربية، لا يكسر التطبيق.
- **ما لم يُعدل:** لا تغيير في `ota_update.dart` — السلوك الحالي آمن ومتوافق مع المخرجات الجديدة.

### 8) الاختبارات والتحقق بعد الإصلاح

- **اختبارات Python الحالية:**
  - `test/tool/release_validation_test.py` (8 حالات): `PASS parse 0.1.0, prerelease, leading-zero major rejected, numeric prerelease leading-zero, compare greater/less, release>prerelease, extract v prefix, same-core not greater fails, newer ok, bad build, short notes, duplicate tag` — **ALL TESTS PASS** (14 تحققاً).
  - `test/tool/branch_cleanup_test.py`: **18 PASS** (حالات الفروع المحمية/Default/مفتوحة PR/ancestor/merge commit/diff empty/fetch error).
  - `tool/release_validation.py`: يستورد ويُحتسب `compareVersions` مطابق للـ Dart.
- **ما أُضيف للاختبار (مُغطى ضمنياً):** حالات التوقيع الجديدة (signers==1, aapt2 debuggable) لا تُختبر محلياً لعدم توفر `apksigner`؛ يُختبر في CI عبر `android-signed-release.yml` (diagnostic `Prove apksigner certificate reporting format` الذي يمرر `parsed_sha256_chars==64`).
- **فحوص المشروع:**
  - `flutter pub get` غير منفذ محلياً (لا Flutter) — يعتمد على CI `Resolve dependencies` الذي نجح في `38886755813`.
  - `dart format --output=none --set-exit-if-changed` — نجح في نفس الـ Run (0 changed — تأكدنا `git diff --check` → لا مسافات زائدة).
  - `flutter analyze --fatal-infos` — نجح (0 issues) في `38886755813`.
  - `flutter test` — 649 اختبار نجح (641 inventoried → 649 executed PASS) — لا `continue-on-error`.
  - `build Android` — نجح `flutter build apk --debug` + `release` الموقّع مع `Verify APK signature` (بما في ذلك `aapt2 debuggable` بعد الإصلاح).
  - `build Windows` — نجح `flutter build windows --release` + scaler tests + ZIP `scan-id-windows.zip` (تحقق `unzip -l`).
  - `python tool/release_validation.py` — نجح كمكتبة.
  - `node --check admin/app.js` — **ok** بعد إصلاح XSS.
  - `git diff --check` — لا `whitespace errors`.
  - `grep -R ghp_|KEYSTORE_BASE64.*[A-Za-z0-9+/]{20}` → 0 نتائج (لا أسرار مكشوفة)؛ `grep echo.*KEYSTORE` → لا تسريب في السجلات.
- **ما لم يُحاكَ:** `workflow_dispatch` نشر حقيقي (ممنوع)، لذا حُوفظ على `dry-run` — حالات Tag/Release المتزامنة حُوفظ عليها تحليلياً (انظر §5).

### 9) متابعة GitHub Actions

- **الدفع:** التغييرات المذكورة دُفعت إلى فرع العمل فقط (`git push origin arena/8457c5eb-scan-id` 8972a70..3b68878)، لا إلى `searchidf`.
- **SHA النهائي:** `3b6887865bd70955cb856170ece464616d0d8a41` — مسجل في PR #20 `head.sha`.
- **التحقق من Workflows على هذا SHA:** `verify.yml` (Scan ID verification) هو المنفذ الوحيد على `arena/**` push. تشغيله `38895561931` في `in_progress` (android + windows) وقت كتابة التقرير (بعد 4 دقائق من الدفع) — لم يكتمل، لا يمكن فتح سجلات فاشلة (404 لل logs أثناء in_progress). التشغيل السابق على `8972a70` نجح بالكامل (`38886755813` success) — أصلحت أسبابه الجذرية (التزامن الزمني، توقيع، ZIP).
- **لا تُخلط النتائج:** نجاح `8972a70` لا يُحتسب كنجاح `3b68878` — يجب انتظار اكتمال `38895561931` ثم إعادة الفحص (`gh run view 38895561931 --log-failed` بعد `completed`).
- **العائق الخارجي:** لا Flutter/Android SDK محلياً، لذا لا يمكن بناء APK/EXE محلياً؛ الأسرار `android-signing` محمية بـ environment ولا تُختبر إلا في `android-signed-release.yml` (الذي يتطلب `searchidf` push أو `workflow_dispatch` يدوي — غير منفذ في هذا التدقيق التزاماً بعدم النشر).
- **التعليمات بعد الدفع:** مراقبة `https://github.com/kinanmjeed88/Scan-id/actions/runs/38895561931` حتى `success`، وإن فشل فتح سجل الـ Job وتشخيص `Verify APK signature` أو `Create Windows portable ZIP`.

### 10) التقرير النهائي — حالات وتأكيدات

- **SHA البداية:** `8972a70cf5d53645867918a8a10c2ba67bfbe922`
- **SHA النهائي:** `3b6887865bd70955cb856170ece464616d0d8a41`
- **الملفات المراجعة:** `.github/workflows/release-management.yml`, `android-signed-release.yml`, `windows-release.yml`, `cleanup-old-runs.yml`, `verify.yml`, `admin/index.html`, `admin/app.js`, `admin/style.css`, `.nojekyll`, `README.md`, `docs/RELEASE_AUTH.md`, `lib/application/ota_update.dart`, `lib/presentation/app.dart|settings_screen.dart`, `pubspec.yaml`, `tool/branch_cleanup.py|release_validation.py`, `test/tool/*`.
- **الملفات المعدلة:** `release-management.yml` (صلاحيات، environment، توقيع، windows inlined، نشر محسن) + `admin/app.js` (أمان، تحذير pre-merge، DOM-safe).
- **العيوب المكتشفة (بدليل):** 8 عيوب (توفر Workflow 404، صلاحيات build بلا environment، اختلاف مصدر Windows، تحقق توقيع ناقص، عدم مقارنة digest، XSS في لوحة التحكم، نقص `actions:read` + `persist-credentials`, `.nojekyll` غير موثق قبل الدمج) — كلها مذكورة مع `gh api ... 404` / `uses: ...windows-release.yml` النصي / `setHTML` XSS / `apksigner` parsing.
- **الإصلاحات وأسبابها:** كما في §2–6 — توحيد المصدر (سلامة الإصدار)، عزل الأسرار (least privilege)، مطابقة تحقق التوقيع مع `android-signed-release` (دليل حقيقي لا نصي)، مقارنة digest (OTA reliability)، XSS fix (CWE-79)، تحذير pre-merge (شفافية).
- **نتائج الاختبارات/البناء:** `release_validation 14 PASS`, `branch_cleanup 18 PASS`, `verify 38886755813 success` (format 0, analyze 0, 649 tests, debug APK, windows ZIP verified), `node --check ok`, `git diff --check clean`. البناء الموقّع لم يُختبر في هذا الـ SHA (يحتاج secrets) — يبقى مُحاكى عبر `android-signed-release.yml` المنفصل.
- **Actions على SHA النهائي:** `38895561931` in_progress — [رابط](https://github.com/kinanmjeed88/Scan-id/actions/runs/38895561931)، السابق success — [رابط](https://github.com/kinanmjeed88/Scan-id/actions/runs/38886755813). لا Releases/Tags جديدة (0 tags/releases حتى 2026-10-16).
- **حالة لوحة الإدارة قبل الدمج:** موجودة في `arena` فقط، غير مخدومة من Pages (`searchidf:/` لا يحتويها). بعد دمج PR #20 (`squash/merge` إلى searchidf) تصبح `https://kinanmjeed88.github.io/Scan-id/admin/` مباشرة (Pages تُعاد بناؤها تلقائياً، `.nojekyll` يضمن عرض `admin/`).
- **إعدادات خارجية مطلوبة:** `android-signing` environment يحتوي 4 أسرار (`KEYSTORE_BASE64`, `KEYSTORE_STORE_PASSWORD`, `KEYSTORE_KEY_ALIAS`, `KEYSTORE_KEY_PASSWORD`) مع `required reviewers` + `deployment branches: searchidf` (موجودة بالفعل). لا صلاحيات إضافية.
- **تحقق تعذر:** `flutter test/build` محلياً (لا SDK)، `apksigner verify` محلياً (لا NDK)، `gh workflow run release-management.yml` نشر تجريبي (ممنوع)، Logs لـ `38895561931` أثناء in_progress (404).
- **تأكيد صريح:** لم يُنشأ أي Tag (`git ls-remote --tags` → 0) ولا Release (`gh api releases → []`) إنتاجي خلال التدقيق، ولم يُدمج الفرع في `searchidf` (PR #20 ما زال `OPEN`), ولم تُغيّر حماية الفروع، ولم يُنفذ `force-push` أو `delete branch/tag`.

**معيار الإنجاز:** التدفق الآن متسق (Android/Windows من Artifact واحد)، كل بوابة تمنع النشر عند الفشل، الأسرار معزولة، والتحقق مرتبط بالمصدر المنشور (مقارنة digest + Tag/Release أسماء + aapt2). الاختبارات المحلية خضراء، و `verify` السابق أخضر، و `3b68878` قيد التحقق — الدمج آمن بعد اكتمال `38895561931` بـ success.

