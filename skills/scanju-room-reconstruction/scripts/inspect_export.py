#!/usr/bin/env python3
"""Inspect ScanJu metadata and RGB-D file sizes without extracting/loading media."""

import argparse
from collections import Counter
import json
import math
from pathlib import Path, PurePosixPath
import stat
import sys
import zipfile


METADATA_LIMIT = 32 * 1024 * 1024  # Per JSON file; never read meshes/media here.
ROOT_MARKERS = {"Room.json", "cameras.json", "scan.json", "Mesh.obj", "PointCloud.ply",
                "FloorPlan.svg", "FloorPlan.dxf", "TexturedMesh.usdz", "Room.usdz", "Mesh.usda"}
CHANNELS = ("walls", "doors", "windows", "openings", "floors", "objects")


def safe_relative(name):
    path = PurePosixPath(name)
    if (not name or "\\" in name or ":" in name or path.is_absolute()
            or ".." in path.parts or path.as_posix() != name):
        raise ValueError(f"Unsafe or noncanonical relative path: {name!r}")
    return path


class Export:
    def __init__(self, path):
        self.path = path
        self.archive = None
        self.files = {}
        self.prefix = ""
        try:
            if path.is_dir():
                for entry in path.rglob("*"):
                    if entry.is_symlink():
                        raise ValueError("Extracted exports must not contain symlinks")
                    if entry.is_file():
                        name = entry.relative_to(path).as_posix()
                        safe_relative(name)
                        self.files[name] = entry.stat().st_size
            else:
                self.archive = zipfile.ZipFile(path)
                for entry in self.archive.infolist():
                    safe_relative(entry.filename.rstrip("/") if entry.is_dir() else entry.filename)
                    if stat.S_ISLNK(entry.external_attr >> 16):
                        raise ValueError("ZIP exports must not contain symlinks")
                    if entry.is_dir():
                        continue
                    if entry.filename in self.files:
                        raise ValueError(f"Duplicate ZIP member: {entry.filename}")
                    self.files[entry.filename] = entry.file_size
                roots = {str(PurePosixPath(name).parent) for name in self.files
                         if PurePosixPath(name).name in ROOT_MARKERS}
                if len(roots) != 1:
                    raise ValueError("Expected one export root in ZIP; provide one capture at a time")
                root = roots.pop()
                self.prefix = "" if root == "." else root + "/"
                self.files = {name[len(self.prefix):]: size
                              for name, size in self.files.items() if name.startswith(self.prefix)}
            if not ROOT_MARKERS.intersection(self.files):
                raise ValueError("No ScanJu export markers found; provide the export root")
        except Exception:
            self.close()
            raise

    def close(self):
        if self.archive:
            self.archive.close()

    def read_json(self, name):
        if name not in self.files:
            return None
        if self.files[name] > METADATA_LIMIT:
            raise ValueError(f"{name} exceeds the inspector's 32 MiB metadata limit")
        if self.archive:
            with self.archive.open(self.prefix + name) as stream:
                raw = stream.read(METADATA_LIMIT + 1)
        else:
            with (self.path / name).open("rb") as stream:
                raw = stream.read(METADATA_LIMIT + 1)
        if len(raw) > METADATA_LIMIT:
            raise ValueError(f"{name} exceeds the inspector's metadata limit")
        value = json.loads(raw)
        if value is None:
            raise ValueError(f"{name} must not contain JSON null")
        return value


def numeric_vector(value, length):
    return (isinstance(value, list) and len(value) == length
            and all(type(x) in (int, float) and math.isfinite(x) for x in value))


