use super::*;

impl ReviewStore {
    pub fn save_settings(
        &mut self,
        expected_revision: u64,
        settings: &ReviewSettings,
    ) -> Result<ReviewMetadata, CoreError> {
        settings.validate()?;
        self.verify_current()?;
        let version = self.data_version;
        let tx = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|_| CoreError::WriteFailed)?;
        let mut metadata = write_state(&tx, version, expected_revision)?;
        let previous: Vec<u8> = tx
            .query_row("SELECT payload FROM settings WHERE id=1", [], |row| {
                row.get(0)
            })
            .optional()
            .map_err(corrupt)?
            .ok_or(CoreError::ProtectionUnavailable)?;
        let previous: ReviewSettings = decode(&previous)?;
        if previous == *settings {
            tx.commit().map_err(|_| CoreError::WriteFailed)?;
            return Ok(metadata);
        }
        for source in settings
            .preferred_source
            .iter()
            .chain(settings.query.source.iter())
            .chain(
                settings
                    .sides
                    .iter()
                    .flat_map(|sides| [&sides.first, &sides.second]),
            )
        {
            let exists: bool = tx
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM sources WHERE id=?1)",
                    [source],
                    |row| row.get(0),
                )
                .map_err(corrupt)?;
            if !exists {
                return Err(CoreError::InvalidValue);
            }
        }
        let scope_changed = previous.similar_scenes_enabled != settings.similar_scenes_enabled
            || previous.photo_scope != settings.photo_scope
            || previous.sides != settings.sides
            || previous.preferred_source != settings.preferred_source;
        tx.execute(
            "UPDATE settings SET payload=?1 WHERE id=1",
            params![encode(settings)?],
        )
        .map_err(|_| CoreError::WriteFailed)?;
        metadata.revision = next(metadata.revision)?;
        if scope_changed {
            metadata.scope_epoch = next(metadata.scope_epoch)?;
            tx.execute("UPDATE groups SET active=0 WHERE active=1", [])
                .map_err(|_| CoreError::WriteFailed)?;
        }
        write_metadata(&tx, &metadata, None)?;
        tx.commit().map_err(|_| CoreError::WriteFailed)?;
        self.verify_current()?;
        Ok(metadata)
    }

    /// Reset review choices only; sources and protection remain authoritative.
    pub fn reset_progress(&mut self, expected_revision: u64) -> Result<ReviewMetadata, CoreError> {
        self.remove_decisions(expected_revision, false)
    }

    pub fn remove_invalid_decisions(
        &mut self,
        expected_revision: u64,
    ) -> Result<ReviewMetadata, CoreError> {
        self.remove_decisions(expected_revision, true)
    }

    fn remove_decisions(
        &mut self,
        expected_revision: u64,
        invalid_only: bool,
    ) -> Result<ReviewMetadata, CoreError> {
        self.verify_current()?;
        let version = self.data_version;
        let tx = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|_| CoreError::WriteFailed)?;
        let mut metadata = write_state(&tx, version, expected_revision)?;
        let removed = if invalid_only {
            let mut statement = tx
                .prepare("SELECT signature,payload FROM decisions")
                .map_err(corrupt)?;
            let mut rows = statement.query([]).map_err(corrupt)?;
            let mut signatures = Vec::new();
            while let Some(row) = rows.next().map_err(corrupt)? {
                let decision: ReviewDecision = decode(&row.get::<_, Vec<u8>>(1).map_err(corrupt)?)?;
                if decision.invalidated {
                    signatures.push(row.get::<_, String>(0).map_err(corrupt)?);
                }
            }
            for signature in &signatures {
                tx.execute("DELETE FROM decisions WHERE signature=?1", [signature])
                    .map_err(|_| CoreError::WriteFailed)?;
            }
            signatures.len()
        } else {
            tx.execute("DELETE FROM decisions", [])
                .map_err(|_| CoreError::WriteFailed)?
        };
        if removed > 0 || !invalid_only {
            tx.execute("DELETE FROM groups WHERE active=0 AND NOT EXISTS(SELECT 1 FROM decisions WHERE decisions.signature=groups.signature)", [])
                .map_err(|_| CoreError::WriteFailed)?;
            if !invalid_only {
                // Advance sequence so in-flight navigation cannot restore the old anchor.
                let sequence: u64 = tx
                    .query_row("SELECT sequence FROM navigation WHERE id=1", [], |row| {
                        row.get(0)
                    })
                    .optional()
                    .map_err(corrupt)?
                    .ok_or(CoreError::ProtectionUnavailable)?;
                tx.execute(
                    "UPDATE navigation SET anchor=NULL,position=NULL,sequence=?1 WHERE id=1",
                    [next(sequence)?],
                )
                .map_err(|_| CoreError::WriteFailed)?;
            }
            metadata.revision = next(metadata.revision)?;
            metadata.decision_epoch = next(metadata.decision_epoch)?;
            metadata.decision_count = metadata
                .decision_count
                .checked_sub(removed as u64)
                .ok_or(CoreError::StorageCorrupt)?;
            metadata.group_count = tx
                .query_row("SELECT count(*) FROM groups", [], |row| row.get(0))
                .map_err(corrupt)?;
            write_metadata(&tx, &metadata, None)?;
        }
        tx.commit().map_err(|_| CoreError::WriteFailed)?;
        self.verify_current()?;
        Ok(metadata)
    }
}
