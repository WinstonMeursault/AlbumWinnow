use super::*;
use crate::{
    Cancellation, review_scan::ScanReviewAsset, scan::ScanSession, scene_session::SceneSession,
};
use std::collections::{BTreeSet, HashSet};

impl ReviewSession {
    pub fn append_scan_assets(
        &mut self,
        operation: &str,
        assets: Vec<ScanReviewAsset>,
        cancellation: &Cancellation,
    ) -> Result<(), CoreError> {
        self.ensure_editable()?;
        cancellation.check()?;
        if assets.len() > crate::scan::MAX_BATCH_SIZE {
            return Err(CoreError::InvalidBuffer);
        }
        let staged = self.staged_scan.as_ref().ok_or(CoreError::InvalidState)?;
        if staged.operation != operation || staged.revision != self.metadata.revision {
            return Err(CoreError::StaleOperation);
        }
        if !staged.groups.is_empty() {
            return Err(CoreError::InvalidState);
        }
        let mut seen = BTreeSet::new();
        for asset in &assets {
            cancellation.check()?;
            asset.validate()?;
            let source = self
                .sources
                .get(&asset.asset.id.source_id)
                .ok_or(CoreError::InvalidValue)?;
            if !source.active
                || source.kind != asset.asset.kind
                || staged.assets.contains_key(&asset.asset.id)
                || !seen.insert(&asset.asset.id)
            {
                return Err(CoreError::InvalidValue);
            }
        }
        let packed = assets
            .into_iter()
            .map(|m| {
                let packed = crate::review_scan::PackedScanReviewAsset::pack(&m)?;
                Ok((m.asset.id, packed))
            })
            .collect::<Result<Vec<_>, CoreError>>()?;
        let staged = self.staged_scan.as_mut().ok_or(CoreError::InvalidState)?;
        staged.assets.extend(packed);
        Ok(())
    }

    /// Consumes completed core detection outputs directly. No host-created
    /// review group or JSON snapshot participates in this production handoff.
    pub fn finish_detected_scan(
        &mut self,
        operation: &str,
        scan: &ScanSession,
        scenes: Option<&SceneSession>,
        cancellation: &Cancellation,
    ) -> Result<(), CoreError> {
        self.ensure_editable()?;
        cancellation.check()?;
        let staged = self.staged_scan.as_ref().ok_or(CoreError::InvalidState)?;
        let sources: HashSet<_> = self
            .sources
            .values()
            .filter(|s| s.active)
            .map(|s| s.id.clone())
            .collect();
        if staged.operation != operation
            || staged.revision != self.metadata.revision
            || scan.operation_id != operation
            || !scan.source_ids.is_subset(&sources)
            || self.settings.sides.as_ref().is_some_and(|s| {
                scan.source_ids != HashSet::from([s.first.clone(), s.second.clone()])
            })
            || scan.sides != self.settings.sides
            || scan.preferred_source != self.settings.preferred_source
            || scenes.is_some() != self.settings.similar_scenes_enabled
        {
            return Err(CoreError::StaleOperation);
        }
        if !staged.groups.is_empty() {
            return Err(CoreError::InvalidState);
        }
        let groups = crate::review_scan::assemble(scan, scenes, &staged.assets, cancellation)?;
        cancellation.check()?;
        let expected = staged.revision;
        self.staged_scan = None;
        self.complete_scan(expected, groups)
    }
}
