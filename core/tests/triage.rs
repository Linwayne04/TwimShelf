//! Triage mode: decisions per post, local only; effects (bin, folders) sync; undo is exact;
//! invariants hold under sync, bin, renames, folder deletion and new media arriving.
use proptest::prelude::*;
use tl_core::model::{MediaKind, Origin, PostMeta};
use tl_core::rules::{TrashAction, LIVE, TRASHED};
use tl_core::store::Store;
use tl_core::triage::{Decision, TriageFilter, TriageKind, TriageMedia};

fn mid(m: u8) -> String { format!("{m:064}") }
/// posts p0..p2 with media (p0: m0 m1, p1: m2, p2: m3 video); loose:m4
fn lib() -> Store {
    let s = Store::open(":memory:").unwrap();
    for p in 0..3 { s.upsert_post(&PostMeta { id: format!("p{p}"), ..Default::default() }).unwrap(); }
    s.upsert_post(&PostMeta { id: format!("loose:{}", mid(4)), ..Default::default() }).unwrap();
    for (m, p, o, k) in [(0u8, "p0", 0, MediaKind::Photo), (1, "p0", 1, MediaKind::Photo), (2, "p1", 0, MediaKind::Photo), (3, "p2", 0, MediaKind::Video)] {
        s.add_media(&mid(m), p, o, &k, &format!("blobs/00/{}.jpg", mid(m)), false).unwrap();
    }
    s.add_media(&mid(4), &format!("loose:{}", mid(4)), 0, &MediaKind::Photo, &format!("blobs/00/{}.jpg", mid(4)), false).unwrap();
    s
}
fn queue(s: &Store, f: &TriageFilter) -> Vec<String> { s.triage_queue(f).unwrap().into_iter().map(|u| u.post_id).collect() }

#[test]
fn decisions_undo_and_groups() {
    let s = lib();
    let all = TriageFilter::default();
    let q = s.triage_queue(&all).unwrap();
    assert_eq!(q.len(), 4);
    assert_eq!(q.iter().find(|u| u.post_id == "p0").unwrap().items.len(), 2, "a post comes as one group");
    // keep p0 → gone from the queue for good
    assert!(s.triage_decide("p0", Decision::Keep, None).unwrap());
    assert!(!queue(&s, &all).contains(&"p0".to_string()));
    assert!(!s.triage_decide("p0", Decision::Delete, None).unwrap(), "a triaged post cannot be decided again");
    // delete p1 → its media in the bin; undo → back
    assert!(s.triage_decide("p1", Decision::Delete, None).unwrap());
    assert_eq!(s.trash_reg(&mid(2)).unwrap().state, TRASHED);
    assert!(s.triage_undo("p1").unwrap());
    assert_eq!(s.trash_reg(&mid(2)).unwrap().state, LIVE);
    assert!(queue(&s, &all).contains(&"p1".to_string()), "undone post is offered again");
    // folder
    assert!(s.triage_decide("p2", Decision::Folder, Some("好看")).unwrap());
    assert_eq!(s.folders_of(&mid(3)).unwrap(), vec!["好看".to_string()]);
    assert!(s.triage_undo("p2").unwrap());
    assert!(s.folders_of(&mid(3)).unwrap().is_empty(), "undo takes it out of the folder again");
    // clearing the history brings back p0
    s.triage_clear().unwrap();
    assert_eq!(queue(&s, &all).len(), 4);
}

#[test]
fn undo_restores_only_what_the_delete_moved() {
    let s = lib();
    s.trash_action(&mid(1), TrashAction::Trash).unwrap();          // m1 already in the bin
    assert!(s.triage_decide("p0", Decision::Delete, None).unwrap());
    assert_eq!((s.trash_reg(&mid(0)).unwrap().state, s.trash_reg(&mid(1)).unwrap().state), (TRASHED, TRASHED));
    s.trash_action(&mid(0), TrashAction::Purge).unwrap();          // and m0 is emptied from the bin meanwhile
    assert!(s.triage_undo("p0").unwrap());
    assert_eq!(s.trash_reg(&mid(1)).unwrap().state, TRASHED, "m1 was binned before the triage: it stays binned");
    assert_ne!(s.trash_reg(&mid(0)).unwrap().state, LIVE, "a permanently deleted media is never revived by undo");
}

