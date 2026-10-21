//! Consistency checks shared by the fault-injection tests.
#![allow(dead_code)]
use tl_core::library::Library;
use tl_core::oplog::{LoggedOp, VersionVector};
use tl_core::store::Store;

/// State lines that depend only on the records (not on local-only tables or file presence).
pub fn synced_state(s: &Store) -> Vec<String> {
    let mut v = vec![];
    for (sql, n) in [
        ("SELECT id, author_name, text FROM post ORDER BY 1", 3),
        ("SELECT tm.media_id, t.label, tm.origin, tm.h_user, tm.h_ai FROM tag_media tm JOIN tag t ON t.id=tm.tag_id ORDER BY 1,2", 5),
        ("SELECT media_id, inc, state, hlc FROM trash ORDER BY 1", 4),
        ("SELECT name, deleted, hlc FROM folder ORDER BY 1", 3),
        ("SELECT folder, media_id, present, hlc FROM folder_media ORDER BY 1,2", 4),
        ("SELECT media_id, post_id, ordinal FROM media_claim ORDER BY 1,2,3", 3),
    ] {
        let mut st = s.conn().prepare(sql).unwrap();
        let rows = st.query_map([], |r| {
            let mut parts = vec![];
            for i in 0..n { parts.push(match r.get_ref(i)? { rusqlite::types::ValueRef::Null => "-".into(), rusqlite::types::ValueRef::Integer(x) => x.to_string(), rusqlite::types::ValueRef::Text(t) => String::from_utf8_lossy(t).into_owned(), _ => "?".into() }); }
            Ok(parts.join(" "))
        }).unwrap();
        for r in rows { v.push(format!("{sql}: {}", r.unwrap())); }
    }
    v
}

/// Opens the library and checks every invariant; panics with the round on a violation.
pub fn check(dir: &std::path::Path, round: usize) {
    let lib = Library::open(dir).unwrap_or_else(|e| panic!("round {round}: the library does not open after a kill: {e:#}"));
    let db = lib.db();
    let ok: String = db.conn().query_row("PRAGMA integrity_check", [], |r| r.get(0)).unwrap();
    assert_eq!(ok, "ok", "round {round}: integrity");
    // contiguous logs
    let log: Vec<LoggedOp> = db.ops_since(&VersionVector::new(), 10_000_000).unwrap();
    for (dev, max) in db.version_vector().unwrap() {
        assert_eq!(log.iter().filter(|o| o.device == dev).count() as i64, max, "round {round}: log of {dev} has gaps");
    }
    // every stored media has its file with the right content
    let rows: Vec<(String, String)> = { let mut st = db.conn().prepare("SELECT id, path FROM media").unwrap(); let v = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).unwrap().map(|r| r.unwrap()).collect(); v };
    drop(db);
    for (id, path) in &rows {
        let purged = lib.db().trash_reg(id).unwrap().state == tl_core::rules::PURGED;
        if purged { continue; }   // deleted permanently: its file is gone on purpose
        assert_eq!(lib.check_file(id, path), None, "round {round}: media {id} has no intact file");
    }
    // no unreferenced files are left (startup sweeps them)
    let known: std::collections::HashSet<String> = rows.iter().map(|r| r.0.clone()).collect();
    for d in std::fs::read_dir(dir.join("blobs")).unwrap().flatten() {
        for f in std::fs::read_dir(d.path()).unwrap().flatten() {
            let n = f.file_name().to_string_lossy().into_owned();
            let id = n.split('.').next().unwrap().to_string();
            assert!(known.contains(&id) || lib.db().wanted_is_photo(&id).unwrap().is_some(), "round {round}: unreferenced file {n}");
        }
    }
    // replaying the logs gives the same state
    let replay = Store::open(":memory:").unwrap();
    replay.apply_remote_counted(&log, |id, ext| dir.join(tl_core::oplog::blob_rel(id, ext)).exists()).unwrap();
    let (got, want) = (synced_state(&lib.db()), synced_state(&replay));
    if got != want {
        let missing: Vec<_> = want.iter().filter(|l| !got.contains(l)).take(5).collect();
        let extra: Vec<_> = got.iter().filter(|l| !want.contains(l)).take(5).collect();
        panic!("round {round}: state differs from the replay of its own records\n  in the replay only: {missing:?}\n  in the library only: {extra:?}");
    }
}

