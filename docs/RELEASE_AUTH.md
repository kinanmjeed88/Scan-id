# مصادقة إدارة الإصدارات — Scan-id

## المبدأ
- **لا PAT ثابت في الصفحة:** `admin/index.html` و`admin/app.js` لا يحتويان أي سر. تحقق: `grep -r token admin/` → 0 (كلمة token تظهر فقط في التوثيق).
- **الجهة الموثوقة:** GitHub Actions فقط (`release-management.yml`) يملك `GITHUB_TOKEN` مع `contents: write` في مهمة النشر، وباقي المهام `read`.
- **التحقق من الهوية:** كل تشغيل يفحص `actor permission` عبر `gh api repos/<repo>/collaborators/<actor>/permission` — يجب أن يكون `admin/write/maintain`، وإلا يفشل.

## كيف يُطلق الإصدار بأمان
1. المستخدم يفتح `https://kinanmjeed88.github.io/Scan-id/admin/` (Pages من `searchidf /`).
2. يملأ `version, build_number, release_notes, targets` — الواجهة تتحقق محلياً بـ SemVer نفس منطق Dart (`_SemVersion.parse`).
3. يضغط **إنشاء إصدار ونشر** → تُبنى `gh workflow run release-management.yml -f version=...` **ولا يُرسل PAT** — يُعرض الأمر للنسخ + زر **فتح Actions**.
4. المستخدم يسجل دخوله إلى GitHub (مصادقة GitHub نفسها) → `Actions → Release Management → Run workflow` → يلصق القيم → `Run`.
5. الـ Workflow يتحقق من `github.ref == refs/heads/searchidf`, `concurrency: release-management`, عدم وجود نشر متزامن, SemVer, عدم تكرار Tag, `build_number` موجب, `release_notes` 3–5000, اختلاف كود/Release → ثم يحدّث `pubspec.yaml` + `app.dart` بعد التحقق فقط (لا `git checkout --` للتراجع).

## الصلاحيات الدنيا
- `validate`: `contents: read, actions: read`
- `update-version`/`build`: `contents: read`
- `publish`: `contents: write` فقط هنا
- `windows`: `contents: read`

## الخيارات المستقبلية (غير مفعّلة الآن)
- **PAT مؤقت fine-grained** (`contents:write, actions:write`, expiry 7 أيام) يُدخل في حقل مؤقت لا يُخزن (`let token` في الذاكرة يُمسح بعد `fetch`), لكنه غير موصى به — الوثيقة الحالية تفضّل Deep-link.
- **GitHub App** مع `permissions: contents:write, actions:write` و`OAuth PKCE` — يتطلب خادم تبادل code→token (خارج Pages). إذا احتاج المالك إعداده، سيُضاف `admin/backend` منفصل.

## ماذا لا يحدث
- لا يُخزن PAT في `localStorage/sessionStorage` أو `URL` أو سجلات.
- لا يُطبع Secret في logs (فقط أسماء: `KEYSTORE_BASE64: present/MISSING`).
- لا يُنشأ Tag/Release قبل نجاح `analyze, test, build, sign`.
- لا Force Push, لا حذف Tags/Releases, لا دمج PRs تلقائياً.
