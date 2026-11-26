use super::*;
use albumwinnow_core::review_session::{ReviewOverview, ReviewPageMode};

#[derive(uniffi::Enum)]
pub enum CoreReviewPageMode {
    Visible,
    Pending,
    CleanupCandidates,
}
impl From<CoreReviewPageMode> for ReviewPageMode {
    fn from(value: CoreReviewPageMode) -> Self {
        match value {
            CoreReviewPageMode::Visible => Self::Visible,
            CoreReviewPageMode::Pending => Self::Pending,
            CoreReviewPageMode::CleanupCandidates => Self::CleanupCandidates,
        }
    }
}
#[derive(uniffi::Record)]
pub struct CoreReviewOverview {
    pub duplicate_groups: u64,
    pub scene_groups: u64,
    pub visible_groups: u64,
    pub pending_groups: u64,
    pub candidate_groups: u64,
    pub saved_removals: u64,
    pub hidden_saved_removals: u64,
}
impl From<ReviewOverview> for CoreReviewOverview {
    fn from(v: ReviewOverview) -> Self {
        Self {
            duplicate_groups: v.duplicate_groups,
            scene_groups: v.scene_groups,
            visible_groups: v.visible_groups,
            pending_groups: v.pending_groups,
            candidate_groups: v.candidate_groups,
            saved_removals: v.saved_removals,
            hidden_saved_removals: v.hidden_saved_removals,
        }
    }
}
#[derive(uniffi::Record)]
pub struct CoreReviewPage {
    pub header: CoreReviewHeader,
    pub overview: CoreReviewOverview,
    pub total: u64,
    pub groups: Vec<CoreGroupSummary>,
}

pub(super) fn review_header(s: &ReviewSession) -> CoreReviewHeader {
    let (anchor, position) = s.position();
    CoreReviewHeader {
        metadata: s.metadata().clone().into(),
        settings: s.settings().clone().into(),
        healthy: s.healthy(),
        anchor: anchor.map(str::to_owned),
        position,
        navigation_sequence: s.navigation_sequence(),
        invalid_decision_count: s.invalid_decision_count() as u64,
        locked_count: s.protection().locks().count() as u64,
        read_only_sources: s
            .protection()
            .policies()
            .map(|p| p.source_id.clone())
            .collect(),
    }
}

#[uniffi::export]
impl RustReviewSession {
    pub fn review_page(
        &self,
        mode: CoreReviewPageMode,
        offset: u64,
        limit: u32,
    ) -> Result<CoreReviewPage, BridgeError> {
        let offset = usize::try_from(offset).map_err(|_| BridgeError::InvalidValue)?;
        self.access(|s| {
            let (overview, total, groups) =
                s.presentation_page(mode.into(), offset, limit as usize)?;
            Ok(CoreReviewPage {
                header: review_header(s),
                overview: overview.into(),
                total: total as u64,
                groups: groups.into_iter().map(Into::into).collect(),
            })
        })
    }
    pub fn lock_owners_page(
        &self,
        asset: CoreReviewAsset,
        offset: u64,
        limit: u32,
    ) -> Result<Vec<CoreAssetKey>, BridgeError> {
        let offset = usize::try_from(offset).map_err(|_| BridgeError::InvalidValue)?;
        self.access(|s| {
            Ok(s.lock_owners_page(&asset.into(), offset, limit as usize)?
                .into_iter()
                .map(Into::into)
                .collect())
        })
    }
}
