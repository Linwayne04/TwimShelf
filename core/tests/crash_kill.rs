//! Crash consistency: a child process runs a realistic workload on a library on disk (imports
//! that store files, tagging, the recycle bin with permanent deletion, folders, records arriving
//! from another device) and is killed with SIGKILL at a random moment, again and again on the
//! same library. After every kill the library must open and satisfy:
//!  * SQLite's integrity check passes;
//!  * every device's log is contiguous;
//!  * every stored media has its file, with the content its id says;
//!  * no file in blobs/ is left unreferenced (startup sweeps them);
//!  * replaying the library's own logs into an empty store gives the same state: every change
//!    and the record that syncs it were written together, so nothing changed here can be missing
//!    from what other devices receive.
mod common;
use common::check;
use std::process::{Command, Stdio};
use std::time::Duration;
use tl_core::library::Library;
use tl_core::model::{MediaKind, Origin, PostMeta};
use tl_core::oplog::VersionVector;
use tl_core::rules::TrashAction;
use tl_core::store::Store;

const CHILD: &str = "TL_CRASH_CHILD_DIR";

/// The workload, run by the child until it is killed.
fn workload(dir: &std::path::Path, seed: u64) {
    let lib = Library::open(dir).unwrap();
    let mut x = seed | 1;
    let mut rnd = move |n: u64| { x ^= x << 13; x ^= x >> 7; x ^= x << 17; x % n };
    // a second device whose records keep arriving
    let peer = Store::open(":memory:").unwrap();
    let mut sent = VersionVector::new();
    let mut i: u64 = 0;
    loop {
        i += 1;
        match rnd(8) {
            0 | 1 => {
                // an import: the file, then the post and its media in one transaction (as downloads do)
                let mut bytes = vec![0xFF, 0xD8, 0xFF, 0xE0];
                bytes.extend_from_slice(format!("{seed}-{i}-{}", rnd(1 << 30)).as_bytes());
                let (sha, rel) = lib.put_blob(&bytes, "jpg").unwrap();
                let db = lib.db();
                let tx = db.conn().unchecked_transaction().unwrap();
                let post = format!("p{}", rnd(20));
                db.upsert_post(&PostMeta { id: post.clone(), text: Some(format!("正文{i}")), ..Default::default() }).unwrap();
                db.add_media(&sha, &post, rnd(4) as i64, &MediaKind::Photo, &rel, false).unwrap();
                tx.commit().unwrap();
            }
            2 => {
                let ids = media_ids(&lib);
                if let Some(id) = pick(&ids, rnd(1000)) { lib.tag(&id, &format!("l{}", rnd(5)), if rnd(2) == 0 { Origin::USER } else { Origin::AI }).unwrap(); }
            }
            3 => {
                let ids = media_ids(&lib);
                if let Some(id) = pick(&ids, rnd(1000)) { lib.db().untag_media(&id, &format!("l{}", rnd(5))).unwrap(); }
            }
            4 => {
                let ids = media_ids(&lib);
                if let Some(id) = pick(&ids, rnd(1000)) {
                    let a = [TrashAction::Trash, TrashAction::Restore, TrashAction::Purge][rnd(3) as usize];
                    lib.trash_apply(&[id], a).unwrap();
                }
            }
            5 => {
                let ids = media_ids(&lib);
                if let Some(id) = pick(&ids, rnd(1000)) { lib.db().add_to_folder(&format!("夹{}", rnd(3)), &[id]).unwrap(); }
            }
            _ => {
                // the other device edits, and its new records arrive here
                peer.upsert_post(&PostMeta { id: format!("q{}", rnd(10)), author_name: Some(format!("作者{}", rnd(5))), ..Default::default() }).unwrap();
                peer.tag_media(&format!("{:064x}", rnd(6)), &format!("l{}", rnd(5)), Origin::USER).unwrap();
                let ops = peer.ops_since(&sent, 1000).unwrap();
                for o in &ops { sent.insert(o.device.clone(), o.seq); }
                let d = dir.to_path_buf();
                lib.db().apply_remote_counted(&ops, |id, ext| d.join(tl_core::oplog::blob_rel(id, ext)).exists()).unwrap();
            }
        }
    }
}

fn media_ids(lib: &Library) -> Vec<String> {
    let db = lib.db();
    let mut st = db.conn().prepare("SELECT id FROM media ORDER BY id").unwrap();
    let v = st.query_map([], |r| r.get(0)).unwrap().map(|r| r.unwrap()).collect();
    v
}
fn pick(v: &[String], r: u64) -> Option<String> { if v.is_empty() { None } else { Some(v[r as usize % v.len()].clone()) } }

#[test]
fn killed_at_any_moment_the_library_stays_consistent() {
    if let Ok(d) = std::env::var(CHILD) {
        let seed: u64 = std::env::var("TL_CRASH_SEED").unwrap().parse().unwrap();
        workload(std::path::Path::new(&d), seed);
        return;
    }
    let rounds: usize = std::env::var("TL_CRASH_ROUNDS").ok().and_then(|v| v.parse().ok()).unwrap_or(40);
    let dir = std::env::temp_dir().join(format!("tl-crash-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let exe = std::env::current_exe().unwrap();
    let mut x: u64 = 0x9E3779B97F4A7C15;
    for round in 0..rounds {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        let mut child = Command::new(&exe)
            .args(["killed_at_any_moment_the_library_stays_consistent", "--exact", "--nocapture", "--test-threads=1"])
            .env(CHILD, &dir).env("TL_CRASH_SEED", (x % 1_000_000).to_string())
            .stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
        // let it open the library (and migrate / sweep) and then work for a random while
        std::thread::sleep(Duration::from_millis(30 + x % 400));
        child.kill().unwrap();   // SIGKILL
        child.wait().unwrap();
        check(&dir, round);
    }
    let lib = Library::open(&dir).unwrap();
    let n: i64 = lib.db().conn().query_row("SELECT count(*) FROM op", [], |r| r.get(0)).unwrap();
    eprintln!("{rounds} kills, {n} records survived and replay identically");
    assert!(n > 0, "the workload ran");
    drop(lib);
    let _ = std::fs::remove_dir_all(&dir);
}
