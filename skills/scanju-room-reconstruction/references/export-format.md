# ScanJu export and calibration

The supplied export's README and schemas take precedence if a later app version
changes the format. Current source definitions live in
[ScanData.swift](https://github.com/julianfbeck/ScanJu/blob/main/ScanJu/ScanData.swift),
[DepthCalibration.swift](https://github.com/julianfbeck/ScanJu/blob/main/ScanJu/DepthCalibration.swift),
and [ScanProcessor.swift](https://github.com/julianfbeck/ScanJu/blob/main/ScanJu/ScanProcessor.swift).

## Inputs and fallbacks

| Input | Use |
| --- | --- |
| `README.txt`, `scan.json` | Conventions, capture warnings, available channels |
| `Room.json` | RoomPlan surfaces, openings, object boxes, semantic confidence |
| `FloorPlan.svg`, `FloorPlan.dxf` | Cross-check wall/opening drawing; DXF units are meters |
| `Mesh.obj`, `Mesh.mtl`, `frames/*.jpg` | Observed triangle geometry and existing photo UVs; keep paths together |
| `TexturedMesh.usdz`, `Mesh.usda` | Alternative textured reference, if the importer supports it |
| `PointCloud.ply` | XYZ float32 + RGB uint8, binary little-endian; optional geometric cross-check |
| `cameras.json`, `frames/*` | Calibrated photos, poses, raw depth, confidence or valid-depth masks |

An imported textured scan is useful as a reference but retains curtains, clutter,
holes, and duplicated observations. Replacing it with clean geometry requires
reprojecting images or retaining carefully selected reference UV patches. A mesh
without calibrated cameras can still support a clean model; describe the overlay
as unavailable or limited instead of inventing a camera calibration.

## Coordinates

All raw 3D coordinates are **meters, right-handed, Y up**. Flat matrices are
**column-major**, including `cameraToWorld` (4×4), `transform` (4×4), and
`intrinsics` (3×3). In Blender:

```python
from mathutils import Matrix

def column_major(values, size):
    return Matrix([[values[c * size + r] for c in range(size)]
                   for r in range(size)])

# Right-handed rotation: (x, y, z) -> (x, -z, y); determinant +1.
arkit_to_blender = Matrix(((1, 0, 0, 0),
                          (0, 0, -1, 0),
                          (0, 1, 0, 0),
                          (0, 0, 0, 1)))
model_matrix = arkit_to_blender @ column_major(surface['transform'], 4)
```

An additional yaw alignment and floor-height/origin translation may make modeling
easier. Derive those from the new scan; record the complete matrix and its inverse
instead of copying coordinates from an example. Keep determinant positive and
scale one. Apply the same transform to cameras. Account for importer axis
conversion exactly once when bringing in OBJ/USD/glTF references; do not rotate
an already converted asset a second time. GLB's Y-up export is another documented
conversion, so compare world placement after importing it back.

## RoomPlan interpretation

- Top-level arrays include `walls`, `doors`, `windows`, `openings`, `floors`, and
  `objects`. Do not assume a fixed order, array count, single floor, or room shape.
  Process different stories separately when present.
- A surface's `transform` gives its center and local axes. Wall/opening dimensions
  are local width X, height Y, and thickness Z. Object boxes similarly have local
  width, height, depth. Keep the detected bottom elevation; do not place every
  window or hanging cabinet on the floor.
- Transform `polygonCorners` from surface-local to world space. Prefer actual
  floor polygons to a bounding rectangle; handle concavity, multiple polygons,
  and missing floors explicitly. Do not fill every gap with an invented room.
- Match openings through `parentIdentifier` to a wall's `identifier`. Compute
  opening extents in that wall's local coordinates. Check bounds, plane distance,
  and overlap rather than guessing the parent from proximity alone. Curved walls
  need their curve information or a documented approximation.
- `category` and `confidence` are encoded objects, not necessarily plain strings.
  Preserve identifiers/confidence as evidence. Door/storage conflicts and partial
  detections need photo review. A thin box often describes a visible front, not
  the true furniture depth; an aperture may belong to a recessed cabinet rather
  than a passage.

## Camera projection and RGB-D checks

`cameras.json` is an array. Each entry usually includes `image`, `depth`,
`confidence`, `width`, `height`, `depthWidth`, `depthHeight`, `intrinsics`,
`cameraToWorld`, `timestamp`, `tracking`, and `depthSource`. Newer entries can
include `confidenceSource` and an optical `depthCalibration` object. Paths are relative
to the export root. Check referenced files and lengths before reading them.

Camera axes: +X right, +Y up, view direction **−Z**. JPEG pixels start at the
**top left** and retain native camera orientation. Do not apply an unrecorded EXIF
rotation. For `q = inverse(cameraToWorld) @ world_point`, set `d = -q.z`:

```text
u_px = fx * q.x / d + cx
v_px = cy - fy * q.y / d
Blender UV = (u_px / image_width, 1 - v_px / image_height)
```

Reject points behind the camera and outside the image. Intrinsics refer to the
native JPEG dimensions. When loading a resized image, scale focal lengths and
principal point by the actual X/Y resize factors. For raw depth pixels scale
intrinsics to `depthWidth × depthHeight`; do not reuse native values unchanged.
Unproject a rectified depth pixel `(u, v)` as
`((u-cx)*d/fx, -(v-cy)*d/fy, -d)` before applying the camera pose.

Depth files are tightly packed little-endian float32 **axial depth in meters**,
not Euclidean ray length. Expected length: `4 * depthWidth * depthHeight` bytes.
Confidence/mask files are uint8 of `depthWidth * depthHeight` bytes. Reject NaN,
nonpositive depths, out-of-frame samples, and invalid/low-confidence measurements.
Rear LiDAR confidence levels are 0/1/2; `validDepthMask` for front TrueDepth is
0 invalid / 1 valid. Never reject all TrueDepth samples by requiring level 2.
Legacy rear exports can omit `confidenceSource`; inspect `depthSource` and the
export README rather than silently assigning the TrueDepth convention.

Compare projected axial depth to the observed RGB-D depth **before** using a
photo on a rebuilt surface. A closer foreground observation means the target is
occluded; do not project a sofa, curtain, or person onto the wall behind it.
Favor stable tracking, front-facing surfaces, sharp views, short distances, and
image interiors. Select nearby consistent views; averaging incompatible poses
causes ghosting. A depth tolerance is a reconstruction parameter, not sensor
accuracy; record it and inspect coverage after changing geometry.

TrueDepth's `depthCalibration` contains `matrix` (column-major 3×3),
`referenceWidth`, `referenceHeight`, `center`, `forward`, and `inverse`. Use that
optical matrix, scaled from its reference dimensions to the target resolution,
when present; the top-level ARKit image intrinsics are not a substitute. The
distortion center and radial forward/inverse lookup tables rectify raw depth pixels for
unprojection, and distort rectilinear projections to sample raw imagery. Port the
documented calibration logic rather than silently treating it as rear LiDAR.
Close-up data does not provide a full room plan.

After straightening geometry, project from the corresponding measured surface
using its retained source mapping. Comparing corrected points directly with old
depth can reject valid pixels or move features. If that correspondence is no
longer reliable, reduce overlay coverage and report it.
