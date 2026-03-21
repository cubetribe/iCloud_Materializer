# iCloud Materializer

Native macOS utility for turning iCloud Drive project trees into verified local copies.

The app is built for large coding-project folders that may contain iCloud placeholders, generated caches, hidden files, and long-running copy operations. It does not rely on Finder scripting for the normal path. Finder automation is only used as a recovery fallback when direct file-coordinated access stalls or fails.

Current operational change history lives in [CHANGELOG.md](CHANGELOG.md).

## Versioning

The repository version is controlled by the root-level [VERSION](VERSION) file.

Rules:
- `VERSION` is the single source of truth for the app version shown in the UI.
- The format is strict semantic versioning: `MAJOR.MINOR.PATCH`.
- Every repository change must bump `VERSION` before commit or push.
- Use a patch bump for fixes, a minor bump for new features, and a major bump for breaking workflow or compatibility changes.
- Do not hardcode the visible app version anywhere else in SwiftUI or other source files.

Build behavior:
- the root `VERSION` file is bundled into the macOS app
- the SwiftUI frontend reads that bundled file at runtime and shows it in the header automatically
- if `VERSION` is missing or not valid semantic versioning, tests should fail

## Current Status

`iCloud Materializer` is a macOS-only SwiftUI app with a production-oriented first implementation pass.

Implemented today:
- single-project runs
- batch queue runs over direct child folders
- SQLite-backed per-job state
- automatic per-session JSONL log files under `~/Library/Logs/iCloudMaterializer/`
- coalesced UI update delivery and large-queue rendering guards so long batch runs stay observable without stalling the rescue workers
- mandatory preflight before rescue runs start
- shallow-first discovery, hydration, staged copy, verification, and promotion
- live telemetry, logs, failures, stall warnings, and hydration-state timing
- transfer scope presets for exact copies vs. coding-project copies
- priority presets for critical files first
- batch resume state and deletion manifests for later manual review
- conservative default concurrency for rescue stability

Not implemented yet:
- automatic ZIP creation in the default rescue path
- automatic source deletion
- a dedicated deletion review/execute UI
- App Sandbox and security-scoped bookmarks
- CI workflows in `.github/`

## What The App Does

For a single project run, the app executes this pipeline:

1. run a mandatory preflight and block the start until required checks are green
2. discover top-level entries first instead of waiting for a whole-tree scan
3. hydrate cold iCloud items with explicit queued/downloading/stalled/request-failed state tracking
4. plan smaller work units so ready files can move while colder items continue hydrating
5. copy each chunk into an internal staging area
6. verify staged and assembled output by path count and file sizes
7. promote the assembled tree into the visible destination
8. verify the visible destination again
9. stop after the verified local copy is complete; ZIP creation is a later manual follow-up

For batch runs, the selected source root is treated as a queue of independent project runs. Each direct subfolder becomes its own isolated project job.

## Preflight

The rescue preflight is mandatory. The app will not start a run until required checks are resolved or explicitly confirmed.

Preflight currently covers:
- readable source root
- writable local destination
- destination outside likely iCloud Drive paths
- destination free-space thresholds
- top-level source availability to catch cloud-only folders early
- a scan-risk warning for `.git/objects`
- manual confirmations for `Sync this Mac`, Finder `Keep Downloaded`, permissions, and competing sync tools

## Safety Model

The app is intentionally conservative.

- source files are never deleted by the current app
- visible targets are not merged silently
- existing visible targets are treated as conflicts
- single-project runs can quarantine an existing target only after explicit approval
- batch runs skip conflicting projects instead of merging into them
- the visible destination is verified after promotion, not just the internal assembled tree
- the default rescue path completes after a successful visible-target verification
- automatic ZIP creation is disabled by default so the critical path stays focused on getting the local copy back first
- batch archive/deletion preparation only creates manifests for later manual review when archive creation is enabled again

## Run Modes

### Single Project

