use crate::{
    model::AssetId,
    review::{ProtectionState, RecommendationReason, ReviewDecision, ReviewGroup, ReviewStatus},
};
use std::collections::{BTreeSet, HashMap};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SizeEstimate {
    pub known_bytes: u64,
    pub known_count: u64,
    pub unknown_count: u64,
    pub overflowed: bool,
}
impl SizeEstimate {
    pub fn has_known_amount(&self) -> bool {
        self.known_count > 0 || self.unknown_count == 0
    }
    fn add(&mut self, bytes: Option<u64>) {
        if let Some(bytes) = bytes {
            self.known_count += 1;
            let total = self.known_bytes.saturating_add(bytes);
            self.overflowed |= total > i64::MAX as u64;
            self.known_bytes = total.min(i64::MAX as u64);
        } else {
            self.unknown_count += 1;
        }
    }
}
impl ReviewGroup {
    pub fn size_estimate(&self, removals: &BTreeSet<AssetId>) -> SizeEstimate {
        let mut result = SizeEstimate::default();
        for asset in &self.members {
            if removals.contains(&asset.id) {
                result.add(asset.byte_count);
            }
        }
        result
    }

    /// An estimate is display information, never authority to remove resources.
    pub fn estimated_removals(
        &self,
        decision: Option<&ReviewDecision>,
        protection: &ProtectionState,
    ) -> BTreeSet<AssetId> {
        if let Some(decision) = decision.filter(|d| !d.invalidated) {
            if decision.status == ReviewStatus::Kept {
                return BTreeSet::new();
            }
            if decision.delete_all {
                return self
                    .members
                    .iter()
                    .filter(|asset| {
                        decision.removals.contains(&asset.id) && !protection.protected(asset)
                    })
                    .map(|asset| asset.id.clone())
                    .collect();
            }
            if let Some(keep) = &decision.keep {
                return self
                    .removal_pairs(keep, protection)
                    .into_iter()
                    .map(|(_, remove)| remove)
                    .filter(|id| decision.removals.contains(id))
                    .collect();
            }
        }
        if !self.has_quality_recommendation {
            return BTreeSet::new();
        }
        self.removal_pairs(self.recommendation_id(), protection)
            .into_iter()
            .map(|(_, remove)| remove)
            .collect()
    }

    pub fn recommendation_reasons(&self) -> Vec<RecommendationReason> {
        use RecommendationReason::*;
        if self.scene.is_some() {
            return vec![
                self.scene_recommendation_reason
                    .unwrap_or(NoQualityAdvantage),
            ];
        }
        let preferred = self
            .members
            .iter()
            .find(|a| a.id == *self.recommendation_id());
        let Some(preferred) = preferred else {
            return vec![NoQualityAdvantage];
        };
        let others: Vec<_> = self
            .members
            .iter()
            .filter(|a| a.id != preferred.id)
            .collect();
        let mut reasons = if self.recommendation.is_some() {
            vec![SourcePreference]
        } else {
            vec![]
        };
        if preferred.associated_resources() && others.iter().any(|a| !a.associated_resources()) {
            reasons.push(AssociatedResources);
        }
        let evidence: HashMap<_, _> = self.evidence.iter().map(|e| (&e.asset, e)).collect();
        if let Some(selected) = evidence.get(&preferred.id) {
            let compared: Vec<_> = others.iter().filter_map(|a| evidence.get(&a.id)).collect();
            let area = u64::from(selected.width) * u64::from(selected.height);
            let area_of =
                |e: &&&crate::review::ReviewEvidence| u64::from(e.width) * u64::from(e.height);
            if !compared.is_empty()
                && compared.iter().all(|e| area_of(e) <= area)
                && compared.iter().any(|e| area_of(e) < area)
            {
                reasons.push(HigherResolution);
            }
            let depths: Vec<_> = compared.iter().filter_map(|e| e.bit_depth).collect();
            if let Some(depth) = selected.bit_depth
                && !depths.is_empty()
                && depths.iter().all(|d| *d <= depth)
                && depths.iter().any(|d| *d < depth)
            {
                reasons.push(HigherBitDepth);
            }
            if selected.wide_color && compared.iter().any(|e| !e.wide_color) {
                reasons.push(WideColor);
            }
            if reasons.is_empty()
                && let Some(contrast) = selected.edge_detail
                && !compared.is_empty()
                && compared
                    .iter()
                    .all(|e| e.edge_detail.is_some_and(|v| v < contrast))
            {
                reasons.push(EdgeContrast);
            }
        }
        if reasons.is_empty() {
            vec![NoQualityAdvantage]
        } else {
            reasons
        }
    }
}
