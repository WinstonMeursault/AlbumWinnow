use super::*;

#[derive(Clone, Copy, Debug)]
pub enum ReviewPageMode {
    Visible,
    Pending,
    CleanupCandidates,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ReviewOverview {
    pub duplicate_groups: u64,
    pub scene_groups: u64,
    pub visible_groups: u64,
    pub pending_groups: u64,
    pub candidate_groups: u64,
    pub saved_removals: u64,
    pub hidden_saved_removals: u64,
}

impl ReviewSession {
    /// Read-only presentation data. Estimates are never converted into saved
    /// choices or deletion authority; deferred choices count only when saved.
    pub fn presentation_page(
        &mut self,
        mode: ReviewPageMode,
        offset: usize,
        limit: usize,
    ) -> Result<(ReviewOverview, usize, Vec<GroupSummary>), CoreError> {
        self.ensure_healthy()?;
        if limit == 0 || limit > 256 {
            return Err(CoreError::InvalidBuffer);
        }
        let mut overview = ReviewOverview::default();
        let mut candidate_order = Vec::new();
        for stored in self.groups.values().filter(|g| g.active) {
            let summary = self.summary(stored, false);
            if summary.kind == MatchKind::SceneSimilar {
                overview.scene_groups += 1;
            } else {
                overview.duplicate_groups += 1;
            }
            let visible = self.settings.query.includes(&stored.group, summary.status);
            if visible {
                overview.visible_groups += 1;
                if matches!(
                    summary.status,
                    ReviewStatus::Pending | ReviewStatus::Deferred
                ) {
                    overview.pending_groups += 1;
                }
            }
            if summary.saved_removal_count != 0 {
                overview.candidate_groups += 1;
                overview.saved_removals += summary.saved_removal_count;
                if !visible {
                    overview.hidden_saved_removals += summary.saved_removal_count;
                }
                if matches!(mode, ReviewPageMode::CleanupCandidates) {
                    candidate_order.push((stored.ordinal, stored.signature.clone()));
                }
            }
        }
        let order = match mode {
            ReviewPageMode::CleanupCandidates => {
                candidate_order.sort_by_key(|(ordinal, _)| *ordinal);
                candidate_order
                    .into_iter()
                    .map(|(_, signature)| signature)
                    .collect::<Vec<_>>()
            }
            ReviewPageMode::Visible | ReviewPageMode::Pending => {
                self.ordered_query();
                self.query_order
                    .as_ref()
                    .into_iter()
                    .flatten()
                    .filter(|signature| {
                        !matches!(mode, ReviewPageMode::Pending)
                            || self
                                .decisions
                                .get(*signature)
                                .filter(|d| !d.decision.invalidated)
                                .is_none_or(|d| {
                                    matches!(
                                        d.decision.status,
                                        ReviewStatus::Pending | ReviewStatus::Deferred
                                    )
                                })
                    })
                    .cloned()
                    .collect()
            }
        };
        let total = order.len();
        let groups = order
            .into_iter()
            .skip(offset)
            .take(limit)
            .filter_map(|signature| self.groups.get(&signature))
            .map(|stored| self.summary(stored, true))
            .collect();
        Ok((overview, total, groups))
    }

    pub fn lock_owners_page(
        &mut self,
        asset: &ReviewAsset,
        offset: usize,
        limit: usize,
    ) -> Result<Vec<AssetId>, CoreError> {
        self.ensure_healthy()?;
        asset.validate()?;
        if limit == 0 || limit > 256 {
            return Err(CoreError::InvalidBuffer);
        }
        let source = self
            .sources
            .get(&asset.id.source_id)
            .ok_or(CoreError::InvalidValue)?;
        if source.kind != asset.kind {
            return Err(CoreError::InvalidValue);
        }
        Ok(self
            .protection
            .lock_owners(asset)
            .into_iter()
            .skip(offset)
            .take(limit)
            .collect())
    }
}