def inspect(export):
    warnings = []
    report = {
        "schema_version": 1,
        "files": len(export.files),
        "total_uncompressed_bytes": sum(export.files.values()),
        "present": {name: name in export.files for name in (
            "README.txt", "scan.json", "Room.json", "FloorPlan.svg", "FloorPlan.dxf",
            "Mesh.obj", "Mesh.mtl", "TexturedMesh.usdz", "PointCloud.ply", "cameras.json")},
        "conventions": "ARKit meters, right-handed Y-up; column-major matrices; verify export README",
    }
    room = export.read_json("Room.json")
    if room is not None:
        if not isinstance(room, dict):
            raise ValueError("Room.json must be a RoomPlan object")
        counts, walls, openings, stories = {}, set(), [], set()
        curved = 0
        for kind in CHANNELS:
            entries = room.get(kind, [])
            if not isinstance(entries, list):
                raise ValueError(f"Room.json {kind} must be an array")
            counts[kind] = len(entries)
            for index, entry in enumerate(entries):
                if not isinstance(entry, dict):
                    raise ValueError(f"{kind}[{index}] must be an object")
                if (not numeric_vector(entry.get("transform"), 16)
                        or not numeric_vector(entry.get("dimensions"), 3)):
                    raise ValueError(f"{kind}[{index}] has invalid transform/dimensions")
                if any(x < 0 for x in entry["dimensions"]):
                    raise ValueError(f"{kind}[{index}] has negative dimensions")
                stories.add(str(entry.get("story", "unspecified")))
                curved += entry.get("curve") is not None
                if kind == "walls":
                    identifier = entry.get("identifier")
                    if not isinstance(identifier, str):
                        raise ValueError(f"walls[{index}] lacks a string identifier")
                    walls.add(identifier)
                elif kind in ("doors", "windows", "openings"):
                    parent = entry.get("parentIdentifier")
                    if parent is not None and not isinstance(parent, str):
                        raise ValueError(f"{kind}[{index}] has invalid parentIdentifier")
                    openings.append((kind, index, parent))
        orphaned = [(kind, index) for kind, index, parent in openings
                    if not parent or parent not in walls]
        report["room"] = {"counts": counts, "stories": sorted(stories),
                          "curved_entities": curved, "orphaned_openings": len(orphaned)}
        if orphaned:
            warnings.append(f"{len(orphaned)} openings lack a matching parent wall; inspect manually")
        if not counts["walls"] or not counts["floors"]:
            warnings.append("Room geometry is incomplete; do not assume a complete floor plan")
    else:
        warnings.append("Room.json absent: surface-only/partial input; establish layout and heights separately")

    cameras = export.read_json("cameras.json")
    if cameras is not None:
        if not isinstance(cameras, list):
            raise ValueError("cameras.json must be an array")
        depth_sources, confidence_sources = Counter(), Counter()
        for index, camera in enumerate(cameras):
            if not isinstance(camera, dict):
                raise ValueError(f"camera[{index}] must be an object")
            for key, length in (("cameraToWorld", 16), ("intrinsics", 9)):
                if not numeric_vector(camera.get(key), length):
                    raise ValueError(f"camera[{index}] has invalid {key}")
            dimensions = [camera.get(k) for k in ("width", "height", "depthWidth", "depthHeight")]
            if not all(type(x) is int and x > 0 for x in dimensions):
                raise ValueError(f"camera[{index}] has invalid image/depth dimensions")
            pixels = camera["depthWidth"] * camera["depthHeight"]
            for key, expected in (("image", None), ("depth", pixels * 4), ("confidence", pixels)):
                name = camera.get(key)
                if not isinstance(name, str):
                    warnings.append(f"camera[{index}] has no {key} path")
                    continue
                safe_relative(name)
                actual = export.files.get(name)
                if actual is None:
                    warnings.append(f"camera[{index}] missing {key} file: {name}")
                elif expected is not None and actual != expected:
                    warnings.append(f"camera[{index}] {key} bytes: expected {expected}, found {actual}")
            depth_sources[str(camera.get("depthSource", "unspecified"))] += 1
            confidence_sources[str(camera.get("confidenceSource", "legacy/unspecified: consult README"))] += 1
        report["cameras"] = {"count": len(cameras), "depth_sources": dict(depth_sources),
                             "confidence_sources": dict(confidence_sources)}
        if not cameras:
            warnings.append("No calibrated camera views; a photo overlay is unavailable")
    else:
        warnings.append("cameras.json absent: calibrated photo projection is unavailable")
    report["warnings"] = warnings
    report["scope"] = "Metadata and file-size inspection only; no visual, calibration-accuracy or topology validation"
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="ScanJu ZIP or extracted export root")
    parser.add_argument("--report", type=Path, help="Write a new JSON report (default: stdout)")
    args = parser.parse_args()
    export = None
    try:
        export = Export(args.input.resolve(strict=True))
        report = inspect(export)
        text = json.dumps(report, indent=2, allow_nan=False) + "\n"
        if args.report:
            # Exclusive create protects source metadata and existing reports.
            with args.report.open("x", encoding="utf-8") as stream:
                stream.write(text)
        else:
            sys.stdout.write(text)
    except (OSError, ValueError, zipfile.BadZipFile, RuntimeError) as error:
        parser.exit(1, f"Inspection failed: {error}\n")
    finally:
        if export:
            export.close()


if __name__ == "__main__":
    main()
