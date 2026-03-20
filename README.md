# iCloud Materializer

Native macOS utility for turning iCloud Drive project trees into verified local copies.

The app is built for large coding-project folders that may contain iCloud placeholders, generated caches, hidden files, and long-running copy operations. It does not rely on Finder scripting for the normal path. Finder automation is only used as a recovery fallback when direct file-coordinated access stalls or fails.

Current operational change history lives in [CHANGELOG.md](CHANGELOG.md).

## Current Status

`iCloud Materializer` is a macOS-only SwiftUI app with a production-oriented first implementation pass.

Implemented today:
- single-project runs
- batch queue runs over direct child folders
- SQLite-backed per-job state
- staged copy, verification, promotion, and ZIP creation
- live telemetry, logs, failures, and stall warnings
- transfer scope presets for exact copies vs. coding-project copies
- priority presets for critical files first
- batch resume state and deletion manifests for later manual review

Not implemented yet:
- automatic source deletion
- a dedicated deletion review/execute UI
- App Sandbox and security-scoped bookmarks
- CI workflows in `.github/`

## What The App Does

For a single project run, the app executes this pipeline:

1. scan the full source tree, including hidden files and dotfiles
2. detect iCloud ubiquitous items and hydrate placeholders as needed
3. plan chunked work units, including earlier splitting of hydration-heavy directories so multiple workers can stay busy
4. copy each chunk into an internal staging area
5. verify staged and assembled output by path count and file sizes
6. promote the assembled tree into the visible destination
7. verify the visible destination again
8. create a ZIP of the source only after verification passes

For batch runs, the selected source root is treated as a queue of independent project runs. Each direct subfolder becomes its own isolated project job.

## Safety Model

The app is intentionally conservative.

- source files are never deleted by the current app
- visible targets are not merged silently
- existing visible targets are treated as conflicts
- single-project runs can quarantine an existing target only after explicit approval
- batch runs skip conflicting projects instead of merging into them
- the visible destination is verified after promotion, not just the internal assembled tree
- ZIP creation happens only after a successful visible-target verification
- batch archive/deletion preparation only creates manifests for later manual review

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

### Batch Queue

Use `Batch Queue` when you want to process all direct subfolders under one source root.

Behavior:
- each direct child folder becomes its own isolated project run
- `_Materializer_Archives` and `.icloud-materializer` are ignored as source children
- each project produces its own local copy, ZIP, and optional deletion manifest
- the next few project roots are prewarmed in the background to reduce hydration idle time between batch items
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

Custom directory-name and file-extension exclusions are supported, but the app blocks risky custom rules that would exclude core source or repo structure such as `.git`, `src`, `tests`, or common source file extensions.

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
- current phase and current path
- discovered, downloaded, copied, and failed counts
- throughput in items per second and bytes per second
- chunk progress
- live worker activity
- live event stream
- failure list
- estimated remaining work after the scan has enough information
- run-health warnings when there has been no progress for 90 seconds or more

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
- [Sources/App](Sources/App): app entry point and Info.plist
- [Sources/UI](Sources/UI): SwiftUI screens and view model
- [Sources/Core](Sources/Core): engines, models, persistence, recovery, and pipeline logic
- [Tests](Tests): unit and integration-style coverage for planning, persistence, verification, batch orchestration, naming, and run health
- [iCloud_Migration_Findings.md](iCloud_Migration_Findings.md): session findings that shaped the current architecture

## Known Limitations

- source deletion is still a manual follow-up step; the app only prepares deletion manifests
- there is no dedicated deletion review or execute workflow yet
- Finder fallback can still be fragile on very large or changing trees because it depends on macOS Automation and Finder stability
- throughput depends heavily on iCloud/File Provider behavior; larger hydration windows and project-root prewarming help, but pushing concurrency too far can still destabilize long runs
- batch copy is still promoted one project at a time; the speed-up comes from earlier hydration and better worker saturation, not from unsafe final-target merging
- the current batch resume model is queue-oriented; it does not yet expose a dedicated UI for repairing a partially successful single project at sub-phase granularity
- no CI pipeline is configured yet, so validation is currently local via `xcodebuild`

## Additional Context

The architecture was driven by the findings in [iCloud_Migration_Findings.md](iCloud_Migration_Findings.md): chunk-first execution, verify-before-promote, resume-first persistence, and explicit handling of contaminated targets.
