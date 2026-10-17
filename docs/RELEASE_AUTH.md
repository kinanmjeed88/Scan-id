# مصادقة إدارة الإصدارات — Scan-id

## التوكنان منفصلان

1. **توكن لوحة الإدارة (لإطلاق التشغيل فقط):** تكتب Fine-grained PAT في حقل كلمة المرور عند كل إرسال. يحتاج صلاحية `Actions: write` لمستودع `kinanmjeed88/Scan-id` فقط. يرسله المتصفح مباشرةً إلى GitHub API عبر HTTPS لطلب `workflow_dispatch` على الفرع `searchidf`، ثم يُفرغ الحقل ولا يُحفظ في `localStorage` أو `sessionStorage` أو URL أو السجلات. لا يمكن لصفحة GitHub Pages قراءة أسرار Actions. لا تلصق في هذا الحقل سر `RELEASE_TOKEN`.
2. **سر سير العمل `RELEASE_TOKEN` (للكتابة والنشر من Actions):** أضفه كـ **Repository secret** بالاسم الدقيق `RELEASE_TOKEN` من `Settings → Secrets and variables → Actions`. لا تضفه كـ Variable أو كسرّ خاص ببيئة `android-signing`؛ سير التحقق والنشر يقرؤه عبر `${{ secrets.RELEASE_TOKEN }}`. استخدم Fine-grained PAT مقيّداً بهذا المستودع، بصلاحية `Contents: read and write` و`Actions: read`، وحدد مدة صلاحية مناسبة. هذا السر يبقى داخل GitHub Actions ولا يصل إلى صفحة الإدارة.

لا تضع أيّاً من قيم التوكن في ملفات المستودع أو في المحادثة. صلاحية Actions في توكن اللوحة تمنح إمكانية إطلاق سير العمل؛ لذلك اجعله محدوداً بالمستودع، قصير العمر، ولا تستخدم توكن الكتابة الأوسع `RELEASE_TOKEN` في المتصفح. ما يزال التوكن المؤقت متاحاً لشفرة الصفحة أثناء الإرسال، لذا لا تستخدمه إلا من النسخة الموثوقة من لوحة الإدارة.

## طريقة الإطلاق ومسار التحديث

1. افتح `https://kinanmjeed88.github.io/Scan-id/admin/`.
2. أدخل `version`, `build_number`, `release_notes`, النظام المستهدف، وتوكن اللوحة المؤقت.
3. يتحقق المتصفح من المدخلات ثم يرسل `POST /repos/kinanmjeed88/Scan-id/actions/workflows/release-management.yml/dispatches` مع `ref: searchidf`. عند نجاح الإرسال يبقى المستخدم في الصفحة، ويعرض اللوح رسالة القبول ويحدّث قائمة التشغيلات. قيم `targets` المسموحة هي `both`, `android`, أو `windows`.
4. يتحقق Workflow مجدداً من `github.ref == refs/heads/searchidf` وأن `github.actor` هو مالك المستودع، ومن `concurrency`, وSemVer, ورقم البناء، وملاحظات الإصدار، وعدم تكرار Tag/Release.
5. ينفّذ Workflow: التحقق → تحديث `pubspec.yaml` و`lib/application/app_release.dart` → الاختبارات والبناء للنظام/الأنظمة المختارة → فحص التوقيع والأصول → دفع التغيير وإنشاء Tag وGitHub Release والتحقق من SHA-256.
6. بعد نجاح النشر، تصبح الأصول متاحة لفحص OTA داخل التطبيق. لا يُثبّت التطبيق التحديث بصمت؛ يتبع التطبيق آلية التحقق والتأكيد المعتادة.

استجابة GitHub الناجحة لإطلاق `workflow_dispatch` هي `204`؛ تعني قبول الطلب فقط، لا نجاح البناء. راجع التشغيلات الأخيرة من نفس الصفحة، أو افتح سجل Actions يدوياً عند الحاجة. فشل الاختبارات أو التوقيع أو النشر سيبقى فشلاً ولن يُنشر إصدار OTA غير مكتمل.

## حدود الصلاحيات

- `validate`: صلاحيات `GITHUB_TOKEN` هي `contents: read` و`actions: read`؛ يستخدم قراءة المستودع و`RELEASE_TOKEN` لاستدعاءات GitHub API.
- `update-version`, `build`, و`windows`: `contents: read` فقط.
- `publish`: `contents: write`؛ يستخدم `RELEASE_TOKEN` للـ commit/tag/push وإنشاء الـ Release.
- توكن لوحة الإدارة: `Actions: write` فقط لإطلاق Workflow، منفصل عن سر النشر.

## ما لا يحدث

- لا يُضمَّن أي توكن ثابت في الصفحة أو الشيفرة.
- لا تُخزَّن قيمة توكن اللوحة في المتصفح ولا توضع في URL أو نصوص الصفحة أو السجلات.
- لا يُنشأ Release قبل نجاح متطلبات البناء والتحقق.
- لا Force Push، ولا حذف Tags/Releases، ولا تثبيت صامت على أجهزة المستخدمين.
