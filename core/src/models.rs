//! On-device models in the standard Hugging Face / MLX folder layout (config.json, tokenizer
//! files, *.safetensors) — the same folder `mlx_lm`/`mlx-vlm` and the HF hub produce. Nothing
//! proprietary: a model is exported as that folder in a plain ZIP, and any such folder or ZIP can
//! be imported. Several models can be installed side by side, one folder each.
use crate::download::runtime;
use crate::net::client;
use anyhow::{bail, Context};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use tokio::io::AsyncWriteExt;

/// Present while a download into the folder is incomplete.
const MARKER: &str = ".downloading";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelInfo {
    /// Folder name (stable id).
    pub id: String,
    /// Hugging Face repo, when known (downloaded models: folder `org--name`).
    pub repo: Option<String>,
    pub model_type: Option<String>,
    /// Has a vision tower (usable as a tagger); otherwise treated as a text embedder.
    pub vision: bool,
    pub bytes: u64,
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelFile { pub name: String, pub size: u64, pub sha256: Option<String> }

#[derive(Debug, Clone, Serialize, Default)]
pub struct ModelDownloadStatus { pub repo: String, pub running: bool, pub total_bytes: u64, pub done_bytes: u64, pub file: String, pub error: Option<String>, pub finished: bool }

static STATUS: Mutex<Option<ModelDownloadStatus>> = Mutex::new(None);
/// Limits for an imported model ZIP: files in it, and bytes after unpacking.
const MAX_ZIP_ENTRIES: usize = 10_000;
const MAX_MODEL_BYTES: u64 = 64 << 30;
static CANCEL: AtomicBool = AtomicBool::new(false);

pub fn status() -> Option<ModelDownloadStatus> { STATUS.lock().unwrap().clone() }

/// Progress reporting shared with LAN model pulls (same UI as downloads).
pub(crate) fn begin_external(label: &str, total: u64) -> anyhow::Result<()> {
    claim(ModelDownloadStatus { repo: label.into(), running: true, total_bytes: total, ..Default::default() })
}

/// Starts a model operation unless one is running: the check and the claim happen under one
/// lock, so two taps (or a download and a pull from another device) can never both start.
fn claim(s: ModelDownloadStatus) -> anyhow::Result<()> {
    let mut g = STATUS.lock().unwrap_or_else(|e| e.into_inner());
    if g.as_ref().map_or(false, |s| s.running) { bail!("已有模型正在下载"); }
    CANCEL.store(false, Ordering::SeqCst);
    *g = Some(s);
    Ok(())
}

/// A private staging folder name (two operations never share or delete each other's).
pub(crate) fn staging_name(prefix: &str) -> String { format!(".{prefix}-{}", hex::encode(rand::random::<[u8; 6]>())) }
pub(crate) fn external_progress(done: u64, file: &str) { update(|s| { s.done_bytes = done; s.file = file.into(); }) }
pub(crate) fn external_cancelled() -> bool { CANCEL.load(Ordering::SeqCst) }
pub(crate) fn end_external(r: &anyhow::Result<()>) {
    update(|s| { s.running = false; s.finished = r.is_ok(); s.error = r.as_ref().err().map(|e| format!("{e:#}")); if r.is_ok() { s.done_bytes = s.total_bytes; } });
}
pub(crate) fn is_wanted_file(name: &str) -> bool { wanted(name) }
pub(crate) fn checked_id(id: &str) -> anyhow::Result<&str> { safe_id(id) }
pub fn cancel() { CANCEL.store(true, Ordering::SeqCst) }
fn update(f: impl FnOnce(&mut ModelDownloadStatus)) { if let Some(s) = STATUS.lock().unwrap().as_mut() { f(s) } }

pub fn slug(repo: &str) -> String { repo.replace('/', "--") }

/// Files needed to run an MLX model; docs, images and git metadata are skipped.
fn wanted(name: &str) -> bool {
    if name.contains('/') || name.starts_with('.') { return false; }
    let l = name.to_ascii_lowercase();
    l.ends_with(".safetensors") || l.ends_with(".json") || l.ends_with(".jinja") || l.ends_with(".txt") || l.ends_with(".model") || l.ends_with(".tiktoken")
}

#[derive(Deserialize)]
struct TreeEntry { #[serde(rename = "type")] kind: String, path: String, size: u64, lfs: Option<Lfs> }
#[derive(Deserialize)]
struct Lfs { oid: String }

pub fn start_download(repo: String, models_dir: PathBuf) -> anyhow::Result<()> {
    claim(ModelDownloadStatus { repo: repo.clone(), running: true, ..Default::default() })?;
    runtime().spawn(async move {
        let r = download(&repo, &models_dir).await;
        update(|s| { s.running = false; s.finished = r.is_ok(); s.error = r.err().map(|e| format!("{e:#}")); });
    });
    Ok(())
}

async fn download(repo: &str, models_dir: &Path) -> anyhow::Result<()> {
    let tree: Vec<TreeEntry> = client().get(format!("https://huggingface.co/api/models/{repo}/tree/main"))
        .send().await?.error_for_status()?.json().await.context("读取模型文件列表失败")?;
    let files: Vec<ModelFile> = tree.into_iter().filter(|e| e.kind == "file" && wanted(&e.path))
        .map(|e| ModelFile { name: e.path, size: e.size, sha256: e.lfs.map(|l| l.oid) }).collect();
    if !files.iter().any(|f| f.name.ends_with(".safetensors")) { bail!("仓库中没有 safetensors 权重"); }
    let total: u64 = files.iter().try_fold(0u64, |a, f| a.checked_add(f.size)).ok_or_else(|| anyhow::anyhow!("模型文件大小无效"))?;
    let dir = models_dir.join(slug(repo));
    if is_complete(&dir) { update(|s| { s.total_bytes = total; s.done_bytes = total; }); return Ok(()); }
    fs::create_dir_all(&dir)?;
    fs::write(dir.join(MARKER), repo)?;
    update(|s| s.total_bytes = total);
    let mut done = 0u64;
    for f in &files {
        if CANCEL.load(Ordering::SeqCst) { bail!("已取消"); }
        update(|s| { s.file = f.name.clone(); s.done_bytes = done; });
        fetch_file(repo, &dir, f, done).await.with_context(|| format!("下载 {} 失败", f.name))?;
        done += f.size;
    }
    validate_dir(&dir)?;
    fs::remove_file(dir.join(MARKER))?;
    update(|s| s.done_bytes = total);
    Ok(())
}

/// Downloads one file with HTTP Range resume, then verifies size (and sha256 for LFS files).
async fn fetch_file(repo: &str, dir: &Path, f: &ModelFile, base: u64) -> anyhow::Result<()> {
    let dst = dir.join(&f.name);
    if dst.exists() && fs::metadata(&dst)?.len() == f.size { return Ok(()); }
    let part = dir.join(format!("{}.partial", f.name));
    for attempt in 0..5u32 {
        if attempt > 0 { tokio::time::sleep(std::time::Duration::from_secs(2u64.pow(attempt))).await; }
        let have = fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
        if have < f.size || f.size == 0 {
            let mut rq = client().get(format!("https://huggingface.co/{repo}/resolve/main/{}", f.name));
            if have > 0 { rq = rq.header("Range", format!("bytes={have}-")); }
            let resp = match rq.send().await.and_then(|r| r.error_for_status()) { Ok(r) => r, Err(_) if attempt < 4 => continue, Err(e) => return Err(e.into()) };
            let append = have > 0 && resp.status().as_u16() == 206;
            let mut out = tokio::fs::OpenOptions::new().create(true).write(true).append(append).truncate(!append).open(&part).await?;
            let mut got = if append { have } else { 0 };
            let mut stream = resp.bytes_stream();
            let mut failed = false;
            while let Some(c) = stream.next().await {
                if CANCEL.load(Ordering::SeqCst) { bail!("已取消"); }
                match c {
                    Ok(c) => { out.write_all(&c).await?; got += c.len() as u64; update(|s| s.done_bytes = base + got); }
                    Err(_) => { failed = true; break; }
                }
            }
            out.flush().await?;
            out.sync_all().await?;
            if failed { continue; }
        }
        let len = fs::metadata(&part)?.len();
        if f.size != 0 && len != f.size { let _ = fs::remove_file(&part); continue; }
        if let Some(want) = &f.sha256 {
            let p = part.clone();
            let got = tokio::task::spawn_blocking(move || sha256_file(&p)).await??;
            if &got != want { let _ = fs::remove_file(&part); bail!("校验失败"); }
        }
        fs::rename(&part, &dst)?;
        return Ok(());
    }
    bail!("多次重试后仍失败")
}

fn sha256_file(p: &Path) -> anyhow::Result<String> {
    let mut h = Sha256::new();
    let mut r = BufReader::with_capacity(1 << 20, File::open(p)?);
    let mut buf = vec![0u8; 1 << 20];
    loop { let n = r.read(&mut buf)?; if n == 0 { break; } h.update(&buf[..n]); }
    Ok(hex::encode(h.finalize()))
}

fn is_complete(dir: &Path) -> bool {
    dir.join("config.json").is_file() && !dir.join(MARKER).exists() && validate_dir(dir).is_ok()
}

/// Checks a model folder: parsable config.json, at least one safetensors file, and every
/// safetensors header consistent with the file size (catches truncated or corrupted copies).
pub fn validate_dir(dir: &Path) -> anyhow::Result<()> {
    let cfg: serde_json::Value = serde_json::from_slice(&fs::read(dir.join("config.json")).context("缺少 config.json")?).context("config.json 无法解析")?;
    if !cfg.is_object() { bail!("config.json 格式不正确"); }
    let mut n = 0;
    for e in fs::read_dir(dir)? {
        let p = e?.path();
        if p.extension().and_then(|x| x.to_str()) == Some("safetensors") { check_safetensors(&p)?; n += 1; }
    }
    if n == 0 { bail!("没有 .safetensors 权重文件"); }
    Ok(())
}

/// safetensors = u64 LE header length, JSON header with data_offsets, then the tensor bytes.
pub fn check_safetensors(p: &Path) -> anyhow::Result<()> {
    let name = p.file_name().unwrap_or_default().to_string_lossy().into_owned();
    let len = fs::metadata(p)?.len();
    let mut f = File::open(p)?;
    let mut h = [0u8; 8];
    f.read_exact(&mut h).with_context(|| format!("{name} 已损坏"))?;
    let hl = u64::from_le_bytes(h);
    if hl == 0 || hl > 100 << 20 || 8 + hl > len { bail!("{name} 头部损坏"); }
    let mut buf = vec![0u8; hl as usize];
    f.read_exact(&mut buf)?;
    let hdr: serde_json::Value = serde_json::from_slice(&buf).with_context(|| format!("{name} 头部无法解析"))?;
    let mut end = 0u64;
    for (k, v) in hdr.as_object().into_iter().flatten() {
        if k == "__metadata__" { continue; }
        let off = v["data_offsets"].as_array().and_then(|a| a.get(1)).and_then(|x| x.as_u64()).with_context(|| format!("{name} 张量 {k} 缺少偏移"))?;
        end = end.max(off);
    }
    if 8u64.checked_add(hl).and_then(|x| x.checked_add(end)) != Some(len) { bail!("{name} 大小与头部不符（文件不完整）"); }
    Ok(())
}

fn dir_info(dir: &Path) -> Option<ModelInfo> {
    if !is_complete(dir) { return None; }
    let id = dir.file_name()?.to_string_lossy().into_owned();
    let cfg: serde_json::Value = serde_json::from_slice(&fs::read(dir.join("config.json")).ok()?).ok()?;
    let bytes = fs::read_dir(dir).ok()?.filter_map(|e| e.ok()).filter_map(|e| e.metadata().ok()).filter(|m| m.is_file()).map(|m| m.len()).sum();
    Some(ModelInfo {
        repo: id.split_once("--").map(|(a, b)| format!("{a}/{b}")),
        model_type: cfg["model_type"].as_str().map(str::to_string),
        vision: cfg.get("vision_config").map_or(false, |v| !v.is_null()),
        bytes, path: dir.to_string_lossy().into_owned(), id,
    })
}

/// A download that was interrupted (app quit or crashed): its repo and the bytes already on disk.
#[derive(Serialize, Clone, Debug)]
pub struct Interrupted { pub repo: String, pub bytes: u64 }

/// Downloads left unfinished: folders still carrying the in-progress marker. Starting the same
/// repo again continues from the bytes already there.
pub fn interrupted(models_dir: &Path) -> Vec<Interrupted> {
    if status().map_or(false, |s| s.running) { return vec![]; }
    let Ok(rd) = fs::read_dir(models_dir) else { return vec![] };
    let mut v: Vec<Interrupted> = rd.filter_map(|e| e.ok()).map(|e| e.path()).filter(|d| d.join(MARKER).is_file()).filter_map(|d| {
        let repo = fs::read_to_string(d.join(MARKER)).ok()?.trim().to_string();
        if repo.is_empty() { return None; }
        let bytes = fs::read_dir(&d).ok()?.filter_map(|e| e.ok()).filter_map(|e| e.metadata().ok()).filter(|m| m.is_file()).map(|m| m.len()).sum();
        Some(Interrupted { repo, bytes })
    }).collect();
    v.sort_by(|a, b| a.repo.cmp(&b.repo));
    v
}

/// Installed models: every complete standard model folder under `models_dir`.
pub fn installed(models_dir: &Path) -> Vec<ModelInfo> {
    let Ok(rd) = fs::read_dir(models_dir) else { return vec![] };
    let mut v: Vec<ModelInfo> = rd.filter_map(|e| e.ok()).filter(|e| e.path().is_dir()).filter_map(|e| dir_info(&e.path())).collect();
    v.sort_by(|a, b| a.id.cmp(&b.id));
    v
}

fn safe_id(id: &str) -> anyhow::Result<&str> {
    if id.is_empty() || id.contains('/') || id.contains("..") || id.starts_with('.') { bail!("非法模型名"); }
    Ok(id)
}

pub fn delete(models_dir: &Path, id: &str) -> anyhow::Result<()> {
    let d = models_dir.join(safe_id(id)?);
    if d.exists() { fs::remove_dir_all(d)?; }
    Ok(())
}

/// Plain ZIP of the model folder (stored, the folder itself as the single top-level entry).
pub fn export_zip(models_dir: &Path, id: &str, out: &Path) -> anyhow::Result<u64> {
    let dir = models_dir.join(safe_id(id)?);
    validate_dir(&dir)?;
    let tmp = out.with_extension("partial");
    let mut zw = zip::ZipWriter::new(BufWriter::new(File::create(&tmp)?));
    let o = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored).large_file(true);
    let mut bytes = 0;
    let mut names: Vec<String> = fs::read_dir(&dir)?.filter_map(|e| e.ok()).filter(|e| e.path().is_file())
        .map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| !n.starts_with('.') && n != "tlmodel.json").collect();
    names.sort();
    for n in names {
        zw.start_file(format!("{id}/{n}"), o)?;
        bytes += io::copy(&mut File::open(dir.join(&n))?, &mut zw)?;
    }
    zw.finish()?.flush()?;
    fs::rename(&tmp, out)?;
    Ok(bytes)
}

