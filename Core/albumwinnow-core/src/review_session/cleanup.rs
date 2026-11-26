use super::*;
use crate::cleanup::{
    CleanupPlan, CleanupReason, PairFacts, PlanGroup, RemovalFacts,
    run::{CleanupItemKey, CleanupItemResult, CleanupOutcome, CleanupRun, CleanupTicket},
};

impl ReviewSession {
    fn validate_cleanup_operation(&self, operation: &str) -> Result<(), CleanupReason> {
        let run = self
            .cleanup
            .as_ref()
            .filter(|r| r.plan().operation == operation)
            .ok_or(CleanupReason::StalePlan)?;
        if run.cancelled() {
            return Err(CleanupReason::Cancelled);
        }
        if run.busy() {
            return Err(CleanupReason::OperationInProgress);
        }
        run.plan().check_epochs(&self.metadata)
    }
    fn validate_cleanup_capture_dates<'a>(
        &self,
        assets: impl IntoIterator<Item = &'a ReviewAsset>,
    ) -> Result<(), CleanupReason> {
        if let Some(range) = &self.settings.photo_scope.dates {
            for asset in assets {
                if asset.kind == SourceKind::PhotoLibrary
                    && !range
                        .contains(asset.capture_date)
                        .map_err(|_| CleanupReason::ChangedAsset)?
                {
                    return Err(CleanupReason::ChangedAsset);
                }
            }
        }
        Ok(())
    }
    pub fn start_cleanup(&mut self, expected: u64) -> Result<String, CoreError> {
        self.ensure_editable()?;
        if expected != self.metadata.revision {
            return Err(CoreError::StaleOperation);
        }
        if self
            .cleanup
            .as_ref()
            .is_some_and(|run| !run.outcomes().is_empty())
        {
            return Err(CoreError::InvalidState);
        }
        let result = self.store.new_cleanup_operation();
        let operation = self.storage_result(result)?;
        let mut groups: Vec<_> = self.groups.values().filter(|g| g.active).collect();
        groups.sort_by_key(|g| g.ordinal);
        let inputs = groups.into_iter().map(|g| PlanGroup {
            signature: &g.signature,
            group: &g.group,
            decision: self.decisions.get(&g.signature).map(|d| &d.decision),
        });
        let plan = CleanupPlan::build(
            operation.clone(),
            &self.metadata,
            inputs,
            self.sources.values(),
            &self.protection,
        )?;
        if plan.item_count() == 0 {
            return Err(CoreError::InvalidValue);
        }
        self.cleanup = Some(CleanupRun::new(plan));
        self.last_cleanup.clear();
        self.last_cleanup_operation = None;
        Ok(operation)
    }
    pub fn cleanup_progress(&self, operation: &str) -> Option<(usize, bool, bool)> {
        self.cleanup
            .as_ref()
            .filter(|run| run.plan().operation == operation)
            .map(|run| (run.outcomes().len(), run.cancelled(), run.busy()))
    }
    pub fn cleanup_plan(&self) -> Option<&CleanupPlan> {
        self.cleanup.as_ref().map(CleanupRun::plan)
    }
    pub fn last_cleanup_results(&self) -> &[CleanupItemResult] {
        &self.last_cleanup
    }
    pub fn last_cleanup_operation(&self) -> Option<&str> {
        self.last_cleanup_operation.as_deref()
    }
    pub fn current_cleanup_results(
        &self,
        operation: &str,
        offset: usize,
        limit: usize,
    ) -> Result<Vec<CleanupItemResult>, CleanupReason> {
        if limit > 256 {
            return Err(CleanupReason::InvalidSelection);
        }
        let run = self
            .cleanup
            .as_ref()
            .filter(|r| r.plan().operation == operation)
            .ok_or(CleanupReason::StalePlan)?;
        Ok(run
            .outcomes()
            .iter()
            .skip(offset)
            .take(limit)
            .map(|(key, outcome)| CleanupItemResult {
                key: *key,
                pair: run.plan().groups[key.group].pairs[key.pair].clone(),
                outcome: *outcome,
            })
            .collect())
    }
    pub fn begin_cleanup_preflight(
        &mut self,
        operation: &str,
        group: usize,
    ) -> Result<(), CleanupReason> {
        self.ensure_healthy()
            .map_err(|_| CleanupReason::UnavailableProtection)?;
        self.cleanup
            .as_mut()
            .filter(|r| r.plan().operation == operation)
            .ok_or(CleanupReason::StalePlan)?
            .begin_whole_preflight(group, &self.metadata)
    }
    pub fn append_cleanup_preflight(
        &mut self,
        operation: &str,
        group: usize,
        facts: &[RemovalFacts],
    ) -> Result<(), CleanupReason> {
        self.ensure_healthy()
            .map_err(|_| CleanupReason::UnavailableProtection)?;
        self.validate_cleanup_operation(operation)?;
        self.validate_cleanup_capture_dates(facts.iter().map(|f| &f.asset))?;
        self.cleanup
            .as_mut()
            .filter(|r| r.plan().operation == operation)
            .ok_or(CleanupReason::StalePlan)?
            .append_whole_preflight(group, facts, &self.metadata, &self.protection)
    }
    pub fn finish_cleanup_preflight(
        &mut self,
        operation: &str,
        group: usize,
    ) -> Result<(), CleanupReason> {
        self.ensure_healthy()
            .map_err(|_| CleanupReason::UnavailableProtection)?;
        self.cleanup
            .as_mut()
            .filter(|r| r.plan().operation == operation)
            .ok_or(CleanupReason::StalePlan)?
            .finish_whole_preflight(group, &self.metadata)
    }
    pub fn preflight_cleanup_group(
        &mut self,
        operation: &str,
        group: usize,
        facts: &[RemovalFacts],
    ) -> Result<(), CleanupReason> {
        self.begin_cleanup_preflight(operation, group)?;
        for batch in facts.chunks(16) {
            self.append_cleanup_preflight(operation, group, batch)?;
        }
        self.finish_cleanup_preflight(operation, group)
    }
    pub fn authorize_cleanup(
        &mut self,
        operation: &str,
        items: &[(CleanupItemKey, PairFacts)],
    ) -> Result<CleanupTicket, CleanupReason> {
        self.ensure_healthy()
            .map_err(|_| CleanupReason::UnavailableProtection)?;
        self.validate_cleanup_operation(operation)?;
        self.validate_cleanup_capture_dates(items.iter().flat_map(|(_, f)| {
            std::iter::once(&f.remove.asset).chain(f.keep.iter().map(|k| &k.asset))
        }))?;
        let run = self
            .cleanup
            .as_mut()
            .filter(|r| r.plan().operation == operation)
            .ok_or(CleanupReason::StalePlan)?;
        run.authorize(items, &self.metadata, &self.protection)
    }
    pub fn validate_cleanup_ticket(&mut self, ticket: &CleanupTicket) -> Result<(), CleanupReason> {
        self.ensure_healthy()
            .map_err(|_| CleanupReason::UnavailableProtection)?;
        self.cleanup
            .as_ref()
            .ok_or(CleanupReason::StalePlan)?
            .validate_ticket(ticket, &self.metadata)
    }
    pub fn report_cleanup(
        &mut self,
        ticket: &CleanupTicket,
        outcomes: Vec<CleanupOutcome>,
    ) -> Result<bool, CleanupReason> {
        // Reporting a completed OS operation grants no new authority, even if
        // the backing store failed after the OS moved the resource.
        self.cleanup
            .as_mut()
            .ok_or(CleanupReason::StalePlan)?
            .report(ticket, outcomes)
    }
    pub fn skip_cleanup_item(
        &mut self,
        operation: &str,
        key: CleanupItemKey,
        reason: CleanupReason,
    ) -> Result<(), CleanupReason> {
        self.cleanup
            .as_mut()
            .filter(|r| r.plan().operation == operation)
            .ok_or(CleanupReason::StalePlan)?
            .skip(key, reason)
    }
    pub fn cancel_cleanup(&mut self, operation: &str) -> Result<(), CleanupReason> {
        self.cleanup
            .as_mut()
            .filter(|r| r.plan().operation == operation)
            .ok_or(CleanupReason::StalePlan)?
            .cancel();
        Ok(())
    }
    pub fn fail_cleanup_item(
        &mut self,
        operation: &str,
        key: CleanupItemKey,
    ) -> Result<(), CleanupReason> {
        self.cleanup
            .as_mut()
            .filter(|r| r.plan().operation == operation)
            .ok_or(CleanupReason::StalePlan)?
            .fail(key)
    }
    pub fn finish_cleanup(&mut self, operation: &str) -> Result<&[CleanupItemResult], CoreError> {
        self.ensure_editable()?;
        let run = self
            .cleanup
            .as_ref()
            .filter(|r| r.plan().operation == operation)
            .ok_or(CoreError::StaleOperation)?;
        let results = run.results().map_err(|_| CoreError::InvalidState)?;
        let moved = results
            .iter()
            .filter(|r| r.outcome.moved())
            .map(|r| r.pair.remove.id.clone())
            .collect();
        let result = self.store.complete_cleanup(self.metadata.revision, &moved);
        let committed = self.storage_result(result)?;
        for signature in committed.removed_decisions {
            self.decisions.remove(&signature);
        }
        if !moved.is_empty() {
            self.groups.retain(|signature, g| {
                g.active = false;
                self.decisions.contains_key(signature)
            });
            self.query_order = None;
        }
        self.metadata = committed.metadata;
        self.cleanup = None;
        self.last_cleanup = results;
        self.last_cleanup_operation = Some(operation.into());
        Ok(&self.last_cleanup)
    }
}