#[test]
fn triage_is_local_but_its_effects_sync() {
    let (a, b) = (lib(), lib());
    let all = TriageFilter::default();
    a.triage_decide("p0", Decision::Keep, None).unwrap();
    a.triage_decide("p1", Decision::Delete, None).unwrap();
    a.triage_decide("p2", Decision::Folder, Some("夹")).unwrap();
    let ops = a.ops_since(&b.version_vector().unwrap(), 100_000).unwrap();
    assert!(ops.iter().all(|o| !format!("{:?}", o.op).to_lowercase().contains("triage")), "no triage records in the sync log");
    b.apply_remote(&ops, |_, _| true).unwrap();
    assert!(!b.is_triaged("p0").unwrap() && !b.is_triaged("p1").unwrap(), "the other device keeps its own triage progress");
    assert_eq!(b.trash_reg(&mid(2)).unwrap().state, TRASHED, "the delete synced (bin)");
    assert_eq!(b.folders_of(&mid(3)).unwrap(), vec!["夹".to_string()], "the folder synced");
    let qb = queue(&b, &all);
    assert!(qb.contains(&"p0".to_string()) && !qb.contains(&"p1".to_string()), "p1 has no live media left anywhere");
}

#[test]
fn filters_folder_tag_kind_media_and_renames() {
    let s = lib();
    s.add_to_folder("A", &[mid(1)]).unwrap();
    s.tag_media(&mid(3), "夜景", Origin::AI).unwrap();
    let f = |folders: Vec<&str>, labels: Vec<&str>, kind, media| TriageFilter { folders: folders.into_iter().map(String::from).collect(), labels: labels.into_iter().map(String::from).collect(), kind, media, recent_only: false };
    assert_eq!(queue(&s, &f(vec!["A"], vec![], TriageKind::All, TriageMedia::All)), vec!["p0"], "a post qualifies through any of its media");
    assert_eq!(queue(&s, &f(vec![], vec!["夜景"], TriageKind::All, TriageMedia::All)), vec!["p2"]);
    assert_eq!(queue(&s, &f(vec![], vec![], TriageKind::Loose, TriageMedia::All)), vec![format!("loose:{}", mid(4))]);
    assert_eq!(queue(&s, &f(vec![], vec![], TriageKind::Posts, TriageMedia::Video)), vec!["p2"]);
    // rename during triage: the old filter name still finds the tag
    s.rename_tag("夜景", "城市夜景").unwrap();
    assert_eq!(queue(&s, &f(vec![], vec!["夜景"], TriageKind::All, TriageMedia::All)), vec!["p2"]);
    assert_eq!(queue(&s, &f(vec![], vec!["城市夜景"], TriageKind::All, TriageMedia::All)), vec!["p2"]);
}

#[derive(Debug, Clone)]
enum Step { Keep(u8), Delete(u8), Folder(u8), Undo(u8), Clear, Bin(u8), Restore(u8), Purge(u8), NewMedia(u8, u8), RemoteBin(u8), Rename, DropFolder, Sync }

