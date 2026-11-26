use crate::{
    Cancellation, CoreError,
    candidate::CandidateIndex,
    matching::{Fingerprint, MatchKind, is_visual_candidate},
    model::AssetId,
};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

pub const MAX_BATCH_SIZE: usize = 16;

#[derive(Clone, Debug)]
pub struct ScanItem {
    pub id: AssetId,
    pub fingerprint: Fingerprint,
    pub revision: String,
    pub associated_resources: bool,
    /// Namespaced, opaque native identity. No path or revision parsing in Rust.
    pub native_identity: Option<String>,
}

impl ScanItem {
    pub fn validate(&self) -> Result<(), CoreError> {
        self.id.validate()?;
        self.fingerprint.validate()?;
        if self.revision.len() > 8192
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

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ComparisonSides {
    pub first: String,
    pub second: String,
}

impl ComparisonSides {
    fn permits(&self, a: &AssetId, b: &AssetId) -> bool {
        (a.source_id == self.first && b.source_id == self.second)
            || (a.source_id == self.second && b.source_id == self.first)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairTask {
    pub task_id: u64,
    pub first: AssetId,
    pub second: AssetId,
    pub exact_identity: bool,
    pub first_revision: String,
    pub second_revision: String,
}

#[derive(Clone, Debug)]
pub struct ScanBatch {
    pub batch_id: u64,
    pub tasks: Vec<PairTask>,
    pub completed: usize,
    pub total: usize,
    pub done: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VerificationOutcome {
    Matched(MatchKind),
    Failed(AssetId),
}

#[derive(Clone, Debug)]
pub struct AssetValidation {
    pub id: AssetId,
    pub accessible: bool,
    pub revision: Option<String>,
}

#[derive(Clone, Debug)]
pub struct TaskResult {
    pub task_id: u64,
    pub outcome: VerificationOutcome,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MatchEdge {
    pub first: AssetId,
    pub second: AssetId,
    pub kind: MatchKind,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DetectedGroup {
    pub preferred: AssetId,
    pub duplicates: Vec<(AssetId, MatchKind)>,
    pub edges: Option<Vec<MatchEdge>>,
    pub recommended: Option<AssetId>,
}

struct PendingTask {
    request: PairTask,
    first: usize,
    second: usize,
    result: Option<VerificationOutcome>,
}

struct PendingBatch {
    id: u64,
    tasks: Vec<PendingTask>,
}

struct MatchingState {
    items: Vec<ScanItem>,
    lookup: Vec<usize>,
    cohorts: HashMap<usize, Vec<usize>>,
    index: CandidateIndex,
    cursor: usize,
    representative: Option<usize>,
    candidates: Vec<usize>,
    next_candidate: usize,
    assigned: HashSet<usize>,
    current_members: Vec<(usize, MatchKind)>,
    groups: Vec<DetectedGroup>,
    edges: Vec<(usize, usize, MatchKind)>,
    failed: HashSet<AssetId>,
    pending: Option<PendingBatch>,
    next_batch_id: u64,
    next_task_id: u64,
    done: bool,
    final_required: BTreeMap<AssetId, String>,
    final_order: Vec<AssetId>,
    final_validated: HashSet<AssetId>,
    scene_candidates: Option<Vec<AssetId>>,
}

pub struct ScanSession {
    pub(crate) operation_id: String,
    pub(crate) source_ids: HashSet<String>,
    pub(crate) sides: Option<ComparisonSides>,
    pub(crate) preferred_source: Option<String>,
    prepared: Vec<ScanItem>,
    prepared_ids: HashSet<AssetId>,
    matching: Option<MatchingState>,
}

impl ScanSession {
    pub(crate) fn review_items(&self) -> Result<&[ScanItem], CoreError> {
        Ok(&self.matching.as_ref().ok_or(CoreError::InvalidState)?.items)
    }

    pub fn new(
        operation_id: String,
        source_ids: Vec<String>,
        sides: Option<ComparisonSides>,
        preferred_source: Option<String>,
    ) -> Result<Self, CoreError> {
        let sources: HashSet<_> = source_ids.iter().cloned().collect();
        if operation_id.is_empty()
            || operation_id.len() > 128
            || sources.len() != source_ids.len()
            || sources
                .iter()
                .any(|source| source.is_empty() || source.len() > 4096)
            || preferred_source
                .as_ref()
                .is_some_and(|source| source.is_empty() || source.len() > 4096)
            || sides.as_ref().is_some_and(|s| {
                s.first == s.second || !sources.contains(&s.first) || !sources.contains(&s.second)
            })
        {
            return Err(CoreError::InvalidValue);
        }
        Ok(Self {
            operation_id,
            source_ids: sources,
            sides,
            preferred_source,
            prepared: Vec::new(),
            prepared_ids: HashSet::new(),
            matching: None,
        })
    }

    pub fn append_prepared(
        &mut self,
        items: Vec<ScanItem>,
        cancel: &Cancellation,
    ) -> Result<(), CoreError> {
        cancel.check()?;
        if self.matching.is_some() {
            return Err(CoreError::InvalidState);
        }
        if items.len() > MAX_BATCH_SIZE {
            return Err(CoreError::InvalidValue);
        }
        let mut ids = HashSet::new();
        for item in &items {
            cancel.check()?;
            item.validate()?;
            if !self.source_ids.contains(&item.id.source_id)
                || self.prepared_ids.contains(&item.id)
                || !ids.insert(item.id.clone())
                || self
                    .sides
                    .as_ref()
                    .is_some_and(|s| item.id.source_id != s.first && item.id.source_id != s.second)
            {
                return Err(CoreError::InvalidValue);
            }
        }
        self.prepared_ids.extend(ids);
        self.prepared.extend(items);
        Ok(())
    }

    pub fn complete_preparation(&mut self, cancel: &Cancellation) -> Result<(), CoreError> {
        cancel.check()?;
        if self.matching.is_some() {
            return Err(CoreError::InvalidState);
        }
        let mut items = std::mem::take(&mut self.prepared);
        items.sort_by(quality_order);
        let mut cohorts = HashMap::new();
        let lookup = if self.sides.is_some() {
            let mut by_key = BTreeMap::<(String, [u8; 32]), Vec<usize>>::new();
            for (index, item) in items.iter().enumerate() {
                cancel.check()?;
                by_key
                    .entry((item.id.source_id.clone(), item.fingerprint.file_hash))
                    .or_default()
                    .push(index);
            }
            let mut representatives = Vec::new();
            for members in by_key.into_values() {
                if let Some(first) = members.first() {
                    representatives.push(*first);
                    cohorts.insert(*first, members);
                }
            }
            representatives.sort_unstable();
            representatives
        } else {
            (0..items.len()).collect()
        };
        let fingerprints: Vec<_> = lookup
            .iter()
            .map(|index| items[*index].fingerprint.clone())
            .collect();
        let index = CandidateIndex::new(&fingerprints, cancel)?;
        self.matching = Some(MatchingState {
            items,
            lookup,
            cohorts,
            index,
            cursor: 0,
            representative: None,
            candidates: Vec::new(),
            next_candidate: 0,
            assigned: HashSet::new(),
            current_members: Vec::new(),
            groups: Vec::new(),
            edges: Vec::new(),
            failed: HashSet::new(),
            pending: None,
            next_batch_id: 1,
            next_task_id: 1,
            done: false,
            final_required: BTreeMap::new(),
            final_order: Vec::new(),
            final_validated: HashSet::new(),
            scene_candidates: None,
        });
        self.prepared_ids.clear();
        Ok(())
    }

    pub fn next_batch(
        &mut self,
        maximum: usize,
        cancel: &Cancellation,
    ) -> Result<ScanBatch, CoreError> {
        cancel.check()?;
        if maximum == 0 || maximum > MAX_BATCH_SIZE {
            return Err(CoreError::InvalidValue);
        }
        let state = self.matching.as_mut().ok_or(CoreError::InvalidState)?;
        if state.pending.is_some() {
            return Err(CoreError::InvalidState);
        }
        let mut tasks = Vec::new();
        while !state.done {
            cancel.check()?;
            if state.representative.is_none() {
                while state.cursor < state.lookup.len()
                    && self.sides.is_none()
                    && state.assigned.contains(&state.lookup[state.cursor])
                {
                    state.cursor += 1;
                }
                if state.cursor == state.lookup.len() {
                    state.done = true;
                    let groups = if self.sides.is_some() {
                        cross_groups(state, &self.preferred_source, cancel)?
                    } else {
                        state.groups.clone()
                    };
                    let revisions: HashMap<_, _> = state
                        .items
                        .iter()
                        .map(|item| (&item.id, &item.revision))
                        .collect();
                    for group in groups {
                        for id in std::iter::once(group.preferred)
                            .chain(group.duplicates.into_iter().map(|(id, _)| id))
                        {
                            let revision = revisions
                                .get(&id)
                                .ok_or(CoreError::InternalFailure)?
                                .to_string();
                            state.final_required.insert(id, revision);
                        }
                    }
                    state.final_order = state.final_required.keys().cloned().collect();
                    break;
                }
                let representative = state.lookup[state.cursor];
                state.candidates = state.index.candidates(
                    &state.items[representative].fingerprint,
                    state.cursor,
                    cancel,
                )?;
                state.next_candidate = 0;
                state.representative = Some(representative);
            }
            let first = state.representative.ok_or(CoreError::InternalFailure)?;
            while state.next_candidate < state.candidates.len() && tasks.len() < maximum {
                cancel.check()?;
                let second = state.lookup[state.candidates[state.next_candidate]];
                state.next_candidate += 1;
                let a = &state.items[first];
                let b = &state.items[second];
                if state.failed.contains(&a.id)
                    || state.failed.contains(&b.id)
                    || (self.sides.is_none() && state.assigned.contains(&second))
                    || self
                        .sides
                        .as_ref()
                        .is_some_and(|s| !s.permits(&a.id, &b.id))
                {
                    continue;
                }
                let exact_identity = a.fingerprint.file_hash == b.fingerprint.file_hash;
                if !exact_identity && !is_visual_candidate(&a.fingerprint, &b.fingerprint) {
                    continue;
                }
                let task_id = state.next_task_id;
                state.next_task_id = task_id.checked_add(1).ok_or(CoreError::InternalFailure)?;
                tasks.push(PendingTask {
                    request: PairTask {
                        task_id,
                        first: a.id.clone(),
                        second: b.id.clone(),
                        exact_identity,
                        first_revision: a.revision.clone(),
                        second_revision: b.revision.clone(),
                    },
                    first,
                    second,
                    result: None,
                });
            }
            if !tasks.is_empty() {
                break;
            }
            if state.next_candidate == state.candidates.len() {
                finish_representative(state, &self.sides, &self.preferred_source);
            }
        }
        let batch_id = state.next_batch_id;
        let requests = tasks.iter().map(|task| task.request.clone()).collect();
        if !tasks.is_empty() {
            state.next_batch_id = batch_id.checked_add(1).ok_or(CoreError::InternalFailure)?;
            state.pending = Some(PendingBatch {
                id: batch_id,
                tasks,
            });
        }
        Ok(ScanBatch {
            batch_id,
            tasks: requests,
            completed: state.cursor,
            total: state.lookup.len(),
            done: state.done,
        })
    }

    pub fn submit_results(
        &mut self,
        operation_id: &str,
        batch_id: u64,
        results: Vec<TaskResult>,
        cancel: &Cancellation,
    ) -> Result<(), CoreError> {
        cancel.check()?;
        if operation_id != self.operation_id {
            return Err(CoreError::StaleOperation);
        }
        if results.is_empty() || results.len() > MAX_BATCH_SIZE {
            return Err(CoreError::InvalidValue);
        }
        let state = self.matching.as_mut().ok_or(CoreError::InvalidState)?;
        let pending = state.pending.as_mut().ok_or(CoreError::StaleOperation)?;
        if pending.id != batch_id {
            return Err(CoreError::StaleOperation);
        }
        let mut accepted = Vec::new();
        let mut submitted = HashSet::new();
        for result in results {
            let index = pending
                .tasks
                .iter()
                .position(|task| task.request.task_id == result.task_id)
                .ok_or(CoreError::StaleOperation)?;
            let task = &pending.tasks[index];
            if task.result.is_some() || !submitted.insert(index) {
                return Err(CoreError::StaleOperation);
            }
            match &result.outcome {
                VerificationOutcome::Matched(MatchKind::SceneSimilar) => {
                    return Err(CoreError::InvalidValue);
                }
                VerificationOutcome::Matched(kind)
                    if task.request.exact_identity && *kind != MatchKind::ExactDuplicate =>
                {
                    return Err(CoreError::InvalidValue);
                }
                VerificationOutcome::Failed(id)
                    if id != &task.request.first && id != &task.request.second =>
                {
                    return Err(CoreError::InvalidValue);
                }
                _ => {}
            }
            accepted.push((index, result.outcome));
        }
        for (index, outcome) in accepted {
            pending.tasks[index].result = Some(outcome);
        }
        if pending.tasks.iter().any(|task| task.result.is_none()) {
            return Ok(());
        }
        let pending = state.pending.take().ok_or(CoreError::InternalFailure)?;
        for task in pending.tasks {
            cancel.check()?;
            match task.result.ok_or(CoreError::InternalFailure)? {
                VerificationOutcome::Failed(id) => {
                    state.failed.insert(id);
                }
                VerificationOutcome::Matched(kind) => {
                    if kind == MatchKind::Distinct
                        || state.failed.contains(&task.request.first)
                        || state.failed.contains(&task.request.second)
                    {
                        continue;
                    }
                    if self.sides.is_none() {
                        state.assigned.insert(task.second);
                        state.current_members.push((task.second, kind));
                    } else {
                        append_cross_edges(state, task.first, task.second, kind, cancel)?;
                    }
                }
            }
        }
        if state.next_candidate == state.candidates.len() {
            finish_representative(state, &self.sides, &self.preferred_source);
        }
        Ok(())
    }

    pub fn final_validation_ids(&self, cancel: &Cancellation) -> Result<Vec<AssetId>, CoreError> {
        cancel.check()?;
        let state = self.matching.as_ref().ok_or(CoreError::InvalidState)?;
        if !state.done || state.pending.is_some() {
            return Err(CoreError::InvalidState);
        }
        Ok(state.final_order.clone())
    }

    pub fn final_validation_page(
        &self,
        offset: usize,
        limit: usize,
        cancel: &Cancellation,
    ) -> Result<Vec<AssetId>, CoreError> {
        cancel.check()?;
        if limit == 0 || limit > MAX_BATCH_SIZE {
            return Err(CoreError::InvalidBuffer);
        }
        let state = self.matching.as_ref().ok_or(CoreError::InvalidState)?;
        if !state.done || state.pending.is_some() {
            return Err(CoreError::InvalidState);
        }
        Ok(state
            .final_order
            .get(offset..)
            .unwrap_or_default()
            .iter()
            .take(limit)
            .cloned()
            .collect())
    }

    pub fn submit_final_validations(
        &mut self,
        operation_id: &str,
        validations: Vec<AssetValidation>,
        cancel: &Cancellation,
    ) -> Result<(), CoreError> {
        cancel.check()?;
        if operation_id != self.operation_id {
            return Err(CoreError::StaleOperation);
        }
        if validations.len() > MAX_BATCH_SIZE {
            return Err(CoreError::InvalidValue);
        }
        let state = self.matching.as_mut().ok_or(CoreError::InvalidState)?;
        if !state.done || state.pending.is_some() {
            return Err(CoreError::InvalidState);
        }
        if validations
            .iter()
            .any(|v| !state.final_required.contains_key(&v.id))
        {
            return Err(CoreError::InvalidValue);
        }
        state.scene_candidates = None;
        for validation in validations {
            state.final_validated.insert(validation.id.clone());
            if !validation.accessible
                || state.final_required.get(&validation.id) != validation.revision.as_ref()
            {
                state.failed.insert(validation.id);
            }
        }
        Ok(())
    }

    /// Scene analysis excludes only members of the final, validated duplicate groups.
    /// Compute once per validation state; page reads do not rebuild the groups.
    pub fn scene_candidate_page(
        &mut self,
        offset: usize,
        limit: usize,
        cancel: &Cancellation,
    ) -> Result<Vec<AssetId>, CoreError> {
        cancel.check()?;
        if limit == 0 || limit > MAX_BATCH_SIZE {
            return Err(CoreError::InvalidBuffer);
        }
        if self
            .matching
            .as_ref()
            .ok_or(CoreError::InvalidState)?
            .scene_candidates
            .is_none()
        {
            let excluded: HashSet<_> = self
                .groups(cancel)?
                .into_iter()
                .flat_map(|group| {
                    std::iter::once(group.preferred)
                        .chain(group.duplicates.into_iter().map(|(id, _)| id))
                })
                .collect();
            let state = self.matching.as_mut().ok_or(CoreError::InvalidState)?;
            let mut candidates = Vec::new();
            for item in &state.items {
                cancel.check()?;
                if !excluded.contains(&item.id) {
                    candidates.push(item.id.clone());
                }
            }
            state.scene_candidates = Some(candidates);
        }
        let candidates = self
            .matching
            .as_ref()
            .and_then(|state| state.scene_candidates.as_ref())
            .ok_or(CoreError::InternalFailure)?;
        Ok(candidates
            .get(offset..)
            .unwrap_or_default()
            .iter()
            .take(limit)
            .cloned()
            .collect())
    }

    pub fn groups(&self, cancel: &Cancellation) -> Result<Vec<DetectedGroup>, CoreError> {
        cancel.check()?;
        let state = self.matching.as_ref().ok_or(CoreError::InvalidState)?;
        if !state.done
            || state.pending.is_some()
            || state
                .final_required
                .keys()
                .any(|id| !state.final_validated.contains(id))
        {
            return Err(CoreError::InvalidState);
        }
        if self.sides.is_some() {
            return cross_groups(state, &self.preferred_source, cancel);
        }
        let mut result = Vec::new();
        for group in &state.groups {
            cancel.check()?;
            if state.failed.contains(&group.preferred) {
                continue;
            }
            let mut group = group.clone();
            group
                .duplicates
                .retain(|(id, _)| !state.failed.contains(id));
            if group
                .recommended
                .as_ref()
                .is_some_and(|id| state.failed.contains(id))
            {
                group.recommended = None;
            }
            if !group.duplicates.is_empty() {
                result.push(group);
            }
        }
        Ok(result)
    }
}

pub fn quality_tied(a: &ScanItem, b: &ScanItem) -> bool {
    a.associated_resources == b.associated_resources
        && u64::from(a.fingerprint.width) * u64::from(a.fingerprint.height)
            == u64::from(b.fingerprint.width) * u64::from(b.fingerprint.height)
        && a.fingerprint.bit_depth == b.fingerprint.bit_depth
        && a.fingerprint.wide_color == b.fingerprint.wide_color
        && a.fingerprint.metrics.edge_detail == b.fingerprint.metrics.edge_detail
}

fn quality_order(a: &ScanItem, b: &ScanItem) -> std::cmp::Ordering {
    b.associated_resources
        .cmp(&a.associated_resources)
        .then_with(|| {
            (u64::from(b.fingerprint.width) * u64::from(b.fingerprint.height))
                .cmp(&(u64::from(a.fingerprint.width) * u64::from(a.fingerprint.height)))
        })
        .then_with(|| b.fingerprint.bit_depth.cmp(&a.fingerprint.bit_depth))
        .then_with(|| b.fingerprint.wide_color.cmp(&a.fingerprint.wide_color))
        .then_with(|| {
            if a.fingerprint.metrics.edge_detail == b.fingerprint.metrics.edge_detail {
                std::cmp::Ordering::Equal
            } else {
                b.fingerprint
                    .metrics
                    .edge_detail
                    .total_cmp(&a.fingerprint.metrics.edge_detail)
            }
        })
        .then_with(|| a.id.cmp(&b.id))
}

fn recommendation(
    state: &MatchingState,
    first: usize,
    members: &[usize],
    source: &Option<String>,
) -> Option<AssetId> {
    let source = source.as_ref()?;
    members
        .iter()
        .map(|index| &state.items[*index])
        .find(|item| item.id.source_id == *source && quality_tied(&state.items[first], item))
        .map(|item| item.id.clone())
}

fn finish_representative(
    state: &mut MatchingState,
    sides: &Option<ComparisonSides>,
    source: &Option<String>,
) {
    if let Some(first) = state.representative.take() {
        if state.failed.contains(&state.items[first].id) {
            for (index, _) in &state.current_members {
                state.assigned.remove(index);
            }
        } else if sides.is_none() && !state.current_members.is_empty() {
            let mut members = vec![first];
            members.extend(state.current_members.iter().map(|(index, _)| *index));
            state.groups.push(DetectedGroup {
                preferred: state.items[first].id.clone(),
                duplicates: state
                    .current_members
                    .iter()
                    .map(|(index, kind)| (state.items[*index].id.clone(), *kind))
                    .collect(),
                edges: None,
                recommended: recommendation(state, first, &members, source),
            });
        }
        state.current_members.clear();
        state.cursor += 1;
    }
}

fn append_cross_edges(
    state: &mut MatchingState,
    first: usize,
    second: usize,
    kind: MatchKind,
    cancel: &Cancellation,
) -> Result<(), CoreError> {
    let left = state
        .cohorts
        .get(&first)
        .cloned()
        .ok_or(CoreError::InternalFailure)?;
    let right = state
        .cohorts
        .get(&second)
        .cloned()
        .ok_or(CoreError::InternalFailure)?;
    for (a, b) in std::iter::once((first, second))
        .chain(
            left.into_iter()
                .filter(|index| *index != first)
                .map(|index| (index, second)),
        )
        .chain(
            right
                .into_iter()
                .filter(|index| *index != second)
                .map(|index| (first, index)),
        )
    {
        cancel.check()?;
        if state.failed.contains(&state.items[a].id) || state.failed.contains(&state.items[b].id) {
            continue;
        }
        if let (Some(left), Some(right)) = (
            &state.items[a].native_identity,
            &state.items[b].native_identity,
        ) && left == right
        {
            continue;
        }
        state.edges.push((a, b, kind));
    }
    Ok(())
}

fn cross_groups(
    state: &MatchingState,
    source: &Option<String>,
    cancel: &Cancellation,
) -> Result<Vec<DetectedGroup>, CoreError> {
    let mut adjacency = BTreeMap::<usize, BTreeSet<usize>>::new();
    let mut edge_indices = HashMap::<usize, Vec<usize>>::new();
    for (index, (a, b, _)) in state.edges.iter().enumerate() {
        cancel.check()?;
        if state.failed.contains(&state.items[*a].id) || state.failed.contains(&state.items[*b].id)
        {
            continue;
        }
        adjacency.entry(*a).or_default().insert(*b);
        adjacency.entry(*b).or_default().insert(*a);
        edge_indices.entry(*a).or_default().push(index);
        edge_indices.entry(*b).or_default().push(index);
    }
    let mut seen = HashSet::new();
    let mut groups = Vec::new();
    for root in adjacency.keys().copied() {
        cancel.check()?;
        if !seen.insert(root) {
            continue;
        }
        let mut members = vec![root];
        let mut component_edges = BTreeSet::<usize>::new();
        let mut cursor = 0;
        while cursor < members.len() {
            cancel.check()?;
            let current = members[cursor];
            if let Some(edges) = edge_indices.get(&current) {
                component_edges.extend(edges.iter().copied());
            }
            if let Some(neighbors) = adjacency.get(&current) {
                for member in neighbors {
                    if seen.insert(*member) {
                        members.push(*member);
                    }
                }
            }
            cursor += 1;
        }
        members.sort_unstable();
        let edges: Vec<_> = component_edges
            .into_iter()
            .map(|index| state.edges[index])
            .collect();
        let direct: HashMap<_, _> = edges
            .iter()
            .filter_map(|(a, b, kind)| {
                if *a == root {
                    Some((*b, *kind))
                } else if *b == root {
                    Some((*a, *kind))
                } else {
                    None
                }
            })
            .collect();
        groups.push(DetectedGroup {
            preferred: state.items[root].id.clone(),
            duplicates: members
                .iter()
                .copied()
                .filter(|index| *index != root)
                .map(|index| {
                    (
                        state.items[index].id.clone(),
                        direct.get(&index).copied().unwrap_or(MatchKind::Distinct),
                    )
                })
                .collect(),
            edges: Some(
                edges
                    .iter()
                    .map(|(a, b, kind)| MatchEdge {
                        first: state.items[*a].id.clone(),
                        second: state.items[*b].id.clone(),
                        kind: *kind,
                    })
                    .collect(),
            ),
            recommended: recommendation(state, root, &members, source),
        });
    }
    Ok(groups)
}
