use crate::review::SourceKind;
use crate::{
    CoreError,
    review::{
        ProtectionState, ReadOnlyPolicy, ReviewAsset, ReviewDecision, ReviewGroup, ReviewSettings,
        SourceRecord,
    },
};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Serialize, de::DeserializeOwned};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

const APPLICATION_ID: i32 = 0x41575232;
const SCHEMA: i32 = 1;
const MAX_PAYLOAD: usize = 64 * 1024 * 1024;
type DecisionRow = (Vec<u8>, Option<String>, Option<Vec<u8>>);

mod cleanup;
mod protection;
mod settings;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReviewMetadata {
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
#[derive(Clone, Debug)]
pub struct StoredGroup {
    pub signature: String,
    pub active: bool,
    pub ordinal: u64,
    pub group: ReviewGroup,
}
#[derive(Clone, Debug)]
pub struct StoredDecision {
    pub signature: String,
    pub decision: ReviewDecision,
    pub command_id: Option<String>,
    pub request_hash: Option<Vec<u8>>,
}
pub struct ReviewSnapshot {
    pub metadata: ReviewMetadata,
    pub sources: Vec<SourceRecord>,
    pub groups: Vec<StoredGroup>,
    pub decisions: Vec<StoredDecision>,
    pub protection: ProtectionState,
    pub settings: ReviewSettings,
    pub anchor: Option<String>,
    pub position: Option<u64>,
    pub navigation_sequence: u64,
}
pub struct ReviewStore {
    connection: Connection,
    _owner_lock: std::fs::File,
    owner_lock_path: PathBuf,
    owner_lock_identity: (u64, u64),
    path: PathBuf,
    file_identity: (u64, u64),
    data_version: i64,
}
fn corrupt(_: rusqlite::Error) -> CoreError {
    CoreError::StorageCorrupt
}
fn decode<T: DeserializeOwned>(bytes: &[u8]) -> Result<T, CoreError> {
    if bytes.len() > MAX_PAYLOAD {
        return Err(CoreError::StorageCorrupt);
    }
    serde_json::from_slice(bytes).map_err(|_| CoreError::StorageCorrupt)
}
fn encode<T: Serialize>(value: &T) -> Result<Vec<u8>, CoreError> {
    let data = serde_json::to_vec(value).map_err(|_| CoreError::InvalidValue)?;
    if data.len() > MAX_PAYLOAD {
        return Err(CoreError::InvalidBuffer);
    }
    Ok(data)
}
fn protection_digest(connection: &Connection) -> Result<[u8; 32], CoreError> {
    let mut hash = blake3::Hasher::new();
    hash.update(b"AlbumWinnow.v2.protection.1\0");
    for (tag, keys, query) in [
        (
            0_u8,
            1,
            "SELECT id,CASE WHEN length(payload)<=1048576 THEN payload END FROM sources ORDER BY id",
        ),
        (
            1,
            2,
            "SELECT source,item,CASE WHEN length(payload)<=1048576 THEN payload END FROM locks ORDER BY source,item",
        ),
        (
            2,
            1,
            "SELECT source,CASE WHEN length(payload)<=1048576 THEN payload END FROM read_only ORDER BY source",
        ),
        (
            3,
            2,
            "SELECT source,item,CASE WHEN length(payload)<=1048576 THEN payload END FROM read_only_members ORDER BY source,item",
        ),
    ] {
        hash.update(&[tag]);
        let mut statement = connection.prepare(query).map_err(corrupt)?;
        let mut rows = statement.query([]).map_err(corrupt)?;
        while let Some(row) = rows.next().map_err(corrupt)? {
            for index in 0..keys {
                let key: String = row.get(index).map_err(corrupt)?;
                hash.update(&(key.len() as u64).to_le_bytes());
                hash.update(key.as_bytes());
            }
            let payload: Vec<u8> = row.get(keys).map_err(corrupt)?;
            hash.update(&(payload.len() as u64).to_le_bytes());
            hash.update(&payload);
        }
    }
    Ok(*hash.finalize().as_bytes())
}
fn next(value: u64) -> Result<u64, CoreError> {
    value
        .checked_add(1)
        .filter(|value| *value <= i64::MAX as u64)
        .ok_or(CoreError::InvalidState)
}
fn read_metadata(connection: &Connection) -> Result<(ReviewMetadata, Vec<u8>), CoreError> {
    let metadata=connection.query_row("SELECT revision,scan_generation,protection_epoch,scope_epoch,decision_epoch,source_count,group_count,decision_count,scan_scope_epoch,CASE WHEN length(protection_hash)=32 THEN protection_hash END FROM meta WHERE id=1",[],|row|Ok((ReviewMetadata {
            revision:row.get(0)?,scan_generation:row.get(1)?,protection_epoch:row.get(2)?,scope_epoch:row.get(3)?,decision_epoch:row.get(4)?,source_count:row.get(5)?,group_count:row.get(6)?,decision_count:row.get(7)?,scan_scope_epoch:row.get(8)?},row.get::<_,Vec<u8>>(9)?))).optional().map_err(corrupt)?.ok_or(CoreError::ProtectionUnavailable)?;
    if metadata.0.revision == 0
        || metadata.0.protection_epoch == 0
        || metadata.0.scope_epoch == 0
        || metadata.0.decision_epoch == 0
    {
        return Err(CoreError::StorageCorrupt);
    }
    Ok(metadata)
}
fn write_metadata(
    connection: &Connection,
    metadata: &ReviewMetadata,
    digest: Option<&[u8]>,
) -> Result<(), CoreError> {
    let changed=connection.execute("UPDATE meta SET revision=?1,scan_generation=?2,protection_epoch=?3,scope_epoch=?4,decision_epoch=?5,source_count=?6,group_count=?7,decision_count=?8,scan_scope_epoch=?9,protection_hash=coalesce(?10,protection_hash) WHERE id=1",
        params![metadata.revision,metadata.scan_generation,metadata.protection_epoch,metadata.scope_epoch,metadata.decision_epoch,metadata.source_count,metadata.group_count,metadata.decision_count,metadata.scan_scope_epoch,digest]).map_err(|_|CoreError::WriteFailed)?;
    if changed != 1 {
        return Err(CoreError::ProtectionUnavailable);
    }
    Ok(())
}
fn write_state(
    connection: &Connection,
    version: i64,
    expected: u64,
) -> Result<ReviewMetadata, CoreError> {
    let current: i64 = connection
        .pragma_query_value(None, "data_version", |row| row.get(0))
        .map_err(corrupt)?;
    if current != version {
        return Err(CoreError::ProtectionUnavailable);
    }
    let metadata = read_metadata(connection)?.0;
    if metadata.revision != expected {
        return Err(CoreError::StaleOperation);
    }
    Ok(metadata)
}
pub struct SourceCommit {
    pub source: SourceRecord,
    pub metadata: ReviewMetadata,
}
pub struct DecisionCommit {
    pub metadata: ReviewMetadata,
    pub decision: ReviewDecision,
    pub replayed: bool,
}
pub struct ProtectionCommit {
    pub metadata: ReviewMetadata,
    pub changed_decisions: Vec<(String, ReviewDecision)>,
}
pub struct CleanupCommit {
    pub metadata: ReviewMetadata,
    pub removed_decisions: Vec<String>,
}
impl ReviewStore {
    #[cfg(test)]
    pub(crate) fn testing_connection(&self) -> &Connection {
        &self.connection
    }
    pub(crate) fn ensure_current(&self) -> Result<(), CoreError> {
        self.verify_current()
    }
    /// The host's independent initialized marker distinguishes a new workspace
    /// from lost protection data. This owner never reconstructs a review DB.
    pub fn open(path: &Path, initialized: bool) -> Result<Self, CoreError> {
        let exists = path
            .try_exists()
            .map_err(|_| CoreError::StorageUnavailable)?;
        if initialized && !exists {
            return Err(CoreError::ProtectionUnavailable);
        }
        if exists {
            database_identity(path)?;
        }
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|_| CoreError::StorageUnavailable)?;
        }
        // Keep the owner lock separate from SQLite's own database locks.
        let mut lock_name = path.as_os_str().to_os_string();
        lock_name.push(".owner.lock");
        let owner_lock_path = PathBuf::from(lock_name);
        if owner_lock_path
            .try_exists()
            .map_err(|_| CoreError::StorageUnavailable)?
        {
            database_identity(&owner_lock_path)?;
        }
        let owner_lock = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&owner_lock_path)
            .map_err(|_| CoreError::StorageUnavailable)?;
        owner_lock
            .try_lock()
            .map_err(|_| CoreError::ProtectionUnavailable)?;
        let owner_lock_identity = database_identity(&owner_lock_path)?;
        let mut connection = Connection::open(path).map_err(|_| CoreError::StorageUnavailable)?;
        let application: i32 = connection
            .pragma_query_value(None, "application_id", |r| r.get(0))
            .map_err(corrupt)?;
        let schema: i32 = connection
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .map_err(corrupt)?;
        let tables: i64 = connection
            .query_row(
                "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'",
                [],
                |r| r.get(0),
            )
            .map_err(corrupt)?;
        if !initialized && application == 0 && schema == 0 && tables == 0 {
            let tx = connection
                .transaction()
                .map_err(|_| CoreError::WriteFailed)?;
            tx.execute_batch("CREATE TABLE meta (id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL,scan_generation INTEGER NOT NULL,protection_epoch INTEGER NOT NULL,scope_epoch INTEGER NOT NULL,decision_epoch INTEGER NOT NULL,source_count INTEGER NOT NULL,group_count INTEGER NOT NULL,decision_count INTEGER NOT NULL,scan_scope_epoch INTEGER NOT NULL,protection_hash BLOB NOT NULL);
                CREATE TABLE sources (id TEXT PRIMARY KEY NOT NULL,payload BLOB NOT NULL) WITHOUT ROWID;
                CREATE TABLE groups (signature TEXT PRIMARY KEY NOT NULL,active INTEGER NOT NULL CHECK(active IN (0,1)),ordinal INTEGER NOT NULL,payload BLOB NOT NULL) WITHOUT ROWID;
                CREATE TABLE decisions (signature TEXT PRIMARY KEY NOT NULL REFERENCES groups(signature),payload BLOB NOT NULL,command_id TEXT UNIQUE,request_hash BLOB) WITHOUT ROWID;
                CREATE TABLE locks (source TEXT NOT NULL,item TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(source,item)) WITHOUT ROWID;
                CREATE TABLE read_only (source TEXT PRIMARY KEY NOT NULL REFERENCES sources(id),payload BLOB NOT NULL) WITHOUT ROWID;
                CREATE TABLE read_only_members (source TEXT NOT NULL REFERENCES read_only(source),item TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(source,item)) WITHOUT ROWID;
                CREATE TABLE settings (id INTEGER PRIMARY KEY CHECK(id=1),payload BLOB NOT NULL);
                CREATE TABLE navigation (id INTEGER PRIMARY KEY CHECK(id=1),anchor TEXT,position INTEGER,sequence INTEGER NOT NULL);").map_err(|_|CoreError::WriteFailed)?;
            let digest = protection_digest(&tx)?;
            tx.execute(
                "INSERT INTO meta VALUES(1,1,0,1,1,1,0,0,0,0,?1)",
                params![digest.as_slice()],
            )
            .map_err(|_| CoreError::WriteFailed)?;
            tx.execute(
                "INSERT INTO settings VALUES(1,?1)",
                params![encode(&ReviewSettings::default())?],
            )
            .map_err(|_| CoreError::WriteFailed)?;
            tx.execute("INSERT INTO navigation VALUES(1,NULL,NULL,0)", [])
                .map_err(|_| CoreError::WriteFailed)?;
            tx.pragma_update(None, "application_id", APPLICATION_ID)
                .map_err(|_| CoreError::WriteFailed)?;
            tx.pragma_update(None, "user_version", SCHEMA)
                .map_err(|_| CoreError::WriteFailed)?;
            tx.commit().map_err(|_| CoreError::WriteFailed)?;
        } else if application != APPLICATION_ID || schema != SCHEMA {
            return Err(
                if initialized && application == 0 && schema == 0 && tables == 0 {
                    CoreError::ProtectionUnavailable
                } else {
                    CoreError::UnsupportedSchema
                },
            );
        }
        connection
            .execute_batch(
                "PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA cache_size=-2048;",
            )
            .map_err(corrupt)?;
        let check: String = connection
            .query_row("PRAGMA quick_check", [], |row| row.get(0))
            .map_err(corrupt)?;
        if check != "ok" {
            return Err(CoreError::StorageCorrupt);
        }
        let file_identity = database_identity(path)?;
        {
            use std::os::unix::fs::MetadataExt;
            let owned = owner_lock
                .metadata()
                .map_err(|_| CoreError::ProtectionUnavailable)?;
            if owner_lock_identity != (owned.dev(), owned.ino()) {
                return Err(CoreError::ProtectionUnavailable);
            }
        }
        let data_version = connection
            .pragma_query_value(None, "data_version", |row| row.get(0))
            .map_err(corrupt)?;
        let mut store = Self {
            connection,
            _owner_lock: owner_lock,
            owner_lock_path,
            owner_lock_identity,
            path: path.to_path_buf(),
            file_identity,
            data_version,
        };
        store.load()?;
        store
            .connection
            .execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
            .map_err(|_| CoreError::StorageUnavailable)?;
        store.data_version = store
            .connection
            .pragma_query_value(None, "data_version", |row| row.get(0))
            .map_err(corrupt)?;
        Ok(store)
    }
    pub fn verify_current(&self) -> Result<(), CoreError> {
        if database_identity(&self.path)? != self.file_identity
            || database_identity(&self.owner_lock_path)? != self.owner_lock_identity
        {
            return Err(CoreError::ProtectionUnavailable);
        }
        let version: i64 = self
            .connection
            .pragma_query_value(None, "data_version", |row| row.get(0))
            .map_err(corrupt)?;
        if version != self.data_version {
            return Err(CoreError::ProtectionUnavailable);
        }
        Ok(())
    }
    pub fn register_source(
        &mut self,
        expected_revision: u64,
        kind: SourceKind,
        native_namespace: String,
        native_identity: Vec<u8>,
        bookmark: Vec<u8>,
        label: String,
    ) -> Result<SourceCommit, CoreError> {
        self.verify_current()?;
        let version = self.data_version;
        let tx = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|_| CoreError::WriteFailed)?;
        let mut metadata = write_state(&tx, version, expected_revision)?;
        let mut existing = None;
        {
            let mut statement = tx
                .prepare("SELECT CASE WHEN length(payload)<=1048576 THEN payload END FROM sources")
                .map_err(corrupt)?;
            let mut rows = statement.query([]).map_err(corrupt)?;
            while let Some(row) = rows.next().map_err(corrupt)? {
                let bytes: Vec<u8> = row.get(0).map_err(corrupt)?;
                let source: SourceRecord = decode(&bytes)?;
                if source.native_namespace == native_namespace
                    && source.native_identity == native_identity
                {
                    if source.kind != kind {
                        return Err(CoreError::InvalidValue);
                    }
                    if existing.is_some() {
                        return Err(CoreError::StorageCorrupt);
                    }
                    existing = Some(source);
                }
            }
        }
        let id = if let Some(source) = &existing {
            source.id.clone()
        } else {
            tx.query_row(
                "SELECT 'source.v2.'||lower(hex(randomblob(16)))",
                [],
                |row| row.get(0),
            )
            .map_err(|_| CoreError::WriteFailed)?
        };
        let source = SourceRecord {
            id,
            kind,
            native_namespace,
            native_identity,
            bookmark,
            label,
            active: true,
        };
        source.validate()?;
        if existing.as_ref() == Some(&source) {
            tx.commit().map_err(|_| CoreError::WriteFailed)?;
            return Ok(SourceCommit { source, metadata });
        }
        tx.execute("INSERT INTO sources VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",params![source.id,encode(&source)?]).map_err(|_|CoreError::WriteFailed)?;
        metadata.revision = next(metadata.revision)?;
        metadata.scope_epoch = next(metadata.scope_epoch)?;
        if existing.is_none() {
            metadata.source_count = next(metadata.source_count)?;
        }
        tx.execute("UPDATE groups SET active=0 WHERE active=1", [])
            .map_err(|_| CoreError::WriteFailed)?;
        let digest = protection_digest(&tx)?;
        write_metadata(&tx, &metadata, Some(&digest))?;
        tx.commit().map_err(|_| CoreError::WriteFailed)?;
        self.verify_current()?;
        Ok(SourceCommit { source, metadata })
    }
    pub fn set_source_active(
        &mut self,
        expected_revision: u64,
        id: &str,
        active: bool,
    ) -> Result<SourceCommit, CoreError> {
        self.verify_current()?;
        let version = self.data_version;
        let tx = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|_| CoreError::WriteFailed)?;
        let mut metadata = write_state(&tx, version, expected_revision)?;
        let bytes:Vec<u8>=tx.query_row("SELECT CASE WHEN length(payload)<=1048576 THEN payload END FROM sources WHERE id=?1",[id],|row|row.get(0)).optional().map_err(corrupt)?.ok_or(CoreError::InvalidValue)?;
        let mut source: SourceRecord = decode(&bytes)?;
        if source.active == active {
            tx.commit().map_err(|_| CoreError::WriteFailed)?;
            return Ok(SourceCommit { source, metadata });
        }
        source.active = active;
        tx.execute(
            "UPDATE sources SET payload=?1 WHERE id=?2",
            params![encode(&source)?, id],
        )
        .map_err(|_| CoreError::WriteFailed)?;
        tx.execute("UPDATE groups SET active=0 WHERE active=1", [])
            .map_err(|_| CoreError::WriteFailed)?;
        metadata.revision = next(metadata.revision)?;
        metadata.scope_epoch = next(metadata.scope_epoch)?;
        let digest = protection_digest(&tx)?;
        write_metadata(&tx, &metadata, Some(&digest))?;
        tx.commit().map_err(|_| CoreError::WriteFailed)?;
        self.verify_current()?;
        Ok(SourceCommit { source, metadata })
    }
    pub fn complete_scan(
        &mut self,
        expected_revision: u64,
        groups: Vec<ReviewGroup>,
    ) -> Result<ReviewMetadata, CoreError> {
        let mut signatures = std::collections::HashSet::new();
        let mut members = std::collections::HashSet::new();
        let mut encoded = Vec::with_capacity(groups.len());
        for group in &groups {
            let signature = group.signature()?;
            if !signatures.insert(signature.clone())
                || group
                    .members
                    .iter()
                    .any(|asset| !members.insert(asset.id.clone()))
            {
                return Err(CoreError::InvalidValue);
            }
            encoded.push((signature, encode(group)?));
        }
        self.verify_current()?;
        let version = self.data_version;
        let tx = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|_| CoreError::WriteFailed)?;
        let mut metadata = write_state(&tx, version, expected_revision)?;
        let settings: Vec<u8> = tx
            .query_row("SELECT payload FROM settings WHERE id=1", [], |row| {
                row.get(0)
            })
            .map_err(corrupt)?;
        let mut settings: ReviewSettings = decode(&settings)?;
        settings.validate()?;
        let mut source_kinds = BTreeMap::new();
        {
            let mut statement = tx
                .prepare("SELECT CASE WHEN length(payload)<=1048576 THEN payload END FROM sources")
                .map_err(corrupt)?;
            let mut rows = statement.query([]).map_err(corrupt)?;
            while let Some(row) = rows.next().map_err(corrupt)? {
                let payload: Vec<u8> = row.get(0).map_err(corrupt)?;
                let source: SourceRecord = decode(&payload)?;
                if source.active {
                    source_kinds.insert(source.id, source.kind);
                }
            }
        }
        if groups.iter().any(|group| {
            group.sides != settings.sides
                || (group.scene.is_some() && !settings.similar_scenes_enabled)
                || group
                    .members
                    .iter()
                    .any(|asset| source_kinds.get(&asset.id.source_id) != Some(&asset.kind))
        }) {
            return Err(CoreError::InvalidValue);
        }
        let mut invalidated = Vec::new();
        {
            let mut statement=tx.prepare("SELECT decisions.signature,decisions.payload,groups.payload FROM decisions JOIN groups USING(signature)").map_err(corrupt)?;
            let mut rows = statement.query([]).map_err(corrupt)?;
            while let Some(row) = rows.next().map_err(corrupt)? {
                let signature: String = row.get(0).map_err(corrupt)?;
                let decision: Vec<u8> = row.get(1).map_err(corrupt)?;
                let group: Vec<u8> = row.get(2).map_err(corrupt)?;
                let mut decision: ReviewDecision = decode(&decision)?;
                let group: ReviewGroup = decode(&group)?;
                if !signatures.contains(&signature)
                    && !decision.invalidated
                    && (group.scene.is_none() || settings.similar_scenes_enabled)
                    && group
                        .members
                        .iter()
                        .any(|asset| members.contains(&asset.id))
                {
                    decision.invalidated = true;
                    invalidated.push((signature, encode(&decision)?));
                }
            }
        }
        tx.execute("UPDATE groups SET active=0 WHERE active=1", [])
            .map_err(|_| CoreError::WriteFailed)?;
        {
            let mut insert=tx.prepare_cached("INSERT INTO groups VALUES(?1,1,?2,?3) ON CONFLICT(signature) DO UPDATE SET active=1,ordinal=excluded.ordinal,payload=excluded.payload").map_err(|_|CoreError::WriteFailed)?;
            for (ordinal, (signature, payload)) in encoded.into_iter().enumerate() {
                insert
                    .execute(params![signature, ordinal as u64, payload])
                    .map_err(|_| CoreError::WriteFailed)?;
            }
        }
        for (signature, payload) in &invalidated {
            tx.execute(
                "UPDATE decisions SET payload=?1 WHERE signature=?2",
                params![payload, signature],
            )
            .map_err(|_| CoreError::WriteFailed)?;
        }
        tx.execute("DELETE FROM groups WHERE active=0 AND NOT EXISTS(SELECT 1 FROM decisions WHERE decisions.signature=groups.signature)",[]).map_err(|_|CoreError::WriteFailed)?;
        settings.scan_cancelled_by_user = false;
        tx.execute(
            "UPDATE settings SET payload=?1 WHERE id=1",
            params![encode(&settings)?],
        )
        .map_err(|_| CoreError::WriteFailed)?;
        metadata.revision = next(metadata.revision)?;
        metadata.scan_generation = next(metadata.scan_generation)?;
        metadata.scan_scope_epoch = metadata.scope_epoch;
        if !invalidated.is_empty() {
            metadata.decision_epoch = next(metadata.decision_epoch)?;
        }
        metadata.group_count = tx
            .query_row("SELECT count(*) FROM groups", [], |row| row.get(0))
            .map_err(corrupt)?;
        write_metadata(&tx, &metadata, None)?;
        tx.commit().map_err(|_| CoreError::WriteFailed)?;
        self.verify_current()?;
        Ok(metadata)
    }
    pub fn save_decision(
        &mut self,
        expected_revision: u64,
        signature: &str,
        decision: ReviewDecision,
        command_id: String,
        request_hash: [u8; 32],
    ) -> Result<DecisionCommit, CoreError> {
        if command_id.is_empty() || command_id.len() > 256 {
            return Err(CoreError::InvalidValue);
        }
        self.verify_current()?;
        let version = self.data_version;
        let tx = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|_| CoreError::WriteFailed)?;
        let mut metadata = read_metadata(&tx)?.0;
        let current: i64 = tx
            .pragma_query_value(None, "data_version", |row| row.get(0))
            .map_err(corrupt)?;
        if current != version {
            return Err(CoreError::ProtectionUnavailable);
        }
        let previous:Option<DecisionRow>=tx.query_row("SELECT CASE WHEN length(payload)<=67108864 THEN payload END,command_id,CASE WHEN length(request_hash)=32 THEN request_hash END FROM decisions WHERE signature=?1",[signature],|row|Ok((row.get(0)?,row.get(1)?,row.get(2)?))).optional().map_err(corrupt)?;
        if let Some((payload, Some(previous_id), Some(previous_hash))) = &previous
            && *previous_id == command_id
        {
            if previous_hash.as_slice() != request_hash {
                return Err(CoreError::InvalidValue);
            }
            let current: ReviewDecision = decode(payload)?;
            tx.commit().map_err(|_| CoreError::WriteFailed)?;
            return Ok(DecisionCommit {
                metadata,
                decision: current,
                replayed: true,
            });
        }
        if metadata.revision != expected_revision {
            return Err(CoreError::StaleOperation);
        }
        if metadata.scan_generation == 0 || metadata.scan_scope_epoch != metadata.scope_epoch {
            return Err(CoreError::StaleOperation);
        }
        let group:Option<(i32,Vec<u8>)>=tx.query_row("SELECT active,CASE WHEN length(payload)<=67108864 THEN payload END FROM groups WHERE signature=?1",[signature],|row|Ok((row.get(0)?,row.get(1)?))).optional().map_err(corrupt)?;
        let (active, payload) = group.ok_or(CoreError::InvalidValue)?;
        if active != 1 {
            return Err(CoreError::StaleOperation);
        }
        let group: ReviewGroup = decode(&payload)?;
        decision.validate(&group)?;
        let owner: Option<String> = tx
            .query_row(
                "SELECT signature FROM decisions WHERE command_id=?1",
                [&command_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(corrupt)?;
        if owner.as_ref().is_some_and(|owner| owner != signature) {
            return Err(CoreError::InvalidValue);
        }
        tx.execute("INSERT INTO decisions VALUES(?1,?2,?3,?4) ON CONFLICT(signature) DO UPDATE SET payload=excluded.payload,command_id=excluded.command_id,request_hash=excluded.request_hash",
            params![signature,encode(&decision)?,command_id,request_hash.as_slice()]).map_err(|_|CoreError::WriteFailed)?;
        metadata.revision = next(metadata.revision)?;
        metadata.decision_epoch = next(metadata.decision_epoch)?;
        if previous.is_none() {
            metadata.decision_count = next(metadata.decision_count)?;
        }
        write_metadata(&tx, &metadata, None)?;
        tx.commit().map_err(|_| CoreError::WriteFailed)?;
        self.verify_current()?;
        Ok(DecisionCommit {
            metadata,
            decision,
            replayed: false,
        })
    }
    pub fn save_position(
        &mut self,
        expected_revision: u64,
        sequence: u64,
        anchor: Option<String>,
        position: Option<u64>,
    ) -> Result<(), CoreError> {
        if sequence > i64::MAX as u64
            || position.is_some_and(|p| p > i64::MAX as u64)
            || anchor
                .as_ref()
                .is_some_and(|a| a.is_empty() || a.len() > 256)
        {
            return Err(CoreError::InvalidValue);
        }
        self.verify_current()?;
        let version = self.data_version;
        let tx = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|_| CoreError::WriteFailed)?;
        write_state(&tx, version, expected_revision)?;
        let previous: (Option<String>, Option<u64>, u64) = tx
            .query_row(
                "SELECT anchor,position,sequence FROM navigation WHERE id=1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()
            .map_err(corrupt)?
            .ok_or(CoreError::ProtectionUnavailable)?;
        if sequence <= previous.2 {
            if sequence == previous.2 && anchor == previous.0 && position == previous.1 {
                tx.commit().map_err(|_| CoreError::WriteFailed)?;
                return Ok(());
            }
            return Err(CoreError::StaleOperation);
        }
        tx.execute(
            "UPDATE navigation SET anchor=?1,position=?2,sequence=?3 WHERE id=1",
            params![anchor, position, sequence],
        )
        .map_err(|_| CoreError::WriteFailed)?;
        tx.commit().map_err(|_| CoreError::WriteFailed)?;
        self.verify_current()?;
        Ok(())
    }
    pub fn load(&mut self) -> Result<ReviewSnapshot, CoreError> {
        self.verify_current()?;
        let tx = self.connection.transaction().map_err(corrupt)?;
        let snapshot = Self::read_snapshot(&tx)?;
        tx.commit().map_err(corrupt)?;
        self.verify_current()?;
        Ok(snapshot)
    }
    fn read_snapshot(connection: &Connection) -> Result<ReviewSnapshot, CoreError> {
        let metadata = read_metadata(connection)?;
        if metadata.1.as_slice() != protection_digest(connection)? {
            return Err(CoreError::ProtectionUnavailable);
        }
        {
            let mut check = connection
                .prepare("PRAGMA foreign_key_check")
                .map_err(corrupt)?;
            if check
                .query([])
                .map_err(corrupt)?
                .next()
                .map_err(corrupt)?
                .is_some()
            {
                return Err(CoreError::ProtectionUnavailable);
            }
        }
        let mut sources = Vec::new();
        {
            let mut statement=connection.prepare("SELECT id,CASE WHEN length(payload)<=67108864 THEN payload END FROM sources ORDER BY id").map_err(corrupt)?;
            let mut rows = statement.query([]).map_err(corrupt)?;
            while let Some(row) = rows.next().map_err(corrupt)? {
                let id: String = row.get(0).map_err(corrupt)?;
                let payload: Vec<u8> = row.get(1).map_err(corrupt)?;
                let source: SourceRecord = decode(&payload)?;
                source.validate().map_err(|_| CoreError::StorageCorrupt)?;
                if source.id != id {
                    return Err(CoreError::StorageCorrupt);
                }
                sources.push(source);
            }
        }
        let source_kinds: BTreeMap<_, _> = sources.iter().map(|s| (&s.id, s.kind)).collect();
        let mut groups = Vec::new();
        {
            let mut statement=connection.prepare("SELECT signature,active,ordinal,CASE WHEN length(payload)<=67108864 THEN payload END FROM groups ORDER BY ordinal,signature").map_err(corrupt)?;
            let mut rows = statement.query([]).map_err(corrupt)?;
            while let Some(row) = rows.next().map_err(corrupt)? {
                let signature: String = row.get(0).map_err(corrupt)?;
                let active: i32 = row.get(1).map_err(corrupt)?;
                let ordinal: u64 = row.get(2).map_err(corrupt)?;
                let payload: Vec<u8> = row.get(3).map_err(corrupt)?;
                let group: ReviewGroup = decode(&payload)?;
                if group.signature().map_err(|_| CoreError::StorageCorrupt)? != signature
                    || ![0, 1].contains(&active)
                {
                    return Err(CoreError::StorageCorrupt);
                }
                if group
                    .members
                    .iter()
                    .any(|asset| source_kinds.get(&asset.id.source_id) != Some(&asset.kind))
                {
                    return Err(CoreError::ProtectionUnavailable);
                }
                groups.push(StoredGroup {
                    signature,
                    active: active == 1,
                    ordinal,
                    group,
                });
            }
        }
        let group_lookup: BTreeMap<_, _> = groups
            .iter()
            .map(|group| (&group.signature, &group.group))
            .collect();
        let mut decisions = Vec::new();
        {
            let mut statement=connection.prepare("SELECT signature,CASE WHEN length(payload)<=67108864 THEN payload END,command_id,CASE WHEN length(request_hash)=32 THEN request_hash END FROM decisions ORDER BY signature").map_err(corrupt)?;
            let mut rows = statement.query([]).map_err(corrupt)?;
            while let Some(row) = rows.next().map_err(corrupt)? {
                let signature: String = row.get(0).map_err(corrupt)?;
                let payload: Vec<u8> = row.get(1).map_err(corrupt)?;
                let command_id: Option<String> = row.get(2).map_err(corrupt)?;
                let request_hash: Option<Vec<u8>> = row.get(3).map_err(corrupt)?;
                if command_id.is_some() != request_hash.is_some()
                    || command_id
                        .as_ref()
                        .is_some_and(|id| id.is_empty() || id.len() > 256)
                {
                    return Err(CoreError::StorageCorrupt);
                }
                let decision: ReviewDecision = decode(&payload)?;
                let group = group_lookup
                    .get(&signature)
                    .ok_or(CoreError::ProtectionUnavailable)?;
                decision
                    .validate(group)
                    .map_err(|_| CoreError::StorageCorrupt)?;
                decisions.push(StoredDecision {
                    signature,
                    decision,
                    command_id,
                    request_hash,
                });
            }
        }
        let mut locks = Vec::new();
        {
            let mut statement=connection.prepare("SELECT source,item,CASE WHEN length(payload)<=67108864 THEN payload END FROM locks ORDER BY source,item").map_err(corrupt)?;
            let mut rows = statement.query([]).map_err(corrupt)?;
            while let Some(row) = rows.next().map_err(corrupt)? {
                let source: String = row.get(0).map_err(corrupt)?;
                let item: String = row.get(1).map_err(corrupt)?;
                let payload: Vec<u8> = row.get(2).map_err(corrupt)?;
                let asset: ReviewAsset = decode(&payload)?;
                if asset.id.source_id != source
                    || asset.id.item_id != item
                    || source_kinds.get(&source) != Some(&asset.kind)
                {
                    return Err(CoreError::StorageCorrupt);
                }
                locks.push(asset);
            }
        }
        let mut policies = BTreeMap::new();
        {
            let mut statement=connection.prepare("SELECT source,CASE WHEN length(payload)<=67108864 THEN payload END FROM read_only ORDER BY source").map_err(corrupt)?;
            let mut rows = statement.query([]).map_err(corrupt)?;
            while let Some(row) = rows.next().map_err(corrupt)? {
                let source: String = row.get(0).map_err(corrupt)?;
                let payload: Vec<u8> = row.get(1).map_err(corrupt)?;
                let policy: ReadOnlyPolicy = decode(&payload)?;
                if policy.source_id != source
                    || !policy.members.is_empty()
                    || source_kinds.get(&source) != Some(&policy.kind)
                {
                    return Err(CoreError::StorageCorrupt);
                }
                policies.insert(source, policy);
            }
        }
        {
            let mut statement=connection.prepare("SELECT source,item,CASE WHEN length(payload)<=67108864 THEN payload END FROM read_only_members ORDER BY source,item").map_err(corrupt)?;
            let mut rows = statement.query([]).map_err(corrupt)?;
            while let Some(row) = rows.next().map_err(corrupt)? {
                let source: String = row.get(0).map_err(corrupt)?;
                let item: String = row.get(1).map_err(corrupt)?;
                let payload: Vec<u8> = row.get(2).map_err(corrupt)?;
                let asset: ReviewAsset = decode(&payload)?;
                if asset.id.source_id != source
                    || asset.id.item_id != item
                    || source_kinds.get(&source) != Some(&asset.kind)
                {
                    return Err(CoreError::StorageCorrupt);
                }
                policies
                    .get_mut(&source)
                    .ok_or(CoreError::ProtectionUnavailable)?
                    .members
                    .push(asset);
            }
        }
        let protection = ProtectionState::new(locks, policies.into_values().collect())
            .map_err(|_| CoreError::ProtectionUnavailable)?;
        let settings:Vec<u8>=connection.query_row("SELECT CASE WHEN length(payload)<=67108864 THEN payload END FROM settings WHERE id=1",[],|row|row.get(0)).optional().map_err(corrupt)?.ok_or(CoreError::ProtectionUnavailable)?;
        let settings: ReviewSettings = decode(&settings)?;
        settings.validate().map_err(|_| CoreError::StorageCorrupt)?;
        let (anchor, position, navigation_sequence): (Option<String>, Option<u64>, u64) =
            connection
                .query_row(
                    "SELECT anchor,position,sequence FROM navigation WHERE id=1",
                    [],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )
                .optional()
                .map_err(corrupt)?
                .ok_or(CoreError::ProtectionUnavailable)?;
        if metadata.0.source_count != sources.len() as u64
            || metadata.0.group_count != groups.len() as u64
            || metadata.0.decision_count != decisions.len() as u64
        {
            return Err(CoreError::ProtectionUnavailable);
        }
        Ok(ReviewSnapshot {
            metadata: metadata.0,
            sources,
            groups,
            decisions,
            protection,
            settings,
            anchor,
            position,
            navigation_sequence,
        })
    }
}

// Database-file lifecycle only; media identities remain opaque native facts.
fn database_identity(path: &Path) -> Result<(u64, u64), CoreError> {
    use std::os::unix::fs::MetadataExt;
    let metadata = std::fs::symlink_metadata(path).map_err(|_| CoreError::ProtectionUnavailable)?;
    if !metadata.is_file() || metadata.nlink() != 1 {
        return Err(CoreError::ProtectionUnavailable);
    }
    Ok((metadata.dev(), metadata.ino()))
}

#[cfg(test)]
mod tests;
