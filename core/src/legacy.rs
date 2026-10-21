//! Parser for the legacy `推文内容.txt` sidecar written by the old scripts.
use crate::model::PostMeta;

pub const SIDECAR_NAME: &str = "推文内容.txt";
const BODY_MARKER: &str = "【推文完整正文】";

pub fn parse_sidecar(txt: &str) -> PostMeta {
    // files saved by Windows Notepad start with a byte-order mark: it would hide the first key
    let txt = txt.strip_prefix('\u{feff}').unwrap_or(txt);
    let mut m = PostMeta::default();
    let (head, body) = match txt.split_once(BODY_MARKER) {
        Some((h, b)) => (h, Some(b.trim().to_string())),
        None => (txt, None),
    };
    for line in head.lines() {
        let Some((k, v)) = line.split_once(':').or_else(|| line.split_once('：')) else { continue };
        let v = v.trim();
        if v.is_empty() { continue; }   // an empty value is no value
        match k.trim() {
            "作者" => {
                if let Some((name, rest)) = v.rsplit_once(" (@") {
                    m.author_name = Some(name.to_string());
                    m.screen_name = Some(rest.trim_end_matches(')').to_string());
                } else { m.author_name = Some(v.to_string()); }
            }
            "推文 ID" => m.id = v.to_string(),
            "发布时间" => m.created_at = Some(v.to_string()),
            "原帖链接" => m.url = Some(v.to_string()),
            _ => {}
        }
    }
    m.text = body.filter(|b| !b.is_empty());
    m
}

/// A folder without a sidecar (batch 1): the folder name is the post text.
pub fn meta_from_folder_name(name: &str) -> PostMeta {
    PostMeta { id: format!("legacy:{name}"), text: Some(name.to_string()), ..Default::default() }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_user_sample() {
        let t = "作者: Example Author (@example_user)\n推文 ID: 1700000000000000001\n发布时间: Fri Oct 24 08:13:11 +0000 2025\n原帖链接: https://x.com/example_user/status/1700000000000000001\nFxTwitter 链接: https://fxtwitter.com/example_user/status/1700000000000000001\n媒体数量: 1\n----------------------------------------\n【推文完整正文】\n#Example\n";
        let m = parse_sidecar(t);
        assert_eq!(m.author_name.as_deref(), Some("Example Author"));
        assert_eq!(m.screen_name.as_deref(), Some("example_user"));
        assert_eq!(m.id, "1700000000000000001");
        assert_eq!(m.url.as_deref(), Some("https://x.com/example_user/status/1700000000000000001"));
        assert_eq!(m.text.as_deref(), Some("#Example"));
    }
}
