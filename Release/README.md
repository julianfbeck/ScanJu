# ScanJu TestFlight — 1.0 (2)

Distribution status checked: November 2, 2026. The official app uses bundle ID
`com.julianbeck.ScanJu` and requires iOS/iPadOS 17.0. Complete/Surface require
LiDAR; Close-up requires front TrueDepth plus ARKit world tracking. Unsupported
modes are disabled.

## Distribution

- [Public TestFlight link](https://testflight.apple.com/join/jDMD2rmb).
- Version 1.0 (2) uploaded, processed as `VALID`, and assigned to Public Beta
  and Internal Beta. Internal Beta has access to all builds and an internal tester.
- Apple Beta App Review is `APPROVED`; internal and external distribution both
  report `IN_BETA_TESTING`. Automatic tester notification is enabled.
  This is a dated record, not a live status.
- Feedback is enabled. Public Beta excludes Mac and Apple Vision; capture requires
  physical iPhone/iPad depth-camera hardware.

## Build 2 changes

- Removed the four-minute cutoff and app-imposed heat/memory-warning stops.
  Memory warnings flush caches while recording continues.
- Low storage ends capture with checkpoints retained; 150 MB is reserved for saving.
  If RoomPlan ends independently, detailed mesh, points and RGB-D continue with
  the latest floor plan retained.
- Complete ZIP exports support ZIP64 beyond classic size/count limits. USDZ keeps
  its format limits, with other export formats and original source data retained.
- iOS can still interrupt the camera or terminate an app under resource pressure.
  Processing and export need additional storage beyond the captured source data.

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

Apple processed Build 2 successfully on November 2, 2026. Local checks verified
IPA CRCs, distribution signatures and entitlements, matching executable/dSYM UUIDs,
privacy manifest, and encryption declaration. All 25 automated tests passed; an
independent reader verified a synthetic ZIP64 archive containing a file above
4 GiB and a subsequent large entry offset. See [TESTING.md](../TESTING.md) for
these checks and the earlier real-device capture/recovery results. This update
did not include a new long-running physical capture.

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
capture data. Storage, platform-resource and incomplete-surface/measurement limits
are stated in the beta notes. Full-room accuracy and long moving captures remain
hardware validation goals.
