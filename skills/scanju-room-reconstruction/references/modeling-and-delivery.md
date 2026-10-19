# Modeling and delivery lessons

These are reusable lessons from the session that produced the public ScanJu room
renders. They are not a fixed apartment template. Derive every dimension, material
choice, fixture, and room boundary from the user's capture or stated preferences.

## Clean architecture

Build a first measured layout before adding detail. Preserve source IDs on objects
and retain the source transform, dimensions, confidence, and any corrections in a
manifest. Separate architecture, joinery, furniture, fixtures, presentation, and
hidden reference collections. Group furniture parts under editable roots.

Create **real holes** in wall solids. In each wall's local plane, split at opening
X and height boundaries, omit occupied aperture cells, and generate front/back
faces plus boundary reveals. Weld shared vertices and recalculate normals. Exact
Boolean unions can join wall intersections; an orthogonal occupancy-cell union
is an alternative for truly rectilinear layouts. The latter is unsuitable for
angled or curved geometry. Keep original segments hidden for later editing.

Wall thickness is often an assumption: derive it where evidence allows and mark
fallback values. Use a small, recorded join tolerance to avoid hairline gaps;
do not use a large merge distance that erases narrow trim or openings. Check
volume and non-manifold/internal faces on the finished solid shell.

Recesses are real negative space. A shallow storage detection may cover only the
visible front of an embedded wardrobe. Compare overlapping door/storage outlines,
the aperture, photographs, and depth points before deciding its full extent.
Keep measured front width/height separate from an inferred carcass depth. Do not
leave a false wall across the missing part of a partly detected front.

## Photo audit before polish

Create contact sheets to select useful frames, then inspect the original photos
at useful resolution. Use several views and calibrated rays intersecting a
measured wall plane when an opening's width/position is ambiguous. A single
perspective image is insufficient to measure an unknown plane/depth. Record the
frame paths and uncertainty for each correction in the private delivery report.

| Common failure | Check and correction |
| --- | --- |
| Window with a high false sill | Verify whether glazing actually reaches the floor; change the wall aperture as well as the frame |
| Opening widened by curtains | Find physical jambs in multiple views; mask curtains from photo projection |
| Wrong pane count | Count actual sashes/mullions from photos; do not derive count from width alone |
| Wardrobe labeled as a door | Resolve semantic conflict and recess; preserve alternate source outlines |
| Kitchen made of skewed boxes | Align evidence-supported cabinets/appliances to a common run and build a continuous worktop/plinth |
| Repeated chair or fixture | Compare source ID, pose, and photos; remove duplicate detection rather than duplicating the real item |
| Bathroom fixtures on wrong sides | Trace views back through camera poses; cross-check the window, doorway, shower, basin, and toilet |
| Wavy exterior/floor edge | Find supported common planes; move openings, floor, trim, and UVs consistently with the wall |
| Filled sink or blocked doorway | Inspect actual mesh apertures and swing clearance, not just decorative outlines |

Keep source layout, reconstructed existing layout, and any proposed redesign
distinct. Changing furniture positions for aesthetics is a redesign and needs the
user's request. Door hinge side/swing can be missing from scans: obtain evidence
or mark it unknown. If modeling a swing, test the swept leaf volume across its
range, not just the final open pose.

Use restrained detail that improves recognition: separate jambs, recessed frames,
sashes, transparent glass, seals, handles, thresholds, and sills where observed.
For furniture, simple boxes/cylinders with softened edges usually suffice. Match
major visible colors and finishes. Avoid guessed tiny fittings, hidden structure,
or third-party assets the user did not request. Distinguish clean replacement
materials from captured photo evidence.

Trim must stop at floor-level doors/recesses and not cross circulation paths.
Check repeated coplanar wall caps, open corner seams, floating cabinets, duplicate
glazing, intersecting handles, and a worktop filling its sink cutout in close views.

## Comparable clean and photo scenes

Keep the final corrected transforms and geometry identical in both scenes.
Share joinery/furniture objects or mesh data where possible. Photo architecture
may need separate mesh copies or object-linked materials for independent
materials/UVs; compare source IDs, transforms, and vertex positions after edits.
Do not let an earlier duplicate retain a stale wardrobe or window position.

Project calibrated photos onto rebuilt surfaces with the conventions and depth
checks in [export-format.md](export-format.md). Retain measured-to-corrected
surface mappings. Export coverage masks alongside baked surface textures.
Mask glass, curtains, clutter, and unreliable borders. Blend only the edges of
valid photo coverage into clean material; do not fill large missing regions with
invented imagery or conceal them in the coverage report. Keep the overlay's
partial nature visible and documented.

Process camera images/depth one view or bounded batch at a time. Bound resized
image/atlas memory rather than loading every full-resolution RGB-D frame at once.
Keep original source resolution available for selected close checks. When baking
materials, handle sRGB image colors versus linear shader colors explicitly.
Use UV image textures or bake procedural materials for portable glTF appearance.

## Editing and presentation

Solid shading with material colors is a useful default working view. Disable
costly bevel/normal modifiers in the viewport while retaining them for renders.
Keep free perspective navigation; do not leave camera-lock enabled or an active
render blocking the live UI. Measure evaluated geometry/update time if lagging,
rather than applying the example project's polygon count as a universal limit.

Use an orthographic top-down camera for the plan and a separate three-quarter
cutaway camera for the overview. Frame the full floor footprint with a margin,
soft area lighting and a restrained background. Preserve true dimensions; do not
stretch the model to improve the image. Produce close views for ambiguous joinery.

Save checkpoints before structural edits and before rendering. A separate local
Blender background process with a bounded thread count can render a saved
snapshot while the live file stays editable. Keep its output/log separate and
never save that stale snapshot over a newer live project. Regenerate affected
renders/exports after geometry changes; don't deliver mixed revisions.

## Verification and portable delivery

Record actual checks in `verification.json`, including failures/not checked:

- Meter scale, handedness, floor height, source-to-model conversion and its inverse.
- Wall lengths, opening width/bottom/top and parent plane versus source; every
  straightening/photo correction with evidence and magnitude of deviation.
- Closed solid wall shells with no unintended boundary/non-manifold edges or
  internal caps. Deliberately open reference meshes need not pass a solid test.
- Floors/corners match walls; trim avoids apertures; relevant intersections and
  door clearances reviewed; duplicate furniture removed without deleting real items.
- Geometry/placement parity across clean and overlay scenes, including later fixes.
- Packed images and preserved scenes **after reopening** the saved `.blend` in a
  separate process. Give non-current scenes fake users or another durable user
  so saving/reloading does not discard them. Avoid missing external dependencies.
- Per-scene GLB exports contain only intended model objects: exclude cameras,
  lights, staging planes, hidden source walls and raw scan geometry. Embed images
  and check there are no external URIs. Import into a clean file to verify scale,
  placement, transparent glass, texture appearance, and model bounds.
- Actual overview, top-down and detail renders inspected for seams, filled holes,
  untextured parts, framing, and regressions. Do not claim visual review from file
  existence alone.

The delivery README should explain how to open/switch scenes, what was measured,
what was corrected from photos, which dimensions/materials are inferred, missing
coverage, and any failed verification. Include the reproducible build/projection
scripts used for this capture. Bundle a delivery ZIP if requested; exclude
backups, transient logs, and raw camera/depth data unless the user needs them.
Models are reconstruction estimates, not a guarantee of construction accuracy.
