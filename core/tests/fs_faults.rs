//! File-system faults: writes that fail must come back as errors (never a panic, never a half
//! state), leave the library consistent, and work again once the fault is gone.
//!  * folders that cannot be written (permissions);
//!  * a file where a folder is expected;
//!  * a full disk: a real 16 MB volume (hdiutil), filled until the system reports no space.
//! The disk-full case mounts a disk image, so it runs only with TL_DISKFULL=1.
mod common;
use common::check;
use std::os::unix::fs::PermissionsExt;
use tl_core::library::Library;
use tl_core::model::{MediaKind, PostMeta};

fn jpeg(n: usize, salt: u64) -> Vec<u8> {
    let mut b = vec![0xFF, 0xD8, 0xFF, 0xE0];
    let mut x = salt | 1;
    b.extend((0..n).map(|_| { x ^= x << 13; x ^= x >> 7; x ^= x << 17; x as u8 }));
    b
}

/// An import as the app does it: the file, then the post and media in one transaction.
fn import(lib: &Library, bytes: &[u8], post: &str) -> anyhow::Result<String> {
    let (sha, rel) = lib.put_blob(bytes, "jpg")?;
    let db = lib.db();
    let tx = db.conn().unchecked_transaction()?;
    db.upsert_post(&PostMeta { id: post.into(), text: Some("正文".into()), ..Default::default() })?;
    db.add_media(&sha, post, 0, &MediaKind::Photo, &rel, false)?;
    tx.commit()?;
    Ok(sha)
}

fn set_mode(p: &std::path::Path, mode: u32) { std::fs::set_permissions(p, std::fs::Permissions::from_mode(mode)).unwrap(); }

#[test]
fn unwritable_folders_fail_cleanly_and_recover() {
    let dir = std::env::temp_dir().join(format!("tl-fsfault-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    {
        let lib = Library::open(&dir).unwrap();
        for i in 0..5 { import(&lib, &jpeg(2000, i), &format!("p{i}")).unwrap(); }
        let before: i64 = lib.db().conn().query_row("SELECT count(*) FROM media", [], |r| r.get(0)).unwrap();
        // 1. blobs/ and its subfolders read-only: every new file fails
        let blobs = dir.join("blobs");
        let subs: Vec<_> = std::fs::read_dir(&blobs).unwrap().flatten().map(|e| e.path()).collect();
        for s in &subs { set_mode(s, 0o555); }
        set_mode(&blobs, 0o555);
        let mut failed = 0;
        for i in 10..20 { if import(&lib, &jpeg(2000, i), &format!("q{i}")).is_err() { failed += 1; } }
        assert_eq!(failed, 10, "every import into a read-only folder fails (as an error)");
        let after: i64 = lib.db().conn().query_row("SELECT count(*) FROM media", [], |r| r.get(0)).unwrap();
        assert_eq!(after, before, "no media row without its file");
        set_mode(&blobs, 0o755);
        for s in &subs { set_mode(s, 0o755); }
        // 2. a file where a subfolder of blobs/ should be
        let probe = jpeg(2000, 99);
        let sha = { use sha2::Digest; hex::encode(sha2::Sha256::digest(&probe)) };
        let sub = blobs.join(&sha[..2]);
        if !sub.exists() { std::fs::write(&sub, b"not a folder").unwrap(); }
        let r = import(&lib, &probe, "r");
        if std::fs::metadata(&sub).unwrap().is_file() {
            assert!(r.is_err(), "storing under a file instead of a folder fails as an error");
            std::fs::remove_file(&sub).unwrap();
        }
        // recovered: imports work again
        for i in 30..33 { import(&lib, &jpeg(2000, i), &format!("s{i}")).unwrap(); }
    }
    check(&dir, 0);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_full_disk_fails_cleanly_and_recovers() {
    if std::env::var("TL_DISKFULL").is_err() { eprintln!("skipped: set TL_DISKFULL=1 (mounts a 16 MB disk image)"); return; }
    let base = std::env::temp_dir().join(format!("tl-diskfull-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    std::fs::create_dir_all(&base).unwrap();
    let img = base.join("full.dmg");
    let mnt = base.join("vol");
    std::fs::create_dir_all(&mnt).unwrap();
    let run = |args: &[&str]| { let o = std::process::Command::new("hdiutil").args(args).output().unwrap(); assert!(o.status.success(), "hdiutil {:?}: {}", args, String::from_utf8_lossy(&o.stderr)); };
    run(&["create", "-size", "16m", "-fs", "HFS+", "-volname", "tlfull", img.to_str().unwrap()]);
    run(&["attach", "-nobrowse", "-mountpoint", mnt.to_str().unwrap(), img.to_str().unwrap()]);
    let dir = mnt.join("lib");
    let result = std::panic::catch_unwind(|| {
        let lib = Library::open(&dir).unwrap();
        let mut stored = vec![];
        let mut err = None;
        for i in 0..200 {
            match import(&lib, &jpeg(400_000, i), &format!("p{i}")) {
                Ok(sha) => stored.push(sha),
                Err(e) => { err = Some(format!("{e:#}")); break; }
            }
        }
        let err = err.expect("the volume filled up");
        eprintln!("full after {} imports: {err}", stored.len());
        assert!(err.contains("No space left") || err.contains("space") || err.contains("disk full") || err.contains("SQLITE_FULL") || err.contains("full"), "{err}");
        drop(lib);
        check(&dir, 1);
        // free space by deleting media permanently, then imports work again
        let lib = Library::open(&dir).unwrap();
        lib.trash_apply(&stored[..stored.len().min(8)], tl_core::rules::TrashAction::Trash).unwrap();
        lib.trash_apply(&stored[..stored.len().min(8)], tl_core::rules::TrashAction::Purge).unwrap();
        import(&lib, &jpeg(400_000, 9999), "again").expect("imports work once there is space again");
        drop(lib);
        check(&dir, 2);
    });
    let _ = std::process::Command::new("hdiutil").args(["detach", "-force", mnt.to_str().unwrap()]).output();
    let _ = std::fs::remove_dir_all(&base);
    if let Err(p) = result { std::panic::resume_unwind(p); }
}
