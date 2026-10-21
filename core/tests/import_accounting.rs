//! Import accounting: whatever the archive contains, every entry ends up in exactly one bucket,
//! the library's totals follow from the report, nothing that is not real media is stored, and
//! ZIP and folder imports of the same tree agree. Problem files export unchanged.
use proptest::prelude::*;
use std::collections::BTreeMap;
use std::io::{Read, Write};
use tl_core::library::Library;

#[derive(Debug, Clone, Copy)]
enum Content { Jpeg(u8), Png(u8), Mp4(u8), Html(u8), Empty, Text }

fn bytes(c: Content) -> Vec<u8> {
    match c {
        Content::Jpeg(k) => [&[0xFF, 0xD8, 0xFF, 0xE0][..], &[k; 3]].concat(),
        Content::Png(k) => [&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A][..], &[k; 3]].concat(),
        Content::Mp4(k) => [&b"\0\0\0\x18ftypisom"[..], &[k; 3]].concat(),
        Content::Html(k) => format!("<!DOCTYPE html><title>error {k}</title>").into_bytes(),
        Content::Empty => vec![],
        Content::Text => b"just some notes".to_vec(),
    }
}

fn content() -> impl Strategy<Value = Content> {
    prop_oneof![
        (0..3u8).prop_map(Content::Jpeg), (0..2u8).prop_map(Content::Png), (0..2u8).prop_map(Content::Mp4),
        (0..2u8).prop_map(Content::Html), Just(Content::Empty), Just(Content::Text),
    ]
}

fn entry() -> impl Strategy<Value = (String, Content)> {
    let dir = prop::sample::select(vec!["", "包/", "包/帖子A/", "包/帖子B/", "包/帖子C/", "包/帖子A/子文件夹/", "包/.隐藏/", "__MACOSX/包/", "帖子D/", "../"]);
    let file = prop::sample::select(vec!["1.jpg", "2.png", "3.mp4", "4.jpeg", "a.mov", "b.heic", "noext", ".DS_Store", "推文内容.txt"]);
    (dir, file, content()).prop_map(|(d, f, c)| (format!("{d}{f}"), c))
}

/// Sidecars get text content with an ID from a small set (so posts merge sometimes).
fn sidecar(i: usize) -> Vec<u8> { format!("推文 ID: {}\n【推文完整正文】\n正文 {i}", 900 + i % 2).into_bytes() }

