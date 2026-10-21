//! Manual check against a real archive (counts only, nothing printed about content):
//! TL_ZIP=/path/to.zip TL_LIB=/tmp/dir cargo test --release --test real_zip -- --ignored --nocapture
#[test]
#[ignore]
fn import_real_zip_counts_only() {
    let zip = std::env::var("TL_ZIP").unwrap();
    let dir = std::env::var("TL_LIB").unwrap();
    let lib = tl_core::library::Library::open(&dir).unwrap();
    let r = tl_core::archive::import_legacy_zip(&lib, std::path::Path::new(&zip)).unwrap();
    let mut cats = std::collections::BTreeMap::<String, usize>::new();
    for i in &r.issues { *cats.entry(i.category.clone()).or_default() += 1; }
    let st = lib.db().stats().unwrap();
    println!("entries={} system={} sidecars={} folders={} posts_imported={} new_media={} duplicates={} merged={} hidden={}",
        r.entries, r.system_files, r.sidecars, r.folders, r.posts, r.new_media, r.duplicate_media, r.merged_posts, r.posts_without_media);
    println!("issues_by_category={cats:?}");
    let reasons: std::collections::BTreeSet<String> = r.issues.iter().filter(|i| i.category == "not_media").map(|i| i.reason.clone()).collect();
    println!("not_media_reasons={reasons:?}");
    println!("library: posts={} photos={} videos={}", st.posts, st.photos, st.videos);
}
