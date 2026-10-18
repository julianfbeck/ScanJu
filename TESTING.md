# ScanJu verification — 18 October 2026

## Build context

- Project: `ScanJu.xcodeproj`; scheme: `ScanJu`; Debug configuration.
- Device build, signing, installation, and launch: XcodeBuildMCP.
- Hardware: the attached LiDAR iPhone, iOS 27.0.1, bundle `com.julianbeck.ScanJu`.
- Device interaction: the WebDriverAgent runner on the attached iPhone; restarted
  through XcodeBuildMCP after its previous UI-testing authorization expired.
- Unit tests: iPhone 17 simulator, iOS 27; 22 passed, 0 failed.

## Large-room interruption and recovery

- The interrupted 178-second capture retained 900,000 points, 1,034,972 triangles,
  600,026 textured triangles, 180 RGB-D views, and 21 RoomPlan walls. The point and
  image counts reached the previous fixed caps; future captures have no such caps.
- Source data was copied from the phone before any app update. All 553 manifest
  files were present. The original textured USDZ passed ZIP CRC validation.
- `Processing.txt` showed packaging; a 770 MB partial ZIP existed without a final
  archive. No matching OS crash report was available, so the precise termination
  cause is unconfirmed. Fixed unbounded autoreleased file-read buffers during
  packaging and full-resolution texture decoding during preview loading.
- A complete 802,588,547-byte ZIP is now present on the phone. A fresh copy of this
  on-device archive passed all 553 CRC checks on the Mac. The recovered large mesh
  opened on the phone with camera textures visible.
- After successful validation, local capture screenshots, backups, and recovery
  archives were removed from the Mac at the user's request (3.27 GB). Device-side
  deletion was not invoked; the user clarified that cleanup applied only to the Mac.
- The on-device **Delete all scans** confirmation was opened and dismissed without
  deleting existing captures. Actual recursive deletion is tested against isolated
  temporary finished/interrupted data, including preservation of a sibling file.

## Hardware checks

- Fresh launch selects **Complete** and **Detail**. Mesh, color points, textures,
  and available RoomPlan data are captured together.
- Real camera/LiDAR capture of the visible wall/ceiling corner.
- Coverage now displays an opaque, faceted turquoise mesh with a dark triangle
  grid. Unreconstructed camera gaps are visibly distinct. Verified on the phone
  before mesh arrived and after reconstruction; the center marker changed from
  **Not captured yet** to **Mesh captured**. Wireframe and Camera controls were
  exercised and returned to Coverage successfully.
- A fresh capture with the new display processed successfully on-device, retaining
  approximately **133,000 color points** and **19 RGB-D camera views**. The saved
  textured mesh opened in the result screen. This was another partial room view.
- Complete capture retained **37,154 color points**, **6,753 triangles**, and
  **9 synchronized RGB-D camera views** in a 29-second capture.
- **6,425 triangles** received depth-checked camera textures (95%).
- Capture stopped and processing finished entirely on the phone. The saved scan
  survived an application update/relaunch and opened from the library.
- The final build displayed the textured surface and the colored point cloud.
- Files listed OBJ/MTL, USDA, USDZ, PLY, camera calibration, and all nine JPEG,
  native depth, and confidence sets. The native share sheet opened for ZIP and USDZ;
  a ZIP was also handed to Save to Files.

This hardware test covered a stationary, partial room view. A complete RoomPlan
floor plan and room dimensions were **not verified**: the phone must be moved to
observe the floor, walls, and corners. Full-room accuracy, multi-minute thermal
behavior, maximum-size scans, and importing a real capture on a second device
remain unverified.

## TrueDepth Close-up verification

- The signed build installed on the same iPhone. Launch initially failed because
  iOS reported the phone locked; launch succeeded after the user unlocked it.
- Selected **Close-up + Detail**. The device reported **TrueDepth ready**.
- Actual front capture retained **608,277 color points**, **424,196 triangles**,
  and **12 synchronized RGB-D views**. **368,512 triangles (86.9%)** received
  depth-checked camera textures. The scan duration in its record is 15.1 seconds.
- The live turquoise coverage mesh appeared over the front camera image. The
  processing progress panel appeared, and final OBJ, PLY, textured USDZ (54.8 MB),
  and complete ZIP (198.3 MB) were present in the phone container.
- Camera metadata identified `trueDepth`, `validDepthMask`, **1440×1080 RGB**,
  **640×480 float32 depth**, and unfiltered depth. Optical calibration retained
  4032×3024 reference dimensions and both 42-value distortion lookup tables.
- A single raw map was inspected: 1,228,800 depth bytes and 307,200 mask bytes;
  all 90,821 valid samples matched the exported 0/1 mask. Median accepted range
  was 0.224 m. Only small metadata and one depth/mask pair were copied to the Mac;
  temporary inspection copies and screenshots were deleted afterward.
- This checks the real sensor, live geometry, source data, and on-device export.
  It does not establish dimensional accuracy or a complete watertight object.
  Keep objects stationary; moving subjects can produce duplicate surfaces.
  Long Close-up captures, thermal behavior, and second-device import remain unverified.
- Existing phone scans were retained. The library also loaded a pre-existing
  Complete capture with 3,545,117 points and 203 camera views, beyond the old caps.

