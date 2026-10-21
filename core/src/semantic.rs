//! Semantic tag matching: tag-label embeddings (computed on device by the embedding model)
//! are stored per model and compared by cosine similarity.
use std::collections::HashMap;

pub fn to_blob(v: &[f32]) -> Vec<u8> { v.iter().flat_map(|x| x.to_le_bytes()).collect() }
pub fn from_blob(b: &[u8]) -> Vec<f32> { b.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect() }

/// Cosine similarity; returns 0 for mismatched or zero vectors.
pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() { return 0.0; }
    let (mut dot, mut na, mut nb) = (0f32, 0f32, 0f32);
    for (x, y) in a.iter().zip(b) { dot += x * y; na += x * x; nb += y * y; }
    if na == 0.0 || nb == 0.0 { 0.0 } else { dot / (na.sqrt() * nb.sqrt()) }
}

/// How far below the best semantic score a label may be and still match. Calibrated on
/// Qwen3-Embedding with an instructed query (see technical report): related tags score ≥ ~0.6,
/// unrelated ones ≤ ~0.55, and a relative band keeps a strong best match from dragging in noise.
pub const RELATIVE_BAND: f32 = 0.10;

/// Labels a search term should match: substring hits (墙 → 白墙) plus labels whose embedding
/// scores at least `threshold` and within `RELATIVE_BAND` of the best-scoring label.
pub fn expand(term: &str, labels: &[String], term_vec: Option<&[f32]>, vectors: &HashMap<String, Vec<f32>>, threshold: f32) -> Vec<String> {
    let t = term.trim().to_lowercase();
    let scores: Vec<f32> = labels.iter().map(|l| term_vec.zip(vectors.get(l)).map_or(f32::MIN, |(q, v)| cosine(q, v))).collect();
    let best = scores.iter().cloned().fold(f32::MIN, f32::max);
    let cutoff = threshold.max(best - RELATIVE_BAND);
    labels.iter().zip(&scores).filter(|(l, &sc)| l.contains(&t) || sc >= cutoff).map(|(l, _)| l.clone()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cosine_basics() {
        assert!((cosine(&[1.0, 0.0], &[1.0, 0.0]) - 1.0).abs() < 1e-6);
        assert!(cosine(&[1.0, 0.0], &[0.0, 1.0]).abs() < 1e-6);
        assert_eq!(cosine(&[1.0], &[1.0, 2.0]), 0.0);
        assert_eq!(from_blob(&to_blob(&[0.5, -2.0])), vec![0.5, -2.0]);
    }
    #[test]
    fn expand_substring_and_vector() {
        let labels: Vec<String> = ["墙", "白墙", "猫", "围墙", "小猫咪"].iter().map(|s| s.to_string()).collect();
        let mut vecs = HashMap::new();
        vecs.insert("小猫咪".to_string(), vec![0.9, 0.1]);
        vecs.insert("猫".to_string(), vec![1.0, 0.0]);
        assert_eq!(expand("墙", &labels, None, &vecs, 0.8), vec!["墙", "白墙", "围墙"]);
        let mut got = expand("猫", &labels, Some(&[1.0, 0.0]), &vecs, 0.8);
        got.sort();
        assert_eq!(got, vec!["小猫咪", "猫"]);
        // A weak best match does not pull in anything below the absolute threshold.
        vecs.insert("围墙".to_string(), vec![0.0, 1.0]);
        assert_eq!(expand("狗", &labels, Some(&[0.6, 0.8]), &vecs, 0.9), Vec::<String>::new());
    }
}
