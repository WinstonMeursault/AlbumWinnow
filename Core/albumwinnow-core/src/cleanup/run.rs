use super::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct CleanupItemKey {
    pub group: usize,
    pub pair: usize,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CleanupTicket {
    pub operation: String,
    pub nonce: u64,
    pub items: Vec<CleanupItemKey>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CleanupOutcome {
    MovedToTrash,
    MovedToRecentlyDeleted,
    Skipped(CleanupReason),
    Failed,
}
pub struct CleanupItemResult {
    pub key: CleanupItemKey,
    pub pair: CleanupPair,
    pub outcome: CleanupOutcome,
}
impl CleanupOutcome {
    pub fn moved(self) -> bool {
        matches!(self, Self::MovedToTrash | Self::MovedToRecentlyDeleted)
    }
}

/// A single transient execution. Only a current, single-use ticket authorizes
/// native work; a pending ticket keeps state edits from racing that work.
pub struct CleanupRun {
    plan: CleanupPlan,
    preflighted: BTreeSet<usize>,
    staged_preflights: BTreeMap<usize, StagedPreflight>,
    issued: Option<CleanupTicket>,
    last_report: Option<(CleanupTicket, Vec<CleanupOutcome>)>,
    outcomes: BTreeMap<CleanupItemKey, CleanupOutcome>,
    sequence: u64,
    cancelled: bool,
}
struct StagedPreflight {
    positions: BTreeMap<crate::model::AssetId, usize>,
    seen: BTreeSet<crate::model::AssetId>,
}
impl CleanupRun {
    pub fn new(plan: CleanupPlan) -> Self {
        Self {
            plan,
            preflighted: BTreeSet::new(),
            staged_preflights: BTreeMap::new(),
            issued: None,
            last_report: None,
            outcomes: BTreeMap::new(),
            sequence: 0,
            cancelled: false,
        }
    }
    pub fn plan(&self) -> &CleanupPlan {
        &self.plan
    }
    pub fn busy(&self) -> bool {
        self.issued.is_some()
    }
    pub fn cancel(&mut self) {
        self.cancelled = true;
        self.staged_preflights.clear();
    }
    pub fn cancelled(&self) -> bool {
        self.cancelled
    }
    pub fn outcomes(&self) -> &BTreeMap<CleanupItemKey, CleanupOutcome> {
        &self.outcomes
    }
    pub fn skip(
        &mut self,
        key: CleanupItemKey,
        reason: CleanupReason,
    ) -> Result<(), CleanupReason> {
        self.record_unexecuted(key, CleanupOutcome::Skipped(reason))
    }
    pub fn fail(&mut self, key: CleanupItemKey) -> Result<(), CleanupReason> {
        self.record_unexecuted(key, CleanupOutcome::Failed)
    }
    fn record_unexecuted(
        &mut self,
        key: CleanupItemKey,
        outcome: CleanupOutcome,
    ) -> Result<(), CleanupReason> {
        if self.busy() {
            return Err(CleanupReason::OperationInProgress);
        }
        if self
            .plan
            .groups
            .get(key.group)
            .and_then(|g| g.pairs.get(key.pair))
            .is_none()
            || self.outcomes.contains_key(&key)
        {
            return Err(CleanupReason::InvalidSelection);
        }
        self.outcomes.insert(key, outcome);
        Ok(())
    }
    pub fn results(&self) -> Result<Vec<CleanupItemResult>, CleanupReason> {
        if self.busy() {
            return Err(CleanupReason::OperationInProgress);
        }
        let mut results = Vec::with_capacity(self.plan.item_count());
        for (group_index, group) in self.plan.groups.iter().enumerate() {
            for (pair_index, pair) in group.pairs.iter().enumerate() {
                let key = CleanupItemKey {
                    group: group_index,
                    pair: pair_index,
                };
                let outcome = self
                    .outcomes
                    .get(&key)
                    .copied()
                    .or_else(|| {
                        self.cancelled
                            .then_some(CleanupOutcome::Skipped(CleanupReason::Cancelled))
                    })
                    .ok_or(CleanupReason::OperationInProgress)?;
                results.push(CleanupItemResult {
                    key,
                    pair: pair.clone(),
                    outcome,
                });
            }
        }
        Ok(results)
    }
    pub fn preflight_whole_group(
        &mut self,
        group: usize,
        facts: &[RemovalFacts],
        metadata: &ReviewMetadata,
        protection: &ProtectionState,
    ) -> Result<(), CleanupReason> {
        self.begin_whole_preflight(group, metadata)?;
        for batch in facts.chunks(16) {
            self.append_whole_preflight(group, batch, metadata, protection)?;
        }
        self.finish_whole_preflight(group, metadata)
    }
    pub fn begin_whole_preflight(
        &mut self,
        group: usize,
        metadata: &ReviewMetadata,
    ) -> Result<(), CleanupReason> {
        if self.cancelled {
            return Err(CleanupReason::Cancelled);
        }
        if self.busy() {
            return Err(CleanupReason::OperationInProgress);
        }
        self.plan.check_epochs(metadata)?;
        let selected = self
            .plan
            .groups
            .get(group)
            .filter(|g| g.delete_all)
            .ok_or(CleanupReason::InvalidSelection)?;
        self.preflighted.remove(&group);
        self.staged_preflights.insert(
            group,
            StagedPreflight {
                positions: selected
                    .pairs
                    .iter()
                    .enumerate()
                    .map(|(i, p)| (p.remove.id.clone(), i))
                    .collect(),
                seen: BTreeSet::new(),
            },
        );
        Ok(())
    }
    pub fn append_whole_preflight(
        &mut self,
        group: usize,
        facts: &[RemovalFacts],
        metadata: &ReviewMetadata,
        protection: &ProtectionState,
    ) -> Result<(), CleanupReason> {
        if self.cancelled {
            return Err(CleanupReason::Cancelled);
        }
        if self.busy() {
            return Err(CleanupReason::OperationInProgress);
        }
        self.plan.check_epochs(metadata)?;
        if facts.len() > 16 {
            return Err(CleanupReason::InvalidSelection);
        }
        let staged = self
            .staged_preflights
            .get_mut(&group)
            .ok_or(CleanupReason::InvalidSelection)?;
        let mut new_ids = BTreeSet::new();
        for fact in facts {
            let position = *staged
                .positions
                .get(&fact.asset.id)
                .ok_or(CleanupReason::InvalidSelection)?;
            if staged.seen.contains(&fact.asset.id) || !new_ids.insert(fact.asset.id.clone()) {
                return Err(CleanupReason::InvalidSelection);
            }
            self.plan.resource(
                &self.plan.groups[group].pairs[position].remove,
                fact,
                true,
                protection,
            )?;
        }
        staged.seen.extend(new_ids);
        Ok(())
    }
    pub fn finish_whole_preflight(
        &mut self,
        group: usize,
        metadata: &ReviewMetadata,
    ) -> Result<(), CleanupReason> {
        if self.cancelled {
            return Err(CleanupReason::Cancelled);
        }
        if self.busy() {
            return Err(CleanupReason::OperationInProgress);
        }
        self.plan.check_epochs(metadata)?;
        let staged = self
            .staged_preflights
            .get(&group)
            .ok_or(CleanupReason::InvalidSelection)?;
        if staged.seen.len() != staged.positions.len() {
            return Err(CleanupReason::InvalidSelection);
        }
        self.staged_preflights.remove(&group);
        self.preflighted.insert(group);
        Ok(())
    }
    pub fn authorize(
        &mut self,
        items: &[(CleanupItemKey, PairFacts)],
        metadata: &ReviewMetadata,
        protection: &ProtectionState,
    ) -> Result<CleanupTicket, CleanupReason> {
        if self.cancelled {
            return Err(CleanupReason::Cancelled);
        }
        if self.busy() {
            return Err(CleanupReason::OperationInProgress);
        }
        self.plan.check_epochs(metadata)?;
        if items.is_empty() {
            return Err(CleanupReason::InvalidSelection);
        }
        let mut keys = BTreeSet::new();
        for (key, facts) in items {
            if !keys.insert(*key) || self.outcomes.contains_key(key) {
                return Err(CleanupReason::InvalidSelection);
            }
            let group = self
                .plan
                .groups
                .get(key.group)
                .ok_or(CleanupReason::InvalidSelection)?;
            if group.delete_all && !self.preflighted.contains(&key.group) {
                return Err(CleanupReason::InvalidSelection);
            }
            self.plan
                .validate_pair(key.group, key.pair, facts, metadata, protection)?;
        }
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or(CleanupReason::InvalidSelection)?;
        let ticket = CleanupTicket {
            operation: self.plan.operation.clone(),
            nonce: self.sequence,
            items: items.iter().map(|(key, _)| *key).collect(),
        };
        self.issued = Some(ticket.clone());
        Ok(ticket)
    }
    /// Native adapters call this at the final coordinated mutation boundary.
    pub fn validate_ticket(
        &self,
        ticket: &CleanupTicket,
        metadata: &ReviewMetadata,
    ) -> Result<(), CleanupReason> {
        if self.cancelled {
            return Err(CleanupReason::Cancelled);
        }
        self.plan.check_epochs(metadata)?;
        if self.issued.as_ref() != Some(ticket) {
            return Err(CleanupReason::StalePlan);
        }
        Ok(())
    }
    pub fn report(
        &mut self,
        ticket: &CleanupTicket,
        outcomes: Vec<CleanupOutcome>,
    ) -> Result<bool, CleanupReason> {
        if let Some((previous, values)) = &self.last_report
            && previous == ticket
        {
            if *values != outcomes {
                return Err(CleanupReason::InvalidSelection);
            }
            return Ok(false);
        }
        if self.issued.as_ref() != Some(ticket) {
            return Err(CleanupReason::StalePlan);
        }
        if outcomes.len() != ticket.items.len() {
            return Err(CleanupReason::InvalidSelection);
        }
        for (key, outcome) in ticket.items.iter().zip(&outcomes) {
            let pair = &self.plan.groups[key.group].pairs[key.pair];
            if matches!(outcome, CleanupOutcome::MovedToTrash)
                && pair.remove.kind == SourceKind::PhotoLibrary
                || matches!(outcome, CleanupOutcome::MovedToRecentlyDeleted)
                    && pair.remove.kind == SourceKind::FileSystem
            {
                return Err(CleanupReason::InvalidSelection);
            }
        }
        // A cancellation may arrive after the native operation succeeded. Its
        // actual outcome must still be recorded; cancellation cannot undo it.
        for (key, outcome) in ticket.items.iter().zip(&outcomes) {
            self.outcomes.insert(*key, *outcome);
        }
        self.last_report = Some((ticket.clone(), outcomes));
        self.issued = None;
        Ok(true)
    }
}
