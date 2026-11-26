use crate::{
    CoreError,
    matching::MatchKind,
    model::{AssetId, SceneProvider, validate_date},
    scan::ComparisonSides,
    signature::{SignatureEdge, SignatureEvidence, SignatureMember},
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum SourceKind {
    FileSystem,
    PhotoLibrary,
    ControlledTest,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ReviewAsset {
    pub id: AssetId,
    pub name: String,
    pub revision: String,
    pub kind: SourceKind,
    pub properties: Option<u8>,
    pub byte_count: Option<u64>,
    pub capture_date: Option<f64>,
    pub burst: Option<String>,
    pub native_identity: Option<String>,
    pub link_count: Option<u64>,
}
impl ReviewAsset {
    pub fn validate(&self) -> Result<(), CoreError> {
        self.id.validate()?;
        validate_date(self.capture_date)?;
        if self.name.len() > 16384
            || self.revision.len() > 8192
            || self.properties.is_some_and(|v| v > 7)
            || self.byte_count.is_some_and(|v| v > i64::MAX as u64)
            || self.burst.as_ref().is_some_and(|v| v.len() > 8192)
            || self
                .native_identity
                .as_ref()
                .is_some_and(|v| v.is_empty() || v.len() > 4096)
            || self.link_count == Some(0)
        {
            return Err(CoreError::InvalidValue);
        }
        Ok(())
    }
    pub fn associated_resources(&self) -> bool {
        self.properties.is_some_and(|v| v != 0)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ReviewEvidence {
    pub asset: AssetId,
    pub width: u32,
    pub height: u32,
    pub bit_depth: Option<u16>,
    pub wide_color: bool,
    pub edge_detail: Option<f64>,
    pub capture_date: Option<f64>,
}
impl ReviewEvidence {
    pub(crate) fn validate(&self) -> Result<(), CoreError> {
        self.asset.validate()?;
        validate_date(self.capture_date)?;
        if self.width == 0
            || self.height == 0
            || u64::from(self.width) * u64::from(self.height) > crate::model::MAX_SOURCE_PIXELS
            || self.bit_depth.is_some_and(|v| v == 0 || v > 64)
            || self.edge_detail.is_some_and(|v| !v.is_finite() || v < 0.0)
        {
            return Err(CoreError::InvalidValue);
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum RecommendationReason {
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
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ReviewGroup {
    pub preferred: AssetId,
    /// Native/display order is preserved; signature member order is canonical.
    pub members: Vec<ReviewAsset>,
    pub duplicates: Vec<(AssetId, MatchKind)>,
    pub edges: Option<Vec<SignatureEdge>>,
    pub sides: Option<ComparisonSides>,
    pub scene: Option<SceneProvider>,
    pub recommendation: Option<AssetId>,
    pub has_quality_recommendation: bool,
    pub scene_recommendation_reason: Option<RecommendationReason>,
    pub scene_quality: Vec<(AssetId, crate::scene::SceneQuality)>,
    pub scene_matches: Vec<crate::scene_session::SceneEdge>,
    pub evidence: Vec<ReviewEvidence>,
}
impl ReviewGroup {
    pub fn signature(&self) -> Result<String, CoreError> {
        self.validate()?;
        SignatureEvidence {
            members: self
                .members
                .iter()
                .map(|a| SignatureMember {
                    id: a.id.clone(),
                    revision: a.revision.clone(),
                    properties: a.properties,
                })
                .collect(),
            edges: self.actual_edges(),
            sides: self.sides.clone(),
            scene: self.scene.clone(),
        }
        .digest()
    }
    pub fn validate(&self) -> Result<(), CoreError> {
        if self.members.len() < 2
            || self.members.len() > 100000
            || self.duplicates.len() + 1 != self.members.len()
        {
            return Err(CoreError::InvalidValue);
        }
        let mut ids = HashSet::new();
        for asset in &self.members {
            asset.validate()?;
            if !ids.insert(&asset.id) {
                return Err(CoreError::InvalidValue);
            }
        }
        if !ids.contains(&self.preferred)
            || self
                .recommendation
                .as_ref()
                .is_some_and(|id| !ids.contains(id))
        {
            return Err(CoreError::InvalidValue);
        }
        let mut duplicates = HashSet::new();
        for (id, kind) in &self.duplicates {
            if !ids.contains(id)
                || *id == self.preferred
                || !duplicates.insert(id)
                || (*kind == MatchKind::Distinct && self.edges.is_none())
            {
                return Err(CoreError::InvalidValue);
            }
        }
        if let Some(provider) = &self.scene {
            provider.validate()?;
        }
        if let Some(sides) = &self.sides
            && (sides.first == sides.second
                || sides.first.is_empty()
                || sides.second.is_empty()
                || self
                    .members
                    .iter()
                    .any(|m| m.id.source_id != sides.first && m.id.source_id != sides.second))
        {
            return Err(CoreError::InvalidValue);
        }
        if let Some(edges) = &self.edges {
            if edges.is_empty() || edges.len() > 1600000 {
                return Err(CoreError::InvalidValue);
            }
            for edge in edges {
                if edge.first == edge.second
                    || !ids.contains(&edge.first)
                    || !ids.contains(&edge.second)
                    || edge.kind == MatchKind::Distinct
                    || (edge.kind == MatchKind::SceneSimilar && self.scene.is_none())
                    || self
                        .sides
                        .as_ref()
                        .is_some_and(|s| !permits(s, &edge.first, &edge.second))
                {
                    return Err(CoreError::InvalidValue);
                }
            }
        }
        let mut seen = HashSet::new();
        for evidence in &self.evidence {
            evidence.validate()?;
            if !ids.contains(&evidence.asset) || !seen.insert(&evidence.asset) {
                return Err(CoreError::InvalidValue);
            }
        }
        let mut quality_ids = HashSet::new();
        for (id, quality) in &self.scene_quality {
            quality.validate()?;
            if self.scene.is_none() || !ids.contains(id) || !quality_ids.insert(id) {
                return Err(CoreError::InvalidValue);
            }
        }
        let actual_edges = self.actual_edges();
        let scene_edges: HashSet<_> = actual_edges
            .iter()
            .filter(|edge| edge.kind == MatchKind::SceneSimilar)
            .map(|edge| {
                if edge.first < edge.second {
                    (&edge.first, &edge.second)
                } else {
                    (&edge.second, &edge.first)
                }
            })
            .collect();
        let mut measured = HashSet::new();
        for edge in &self.scene_matches {
            let pair = if edge.first < edge.second {
                (&edge.first, &edge.second)
            } else {
                (&edge.second, &edge.first)
            };
            if self.scene.is_none()
                || edge.first == edge.second
                || !ids.contains(&edge.first)
                || !ids.contains(&edge.second)
                || !edge.distance.is_finite()
                || edge.distance < 0.0
                || !scene_edges.contains(&pair)
                || !measured.insert(pair)
            {
                return Err(CoreError::InvalidValue);
            }
        }
        Ok(())
    }
    pub fn actual_edges(&self) -> Vec<SignatureEdge> {
        self.edges.clone().unwrap_or_else(|| {
            self.duplicates
                .iter()
                .map(|(id, kind)| SignatureEdge {
                    first: self.preferred.clone(),
                    second: id.clone(),
                    kind: *kind,
                })
                .collect()
        })
    }
    pub fn match_kind(&self) -> MatchKind {
        if self.scene.is_some() {
            return MatchKind::SceneSimilar;
        }
        for kind in [MatchKind::SimilarPhoto, MatchKind::VisualDuplicate] {
            if self.duplicates.iter().any(|(_, v)| *v == kind)
                || self
                    .edges
                    .as_ref()
                    .is_some_and(|edges| edges.iter().any(|e| e.kind == kind))
            {
                return kind;
            }
        }
        MatchKind::ExactDuplicate
    }
    pub fn recommendation_id(&self) -> &AssetId {
        self.recommendation.as_ref().unwrap_or(&self.preferred)
    }
    pub fn latest_date(&self) -> Option<f64> {
        let dates: HashMap<_, _> = self
            .evidence
            .iter()
            .map(|e| (&e.asset, e.capture_date))
            .collect();
        self.members
            .iter()
            .filter_map(|asset| {
                asset
                    .capture_date
                    .or_else(|| dates.get(&asset.id).copied().flatten())
            })
            .max_by(f64::total_cmp)
    }
    /// Keeps the original deterministic retained-member graph rule. A missing
    /// direct approximate edge never becomes evidence through transitivity.
    pub fn removal_pairs(
        &self,
        keep: &AssetId,
        protection: &ProtectionState,
    ) -> Vec<(AssetId, AssetId)> {
        let Some(selected) = self.members.iter().find(|a| a.id == *keep) else {
            return Vec::new();
        };
        let same_native = |a: &ReviewAsset, b: &ReviewAsset| {
            a.native_identity
                .as_ref()
                .is_some_and(|id| Some(id) == b.native_identity.as_ref())
        };
        if self.edges.is_none()
            && self
                .duplicates
                .iter()
                .all(|(_, kind)| *kind == MatchKind::ExactDuplicate)
        {
            return self
                .members
                .iter()
                .filter(|a| a.id != *keep && !protection.protected(a) && !same_native(selected, a))
                .map(|a| (keep.clone(), a.id.clone()))
                .collect();
        }
        let edges = self.actual_edges();
        let mut adjacent: HashMap<&AssetId, Vec<&AssetId>> = HashMap::new();
        for edge in &edges {
            if edge.kind != MatchKind::Distinct {
                adjacent.entry(&edge.first).or_default().push(&edge.second);
                adjacent.entry(&edge.second).or_default().push(&edge.first);
            }
        }
        let mut retained: HashMap<&AssetId, &ReviewAsset> = self
            .members
            .iter()
            .filter(|a| a.id == *keep || protection.protected(a))
            .map(|a| (&a.id, a))
            .collect();
        let mut pairs = Vec::new();
        for asset in &self.members {
            if asset.id == *keep || retained.contains_key(&asset.id) {
                continue;
            }
            let keeper = adjacent
                .get(&asset.id)
                .into_iter()
                .flatten()
                .filter_map(|id| retained.get(id).copied())
                .find(|keeper| !same_native(keeper, asset));
            if let Some(keeper) = keeper {
                pairs.push((keeper.id.clone(), asset.id.clone()));
            } else {
                retained.insert(&asset.id, asset);
            }
        }
        pairs
    }
}
fn permits(sides: &ComparisonSides, a: &AssetId, b: &AssetId) -> bool {
    a != b
        && ((a.source_id == sides.first && b.source_id == sides.second)
            || (a.source_id == sides.second && b.source_id == sides.first))
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ReadOnlyPolicy {
    pub source_id: String,
    pub kind: SourceKind,
    pub snapshot_complete: bool,
    pub members: Vec<ReviewAsset>,
}
#[derive(Clone, Debug, Default)]
pub struct ProtectionState {
    locks: BTreeMap<AssetId, ReviewAsset>,
    read_only: BTreeMap<String, ReadOnlyPolicy>,
    locked_identities: HashMap<String, Vec<AssetId>>,
    read_only_identities: HashSet<String>,
    unknown_filesystem_locks: bool,
    filesystem_read_only: bool,
    unknown_filesystem_policy: bool,
}
impl ProtectionState {
    pub fn new(locks: Vec<ReviewAsset>, policies: Vec<ReadOnlyPolicy>) -> Result<Self, CoreError> {
        let mut result = Self::default();
        for asset in locks {
            asset.validate()?;
            if result.locks.contains_key(&asset.id) {
                return Err(CoreError::InvalidValue);
            }
            if let Some(identity) = &asset.native_identity {
                result
                    .locked_identities
                    .entry(identity.clone())
                    .or_default()
                    .push(asset.id.clone());
            } else if asset.kind == SourceKind::FileSystem {
                result.unknown_filesystem_locks = true;
            }
            result.locks.insert(asset.id.clone(), asset);
        }
        for policy in policies {
            if policy.source_id.is_empty()
                || policy.source_id.len() > 4096
                || result.read_only.contains_key(&policy.source_id)
            {
                return Err(CoreError::InvalidValue);
            }
            if policy.kind == SourceKind::FileSystem {
                result.filesystem_read_only = true;
                if !policy.snapshot_complete {
                    result.unknown_filesystem_policy = true;
                }
            }
            let mut member_ids = HashSet::new();
            for asset in &policy.members {
                asset.validate()?;
                if asset.id.source_id != policy.source_id
                    || asset.kind != policy.kind
                    || !member_ids.insert(&asset.id)
                {
                    return Err(CoreError::InvalidValue);
                }
                if let Some(identity) = &asset.native_identity {
                    result.read_only_identities.insert(identity.clone());
                }
            }
            result.read_only.insert(policy.source_id.clone(), policy);
        }
        Ok(result)
    }
    pub fn locks(&self) -> impl Iterator<Item = &ReviewAsset> {
        self.locks.values()
    }
    pub fn policies(&self) -> impl Iterator<Item = &ReadOnlyPolicy> {
        self.read_only.values()
    }
    pub fn setting_lock(&self, asset: ReviewAsset, locked: bool) -> Result<Self, CoreError> {
        asset.validate()?;
        let mut locks = self.locks.clone();
        if locked {
            locks.insert(asset.id.clone(), asset);
        } else {
            for id in self.lock_owners(&asset) {
                locks.remove(&id);
            }
        }
        Self::new(
            locks.into_values().collect(),
            self.read_only.values().cloned().collect(),
        )
    }
    pub fn removing_saved_lock(&self, id: &AssetId) -> Result<Self, CoreError> {
        id.validate()?;
        let locks = self
            .locks
            .values()
            .filter(|asset| asset.id != *id)
            .cloned()
            .collect();
        Self::new(locks, self.read_only.values().cloned().collect())
    }
    pub fn setting_read_only(
        &self,
        source: &str,
        policy: Option<ReadOnlyPolicy>,
    ) -> Result<Self, CoreError> {
        let mut policies = self.read_only.clone();
        if let Some(policy) = policy {
            if policy.source_id != source {
                return Err(CoreError::InvalidValue);
            }
            policies.insert(source.into(), policy);
        } else {
            policies.remove(source);
        }
        Self::new(
            self.locks.values().cloned().collect(),
            policies.into_values().collect(),
        )
    }
    pub fn lock_owners(&self, asset: &ReviewAsset) -> Vec<AssetId> {
        let mut owners = self
            .locked_identities
            .get(asset.native_identity.as_deref().unwrap_or(""))
            .cloned()
            .unwrap_or_default();
        if self.locks.contains_key(&asset.id) && !owners.contains(&asset.id) {
            owners.push(asset.id.clone());
        }
        owners.sort();
        owners
    }
    pub fn locked(&self, asset: &ReviewAsset) -> bool {
        self.locks.contains_key(&asset.id)
            || asset
                .native_identity
                .as_ref()
                .is_some_and(|identity| self.locked_identities.contains_key(identity))
    }
    pub fn protected(&self, asset: &ReviewAsset) -> bool {
        asset.associated_resources()
            || self.read_only.contains_key(&asset.id.source_id)
            || self.locked(asset)
            || asset
                .native_identity
                .as_ref()
                .is_some_and(|identity| self.read_only_identities.contains(identity))
            || (asset.kind == SourceKind::FileSystem
                && (asset.native_identity.is_none()
                    || self.unknown_filesystem_locks
                    || self.unknown_filesystem_policy
                    || (self.filesystem_read_only
                        && asset.link_count.is_none_or(|count| count > 1))))
    }
    pub fn read_only_source_or_alias(&self, asset: &ReviewAsset) -> bool {
        self.read_only.contains_key(&asset.id.source_id)
            || asset
                .native_identity
                .as_ref()
                .is_some_and(|id| self.read_only_identities.contains(id))
    }
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub enum ReviewStatus {
    #[default]
    Pending,
    Deferred,
    Confirmed,
    Kept,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ReviewDecision {
    pub status: ReviewStatus,
    pub keep: Option<AssetId>,
    pub removals: BTreeSet<AssetId>,
    pub delete_all: bool,
    pub invalidated: bool,
}
impl Default for ReviewDecision {
    fn default() -> Self {
        Self {
            status: ReviewStatus::Pending,
            keep: None,
            removals: BTreeSet::new(),
            delete_all: false,
            invalidated: false,
        }
    }
}
impl ReviewDecision {
    pub fn confirm(
        group: &ReviewGroup,
        keep: Option<AssetId>,
        delete_all: bool,
        protection: &ProtectionState,
    ) -> Result<Self, CoreError> {
        group.validate()?;
        if delete_all {
            if keep.is_some() || group.members.iter().any(|a| protection.protected(a)) {
                return Err(CoreError::ProtectionUnavailable);
            }
            return Ok(Self {
                status: ReviewStatus::Confirmed,
                keep: None,
                removals: group.members.iter().map(|a| a.id.clone()).collect(),
                delete_all: true,
                invalidated: false,
            });
        }
        let keep = keep.ok_or(CoreError::InvalidValue)?;
        if !group.members.iter().any(|a| a.id == keep) {
            return Err(CoreError::InvalidValue);
        }
        let removals = group
            .removal_pairs(&keep, protection)
            .into_iter()
            .map(|(_, remove)| remove)
            .collect();
        Ok(Self {
            status: ReviewStatus::Confirmed,
            keep: Some(keep),
            removals,
            delete_all: false,
            invalidated: false,
        })
    }
    pub fn prune(&mut self, group: &ReviewGroup, protection: &ProtectionState) {
        if self.delete_all && group.members.iter().any(|a| protection.protected(a)) {
            *self = Self::default();
            return;
        }
        let assets: HashMap<_, _> = group.members.iter().map(|a| (&a.id, a)).collect();
        self.removals.retain(|id| {
            assets
                .get(id)
                .is_some_and(|asset| !protection.protected(asset))
        });
    }
    pub fn validate(&self, group: &ReviewGroup) -> Result<(), CoreError> {
        let ids: HashSet<_> = group.members.iter().map(|a| &a.id).collect();
        if self.removals.iter().any(|id| !ids.contains(id))
            || self
                .keep
                .as_ref()
                .is_some_and(|id| !ids.contains(id) || self.removals.contains(id))
            || (self.delete_all && (self.keep.is_some() || self.removals.len() != ids.len()))
            || (!self.removals.is_empty() && !self.delete_all && self.keep.is_none())
        {
            return Err(CoreError::InvalidValue);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub enum StatusFilter {
    #[default]
    Active,
    All,
    Pending,
    Confirmed,
    Deferred,
    Kept,
}
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub enum ReviewSort {
    #[default]
    Stable,
    Newest,
    Oldest,
    Count,
    Bytes,
}
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub enum ReviewCollection {
    #[default]
    Duplicates,
    SimilarScenes,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReviewQuery {
    pub collection: ReviewCollection,
    pub status: StatusFilter,
    pub kind: Option<MatchKind>,
    pub source: Option<String>,
    pub sort: ReviewSort,
}
impl ReviewQuery {
    pub fn includes(&self, group: &ReviewGroup, status: ReviewStatus) -> bool {
        (self.collection == ReviewCollection::SimilarScenes)
            == (group.match_kind() == MatchKind::SceneSimilar)
            && match self.status {
                StatusFilter::All => true,
                StatusFilter::Active => status != ReviewStatus::Kept,
                StatusFilter::Pending => status == ReviewStatus::Pending,
                StatusFilter::Confirmed => status == ReviewStatus::Confirmed,
                StatusFilter::Deferred => status == ReviewStatus::Deferred,
                StatusFilter::Kept => status == ReviewStatus::Kept,
            }
            && self.kind.is_none_or(|kind| kind == group.match_kind())
            && self
                .source
                .as_ref()
                .is_none_or(|source| group.members.iter().any(|a| a.id.source_id == *source))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct SourceRecord {
    pub id: String,
    pub kind: SourceKind,
    pub native_namespace: String,
    pub native_identity: Vec<u8>,
    pub bookmark: Vec<u8>,
    pub label: String,
    pub active: bool,
}
impl SourceRecord {
    pub fn validate(&self) -> Result<(), CoreError> {
        if self.id.is_empty()
            || self.id.len() > 4096
            || self.native_namespace.is_empty()
            || self.native_namespace.len() > 256
            || self.native_identity.is_empty()
            || self.native_identity.len() > 4096
            || self.bookmark.len() > 131072
            || self.label.len() > 16384
        {
            return Err(CoreError::InvalidValue);
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct CaptureRange {
    pub start: f64,
    pub end: f64,
    pub includes_unknown: bool,
}
impl CaptureRange {
    pub fn validate(&self) -> Result<(), CoreError> {
        if !self.start.is_finite() || !self.end.is_finite() || self.end <= self.start {
            return Err(CoreError::InvalidValue);
        }
        Ok(())
    }
    pub fn contains(&self, date: Option<f64>) -> Result<bool, CoreError> {
        self.validate()?;
        validate_date(date)?;
        Ok(date.map_or(self.includes_unknown, |date| {
            date >= self.start && date < self.end
        }))
    }
}
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct PhotoScope {
    pub albums: Option<BTreeMap<String, String>>,
    pub dates: Option<CaptureRange>,
}
impl PhotoScope {
    pub fn validate(&self) -> Result<(), CoreError> {
        if let Some(range) = &self.dates {
            range.validate()?;
        }
        if self.albums.as_ref().is_some_and(|albums| {
            albums.len() > 10000
                || albums
                    .iter()
                    .any(|(id, name)| id.is_empty() || id.len() > 4096 || name.len() > 16384)
        }) {
            return Err(CoreError::InvalidValue);
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct ReviewSettings {
    pub query: ReviewQuery,
    pub similar_scenes_enabled: bool,
    pub scan_cancelled_by_user: bool,
    pub photo_scope: PhotoScope,
    pub sides: Option<ComparisonSides>,
    pub preferred_source: Option<String>,
}
impl ReviewSettings {
    pub fn validate(&self) -> Result<(), CoreError> {
        self.photo_scope.validate()?;
        if self
            .preferred_source
            .as_ref()
            .is_some_and(|s| s.is_empty() || s.len() > 4096)
            || self
                .query
                .source
                .as_ref()
                .is_some_and(|s| s.is_empty() || s.len() > 4096)
            || self.sides.as_ref().is_some_and(|s| {
                s.first.is_empty()
                    || s.second.is_empty()
                    || s.first == s.second
                    || s.first.len() > 4096
                    || s.second.len() > 4096
            })
        {
            return Err(CoreError::InvalidValue);
        }
        Ok(())
    }
}
