// Scan-id Release Dashboard.
// Reads public release data and dispatches the workflow with a short-lived,
// user-entered token. The token is never persisted or placed in a URL/log.
(function () {
  const OWNER = 'kinanmjeed88';
  const REPO = 'Scan-id';
  const API_BASE = 'https://api.github.com/repos/' + OWNER + '/' + REPO;
  const RAW_PUBSPEC = 'https://raw.githubusercontent.com/' + OWNER + '/' + REPO + '/searchidf/pubspec.yaml';
  const WORKFLOW_ID = 'release-management.yml';
  const WORKFLOW_REF = 'searchidf';
  const EL = {};

  function $(id) { return document.getElementById(id); }

  function initEls() {
    ['global-alert','status-loading','status-error','status-grid','code-version','code-branch','build-number','active-branch','active-branch-meta','last-tag','last-tag-date','last-release','last-release-date','android-status','android-link','windows-status','windows-link','signature-status','signature-meta','last-updated','refresh-btn','mismatch-warning','ota-compat','new-version','new-build','release-notes','target-android','target-windows','release-form','release-token','err-version','err-build','err-notes','err-targets','err-token','change-summary','sum-current','sum-proposed','sum-type','form-error','form-success','btn-create','btn-copy-gh','btn-open-actions','gh-command','cmd-text','copy-cmd','action-steps','recent-runs','runs-list','page-built'].forEach(function (id) { EL[id] = $(id); });
  }

  // --- SemVer 2.0.0 port from Dart (_SemVersion) ---
  function parseSemVer(v) {
    var m = v.match(/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/);
    if (!m) return null;
    var pr = m[4] ? m[4].split('.') : [];
    for (var i = 0; i < pr.length; i++) {
      var id = pr[i];
      if (/^[0-9]+$/.test(id) && id.length > 1 && id[0] === '0') return null;
    }
    return { major: m[1], minor: m[2], patch: m[3], prerelease: pr, core: m[1]+'.'+m[2]+'.'+m[3], prStr: m[4]||'', build: m[5]||'' };
  }
  function parseReleaseVersion(v){
    var parsed = parseSemVer(v);
    // The workflow adds `build_number` to pubspec itself; accepting +metadata
    // here would send a version it will reject or duplicate the build suffix.
    return parsed && !parsed.build ? parsed : null;
  }

  function compareSemVer(a, b) {
    var pa = parseSemVer(a), pb = parseSemVer(b);
    if (!pa || !pb) throw new Error('Invalid SemVer: '+(pa?b:a));
    function cmpNum(x,y){
      if (x.length !== y.length) return x.length - y.length;
      return x < y ? -1 : x > y ? 1 : 0;
    }
    var c = cmpNum(pa.major, pb.major); if(c) return c>0?1:-1;
    c = cmpNum(pa.minor, pb.minor); if(c) return c>0?1:-1;
    c = cmpNum(pa.patch, pb.patch); if(c) return c>0?1:-1;
    var pra = pa.prerelease, prb = pb.prerelease;
    if (pra.length===0 && prb.length===0) return 0;
    if (pra.length===0) return 1;
    if (prb.length===0) return -1;
    for (var i=0;i<Math.min(pra.length,prb.length);i++){
      var la=pra[i], ra=prb[i];
      var na = /^[0-9]+$/.test(la), nb = /^[0-9]+$/.test(ra);
      var o;
      if (na && nb) o = la.length!==ra.length ? (la.length<ra.length?-1:1) : (la<ra?-1:la>ra?1:0);
      else if (na!==nb) o = na ? -1 : 1;
      else o = la<ra?-1:la>ra?1:0;
      if(o) return o;
    }
    return pra.length - prb.length;
  }
  function extractVersion(tag){
    var v = tag;
    if (v[0]==='v') v = v.slice(1);
    if (v.indexOf('release-')===0) v = v.slice(8);
    return parseSemVer(v) ? v : null;
  }

  function show(el, yes){ if(el) el.classList.toggle('hidden', !yes); }
  function setText(id, t){ var e = typeof id==='string'? EL[id] : id; if(e) e.textContent = t; }
  function setHTML(id, h){ var e = typeof id==='string'? EL[id] : id; if(e) e.innerHTML = h; }
  // Safe DOM helpers (prevent XSS from GitHub API data)
  function setLink(containerId, href, text, suffix){
    var c = typeof containerId==='string'? EL[containerId] : containerId;
    if (!c) return;
    c.textContent = '';
    var a = document.createElement('a');
    a.href = href;
    a.target = '_blank';
    a.rel = 'noopener noreferrer';
    a.textContent = text;
    c.appendChild(a);
    if (suffix) c.appendChild(document.createTextNode(suffix));
  }
  function escapeHtml(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }
  function sanitizeReleaseNotesForDisplay(s){
    // Render as text only — never as HTML
    var div = document.createElement('div');
    div.textContent = s;
    return div.textContent;
  }

  var state = {
    currentCore: null, currentBuild: null, currentPubspec: null,
    lastTag: null, lastRelease: null, lastReleaseDate: null,
    defaultBranch: 'searchidf', dispatching: false
  };

  async function fetchJSON(url, opts){
    var r = await fetch(url, opts||{});
    if (!r.ok) {
      var txt = await r.text().catch(function(){return '';});
      var err = new Error('HTTP '+r.status+' '+txt.slice(0,200));
      err.status = r.status; throw err;
    }
    return r.json();
  }
  async function fetchText(url){
    var r = await fetch(url);
    if (!r.ok) throw new Error('HTTP '+r.status);
    return r.text();
  }

  async function loadStatus(){
    show(EL['status-loading'], true);
    show(EL['status-error'], false);
    show(EL['status-grid'], false);
    var errors = [];
    try {
      // 1. pubspec
      var pubspecText = await fetchText(RAW_PUBSPEC);
      var m = pubspecText.match(/^version:\s*([^\s#]+)/m);
      var pubVer = m ? m[1].trim() : null;
      if (pubVer) {
        var core = pubVer.split('+')[0];
        var build = pubVer.split('+')[1] || '1';
        state.currentCore = core; state.currentBuild = build; state.currentPubspec = pubVer;
        setText('code-version', core + ' ('+pubVer+')');
        setText('build-number', build);
        setText('code-branch', 'فرع: searchidf');
        setText('active-branch', 'searchidf');
        setText('active-branch-meta', 'الافتراضي (Pages & النشر)');
      } else throw new Error('pubspec version missing');

      // 2. default branch
      try {
        var repo = await fetchJSON(API_BASE);
        state.defaultBranch = repo.default_branch || 'searchidf';
        setText('active-branch', state.defaultBranch);
      } catch(e){ errors.push('default_branch: '+e.message); }

      // 3. tags
      try {
        var tags = await fetchJSON(API_BASE + '/tags?per_page=20');
        if (tags.length) {
          var tag = tags[0];
          state.lastTag = tag.name;
          setText('last-tag', tag.name);
          setText('last-tag-date', tag.commit.sha.slice(0,7));
        } else {
          setText('last-tag','لا يوجد');
          setText('last-tag-date','404 - لم يُنشأ Tag بعد');
        }
      } catch(e){
        if (e.status===404) { setText('last-tag','لا يوجد'); setText('last-tag-date','لم يُنشأ بعد'); }
        else errors.push('tags: '+e.message);
      }

      // 4. release
      try {
        var rel = await fetchJSON(API_BASE + '/releases/latest');
        state.lastRelease = rel.tag_name;
        state.lastReleaseDate = rel.published_at;
        setText('last-release', rel.tag_name);
        setText('last-release-date', new Date(rel.published_at).toLocaleString('ar-IQ'));
        // OTA compat check
        var assets = rel.assets||[];
        var hasApk = assets.some(function(a){return a.name.endsWith('.apk');});
        var hasZip = assets.some(function(a){return a.name.endsWith('.zip')||a.name.endsWith('.exe')||a.name.endsWith('.msi');});
        var missingDigest = assets.filter(function(a){return !a.digest;}).length;
        if (hasApk && hasZip) {
          show(EL['ota-compat'], true);
          EL['ota-compat'].textContent = '✓ OTA متوافق: APK + ZIP + digest:'+(missingDigest?' تحذير '+missingDigest+' بلا digest':' ✓');
          EL['ota-compat'].className = missingDigest? 'alert alert-warning' : 'alert alert-success';
        } else {
          show(EL['ota-compat'], true);
          EL['ota-compat'].textContent = '⚠ OTA غير مكتمل: '+(hasApk?'APK ✓':'APK ✗')+' '+(hasZip?'ZIP ✓':'ZIP ✗');
          EL['ota-compat'].className = 'alert alert-warning';
        }
      } catch(e){
        if (e.status===404) {
          setText('last-release','لا يوجد'); setText('last-release-date','لم يُنشر Release بعد');
          state.lastRelease = null;
        } else errors.push('release: '+e.message);
      }

      // 5. actions runs
      try {
        var runs = await fetchJSON(API_BASE + '/actions/workflows/verify.yml/runs?per_page=3');
        var last = runs.workflow_runs && runs.workflow_runs[0];
        if (last) {
          // Android verification is part of verify.yml -> android job
          // We show last verify run as proxy for both platforms
          // For granular, fetch android-signed and windows
        }
        var workflowAvailable = true;
        try { await fetchJSON(API_BASE + '/actions/workflows/release-management.yml'); }
        catch(e){ if (e.status===404) { workflowAvailable = false; errors.push('release-management workflow غير موجود في searchidf — الأمر gh غير صالح قبل الدمج (PR #20)'); } }

        var androidRuns = await fetchJSON(API_BASE + '/actions/workflows/android-signed-release.yml/runs?per_page=1');
        var ar = androidRuns.workflow_runs && androidRuns.workflow_runs[0];
        if (ar) {
          setText('android-status', ar.conclusion || ar.status);
          var cls = ar.conclusion==='success'?'success':ar.conclusion==='failure'?'error':'warning';
          EL['android-status'].className = 'status-value badge-'+cls;
          setLink('android-link', ar.html_url, 'فتح السجل', ' — '+new Date(ar.created_at).toLocaleString('ar-IQ'));
        } else { setText('android-status','لا يوجد'); setText('android-link','—'); }
        // Windows: prefer release-management workflow (inline job post-merge), fallback to standalone
        var winStatusSet = false;
        if (workflowAvailable) {
          try {
            var rmRuns = await fetchJSON(API_BASE + '/actions/workflows/release-management.yml/runs?per_page=1');
            var rmr = rmRuns.workflow_runs && rmRuns.workflow_runs[0];
            if (rmr) { setText('windows-status', rmr.conclusion||rmr.status); if (rmr.html_url) setLink('windows-link', rmr.html_url, 'فتح السجل', ''); winStatusSet = true; }
          } catch(e){}
        }
        if (!winStatusSet) {
          var winRuns = await fetchJSON(API_BASE + '/actions/workflows/windows-release.yml/runs?per_page=1');
          if (winRuns.workflow_runs && winRuns.workflow_runs[0]) {
            var wr = winRuns.workflow_runs[0];
            setText('windows-status', wr.conclusion||wr.status);
            if (wr.html_url) setLink('windows-link', wr.html_url, 'فتح السجل', '');
            winStatusSet = true;
          } else if (last) {
            setText('windows-status', last.conclusion||last.status);
            if (last.html_url) setLink('windows-link', last.html_url, 'فتح السجل', '');
            winStatusSet = true;
          }
        }
        if (!winStatusSet || !EL['windows-link'].textContent || EL['windows-link'].textContent==='—') {
          try {
            var verifyRuns = await fetchJSON(API_BASE + '/actions/workflows/verify.yml/runs?per_page=1');
            var vr = verifyRuns.workflow_runs && verifyRuns.workflow_runs[0];
            if (vr) {
              if (!winStatusSet) setText('windows-status', vr.conclusion||vr.status);
              if (vr.html_url) setLink('windows-link', vr.html_url, 'فتح السجل', '');
            }
          } catch(e){}
        }
      } catch(e){ errors.push('actions: '+e.message); }

      // Signature status (public cert fingerprint)
      setText('signature-status','EXPECTED_CERT_SHA256');
      setText('signature-meta','3e9c...74a — يُتحقق في Workflow (لا يُطبع السر)');

      // Mismatch warning
      if (state.currentCore && state.lastRelease) {
        var relVer = extractVersion(state.lastRelease);
        if (relVer && compareSemVer(state.currentCore, relVer) !==0) {
          show(EL['mismatch-warning'], true);
          EL['mismatch-warning'].textContent = '⚠ اختلاف: إصدار الكود ('+state.currentCore+') ≠ آخر Release ('+relVer+') — قد يحتاج نشر أو رفع Core.';
        } else {
          show(EL['mismatch-warning'], false);
        }
      }

      setText('last-updated', 'آخر تحديث: '+new Date().toLocaleString('ar-IQ'));
      show(EL['status-loading'], false);
      show(EL['status-grid'], true);
      if (errors.length) {
        show(EL['global-alert'], true);
        EL['global-alert'].className='alert alert-warning';
        EL['global-alert'].textContent = 'تحذير: '+errors.join(' | ');
      } else {
        show(EL['global-alert'], false);
      }
      // Prefill form with next suggestions
      prefillForm();
      loadRecentRuns();
    } catch(e){
      show(EL['status-loading'], false);
      show(EL['status-error'], true);
      EL['status-error'].textContent = 'تعذر جلب البيانات: '+e.message+' — تحقق من الشبكة أو GitHub API rate limit (60/h بدون مصادقة).';
      var retryBtn = document.createElement('button'); retryBtn.className='btn btn-small'; retryBtn.textContent='إعادة المحاولة'; retryBtn.addEventListener('click', function(){ location.reload(); }); EL['status-error'].appendChild(document.createTextNode(' ')); EL['status-error'].appendChild(retryBtn);
    }
  }

  function prefillForm(){
    if (!state.currentCore) return;
    // Suggest next patch
    var parts = state.currentCore.split('.');
    var nextPatch = parts[0]+'.'+parts[1]+'.'+(parseInt(parts[2])+1);
    var nextBuild = state.currentBuild ? String(parseInt(state.currentBuild)+1) : '2';
    if (!EL['new-version'].value) EL['new-version'].placeholder = nextPatch;
    if (!EL['new-build'].value) EL['new-build'].placeholder = nextBuild;
    // If user hasn't typed, set test values as placeholder not value (spec says test values are only test inputs, not assumptions)
    EL['release-notes'].placeholder = 'تحسينات وإصلاحات';
  }

  function updateSummary(){
    var v = EL['new-version'].value.trim();
    var b = EL['new-build'].value.trim();
    if (!v || !b) { show(EL['change-summary'], false); return; }
    var cur = state.currentPubspec || (state.currentCore+'+'+state.currentBuild);
    var prop = v+'+'+b;
    setText('sum-current', cur);
    setText('sum-proposed', prop);
    try {
      var proposed = parseReleaseVersion(v);
      if (!proposed) { setText('sum-type','صيغة غير صالحة؛ رقم البناء منفصل'); return; }
      var cmp = compareSemVer(v, state.currentCore);
      var current = parseSemVer(state.currentCore);
      var type = cmp>0 ? (proposed.major!==current.major ? 'major': proposed.minor!==current.minor ? 'minor':'patch') : cmp===0 ? 'نفس Core (build فقط)' : 'أقدم!';
      setText('sum-type', type + (cmp<=0?' ⚠':' ✓'));
    } catch(e){ setText('sum-type','خطأ: '+e.message); }
    show(EL['change-summary'], true);
  }

  function selectedTargets(){
    var android = EL['target-android'].checked;
    var windows = EL['target-windows'].checked;
    if (android && windows) return 'both';
    if (android) return 'android';
    if (windows) return 'windows';
    return '';
  }

  function shellQuote(value){
    return "'" + String(value).replace(/'/g, "'\\''") + "'";
  }

  function validate(requireToken){
    var ok = true;
    var v = EL['new-version'].value.trim();
    var b = EL['new-build'].value.trim();
    var notes = EL['release-notes'].value.trim();
    var targets = selectedTargets();
    var token = EL['release-token'].value.trim();
    // reset
    ['err-version','err-build','err-notes','err-targets','err-token','form-error'].forEach(function(id){ show(EL[id], false); });
    // version
    if (!v) { show(EL['err-version'], true); EL['err-version'].textContent='مطلوب'; ok=false; }
    else if (!parseReleaseVersion(v)) { show(EL['err-version'], true); EL['err-version'].textContent='صيغة SemVer غير صالحة؛ لا تضف +build metadata لأن رقم البناء في حقل مستقل (مثال 0.1.1 أو 1.0.0-rc.1)'; ok=false; }
    else if (state.currentCore) {
      try {
        if (compareSemVer(v, state.currentCore) <=0) { show(EL['err-version'], true); EL['err-version'].textContent='يجب أن يكون أحدث من الكود الحالي ('+state.currentCore+')'; ok=false; }
        if (state.lastRelease) {
          var relVer = extractVersion(state.lastRelease);
          if (relVer && compareSemVer(v, relVer) <=0) { show(EL['err-version'], true); EL['err-version'].textContent='يجب أن يكون أحدث من آخر Release ('+relVer+')'; ok=false; }
        }
      } catch(e){ show(EL['err-version'], true); EL['err-version'].textContent=e.message; ok=false; }
      // duplicate tag check (public API already fetched tags)
      if (state.lastTag === 'v'+v) { show(EL['err-version'], true); EL['err-version'].textContent='Tag v'+v+' موجود مسبقاً'; ok=false; }
    }
    // build
    if (!b) { show(EL['err-build'], true); EL['err-build'].textContent='مطلوب'; ok=false; }
    else if (!/^[0-9]+$/.test(b) || parseInt(b)<1) { show(EL['err-build'], true); EL['err-build'].textContent='رقم بناء موجب فقط'; ok=false; }
    else if (state.currentCore && v===state.currentCore && parseInt(b) <= parseInt(state.currentBuild)) { show(EL['err-build'], true); EL['err-build'].textContent='يجب أن يكون أكبر من '+state.currentBuild+' لنفس Core'; ok=false; }
    // notes
    if (!notes) { show(EL['err-notes'], true); EL['err-notes'].textContent='مطلوب'; ok=false; }
    else if (notes.length<3) { show(EL['err-notes'], true); EL['err-notes'].textContent='قصير جداً (≥3)'; ok=false; }
    else if (notes.length>5000) { show(EL['err-notes'], true); EL['err-notes'].textContent='طويل جداً (>5000)'; ok=false; }
    // targets (the workflow accepts `both`, not `android,windows`)
    if (!targets) { show(EL['err-targets'], true); EL['err-targets'].textContent='اختر نظاماً واحداً على الأقل'; ok=false; }
    // Dashboard tokens are used only by the dispatch request and are not stored.
    if (requireToken && !token) { show(EL['err-token'], true); EL['err-token'].textContent='أدخل توكن الإطلاق المؤقت لإرسال الطلب إلى GitHub'; ok=false; }
    // branch check
    if (state.defaultBranch !== 'searchidf') {
      // This is just warning in UI, hard check in Workflow
    }
    return ok;
  }

  function buildGhCommand(){
    var v = EL['new-version'].value.trim();
    var b = EL['new-build'].value.trim();
    var notes = EL['release-notes'].value.trim();
    var targets = selectedTargets();
    if (!v || !b || !targets) return '';
    return 'gh workflow run ' + WORKFLOW_ID + ' --ref ' + WORKFLOW_REF +
      ' -f version=' + shellQuote(v) +
      ' -f build_number=' + shellQuote(b) +
      ' -f release_notes=' + shellQuote(notes) +
      ' -f targets=' + shellQuote(targets);
  }

  async function dispatchRelease(token, release){
    var response;
    try {
      response = await fetch(API_BASE + '/actions/workflows/' + WORKFLOW_ID + '/dispatches', {
        method: 'POST',
        mode: 'cors',
        cache: 'no-store',
        credentials: 'omit',
        redirect: 'error',
        referrerPolicy: 'no-referrer',
        headers: {
          'Accept': 'application/vnd.github+json',
          'Authorization': 'Bearer ' + token,
          'Content-Type': 'application/json',
          'X-GitHub-Api-Version': '2022-11-28'
        },
        body: JSON.stringify({
          ref: WORKFLOW_REF,
          inputs: {
            version: release.version,
            build_number: release.build,
            release_notes: release.notes,
            targets: release.targets
          }
        })
      });
    } catch{
      throw new Error('تعذر الاتصال بـ GitHub API. تحقق من الشبكة أو إعدادات المتصفح؛ لا تعاود الإرسال قبل مراجعة التشغيلات الأخيرة فقد يكون الطلب وصل.');
    }

    if (response.status === 204) return;
    var payload = await response.json().catch(function(){ return {}; });
    var detail = payload && payload.message ? String(payload.message).slice(0, 240) : '';
    var message;
    if (response.status === 401) {
      message = 'توكن اللوحة غير صالح أو منتهي الصلاحية.';
    } else if (response.status === 403) {
      message = 'رفض GitHub الطلب: امنح توكن اللوحة صلاحية Actions: write لهذا المستودع فقط، وتأكد من تفعيل Actions.';
    } else if (response.status === 404) {
      message = 'لم يجد GitHub سير العمل أو لم يسمح التوكن بالوصول إليه؛ تحقق من وجود release-management.yml على الفرع الافتراضي وصلاحية Actions: write.';
    } else if (response.status === 422) {
      message = 'رفض GitHub مدخلات تشغيل سير العمل (HTTP 422). تحقق من قيم الإصدار والنظام المستهدف.';
    } else {
      message = 'تعذر إطلاق سير العمل (HTTP ' + response.status + ').';
    }
    if (detail) message += ' ' + detail;
    var dispatchError = new Error(message);
    dispatchError.status = response.status;
    throw dispatchError;
  }

  async function loadRecentRuns(){
    try {
      var data = await fetchJSON(API_BASE + '/actions/workflows/' + WORKFLOW_ID + '/runs?per_page=3', { cache: 'no-store' });
      var runs = data.workflow_runs||[];
      if (!runs.length) {
        // fallback to any workflow
        var any = await fetchJSON(API_BASE + '/actions/runs?per_page=3', { cache: 'no-store' });
        runs = any.workflow_runs.slice(0,3);
      }
      if (!runs.length) return;
      show(EL['recent-runs'], true);
      // Build DOM safely (textContent for names, href via DOM API to prevent XSS)
      EL['runs-list'].textContent = '';
      runs.forEach(function(r){
        var item = document.createElement('div'); item.className = 'run-item';
        var left = document.createElement('div');
        var strong = document.createElement('strong'); strong.textContent = r.name || 'run'; left.appendChild(strong);
        left.appendChild(document.createTextNode(' #' + (r.run_number || '')));
        left.appendChild(document.createElement('br'));
        var small = document.createElement('small'); small.textContent = new Date(r.created_at).toLocaleString('ar-IQ'); left.appendChild(small);
        item.appendChild(left);
        var badge = document.createElement('span'); badge.className = 'run-badge ' + (r.conclusion==='success'?'success':r.conclusion==='failure'?'failure':'in_progress'); badge.textContent = r.conclusion||r.status||''; item.appendChild(badge);
        var a = document.createElement('a'); a.href = r.html_url; a.target = '_blank'; a.rel = 'noopener noreferrer'; a.className = 'btn btn-small'; a.textContent = 'فتح'; item.appendChild(a);
        EL['runs-list'].appendChild(item);
      });
    } catch(e){}
  }

  async function submitRelease(){
    if (state.dispatching) return;
    if (!validate(true)) {
      show(EL['form-error'], true);
      EL['form-error'].textContent='صحّح الحقول المطلوبة قبل إرسال الطلب.';
      return;
    }

    var releaseToken = EL['release-token'].value.trim();
    var release = {
      version: EL['new-version'].value.trim(),
      build: EL['new-build'].value.trim(),
      notes: EL['release-notes'].value.trim(),
      targets: selectedTargets()
    };
    var runUrl = 'https://github.com/' + OWNER + '/' + REPO + '/actions/workflows/' + WORKFLOW_ID;

    show(EL['form-error'], false);
    show(EL['form-success'], false);
    show(EL['gh-command'], false);
    show(EL['action-steps'], true);
    state.dispatching = true;
    EL['btn-create'].disabled = true;
    EL['btn-create'].setAttribute('aria-busy', 'true');
    EL['btn-create'].textContent = 'جارٍ إرسال طلب البناء...';
    // Clear the visible field immediately. The token is only kept in this
    // function's memory for the single HTTPS request; it is never persisted.
    EL['release-token'].value = '';

    try {
      await dispatchRelease(releaseToken, release);
      show(EL['form-success'], true);
      EL['form-success'].textContent = 'استلم GitHub طلب الإصدار ' + release.version + '+' + release.build +
        ' (' + release.targets + '). يجري البناء والنشر في الخلفية؛ سيظهر التشغيل هنا بعد قليل. بعد نجاح النشر يصبح الإصدار متاحاً لفحص OTA داخل التطبيق.';
      var link = document.createElement('a');
      link.href = runUrl;
      link.target = '_blank';
      link.rel = 'noopener noreferrer';
      link.textContent = 'فتح سجل Actions اختيارياً';
      EL['form-success'].appendChild(document.createElement('br'));
      EL['form-success'].appendChild(link);
      window.setTimeout(loadRecentRuns, 2500);
      window.setTimeout(loadStatus, 7000);
    } catch(error){
      show(EL['form-error'], true);
      EL['form-error'].textContent = error.message || 'فشل إرسال طلب البناء إلى GitHub.';
    } finally {
      // Best-effort clearing of the transient JavaScript reference.
      releaseToken = '';
      state.dispatching = false;
      EL['btn-create'].disabled = false;
      EL['btn-create'].removeAttribute('aria-busy');
      EL['btn-create'].textContent = 'إرسال وبدء البناء والنشر';
    }
  }

  function bindEvents(){
    ['new-version','new-build','release-notes','target-android','target-windows'].forEach(function(id){
      var el = EL[id];
      if (el) el.addEventListener('input', function(){ validate(false); updateSummary(); updateGhCommand(); });
    });
    EL['release-token'].addEventListener('input', function(){ show(EL['err-token'], false); });
    EL['release-form'].addEventListener('submit', function(event){
      event.preventDefault();
      submitRelease();
    });
    EL['refresh-btn'].addEventListener('click', loadStatus);
    EL['btn-copy-gh'].addEventListener('click', function(){
      if (!validate(false)) return;
      var cmd = buildGhCommand();
      show(EL['gh-command'], true);
      EL['cmd-text'].textContent = cmd;
      EL['action-steps'].classList.remove('hidden');
    });
    EL['copy-cmd'].addEventListener('click', function(){
      var txt = EL['cmd-text'].textContent;
      navigator.clipboard.writeText(txt).then(function(){
        EL['copy-cmd'].textContent='✓ نُسخ';
        setTimeout(function(){ EL['copy-cmd'].textContent='نسخ'; },1500);
      }).catch(function(){
        EL['copy-cmd'].textContent='تعذر النسخ';
        setTimeout(function(){ EL['copy-cmd'].textContent='نسخ'; },1500);
      });
    });
    EL['btn-create'].addEventListener('click', submitRelease);
  }

  function updateGhCommand(){
    var cmd = buildGhCommand();
    if (cmd) { EL['cmd-text'].textContent = cmd; }
  }

  document.addEventListener('DOMContentLoaded', function(){
    initEls();
    EL['page-built'].textContent = new Date().toLocaleString('ar-IQ');
    loadStatus();
    bindEvents();
    setInterval(loadStatus, 60000);
  });
})();
