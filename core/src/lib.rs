//! TwimShelf core: data model, persistence and ingest parsing.
pub mod model;
pub mod crdt;
pub mod rules;
pub mod oplog;
pub mod sync;
pub mod bookmarks;
pub mod legacy;
pub mod store;
pub mod library;
pub mod actions;
pub mod net;
pub mod download;
pub mod archive;
pub mod models;
pub mod semantic;
pub mod verify;
pub mod import;
pub mod triage;
/// Specification of tagging and sync, checked by tests and Kani proofs.
pub mod tagmodel;
pub mod diagnostics;
pub mod protected;
pub mod ffi;

/// Test fixtures: a tiny file with a real JPEG signature (imports check content, not extensions).
#[cfg(test)]
pub mod testutil {
    pub fn jpg(b: &[u8]) -> Vec<u8> { let mut v = vec![0xFF, 0xD8, 0xFF, 0xE0]; v.extend_from_slice(b); v }
}
