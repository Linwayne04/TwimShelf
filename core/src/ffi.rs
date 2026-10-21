//! C ABI surface for the Swift apps. Complex values cross as UTF-8 JSON in an
//! `{"ok": …}` / `{"error": "…"}` envelope; every returned string is freed with `tl_string_free`.
use crate::archive;
use crate::download::{self, DownloadRequest};
use crate::library::{FeedRequest, Library};
use crate::model::Origin;
use serde::Deserialize;
use std::ffi::{c_char, CStr, CString};
use std::path::Path;
use std::sync::{Arc, Mutex};

static LIB: Mutex<Option<Arc<Library>>> = Mutex::new(None);

fn s(p: *const c_char) -> String {
    if p.is_null() { return String::new(); }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}
fn out(v: String) -> *mut c_char { CString::new(v).map_or(std::ptr::null_mut(), CString::into_raw) }
fn lib() -> anyhow::Result<Arc<Library>> {
    LIB.lock().unwrap().clone().ok_or_else(|| anyhow::anyhow!("library not open"))
}
fn with<T: serde::Serialize>(f: impl FnOnce(Arc<Library>) -> anyhow::Result<T>) -> *mut c_char {
    // A Rust panic must never unwind into Swift (that aborts the app): report it as an error.
    let r = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| lib().and_then(f))) {
        Ok(r) => r,
        Err(p) => Err(anyhow::anyhow!("内部错误：{}", p.downcast_ref::<&str>().map(|s| s.to_string()).or_else(|| p.downcast_ref::<String>().cloned()).unwrap_or_default())),
    };
    out(match r {
        Ok(v) => serde_json::json!({ "ok": v }).to_string(),
        Err(e) => serde_json::json!({ "error": format!("{e:#}") }).to_string(),
    })
}

/// Every exported function runs under `catch_unwind` (directly or through `with`): a Rust panic
/// unwinding into Swift aborts the app. These are for functions that do not use `with`.
fn guard<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(fallback)
}
fn guard_ptr(f: impl FnOnce() -> *mut c_char) -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or_else(|p| {
        let m = p.downcast_ref::<&str>().map(|s| s.to_string()).or_else(|| p.downcast_ref::<String>().cloned()).unwrap_or_default();
        out(serde_json::json!({ "error": format!("内部错误：{m}") }).to_string())
    })
}

/// A setting shared by every device (`null` = the default).
#[no_mangle]
pub extern "C" fn tl_setting(key: *const c_char) -> *mut c_char { with(|l| Ok(l.db().setting(&s(key))?)) }

/// Changes a shared setting on every device; `value` NULL = back to the default.
#[no_mangle]
pub extern "C" fn tl_set_setting(key: *const c_char, value: *const c_char) -> *mut c_char {
    with(|l| { let v = (!value.is_null()).then(|| s(value)); l.db().set_setting(&s(key), v.as_deref())?; Ok(()) })
}

/// Returns the FxTwitter API URL for a status link, or NULL.
#[no_mangle]
pub extern "C" fn tl_fx_api_url(url: *const c_char) -> *mut c_char { guard_ptr(|| {
    crate::bookmarks::to_fx_api(&s(url)).map_or(std::ptr::null_mut(), out)
}) }

/// Opens (or creates) the library at `dir`. Returns true on success.
#[no_mangle]
pub extern "C" fn tl_open(dir: *const c_char) -> bool { guard(false, || {
    let d = s(dir);
    crate::diagnostics::install_panic_hook(Path::new(&d));
    match Library::open(&d) {
        Ok(l) => { *LIB.lock().unwrap() = Some(Arc::new(l)); true }
        Err(e) => { crate::diagnostics::log_open_failure(Path::new(&d), &format!("{e:#}")); false }
    }
}) }

#[no_mangle]
pub extern "C" fn tl_feed(request_json: *const c_char) -> *mut c_char {
    with(|l| { let req: FeedRequest = serde_json::from_str(&s(request_json))?; l.feed(&req) })
}

#[no_mangle]
pub extern "C" fn tl_import_legacy_dir(dir: *const c_char) -> *mut c_char {
    with(|l| l.import_legacy_dir(Path::new(&s(dir))))
}

