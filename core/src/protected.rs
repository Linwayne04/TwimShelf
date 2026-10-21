//! Posts the public mirror cannot reach (protected accounts): fetched by the module `tl-protected`
//! with the user's session cookies, through the types of `tl-protected-api`. The module is
//! compiled into this library and called directly (on a blocking worker thread).
use crate::model::{MediaKind, PostMeta};
use crate::net::{RemoteMedia, RemotePost};
pub use tl_protected_api::{Credentials, ProtectedError};

/// Converts the module's post into the core's.
pub fn to_remote(p: tl_protected_api::ProtectedPost) -> RemotePost {
    RemotePost {
        meta: PostMeta { id: p.id, author_name: p.author_name, screen_name: p.screen_name, text: p.text, created_at: p.created_at, url: p.url },
        media: p.media.into_iter().map(|m| RemoteMedia {
            kind: match m.kind { tl_protected_api::MediaKind::Photo => MediaKind::Photo, tl_protected_api::MediaKind::Video => MediaKind::Video },
            url: m.url, headers: m.headers,
        }).collect(),
    }
}

/// Fetches a post through the module (off the async runtime's threads).
pub async fn fetch_post(url: &str, creds: &Credentials) -> Result<RemotePost, ProtectedError> {
    let (u, c) = (url.to_string(), creds.clone());
    match tokio::task::spawn_blocking(move || tl_protected::fetch_post(&u, &c)).await {
        Ok(r) => r.map(to_remote),
        Err(e) => Err(ProtectedError::Other(format!("锁定账号模块异常退出：{e}"))),
    }
}

/// Checks the cookies (Settings → 检查 Cookie).
pub fn check(creds: &Credentials) -> Result<tl_protected_api::Account, ProtectedError> { tl_protected::check_credentials(creds) }

/// Whether the real module is built in (the placeholder answers NotAvailable).
pub fn available() -> bool {
    !matches!(tl_protected::check_credentials(&Credentials { auth_token: String::new(), ct0: String::new() }), Err(ProtectedError::NotAvailable))
}
