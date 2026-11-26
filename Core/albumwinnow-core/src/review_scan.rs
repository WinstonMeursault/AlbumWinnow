//! Direct detection-to-review handoff. Native hosts supply bounded metadata,
//! never round-trip detected groups back as review authority.
use crate::{
    Cancellation, CoreError,
    matching::MatchKind,
    model::AssetId,
    review::{RecommendationReason, ReviewAsset, ReviewEvidence, ReviewGroup},
    scan::{ScanItem, ScanSession},
    scene_session::{Recommendation, SceneSession},
    signature::SignatureEdge,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ScanReviewAsset {
    pub asset: ReviewAsset,
    pub evidence: ReviewEvidence,
}
impl ScanReviewAsset {
    pub fn validate(&self) -> Result<(), CoreError> {
        self.asset.validate()?;
        self.evidence.validate()?;
        if self.asset.id != self.evidence.asset {
            return Err(CoreError::InvalidValue);
        }
        Ok(())
    }
    fn matches(&self, item: &ScanItem) -> bool {
        self.asset.id == item.id
            && self.asset.revision == item.revision
            && self.asset.native_identity == item.native_identity
            && self.asset.associated_resources() == item.associated_resources
            && self.evidence.width == item.fingerprint.width
            && self.evidence.height == item.fingerprint.height
            && self
                .evidence
                .bit_depth
                .is_none_or(|v| v == item.fingerprint.bit_depth)
            && self.evidence.wide_color == item.fingerprint.wide_color
            && self.evidence.edge_detail == Some(item.fingerprint.metrics.edge_detail)
    }
}

// Staging holds metadata for every scanned asset until the native validations
// finish. Pack it to avoid retaining duplicate identity strings and many small
// allocations alongside the detection session. This is never a wire/store format.
pub(crate) struct PackedScanReviewAsset(Box<[u8]>);
impl PackedScanReviewAsset {
    // Includes worst-case JSON escaping of every bounded metadata string.
    const MAX_BYTES: usize = 2 * 1024 * 1024;

    pub(crate) fn pack(value: &ScanReviewAsset) -> Result<Self, CoreError> {
        let bytes = serde_json::to_vec(value).map_err(|_| CoreError::InvalidValue)?;
        if bytes.len() > Self::MAX_BYTES {
            return Err(CoreError::InvalidBuffer);
        }
        Ok(Self(
            lz4_flex::compress_prepend_size(&bytes).into_boxed_slice(),
        ))
    }

    fn unpack(&self) -> Result<ScanReviewAsset, CoreError> {
        let size = self.0.get(..4).ok_or(CoreError::InvalidBuffer)?;
        let size = u32::from_le_bytes(size.try_into().map_err(|_| CoreError::InvalidBuffer)?);
        if size as usize > Self::MAX_BYTES {
            return Err(CoreError::InvalidBuffer);
        }
        let bytes =
            lz4_flex::decompress_size_prepended(&self.0).map_err(|_| CoreError::InvalidBuffer)?;
        serde_json::from_slice(&bytes).map_err(|_| CoreError::InvalidValue)
    }
}

pub(crate) fn assemble(
    scan: &ScanSession,
    scenes: Option<&SceneSession>,
    metadata: &BTreeMap<AssetId, PackedScanReviewAsset>,
    cancel: &Cancellation,
) -> Result<Vec<ReviewGroup>, CoreError> {
    let detected = scan.groups(cancel)?;
    let items = scan.review_items()?;
    if metadata.len() != items.len() {
        return Err(CoreError::InvalidValue);
    }
    for item in items {
        cancel.check()?;
        let m = metadata
            .get(&item.id)
            .ok_or(CoreError::StaleOperation)?
            .unpack()?;
        if !m.matches(item) {
            return Err(CoreError::StaleOperation);
        }
    }
    let mut used = HashSet::new();
    let mut result = Vec::with_capacity(detected.len());
    for detected in detected {
        cancel.check()?;
        let ids = std::iter::once(&detected.preferred)
            .chain(detected.duplicates.iter().map(|(id, _)| id));
        let members = ids
            .map(|id| metadata[id].unpack())
            .collect::<Result<Vec<_>, _>>()?;
        used.extend(members.iter().map(|m| m.asset.id.clone()));
        result.push(ReviewGroup {
            preferred: detected.preferred,
            members: members.iter().map(|m| m.asset.clone()).collect(),
            duplicates: detected.duplicates,
            edges: detected.edges.map(|edges| {
                edges
                    .into_iter()
                    .map(|e| SignatureEdge {
                        first: e.first,
                        second: e.second,
                        kind: e.kind,
                    })
                    .collect()
            }),
            sides: scan.sides.clone(),
            scene: None,
            recommendation: detected.recommended,
            has_quality_recommendation: true,
            scene_recommendation_reason: None,
            scene_quality: vec![],
            scene_matches: vec![],
            evidence: members.into_iter().map(|m| m.evidence).collect(),
        });
    }
    if let Some(scenes) = scenes {
        scenes.validate_for_review()?;
        let depths: BTreeMap<_, _> = items
            .iter()
            .map(|i| (&i.id, i.fingerprint.bit_depth))
            .collect();
        let sides = scan
            .sides
            .as_ref()
            .map(|s| (s.first.clone(), s.second.clone()));
        if scenes.operation != scan.operation_id
            || scenes.sides != sides
            || scenes.preferred_source != scan.preferred_source
        {
            return Err(CoreError::StaleOperation);
        }
        let groups = scenes.groups()?;
        let mut scene_items = BTreeMap::new();
        for item in &scenes.items {
            cancel.check()?;
            let m = metadata
                .get(&item.id)
                .ok_or(CoreError::InvalidValue)?
                .unpack()?;
            if used.contains(&item.id)
                || item.revision != m.asset.revision
                || item.native_identity != m.asset.native_identity
                || item.associated_resources != m.asset.associated_resources()
                || item.width != m.evidence.width
                || item.height != m.evidence.height
                || depths.get(&item.id) != Some(&item.bit_depth)
                || item.wide_color != m.evidence.wide_color
                || Some(item.edge_detail) != m.evidence.edge_detail
                || item.burst != m.asset.burst
                || item.date != m.asset.capture_date.or(m.evidence.capture_date)
            {
                return Err(CoreError::StaleOperation);
            }
            scene_items.insert(&item.id, item);
        }
        for detected in groups {
            cancel.check()?;
            let preferred = detected
                .members
                .first()
                .ok_or(CoreError::InvalidValue)?
                .clone();
            let mut members = Vec::with_capacity(detected.members.len());
            let mut evidence = Vec::with_capacity(detected.members.len());
            let mut quality = Vec::with_capacity(detected.members.len());
            for id in &detected.members {
                if !used.insert(id.clone()) {
                    return Err(CoreError::InvalidValue);
                }
                let m = metadata.get(id).ok_or(CoreError::InvalidValue)?.unpack()?;
                let item = scene_items.get(id).ok_or(CoreError::InvalidValue)?;
                members.push(m.asset.clone());
                evidence.push(m.evidence.clone());
                quality.push((id.clone(), item.quality));
            }
            let edges: Vec<_> = detected
                .edges
                .iter()
                .map(|e| SignatureEdge {
                    first: e.first.clone(),
                    second: e.second.clone(),
                    kind: MatchKind::SceneSimilar,
                })
                .collect();
            let duplicates = detected
                .members
                .into_iter()
                .skip(1)
                .map(|id| {
                    let matches = edges.iter().any(|e| {
                        (e.first == preferred && e.second == id)
                            || (e.second == preferred && e.first == id)
                    });
                    (
                        id,
                        if matches {
                            MatchKind::SceneSimilar
                        } else {
                            MatchKind::Distinct
                        },
                    )
                })
                .collect();
            let has_quality_recommendation = detected.recommended.is_some();
            result.push(ReviewGroup {
                preferred,
                members,
                duplicates,
                edges: Some(edges),
                sides: scan.sides.clone(),
                scene: Some(scenes.provider.clone()),
                recommendation: detected.recommended,
                has_quality_recommendation,
                scene_recommendation_reason: detected.reason.map(|r| match r {
                    Recommendation::AssociatedResources => {
                        RecommendationReason::AssociatedResources
                    }
                    Recommendation::FocusSignal => RecommendationReason::FocusSignal,
                    Recommendation::ExposureSignal => RecommendationReason::ExposureSignal,
                    Recommendation::SourcePreference => RecommendationReason::SourcePreference,
                }),
                scene_quality: quality,
                scene_matches: detected.edges,
                evidence,
            });
        }
    }
    for group in &result {
        cancel.check()?;
        group.validate()?;
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::review::SourceKind;

    #[test]
    fn packed_metadata_preserves_bounded_strings_and_float_bits() {
        let id = AssetId {
            source_id: "\u{1}".repeat(4096),
            item_id: "\u{2}".repeat(65536),
        };
        let value = ScanReviewAsset {
            asset: ReviewAsset {
                id: id.clone(),
                name: "\u{3}".repeat(16384),
                revision: "\u{4}".repeat(8192),
                kind: SourceKind::FileSystem,
                properties: Some(7),
                byte_count: Some(i64::MAX as u64),
                capture_date: Some(-0.0),
                burst: Some("\u{5}".repeat(8192)),
                native_identity: Some("\u{6}".repeat(4096)),
                link_count: Some(u64::MAX),
            },
            evidence: ReviewEvidence {
                asset: id,
                width: 100,
                height: 100,
                bit_depth: Some(64),
                wide_color: true,
                edge_detail: Some(f64::from_bits(0x3fb999999999999b)),
                capture_date: Some(f64::from_bits(0x41d954fc40000001)),
            },
        };
        value.validate().unwrap();
        let decoded = PackedScanReviewAsset::pack(&value)
            .unwrap()
            .unpack()
            .unwrap();
        assert_eq!(decoded.asset, value.asset);
        assert_eq!(decoded.evidence, value.evidence);
        assert_eq!(
            decoded.asset.capture_date.unwrap().to_bits(),
            (-0.0_f64).to_bits()
        );
        assert_eq!(
            decoded.evidence.edge_detail.unwrap().to_bits(),
            value.evidence.edge_detail.unwrap().to_bits()
        );
        assert_eq!(
            decoded.evidence.capture_date.unwrap().to_bits(),
            value.evidence.capture_date.unwrap().to_bits()
        );
    }

    #[test]
    fn packed_metadata_rejects_invalid_length_and_payload() {
        for bytes in [vec![], u32::MAX.to_le_bytes().to_vec(), vec![1, 0, 0, 0]] {
            assert!(
                PackedScanReviewAsset(bytes.into_boxed_slice())
                    .unpack()
                    .is_err()
            );
        }
    }
}
