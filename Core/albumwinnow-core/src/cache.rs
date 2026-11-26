use crate::{
    Cancellation, CoreError,
    matching::Fingerprint,
    model::{AssetId, SceneProvider, validate_date},
    scene::SceneQuality,
};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    path::Path,
};

const APPLICATION_ID: i32 = 0x41574332;
const SCHEMA: i32 = 1;
pub const FINGERPRINT_VERSION: &str = "aw.v2.fingerprint.1";
const SAMPLE_BYTES: usize = 128 * 128 * 4;
const MAX_COMPRESSED: usize = SAMPLE_BYTES + 512;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CachedFingerprint {
    pub id: AssetId,
    pub revision: String,
    pub fingerprint: Fingerprint,
    pub observed_bit_depth: Option<u16>,
    pub capture_date: Option<f64>,
}
impl CachedFingerprint {
    fn validate(&self) -> Result<(), CoreError> {
        self.id.validate()?;
        self.fingerprint.validate()?;
        validate_date(self.capture_date)?;
        if self.revision.len() > 8192
            || self
                .observed_bit_depth
                .is_some_and(|d| d != self.fingerprint.bit_depth)
        {
            return Err(CoreError::InvalidValue);
        }
        Ok(())
    }
}
pub struct PreparedCacheEntry {
    pub metadata: CachedFingerprint,
    pub sample: Vec<u8>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CachedScene {
    pub provider: SceneProvider,
    pub quality: SceneQuality,
    pub archive: Vec<u8>,
}
impl CachedScene {
    fn validate(&self) -> Result<(), CoreError> {
        self.provider.validate()?;
        self.quality.validate()?;
        if self.archive.is_empty() || self.archive.len() > 16384 {
            return Err(CoreError::InvalidBuffer);
        }
        Ok(())
    }
}

pub struct CacheStore {
    connection: Connection,
    data_version: i64,
    // Metadata only. Samples remain bounded per read, never library-resident.
    validated: HashMap<(String, String), BTreeMap<String, CachedFingerprint>>,
}
fn read_error(error: rusqlite::Error) -> CoreError {
    match error.sqlite_error_code() {
        Some(rusqlite::ErrorCode::DatabaseCorrupt | rusqlite::ErrorCode::NotADatabase) => {
            CoreError::StorageCorrupt
        }
        _ => CoreError::StorageUnavailable,
    }
}
fn checksum(metadata: &[u8], sample: &[u8]) -> [u8; 32] {
    let mut hash = blake3::Hasher::new();
    hash.update(b"AlbumWinnow.v2.cache.entry.1\0");
    hash.update(&(metadata.len() as u64).to_le_bytes());
    hash.update(metadata);
    hash.update(&(sample.len() as u64).to_le_bytes());
    hash.update(sample);
    *hash.finalize().as_bytes()
}
fn scene_checksum(
    id: &AssetId,
    revision: &str,
    provider: &[u8],
    quality: &[u8],
    archive: &[u8],
) -> Result<[u8; 32], CoreError> {
    let key = serde_json::to_vec(&(id, revision)).map_err(|_| CoreError::InvalidValue)?;
    let mut hash = blake3::Hasher::new();
    hash.update(b"AlbumWinnow.v2.cache.scene.1\0");
    for bytes in [key.as_slice(), provider, quality, archive] {
        hash.update(&(bytes.len() as u64).to_le_bytes());
        hash.update(bytes);
    }
    Ok(*hash.finalize().as_bytes())
}
fn decode_sample(compressed: &[u8]) -> Result<Vec<u8>, CoreError> {
    if compressed.len() > MAX_COMPRESSED {
        return Err(CoreError::InvalidBuffer);
    }
    let mut sample = vec![0; SAMPLE_BYTES];
    let length = lz4_flex::block::decompress_into(compressed, &mut sample)
        .map_err(|_| CoreError::InvalidBuffer)?;
    if length != SAMPLE_BYTES {
        return Err(CoreError::InvalidBuffer);
    }
    Ok(sample)
}
impl CacheStore {
    /// Only the dedicated v2 scan-cache path may be supplied. The review database
    /// has a different application ID and is never repaired by this owner.
    pub fn open(path: &Path) -> Result<Self, CoreError> {
        match Self::open_once(path) {
            Err(CoreError::StorageCorrupt) => {
                let stamp = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_err(|_| CoreError::StorageUnavailable)?
                    .as_nanos();
                for suffix in ["", "-wal", "-shm"] {
                    let mut name = path.as_os_str().to_os_string();
                    name.push(suffix);
                    let source = std::path::PathBuf::from(name);
                    if source
                        .try_exists()
                        .map_err(|_| CoreError::StorageUnavailable)?
                    {
                        let mut target = path.as_os_str().to_os_string();
                        target.push(format!(".corrupt-{stamp}{suffix}"));
                        std::fs::rename(source, target)
                            .map_err(|_| CoreError::StorageUnavailable)?;
                    }
                }
                Self::open_once(path)
            }
            other => other,
        }
    }
    fn open_once(path: &Path) -> Result<Self, CoreError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|_| CoreError::StorageUnavailable)?;
        }
        let mut connection = Connection::open(path).map_err(read_error)?;
        let application: i32 = connection
            .pragma_query_value(None, "application_id", |r| r.get(0))
            .map_err(read_error)?;
        let schema: i32 = connection
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .map_err(read_error)?;
        let tables: i64 = connection
            .query_row(
                "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'",
                [],
                |r| r.get(0),
            )
            .map_err(read_error)?;
        if application == 0 && schema == 0 && tables == 0 {
            let tx = connection.transaction().map_err(read_error)?;
            tx.execute_batch("CREATE TABLE fingerprints (source TEXT NOT NULL,item TEXT NOT NULL,revision TEXT NOT NULL,version TEXT NOT NULL,pipeline TEXT NOT NULL,metadata BLOB NOT NULL,sample BLOB NOT NULL,checksum BLOB NOT NULL,PRIMARY KEY(source,item)) WITHOUT ROWID;
                CREATE TABLE scene_features (source TEXT NOT NULL,item TEXT NOT NULL,revision TEXT NOT NULL,provider BLOB NOT NULL,quality BLOB NOT NULL,archive BLOB NOT NULL,checksum BLOB NOT NULL,PRIMARY KEY(source,item)) WITHOUT ROWID;") .map_err(read_error)?;
            tx.pragma_update(None, "application_id", APPLICATION_ID)
                .map_err(read_error)?;
            tx.pragma_update(None, "user_version", SCHEMA)
                .map_err(read_error)?;
            tx.commit().map_err(read_error)?;
        } else if application != APPLICATION_ID || schema != SCHEMA {
            return Err(CoreError::UnsupportedSchema);
        }
        for query in [
            "SELECT source,item,revision,version,pipeline,metadata,sample,checksum FROM fingerprints LIMIT 0",
            "SELECT source,item,revision,provider,quality,archive,checksum FROM scene_features LIMIT 0",
        ] {
            connection
                .prepare(query)
                .map_err(|_| CoreError::StorageCorrupt)?;
        }
        let check: String = connection
            .query_row("PRAGMA quick_check", [], |r| r.get(0))
            .map_err(read_error)?;
        if check != "ok" {
            return Err(CoreError::StorageCorrupt);
        }
        connection
            .execute_batch(
                "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-2048;",
            )
            .map_err(read_error)?;
        let data_version = connection
            .pragma_query_value(None, "data_version", |row| row.get(0))
            .map_err(read_error)?;
        Ok(Self {
            connection,
            data_version,
            validated: HashMap::new(),
        })
    }
    fn sync_external_changes(&mut self) -> Result<(), CoreError> {
        let version = self
            .connection
            .pragma_query_value(None, "data_version", |row| row.get(0))
            .map_err(read_error)?;
        if version != self.data_version {
            self.validated.clear();
            self.data_version = version;
        }
        Ok(())
    }
    pub fn store(
        &mut self,
        entries: Vec<PreparedCacheEntry>,
        pipeline: &str,
        cancel: &Cancellation,
    ) -> Result<(), CoreError> {
        validate_pipeline(pipeline)?;
        if entries.len() > 16 {
            return Err(CoreError::InvalidBuffer);
        }
        let mut encoded = Vec::with_capacity(entries.len());
        for entry in entries {
            cancel.check()?;
            entry.metadata.validate()?;
            if entry.sample.len() != SAMPLE_BYTES {
                return Err(CoreError::InvalidPixels);
            }
            let metadata =
                serde_json::to_vec(&entry.metadata).map_err(|_| CoreError::InvalidValue)?;
            if metadata.len() > 131072 {
                return Err(CoreError::InvalidBuffer);
            }
            let digest = checksum(&metadata, &entry.sample);
            let compressed = lz4_flex::block::compress(&entry.sample);
            encoded.push((entry.metadata, metadata, compressed, digest));
        }
        self.sync_external_changes()?;
        let updated: Vec<_> = encoded
            .iter()
            .map(|(entry, _, _, _)| entry.clone())
            .collect();
        let tx = self
            .connection
            .transaction()
            .map_err(|_| CoreError::WriteFailed)?;
        {
            let mut statement=tx.prepare_cached("INSERT INTO fingerprints VALUES (?1,?2,?3,?4,?5,?6,?7,?8)
                ON CONFLICT(source,item) DO UPDATE SET revision=excluded.revision,version=excluded.version,pipeline=excluded.pipeline,metadata=excluded.metadata,sample=excluded.sample,checksum=excluded.checksum").map_err(|_|CoreError::WriteFailed)?;
            for (entry, metadata, sample, checksum) in encoded {
                cancel.check()?;
                statement
                    .execute(params![
                        entry.id.source_id,
                        entry.id.item_id,
                        entry.revision,
                        FINGERPRINT_VERSION,
                        pipeline,
                        metadata,
                        sample,
                        checksum.as_slice()
                    ])
                    .map_err(|_| CoreError::WriteFailed)?;
            }
        }
        cancel.check()?;
        tx.commit().map_err(|_| CoreError::WriteFailed)?;
        self.sync_external_changes()?;
        for entry in updated {
            for ((source, _), entries) in &mut self.validated {
                if *source == entry.id.source_id {
                    entries.remove(&entry.id.item_id);
                }
            }
            if let Some(entries) = self
                .validated
                .get_mut(&(entry.id.source_id.clone(), pipeline.into()))
            {
                entries.insert(entry.id.item_id.clone(), entry);
            }
        }
        Ok(())
    }
    pub fn signatures(
        &mut self,
        source: &str,
        pipeline: &str,
        cancel: &Cancellation,
    ) -> Result<Vec<CachedFingerprint>, CoreError> {
        self.load_signatures(source, pipeline, cancel)?;
        self.validated[&(source.into(), pipeline.into())]
            .values()
            .map(|entry| {
                cancel.check()?;
                Ok(entry.clone())
            })
            .collect()
    }

    pub fn signatures_page(
        &mut self,
        source: &str,
        pipeline: &str,
        offset: u64,
        limit: u32,
        cancel: &Cancellation,
    ) -> Result<Vec<CachedFingerprint>, CoreError> {
        if limit == 0 || limit > 256 {
            return Err(CoreError::InvalidBuffer);
        }
        let offset = usize::try_from(offset).map_err(|_| CoreError::InvalidValue)?;
        self.load_signatures(source, pipeline, cancel)?;
        self.validated[&(source.into(), pipeline.into())]
            .values()
            .skip(offset)
            .take(limit as usize)
            .map(|entry| {
                cancel.check()?;
                Ok(entry.clone())
            })
            .collect()
    }

    /// A bounded decoded sample is checked here so corrupt records cannot make a
    /// metadata-only hit look reusable. The buffer is discarded after each row.
    fn load_signatures(
        &mut self,
        source: &str,
        pipeline: &str,
        cancel: &Cancellation,
    ) -> Result<(), CoreError> {
        validate_pipeline(pipeline)?;
        if source.is_empty() || source.len() > 4096 {
            return Err(CoreError::InvalidValue);
        }
        cancel.check()?;
        self.sync_external_changes()?;
        let key = (source.to_owned(), pipeline.to_owned());
        if self.validated.contains_key(&key) {
            return Ok(());
        }
        let version = self.data_version;
        let mut result = BTreeMap::new();
        let mut invalid = Vec::new();
        {
            let mut statement=self.connection.prepare("SELECT item,revision,CASE WHEN length(metadata)<=131072 THEN metadata END,
                CASE WHEN length(sample)<=66048 THEN sample END,CASE WHEN length(checksum)=32 THEN checksum END
                FROM fingerprints WHERE source=?1 AND version=?2 AND pipeline=?3").map_err(read_error)?;
            let mut rows = statement
                .query(params![source, FINGERPRINT_VERSION, pipeline])
                .map_err(read_error)?;
            while let Some(row) = rows.next().map_err(read_error)? {
                cancel.check()?;
                let item: String = row.get(0).map_err(read_error)?;
                let revision: String = row.get(1).map_err(read_error)?;
                let metadata: Option<Vec<u8>> = row.get(2).unwrap_or(None);
                let sample: Option<Vec<u8>> = row.get(3).unwrap_or(None);
                let digest: Option<Vec<u8>> = row.get(4).unwrap_or(None);
                let decoded = (|| {
                    let metadata = metadata?;
                    let sample = decode_sample(&sample?).ok()?;
                    if checksum(&metadata, &sample).as_slice() != digest? {
                        return None;
                    }
                    let value: CachedFingerprint = serde_json::from_slice(&metadata).ok()?;
                    value.validate().ok()?;
                    if value.id.source_id != source
                        || value.id.item_id != item
                        || value.revision != revision
                    {
                        return None;
                    }
                    Some(value)
                })();
                if let Some(value) = decoded {
                    result.insert(item, value);
                } else {
                    invalid.push(item);
                }
            }
        }
        if !invalid.is_empty() {
            let tx = self
                .connection
                .transaction()
                .map_err(|_| CoreError::WriteFailed)?;
            for item in invalid {
                cancel.check()?;
                tx.execute(
                    "DELETE FROM fingerprints WHERE source=?1 AND item=?2",
                    params![source, item],
                )
                .map_err(|_| CoreError::WriteFailed)?;
            }
            tx.commit().map_err(|_| CoreError::WriteFailed)?;
        }
        self.sync_external_changes()?;
        if self.data_version != version {
            return Err(CoreError::StaleOperation);
        }
        self.validated.insert(key, result);
        Ok(())
    }
    pub fn sample(
        &self,
        id: &AssetId,
        revision: &str,
        pipeline: &str,
    ) -> Result<Option<Vec<u8>>, CoreError> {
        id.validate()?;
        validate_pipeline(pipeline)?;
        let record=self.connection.query_row("SELECT CASE WHEN length(metadata)<=131072 THEN metadata END,CASE WHEN length(sample)<=66048 THEN sample END,CASE WHEN length(checksum)=32 THEN checksum END
            FROM fingerprints WHERE source=?1 AND item=?2 AND revision=?3 AND version=?4 AND pipeline=?5",params![id.source_id,id.item_id,revision,FINGERPRINT_VERSION,pipeline],|r|Ok((r.get::<_,Option<Vec<u8>>>(0)?,r.get::<_,Option<Vec<u8>>>(1)?,r.get::<_,Option<Vec<u8>>>(2)?))).optional().map_err(read_error)?;
        let Some((Some(metadata), Some(compressed), Some(digest))) = record else {
            return Ok(None);
        };
        let Ok(sample) = decode_sample(&compressed) else {
            return Ok(None);
        };
        if checksum(&metadata, &sample).as_slice() != digest {
            return Ok(None);
        }
        Ok(Some(sample))
    }
    pub fn store_scene(
        &mut self,
        id: &AssetId,
        revision: &str,
        scene: CachedScene,
    ) -> Result<(), CoreError> {
        id.validate()?;
        scene.validate()?;
        if revision.len() > 8192 {
            return Err(CoreError::InvalidValue);
        }
        let provider = serde_json::to_vec(&scene.provider).map_err(|_| CoreError::InvalidValue)?;
        let quality = serde_json::to_vec(&scene.quality).map_err(|_| CoreError::InvalidValue)?;
        let digest = scene_checksum(id, revision, &provider, &quality, &scene.archive)?;
        self.connection.execute("INSERT INTO scene_features VALUES (?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(source,item) DO UPDATE SET revision=excluded.revision,provider=excluded.provider,quality=excluded.quality,archive=excluded.archive,checksum=excluded.checksum",
            params![id.source_id,id.item_id,revision,provider,quality,scene.archive,digest.as_slice()]).map_err(|_|CoreError::WriteFailed)?;
        Ok(())
    }
    pub fn scene(
        &mut self,
        id: &AssetId,
        revision: &str,
        provider: &SceneProvider,
    ) -> Result<Option<CachedScene>, CoreError> {
        id.validate()?;
        provider.validate()?;
        let record=self.connection.query_row("SELECT CASE WHEN length(provider)<=2048 THEN provider END,CASE WHEN length(quality)<=1024 THEN quality END,CASE WHEN length(archive)<=16384 THEN archive END,CASE WHEN length(checksum)=32 THEN checksum END FROM scene_features WHERE source=?1 AND item=?2 AND revision=?3",
            params![id.source_id,id.item_id,revision],|r|Ok((r.get::<_,Option<Vec<u8>>>(0)?,r.get::<_,Option<Vec<u8>>>(1)?,r.get::<_,Option<Vec<u8>>>(2)?,r.get::<_,Option<Vec<u8>>>(3)?))).optional().map_err(read_error)?;
        let Some(record) = record else {
            return Ok(None);
        };
        let scene = (|| {
            let (Some(encoded_provider), Some(quality), Some(archive), Some(digest)) = record
            else {
                return None;
            };
            if scene_checksum(id, revision, &encoded_provider, &quality, &archive)
                .ok()?
                .as_slice()
                != digest
            {
                return None;
            }
            let scene = CachedScene {
                provider: serde_json::from_slice(&encoded_provider).ok()?,
                quality: serde_json::from_slice(&quality).ok()?,
                archive,
            };
            scene.validate().ok()?;
            Some(scene)
        })();
        match scene {
            Some(scene) if scene.provider == *provider => Ok(Some(scene)),
            Some(_) => Ok(None),
            None => {
                self.remove_scene(id)?;
                Ok(None)
            }
        }
    }
    pub fn remove_scene(&mut self, id: &AssetId) -> Result<(), CoreError> {
        id.validate()?;
        self.connection
            .execute(
                "DELETE FROM scene_features WHERE source=?1 AND item=?2",
                params![id.source_id, id.item_id],
            )
            .map_err(|_| CoreError::WriteFailed)?;
        Ok(())
    }
    /// Called only after all sources finished successfully; cancellation leaves
    /// previous entries available for an explicit rescan.
    pub fn finish(
        &mut self,
        ids: &HashSet<AssetId>,
        sources: &HashSet<String>,
        cancel: &Cancellation,
    ) -> Result<(), CoreError> {
        cancel.check()?;
        self.sync_external_changes()?;
        for id in ids {
            id.validate()?;
            if !sources.contains(&id.source_id) {
                return Err(CoreError::InvalidValue);
            }
        }
        let tx = self
            .connection
            .transaction()
            .map_err(|_| CoreError::WriteFailed)?;
        for table in ["fingerprints", "scene_features"] {
            let mut obsolete = Vec::new();
            {
                let mut statement = tx
                    .prepare(&format!("SELECT source,item FROM {table}"))
                    .map_err(read_error)?;
                let mut rows = statement.query([]).map_err(read_error)?;
                while let Some(row) = rows.next().map_err(read_error)? {
                    cancel.check()?;
                    let id = AssetId {
                        source_id: row.get(0).map_err(read_error)?,
                        item_id: row.get(1).map_err(read_error)?,
                    };
                    if !ids.contains(&id) {
                        obsolete.push(id);
                    }
                }
            }
            for id in obsolete {
                cancel.check()?;
                tx.execute(
                    &format!("DELETE FROM {table} WHERE source=?1 AND item=?2"),
                    params![id.source_id, id.item_id],
                )
                .map_err(|_| CoreError::WriteFailed)?;
            }
        }
        cancel.check()?;
        tx.commit().map_err(|_| CoreError::WriteFailed)?;
        self.sync_external_changes()?;
        self.validated.retain(|(source, _), entries| {
            if !sources.contains(source) {
                return false;
            }
            entries.retain(|_, entry| ids.contains(&entry.id));
            true
        });
        Ok(())
    }
    pub fn clear(&mut self) -> Result<(), CoreError> {
        let tx = self
            .connection
            .transaction()
            .map_err(|_| CoreError::WriteFailed)?;
        tx.execute_batch("DELETE FROM fingerprints; DELETE FROM scene_features;")
            .map_err(|_| CoreError::WriteFailed)?;
        tx.commit().map_err(|_| CoreError::WriteFailed)?;
        self.validated.clear();
        self.connection
            .execute_batch("VACUUM; PRAGMA wal_checkpoint(TRUNCATE);")
            .map_err(|_| CoreError::WriteFailed)
    }
}
fn validate_pipeline(pipeline: &str) -> Result<(), CoreError> {
    if pipeline.is_empty() || pipeline.len() > 128 {
        Err(CoreError::InvalidValue)
    } else {
        Ok(())
    }
}
