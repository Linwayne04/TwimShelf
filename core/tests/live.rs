//! Network tests; run with `cargo test -- --ignored`.
use std::sync::Arc;
use tl_core::download::{self, DownloadRequest, Route};
use tl_core::library::{FeedRequest, Library};
use tl_core::model::SearchScope;

#[test]
#[ignore]
fn downloads_public_post_via_fxtwitter() {
    let dir = std::env::temp_dir().join(format!("tl-live-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let lib = Arc::new(Library::open(&dir).unwrap());
    let url = std::env::var("TL_TEST_STATUS_URL").expect("TL_TEST_STATUS_URL");
    download::start(lib.clone(), DownloadRequest { urls: vec![url.clone(), url], concurrency: 2, interval_ms: 200, route: Route::Fx, revive: false, folder: None, mark_recent: false }).unwrap();
    while download::status().running { std::thread::sleep(std::time::Duration::from_millis(100)); }
    let s = download::status();
    assert_eq!(s.failed, 0, "{:?}", s.errors);
    let items = lib.feed(&FeedRequest { terms: vec![], scope: SearchScope::Both, seed: Some(0), fuzzy: true, term_vectors: vec![], embed_model: None, threshold: 0.7, fields: Default::default(), filter: Default::default() }).unwrap();
    assert_eq!(items.len(), 1);
    assert!(items[0].screen_name.as_deref().is_some_and(|name| !name.is_empty()));
    let bytes = std::fs::metadata(&items[0].path).unwrap().len();
    println!("downloaded {} bytes -> {}", bytes, items[0].path);
    assert!(bytes > 10_000);
}

/// The protected-post boundary: the real module is built in, and malformed links are rejected
/// locally without trying the network.
#[test]
fn protected_module_is_available() {
    let c = tl_core::protected::Credentials { auth_token: "a".into(), ct0: "b".into() };
    assert_eq!(format!("{c:?}"), "Credentials { .. }", "secrets never printed");
    assert!(tl_core::protected::available());
    let rt = tl_core::download::runtime();
    let e = rt.block_on(tl_core::protected::fetch_post("not a status link", &c)).unwrap_err();
    assert!(matches!(e, tl_core::protected::ProtectedError::Other(_)), "{e:?}");
    let p = tl_protected_api::ProtectedPost { id: "9".into(), author_name: Some("N".into()), screen_name: Some("n".into()), text: Some("t".into()),
        created_at: None, url: Some("https://x.com/n/status/9".into()),
        media: vec![tl_protected_api::ProtectedMedia { kind: tl_protected_api::MediaKind::Video, url: "https://video.twimg.com/x.mp4".into(), headers: vec![("Referer".into(), "https://x.com/".into())] }] };
    let r = tl_core::protected::to_remote(p);
    assert_eq!((r.meta.id.as_str(), r.media[0].kind.clone(), r.media[0].headers.len()), ("9", tl_core::model::MediaKind::Video, 1));
}
