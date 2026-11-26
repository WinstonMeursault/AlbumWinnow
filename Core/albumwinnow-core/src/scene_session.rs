use crate::{
    Cancellation, CoreError,
    model::{AssetId, SceneProvider, validate_date},
    scene::{SceneQuality, matches},
};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::Arc,
};

pub const CANDIDATE_LIMIT: usize = 64;
pub const MEMBER_LIMIT: usize = 24;

#[derive(Default)]
pub struct SceneIndex {
    buckets: HashMap<u32, VecDeque<usize>>,
    bursts: HashMap<String, VecDeque<usize>>,
    dated: VecDeque<(usize, f64)>,
}
impl SceneIndex {
    pub fn candidates(
        &self,
        keys: [u16; 4],
        burst: Option<&str>,
        date: Option<f64>,
    ) -> Result<Vec<usize>, CoreError> {
        validate_date(date)?;
        let mut result = Vec::new();
        let mut seen = HashSet::new();
        let mut add = |values: Vec<usize>| {
            for index in values.into_iter().rev() {
                if result.len() < CANDIDATE_LIMIT && seen.insert(index) {
                    result.push(index);
                }
            }
        };
        if let Some(burst) = burst {
            add(self
                .bursts
                .get(burst)
                .map(|v| v.iter().copied().collect())
                .unwrap_or_default());
        }
        if let Some(date) = date {
            add(self
                .dated
                .iter()
                .filter(|(_, d)| (*d - date).abs() <= 10.0)
                .map(|(i, _)| *i)
                .collect());
        }
        for (band, key) in keys.into_iter().enumerate() {
            let base = (band as u32) << 16;
            add(self
                .buckets
                .get(&(base | u32::from(key)))
                .map(|v| v.iter().copied().collect())
                .unwrap_or_default());
            for bit in 0..16 {
                add(self
                    .buckets
                    .get(&(base | u32::from(key ^ (1 << bit))))
                    .map(|v| v.iter().copied().collect())
                    .unwrap_or_default());
            }
        }
        Ok(result)
    }
    pub fn insert(
        &mut self,
        keys: [u16; 4],
        burst: Option<&str>,
        date: Option<f64>,
        index: usize,
    ) -> Result<(), CoreError> {
        validate_date(date)?;
        if burst.is_some_and(|v| v.len() > 8192) {
            return Err(CoreError::InvalidValue);
        }
        for (band, key) in keys.into_iter().enumerate() {
            let values = self
                .buckets
                .entry(((band as u32) << 16) | u32::from(key))
                .or_default();
            values.push_back(index);
            if values.len() > CANDIDATE_LIMIT {
                values.pop_front();
            }
        }
        if let Some(burst) = burst {
            let values = self.bursts.entry(burst.into()).or_default();
            values.push_back(index);
            if values.len() > 32 {
                values.pop_front();
            }
        }
        if let Some(date) = date {
            self.dated.push_back((index, date));
            if self.dated.len() > 16 {
                self.dated.pop_front();
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub struct SceneAsset {
    pub id: AssetId,
    pub revision: String,
    pub provider: SceneProvider,
    pub quality: SceneQuality,
    pub keys: [u16; 4],
    pub width: u32,
    pub height: u32,
    pub bit_depth: u16,
    pub wide_color: bool,
    pub edge_detail: f64,
    pub associated_resources: bool,
    pub native_identity: Option<String>,
    pub burst: Option<String>,
    pub date: Option<f64>,
}
impl SceneAsset {
    fn validate(&self) -> Result<(), CoreError> {
        self.id.validate()?;
        self.provider.validate()?;
        self.quality.validate()?;
        validate_date(self.date)?;
        if self.revision.len() > 8192
            || self.width == 0
            || self.height == 0
            || u64::from(self.width) * u64::from(self.height) > crate::model::MAX_SOURCE_PIXELS
            || self.bit_depth == 0
            || self.bit_depth > 64
            || !self.edge_detail.is_finite()
            || self.edge_detail < 0.0
            || self.burst.as_ref().is_some_and(|v| v.len() > 8192)
            || self
                .native_identity
                .as_ref()
                .is_some_and(|v| v.is_empty() || v.len() > 4096)
        {
            return Err(CoreError::InvalidValue);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Recommendation {
    AssociatedResources,
    FocusSignal,
    ExposureSignal,
    SourcePreference,
}
#[derive(serde::Serialize, serde::Deserialize, Clone, Debug, PartialEq)]
pub struct SceneEdge {
    pub first: AssetId,
    pub second: AssetId,
    pub distance: f32,
    pub shared_burst: bool,
}
#[derive(Clone, Debug, PartialEq)]
pub struct SceneGroup {
    pub members: Vec<AssetId>,
    pub edges: Vec<SceneEdge>,
    pub recommended: Option<AssetId>,
    pub reason: Option<Recommendation>,
}
#[derive(Clone, Debug)]
pub struct DistanceRequest {
    pub task_id: u64,
    pub first: AssetId,
    pub first_revision: String,
    pub second: AssetId,
    pub second_revision: String,
}
#[derive(Clone, Debug)]
pub struct SceneWork {
    pub request: Option<DistanceRequest>,
    pub completed: usize,
    pub total: usize,
}

pub struct SceneSession {
    pub(crate) operation: String,
    pub(crate) items: Vec<SceneAsset>,
    pub(crate) provider: SceneProvider,
    pub(crate) sides: Option<(String, String)>,
    pub(crate) preferred_source: Option<String>,
    cancel: Arc<Cancellation>,
    preparing: bool,
    index: SceneIndex,
    cursor: usize,
    nearby: Option<Vec<usize>>,
    candidate: usize,
    distances: HashMap<usize, f32>,
    assigned: HashMap<usize, usize>,
    members: Vec<Vec<usize>>,
    edges: Vec<Vec<SceneEdge>>,
    pending: Option<(DistanceRequest, usize)>,
    next_task: u64,
    seen: HashSet<AssetId>,
    final_required: Option<Vec<(AssetId, String)>>,
    final_validated: HashMap<AssetId, bool>,
}
impl SceneSession {
    pub fn new(
        operation: String,
        provider: SceneProvider,
        sides: Option<(String, String)>,
        preferred_source: Option<String>,
        cancel: Arc<Cancellation>,
    ) -> Result<Self, CoreError> {
        provider.validate()?;
        if operation.is_empty()
            || operation.len() > 256
            || sides
                .as_ref()
                .is_some_and(|(a, b)| a.is_empty() || b.is_empty() || a == b)
        {
            return Err(CoreError::InvalidValue);
        }
        Ok(Self {
            operation,
            items: Vec::new(),
            provider,
            sides,
            preferred_source,
            cancel,
            preparing: true,
            index: SceneIndex::default(),
            cursor: 0,
            nearby: None,
            candidate: 0,
            distances: HashMap::new(),
            assigned: HashMap::new(),
            members: Vec::new(),
            edges: Vec::new(),
            pending: None,
            next_task: 1,
            seen: HashSet::new(),
            final_required: None,
            final_validated: HashMap::new(),
        })
    }
    pub fn append(&mut self, items: Vec<SceneAsset>) -> Result<(), CoreError> {
        self.cancel.check()?;
        if !self.preparing {
            return Err(CoreError::InvalidState);
        }
        if items.is_empty() || items.len() > 16 {
            return Err(CoreError::InvalidValue);
        }
        let mut batch = HashSet::new();
        for item in &items {
            item.validate()?;
            if item.provider != self.provider
                || self.seen.contains(&item.id)
                || !batch.insert(item.id.clone())
                || self
                    .sides
                    .as_ref()
                    .is_some_and(|(a, b)| item.id.source_id != *a && item.id.source_id != *b)
            {
                return Err(CoreError::InvalidValue);
            }
        }
        self.seen.extend(batch);
        self.items.extend(items);
        Ok(())
    }
    pub fn complete_preparation(&mut self) -> Result<(), CoreError> {
        self.cancel.check()?;
        if !self.preparing {
            return Err(CoreError::InvalidState);
        }
        self.items.sort_by(|a, b| match (a.date, b.date) {
            (Some(a), Some(b)) if a != b => a.total_cmp(&b),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            _ => a.id.cmp(&b.id),
        });
        self.preparing = false;
        Ok(())
    }
    fn cross(&self, a: usize, b: usize) -> bool {
        self.sides.as_ref().is_none_or(|(left, right)| {
            let a = &self.items[a].id.source_id;
            let b = &self.items[b].id.source_id;
            (a == left && b == right) || (a == right && b == left)
        })
    }
    fn edge(&self, other: usize) -> Result<Option<bool>, CoreError> {
        let a = &self.items[self.cursor];
        let b = &self.items[other];
        if a.id == b.id
            || a.native_identity
                .as_ref()
                .is_some_and(|v| Some(v) == b.native_identity.as_ref())
        {
            return Ok(Some(false));
        }
        let burst = a
            .burst
            .as_ref()
            .is_some_and(|v| !v.is_empty() && Some(v) == b.burst.as_ref());
        if !burst && (a.quality.texture_variance < 0.0004 || b.quality.texture_variance < 0.0004) {
            return Ok(Some(false));
        }
        self.distances
            .get(&other)
            .map(|distance| matches(a.quality, b.quality, burst, *distance))
            .transpose()
    }
    fn request(&mut self, other: usize) -> SceneWork {
        let a = &self.items[self.cursor];
        let b = &self.items[other];
        let request = DistanceRequest {
            task_id: self.next_task,
            first: a.id.clone(),
            first_revision: a.revision.clone(),
            second: b.id.clone(),
            second_revision: b.revision.clone(),
        };
        self.next_task += 1;
        self.pending = Some((request.clone(), other));
        SceneWork {
            request: Some(request),
            completed: self.cursor,
            total: self.items.len(),
        }
    }
    fn evidence(&self, other: usize) -> SceneEdge {
        let a = &self.items[self.cursor];
        let b = &self.items[other];
        SceneEdge {
            first: a.id.clone(),
            second: b.id.clone(),
            distance: self.distances[&other],
            shared_burst: a
                .burst
                .as_ref()
                .is_some_and(|v| !v.is_empty() && Some(v) == b.burst.as_ref()),
        }
    }
    pub fn next_work(&mut self) -> Result<SceneWork, CoreError> {
        self.cancel.check()?;
        if self.preparing {
            return Err(CoreError::InvalidState);
        }
        if let Some((request, _)) = &self.pending {
            return Ok(SceneWork {
                request: Some(request.clone()),
                completed: self.cursor,
                total: self.items.len(),
            });
        }
        while self.cursor < self.items.len() {
            self.cancel.check()?;
            if self.nearby.is_none() {
                let item = &self.items[self.cursor];
                self.nearby = Some(self.index.candidates(
                    item.keys,
                    item.burst.as_deref(),
                    item.date,
                )?);
            }
            let nearby = self.nearby.as_ref().unwrap();
            if self.candidate < nearby.len() {
                let candidate = nearby[self.candidate];
                if !self.cross(self.cursor, candidate) {
                    self.candidate += 1;
                    continue;
                }
                match self.edge(candidate)? {
                    None => return Ok(self.request(candidate)),
                    Some(false) => {
                        self.candidate += 1;
                        continue;
                    }
                    Some(true) => {}
                }
                if let Some(group) = self.assigned.get(&candidate).copied() {
                    if self.members[group].len() >= MEMBER_LIMIT {
                        self.candidate += 1;
                        continue;
                    }
                    let mut actual = Vec::new();
                    let mut consistent = true;
                    for member in &self.members[group] {
                        match self.edge(*member)? {
                            None => return Ok(self.request(*member)),
                            Some(false) => {
                                consistent = false;
                                break;
                            }
                            Some(true) => {
                                if self.cross(self.cursor, *member) {
                                    actual.push(self.evidence(*member));
                                }
                            }
                        }
                    }
                    if !consistent || actual.is_empty() {
                        self.candidate += 1;
                        continue;
                    }
                    self.members[group].push(self.cursor);
                    self.edges[group].extend(actual);
                    self.assigned.insert(self.cursor, group);
                } else {
                    let group = self.members.len();
                    self.members.push(vec![candidate, self.cursor]);
                    self.edges.push(vec![self.evidence(candidate)]);
                    self.assigned.insert(candidate, group);
                    self.assigned.insert(self.cursor, group);
                }
            } else {
                self.finish_item()?;
                continue;
            }
            self.finish_item()?;
        }
        Ok(SceneWork {
            request: None,
            completed: self.cursor,
            total: self.items.len(),
        })
    }
    fn finish_item(&mut self) -> Result<(), CoreError> {
        let item = &self.items[self.cursor];
        self.index
            .insert(item.keys, item.burst.as_deref(), item.date, self.cursor)?;
        self.cursor += 1;
        self.candidate = 0;
        self.nearby = None;
        self.distances.clear();
        Ok(())
    }
    pub fn submit(&mut self, operation: &str, task: u64, distance: f32) -> Result<(), CoreError> {
        self.cancel.check()?;
        if operation != self.operation
            || self.pending.as_ref().is_none_or(|(r, _)| r.task_id != task)
        {
            return Err(CoreError::StaleOperation);
        }
        if !distance.is_finite() || distance < 0.0 {
            return Err(CoreError::InvalidValue);
        }
        let (_, other) = self.pending.take().unwrap();
        self.distances.insert(other, distance);
        Ok(())
    }
    fn prepare_final_validation(&mut self) -> Result<(), CoreError> {
        self.cancel.check()?;
        if self.preparing || self.cursor != self.items.len() || self.pending.is_some() {
            return Err(CoreError::InvalidState);
        }
        if self.final_required.is_none() {
            let mut required: Vec<_> = self
                .members
                .iter()
                .flatten()
                .map(|index| {
                    let item = &self.items[*index];
                    (item.id.clone(), item.revision.clone())
                })
                .collect();
            required.sort_by(|a, b| a.0.cmp(&b.0));
            required.dedup_by(|a, b| a.0 == b.0);
            self.final_required = Some(required);
        }
        Ok(())
    }

    pub fn final_validation_page(
        &mut self,
        offset: usize,
        limit: usize,
    ) -> Result<Vec<AssetId>, CoreError> {
        if limit == 0 || limit > crate::scan::MAX_BATCH_SIZE {
            return Err(CoreError::InvalidBuffer);
        }
        self.prepare_final_validation()?;
        let required = self
            .final_required
            .as_ref()
            .ok_or(CoreError::InvalidState)?;
        Ok(required
            .get(offset..)
            .unwrap_or_default()
            .iter()
            .take(limit)
            .map(|(id, _)| id.clone())
            .collect())
    }

    pub fn submit_final_validations(
        &mut self,
        operation: &str,
        validations: Vec<crate::scan::AssetValidation>,
    ) -> Result<(), CoreError> {
        self.cancel.check()?;
        if operation != self.operation {
            return Err(CoreError::StaleOperation);
        }
        if validations.len() > crate::scan::MAX_BATCH_SIZE {
            return Err(CoreError::InvalidBuffer);
        }
        self.prepare_final_validation()?;
        let required = self
            .final_required
            .as_ref()
            .ok_or(CoreError::InvalidState)?;
        let mut seen = HashSet::new();
        let mut checked = Vec::with_capacity(validations.len());
        for validation in validations {
            self.cancel.check()?;
            if self.final_validated.contains_key(&validation.id)
                || !seen.insert(validation.id.clone())
            {
                return Err(CoreError::InvalidValue);
            }
            let index = required
                .binary_search_by(|(id, _)| id.cmp(&validation.id))
                .map_err(|_| CoreError::InvalidValue)?;
            let valid =
                validation.accessible && validation.revision.as_ref() == Some(&required[index].1);
            checked.push((validation.id, valid));
        }
        self.cancel.check()?;
        self.final_validated.extend(checked);
        Ok(())
    }

    pub(crate) fn validate_for_review(&self) -> Result<(), CoreError> {
        self.cancel.check()?;
        let required = self
            .final_required
            .as_ref()
            .ok_or(CoreError::InvalidState)?;
        if required.len() != self.final_validated.len() {
            return Err(CoreError::InvalidState);
        }
        if self.final_validated.values().any(|valid| !valid) {
            return Err(CoreError::StaleOperation);
        }
        Ok(())
    }

    pub fn groups(&self) -> Result<Vec<SceneGroup>, CoreError> {
        self.cancel.check()?;
        if self.preparing || self.cursor != self.items.len() || self.pending.is_some() {
            return Err(CoreError::InvalidState);
        }
        let mut result = Vec::new();
        for (index, members) in self.members.iter().enumerate() {
            self.cancel.check()?;
            let recommendation = members
                .iter()
                .find_map(|candidate| {
                    recommend(
                        &self.items[*candidate],
                        members
                            .iter()
                            .filter(|other| *other != candidate)
                            .map(|i| &self.items[*i]),
                    )
                    .map(|reason| (*candidate, reason))
                })
                .or_else(|| {
                    let reference = &self.items[members[0]];
                    members
                        .iter()
                        .find(|candidate| {
                            let item = &self.items[**candidate];
                            self.preferred_source.as_ref() == Some(&item.id.source_id)
                                && quality_tied(reference, item)
                                && reference.quality == item.quality
                        })
                        .map(|i| (*i, Recommendation::SourcePreference))
                });
            result.push(SceneGroup {
                members: members.iter().map(|i| self.items[*i].id.clone()).collect(),
                edges: self.edges[index].clone(),
                recommended: recommendation.map(|(i, _)| self.items[i].id.clone()),
                reason: recommendation.map(|(_, r)| r),
            });
        }
        Ok(result)
    }
}

fn quality_tied(a: &SceneAsset, b: &SceneAsset) -> bool {
    a.associated_resources == b.associated_resources
        && u64::from(a.width) * u64::from(a.height) == u64::from(b.width) * u64::from(b.height)
        && a.bit_depth == b.bit_depth
        && a.wide_color == b.wide_color
        && a.edge_detail == b.edge_detail
}
fn recommend<'a>(
    item: &SceneAsset,
    others: impl Iterator<Item = &'a SceneAsset>,
) -> Option<Recommendation> {
    let others: Vec<_> = others.collect();
    if item.associated_resources && others.iter().all(|other| !other.associated_resources) {
        return Some(Recommendation::AssociatedResources);
    }
    if !others.iter().all(|other| {
        (f64::from(other.width) / f64::from(other.height)
            - f64::from(item.width) / f64::from(item.height))
        .abs()
            < 0.01
            && other.width == item.width
            && other.height == item.height
    }) {
        return None;
    }
    let quality = item.quality;
    let clipping = quality.dark_clipping + quality.bright_clipping;
    if quality.focus_energy >= 0.002
        && others.iter().all(|other| {
            let q = other.quality;
            quality.focus_energy >= 1.6 * q.focus_energy
                && quality.focus_energy - q.focus_energy >= 0.002
                && (quality.mean_luminance - q.mean_luminance).abs() <= 0.1
                && (clipping - q.dark_clipping - q.bright_clipping).abs() <= 0.05
        })
    {
        return Some(Recommendation::FocusSignal);
    }
    if (0.2..=0.8).contains(&quality.mean_luminance)
        && others.iter().all(|other| {
            let q = other.quality;
            q.dark_clipping + q.bright_clipping - clipping >= 0.15
                && quality.focus_energy >= 0.9 * q.focus_energy
        })
    {
        return Some(Recommendation::ExposureSignal);
    }
    None
}
