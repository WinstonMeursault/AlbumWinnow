mod cleanup;
mod detection;
mod presentation;
mod read_only;
use presentation::review_header;

use crate::{
    BridgeError, CancellationHandle,
    matching::CoreMatch,
    scan::{CoreAssetKey, CoreComparisonSides},
    scene::{CoreSceneEdge, CoreSceneProvider, CoreSceneQuality},
    signature::CoreSignatureEdge,
};
use albumwinnow_core::{
    CoreError, model, review, review_query,
    review_session::{ReviewIntent, ReviewSession, SourceInput},
    review_store, scan, scene_session, signature,
};
use std::{
    path::Path,
    sync::{Arc, Mutex},
};

#[derive(uniffi::Enum)]
pub enum CoreSourceKind {
    FileSystem,
    PhotoLibrary,
    ControlledTest,
}

impl From<CoreSourceKind> for review::SourceKind {
    fn from(v: CoreSourceKind) -> Self {
        match v {
            CoreSourceKind::FileSystem => Self::FileSystem,
            CoreSourceKind::PhotoLibrary => Self::PhotoLibrary,
            CoreSourceKind::ControlledTest => Self::ControlledTest,
        }
    }
}

impl From<review::SourceKind> for CoreSourceKind {
    fn from(v: review::SourceKind) -> Self {
        match v {
            review::SourceKind::FileSystem => Self::FileSystem,
            review::SourceKind::PhotoLibrary => Self::PhotoLibrary,
            review::SourceKind::ControlledTest => Self::ControlledTest,
        }
    }
}

#[derive(uniffi::Enum)]
pub enum CoreReviewStatus {
    Pending,
    Deferred,
    Confirmed,
    Kept,
}

impl From<CoreReviewStatus> for review::ReviewStatus {
    fn from(v: CoreReviewStatus) -> Self {
        match v {
            CoreReviewStatus::Pending => Self::Pending,
            CoreReviewStatus::Deferred => Self::Deferred,
            CoreReviewStatus::Confirmed => Self::Confirmed,
            CoreReviewStatus::Kept => Self::Kept,
        }
    }
}

impl From<review::ReviewStatus> for CoreReviewStatus {
    fn from(v: review::ReviewStatus) -> Self {
        match v {
            review::ReviewStatus::Pending => Self::Pending,
            review::ReviewStatus::Deferred => Self::Deferred,
            review::ReviewStatus::Confirmed => Self::Confirmed,
            review::ReviewStatus::Kept => Self::Kept,
        }
    }
}

#[derive(uniffi::Enum)]
pub enum CoreReviewStatusFilter {
    Active,
    All,
    Pending,
    Confirmed,
    Deferred,
    Kept,
}

impl From<CoreReviewStatusFilter> for review::StatusFilter {
    fn from(v: CoreReviewStatusFilter) -> Self {
        match v {
            CoreReviewStatusFilter::Active => Self::Active,
            CoreReviewStatusFilter::All => Self::All,
            CoreReviewStatusFilter::Pending => Self::Pending,
            CoreReviewStatusFilter::Confirmed => Self::Confirmed,
            CoreReviewStatusFilter::Deferred => Self::Deferred,
            CoreReviewStatusFilter::Kept => Self::Kept,
        }
    }
}

impl From<review::StatusFilter> for CoreReviewStatusFilter {
    fn from(v: review::StatusFilter) -> Self {
        match v {
            review::StatusFilter::Active => Self::Active,
            review::StatusFilter::All => Self::All,
            review::StatusFilter::Pending => Self::Pending,
            review::StatusFilter::Confirmed => Self::Confirmed,
            review::StatusFilter::Deferred => Self::Deferred,
            review::StatusFilter::Kept => Self::Kept,
        }
    }
}

#[derive(uniffi::Enum)]
pub enum CoreReviewSort {
    Stable,
    Newest,
    Oldest,
    Count,
    Bytes,
}

impl From<CoreReviewSort> for review::ReviewSort {
    fn from(v: CoreReviewSort) -> Self {
        match v {
            CoreReviewSort::Stable => Self::Stable,
            CoreReviewSort::Newest => Self::Newest,
            CoreReviewSort::Oldest => Self::Oldest,
            CoreReviewSort::Count => Self::Count,
            CoreReviewSort::Bytes => Self::Bytes,
        }
    }
}

