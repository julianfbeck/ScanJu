# Working on ScanJu

Read [README.md](README.md) for installation and [TESTING.md](TESTING.md) for
verified behavior and hardware limitations. ScanJu is a native SwiftUI iOS 17+
application with Apple frameworks only. No backend, external SDK, API key, or
package-manager dependency is required by the app.

## Get running

Work from the repository root. Open `ScanJu.xcodeproj`, select the **ScanJu**
scheme and an installed iPhone simulator, then run or test in Xcode. The generated
project and shared scheme are committed; `project.yml` is the authoritative spec.
After changing sources, targets, or build settings, run `xcodegen generate` and
commit the resulting project changes with the spec/source changes.

The tested CLI toolchain is XcodeGen 2.46.0, XcodeBuildMCP 2.7.0, and Xcode 27.0.
See the README for installation commands and personal device signing. Existing
maintainer signing identifiers do not grant signing access; use your own team and
unique bundle identifier for personal device builds. Keep personal signing edits local.

Use XcodeBuildMCP first for Apple builds, tests, launches, logs, and UI automation.
With MCP tools, first read `session_show_defaults`, then set the absolute
`projectPath`, `scheme: ScanJu`, and an available simulator. Use `build_run_sim`
for launch and `test_sim` for tests. Avoid inheriting another checkout's defaults.
When using the CLI, pass the project, scheme, and destination explicitly:

```sh
xcodegen generate
xcodebuildmcp simulator list
export SCANJU_SIMULATOR_ID='PASTE_AN_AVAILABLE_SIMULATOR_ID'
xcodebuildmcp simulator build-and-run \
  --project-path "$PWD/ScanJu.xcodeproj" --scheme ScanJu \
  --simulator-id "$SCANJU_SIMULATOR_ID" \
  --derived-data-path "$PWD/build-simulator"
xcodebuildmcp simulator test \
  --project-path "$PWD/ScanJu.xcodeproj" --scheme ScanJu \
  --simulator-id "$SCANJU_SIMULATOR_ID" \
  --derived-data-path "$PWD/build-simulator"
```

Simulator capture modes are disabled because there is no physical depth sensor.
Run synthetic geometry/format/recovery tests there; use permitted real hardware
for LiDAR, TrueDepth, camera textures, coverage, and RoomPlan validation. Do not
report a simulated test as proof of real sensor behavior or measurement accuracy.

## Code map

| Area | Files and responsibility |
| --- | --- |
| App/library | `ScanJuApp.swift`, `LibraryView.swift`, `ScanData.swift`: entry, mode/quality selection, saved records and data conventions |
| Capture | `CaptureEngine.swift`, `CaptureScreen.swift`: shared ARKit/RoomPlan session, frame acquisition, serialized capture work and controls |
| Coverage | `CoverageOverlay.swift`: live mesh materials and center-surface coverage classification |
| Depth geometry | `DepthCalibration.swift`, `DepthSurfaceBuilder.swift`: sensor calibration, distortion, observed TrueDepth surface fusion |
| Persistent points | `PointCloudStore.swift`: disk-backed voxel tiles, bounded cache and PLY export |
| Recovery | `ScanRecovery.swift`, `RecoveryView.swift`: checkpoints, interrupted scan/export recovery and progress |
| Processing/export | `ScanProcessor.swift`, `USDMeshWriter.swift`, `ZipArchive.swift`: texture projection, plans, OpenUSD/USDZ and streaming archives |
| Preview/privacy | `ScanDetailView.swift`, `MeshPreviewLoader.swift`, `PrivacyView.swift`, `PrivacyInfo.xcprivacy` |
| Tests/tools | `ScanJuTests/ScanJuTests.swift`, `Tools/device_test.py`, `Tools/make_icon.swift` |

Swift source paths in the table are relative to `ScanJu/`. Keep changes focused
and follow the current Swift/SwiftUI patterns before adding an abstraction or dependency.

The distributable room-modeling skill is in `skills/scanju-room-reconstruction/`.
Its `SKILL.md` routes to export/calibration and Blender delivery references; the
Python inspector and its tests use only the standard library. Run
`python3 -m unittest discover -s skills/scanju-room-reconstruction/scripts -v`
when changing the helper. Keep the workflow generic; private capture coordinates
and one-off apartment scripts do not belong in the published skill.

## Capture and storage contracts

- Complete + Detail defaults to geometry, color points, camera textures, raw RGB-D,
  calibration, and available RoomPlan data. Coverage/Wireframe/Camera affect the
  display, not the captured channels.
- Preserve disk-backed point fusion, bounded memory, streaming packaging, atomic
  writes, and recoverable source files. Never reintroduce a fixed point/keyframe
  cap or load a complete large scan/full-resolution texture collection into RAM.
- Mesh updates and point/metadata checkpoints must survive interruption.
  `Finish saved scan` must process the saved capture without opening the camera.
  Do not delete checkpoints or source data when processing/export fails.
- Keep expensive capture, recovery, and export work off the UI thread and publish
  UI state safely. Preserve stage/percentage progress and resource-stop behavior.
- Coordinate units are meters in ARKit right-handed Y-up space; transforms are
  column-major. Raw depth is packed little-endian float32. Rear confidence is
  0/1/2, while TrueDepth exports a 0/1 valid-depth mask. Keep calibration and
  distortion metadata compatible with old saved records.
- TrueDepth uses raw sensor depth/color, not face landmarks, expressions, or Face ID
  authentication. Grid spacing is a fusion setting, not a hardware accuracy claim.
- Keep original camera textures in exports and bounded decoded textures in previews.
  Reject occluded projections and leave unobserved faces neutral. Do not imply
  that observed partial surfaces are watertight or construction-grade measurements.

## Tests and device care

Run the ScanJu test scheme after changing capture math, storage, recovery, preview,
or export code. Its 22 tests cover projection/calibration, coverage, disk-backed
points beyond the old cap, interruption recovery, deletion isolation, ZIP CRC and
USDZ alignment/import, textures, and TrueDepth surface edges. Add a regression test
when fixing one of these contracts; use isolated temporary scan directories.
Small documentation-only changes do not need a device scan.

For authorized hardware testing, follow the README device instructions. Reuse an
existing RepDrive/WebDriverAgent session through `Tools/device_test.py`, setting
`SCANJU_WDA_URL` and the appropriate `SCANJU_BUNDLE_ID`. Do not restart someone
else's active runner just to obtain a session. Do not uninstall ScanJu, erase a
device, or invoke Delete all scans on a user's library as a routine test. Use
isolated synthetic data for destructive tests and preserve existing phone scans.

Keep screenshots in ignored `DeviceEvidence/`. Never commit private camera images,
room meshes, raw depth, scan exports, device identifiers, local network endpoints,
signing credentials, provisioning profiles, keychains, or account-specific receipts.
Review staged filenames and diffs before pushing. `.gitignore` protects build,
release, signing, and evidence output; do not force-add those artifacts.
The owner approved the two reconstructed-room renders in `docs/images/` for the
public README. Their original scan, camera images, and Blender project remain
private; the renders do not authorize publishing the underlying capture.

## Distribution

`Release/` tracks public beta copy, review guidance, privacy policy and a dated
status note. Release archives, IPA files, symbols and receipts are private local
artifacts, so they are absent from a fresh clone. App Store Connect credentials
are not required to work on the app. Upload or change distribution only when the
user asks for release work; keep build numbers unique and retain matching symbols.
Update privacy UI/policy/manifest if a change affects captured data or required APIs.
