use super::*;

impl ReviewStore {
    /// Protection edits prune saved choices in the same durable transaction.
    /// Removing protection never recreates a previously pruned removal.
    pub fn save_protection(
        &mut self,
        expected_revision: u64,
        protection: &ProtectionState,
    ) -> Result<ProtectionCommit, CoreError> {
        self.verify_current()?;
        let version = self.data_version;
        let tx = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|_| CoreError::WriteFailed)?;
        let mut metadata = write_state(&tx, version, expected_revision)?;
        let snapshot = Self::read_snapshot(&tx)?;
        let sources: BTreeMap<_, _> = snapshot.sources.iter().map(|s| (&s.id, s.kind)).collect();
        if protection
            .locks()
            .any(|asset| sources.get(&asset.id.source_id) != Some(&asset.kind))
            || protection
                .policies()
                .any(|policy| sources.get(&policy.source_id) != Some(&policy.kind))
        {
            return Err(CoreError::InvalidValue);
        }
        let unchanged = protection.locks().eq(snapshot.protection.locks())
            && protection.policies().eq(snapshot.protection.policies());
        if unchanged {
            tx.commit().map_err(|_| CoreError::WriteFailed)?;
            return Ok(ProtectionCommit {
                metadata,
                changed_decisions: Vec::new(),
            });
        }
        let groups: BTreeMap<_, _> = snapshot
            .groups
            .iter()
            .map(|stored| (&stored.signature, &stored.group))
            .collect();
        let mut changed_decisions = Vec::new();
        for stored in &snapshot.decisions {
            let group = groups
                .get(&stored.signature)
                .ok_or(CoreError::ProtectionUnavailable)?;
            let mut decision = stored.decision.clone();
            decision.prune(group, &snapshot.protection);
            decision.prune(group, protection);
            if decision != stored.decision {
                // Preserve command identity: a retry must return this pruned state.
                tx.execute(
                    "UPDATE decisions SET payload=?1 WHERE signature=?2",
                    params![encode(&decision)?, stored.signature],
                )
                .map_err(|_| CoreError::WriteFailed)?;
                changed_decisions.push((stored.signature.clone(), decision));
            }
        }
        tx.execute("DELETE FROM locks", [])
            .map_err(|_| CoreError::WriteFailed)?;
        tx.execute("DELETE FROM read_only_members", [])
            .map_err(|_| CoreError::WriteFailed)?;
        tx.execute("DELETE FROM read_only", [])
            .map_err(|_| CoreError::WriteFailed)?;
        for asset in protection.locks() {
            tx.execute(
                "INSERT INTO locks VALUES(?1,?2,?3)",
                params![asset.id.source_id, asset.id.item_id, encode(asset)?],
            )
            .map_err(|_| CoreError::WriteFailed)?;
        }
        for policy in protection.policies() {
            let header = ReadOnlyPolicy {
                source_id: policy.source_id.clone(),
                kind: policy.kind,
                snapshot_complete: policy.snapshot_complete,
                members: Vec::new(),
            };
            tx.execute(
                "INSERT INTO read_only VALUES(?1,?2)",
                params![policy.source_id, encode(&header)?],
            )
            .map_err(|_| CoreError::WriteFailed)?;
            for asset in &policy.members {
                tx.execute(
                    "INSERT INTO read_only_members VALUES(?1,?2,?3)",
                    params![asset.id.source_id, asset.id.item_id, encode(asset)?],
                )
                .map_err(|_| CoreError::WriteFailed)?;
            }
        }
        metadata.revision = next(metadata.revision)?;
        metadata.protection_epoch = next(metadata.protection_epoch)?;
        if !changed_decisions.is_empty() {
            metadata.decision_epoch = next(metadata.decision_epoch)?;
        }
        let digest = protection_digest(&tx)?;
        write_metadata(&tx, &metadata, Some(&digest))?;
        tx.commit().map_err(|_| CoreError::WriteFailed)?;
        self.verify_current()?;
        Ok(ProtectionCommit {
            metadata,
            changed_decisions,
        })
    }
}
