//! Deterministic simulation of sync sessions. Three libraries on disk (with real files) edit
//! concurrently and sync over in-memory pipes on a single-threaded runtime; a fault wrapper cuts
//! a session after a chosen number of bytes in either direction (a dropped Wi-Fi, a peer that
//! quits). Every run is fixed by its inputs, so a failure replays exactly (proptest shrinks it).
//! After every session both libraries must pass the consistency checks; at the end, sessions
//! without faults must bring all three to the same state, every live media file included.
mod common;
use common::{check, synced_state};
use proptest::prelude::*;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use tl_core::library::Library;
use tl_core::model::{MediaKind, Origin, PostMeta};
use tl_core::rules::TrashAction;
use tl_core::sync::SyncNode;
use tokio::io::{AsyncRead, AsyncWrite, DuplexStream, ReadBuf};

/// A pipe end that fails after `budget` bytes written (None = never).
struct Faulty { inner: DuplexStream, budget: Option<usize> }
impl AsyncRead for Faulty {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> { Pin::new(&mut self.inner).poll_read(cx, buf) }
}
impl AsyncWrite for Faulty {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<std::io::Result<usize>> {
        let n = match self.budget { Some(0) => return Poll::Ready(Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "simulated disconnect"))), Some(b) => buf.len().min(b), None => buf.len() };
        match Pin::new(&mut self.inner).poll_write(cx, &buf[..n]) {
            Poll::Ready(Ok(w)) => { if let Some(b) = self.budget.as_mut() { *b -= w; } Poll::Ready(Ok(w)) }
            o => o,
        }
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> { Pin::new(&mut self.inner).poll_flush(cx) }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> { Pin::new(&mut self.inner).poll_shutdown(cx) }
}

#[derive(Debug, Clone)]
enum Step {
    Import { n: usize, salt: u16, post: u8 },
    Tag { n: usize, pick: u8, label: u8, ai: bool },
    Untag { n: usize, pick: u8, label: u8 },
    Bin { n: usize, pick: u8, action: u8 },
    /// A session from `a` to `b`; `cut` = (side, bytes): that side's writes fail after so many bytes.
    Session { a: usize, b: usize, cut: Option<(bool, u32)> },
}

fn step() -> impl Strategy<Value = Step> {
    prop_oneof![
        3 => (0..3usize, any::<u16>(), 0..6u8).prop_map(|(n, salt, post)| Step::Import { n, salt, post }),
        2 => (0..3usize, any::<u8>(), 0..4u8, any::<bool>()).prop_map(|(n, pick, label, ai)| Step::Tag { n, pick, label, ai }),
        1 => (0..3usize, any::<u8>(), 0..4u8).prop_map(|(n, pick, label)| Step::Untag { n, pick, label }),
        2 => (0..3usize, any::<u8>(), 0..3u8).prop_map(|(n, pick, action)| Step::Bin { n, pick, action }),
        4 => (0..3usize, 0..3usize, proptest::option::of((any::<bool>(), prop_oneof![3 => 0u32..3_000, 1 => 0u32..60_000]))).prop_map(|(a, b, cut)| Step::Session { a, b, cut }),
    ]
}

fn media(lib: &Library, pick: u8) -> Option<String> {
    let db = lib.db();
    let mut st = db.conn().prepare("SELECT id FROM media ORDER BY id").unwrap();
    let v: Vec<String> = st.query_map([], |r| r.get(0)).unwrap().map(|r| r.unwrap()).collect();
    if v.is_empty() { None } else { Some(v[pick as usize % v.len()].clone()) }
}

async fn session(nodes: &[Arc<SyncNode>], a: usize, b: usize, cut: Option<(bool, u32)>) {
    let (x, y) = tokio::io::duplex(16 << 10);
    let budget = |side: bool| cut.and_then(|(s, n)| (s == side).then_some(n as usize));
    let (wa, wb) = (Faulty { inner: x, budget: budget(true) }, Faulty { inner: y, budget: budget(false) });
    let (na, nb) = (nodes[a].clone(), nodes[b].clone());
    // either side may end with an error when cut; the other then sees a closed pipe
    let r = tokio::time::timeout(std::time::Duration::from_secs(60), async move {
        tokio::join!(na.simulated_session(wa, true), nb.simulated_session(wb, false))
    }).await;
    // how often the fault really cut a session short (reported at the end)
    let cut_short = !matches!(r, Ok((Ok(()), Ok(()))));
    if cut.is_some() { STATS[0].fetch_add(1, std::sync::atomic::Ordering::Relaxed); if cut_short { STATS[1].fetch_add(1, std::sync::atomic::Ordering::Relaxed); } }
}

