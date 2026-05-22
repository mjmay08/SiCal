use anyhow::{anyhow, Result};
use chrono::{Duration, Utc};
use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};
use sia_storage::{
    app_id, generate_recovery_phrase as sia_generate_recovery_phrase,
    validate_recovery_phrase, AppKey, AppMetadata, ApprovedState, Builder,
    DownloadOptions, Hash256, Object, ObjectsCursor, RequestingApprovalState,
    UploadOptions, Sdk,
};
use std::io::Cursor;
use std::str::FromStr;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU32, Ordering};
use tokio::io::AsyncReadExt;
use tokio::sync::Mutex as TokioMutex;

// ---------------------------------------------------------------------------
// App identity — generate your App ID once and never change it.
// ---------------------------------------------------------------------------

const INDEXER_URL: &str = "https://sia.storage";

const APP_META: AppMetadata = AppMetadata {
    id: app_id!("e3a1f8c6d4b2097531a6e8f4c2d0b7a5e3f1c6d4b209753100000000ca1eda42"),
    name: "SiCal",
    description: "Decentralized calendar powered by the Sia network",
    service_url: "https://github.com/mjmay08/SiCal",
    logo_url: "https://raw.githubusercontent.com/mjmay08/SiCal/refs/heads/main/assets/icon.png",
    callback_url: None,
};

// ---------------------------------------------------------------------------
// Shard upload progress — atomic counters read by Dart via polling.
// ---------------------------------------------------------------------------

static SHARD_CURRENT: AtomicU32 = AtomicU32::new(0);
static SHARD_TOTAL: AtomicU32 = AtomicU32::new(0);

#[derive(Debug, Clone)]
pub struct ShardProgressInfo {
    pub current: u32,
    pub total: u32,
}

/// Returns the current shard upload progress (current, total).
/// Poll this from Dart during uploads for real-time shard-level progress.
#[frb(sync)]
pub fn get_shard_progress() -> ShardProgressInfo {
    ShardProgressInfo {
        current: SHARD_CURRENT.load(Ordering::Relaxed),
        total: SHARD_TOTAL.load(Ordering::Relaxed),
    }
}

// ---------------------------------------------------------------------------
// Global SDK state
// ---------------------------------------------------------------------------

static SDK_INSTANCE: OnceLock<TokioMutex<Option<Sdk>>> = OnceLock::new();

fn sdk_lock() -> &'static TokioMutex<Option<Sdk>> {
    SDK_INSTANCE.get_or_init(|| TokioMutex::new(None))
}

async fn get_sdk() -> Result<Sdk> {
    let guard = sdk_lock().lock().await;
    guard
        .clone()
        .ok_or_else(|| anyhow!("SDK not connected — call connect() or register_with_phrase() first"))
}

// ---------------------------------------------------------------------------
// Onboarding state — explicit three-step flow: request → approve → register
// ---------------------------------------------------------------------------

enum OnboardingState {
    AwaitingApproval(Builder<RequestingApprovalState>),
    AwaitingPhrase(Builder<ApprovedState>),
}

static PENDING: OnceLock<TokioMutex<Option<OnboardingState>>> = OnceLock::new();

fn pending_lock() -> &'static TokioMutex<Option<OnboardingState>> {
    PENDING.get_or_init(|| TokioMutex::new(None))
}

