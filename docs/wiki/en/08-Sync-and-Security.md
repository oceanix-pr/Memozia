# 08 · Data Sync and Security

[← Home](Home.md) · Source: FileSyncService, CloudSyncService, EncryptionService

## 1. FileSyncService

[FileSyncService.swift](../../../Memozia/Services/FileSyncService.swift) treats the filesystem as authoritative and SwiftData as an index. Each recording/note has a `yyyyMMddHHmmss[-N]` directory. Disk mirrors allow rebuilding an index after database loss, provided the necessary files and encryption key are available.

### 1.1 Main flow

```text
Scan storage folders → identify unknown folderName values
→ readItemType(meta.json): recording / quicknote
→ Parallel metadata reads and audio-duration inspection
→ Serial insertion/save through the shared ModelContext
```

### 1.2 Operations

The main reconciliation also validates tracks/durations before recovering crash-left `*_mic_tmp_*.caf` / `*_sys_tmp_*.wav` segments. Notes read encrypted or legacy plaintext `source.txt` with `decryptFileOrPlaintext`, plus `source.png`, then store encrypted text in the index. `readItemType` uses `itemType == quicknote` or note-content-without-audio evidence from `hasQuickNoteContent`; otherwise it treats the folder as recording.

### 1.3 Trigger and consent

RootView's `LifecycleTasksModifier` serializes migration, stale-state reset, reconciliation, and queue recovery within a consent-keyed task. Only independent model prewarming may run concurrently. `MemoziaPrivacyPolicy.needsConsent(...)` combines consent and policy major version; do not scan user data before current consent. Withdrawal exits the app and returns to consent on relaunch. Encryption migration uses paged saves and a resumable cursor; long loops yield to keep UI responsive.

### 1.4 Reliability

- `AudioRecording.createUniqueFolder(from:)` allocates with atomic mkdir and retries `-N` on collision. Never check then create or treat an already-existing folder as a new success.
- Recheck `folderName` with `fetchLimit = 1` immediately before insertion, because a long concurrent scan may overlap import/manual refresh.
- `EntryMirrorStore` coalesces consecutive transcript/summary/visual writes to the latest value, with one writer per target. Bounded `flush()` precedes worker spawning on exit. Report failures through PersistenceReporting.
- Reconcile both ways: regenerate missing disk mirrors from populated database fields, or populate empty fields from existing mirrors. Fill missing content without overwriting existing content; ordinary entries need only a stat check.
- Distinguish a missing queue from a damaged queue. Quarantine corruption as `.corrupt-<timestamp>`, try `.bak`, and notify the user. Failure to acquire flock fails the mutation without writing. Never overwrite the queue by treating a read failure as empty.
- Read legacy 12/14-digit names after stripping collision suffixes, accept old flat storage, and prefer `meta.json` over legacy `title.txt`.
- Use atomic file writes for metadata.

## 2. CloudSyncService

[CloudSyncService.swift](../../../Memozia/Services/CloudSyncService.swift) provides account/status scaffolding, not an active cloud data pipeline. SwiftData/CloudKit would perform actual synchronization, but `cloudKitDatabase: .automatic` is disabled pending container/model configuration.

Settings declares the service without invoking account checks or CloudKit writes. The policy discloses that iCloud/CloudKit synchronization is currently disabled; enabling it requires a policy update and renewed consent. Do not manufacture success after a delay or present local saves as confirmed synchronization. Report local persistence as local persistence.

## 3. EncryptionService

Source: [EncryptionService.swift](../../../Memozia/Services/EncryptionService.swift).

### 3.1 Algorithm and key

CryptoKit AES-GCM 256 provides authenticated encryption. Store the key in Keychain with `.afterFirstUnlock`. Creation uses a lock, double-check, and memory cache to avoid concurrent key replacement and repeated Keychain reads. A failed Keychain save is an error; never encrypt with a key that exists only in memory.

### 3.2 Methods

| Method | Contract |
|---|---|
| `encrypt(_:)` | Text to Base64 ciphertext; report and throw errors so existing caller fallback remains explicit |
| `decrypt(_:)` | Ciphertext to plaintext, throwing on failure |
| `decryptSafely(_:)` | Non-Base64 legacy plaintext passes through unchanged. Only failed ciphertext decryption returns empty; erasing all plaintext would permanently lose content on the next save |
| `encryptAndWrite` / `decryptFileOrPlaintext` | File-level write/read compatibility for tasks, OCR, and source text |

### 3.3 Boundaries

| Data | Protection |
|---|---|
| TranscriptSegment.text / transcript.json | Encrypted text |
| AudioRecording.summary / summary.md | Encrypted field and mirror |
| Note body/OCR/summary and screenshot text | Encrypted fields and text files |
| todos.json | Encrypted |
| PNG originals/annotations | Not encrypted |
| m4a recordings | Not encrypted |
| `{base}_video.mp4/mov/m4v` originals | Not encrypted; transcription uses extracted audio |
| visualSummary / visual.md | Encrypted |
| Cached keyframe JPEGs | Not encrypted; may contain screen/document text |
| Whisper/LLM keys and AES key | System Keychain |
| Exported LLM configuration, including API keys | Encrypted with the same device key; same-Mac import only |

### 3.4 Migration

`encryption_migration_completed` controls the one-time upgrade. Use real decryption attempts for idempotency, not formatting guesses.

### 3.5 Configuration export

Exports use the same device key without asking for a password. The key does not accompany the file, so another Mac cannot decrypt it. Present an explicit other-Mac-or-damaged-file explanation instead of a generic format error.

Legacy unencrypted exports without API keys remain readable. Import uses throwing `decrypt(_:)`, not `decryptSafely(_:)`, so an external undecipherable file does not trigger the global alarm that local keys changed. `LLMConfig.transferPayload` temporarily contains plaintext API keys in memory; encrypt before passing bytes to the save panel. Synchronizable Keychain would change the security model and has not been adopted.

### 3.6 Memonta history and primary-key changes

New writes use the device key stored under `app.memozia.encryption` / `encryption_key`. After AES-GCM authentication fails, text and binary-file decryption first tries an archived original Memozia key in `previous_encryption_key`, then the same Mac's Memonta key in `com.Memonta.encryption` / `encryption_key`. Lookup errors remain errors; missing keys and corrupted ciphertext retain the existing failure warnings. Successful fallback keys are cached in memory under the existing lock.

The app does not automatically rotate the primary key or modify Memonta Keychain items. A user-directed primary-key replacement must first archive the original Memozia key in Keychain and read it back successfully, then update and verify the primary key. Never overwrite a different archived key. Restart the application after a manual key change to refresh its in-memory cache. Key values must never enter source control, logs, plaintext files, or distribution packages.

macOS may request permission to access historical Keychain items. This compatibility does not move data folders or import API keys: select the appropriate history folder in settings. Without the historical key, or on another Mac, use a password-protected portable backup instead.

## 4. Deletion protocol

1. Confirm single or bulk deletion.
2. Load dependent `TodoDocument` before removing its folder and clean associated EKReminder items.
3. Remove the disk folder before the database record. If disk removal fails, preserve the record so the next reconciliation cannot resurrect an apparently deleted entry.
