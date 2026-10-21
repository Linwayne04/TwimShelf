//! The boundary between TwimShelf's core (`tl-core`) and the module that fetches posts
//! the public mirror cannot reach (protected accounts, with the user's session cookies).
//!
//! The module is the crate `tl-protected` (folder `core/protected`). It is compiled into the
//! core — one binary, plain function calls, no extra process (iOS forbids spawning processes) —
//! and must provide exactly:
//!
//! ```ignore
//! pub fn fetch_post(status_url: &str, credentials: &Credentials) -> Result<ProtectedPost, ProtectedError>;
//! pub fn check_credentials(credentials: &Credentials) -> Result<Account, ProtectedError>;
//! ```
//!
//! Both are blocking. The core calls them from its worker threads (`tokio::task::spawn_blocking`),
//! possibly several at once, so they must be thread-safe and must not need a Tokio runtime of their
//! own on the calling thread. See `docs/protected-module-interface.md` for the full contract.
#![forbid(unsafe_code)]

/// The user's X session, as entered in Settings (never logged, never sent anywhere but x.com).
#[derive(Clone, PartialEq, Eq)]
pub struct Credentials {
    /// `auth_token` cookie.
    pub auth_token: String,
    /// `ct0` cookie (also the CSRF token).
    pub ct0: String,
}

impl std::fmt::Debug for Credentials {
    // never print the secrets
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str("Credentials { .. }") }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaKind { Photo, Video }

/// One photo or video of the post, in the post's order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProtectedMedia {
    pub kind: MediaKind,
    /// Direct URL of the best quality: the original photo (`…?name=orig`), the highest-bitrate
    /// MP4 for videos and GIFs (never an HLS playlist).
    pub url: String,
    /// Extra HTTP headers the core must send to download `url` (usually none: the media CDN
    /// is public). Never put the cookies here unless the download really requires them.
    pub headers: Vec<(String, String)>,
}

/// A post. Text is the full text with trailing media links (`https://t.co/…` of the media)
/// removed; times are UTC.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProtectedPost {
    /// Numeric status id ("1700000000000000001").
    pub id: String,
    pub author_name: Option<String>,
    /// Without "@".
    pub screen_name: Option<String>,
    pub text: Option<String>,
    /// "YYYY-MM-DD HH:MM:SS +0000".
    pub created_at: Option<String>,
    /// Canonical link: "https://x.com/<screen_name>/status/<id>".
    pub url: Option<String>,
    pub media: Vec<ProtectedMedia>,
}

/// The signed-in account (for "检查 Cookie" in Settings).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Account { pub screen_name: String, pub name: Option<String> }

/// Why a fetch failed. The message is shown to the user (Chinese preferred) and written to the
/// app's problem log, so it must never contain the cookies.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProtectedError {
    /// The module is not built in yet (the placeholder returns this).
    NotAvailable,
    /// The cookies are missing, expired or rejected (HTTP 401/403 for the session).
    Unauthorized(String),
    /// The post does not exist, was deleted, or the account cannot see it.
    NotFound(String),
    /// Rate limited; retry after this many seconds if known.
    RateLimited { retry_after_secs: Option<u64> },
    /// The post exists but has no photo or video.
    NoMedia,
    /// Network or timeout (the core retries these).
    Network(String),
    /// Anything else (e.g. the response format changed).
    Other(String),
}

impl std::fmt::Display for ProtectedError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotAvailable => f.write_str("锁定账号下载模块尚未接入"),
            Self::Unauthorized(m) => write!(f, "Cookie 无效或已过期：{m}"),
            Self::NotFound(m) => write!(f, "帖子不存在或无权查看：{m}"),
            Self::RateLimited { retry_after_secs: Some(s) } => write!(f, "请求过于频繁，请 {s} 秒后再试"),
            Self::RateLimited { retry_after_secs: None } => f.write_str("请求过于频繁，请稍后再试"),
            Self::NoMedia => f.write_str("帖子没有图片或视频"),
            Self::Network(m) => write!(f, "网络错误：{m}"),
            Self::Other(m) => f.write_str(m),
        }
    }
}
impl std::error::Error for ProtectedError {}
