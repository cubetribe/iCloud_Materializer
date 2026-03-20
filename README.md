# iCloud Materializer

Native macOS utility for materializing iCloud project trees into a verified local mirror, with staged copy, chunk planning, SQLite-backed progress tracking, and a post-verify ZIP phase.

## Build

```bash
xcodegen
xcodebuild -scheme iCloudMaterializer -destination 'platform=macOS' build
xcodebuild -scheme iCloudMaterializer -destination 'platform=macOS' test
```

## Notes

- v1 is unsandboxed to keep direct filesystem access and Finder automation fallback available.
- Recovery via Finder requires macOS Automation permission for Finder.
- The source tree is never deleted; the ZIP is only moved into the source root after successful verification.