## Second phone — iPhone 13 Pro Max, iOS 26.6.1

- XcodeBuildMCP built, signed, installed and launched the same ScanJu app on the
  other attached phone. The existing WebDriverAgent session was reused.
- Fresh launch selected Complete + Detail. A rear LiDAR capture showed solid mesh
  coverage, the center captured marker, Wireframe, and Camera modes while recording.
- Deliberately terminated the test app after autosave, without finishing capture,
  then relaunched and chose **Finish saved scan**. Recovery required no camera or
  re-recording and retained **53,511 points, 2,251 triangles, 20 RGB-D views** and
  **2,078 textured faces (92.3%)**. Its textured preview opened successfully.
  This is a forced-termination test, not reproduction of an OS memory crash.
- Selected Close-up + Detail after scrolling its card fully into view and verifying
  the start button label. Native TrueDepth recording showed live coverage and a
  correct out-of-range message for the farther center surface.
- Finished the 37.7-second Close-up test: **533,816 points, 55,292 triangles,
  11 RGB-D views**, and **51,537 textured faces (93.2%)**. The progress panel and
  textured preview both appeared. Captured data is 1440×1080 RGB and 640×480 raw
  float32 depth with both 42-value distortion LUTs and a valid-depth mask.
- Copied its 60.9 MB ZIP temporarily for validation: all **42 entries passed CRC**,
  all manifest paths existed, every mask matched the finite accepted depth range
  in all 11 raw frames, and PLY binary length matched all 533,816 points. The nested
  USDZ also passed CRC and contained the mesh plus every original JPEG.
- The native share sheet opened with the 60.9 MB ZIP and offered AirDrop and
  Save to Files. No message or external transfer was sent.
- Phone test scans remain saved. Temporary Mac archive, metadata and screenshots
  were removed after inspection. No existing phone scan was deleted.
- These stationary partial-surface tests do not establish full-room dimensions,
  close-up dimensional accuracy, watertight object quality, or long-run thermal behavior.

## Automated coverage

1. Camera-pose/depth unprojection and projection round trip, including ARKit -Z.
2. Negative voxel coordinates do not merge across the origin.
3. Concave floor area and reversed polygon winding.
4. Binary PLY coordinate/color round trip.
5. ZIP CRC32, local entry, and central-directory signatures.
6. Unobserved mesh faces retain neutral materials.
7. Texture projection rejects an occluded surface.
8. Complete processing creates a reloadable library record and transferable files.
9. Nested camera images resolve in preview; textured USDZ imports back into SceneKit
   with both triangles and UV coordinates intact.
10. USDZ ZIP entries are uncompressed and 64-byte aligned, including 1–3-byte
    padding edge cases.
11. Coverage classification rejects a foreground surface in front of an existing
    mesh, tolerates depth noise, and handles missing depth, range, and lost tracking.

12. Disk-backed cloud exports and reopens 1,048,577 points, including negative tile
    coordinates, cache eviction, duplicate fusion, and points beyond the old cap.
13. Recovery rebuilds an interrupted capture from point/mesh checkpoints, skips an
    incomplete mesh anchor, and reaches 100% without opening a camera.
14. Interrupted export repair ignores partial ZIP data and preserves source PLY.
15. Streaming ZIP byte progress is monotonic; replacement and CRC32 are valid.
16. Delete all removes completed scans, exports, and interrupted source data while
    preserving files outside the scan folder; repeated empty deletion succeeds.

17. TrueDepth calibration scales intrinsics, preserves radial LUTs in JSON, and
    round trips distorted depth pixels through world coordinates and texture UVs.
18. Existing rear camera metadata decodes without optional TrueDepth fields.
19. Close-up mesh generation preserves camera pose and front-facing winding,
    rejects invalid range and holes, and never bridges foreground/background steps.
20. Repeated close-up views do not stack mesh patches; opposite sides are retained.
21. TrueDepth valid-depth masks support textures, with tighter occlusion rejection.
22. Interrupted Close-up capture recovers 1.5 mm voxels without coarse-grid merging.

Final test result: `test_sim_2026-10-18T17-29-12-966Z_pid65548_3e272f17.xcresult`
in the local XcodeBuildMCP workspace's `result-bundles` directory.

Future private device screenshots belong in ignored `DeviceEvidence/`.

## TestFlight release preparation — October 18, 2026

Release 1.0 (1) archives successfully through XcodeBuildMCP. The final source adds
an in-app privacy page, the required disk-space privacy reason, and the non-exempt
encryption declaration. Existing capture tests above precede these privacy-only
changes; the final Release archive verifies that they compile and bundle correctly.

The App Store Connect IPA passes Apple's server validation with no errors.
Independent local checks verify ZIP CRCs, the distribution certificate chain,
strict sealed-resource signatures, disabled debugger entitlement, active beta
reports, the privacy manifest, and the opaque 1024-pixel app icon. The archived
arm64 executable and dSYM share UUID `40CEFD00-03C7-3C40-AD3C-94B8A2907F65`.

Artifacts and validation receipts are retained privately in the maintainer's local
`Release/` directory and excluded from Git; the public dated distribution note is
in `Release/README.md`. This release preparation does not replace the phone
installations or delete phone scans. Only the superseded prototype archive from
this release-preparation session was removed from the Mac.