fn step() -> impl Strategy<Value = Step> {
    prop_oneof![
        (0..4u8).prop_map(Step::Keep), (0..4u8).prop_map(Step::Delete), (0..4u8).prop_map(Step::Folder), (0..4u8).prop_map(Step::Undo),
        Just(Step::Clear), (0..6u8).prop_map(Step::Bin), (0..6u8).prop_map(Step::Restore), (0..6u8).prop_map(Step::Purge),
        (5..8u8, 0..3u8).prop_map(|(m, p)| Step::NewMedia(m, p)), (0..6u8).prop_map(Step::RemoteBin), Just(Step::Rename), Just(Step::DropFolder), Just(Step::Sync),
    ]
}
fn post_of(i: u8) -> String { if i == 3 { format!("loose:{}", mid(4)) } else { format!("p{i}") } }

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]
    /// Whatever happens — triage, undo, bin edits here and on another device, renames, folders,
    /// new media on triaged posts, clearing the history — the queue is exactly the live, matching,
    /// untriaged posts, and triage never leaks into sync.
    #[test]
    fn queue_invariants(steps in proptest::collection::vec(step(), 1..30), tagged in any::<bool>()) {
        let (a, b) = (lib(), lib());
        if tagged { a.tag_media(&mid(0), "x", Origin::USER).unwrap(); a.tag_media(&mid(3), "x", Origin::AI).unwrap(); }
        let sync = |x: &Store, y: &Store| { let ops = x.ops_since(&y.version_vector().unwrap(), 100_000).unwrap(); y.apply_remote(&ops, |_, _| true).unwrap(); };
        sync(&a, &b);
        let filters = [TriageFilter::default(), TriageFilter { labels: vec!["x".into()], ..Default::default() }, TriageFilter { folders: vec!["整理".into()], ..Default::default() }];
        for st in &steps {
            match st {
                Step::Keep(i) => { a.triage_decide(&post_of(*i), Decision::Keep, None).unwrap(); }
                Step::Delete(i) => { a.triage_decide(&post_of(*i), Decision::Delete, None).unwrap(); }
                Step::Folder(i) => { a.triage_decide(&post_of(*i), Decision::Folder, Some("整理")).unwrap(); }
                Step::Undo(i) => { a.triage_undo(&post_of(*i)).unwrap(); }
                Step::Clear => { a.triage_clear().unwrap(); }
                Step::Bin(m) => { a.trash_action(&mid(*m), TrashAction::Trash).unwrap(); }
                Step::Restore(m) => { a.trash_action(&mid(*m), TrashAction::Restore).unwrap(); }
                Step::Purge(m) => { a.trash_action(&mid(*m), TrashAction::Purge).unwrap(); }
                Step::NewMedia(m, p) => { b.add_media(&mid(*m), &format!("p{p}"), 9, &MediaKind::Photo, "blobs/00/n.jpg", false).unwrap(); }
                Step::RemoteBin(m) => { b.trash_action(&mid(*m), TrashAction::Trash).unwrap(); }
                Step::Rename => { a.rename_tag("x", "y").unwrap(); }
                Step::DropFolder => { a.delete_folder("整理").unwrap(); }
                Step::Sync => { sync(&a, &b); sync(&b, &a); }
            }
            for f in &filters {
                let q = queue(&a, f);
                // completeness and soundness against the rule, post by post
                for i in 0..4u8 {
                    let p = post_of(i);
                    let live = a.live_media_of_post(&p).unwrap();
                    let matches = live.iter().any(|m| {
                        (f.labels.is_empty() || a.media_tags(m).unwrap().iter().any(|(l, o)| *o != 0 && f.labels.iter().any(|x| a.canonical(x).unwrap() == *l)))
                            && (f.folders.is_empty() || a.folders_of(m).unwrap().iter().any(|x| f.folders.contains(x)))
                    });
                    let want = tl_core::rules::triage_eligible(live.len(), a.is_triaged(&p).unwrap(), matches);
                    prop_assert_eq!(q.contains(&p), want, "post {} filter {:?}", p, f);
                }
            }
        }
        // triage records never enter the sync log
        let ops = a.ops_since(&Default::default(), 100_000).unwrap();
        let leaked = ops.iter().any(|o| format!("{:?}", o.op).to_lowercase().contains("triage"));
        prop_assert!(!leaked, "no triage records in the sync log");
        sync(&a, &b);
        prop_assert_eq!(b.triage_counts(&TriageFilter::default()).unwrap().triaged, 0, "the other device never sees triage progress");
    }
}

/// A 1,500-post library with tags and AI provenance: the queue and the counts are built in one
/// pass (a query per post froze the Mac app when triage mode was switched on).
#[test]
fn queue_of_a_large_library_is_fast() {
    let s = Store::open(":memory:").unwrap();
    let tx = s.conn().unchecked_transaction().unwrap();
    for p in 0..1500u32 {
        s.upsert_post(&PostMeta { id: format!("p{p}"), text: Some(format!("帖子 {p}")), ..Default::default() }).unwrap();
        for k in 0..2u32 {
            let id = format!("{:064}", p * 2 + k);
            s.add_media(&id, &format!("p{p}"), k as i64, &MediaKind::Photo, &format!("blobs/00/{id}.jpg"), false).unwrap();
            for t in 0..3 { s.tag_media(&id, &format!("标签{}", (p + t) % 40), Origin::AI).unwrap(); s.set_tag_source(&id, &format!("标签{}", (p + t) % 40), "m", true).unwrap(); }
        }
    }
    tx.commit().unwrap();
    let t0 = std::time::Instant::now();
    let q = s.triage_queue(&TriageFilter::default()).unwrap();
    let c = s.triage_counts(&TriageFilter::default()).unwrap();
    let el = t0.elapsed();
    assert_eq!((q.len(), c.remaining), (1500, 1500));
    assert!(q.iter().all(|u| u.items.len() == 2 && u.items[0].ordinal == 0 && u.items[0].tags.len() == 3));
    if !cfg!(debug_assertions) { assert!(el.as_millis() < 1500, "queue took {el:?}"); }
    eprintln!("triage queue of 1500 posts / 3000 media: {el:?}");
}
