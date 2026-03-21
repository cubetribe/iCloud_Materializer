# Changelog

All notable changes to this repository will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This repository does not use automated releases yet. Until the first tagged release, the current app state is tracked under `[Unreleased]`.

## [Unreleased]

### Added
- Native macOS app scaffold for `iCloud Materializer` with SwiftUI UI and Foundation/AppKit-based file orchestration.
- Single-project pipeline with scan, chunk planning, hydration/materialization, staged copy, verification, promotion, and post-verify ZIP creation.
- SQLite-backed job persistence for scanned items, chunks, failures, and event logging.
- Live telemetry in the UI, including phase detail, throughput, worker activity, logs, failures, and estimated remaining work.
- `Exact Copy` and `Coding Project` transfer-scope presets.
- `Natural Order` and `Critical First` transfer-priority presets.
- Batch queue mode that treats each direct child folder of a selected source root as its own isolated project run.
- Flexible batch target naming with suffix, prefix, and template-based naming.
- Batch resume state persisted under the destination-side `.icloud-materializer` workspace.
- Batch deletion manifests for explicit later review before any source cleanup.
- Session findings document in [iCloud_Migration_Findings.md](iCloud_Migration_Findings.md).
- Mandatory rescue preflight with manual Finder/system confirmations, free-space checks, local destination validation, and `.git` scan-risk warnings.
- Hydration-state telemetry and persisted per-item hydration diagnostics for request failures, queued/downloading items, stalls, and first-useful-progress timings.
- Single-project retry resume that can reuse previously persisted discovery inventory instead of rescanning from scratch.
- Root-level `VERSION` file as the semantic-version source of truth, plus an in-app version label that reads the bundled file at runtime.
- Automatic persistent session log files under `~/Library/Logs/iCloudMaterializer/`, including a stable `latest.log.jsonl` pointer for debugging failures after the fact.

### Changed
- Versioning now follows a strict root-`VERSION` workflow: every change must bump semantic versioning there, and the frontend updates from that bundled file automatically.
- The UI now shows the active session log path and can reveal the current log file or open the log folder directly.
- Large batch runs now coalesce UI updates before they reach SwiftUI, so the rescue pipeline is no longer forced to wait on every main-thread redraw.
- The live batch queue now renders a focused project window for very large queues, and the log/failure panes use lighter-weight scrolling behavior to keep monitoring responsive during long runs.
- Final completion now depends on verifying the visible promoted target, not only the internal assembled tree.
- Batch ZIP archives are written to `<source root>/_Materializer_Archives/` instead of being mixed into each source project directory.
- The UI now exposes stalled-run health signals to make long iCloud operations easier to monitor.
- Batch runs now prewarm the next project roots and split hydration-heavy directories earlier, so large iCloud trees can use the worker pool more effectively.
- Hydration workers now rotate slow iCloud items out of hot slots after a short window, cool them down on a retry schedule, and keep other files moving instead of stalling the pipeline.
- Hydration now uses a bounded prefetch buffer ahead of active slots so iCloud downloads can be requested earlier without letting the queue grow unbounded.
- Batch prewarm now touches each upcoming project root plus a small set of direct children so directory-local iCloud content starts hydrating sooner, and resumed runs can prewarm those projects again.
- README expanded into an operational guide covering run modes, safety model, runtime artifacts, resume behavior, and repo relocation.
- Rescue runs now begin with `preflight -> shallow discovery -> hydration -> copy/verify/promote` instead of waiting for a whole-tree scan and chunk plan before the first useful copy work.
- Automatic ZIP creation is now disabled in the default rescue path so success means a verified local copy first; archive creation is deferred to a later manual step.
- Coding Project mode now allows an explicit custom `.git` exclusion so Git object stores can be skipped when scan time dominates rescue progress.
- Rescue-mode batch previews no longer keep advertising deletion readiness when archive creation is disabled.

### Fixed
- Restored and re-validated the batch queue implementation after workspace recovery.
- Hardened batch resume so already completed restorable projects can be skipped safely on reruns.
- Improved batch target naming so naming strategy is explicit and previewed before runs start.
- Fixed a UI-side hang where large batch transitions could saturate the main thread, make the app look crashed, and stall the next project handoff even though the core rescue pipeline was still healthy.
- Added a planner safety budget so pathological directory shapes cannot leave long batch runs spinning indefinitely in `planningChunks`.
- Replaced Finder-scripted recovery copies with a cancellable `ditto`-based recovery path so aborting a batch no longer leaves delayed system-level copy jobs running in the background.
- Removed silent iCloud download-request failures so rejected hydration requests surface immediately in logs, state, and failure handling.