Use `Single Project` when you want to copy one selected iCloud project folder into one local destination root.

Visible result:
- `<destination>/<source folder name>`

Internal runtime artifacts:
- `<destination>/.icloud-materializer/<job-id>/state.sqlite`
- `<destination>/.icloud-materializer/<job-id>/staging/`
- `<destination>/.icloud-materializer/<job-id>/assembled/`
- `<destination>/.icloud-materializer/<job-id>/archive/`
- `<destination>/.icloud-materializer/<job-id>/quarantine/`

Retry behavior:
- rerunning the same source, destination, and transfer-scope combination reuses the same rescue job identity
- if a previous single-project run already discovered the tree, the next retry can reuse that persisted inventory instead of starting from a full rescan

### Batch Queue

Use `Batch Queue` when you want to process all direct subfolders under one source root.

Behavior:
- each direct child folder becomes its own isolated project run
- `_Materializer_Archives` and `.icloud-materializer` are ignored as source children
- each project produces its own local copy; archive/deletion review is no longer part of the default critical path
- very large queues are windowed in the live UI so monitoring stays responsive while the full persisted batch state still tracks every project
- project-root prewarming is disabled by default for rescue runs
- completed batch projects can be resumed or skipped on later reruns when their expected outputs still exist

Batch runtime artifacts:
- batch resume state: `<destination>/.icloud-materializer/batch-resume/<resume-key>/batch-state.json`
- deletion manifests: `<destination>/.icloud-materializer/batches/<batch-id>/deletion-manifests/*.json`
- batch ZIP archives: `<source root>/_Materializer_Archives/*.zip`

## Batch Target Naming

Batch mode supports three naming strategies for the local target folder:

- `Suffix`: `Project` -> `Project-Lokal`
- `Prefix`: `Project` -> `Lokal-Project`
- `Template`: `Project` -> any pattern containing `{name}`, for example `Archive-{name}-2026`

The naming scheme is part of the batch resume identity. Changing it creates a separate batch resume state.

## Transfer Scope

The app has two transfer-scope presets.

### Exact Copy

`Exact Copy` inventories and copies everything it can see, including hidden files and dotfiles.

### Coding Project

`Coding Project` excludes clearly rebuildable or generated content so large project trees can move faster and more safely.

Built-in exclusions include:
- Python virtual environments and caches such as `.venv`, `venv`, `env`, `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.tox`, `.nox`
- JavaScript dependency and build directories such as `node_modules`, `.pnpm-store`, `.parcel-cache`, `.next`, `.nuxt`, `.svelte-kit`, `.turbo`
- generated build/tooling directories such as `.gradle`, `.dart_tool`, `DerivedData`
- generated files such as `.DS_Store`, `Thumbs.db`, `.pyc`, `.pyo`

Custom directory-name and file-extension exclusions are supported, but the app still blocks risky custom rules that would exclude core source paths such as `src`, `tests`, or common source file extensions. `.git` is the one notable exception now, because explicitly skipping Git object history can be the right tradeoff for a rescue run when discovery time dominates.

## Copy Priority

Priority changes the order of work, not what gets included.

### Natural Order

Default chunk order.

### Critical First

Front-loads the most important content:
- critical environment and runtime config files first, including `.env` and `.env.*`
- base code, manifests, scripts, and key config files next
- standard content afterwards
- reports, screenshots, logs, and similar artifacts later

This mode is useful when you need the project to become operational before every low-value artifact is copied.

## Telemetry And Recovery Signals

The UI exposes:
- preflight status and required confirmations
- current phase and current path
- discovered, downloaded, copied, and failed counts
- throughput in items per second and bytes per second
- chunk progress
- hydration request, failure, queued, ready, and stalled counts
- live worker activity
- live event stream
- failure list
- estimated remaining work after discovery has enough information
- run-health warnings when there has been no progress for 90 seconds or more
- the current session log file path plus direct access to the log folder

## Persistent Log Files