// ---------------------------------------------------------------------------
// Types exposed to Dart via flutter_rust_bridge
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiaObject {
    pub object_id: String,
    pub data: Vec<u8>,
    pub metadata_json: String,
    pub size: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiaObjectEvent {
    pub object_id: String,
    pub deleted: bool,
    pub metadata_json: Option<String>,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncResult {
    pub events: Vec<SiaObjectEvent>,
    pub has_more: bool,
}

#[derive(Debug, Clone)]
pub struct UploadItem {
    pub data: Vec<u8>,
    pub metadata_json: String,
}

// ---------------------------------------------------------------------------
// Connection / Auth
// ---------------------------------------------------------------------------

/// Request a new app connection with the indexer.
/// Returns an approval URL the user must open in a browser.
/// After showing the URL, call [wait_for_approval]. If that fails with a
/// network error, call this again to get a fresh URL and retry.
pub async fn request_connection() -> Result<String> {
    let builder = Builder::new(INDEXER_URL, APP_META)
        .map_err(|e| anyhow!("builder: {e}"))?;
    let builder = builder
        .request_connection()
        .await
        .map_err(|e| anyhow!("request_connection: {e}"))?;

    let url = builder.response_url().to_string();
    pending_lock()
        .lock()
        .await
        .replace(OnboardingState::AwaitingApproval(builder));
    Ok(url)
}

/// Waits for the user to approve the connection in the browser.
/// Returns Ok(()) when approved. Returns Err on network failure or expiry —
/// in that case call [request_connection] again to get a fresh URL and retry.
pub async fn wait_for_approval() -> Result<()> {
    eprintln!("[SiaBridge/Rust] wait_for_approval: called");
    let state = pending_lock()
        .lock()
        .await
        .take();

    eprintln!("[SiaBridge/Rust] wait_for_approval: state after take = {}", match &state {
        Some(OnboardingState::AwaitingApproval(_)) => "AwaitingApproval",
        Some(OnboardingState::AwaitingPhrase(_)) => "AwaitingPhrase",
        None => "None",
    });

    let state = state.ok_or_else(|| anyhow!("no pending onboarding — call request_connection() first"))?;

    let builder = match state {
        OnboardingState::AwaitingApproval(b) => b,
        already_approved @ OnboardingState::AwaitingPhrase(_) => {
            // Already approved; put the state back and return success.
            eprintln!("[SiaBridge/Rust] wait_for_approval: already in AwaitingPhrase, returning Ok");
            pending_lock().lock().await.replace(already_approved);
            return Ok(());
        }
    };

    eprintln!("[SiaBridge/Rust] wait_for_approval: polling builder.wait_for_approval()");
    let approved = match builder.wait_for_approval().await {
        Ok(a) => {
            eprintln!("[SiaBridge/Rust] wait_for_approval: approved!");
            a
        }
        Err(e) => {
            eprintln!("[SiaBridge/Rust] wait_for_approval: poll failed: {e}");
            // builder is consumed by wait_for_approval(self) — cannot restore.
            // Caller must restart from request_connection().
            return Err(anyhow!("wait_for_approval: {e}"));
        }
    };

    pending_lock()
        .lock()
        .await
        .replace(OnboardingState::AwaitingPhrase(approved));
    Ok(())
}

/// Complete registration after [wait_for_approval] succeeds.
/// Returns the hex-encoded App Key.
pub async fn register_with_phrase(recovery_phrase: String) -> Result<String> {
    let state = pending_lock()
        .lock()
        .await
        .take()
        .ok_or_else(|| anyhow!("no pending onboarding — call request_connection() first"))?;

    let builder = match state {
        OnboardingState::AwaitingPhrase(b) => b,
        OnboardingState::AwaitingApproval(_) => {
            return Err(anyhow!(
                "not yet approved — call wait_for_approval() first"
            ));
        }
    };

    let sdk = builder
        .register(&recovery_phrase)
        .await
        .map_err(|e| anyhow!("register: {e}"))?;

    let app_key_hex = hex::encode(sdk.app_key().export());
    sdk_lock().lock().await.replace(sdk);
    Ok(app_key_hex)
}

/// Generate a new BIP-39 12-word recovery phrase.
#[frb(sync)]
pub fn generate_recovery_phrase() -> String {
    sia_generate_recovery_phrase()
}

/// Validate a BIP-39 recovery phrase. Returns Ok(()) or an error message.
#[frb(sync)]
pub fn validate_phrase(phrase: String) -> Result<()> {
    validate_recovery_phrase(&phrase).map_err(|e| anyhow!("{e}"))
}

/// Reconnect to the indexer using a previously stored App Key (hex-encoded).
/// Must be called at app startup before any object operations.
pub async fn connect(app_key_hex: String) -> Result<()> {
    let mut seed = [0u8; 32];
    hex::decode_to_slice(&app_key_hex, &mut seed)
        .map_err(|e| anyhow!("invalid app key hex: {e}"))?;
    let app_key = AppKey::import(seed);

    let builder = Builder::new(INDEXER_URL, APP_META)
        .map_err(|e| anyhow!("builder: {e}"))?;

    let sdk = builder
        .connected(&app_key)
        .await
        .map_err(|e| anyhow!("connect: {e}"))?
        .ok_or_else(|| anyhow!("invalid or revoked App Key"))?;

    sdk_lock().lock().await.replace(sdk);
    Ok(())
}

// ---------------------------------------------------------------------------
// Object Operations
// ---------------------------------------------------------------------------

/// Upload data with metadata, pin the object, and return its hex object ID.
pub async fn upload_and_pin(data: Vec<u8>, metadata_json: String) -> Result<String> {
    let sdk = get_sdk().await?;
    let reader = Cursor::new(data);
    let mut obj = sdk
        .upload(Object::default(), reader, UploadOptions::default())
        .await
        .map_err(|e| anyhow!("upload: {e}"))?;

    obj.metadata = metadata_json.into_bytes();

    sdk.pin_object(&obj)
        .await
        .map_err(|e| anyhow!("pin: {e}"))?;

    Ok(obj.id().to_string())
}

/// Upload multiple small objects packed into shared slabs for efficiency.
/// Returns a list of hex object IDs in the same order as the input items.
///
/// Uses reduced shard counts (3 data + 9 parity = 12 total) for faster
/// uploads while maintaining 4× redundancy and >99.99% recovery probability.
/// Shard-level progress is available via [get_shard_progress].
pub async fn upload_packed_and_pin(items: Vec<UploadItem>) -> Result<Vec<String>> {
    let started = std::time::Instant::now();
    let total_bytes: usize = items.iter().map(|i| i.data.len()).sum();
    println!("[upload_packed] START — {} item(s), {} bytes total", items.len(), total_bytes);

    let sdk = get_sdk().await?;
    println!("[upload_packed] +{:?} — got SDK, creating packed upload", started.elapsed());

    // Fewer shards = fewer host connections = faster upload.
    // 3 data + 9 parity = 12 total (vs default 30), 4× redundancy.
    let data_shards: u8 = 3;
    let parity_shards: u8 = 9;
    let total_shards = (data_shards as u32) + (parity_shards as u32);

    SHARD_CURRENT.store(0, Ordering::Relaxed);
    SHARD_TOTAL.store(total_shards, Ordering::Relaxed);

    let opts = UploadOptions {
        data_shards,
        parity_shards,
        ..Default::default()
    }
    .on_shard_uploaded(|_sp| {
        SHARD_CURRENT.fetch_add(1, Ordering::Relaxed);
    });

    let mut packed = sdk
        .upload_packed(opts)
        .map_err(|e| anyhow!("create packed upload: {e}"))?;
    println!("[upload_packed] +{:?} — slab_remaining={}, shards={}, adding items…", started.elapsed(), packed.remaining(), total_shards);

    for (i, item) in items.iter().enumerate() {
        packed
            .add(Cursor::new(item.data.clone()))
            .await
            .map_err(|e| anyhow!("packed add[{}]: {e}", i))?;
        println!("[upload_packed] +{:?} — added item {} ({} bytes), remaining in slab: {}",
            started.elapsed(), i, item.data.len(), packed.remaining());
    }

    println!("[upload_packed] +{:?} — finalizing (uploading slab to hosts)…", started.elapsed());
    let mut objects = packed
        .finalize()
        .await
        .map_err(|e| anyhow!("packed finalize: {e}"))?;
    println!("[upload_packed] +{:?} — finalize done, got {} object(s), pinning…", started.elapsed(), objects.len());

    let mut ids = Vec::with_capacity(objects.len());
    for (i, obj) in objects.iter_mut().enumerate() {
        if let Some(item) = items.get(i) {
            obj.metadata = item.metadata_json.clone().into_bytes();
        }
        sdk.pin_object(obj)
            .await
            .map_err(|e| anyhow!("pin packed[{}]: {e}", i))?;
        let id = obj.id().to_string();
        println!("[upload_packed] +{:?} — pinned item {} → {}", started.elapsed(), i, &id[..12]);
        ids.push(id);
    }

    println!("[upload_packed] DONE — {} item(s) in {:?}", ids.len(), started.elapsed());
    Ok(ids)
}

/// Download an object by hex ID. Returns the data bytes, metadata JSON, and size.
pub async fn download_object(object_id: String) -> Result<SiaObject> {
    let sdk = get_sdk().await?;
    let oid = Hash256::from_str(&object_id)
        .map_err(|e| anyhow!("download_object: invalid object id (len={}, value='{}'): {e}", object_id.len(), object_id))?;

    let obj = sdk
        .object(&oid)
        .await
        .map_err(|e| anyhow!("object: {e}"))?;

    let mut bytes: Vec<u8> = Vec::new();
    let mut dl = sdk
        .download(&obj, DownloadOptions::default())
        .map_err(|e| anyhow!("download: {e}"))?;
    dl.read_to_end(&mut bytes)
        .await
        .map_err(|e| anyhow!("read download: {e}"))?;

    let metadata_json = String::from_utf8(obj.metadata)
        .unwrap_or_else(|_| "{}".to_string());

    Ok(SiaObject {
        object_id,
        data: bytes.clone(),
        metadata_json,
        size: bytes.len() as u64,
    })
}

/// Update metadata on a pinned object without re-uploading data.
pub async fn update_object_metadata(object_id: String, metadata_json: String) -> Result<()> {
    let started = std::time::Instant::now();
    println!("[update_metadata] START — object={}, meta_len={}", &object_id[..object_id.len().min(12)], metadata_json.len());

    let sdk = get_sdk().await?;
    let oid = Hash256::from_str(&object_id)
        .map_err(|e| anyhow!("update_object_metadata: invalid object id (len={}, value='{}'): {e}", object_id.len(), object_id))?;

    let mut obj = sdk
        .object(&oid)
        .await
        .map_err(|e| anyhow!("object: {e}"))?;
    println!("[update_metadata] +{:?} — fetched object, updating…", started.elapsed());

    obj.metadata = metadata_json.into_bytes();

    sdk.update_object_metadata(&obj)
        .await
        .map_err(|e| anyhow!("update metadata: {e}"))?;
    println!("[update_metadata] DONE in {:?}", started.elapsed());

    Ok(())
}

/// Delete a pinned object and prune unreferenced slabs.
pub async fn delete_object(object_id: String) -> Result<()> {
    let started = std::time::Instant::now();
    println!("[delete_object] START — object={}", &object_id[..object_id.len().min(12)]);

    let sdk = get_sdk().await?;
    let oid = Hash256::from_str(&object_id)
        .map_err(|e| anyhow!("delete_object: invalid object id (len={}, value='{}'): {e}", object_id.len(), object_id))?;

    sdk.delete_object(&oid)
        .await
        .map_err(|e| anyhow!("delete: {e}"))?;
    println!("[delete_object] +{:?} — deleted, pruning slabs…", started.elapsed());

    sdk.prune_slabs()
        .await
        .map_err(|e| anyhow!("prune: {e}"))?;
    println!("[delete_object] DONE in {:?}", started.elapsed());

    Ok(())
}

/// Fetch object events for incremental sync.
/// Pass an empty cursor on first call.  Returns events and whether more pages exist.
pub async fn list_objects(cursor_after: String, cursor_id: String, limit: u32) -> Result<SyncResult> {
    let sdk = get_sdk().await?;

    let cursor = if cursor_after.is_empty() {
        None
    } else {
        Some(ObjectsCursor {
            after: cursor_after
                .parse()
                .map_err(|e| anyhow!("invalid cursor timestamp (value='{}'): {e}", cursor_after))?,
            id: Hash256::from_str(&cursor_id)
                .map_err(|e| anyhow!("invalid cursor id (len={}, value='{}'): {e}", cursor_id.len(), cursor_id))?,
        })
    };

    let events = sdk
        .object_events(cursor, Some(limit as usize))
        .await
        .map_err(|e| anyhow!("object_events: {e}"))?;

    let has_more = events.len() == limit as usize;

    let mapped: Vec<SiaObjectEvent> = events
        .into_iter()
        .map(|ev| {
            let metadata_json = ev
                .object
                .as_ref()
                .map(|o| String::from_utf8_lossy(&o.metadata).to_string());
            SiaObjectEvent {
                object_id: ev.id.to_string(),
                deleted: ev.deleted,
                metadata_json,
                updated_at: ev.updated_at.to_rfc3339(),
            }
        })
        .collect();

    Ok(SyncResult {
        events: mapped,
        has_more,
    })
}

/// Share an object — returns a time-limited public URL.
pub async fn share_object(object_id: String, expires_hours: u32) -> Result<String> {
    let sdk = get_sdk().await?;
    let oid = Hash256::from_str(&object_id)
        .map_err(|e| anyhow!("share_object: invalid object id (len={}, value='{}'): {e}", object_id.len(), object_id))?;

    let obj = sdk
        .object(&oid)
        .await
        .map_err(|e| anyhow!("object: {e}"))?;

    let expires = Utc::now() + Duration::hours(expires_hours as i64);
    let url = sdk
        .share_object(&obj, expires)
        .map_err(|e| anyhow!("share: {e}"))?;

    Ok(url.to_string())
}

/// Delete all pinned objects from the connected account.
/// Pages through all object events and deletes each one.
/// Returns the number of objects deleted.
pub async fn delete_all_objects() -> Result<u32> {
    let sdk = get_sdk().await?;
    let mut deleted = 0u32;
    let mut cursor: Option<ObjectsCursor> = None;

    loop {
        let events = sdk
            .object_events(cursor, Some(100))
            .await
            .map_err(|e| anyhow!("object_events: {e}"))?;

        if events.is_empty() {
            break;
        }

        for ev in &events {
            if !ev.deleted {
                if let Err(e) = sdk.delete_object(&ev.id).await {
                    // Best-effort: log and continue
                    eprintln!("delete_all_objects: failed to delete {}: {e}", ev.id);
                } else {
                    deleted += 1;
                }
            }
        }

        let last = events.last().unwrap();
        cursor = Some(ObjectsCursor {
            after: last.updated_at,
            id: last.id,
        });
    }

    // Prune unreferenced slabs once after all deletes.
    sdk.prune_slabs()
        .await
        .map_err(|e| anyhow!("prune: {e}"))?;

    Ok(deleted)
}