fn run(steps: &[Step]) -> Result<(), TestCaseError> {
    let base = std::env::temp_dir().join(format!("tl-sim-{}-{}", std::process::id(), next_id()));
    let _ = std::fs::remove_dir_all(&base);
    let dirs: Vec<std::path::PathBuf> = (0..3).map(|i| base.join(format!("lib{i}"))).collect();
    let libs: Vec<Arc<Library>> = dirs.iter().map(|d| Arc::new(Library::open(d).unwrap())).collect();
    let nodes: Vec<Arc<SyncNode>> = libs.iter().map(|l| SyncNode::new(l.clone())).collect();
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    for (i, st) in steps.iter().enumerate() {
        match st {
            Step::Import { n, salt, post } => {
                let mut bytes = vec![0xFF, 0xD8, 0xFF, 0xE0];
                bytes.extend_from_slice(format!("file {salt}").as_bytes());
                bytes.resize(1000 + (*salt as usize % 50_000), (*salt % 251) as u8);
                let lib = &libs[*n];
                let (sha, rel) = lib.put_blob(&bytes, "jpg").unwrap();
                let db = lib.db();
                let tx = db.conn().unchecked_transaction().unwrap();
                db.upsert_post(&PostMeta { id: format!("p{post}"), text: Some(format!("正文{post}")), ..Default::default() }).unwrap();
                db.add_media(&sha, &format!("p{post}"), (*salt % 3) as i64, &MediaKind::Photo, &rel, false).unwrap();
                tx.commit().unwrap();
            }
            Step::Tag { n, pick, label, ai } => if let Some(m) = media(&libs[*n], *pick) { libs[*n].tag(&m, &format!("l{label}"), if *ai { Origin::AI } else { Origin::USER }).unwrap(); },
            Step::Untag { n, pick, label } => if let Some(m) = media(&libs[*n], *pick) { libs[*n].db().untag_media(&m, &format!("l{label}")).unwrap(); },
            Step::Bin { n, pick, action } => if let Some(m) = media(&libs[*n], *pick) {
                libs[*n].trash_apply(&[m], [TrashAction::Trash, TrashAction::Restore, TrashAction::Purge][*action as usize]).unwrap();
            },
            Step::Session { a, b, cut } => {
                if a == b { continue; }
                rt.block_on(session(&nodes, *a, *b, *cut));
                for n in [*a, *b] {
                    let r = std::panic::catch_unwind(|| check(&dirs[n], i));
                    prop_assert!(r.is_ok(), "step {i} {st:?}: library {n} inconsistent after the session");
                }
            }
        }
    }
    // without faults, everyone converges (files included)
    for _ in 0..4 { for a in 0..3 { for b in 0..3 { if a != b { rt.block_on(session(&nodes, a, b, None)); } } } }
    for (n, d) in dirs.iter().enumerate() {
        let r = std::panic::catch_unwind(|| check(d, 10_000 + n));
        prop_assert!(r.is_ok(), "library {n} inconsistent at the end");
    }
    let states: Vec<Vec<String>> = libs.iter().map(|l| synced_state(&l.db())).collect();
    for n in 1..3 { prop_assert_eq!(&states[n], &states[0], "library {} differs from library 0 after fault-free sessions", n); }
    let files = |l: &Library| -> Vec<String> {
        let db = l.db();
        let mut st = db.conn().prepare("SELECT m.id FROM media m WHERE NOT EXISTS(SELECT 1 FROM trash x WHERE x.media_id=m.id AND x.state!=0) ORDER BY 1").unwrap();
        let v = st.query_map([], |r| r.get(0)).unwrap().map(|r| r.unwrap()).collect(); v
    };
    let live0 = files(&libs[0]);
    for n in 1..3 { prop_assert_eq!(&files(&libs[n]), &live0, "live media (with files) of library {}", n); }
    drop(nodes); drop(libs);
    let _ = std::fs::remove_dir_all(&base);
    Ok(())
}

static STATS: [std::sync::atomic::AtomicUsize; 2] = [std::sync::atomic::AtomicUsize::new(0), std::sync::atomic::AtomicUsize::new(0)];

fn next_id() -> u64 { use std::sync::atomic::{AtomicU64, Ordering}; static N: AtomicU64 = AtomicU64::new(0); N.fetch_add(1, Ordering::Relaxed) }

proptest! {
    #![proptest_config(ProptestConfig { cases: 48, max_shrink_iters: 300, ..ProptestConfig::default() })]

    #[test]
    fn sessions_with_faults_keep_libraries_consistent_and_converging(steps in proptest::collection::vec(step(), 1..30)) {
        run(&steps)?;
    }
}

/// Runs after the property (alphabetical order is not guaranteed, so it only reports).
#[test]
fn zz_report_how_often_faults_cut_sessions() {
    let (faulty, cut) = (STATS[0].load(std::sync::atomic::Ordering::Relaxed), STATS[1].load(std::sync::atomic::Ordering::Relaxed));
    eprintln!("sessions with a fault: {faulty}, of which ended early: {cut}");
}