#[no_mangle]
pub extern "C" fn tl_import_legacy_zip(path: *const c_char, folder: *const c_char) -> *mut c_char {
    with(|l| { let f = s(folder); crate::import::import_zip(&l, Path::new(&s(path)), (!f.is_empty()).then_some(f.as_str())) })
}

/// Imports a ZIP of loose media (no structure; every file becomes its own loose-media post).
#[no_mangle]
pub extern "C" fn tl_import_loose_zip(path: *const c_char, folder: *const c_char) -> *mut c_char {
    with(|l| { let f = s(folder); crate::import::import_loose_zip(&l, Path::new(&s(path)), (!f.is_empty()).then_some(f.as_str())) })
}

#[no_mangle]
pub extern "C" fn tl_import_pack(path: *const c_char, folder: *const c_char) -> *mut c_char {
    with(|l| { let f = s(folder); archive::import_pack_into(&l, Path::new(&s(path)), (!f.is_empty()).then_some(f.as_str())) })
}

#[derive(Deserialize)]
struct ExportArgs { media_ids: Vec<String>, #[serde(default)] options: archive::ExportOptions, #[serde(default)] out: String }

/// args: {"media_ids": [...], "options": {"tags", "folders", "media_only"}, "out": path}. Exports
/// exactly those media (the result of a search); there is no other way to select.
#[no_mangle]
pub extern "C" fn tl_export_media(args_json: *const c_char) -> *mut c_char {
    with(|l| { let a: ExportArgs = serde_json::from_str(&s(args_json))?; archive::export_media(&l, &a.media_ids, a.options, Path::new(&a.out)) })
}

/// Extracts the post links from a bookmark-export JSON file.
#[no_mangle]
pub extern "C" fn tl_parse_bookmarks(path: *const c_char) -> *mut c_char {
    with(|_| Ok(crate::bookmarks::parse_urls(&std::fs::read_to_string(s(path))?)?))
}

#[no_mangle]
pub extern "C" fn tl_download_start(request_json: *const c_char) -> *mut c_char {
    with(|l| { let req: DownloadRequest = serde_json::from_str(&s(request_json))?; download::start(l, req) })
}

#[no_mangle]
pub extern "C" fn tl_download_status() -> *mut c_char { with(|l| { let mut s = download::status(); s.paused = l.db().paused_jobs()?; Ok(s) }) }

#[no_mangle]
pub extern "C" fn tl_download_cancel() { let p = tl_download_stop(false); tl_string_free(p); }
#[no_mangle]
pub extern "C" fn tl_download_stop(pause: bool) -> *mut c_char { with(|l| download::stop(&l, pause)) }
#[no_mangle]
pub extern "C" fn tl_download_resume(json: *const c_char) -> *mut c_char { with(|l| download::resume(l, serde_json::from_str(&s(json))?)) }

/// Sets the session cookies held in memory for the cookie route; empty values clear them.
#[no_mangle]
pub extern "C" fn tl_set_cookies(auth_token: *const c_char, ct0: *const c_char) { guard((), || {
    let (a, c) = (s(auth_token), s(ct0));
    download::set_cookies((!a.is_empty() && !c.is_empty()).then(|| crate::protected::Credentials { auth_token: a, ct0: c }));
}) }

/// origin: 1 = user, 2 = AI. Adding a user tag to an AI tag endorses it.
#[no_mangle]
pub extern "C" fn tl_tag(media_id: *const c_char, label: *const c_char, origin: u8) -> *mut c_char {
    with(|l| l.tag(&s(media_id), &s(label), Origin(origin & 3)))
}

#[no_mangle]
pub extern "C" fn tl_untag(media_id: *const c_char, label: *const c_char) -> *mut c_char {
    with(|l| l.untag(&s(media_id), &s(label)))
}

/// Renames (or merges) a tag everywhere; synced, works during AI tagging, can be undone.
/// Returns the new name.
#[no_mangle]
pub extern "C" fn tl_rename_tag(from: *const c_char, to: *const c_char) -> *mut c_char { with(|l| l.rename_tag(&s(from), &s(to))) }

/// Removes a tag from every media: returns how many media lost it.
#[no_mangle]
pub extern "C" fn tl_delete_tag(label: *const c_char) -> *mut c_char { with(|l| Ok(l.db().delete_label(&s(label))?)) }

/// Removes every AI tag (endorsed ones stay as mine): returns how many tags lost their AI part.
#[no_mangle]
pub extern "C" fn tl_remove_ai_tags() -> *mut c_char { with(|l| Ok(l.db().remove_ai_tags()?)) }

/// Active renames: [[old, current], …].
#[no_mangle]
pub extern "C" fn tl_tag_renames() -> *mut c_char { with(|l| Ok(l.db().renames()?)) }

#[no_mangle]
pub extern "C" fn tl_undo_rename(old: *const c_char) -> *mut c_char { with(|l| Ok(l.db().undo_rename(&s(old))?)) }

/// Current tags of one media (names after renames), live only: [[label, origin], …].
#[no_mangle]
pub extern "C" fn tl_media_tags(media_id: *const c_char) -> *mut c_char {
    with(|l| Ok(l.db().media_tags(&s(media_id))?.into_iter().filter(|(_, o)| *o != 0).collect::<Vec<_>>()))
}

#[no_mangle]
pub extern "C" fn tl_all_tags() -> *mut c_char { with(|l| Ok(l.db().all_tags()?)) }

#[no_mangle]
pub extern "C" fn tl_stats() -> *mut c_char { with(|l| Ok(l.db().stats()?)) }

/// Deletes all local data (AI models only when `include_models`). Never synced.
#[no_mangle]
pub extern "C" fn tl_wipe(include_models: bool) -> *mut c_char { guard_ptr(|| {
    download::cancel();
    crate::models::cancel();
    crate::verify::cancel();
    if let Some(n) = SYNC.lock().unwrap().as_ref() { n.reset(); }
    // a running import stops after its current post folder; wipe only once it has left
    let _import = crate::import::stop_and_wait();
    with(|l| l.wipe(include_models))
}) }

// ---------- Folders ----------

#[derive(Deserialize)]
struct FolderArgs { name: String, #[serde(default)] media: Vec<String>, #[serde(default)] posts: Vec<String> }

/// Live folders with their media counts: [[name, count], …].
#[no_mangle]
pub extern "C" fn tl_folders() -> *mut c_char { with(|l| Ok(l.db().folders()?)) }

/// The folders page: {"folders":[{name,count,videos,cover_id,cover_path,cover_video}],"photos","videos"}.
#[no_mangle]
pub extern "C" fn tl_folder_overview() -> *mut c_char { with(|l| l.folder_overview()) }

#[no_mangle]
pub extern "C" fn tl_media_folders(media_id: *const c_char) -> *mut c_char { with(|l| Ok(l.db().folders_of(&s(media_id))?)) }

#[no_mangle]
pub extern "C" fn tl_create_folder(name: *const c_char) -> *mut c_char { with(|l| Ok(l.db().create_folder(&s(name))?)) }

#[no_mangle]
pub extern "C" fn tl_delete_folder(name: *const c_char) -> *mut c_char {
    with(|l| { let db = l.db(); let tx = db.conn().unchecked_transaction()?; db.delete_folder(&s(name))?; tx.commit()?; Ok(()) })
}

/// Adds media, and every live media of the given posts, to a folder (created if needed).
#[derive(Deserialize)]
struct FolderRename { old: String, new: String }

/// Renames a folder (merging into an existing one of that name); returns the media moved.
#[no_mangle]
pub extern "C" fn tl_rename_folder(json: *const c_char) -> *mut c_char {
    with(|l| { let a: FolderRename = serde_json::from_str(&s(json))?; Ok(l.db().rename_folder(&a.old, &a.new)?) })
}

#[no_mangle]
pub extern "C" fn tl_folder_add(json: *const c_char) -> *mut c_char {
    with(|l| {
        let a: FolderArgs = serde_json::from_str(&s(json))?;
        let db = l.db(); let tx = db.conn().unchecked_transaction()?;
        let n = db.add_to_folder(&a.name, &a.media)? + db.add_posts_to_folder(&a.name, &a.posts)?;
        tx.commit()?; Ok(n)
    })
}

#[no_mangle]
pub extern "C" fn tl_folder_remove(json: *const c_char) -> *mut c_char {
    with(|l| {
        let a: FolderArgs = serde_json::from_str(&s(json))?;
        let db = l.db(); let tx = db.conn().unchecked_transaction()?;
        let mut media = a.media.clone();
        for p in &a.posts { media.extend(db.action_ids(&[], &[p.clone()])?); }
        let n = db.remove_from_folder(&a.name, &media)?;
        tx.commit()?; Ok(n)
    })
}

// ---------- Triage mode (local only) ----------

#[derive(Deserialize)]
struct TriageArgs { post: String, decision: crate::triage::Decision, #[serde(default)] folder: Option<String>, expected: Option<Vec<String>> }

/// Posts still to triage under a filter, each with its live media (absolute paths).
#[no_mangle]
pub extern "C" fn tl_triage_queue(filter_json: *const c_char) -> *mut c_char {
    with(|l| {
        let f: crate::triage::TriageFilter = serde_json::from_str(&s(filter_json))?;
        let mut q = l.db().triage_queue(&f)?;
        for u in &mut q { for it in &mut u.items { it.path = l.dir.join(&it.path).to_string_lossy().into_owned(); } }
        Ok(q)
    })
}

#[no_mangle]
pub extern "C" fn tl_triage_counts(filter_json: *const c_char) -> *mut c_char {
    with(|l| { let f: crate::triage::TriageFilter = serde_json::from_str(&s(filter_json))?; Ok(l.db().triage_counts(&f)?) })
}

/// Keep / delete (whole post to the bin) / folder; atomic. Returns whether it applied.
#[no_mangle]
pub extern "C" fn tl_triage_decide(json: *const c_char) -> *mut c_char {
    with(|l| {
        let a: TriageArgs = serde_json::from_str(&s(json))?;
        l.triage_decide_checked(&a.post, a.decision, a.folder.as_deref(), a.expected.as_deref())
    })
}

#[no_mangle]
pub extern "C" fn tl_triage_undo(post: *const c_char) -> *mut c_char {
    with(|l| { let db = l.db(); let tx = db.conn().unchecked_transaction()?; let ok = db.triage_undo(&s(post))?; tx.commit()?; Ok(ok) })
}

/// Forgets every triage decision on this device.
#[no_mangle]
pub extern "C" fn tl_triage_clear() -> *mut c_char { with(|l| Ok(l.db().triage_clear()?)) }

// ---------- Recycle bin ----------

#[derive(Deserialize)]
struct Ids { #[serde(default)] media: Vec<String>, #[serde(default)] post: Option<String> }

/// Moves media (and/or every live media of a post) to the recycle bin. Returns how many moved.
#[no_mangle]
pub extern "C" fn tl_trash(json: *const c_char) -> *mut c_char {
    with(|l| {
        let a: Ids = serde_json::from_str(&s(json))?;
        let mut n = l.trash_apply(&a.media, crate::rules::TrashAction::Trash)?;
        if let Some(p) = a.post { n += l.trash_post(&p)?; }
        Ok(n)
    })
}

#[no_mangle]
pub extern "C" fn tl_trash_restore(json: *const c_char) -> *mut c_char {
    with(|l| { let a: Ids = serde_json::from_str(&s(json))?; l.trash_apply(&a.media, crate::rules::TrashAction::Restore) })
}

/// Permanently deletes media that are in the recycle bin (on every device).
#[no_mangle]
pub extern "C" fn tl_trash_purge(json: *const c_char) -> *mut c_char {
    with(|l| { let a: Ids = serde_json::from_str(&s(json))?; l.trash_apply(&a.media, crate::rules::TrashAction::Purge) })
}

#[no_mangle]
pub extern "C" fn tl_trash_empty() -> *mut c_char { with(|l| l.empty_trash()) }

#[no_mangle]
pub extern "C" fn tl_trash_list() -> *mut c_char { with(|l| l.trash_list()) }

#[no_mangle]
pub extern "C" fn tl_trash_keep_days() -> *mut c_char { with(|l| Ok(l.trash_keep_days())) }

#[no_mangle]
pub extern "C" fn tl_set_trash_keep_days(days: u32) -> *mut c_char { with(|l| l.set_trash_keep_days(days)) }

/// Deletes media that stayed in the bin longer than the retention period.
#[no_mangle]
pub extern "C" fn tl_trash_expire() -> *mut c_char {
    with(|l| l.expire_trash(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)))
}


// ---------- Import progress and reports ----------

#[no_mangle]
pub extern "C" fn tl_import_status() -> *mut c_char { guard_ptr(|| { out(serde_json::json!({ "ok": crate::import::progress() }).to_string()) }) }

/// Saved import reports, newest first: [[file, created_ms, source, issue_count], …].
#[no_mangle]
pub extern "C" fn tl_import_reports() -> *mut c_char { with(|l| Ok(crate::import::reports(&l))) }

#[no_mangle]
pub extern "C" fn tl_import_report(path: *const c_char) -> *mut c_char { with(|_| crate::import::load_report(Path::new(&s(path)))) }

/// Writes the problem files of a report (unchanged) plus 说明.txt into a ZIP; returns the file count.
#[no_mangle]
pub extern "C" fn tl_import_export_issues(report: *const c_char, out_zip: *const c_char) -> *mut c_char {
    with(|_| crate::import::export_issues(Path::new(&s(report)), Path::new(&s(out_zip))))
}

// ---------- Verification and repair ----------

#[no_mangle]
pub extern "C" fn tl_verify_start() -> *mut c_char { with(|l| crate::verify::start(l)) }

#[no_mangle]
pub extern "C" fn tl_verify_status() -> *mut c_char { guard_ptr(|| { out(serde_json::json!({ "ok": crate::verify::status() }).to_string()) }) }

#[no_mangle]
pub extern "C" fn tl_verify_cancel() { guard((), || { crate::verify::cancel() }) }

/// The app failed to decode a media: verify its file and record the damage. Returns the reason.
#[no_mangle]
pub extern "C" fn tl_report_bad(media_id: *const c_char) -> *mut c_char { with(|l| l.report_bad(&s(media_id))) }

/// Downloads a damaged media again (blocking; call off the main thread).
#[no_mangle]
pub extern "C" fn tl_repair(media_id: *const c_char) -> *mut c_char {
    with(|l| {
        let id = s(media_id);
        download::runtime().block_on(async { tokio::time::timeout(std::time::Duration::from_secs(300), download::repair(&l, &id)).await })
            .map_err(|_| anyhow::anyhow!("下载超时"))?
    })
}

// ---------- Models (standard Hugging Face / MLX folders) ----------

#[no_mangle]
pub extern "C" fn tl_set_models_dir(dir: *const c_char) -> *mut c_char { with(|l| l.set_models_dir(s(dir).into())) }

#[no_mangle]
pub extern "C" fn tl_model_download(repo: *const c_char) -> *mut c_char {
    with(|l| crate::models::start_download(s(repo), l.models_dir()))
}

#[no_mangle]
pub extern "C" fn tl_model_status() -> *mut c_char { guard_ptr(|| { out(serde_json::json!({ "ok": crate::models::status() }).to_string()) }) }

#[no_mangle]
pub extern "C" fn tl_model_cancel() { guard((), || { crate::models::cancel() }) }

#[no_mangle]
pub extern "C" fn tl_models_interrupted() -> *mut c_char { with(|l| Ok(crate::models::interrupted(&l.models_dir()))) }
#[no_mangle]
pub extern "C" fn tl_models_installed() -> *mut c_char { with(|l| Ok(crate::models::installed(&l.models_dir()))) }

#[no_mangle]
pub extern "C" fn tl_model_delete(id: *const c_char) -> *mut c_char { with(|l| crate::models::delete(&l.models_dir(), &s(id))) }

/// Writes the model folder as a plain ZIP.
#[no_mangle]
pub extern "C" fn tl_model_export_zip(id: *const c_char, out_path: *const c_char) -> *mut c_char {
    with(|l| crate::models::export_zip(&l.models_dir(), &s(id), Path::new(&s(out_path))))
}

/// Imports a standard model folder or a ZIP of one.
#[no_mangle]
pub extern "C" fn tl_model_import(path: *const c_char) -> *mut c_char {
    with(|l| crate::models::import(&l.models_dir(), Path::new(&s(path))))
}

// ---------- AI tagging & semantic vectors ----------

/// Media no model has analysed yet (the default model can change without re-tagging).
#[no_mangle]
pub extern "C" fn tl_ai_pending(limit: i64) -> *mut c_char {
    with(|l| Ok(abs(&l, l.db().media_needing_ai(limit)?)))
}

/// All media, paged, for "re-tag all".
#[no_mangle]
pub extern "C" fn tl_media_page(after: *const c_char, limit: i64) -> *mut c_char {
    with(|l| Ok(abs(&l, l.db().media_page(&s(after), limit)?)))
}

fn abs(l: &Library, v: Vec<crate::store::MediaRef>) -> Vec<crate::store::MediaRef> {
    v.into_iter().map(|mut m| { m.path = l.dir.join(&m.path).to_string_lossy().into_owned(); m }).collect()
}

/// Media not analysed yet that this device should try with `model`: leaves out media that
/// failed here too often, or once since `since` (unix seconds; 0 = no run limit).
#[no_mangle]
pub extern "C" fn tl_ai_pending_for(model: *const c_char, since: i64, limit: i64) -> *mut c_char {
    with(|l| Ok(abs(&l, l.db().media_needing_ai_for(&s(model), since, limit)?)))
}

#[derive(Deserialize)]
struct AiAttempt { step: String, media_id: String, model: String, #[serde(default)] reason: String, #[serde(default)] now: i64 }

/// An analysis attempt on this device (local only, never synced): `begin` before the model
/// runs (counted even if the app then crashes), `failed` with the reason, `undo` when the run
/// stopped for a reason that is not the media's.
#[no_mangle]
pub extern "C" fn tl_ai_attempt(json: *const c_char) -> *mut c_char {
    with(|l| {
        let a: AiAttempt = serde_json::from_str(&s(json))?;
        match a.step.as_str() {
            "begin" => l.db().ai_attempt_begin(&a.media_id, &a.model, a.now)?,
            "failed" => l.db().ai_attempt_failed(&a.media_id, &a.model, &a.reason)?,
            "undo" => l.db().ai_attempt_undo(&a.media_id, &a.model)?,
            other => anyhow::bail!("unknown step {other}"),
        }
        Ok(())
    })
}

/// Media this device gave up analysing, with the reason.
#[no_mangle]
pub extern "C" fn tl_ai_failures() -> *mut c_char { with(|l| Ok(l.db().ai_failures()?)) }

/// Try them again on this device.
#[no_mangle]
pub extern "C" fn tl_ai_failures_clear() -> *mut c_char { with(|l| Ok(l.db().ai_failures_clear()?)) }

/// (analysed by any model, total).
#[no_mangle]
pub extern "C" fn tl_ai_counts() -> *mut c_char { with(|l| Ok(l.db().ai_counts()?)) }

#[derive(Deserialize)]
struct AiApply { epoch: u64, media_id: String, model: String, labels: Vec<String>, #[serde(default)] replace_old: bool }

/// Applies one model's labels; `replace_old` removes unendorsed AI tags not proposed again.
#[no_mangle]
pub extern "C" fn tl_ai_apply(json: *const c_char) -> *mut c_char {
    with(|l| { let a: AiApply = serde_json::from_str(&s(json))?; l.apply_ai_tags_at(a.epoch, &a.media_id, &a.model, &a.labels, a.replace_old) })
}

#[no_mangle]
pub extern "C" fn tl_labels_missing_vectors(model: *const c_char) -> *mut c_char { with(|l| Ok(l.db().labels_missing_vectors(&s(model))?)) }

#[derive(Deserialize)]
struct SetVectors { epoch: u64, model: String, items: Vec<(String, Vec<f32>)> }

#[no_mangle]
pub extern "C" fn tl_set_vectors(json: *const c_char) -> *mut c_char {
    with(|l| { let a: SetVectors = serde_json::from_str(&s(json))?; l.set_vectors_at(a.epoch, &a.model, &a.items) })
}

/// Capture before starting asynchronous work; writes must supply this generation.
#[no_mangle]
pub extern "C" fn tl_epoch() -> *mut c_char { with(|l| Ok(l.epoch())) }

// ---------- LAN sync ----------

static SYNC: Mutex<Option<Arc<crate::sync::SyncNode>>> = Mutex::new(None);

fn node() -> anyhow::Result<Arc<crate::sync::SyncNode>> {
    let mut g = SYNC.lock().unwrap();
    if g.is_none() { *g = Some(crate::sync::SyncNode::new(lib()?)); }
    Ok(g.clone().unwrap())
}
fn key_from_hex(h: &str) -> anyhow::Result<[u8; 32]> {
    hex::decode(h.trim())?.try_into().map_err(|_| anyhow::anyhow!("bad account key"))
}

/// Generates a new account key (hex). The app stores it in the Keychain.
#[no_mangle]
pub extern "C" fn tl_sync_new_account() -> *mut c_char { guard_ptr(|| {
    out(serde_json::json!({ "ok": hex::encode(crate::sync::Account::generate().key) }).to_string())
}) }

/// Starts (or reconfigures) the node; empty key = not yet joined. Returns the listening port.
#[no_mangle]
pub extern "C" fn tl_sync_start(account_key_hex: *const c_char, device_name: *const c_char) -> *mut c_char {
    with(|_| {
        let n = node()?;
        let k = s(account_key_hex);
        let acct = if k.is_empty() { None } else { Some(crate::sync::Account::from_key(key_from_hex(&k)?)) };
        download::runtime().block_on(n.start(acct, s(device_name)))
    })
}

#[no_mangle]
pub extern "C" fn tl_sync_status() -> *mut c_char { with(|_| Ok(node()?.status())) }

#[no_mangle]
pub extern "C" fn tl_sync_pair_begin() -> *mut c_char { with(|_| node()?.begin_pairing()) }

#[no_mangle]
pub extern "C" fn tl_sync_pair_cancel() { guard((), || { if let Ok(n) = node() { n.cancel_pairing() } }) }

#[no_mangle]
pub extern "C" fn tl_sync_join(host: *const c_char, port: u16, code: *const c_char) -> *mut c_char {
    with(|_| { let n = node()?; let _g = download::runtime().enter(); n.join(s(host), port, s(code)); Ok(()) })
}

/// Fire-and-forget sync with one peer; progress shows up in `tl_sync_status`.
#[no_mangle]
pub extern "C" fn tl_sync_with(host: *const c_char, port: u16) -> *mut c_char {
    with(|_| {
        let n = node()?;
        let host = s(host);
        download::runtime().spawn(async move { let _ = n.sync_with(&host, port).await; });
        Ok(())
    })
}

/// Models installed on a same-account peer (blocking, ≤ 10 s; call off the main thread).
#[no_mangle]
pub extern "C" fn tl_sync_peer_models(host: *const c_char, port: u16) -> *mut c_char {
    with(|_| {
        let n = node()?;
        let host = s(host);
        download::runtime().block_on(async { tokio::time::timeout(std::time::Duration::from_secs(10), n.peer_models(&host, port)).await })
            .map_err(|_| anyhow::anyhow!("连接超时"))?
    })
}

/// Starts copying one model from a peer; progress via `tl_model_status`.
#[no_mangle]
pub extern "C" fn tl_sync_pull_model(host: *const c_char, port: u16, id: *const c_char, label: *const c_char, total: u64) -> *mut c_char {
    with(|_| {
        let n = node()?;
        let (host, id, label) = (s(host), s(id), s(label));
        if crate::models::status().map_or(false, |st| st.running) { anyhow::bail!("已有模型正在下载"); }
        download::runtime().spawn(async move { let _ = n.pull_model(&host, port, &id, &label, total).await; });
        Ok(())
    })
}

/// Leaves sync entirely (used by wipe). Never sends anything to peers.
#[no_mangle]
pub extern "C" fn tl_sync_reset() { guard((), || { if let Ok(n) = node() { n.reset() } }) }

#[no_mangle]
pub extern "C" fn tl_string_free(p: *mut c_char) {
    if !p.is_null() { unsafe { drop(CString::from_raw(p)) } }
}

// ---------- Backup, share inbox, import records ----------

/// Whole-library cold backup into a `.tlpack` (everything but AI models and triage records).
#[no_mangle]
pub extern "C" fn tl_export_backup(out_path: *const c_char) -> *mut c_char {
    with(|l| archive::export_backup(&l, Path::new(&s(out_path))))
}

#[no_mangle]
pub extern "C" fn tl_export_status() -> *mut c_char { guard_ptr(|| { out(serde_json::json!({ "ok": archive::export_progress() }).to_string()) }) }

#[no_mangle]
pub extern "C" fn tl_export_cancel() -> *mut c_char { guard_ptr(|| { archive::cancel_export(); out(serde_json::json!({ "ok": true }).to_string()) }) }

#[derive(Deserialize)]
struct LooseDirArgs { dir: String, #[serde(default)] folder: Option<String>, #[serde(default)] consume: bool, #[serde(default)] keep_to: Option<String> }

/// Imports a folder of loose media (a share from Photos / Files); with `consume`, imported files
/// are removed from it afterwards and only problem files stay.
#[no_mangle]
pub extern "C" fn tl_import_loose_dir(json: *const c_char) -> *mut c_char {
    with(|l| {
        let a: LooseDirArgs = serde_json::from_str(&s(json))?;
        crate::import::import_loose_dir_keep(&l, Path::new(&a.dir), a.folder.as_deref().filter(|f| !f.trim().is_empty()), a.consume, a.keep_to.as_deref().map(Path::new))
    })
}

#[derive(Deserialize)]
struct DeleteReportsArgs { reports: Vec<String>, #[serde(default)] owned: Vec<String> }

/// Deletes import records (and their source when it is one of the app's own copies, see
/// `import::delete_reports`).
#[no_mangle]
pub extern "C" fn tl_delete_import_reports(json: *const c_char) -> *mut c_char {
    with(|l| {
        let a: DeleteReportsArgs = serde_json::from_str(&s(json))?;
        let r: Vec<std::path::PathBuf> = a.reports.iter().map(std::path::PathBuf::from).collect();
        let o: Vec<std::path::PathBuf> = a.owned.iter().map(std::path::PathBuf::from).collect();
        crate::import::delete_reports(&l, &r, &o)
    })
}

/// Diagnostics ZIP for the developer (logs, crash reports, numbers-only summary).
#[no_mangle]
pub extern "C" fn tl_export_diagnostics(out_path: *const c_char, app_info_json: *const c_char) -> *mut c_char {
    with(|l| crate::diagnostics::export(&l, Path::new(&s(out_path)), &s(app_info_json)))
}

#[derive(Deserialize)]
struct TagFolderArgs { label: String, folder: String }

/// Puts every media in the library that carries a tag (under its current name, any origin)
/// into a folder (created if needed). Returns how many were newly added.
#[no_mangle]
pub extern "C" fn tl_tag_to_folder(json: *const c_char) -> *mut c_char {
    with(|l| {
        let a: TagFolderArgs = serde_json::from_str(&s(json))?;
        let db = l.db();
        let ids: Vec<String> = db.export_items(&[a.label.clone()], &[])?.into_iter().map(|i| i.media_id).collect();
        let tx = db.conn().unchecked_transaction()?;
        let name = db.create_folder(&a.folder)?;
        let n = db.add_to_folder(&name, &ids)?;
        tx.commit()?;
        Ok(n)
    })
}

/// Checks the stored cookies through the protected-post module: {"available", "screen_name"?, "error"?}.
#[no_mangle]
pub extern "C" fn tl_check_cookies(auth_token: *const c_char, ct0: *const c_char) -> *mut c_char { guard_ptr(|| {
    let c = crate::protected::Credentials { auth_token: s(auth_token), ct0: s(ct0) };
    let v = match crate::protected::check(&c) {
        Ok(a) => serde_json::json!({ "available": true, "screen_name": a.screen_name, "name": a.name }),
        Err(crate::protected::ProtectedError::NotAvailable) => serde_json::json!({ "available": false }),
        Err(e) => serde_json::json!({ "available": true, "error": e.to_string() }),
    };
    out(serde_json::json!({ "ok": v }).to_string())
}) }

// UI actions: explicit scope, frozen confirmations, and conditional undo receipts.
#[no_mangle]
pub extern "C" fn tl_post_scope(post: *const c_char) -> *mut c_char { with(|l| Ok(l.db().post_scope(&s(post))?)) }
#[no_mangle]
pub extern "C" fn tl_bin_snapshot() -> *mut c_char { with(|l| l.bin_snapshot()) }
#[no_mangle]
pub extern "C" fn tl_action(json: *const c_char) -> *mut c_char { with(|l| l.apply_action(&serde_json::from_str(&s(json))?)) }
#[no_mangle]
pub extern "C" fn tl_action_undo(json: *const c_char) -> *mut c_char { with(|l| l.undo_action(&serde_json::from_str(&s(json))?)) }

#[no_mangle]
pub extern "C" fn tl_integrity_summary() -> *mut c_char { with(|l| crate::verify::summary(&l)) }