impl From<review::ReviewSort> for CoreReviewSort {
    fn from(v: review::ReviewSort) -> Self {
        match v {
            review::ReviewSort::Stable => Self::Stable,
            review::ReviewSort::Newest => Self::Newest,
            review::ReviewSort::Oldest => Self::Oldest,
            review::ReviewSort::Count => Self::Count,
            review::ReviewSort::Bytes => Self::Bytes,
        }
    }
}

#[derive(uniffi::Enum)]
pub enum CoreReviewCollection {
    Duplicates,
    SimilarScenes,
}

impl From<CoreReviewCollection> for review::ReviewCollection {
    fn from(v: CoreReviewCollection) -> Self {
        match v {
            CoreReviewCollection::Duplicates => Self::Duplicates,
            CoreReviewCollection::SimilarScenes => Self::SimilarScenes,
        }
    }
}

impl From<review::ReviewCollection> for CoreReviewCollection {
    fn from(v: review::ReviewCollection) -> Self {
        match v {
            review::ReviewCollection::Duplicates => Self::Duplicates,
            review::ReviewCollection::SimilarScenes => Self::SimilarScenes,
        }
    }
}

#[derive(uniffi::Enum)]
pub enum CoreRecommendationReason {
    FocusSignal,
    ExposureSignal,
    SourcePreference,
    AssociatedResources,
    HigherResolution,
    HigherBitDepth,
    WideColor,
    EdgeContrast,
    NoQualityAdvantage,
}

impl From<CoreRecommendationReason> for review::RecommendationReason {
    fn from(v: CoreRecommendationReason) -> Self {
        match v {
            CoreRecommendationReason::FocusSignal => Self::FocusSignal,
            CoreRecommendationReason::ExposureSignal => Self::ExposureSignal,
            CoreRecommendationReason::SourcePreference => Self::SourcePreference,
            CoreRecommendationReason::AssociatedResources => Self::AssociatedResources,
            CoreRecommendationReason::HigherResolution => Self::HigherResolution,
            CoreRecommendationReason::HigherBitDepth => Self::HigherBitDepth,
            CoreRecommendationReason::WideColor => Self::WideColor,
            CoreRecommendationReason::EdgeContrast => Self::EdgeContrast,
            CoreRecommendationReason::NoQualityAdvantage => Self::NoQualityAdvantage,
        }
    }
}

impl From<review::RecommendationReason> for CoreRecommendationReason {
    fn from(v: review::RecommendationReason) -> Self {
        match v {
            review::RecommendationReason::FocusSignal => Self::FocusSignal,
            review::RecommendationReason::ExposureSignal => Self::ExposureSignal,
            review::RecommendationReason::SourcePreference => Self::SourcePreference,
            review::RecommendationReason::AssociatedResources => Self::AssociatedResources,
            review::RecommendationReason::HigherResolution => Self::HigherResolution,
            review::RecommendationReason::HigherBitDepth => Self::HigherBitDepth,
            review::RecommendationReason::WideColor => Self::WideColor,
            review::RecommendationReason::EdgeContrast => Self::EdgeContrast,
            review::RecommendationReason::NoQualityAdvantage => Self::NoQualityAdvantage,
        }
    }
}

#[derive(uniffi::Record)]
pub struct CoreReviewAsset {
    pub id: CoreAssetKey,
    pub name: String,
    pub revision: String,
    pub kind: CoreSourceKind,
    pub properties: Option<u8>,
    pub byte_count: Option<u64>,
    pub capture_date: Option<f64>,
    pub burst: Option<String>,
    pub native_identity: Option<String>,
    pub link_count: Option<u64>,
}

impl From<CoreReviewAsset> for review::ReviewAsset {
    fn from(v: CoreReviewAsset) -> Self {
        Self {
            id: v.id.into(),
            name: v.name,
            revision: v.revision,
            kind: v.kind.into(),
            properties: v.properties,
            byte_count: v.byte_count,
            capture_date: v.capture_date,
            burst: v.burst,
            native_identity: v.native_identity,
            link_count: v.link_count,
        }
    }
}

impl From<review::ReviewAsset> for CoreReviewAsset {
    fn from(v: review::ReviewAsset) -> Self {
        Self {
            id: v.id.into(),
            name: v.name,
            revision: v.revision,
            kind: v.kind.into(),
            properties: v.properties,
            byte_count: v.byte_count,
            capture_date: v.capture_date,
            burst: v.burst,
            native_identity: v.native_identity,
            link_count: v.link_count,
        }
    }
}