The app now writes persistent newline-delimited JSON log files automatically for every session.

Location:
- session log folder: `~/Library/Logs/iCloudMaterializer/`
- current session file: `session-YYYYMMDD-HHMMSS.log.jsonl`
- stable latest-session pointer: `latest.log.jsonl`

What is logged:
- app launch and termination
- user actions such as start, pause, resume, cancel, quarantine approval, and log export
- pipeline events written through the internal job logger
- batch project start/completion/failure
- fatal startup failures and job-level failures

Operational rule:
- when a run fails or the app appears to crash, inspect `latest.log.jsonl` first
- keep the log file together with the exported SQLite/job state when reporting or debugging rescue failures

Run-health thresholds:
- watch after 90 seconds without progress
- stalled warning after 5 minutes without progress

## Finder Recovery Fallback

The direct path uses Foundation/AppKit APIs, `NSFileCoordinator`, and explicit iCloud hydration.

Finder automation is recovery-only. It may be used when a chunk stalls or repeated direct retries fail. That fallback requires macOS Automation permission for Finder and is intentionally not the primary path.

## Requirements

- macOS 15.0 or later
- Xcode 16 or newer with Swift 6 support
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- a local destination outside iCloud Drive

The app is currently unsandboxed. Persistent folder bookmarks are not implemented in this first pass.

## Build And Test

From the repository root:

```bash
xcodegen
xcodebuild -scheme iCloudMaterializer -project iCloudMaterializer.xcodeproj -destination 'platform=macOS' build
xcodebuild -scheme iCloudMaterializer -project iCloudMaterializer.xcodeproj -destination 'platform=macOS' test
```

Before shipping any change, bump [VERSION](VERSION) first and keep the changelog entry under `[Unreleased]` aligned with that work.

## Moving Or Renaming The Repository Folder

The repository does not depend on a fixed absolute workspace path.

If you move or rename the project directory:

1. reopen the repository from its new path
2. run `xcodegen` again from the new repository root
3. reopen `iCloudMaterializer.xcodeproj`
4. rebuild the app

The generated Xcode project should be treated as derived from [project.yml](project.yml). If the repo location changes, regenerating is the safest way to avoid stale path assumptions.

## Repository Layout

- [project.yml](project.yml): source of truth for the Xcode project
- [VERSION](VERSION): semantic app version source of truth; bump this on every change
- [Sources/App](Sources/App): app entry point and Info.plist
- [Sources/UI](Sources/UI): SwiftUI screens and view model
- [Sources/Core](Sources/Core): engines, models, persistence, recovery, and pipeline logic
- [Tests](Tests): unit and integration-style coverage for planning, persistence, verification, batch orchestration, naming, and run health
- [iCloud_Migration_Findings.md](iCloud_Migration_Findings.md): session findings that shaped the current architecture

## Known Limitations

- source deletion is still a manual follow-up step; the app only prepares deletion manifests when archive creation is enabled
- there is no dedicated deletion review or execute workflow yet
- Finder fallback can still be fragile on very large or changing trees because it depends on macOS Automation and Finder stability
- throughput depends heavily on iCloud/File Provider behavior; this version deliberately starts with conservative concurrency and favors predictability over saturation
- batch copy is still promoted one project at a time; the speed-up now comes mainly from shallow-first discovery, earlier usable progress, and fewer cold items blocking hot work
- single-project retries can reuse persisted discovery inventory, but they do not yet resume already copied/promoted chunk state at sub-phase granularity
- the current batch resume model is queue-oriented; it does not yet expose a dedicated UI for repairing a partially successful single project at sub-phase granularity
- no CI pipeline is configured yet, so validation is currently local via `xcodebuild`

## Additional Context

The architecture was driven by the findings in [iCloud_Migration_Findings.md](iCloud_Migration_Findings.md): chunk-first execution, verify-before-promote, resume-first persistence, and explicit handling of contaminated targets.
