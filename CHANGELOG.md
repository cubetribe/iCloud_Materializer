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

### Changed
- Final completion now depends on verifying the visible promoted target, not only the internal assembled tree.
- Batch ZIP archives are written to `<source root>/_Materializer_Archives/` instead of being mixed into each source project directory.
- The UI now exposes stalled-run health signals to make long iCloud operations easier to monitor.
- Batch runs now prewarm the next project roots and split hydration-heavy directories earlier, so large iCloud trees can use the worker pool more effectively.
- Hydration workers now rotate slow iCloud items out of hot slots after a short window, cool them down on a retry schedule, and keep other files moving instead of stalling the pipeline.
- README expanded into an operational guide covering run modes, safety model, runtime artifacts, resume behavior, and repo relocation.

### Fixed
- Restored and re-validated the batch queue implementation after workspace recovery.
- Hardened batch resume so already completed restorable projects can be skipped safely on reruns.
- Improved batch target naming so naming strategy is explicit and previewed before runs start.
- Added a planner safety budget so pathological directory shapes cannot leave long batch runs spinning indefinitely in `planningChunks`.