#[derive(uniffi::Record)]
pub struct CoreReviewEvidence {
    pub asset: CoreAssetKey,
    pub width: u32,
    pub height: u32,
    pub bit_depth: Option<u16>,
    pub wide_color: bool,
    pub edge_detail: Option<f64>,
    pub capture_date: Option<f64>,
}

impl From<CoreReviewEvidence> for review::ReviewEvidence {
    fn from(v: CoreReviewEvidence) -> Self {
        Self {
            asset: v.asset.into(),
            width: v.width,
            height: v.height,
            bit_depth: v.bit_depth,
            wide_color: v.wide_color,
            edge_detail: v.edge_detail,
            capture_date: v.capture_date,
        }
    }
}

impl From<review::ReviewEvidence> for CoreReviewEvidence {
    fn from(v: review::ReviewEvidence) -> Self {
        Self {
            asset: v.asset.into(),
            width: v.width,
            height: v.height,
            bit_depth: v.bit_depth,
            wide_color: v.wide_color,
            edge_detail: v.edge_detail,
            capture_date: v.capture_date,
        }
    }
}

#[derive(uniffi::Record)]
pub struct CoreReviewDuplicate {
    pub asset: CoreAssetKey,
    pub kind: CoreMatch,
}

#[derive(uniffi::Record)]
pub struct CoreReviewSceneQuality {
    pub asset: CoreAssetKey,
    pub quality: CoreSceneQuality,
}

#[derive(uniffi::Record)]
pub struct CoreReviewGroup {
    pub preferred: CoreAssetKey,
    pub members: Vec<CoreReviewAsset>,
    pub duplicates: Vec<CoreReviewDuplicate>,
    pub edges: Option<Vec<CoreSignatureEdge>>,
    pub sides: Option<CoreComparisonSides>,
    pub scene: Option<CoreSceneProvider>,
    pub recommendation: Option<CoreAssetKey>,
    pub has_quality_recommendation: bool,
    pub scene_recommendation_reason: Option<CoreRecommendationReason>,
    pub scene_quality: Vec<CoreReviewSceneQuality>,
    pub scene_matches: Vec<CoreSceneEdge>,
    pub evidence: Vec<CoreReviewEvidence>,
}