/// Imports a standard model folder or a ZIP of one. Files are staged, validated, then moved in.
pub fn import(models_dir: &Path, path: &Path) -> anyhow::Result<ModelInfo> {
    fs::create_dir_all(models_dir)?;
    let staging = models_dir.join(staging_name("import"));
    let _ = fs::remove_dir_all(&staging);
    fs::create_dir_all(&staging)?;
    let r = (|| -> anyhow::Result<ModelInfo> {
        let mut name = path.file_stem().unwrap_or_default().to_string_lossy().into_owned();
        if path.is_dir() {
            for e in fs::read_dir(path)? {
                let p = e?.path();
                if p.is_file() && wanted(&p.file_name().unwrap_or_default().to_string_lossy()) { fs::copy(&p, staging.join(p.file_name().unwrap()))?; }
            }
            name = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
        } else {
            let mut z = zip::ZipArchive::new(BufReader::new(File::open(path)?))?;
            if z.len() > MAX_ZIP_ENTRIES { bail!("ZIP 里的文件太多（{} 个），不像一个模型", z.len()); }
            let mut written = 0u64;
            for i in 0..z.len() {
                let mut e = z.by_index(i)?;
                if e.is_dir() { continue; }
                let Some(rel) = crate::archive::safe_relative(&String::from_utf8_lossy(e.name_raw())) else { continue };
                if rel.starts_with("__MACOSX") { continue; }
                // only the files a model needs, and never more than a model can be (a ZIP bomb stops here)
                if !wanted(&rel.file_name().unwrap_or_default().to_string_lossy()) { continue; }
                let dst = staging.join(&rel);
                fs::create_dir_all(dst.parent().unwrap())?;
                let n = io::copy(&mut (&mut e).take(MAX_MODEL_BYTES - written + 1), &mut BufWriter::new(File::create(&dst)?))?;
                written += n;
                if written > MAX_MODEL_BYTES { bail!("ZIP 解压后超过 {} GB，不像一个模型", MAX_MODEL_BYTES >> 30); }
            }
        }
        // The model root is the staging dir or its single sub-folder.
        let mut root = staging.clone();
        if !root.join("config.json").exists() {
            let subs: Vec<PathBuf> = fs::read_dir(&staging)?.filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| p.join("config.json").exists()).collect();
            if subs.len() != 1 { bail!("找不到模型文件夹（需要 config.json 与 .safetensors）"); }
            name = subs[0].file_name().unwrap().to_string_lossy().into_owned();
            root = subs[0].clone();
        }
        validate_dir(&root)?;
        let name: String = name.chars().map(|c| if c == '/' || c == '\\' { '-' } else { c }).collect();
        let dst = models_dir.join(safe_id(name.trim_start_matches('.'))?);
        if dst.exists() { fs::remove_dir_all(&dst)?; }
        fs::rename(&root, &dst)?;
        dir_info(&dst).context("导入后的模型无效")
    })();
    let _ = fs::remove_dir_all(&staging);
    r
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake_model(dir: &Path) {
        fs::create_dir_all(dir).unwrap();
        fs::write(dir.join("config.json"), br#"{"model_type":"qwen3_vl","vision_config":{}}"#).unwrap();
        let hdr = br#"{"w":{"dtype":"F32","shape":[2],"data_offsets":[0,8]}}"#;
        let mut f = (hdr.len() as u64).to_le_bytes().to_vec();
        f.extend_from_slice(hdr);
        f.extend_from_slice(&[0u8; 8]);
        fs::write(dir.join("model.safetensors"), f).unwrap();
        fs::write(dir.join("tokenizer.json"), b"{}").unwrap();
    }

    #[test]
    fn standard_folder_zip_roundtrip_and_validation() {
        let root = std::env::temp_dir().join(format!("tl-models-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let (a, b) = (root.join("a"), root.join("b"));
        fake_model(&a.join("org--m"));
        fake_model(&a.join("other"));
        let list = installed(&a);
        assert_eq!(list.len(), 2, "models coexist");
        assert_eq!(list[0].repo.as_deref(), Some("org/m"));
        assert!(list[0].vision);
        let zip = root.join("m.zip");
        export_zip(&a, "org--m", &zip).unwrap();
        let got = import(&b, &zip).unwrap();
        assert_eq!(got.id, "org--m");
        // a plain folder imports too
        let got2 = import(&b, &a.join("other")).unwrap();
        assert_eq!(got2.id, "other");
        assert_eq!(installed(&b).len(), 2);
        // truncated weights are rejected
        let bad = root.join("bad");
        fake_model(&bad);
        let w = fs::read(bad.join("model.safetensors")).unwrap();
        fs::write(bad.join("model.safetensors"), &w[..w.len() - 3]).unwrap();
        assert!(import(&b, &bad).is_err());
        // a partial download is not listed
        fake_model(&b.join("half"));
        fs::write(b.join("half").join(MARKER), "x").unwrap();
        assert_eq!(installed(&b).len(), 2);
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn filters_files() {
        assert!(wanted("model-00001-of-00002.safetensors") && wanted("tokenizer.json") && wanted("chat_template.jinja") && wanted("merges.txt"));
        assert!(!wanted("README.md") && !wanted(".gitattributes") && !wanted("figures/a.png"));
    }
}
