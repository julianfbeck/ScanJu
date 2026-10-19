# ScanJu TestFlight — 1.0 (1)

Distribution status checked: October 19, 2026. The official app uses bundle ID
`com.julianbeck.ScanJu` and requires iOS/iPadOS 17.0. Complete/Surface require
LiDAR; Close-up requires front TrueDepth plus ARKit world tracking. Unsupported
modes are disabled.

## Distribution

- [Public TestFlight link](https://testflight.apple.com/join/jDMD2rmb).
- Version 1.0 (1) uploaded, processed successfully, and assigned to Public Beta.
- Apple Beta App Review is `APPROVED`; external distribution is `BETA_APPROVED`.
  The public link displays **View in TestFlight** and accepts testers.
  This is a dated record, not a live status.
- Feedback is enabled. Mac and Apple Vision availability are disabled because
  capture requires physical iPhone/iPad depth-camera hardware.

## Public metadata and private artifacts

This folder publishes `beta-description.txt`, `what-to-test.txt`,
`review-notes.txt`, and `privacy-policy.md` for review and future beta updates.
The app also presents its privacy information inside Scanning guide → Your data
→ Privacy and contact.

The maintainer retains the signed Release archive, IPA, matching dSYM symbols,
Apple validation results, and upload receipts privately. They are excluded from
Git along with provisioning profiles, certificates, private keys, and keychains.
A fresh clone contains source and beta documentation; build your own installation
using the [local setup guide](../README.md#install-and-run-locally).

Apple's server validation succeeded without errors on October 18, 2026. Local
checks verified archive CRCs, distribution signatures and entitlements, matching
executable/dSYM UUIDs, privacy manifest, encryption declaration, and an opaque
1024-pixel icon. See [TESTING.md](../TESTING.md) for 22 automated test results and
real-device capture/recovery checks. The Release archive includes subsequent
privacy-only UI and metadata changes.

## Subsequent releases

Use your own authorized distribution setup; no signing or service credentials
are provided by this public repository. `project.yml` remains the source of build
settings. Increment `CURRENT_PROJECT_VERSION` for each uploaded binary,
regenerate using `xcodegen generate`, and archive through XcodeBuildMCP. Keep
matching symbols and confirm App Store Connect's existing state before retrying
an upload. Distribution changes require an explicit release request.

The first export on the maintainer's Mac selected an incompatible Homebrew rsync
in an Apple subprocess. Putting Apple's utilities first in `PATH`
(`/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin`) resolved that local export issue.

The app processes scans locally and has no account, purchases, analytics SDK, or
developer-operated cloud upload. Exports include original camera images and raw
capture data. Capture/resource limits and incomplete-surface/measurement limits
are stated in the beta notes. Full-room accuracy and long moving captures remain
hardware validation goals.