impl From<CoreReviewGroup> for review::ReviewGroup {
    fn from(v: CoreReviewGroup) -> Self {
        Self {
            preferred: v.preferred.into(),
            members: v.members.into_iter().map(Into::into).collect(),
            duplicates: v
                .duplicates
                .into_iter()
                .map(|d| (d.asset.into(), d.kind.into()))
                .collect(),
            edges: v
                .edges
                .map(|edges| edges.into_iter().map(Into::into).collect()),
            sides: v.sides.map(Into::into),
            scene: v.scene.map(Into::into),
            recommendation: v.recommendation.map(Into::into),
            has_quality_recommendation: v.has_quality_recommendation,
            scene_recommendation_reason: v.scene_recommendation_reason.map(Into::into),
            scene_quality: v
                .scene_quality
                .into_iter()
                .map(|q| (q.asset.into(), q.quality.into()))
                .collect(),
            scene_matches: v.scene_matches.into_iter().map(Into::into).collect(),
            evidence: v.evidence.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<review::ReviewGroup> for CoreReviewGroup {
    fn from(v: review::ReviewGroup) -> Self {
        Self {
            preferred: v.preferred.into(),
            members: v.members.into_iter().map(Into::into).collect(),
            duplicates: v
                .duplicates
                .into_iter()
                .map(|(asset, kind)| CoreReviewDuplicate {
                    asset: asset.into(),
                    kind: kind.into(),
                })
                .collect(),
            edges: v
                .edges
                .map(|edges| edges.into_iter().map(Into::into).collect()),
            sides: v.sides.map(Into::into),
            scene: v.scene.map(Into::into),
            recommendation: v.recommendation.map(Into::into),
            has_quality_recommendation: v.has_quality_recommendation,
            scene_recommendation_reason: v.scene_recommendation_reason.map(Into::into),
            scene_quality: v
                .scene_quality
                .into_iter()
                .map(|(asset, quality)| CoreReviewSceneQuality {
                    asset: asset.into(),
                    quality: quality.into(),
                })
                .collect(),
            scene_matches: v.scene_matches.into_iter().map(Into::into).collect(),
            evidence: v.evidence.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(uniffi::Record)]
pub struct CoreReviewDecision {
    pub status: CoreReviewStatus,
    pub keep: Option<CoreAssetKey>,
    pub removals: Vec<CoreAssetKey>,
    pub delete_all: bool,
    pub invalidated: bool,
}

impl From<CoreReviewDecision> for review::ReviewDecision {
    fn from(v: CoreReviewDecision) -> Self {
        Self {
            status: v.status.into(),
            keep: v.keep.map(Into::into),
            removals: v.removals.into_iter().map(Into::into).collect(),
            delete_all: v.delete_all,
            invalidated: v.invalidated,
        }
    }
}

impl From<review::ReviewDecision> for CoreReviewDecision {
    fn from(v: review::ReviewDecision) -> Self {
        Self {
            status: v.status.into(),
            keep: v.keep.map(Into::into),
            removals: v.removals.into_iter().map(Into::into).collect(),
            delete_all: v.delete_all,
            invalidated: v.invalidated,
        }
    }
}

#[derive(uniffi::Record)]
pub struct CoreReviewQuery {
    pub collection: CoreReviewCollection,
    pub status: CoreReviewStatusFilter,
    pub kind: Option<CoreMatch>,
    pub source: Option<String>,
    pub sort: CoreReviewSort,
}

impl From<CoreReviewQuery> for review::ReviewQuery {
    fn from(v: CoreReviewQuery) -> Self {
        Self {
            collection: v.collection.into(),
            status: v.status.into(),
            kind: v.kind.map(Into::into),
            source: v.source,
            sort: v.sort.into(),
        }
    }
}

impl From<review::ReviewQuery> for CoreReviewQuery {
    fn from(v: review::ReviewQuery) -> Self {
        Self {
            collection: v.collection.into(),
            status: v.status.into(),
            kind: v.kind.map(Into::into),
            source: v.source,
            sort: v.sort.into(),
        }
    }
}

#[derive(uniffi::Record)]
pub struct CoreCaptureRange {
    pub start: f64,
    pub end: f64,
    pub includes_unknown: bool,
}

impl From<CoreCaptureRange> for review::CaptureRange {
    fn from(v: CoreCaptureRange) -> Self {
        Self {
            start: v.start,
            end: v.end,
            includes_unknown: v.includes_unknown,
        }
    }
}

impl From<review::CaptureRange> for CoreCaptureRange {
    fn from(v: review::CaptureRange) -> Self {
        Self {
            start: v.start,
            end: v.end,
            includes_unknown: v.includes_unknown,
        }
    }
}

#[derive(uniffi::Record)]
pub struct CorePhotoScope {
    pub albums: Option<std::collections::HashMap<String, String>>,
    pub dates: Option<CoreCaptureRange>,
}

impl From<CorePhotoScope> for review::PhotoScope {
    fn from(v: CorePhotoScope) -> Self {
        Self {
            albums: v.albums.map(|a| a.into_iter().collect()),
            dates: v.dates.map(Into::into),
        }
    }
}

impl From<review::PhotoScope> for CorePhotoScope {
    fn from(v: review::PhotoScope) -> Self {
        Self {
            albums: v.albums.map(|a| a.into_iter().collect()),
            dates: v.dates.map(Into::into),
        }
    }
}

#[derive(uniffi::Record)]
pub struct CoreReviewSettings {
    pub query: CoreReviewQuery,
    pub similar_scenes_enabled: bool,
    pub scan_cancelled_by_user: bool,
    pub photo_scope: CorePhotoScope,
    pub sides: Option<CoreComparisonSides>,
    pub preferred_source: Option<String>,
}

impl From<CoreReviewSettings> for review::ReviewSettings {
    fn from(v: CoreReviewSettings) -> Self {
        Self {
            query: v.query.into(),
            similar_scenes_enabled: v.similar_scenes_enabled,
            scan_cancelled_by_user: v.scan_cancelled_by_user,
            photo_scope: v.photo_scope.into(),
            sides: v.sides.map(Into::into),
            preferred_source: v.preferred_source,
        }
    }
}

impl From<review::ReviewSettings> for CoreReviewSettings {
    fn from(v: review::ReviewSettings) -> Self {
        Self {
            query: v.query.into(),
            similar_scenes_enabled: v.similar_scenes_enabled,
            scan_cancelled_by_user: v.scan_cancelled_by_user,
            photo_scope: v.photo_scope.into(),
            sides: v.sides.map(Into::into),
            preferred_source: v.preferred_source,
        }
    }
}

#[derive(uniffi::Record)]
pub struct CoreReviewMetadata {
    pub revision: u64,
    pub scan_generation: u64,
    pub scan_scope_epoch: u64,
    pub protection_epoch: u64,
    pub scope_epoch: u64,
    pub decision_epoch: u64,
    pub source_count: u64,
    pub group_count: u64,
    pub decision_count: u64,
}

impl From<CoreReviewMetadata> for review_store::ReviewMetadata {
    fn from(v: CoreReviewMetadata) -> Self {
        Self {
            revision: v.revision,
            scan_generation: v.scan_generation,
            scan_scope_epoch: v.scan_scope_epoch,
            protection_epoch: v.protection_epoch,
            scope_epoch: v.scope_epoch,
            decision_epoch: v.decision_epoch,
            source_count: v.source_count,
            group_count: v.group_count,
            decision_count: v.decision_count,
        }
    }
}

impl From<review_store::ReviewMetadata> for CoreReviewMetadata {
    fn from(v: review_store::ReviewMetadata) -> Self {
        Self {
            revision: v.revision,
            scan_generation: v.scan_generation,
            scan_scope_epoch: v.scan_scope_epoch,
            protection_epoch: v.protection_epoch,
            scope_epoch: v.scope_epoch,
            decision_epoch: v.decision_epoch,
            source_count: v.source_count,
            group_count: v.group_count,
            decision_count: v.decision_count,
        }
    }
}

#[derive(uniffi::Record)]
pub struct CoreSourceRecord {
    pub id: String,
    pub kind: CoreSourceKind,
    pub native_namespace: String,
    pub native_identity: Vec<u8>,
    pub bookmark: Vec<u8>,
    pub label: String,
    pub active: bool,
}

impl From<CoreSourceRecord> for review::SourceRecord {
    fn from(v: CoreSourceRecord) -> Self {
        Self {
            id: v.id,
            kind: v.kind.into(),
            native_namespace: v.native_namespace,
            native_identity: v.native_identity,
            bookmark: v.bookmark,
            label: v.label,
            active: v.active,
        }
    }
}

impl From<review::SourceRecord> for CoreSourceRecord {
    fn from(v: review::SourceRecord) -> Self {
        Self {
            id: v.id,
            kind: v.kind.into(),
            native_namespace: v.native_namespace,
            native_identity: v.native_identity,
            bookmark: v.bookmark,
            label: v.label,
            active: v.active,
        }
    }
}

#[derive(uniffi::Record)]
pub struct CoreSourceInput {
    pub kind: CoreSourceKind,
    pub namespace: String,
    pub identity: Vec<u8>,
    pub bookmark: Vec<u8>,
    pub label: String,
}

impl From<CoreSourceInput> for SourceInput {
    fn from(v: CoreSourceInput) -> Self {
        Self {
            kind: v.kind.into(),
            namespace: v.namespace,
            identity: v.identity,
            bookmark: v.bookmark,
            label: v.label,
        }
    }
}

#[derive(uniffi::Record)]
pub struct CoreSizeEstimate {
    pub known_bytes: u64,
    pub known_count: u64,
    pub unknown_count: u64,
    pub overflowed: bool,
}

impl From<CoreSizeEstimate> for review_query::SizeEstimate {
    fn from(v: CoreSizeEstimate) -> Self {
        Self {
            known_bytes: v.known_bytes,
            known_count: v.known_count,
            unknown_count: v.unknown_count,
            overflowed: v.overflowed,
        }
    }
}

impl From<review_query::SizeEstimate> for CoreSizeEstimate {
    fn from(v: review_query::SizeEstimate) -> Self {
        Self {
            known_bytes: v.known_bytes,
            known_count: v.known_count,
            unknown_count: v.unknown_count,
            overflowed: v.overflowed,
        }
    }
}

#[derive(uniffi::Record)]
pub struct CoreGroupSummary {
    pub signature: String,
    pub preferred: CoreAssetKey,
    pub ordinal: u64,
    pub kind: CoreMatch,
    pub member_count: u64,
    pub status: CoreReviewStatus,
    pub latest_date: Option<f64>,
    pub estimate: CoreSizeEstimate,
    pub confirmed_removal_count: u64,
    pub saved_removal_count: u64,
    pub preview_assets: Vec<CoreReviewAsset>,
    pub preferred_evidence: Option<CoreReviewEvidence>,
}

impl From<CoreGroupSummary> for albumwinnow_core::review_session::GroupSummary {
    fn from(v: CoreGroupSummary) -> Self {
        Self {
            signature: v.signature,
            preferred: v.preferred.into(),
            ordinal: v.ordinal,
            kind: v.kind.into(),
            member_count: v.member_count,
            status: v.status.into(),
            latest_date: v.latest_date,
            estimate: v.estimate.into(),
            confirmed_removal_count: v.confirmed_removal_count,
            saved_removal_count: v.saved_removal_count,
            preview_assets: v.preview_assets.into_iter().map(Into::into).collect(),
            preferred_evidence: v.preferred_evidence.map(Into::into),
        }
    }
}

impl From<albumwinnow_core::review_session::GroupSummary> for CoreGroupSummary {
    fn from(v: albumwinnow_core::review_session::GroupSummary) -> Self {
        Self {
            signature: v.signature,
            preferred: v.preferred.into(),
            ordinal: v.ordinal,
            kind: v.kind.into(),
            member_count: v.member_count,
            status: v.status.into(),
            latest_date: v.latest_date,
            estimate: v.estimate.into(),
            confirmed_removal_count: v.confirmed_removal_count,
            saved_removal_count: v.saved_removal_count,
            preview_assets: v.preview_assets.into_iter().map(Into::into).collect(),
            preferred_evidence: v.preferred_evidence.map(Into::into),
        }
    }
}

#[derive(uniffi::Record)]
pub struct CoreReviewDelta {
    pub metadata: CoreReviewMetadata,
    pub signature: String,
    pub decision: CoreReviewDecision,
    pub replayed: bool,
}

impl From<CoreReviewDelta> for albumwinnow_core::review_session::ReviewDelta {
    fn from(v: CoreReviewDelta) -> Self {
        Self {
            metadata: v.metadata.into(),
            signature: v.signature,
            decision: v.decision.into(),
            replayed: v.replayed,
        }
    }
}

impl From<albumwinnow_core::review_session::ReviewDelta> for CoreReviewDelta {
    fn from(v: albumwinnow_core::review_session::ReviewDelta) -> Self {
        Self {
            metadata: v.metadata.into(),
            signature: v.signature,
            decision: v.decision.into(),
            replayed: v.replayed,
        }
    }
}

#[derive(uniffi::Record)]
pub struct CoreReviewHeader {
    pub metadata: CoreReviewMetadata,
    pub settings: CoreReviewSettings,
    pub healthy: bool,
    pub anchor: Option<String>,
    pub position: Option<u64>,
    pub navigation_sequence: u64,
    pub invalid_decision_count: u64,
    pub locked_count: u64,
    pub read_only_sources: Vec<String>,
}

#[derive(uniffi::Record)]
pub struct CoreGroupDetail {
    pub group: CoreReviewGroup,
    pub decision: Option<CoreReviewDecision>,
    pub reasons: Vec<CoreRecommendationReason>,
    pub protected: Vec<CoreAssetKey>,
    pub locked: Vec<CoreAssetKey>,
    pub read_only: Vec<CoreAssetKey>,
    pub summary: CoreGroupSummary,
}

impl From<CoreComparisonSides> for scan::ComparisonSides {
    fn from(v: CoreComparisonSides) -> Self {
        Self {
            first: v.first,
            second: v.second,
        }
    }
}
impl From<scan::ComparisonSides> for CoreComparisonSides {
    fn from(v: scan::ComparisonSides) -> Self {
        Self {
            first: v.first,
            second: v.second,
        }
    }
}
impl From<model::SceneProvider> for CoreSceneProvider {
    fn from(v: model::SceneProvider) -> Self {
        Self {
            provider_id: v.provider_id,
            model_revision: v.model_revision,
            preprocessing: v.preprocessing,
            platform_compatibility: v.platform_compatibility,
        }
    }
}
impl From<CoreSignatureEdge> for signature::SignatureEdge {
    fn from(v: CoreSignatureEdge) -> Self {
        Self {
            first: v.first.into(),
            second: v.second.into(),
            kind: v.kind.into(),
        }
    }
}
impl From<signature::SignatureEdge> for CoreSignatureEdge {
    fn from(v: signature::SignatureEdge) -> Self {
        Self {
            first: v.first.into(),
            second: v.second.into(),
            kind: v.kind.into(),
        }
    }
}
impl From<CoreSceneEdge> for scene_session::SceneEdge {
    fn from(v: CoreSceneEdge) -> Self {
        Self {
            first: v.first.into(),
            second: v.second.into(),
            distance: v.distance,
            shared_burst: v.shared_burst,
        }
    }
}
impl From<scene_session::SceneEdge> for CoreSceneEdge {
    fn from(v: scene_session::SceneEdge) -> Self {
        Self {
            first: v.first.into(),
            second: v.second.into(),
            distance: v.distance,
            shared_burst: v.shared_burst,
        }
    }
}
#[derive(uniffi::Enum)]
pub enum CoreReviewIntent {
    ConfirmKeep { keep: CoreAssetKey },
    ConfirmDeleteAll,
    SetStatus { status: CoreReviewStatus },
}
impl From<CoreReviewIntent> for ReviewIntent {
    fn from(v: CoreReviewIntent) -> Self {
        match v {
            CoreReviewIntent::ConfirmKeep { keep } => Self::ConfirmKeep { keep: keep.into() },
            CoreReviewIntent::ConfirmDeleteAll => Self::ConfirmDeleteAll,
            CoreReviewIntent::SetStatus { status } => Self::SetStatus {
                status: status.into(),
            },
        }
    }
}

#[derive(uniffi::Object)]
pub struct RustReviewSession {
    state: Mutex<ReviewSession>,
}
impl RustReviewSession {
    fn access<T>(
        &self,
        operation: impl FnOnce(&mut ReviewSession) -> Result<T, CoreError>,
    ) -> Result<T, BridgeError> {
        let mut session = self
            .state
            .lock()
            .map_err(|_| BridgeError::InternalFailure)?;
        session.validate_storage()?;
        Ok(operation(&mut session)?)
    }
}
#[uniffi::export]
impl RustReviewSession {
    #[uniffi::constructor]
    pub fn new(database_path: String, initialized: bool) -> Result<Arc<Self>, BridgeError> {
        if database_path.is_empty() || database_path.len() > 32768 || database_path.contains('\0') {
            return Err(BridgeError::InvalidValue);
        }
        Ok(Arc::new(Self {
            state: Mutex::new(ReviewSession::open(Path::new(&database_path), initialized)?),
        }))
    }
    pub fn is_healthy(&self) -> bool {
        self.state.lock().is_ok_and(|session| session.healthy())
    }
    pub fn header(&self) -> Result<CoreReviewHeader, BridgeError> {
        self.access(|s| Ok(review_header(s)))
    }
    pub fn register_source(
        &self,
        expected_revision: u64,
        input: CoreSourceInput,
    ) -> Result<CoreSourceRecord, BridgeError> {
        self.access(|s| Ok(s.register_source(expected_revision, input.into())?.into()))
    }
    pub fn set_source_active(
        &self,
        expected_revision: u64,
        source: String,
        active: bool,
    ) -> Result<CoreSourceRecord, BridgeError> {
        self.access(|s| {
            Ok(s.set_source_active(expected_revision, &source, active)?
                .into())
        })
    }
    pub fn sources_page(
        &self,
        offset: u64,
        limit: u32,
    ) -> Result<Vec<CoreSourceRecord>, BridgeError> {
        if limit > 256 {
            return Err(BridgeError::InvalidValue);
        }
        let offset = usize::try_from(offset).map_err(|_| BridgeError::InvalidValue)?;
        self.access(|s| {
            Ok(s.sources()
                .skip(offset)
                .take(limit as usize)
                .cloned()
                .map(Into::into)
                .collect())
        })
    }
    pub fn begin_scan(
        &self,
        expected_revision: u64,
        operation_id: String,
    ) -> Result<(), BridgeError> {
        self.access(|s| s.begin_scan(expected_revision, operation_id))
    }
    pub fn append_scan_groups(
        &self,
        operation_id: String,
        groups: Vec<CoreReviewGroup>,
        cancellation: Arc<CancellationHandle>,
    ) -> Result<(), BridgeError> {
        cancellation.cancellation.check()?;
        if groups.len() > 16 {
            return Err(BridgeError::InvalidBuffer);
        }
        self.access(|s| {
            cancellation.cancellation.check()?;
            s.append_scan_groups(&operation_id, groups.into_iter().map(Into::into).collect())
        })
    }
    pub fn finish_scan(
        &self,
        operation_id: String,
        cancellation: Arc<CancellationHandle>,
    ) -> Result<CoreReviewMetadata, BridgeError> {
        cancellation.cancellation.check()?;
        self.access(|s| {
            cancellation.cancellation.check()?;
            s.finish_scan(&operation_id)?;
            Ok(s.metadata().clone().into())
        })
    }
    pub fn discard_scan(&self, operation_id: String) -> Result<(), BridgeError> {
        self.access(|s| s.discard_scan(&operation_id))
    }
    pub fn apply_intent(
        &self,
        expected_revision: u64,
        signature: String,
        command_id: String,
        intent: CoreReviewIntent,
    ) -> Result<CoreReviewDelta, BridgeError> {
        self.access(|s| {
            Ok(
                s.apply_intent(expected_revision, &signature, command_id, intent.into())?
                    .into(),
            )
        })
    }
    pub fn set_locked(
        &self,
        expected_revision: u64,
        asset: CoreReviewAsset,
        locked: bool,
    ) -> Result<CoreReviewMetadata, BridgeError> {
        self.access(|s| {
            s.set_locked(expected_revision, asset.into(), locked)?;
            Ok(s.metadata().clone().into())
        })
    }
    pub fn remove_saved_lock(
        &self,
        expected_revision: u64,
        asset: CoreAssetKey,
    ) -> Result<CoreReviewMetadata, BridgeError> {
        self.access(|s| {
            s.remove_saved_lock(expected_revision, &asset.into())?;
            Ok(s.metadata().clone().into())
        })
    }
    pub fn locked_page(
        &self,
        offset: u64,
        limit: u32,
    ) -> Result<Vec<CoreReviewAsset>, BridgeError> {
        if limit > 256 {
            return Err(BridgeError::InvalidValue);
        }
        let offset = usize::try_from(offset).map_err(|_| BridgeError::InvalidValue)?;
        self.access(|s| {
            Ok(s.protection()
                .locks()
                .skip(offset)
                .take(limit as usize)
                .cloned()
                .map(Into::into)
                .collect())
        })
    }
    pub fn save_settings(
        &self,
        expected_revision: u64,
        settings: CoreReviewSettings,
    ) -> Result<CoreReviewMetadata, BridgeError> {
        self.access(|s| {
            s.save_settings(expected_revision, settings.into())?;
            Ok(s.metadata().clone().into())
        })
    }
    pub fn save_position(
        &self,
        expected_revision: u64,
        sequence: u64,
        anchor: Option<String>,
        position: Option<u64>,
    ) -> Result<(), BridgeError> {
        self.access(|s| s.save_position(expected_revision, sequence, anchor, position))
    }
    pub fn reset_progress(
        &self,
        expected_revision: u64,
    ) -> Result<CoreReviewMetadata, BridgeError> {
        self.access(|s| {
            s.reset_progress(expected_revision)?;
            Ok(s.metadata().clone().into())
        })
    }
    pub fn remove_invalid_decisions(
        &self,
        expected_revision: u64,
    ) -> Result<CoreReviewMetadata, BridgeError> {
        self.access(|s| {
            s.remove_invalid_decisions(expected_revision)?;
            Ok(s.metadata().clone().into())
        })
    }
    pub fn query_count(&self) -> Result<u64, BridgeError> {
        self.access(|s| Ok(s.query_count()? as u64))
    }
    pub fn query_page(
        &self,
        offset: u64,
        limit: u32,
    ) -> Result<Vec<CoreGroupSummary>, BridgeError> {
        let offset = usize::try_from(offset).map_err(|_| BridgeError::InvalidValue)?;
        self.access(|s| {
            Ok(s.query_page(offset, limit as usize)?
                .into_iter()
                .map(Into::into)
                .collect())
        })
    }
    pub fn group_detail(&self, signature: String) -> Result<CoreGroupDetail, BridgeError> {
        self.access(|s| {
            let detail = s.detail(&signature)?;
            let group = detail.group.clone();
            let decision = detail.decision.cloned();
            let reasons = group
                .recommendation_reasons()
                .into_iter()
                .map(Into::into)
                .collect();
            let protected = group
                .members
                .iter()
                .filter(|a| s.protection().protected(a))
                .map(|a| a.id.clone().into())
                .collect();
            let locked = group
                .members
                .iter()
                .filter(|a| s.protection().locked(a))
                .map(|a| a.id.clone().into())
                .collect();
            let read_only = group
                .members
                .iter()
                .filter(|a| s.protection().read_only_source_or_alias(a))
                .map(|a| a.id.clone().into())
                .collect();
            let summary = s.group_summary(&signature)?.into();
            Ok(CoreGroupDetail {
                group: group.into(),
                decision: decision.map(Into::into),
                reasons,
                protected,
                locked,
                read_only,
                summary,
            })
        })
    }
    pub fn resume_signature(&self) -> Result<Option<String>, BridgeError> {
        self.access(|s| s.resume_signature())
    }
}
