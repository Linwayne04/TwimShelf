//! Triage mode: one post at a time (a multi-media post always as one group, a loose media on
//! its own); up = keep, left = delete the whole post (to the bin), down = into a folder.
//!
//! What was triaged is stored on this device only (`triage` table) and is never synced — the
//! decisions' *effects* (bin, folders) are ordinary synced edits. A triaged post never comes back
//! (`rules::triage_eligible`) until the history is cleared.
use crate::library::FeedItem;
use crate::store::{Store, LIVE_SQL};
use rusqlite::params;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TriageKind { #[default] All, Posts, Loose }

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TriageMedia { #[default] All, Photo, Video }

/// Which posts to triage. A post qualifies when one of its live media is in any chosen folder
/// (if any are chosen), carries any chosen tag (current names, after renames), and has the chosen
/// media type; `kind` picks posts or loose media.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TriageFilter {
    #[serde(default)] pub folders: Vec<String>,
    #[serde(default)] pub labels: Vec<String>,
    #[serde(default)] pub kind: TriageKind,
    #[serde(default)] pub media: TriageMedia,
    /// Only "最近添加" posts.
    #[serde(default)] pub recent_only: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct TriageUnit { pub post_id: String, pub items: Vec<FeedItem>, pub media_ids: Vec<String> }

#[derive(Debug, Clone, Serialize)]
pub struct TriageCounts { pub remaining: usize, pub triaged: i64 }

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Decision { Keep, Delete, Folder }

impl Store {
    /// Post ids still to triage under `f` (ordered).
    fn triage_posts(&self, f: &TriageFilter) -> rusqlite::Result<Vec<String>> {
        let mut sql = format!("SELECT DISTINCT m.post_id FROM media m WHERE {LIVE_SQL} AND m.post_id NOT IN (SELECT post_id FROM triage)");
        let mut args: Vec<String> = vec![];
        match f.kind { TriageKind::All => {}, TriageKind::Posts => sql += " AND m.post_id NOT LIKE 'loose:%'", TriageKind::Loose => sql += " AND m.post_id LIKE 'loose:%'" }
        match f.media { TriageMedia::All => {}, TriageMedia::Photo => sql += " AND m.kind='photo'", TriageMedia::Video => sql += " AND m.kind='video'" }
        if !f.folders.is_empty() {
            let ph: Vec<String> = f.folders.iter().map(|x| { args.push(x.trim().to_string()); format!("?{}", args.len()) }).collect();
            sql += &format!(" AND EXISTS(SELECT 1 FROM folder_media fm JOIN folder fo ON fo.name=fm.folder WHERE fm.media_id=m.id AND fm.present=1 AND fo.deleted=0 AND fm.folder IN ({}))", ph.join(","));
        }
        if !f.labels.is_empty() {
            let mut ph = vec![];
            for l in &f.labels { args.push(self.canonical(l)?); ph.push(format!("?{}", args.len())); }
            sql += &format!(" AND EXISTS(SELECT 1 FROM tag_media tm JOIN tag_c t ON t.raw_id=tm.tag_id WHERE tm.media_id=m.id AND tm.origin!=0 AND t.label IN ({}))", ph.join(","));
        }
        sql += " ORDER BY m.post_id";
        let mut posts: Vec<String> = {
            let mut st = self.conn().prepare(&sql)?;
            let v = st.query_map(rusqlite::params_from_iter(args.iter()), |r| r.get(0))?.collect::<Result<_, _>>()?;
            v
        };
        if f.recent_only {
            let recent = self.recent_posts(crate::store::now_ms())?;
            posts.retain(|p| recent.contains(p));
        }
        Ok(posts)
    }

    /// Posts still to triage under `f`, each with all its live media (paths relative).
    /// One pass over the media (a query per post made a 1,000-post library hang the app).
    pub fn triage_queue(&self, f: &TriageFilter) -> rusqlite::Result<Vec<TriageUnit>> {
        let posts = self.triage_posts(f)?;
        if posts.is_empty() { return Ok(vec![]); }
        let wanted: std::collections::HashSet<&str> = posts.iter().map(String::as_str).collect();
        let items = self.query_items(&format!("SELECT m.id, m.post_id, m.ordinal, m.kind, m.path, p.text, p.author_name, p.screen_name, p.url, p.created_at FROM media m JOIN post p ON p.id=m.post_id WHERE {LIVE_SQL} AND m.post_id NOT IN (SELECT post_id FROM triage) ORDER BY m.post_id, m.ordinal"), &[])?;
        let mut by: std::collections::HashMap<String, Vec<FeedItem>> = std::collections::HashMap::with_capacity(posts.len());
        for it in items { if wanted.contains(it.post_id.as_str()) { by.entry(it.post_id.clone()).or_default().push(it); } }
        let mut pending: std::collections::HashMap<String, Vec<String>> = std::collections::HashMap::new();
        let mut st = self.conn().prepare("SELECT DISTINCT c.post_id, w.media_id FROM want_blob w JOIN media_claim c ON c.media_id=w.media_id WHERE NOT EXISTS(SELECT 1 FROM trash t WHERE t.media_id=w.media_id AND t.state>0)")?;
        for row in st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? { let (p, id) = row?; pending.entry(p).or_default().push(id); }
        Ok(posts.into_iter().filter_map(|p| {
            let items = by.remove(&p)?;
            let mut ids: std::collections::BTreeSet<String> = items.iter().map(|i| i.media_id.clone()).collect();
            ids.extend(pending.remove(&p).unwrap_or_default());
            Some(TriageUnit { post_id: p, items, media_ids: ids.into_iter().collect() })
        }).collect())
    }

    pub fn triage_counts(&self, f: &TriageFilter) -> rusqlite::Result<TriageCounts> {
        Ok(TriageCounts { remaining: self.triage_posts(f)?.len(), triaged: self.conn().query_row("SELECT count(*) FROM triage", [], |r| r.get(0))? })
    }

    pub fn is_triaged(&self, post_id: &str) -> rusqlite::Result<bool> {
        self.conn().prepare_cached("SELECT 1 FROM triage WHERE post_id=?1")?.exists([post_id])
    }

    /// Records a decision for a whole post and applies its effect (callers wrap in a
    /// transaction). Returns false when the post was already triaged or has no live media.
    pub fn triage_decide(&self, post_id: &str, d: Decision, folder: Option<&str>) -> rusqlite::Result<bool> { self.atomic(|| {
        let live = self.live_media_of_post(post_id)?;
        if !crate::rules::triage_eligible(live.len(), self.is_triaged(post_id)?, true) { return Ok(false); }
        // The decision is about the whole post: media of it that another device has recorded but
        // whose file has not arrived yet are decided with it (as when a post is deleted in the
        // timeline), or they would show up later as a "new" part of a post that was already dealt with.
        let awaited = self.pending_media_of_post(post_id)?;
        let mut moved: Vec<String> = vec![];
        let mut fname: Option<String> = None;
        match d {
            Decision::Keep => {}
            Decision::Delete => {
                // exactly the media this decision binned (undo restores those and nothing else)
                for m in live.iter().chain(&awaited) { if self.trash_action(m, crate::rules::TrashAction::Trash)? { moved.push(m.clone()); } }
            }
            Decision::Folder => {
                let name = self.create_folder(folder.unwrap_or(""))?;
                if name.is_empty() { return Ok(false); }
                for m in live.iter().chain(&awaited) { if self.add_to_folder(&name, &[m.clone()])? > 0 { moved.push(m.clone()); } }
                fname = Some(name);
            }
        }
        let dec = match d { Decision::Keep => "keep", Decision::Delete => "delete", Decision::Folder => "folder" };
        // with each media, the clock of the change this decision made: undo reverts exactly that
        // change, and nothing that happened to the media since (a restore and a new deletion
        // elsewhere, the user adding it to the folder by hand later)
        let mut stamped: Vec<Moved> = vec![];
        for m in moved {
            let hlc = match (d, fname.as_deref()) {
                (Decision::Delete, _) => self.trash_reg(&m)?.hlc,
                (Decision::Folder, Some(f)) => self.member_reg(f, &m)?.map_or(0, |r| r.hlc),
                _ => 0,
            };
            stamped.push(Moved { id: m, hlc });
        }
        self.conn().execute("INSERT INTO triage VALUES(?1,?2,?3,?4,unixepoch())",
            params![post_id, dec, fname, serde_json::to_string(&stamped).unwrap()])?;
        Ok(true)
    }) }

    /// Undoes a post's decision: it is offered again; a delete restores the media it binned that
    /// are still in the bin (rules::triage_undo_restores), a folder decision takes out the media
    /// it put in. Returns false when the post was not triaged.
    pub fn triage_undo(&self, post_id: &str) -> rusqlite::Result<bool> { self.atomic(|| {
        use rusqlite::OptionalExtension;
        let row: Option<(String, Option<String>, String)> = self.conn().query_row(
            "SELECT decision, folder, moved FROM triage WHERE post_id=?1", [post_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).optional()?;
        let Some((dec, folder, moved)) = row else { return Ok(false) };
        // older records list ids only (no clock): those are undone as before
        let moved: Vec<Moved> = serde_json::from_str(&moved).unwrap_or_else(|_|
            serde_json::from_str::<Vec<String>>(&moved).unwrap_or_default().into_iter().map(|id| Moved { id, hlc: 0 }).collect());
        let same = |now: u64, then: u64| then == 0 || now == then;
        match dec.as_str() {
            "delete" => for m in &moved {
                let r = self.trash_reg(&m.id)?;
                if crate::rules::triage_undo_restores(true, r.state) && same(r.hlc, m.hlc) { self.trash_action(&m.id, crate::rules::TrashAction::Restore)?; }
            },
            "folder" => if let Some(f) = folder {
                let ours: Vec<String> = moved.iter().filter(|m| self.member_reg(&f, &m.id).ok().flatten().map_or(false, |r| r.origin == 1 && same(r.hlc, m.hlc)))
                    .map(|m| m.id.clone()).collect();
                self.remove_from_folder(&f, &ours)?;
            },
            _ => {}
        }
        self.conn().execute("DELETE FROM triage WHERE post_id=?1", [post_id])?;
        Ok(true)
    }) }

    /// Forgets every triage decision on this device (effects stay: the bin, folders).
    pub fn triage_clear(&self) -> rusqlite::Result<usize> { self.conn().execute("DELETE FROM triage", []) }
}

/// A media a triage decision changed, with the clock of that change.
#[derive(serde::Serialize, serde::Deserialize)]
struct Moved { id: String, hlc: u64 }