fn tmp(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("tl-acct-{name}-{}-{}", std::process::id(), rand_u32()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}
fn rand_u32() -> u32 { use std::sync::atomic::{AtomicU32, Ordering}; static N: AtomicU32 = AtomicU32::new(0); N.fetch_add(1, Ordering::SeqCst) }

fn tree(entries: &[(String, Content)]) -> BTreeMap<String, Vec<u8>> {
    let mut m = BTreeMap::new();
    for (i, (p, c)) in entries.iter().enumerate() {
        let b = if p.ends_with("推文内容.txt") { sidecar(i) } else { bytes(*c) };
        m.entry(p.clone()).or_insert(b);   // one entry per path
    }
    m
}

fn check(lib: &Library, r: &tl_core::library::ImportReport) -> Result<(), TestCaseError> {
    let file_issues = r.issues.iter().filter(|i| !i.category.starts_with("post_") && i.category != "duplicate" && i.category != "in_bin").count();
    prop_assert_eq!(r.entries, r.system_files + r.sidecars + r.new_media + r.duplicate_media + r.deleted + file_issues,
        "every entry accounted for exactly once: {:?}", r.issues);
    prop_assert_eq!(r.issues.iter().filter(|i| i.category == "duplicate").count(), r.duplicate_media);
    let st = lib.db().stats().unwrap();
    prop_assert_eq!((st.photos + st.videos) as usize, r.new_media, "library media = new media");
    prop_assert_eq!(st.posts as usize, r.posts - r.merged_posts - r.posts_without_media, "library posts follow from the report");
    // nothing stored is anything but real media
    for (id, rel) in lib.db().live_media_paths().unwrap() { prop_assert_eq!(lib.check_file(&id, &rel), None, "stored {} is real media", rel); }
    // every duplicate names the file it duplicates
    for i in r.issues.iter().filter(|i| i.category == "duplicate") { prop_assert!(i.same_as.is_some()); }
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    #[test]
    fn every_entry_is_accounted_for(entries in proptest::collection::vec(entry(), 1..18)) {
        let files = tree(&entries);
        let d = tmp("zip");
        // ZIP import
        let zp = d.join("in.zip");
        {
            let mut z = zip::ZipWriter::new(std::fs::File::create(&zp).unwrap());
            for (p, b) in &files { z.start_file(p.as_str(), zip::write::SimpleFileOptions::default()).unwrap(); z.write_all(b).unwrap(); }
            z.finish().unwrap();
        }
        let lz = Library::open(d.join("libz")).unwrap();
        let rz = tl_core::archive::import_legacy_zip(&lz, &zp).unwrap();
        check(&lz, &rz)?;
        // the same tree as a folder (unsafe paths cannot exist on disk, leave them out)
        let src = d.join("src");
        for (p, b) in files.iter().filter(|(p, _)| !p.starts_with("../")) {
            let f = src.join(p);
            std::fs::create_dir_all(f.parent().unwrap()).unwrap();
            std::fs::write(f, b).unwrap();
        }
        std::fs::create_dir_all(&src).unwrap();
        let ld = Library::open(d.join("libd")).unwrap();
        let rd = ld.import_legacy_dir(&src).unwrap();
        check(&ld, &rd)?;
        let unsafe_n = rz.issues.iter().filter(|i| i.category == "unsafe_path").count();
        prop_assert_eq!((rz.new_media, rz.duplicate_media, rz.posts, rz.issues.len() - unsafe_n), (rd.new_media, rd.duplicate_media, rd.posts, rd.issues.len()),
            "zip and folder imports agree");
        // problem files export unchanged
        let out = d.join("issues.zip");
        let n = tl_core::import::export_issues(std::path::Path::new(rz.report_file.as_ref().unwrap()), &out).unwrap();
        let exportable = rz.issues.iter().filter(|i| !i.category.starts_with("post_") && i.category != "unsafe_path").count();
        prop_assert_eq!(n, exportable);
        let mut z = zip::ZipArchive::new(std::fs::File::open(&out).unwrap()).unwrap();
        for i in rz.issues.iter().filter(|i| !i.category.starts_with("post_") && i.category != "unsafe_path") {
            let name = format!("{}/{}", tl_core::import::category_title(&i.category), i.path);
            let mut got = vec![];
            z.by_name(&name).unwrap().read_to_end(&mut got).unwrap();
            prop_assert_eq!(&got, files.get(&i.path).unwrap(), "{} exported byte for byte", name);
        }
        let _ = std::fs::remove_dir_all(&d);
    }
}

/// The real-world case: a downloader saved HTML error pages as .jpg/.mp4, several identical.
#[test]
fn html_error_pages_are_refused_and_listed() {
    let d = tmp("html");
    let src = d.join("src");
    let page = b"<!DOCTYPE html><html><body>Sorry</body></html>".to_vec();
    for (folder, files) in [("帖子1", vec![("1.jpg", page.clone())]), ("帖子2", vec![("1.mp4", page.clone())]),
                            ("帖子3", vec![("1.jpg", page.clone()), ("2.jpg", bytes(Content::Jpeg(1)))])] {
        std::fs::create_dir_all(src.join(folder)).unwrap();
        for (n, b) in files { std::fs::write(src.join(folder).join(n), b).unwrap(); }
    }
    let lib = Library::open(d.join("lib")).unwrap();
    let r = lib.import_legacy_dir(&src).unwrap();
    assert_eq!(r.new_media, 1, "only the real photo is stored");
    assert_eq!(r.duplicate_media, 0, "error pages are never stored, so never 'duplicates'");
    let not_media: Vec<_> = r.issues.iter().filter(|i| i.category == "not_media").collect();
    assert_eq!(not_media.len(), 3);
    assert!(not_media.iter().all(|i| i.reason.contains("网页")), "{:?}", not_media);
    assert_eq!(r.issues.iter().filter(|i| i.category == "post_not_imported").count(), 2, "帖子1 and 帖子2 had nothing usable");
    assert_eq!(lib.db().stats().unwrap().posts, 1);
    let _ = std::fs::remove_dir_all(&d);
}

/// Media stored before content checks existed are found by verification.
#[test]
fn verification_flags_stored_non_media() {
    let d = tmp("verify");
    let lib = std::sync::Arc::new(Library::open(d.join("lib")).unwrap());
    // bypass the import checks: write an HTML page straight into the blob store as a "photo"
    let page = b"<!DOCTYPE html>error".to_vec();
    let (sha, rel) = lib.put_blob(&page, "jpg").unwrap();
    {
        let db = lib.db();
        db.upsert_post(&tl_core::model::PostMeta { id: "p".into(), ..Default::default() }).unwrap();
        db.add_media(&sha, "p", 0, &tl_core::model::MediaKind::Photo, &rel, false).unwrap();
    }
    assert_eq!(lib.check_file(&sha, &rel), Some("not_media"));
    tl_core::verify::start(lib.clone()).unwrap();
    while tl_core::verify::status().running { std::thread::sleep(std::time::Duration::from_millis(10)); }
    assert_eq!(lib.db().bad_reason(&sha).unwrap().as_deref(), Some("not_media"));
    assert!(lib.db().wanted_blobs(10).unwrap().is_empty(), "not re-fetched from peers (they have the same bytes)");
    let _ = std::fs::remove_dir_all(&d);
}

/// A ZIP of one post whose sidecar sits in the post folder and whose pictures are in a subfolder:
/// the post folder is the post (its subfolder is reported), never descended into as a wrapper;
/// a wrapper folder with a stray readme is still descended.
#[test]
fn a_post_folder_is_never_mistaken_for_a_wrapper() {
    use tl_core::import::plan;
    let e = |p: &str, k: usize| (p.to_string(), false, k);
    let p = plan(&[e("帖子A/推文内容.txt", 0), e("帖子A/images/1.jpg", 1)]);
    assert!(p.root.is_empty());
    assert_eq!(p.posts.keys().collect::<Vec<_>>(), vec!["帖子A"]);
    assert_eq!(p.ignored.len(), 1, "the picture in the subfolder is reported");
    let p = plan(&[e("导出/说明.txt", 0), e("导出/帖子1/a.jpg", 1), e("导出/帖子2/b.jpg", 2)]);
    assert_eq!(p.root, vec!["导出".to_string()]);
    assert_eq!(p.posts.len(), 2);
}
