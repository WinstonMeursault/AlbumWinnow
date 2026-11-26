use super::*;
use crate::model::AssetId;
use std::collections::BTreeSet;

impl ReviewStore {
    pub fn new_cleanup_operation(&self) -> Result<String, CoreError> {
        self.verify_current()?;
        self.connection
            .query_row(
                "SELECT 'cleanup.v2.' || lower(hex(randomblob(16)))",
                [],
                |row| row.get(0),
            )
            .map_err(corrupt)
    }
    /// One transaction at execution completion, including cancellation after
    /// partial native success. This never rewrites all decision payloads.
    pub fn complete_cleanup(
        &mut self,
        expected_revision: u64,
        moved: &BTreeSet<AssetId>,
    ) -> Result<CleanupCommit, CoreError> {
        for id in moved {
            id.validate()?;
        }
        self.verify_current()?;
        let version = self.data_version;
        let tx = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|_| CoreError::WriteFailed)?;
        let mut metadata = write_state(&tx, version, expected_revision)?;
        let mut removed_decisions = Vec::new();
        if !moved.is_empty() {
            let mut statement=tx.prepare("SELECT decisions.signature,groups.payload FROM decisions JOIN groups USING(signature)").map_err(corrupt)?;
            let mut rows = statement.query([]).map_err(corrupt)?;
            while let Some(row) = rows.next().map_err(corrupt)? {
                let group: ReviewGroup = decode(&row.get::<_, Vec<u8>>(1).map_err(corrupt)?)?;
                if group.members.iter().any(|a| moved.contains(&a.id)) {
                    removed_decisions.push(row.get::<_, String>(0).map_err(corrupt)?);
                }
            }
            drop(rows);
            drop(statement);
            for signature in &removed_decisions {
                tx.execute("DELETE FROM decisions WHERE signature=?1", [signature])
                    .map_err(|_| CoreError::WriteFailed)?;
            }
            tx.execute("UPDATE groups SET active=0 WHERE active=1", [])
                .map_err(|_| CoreError::WriteFailed)?;
            tx.execute("DELETE FROM groups WHERE active=0 AND NOT EXISTS(SELECT 1 FROM decisions WHERE decisions.signature=groups.signature)",[]).map_err(|_|CoreError::WriteFailed)?;
            metadata.revision = next(metadata.revision)?;
            metadata.decision_epoch = next(metadata.decision_epoch)?;
            metadata.decision_count = metadata
                .decision_count
                .checked_sub(removed_decisions.len() as u64)
                .ok_or(CoreError::StorageCorrupt)?;
            metadata.group_count = tx
                .query_row("SELECT count(*) FROM groups", [], |row| row.get(0))
                .map_err(corrupt)?;
            write_metadata(&tx, &metadata, None)?;
        }
        tx.commit().map_err(|_| CoreError::WriteFailed)?;
        self.verify_current()?;
        Ok(CleanupCommit {
            metadata,
            removed_decisions,
        })
    }
}
