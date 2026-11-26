use super::*;

impl ReviewSession {
    pub fn begin_read_only_snapshot(
        &mut self,
        expected: u64,
        operation: String,
        source: &str,
    ) -> Result<(), CoreError> {
        self.ensure_editable()?;
        if expected != self.metadata.revision {
            return Err(CoreError::StaleOperation);
        }
        if operation.is_empty() || operation.len() > 256 {
            return Err(CoreError::InvalidValue);
        }
        let source = self.sources.get(source).ok_or(CoreError::InvalidValue)?;
        self.staged_read_only = Some(StagedReadOnly {
            operation,
            revision: expected,
            policy: ReadOnlyPolicy {
                source_id: source.id.clone(),
                kind: source.kind,
                snapshot_complete: false,
                members: Vec::new(),
            },
            seen: Default::default(),
        });
        Ok(())
    }
    pub fn append_read_only_snapshot(
        &mut self,
        operation: &str,
        members: Vec<ReviewAsset>,
    ) -> Result<(), CoreError> {
        self.ensure_editable()?;
        if members.len() > 16 {
            return Err(CoreError::InvalidBuffer);
        }
        let staged = self
            .staged_read_only
            .as_mut()
            .ok_or(CoreError::InvalidState)?;
        if staged.operation != operation || staged.revision != self.metadata.revision {
            return Err(CoreError::StaleOperation);
        }
        let mut new_ids = std::collections::BTreeSet::new();
        for asset in &members {
            asset.validate()?;
            if asset.kind != staged.policy.kind
                || asset.id.source_id != staged.policy.source_id
                || staged.seen.contains(&asset.id)
                || !new_ids.insert(asset.id.clone())
            {
                return Err(CoreError::InvalidValue);
            }
        }
        staged.seen.extend(new_ids);
        staged.policy.members.extend(members);
        Ok(())
    }
    pub fn finish_read_only_snapshot(
        &mut self,
        operation: &str,
        complete: bool,
    ) -> Result<(), CoreError> {
        self.ensure_editable()?;
        let staged = self
            .staged_read_only
            .as_ref()
            .ok_or(CoreError::InvalidState)?;
        if staged.operation != operation || staged.revision != self.metadata.revision {
            return Err(CoreError::StaleOperation);
        }
        let mut staged = self
            .staged_read_only
            .take()
            .ok_or(CoreError::InvalidState)?;
        staged.policy.snapshot_complete = complete;
        let source = staged.policy.source_id.clone();
        let protection = self
            .protection
            .setting_read_only(&source, Some(staged.policy))?;
        self.commit_protection(staged.revision, protection)
    }
    pub fn discard_read_only_snapshot(&mut self, operation: &str) -> Result<(), CoreError> {
        if self
            .staged_read_only
            .as_ref()
            .is_some_and(|s| s.operation != operation)
        {
            return Err(CoreError::StaleOperation);
        }
        self.staged_read_only = None;
        Ok(())
    }
    pub fn remove_read_only(&mut self, expected: u64, source: &str) -> Result<(), CoreError> {
        self.set_read_only(expected, source, None)
    }
}
