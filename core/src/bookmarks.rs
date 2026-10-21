//! Parses the bookmark-export JSON array into downloadable post URLs.
use serde::Deserialize;

#[derive(Debug, Deserialize)]
pub struct BookmarkEntry {
    pub id: String,
    pub url: Option<String>,
    pub screen_name: Option<String>,
}

pub fn parse_urls(json: &str) -> Result<Vec<String>, serde_json::Error> {
    let entries: Vec<BookmarkEntry> = serde_json::from_str(json)?;
    Ok(entries.into_iter().map(|e| e.url.unwrap_or_else(|| {
        format!("https://x.com/{}/status/{}", e.screen_name.as_deref().unwrap_or("i"), e.id)
    })).collect())
}

/// Rewrites a twitter.com / x.com status link to the FxTwitter API endpoint. Accepts the forms
/// the share sheets and mirrors produce: any case, www./mobile./m. hosts, the fx/vx mirrors,
/// `/user/status/ID`, `/user/statuses/ID`, `/i/web/status/ID` and `/i/status/ID`.
pub fn to_fx_api(url: &str) -> Option<String> {
    let rest = url.trim().split("://").nth(1).unwrap_or(url.trim());
    let rest = rest.split(['?', '#']).next()?;
    let mut parts = rest.split('/').filter(|p| !p.is_empty());
    let host = parts.next()?.to_ascii_lowercase();
    let host = host.strip_prefix("www.").or_else(|| host.strip_prefix("mobile.")).or_else(|| host.strip_prefix("m.")).unwrap_or(&host).to_string();
    let known = ["twitter.com", "x.com", "fxtwitter.com", "fixupx.com", "vxtwitter.com", "fixvx.com"];
    if !known.contains(&host.as_str()) { return None; }
    let segs: Vec<&str> = parts.collect();
    let (user, id) = match segs.as_slice() {
        ["i", "web", "status", id, ..] | ["i", "status", id, ..] => ("i", *id),
        [user, s, id, ..] if s.eq_ignore_ascii_case("status") || s.eq_ignore_ascii_case("statuses") => (*user, *id),
        _ => return None,
    };
    if user.is_empty() || !user.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') { return None; }
    let id: String = id.chars().take_while(|c| c.is_ascii_digit()).collect();
    if id.is_empty() || id.len() > 20 { return None; }
    Some(format!("https://api.fxtwitter.com/{user}/status/{id}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn share_sheet_and_mirror_links_are_understood() {
        for (u, want) in [
            ("https://x.com/a_b/status/123?s=20", "a_b/status/123"), ("https://X.COM/a/status/1", "a/status/1"),
            ("https://x.com/i/web/status/99", "i/status/99"), ("https://twitter.com/i/status/7", "i/status/7"),
            ("https://mobile.twitter.com/a/status/5/photo/1", "a/status/5"), ("https://m.twitter.com/a/statuses/6", "a/status/6"),
            ("https://vxtwitter.com/a/status/8", "a/status/8"), ("x.com/a/status/9", "a/status/9"),
        ] { assert_eq!(to_fx_api(u).as_deref(), Some(format!("https://api.fxtwitter.com/{want}").as_str()), "{u}"); }
        for bad in ["https://example.com/a/status/1", "https://x.com/a/likes", "https://x.com/a/status/", "https://x.com/../status/1"] {
            assert_eq!(to_fx_api(bad), None, "{bad}");
        }
    }
    #[test]
    fn sample_file_parses() {
        let j = r#"[{"id":"3104827561938472056","url":"https://twitter.com/UserAlpha102/status/3104827561938472056","screen_name":"UserAlpha102","media":[]}]"#;
        assert_eq!(parse_urls(j).unwrap()[0], "https://twitter.com/UserAlpha102/status/3104827561938472056");
    }
    #[test]
    fn fx_rewrite() {
        assert_eq!(to_fx_api("https://x.com/a/status/123?s=20").unwrap(), "https://api.fxtwitter.com/a/status/123");
        assert!(to_fx_api("https://example.com/a/status/1").is_none());
    }
}
