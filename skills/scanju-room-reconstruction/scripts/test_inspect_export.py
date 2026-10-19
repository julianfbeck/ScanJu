"""Synthetic fixtures only. Run: python3 -m unittest discover -s <this directory>."""

import importlib.util
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile


SCRIPT = Path(__file__).with_name("inspect_export.py")
SPEC = importlib.util.spec_from_file_location("inspect_export", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
IDENTITY = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]


def fixture():
    wall = {"identifier": "wall-a", "transform": IDENTITY,
            "dimensions": [4, 2.5, 0], "story": 0}
    opening = {**wall, "identifier": "door-a", "parentIdentifier": "wall-a",
               "dimensions": [0.9, 2.1, 0]}
    room = {"walls": [wall], "floors": [{**wall, "identifier": "floor-a"}],
            "doors": [opening], "objects": [], "windows": [], "openings": []}
    camera = {"cameraToWorld": IDENTITY, "intrinsics": [100, 0, 0, 0, 100, 0, 1, 1, 1],
              "image": "frames/0.jpg", "depth": "frames/0.depth",
              "confidence": "frames/0.confidence", "width": 2, "height": 2,
              "depthWidth": 2, "depthHeight": 2, "depthSource": "sceneDepth"}
    return {"Room.json": json.dumps(room).encode(),
            "cameras.json": json.dumps([camera]).encode(),
            "frames/0.jpg": b"synthetic-not-an-image", "frames/0.depth": b"\0" * 16,
            "frames/0.confidence": b"\2" * 4}


class ExportTests(unittest.TestCase):
    def inspect_files(self, files, zipped=False, prefix=""):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            if zipped:
                source = root / "capture.zip"
                with zipfile.ZipFile(source, "w") as archive:
                    for name, data in files.items():
                        archive.writestr(prefix + name, data)
            else:
                source = root / "capture"
                source.mkdir()
                for name, data in files.items():
                    target = source / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
            export = MODULE.Export(source)
            try:
                return MODULE.inspect(export)
            finally:
                export.close()

    def test_directory_zip_and_wrapped_zip_agree(self):
        expected = self.inspect_files(fixture())
        self.assertEqual(expected, self.inspect_files(fixture(), zipped=True))
        self.assertEqual(expected, self.inspect_files(fixture(), zipped=True, prefix="capture/"))
        self.assertEqual(expected["warnings"], [])
        self.assertEqual(expected["room"]["counts"]["doors"], 1)
        self.assertEqual(expected["cameras"]["count"], 1)

    def test_partial_surface_is_reported(self):
        for name in ("Mesh.obj", "FloorPlan.svg", "TexturedMesh.usdz"):
            with self.subTest(name=name):
                report = self.inspect_files({name: b"synthetic"})
                self.assertNotIn("room", report)
                self.assertTrue(any("Room.json absent" in w for w in report["warnings"]))
                self.assertTrue(any("cameras.json absent" in w for w in report["warnings"]))

    def test_missing_and_truncated_rgbd_are_reported(self):
        files = fixture()
        del files["frames/0.jpg"]
        files["frames/0.depth"] = b"short"
        report = self.inspect_files(files)
        self.assertEqual(len(report["warnings"]), 2)
        self.assertTrue(any("missing image file" in w for w in report["warnings"]))
        self.assertTrue(any("expected 16, found 5" in w for w in report["warnings"]))

    def test_orphaned_opening_is_reported(self):
        files = fixture()
        room = json.loads(files["Room.json"])
        room["doors"][0]["parentIdentifier"] = "absent-wall"
        files["Room.json"] = json.dumps(room).encode()
        self.assertEqual(self.inspect_files(files)["room"]["orphaned_openings"], 1)

    def test_truedepth_valid_mask_is_not_treated_as_lidar(self):
        files = fixture()
        cameras = json.loads(files["cameras.json"])
        cameras[0]["confidenceSource"] = "validDepthMask"
        cameras[0]["depthSource"] = "capturedDepthData"
        files["cameras.json"] = json.dumps(cameras).encode()
        files["frames/0.confidence"] = b"\1" * 4
        report = self.inspect_files(files)
        self.assertEqual(report["warnings"], [])
        self.assertEqual(report["cameras"]["confidence_sources"], {"validDepthMask": 1})

    def test_bad_matrix_is_rejected(self):
        files = fixture()
        cameras = json.loads(files["cameras.json"])
        cameras[0]["cameraToWorld"] = [0] * 15
        files["cameras.json"] = json.dumps(cameras).encode()
        with self.assertRaisesRegex(ValueError, "invalid cameraToWorld"):
            self.inspect_files(files)
        with self.assertRaisesRegex(ValueError, "JSON null"):
            self.inspect_files({"Room.json": b"null"})

    def test_camera_paths_cannot_escape_export(self):
        for path in ("../outside", "/outside", "C:\\outside", "frames/../outside"):
            with self.subTest(path=path):
                files = fixture()
                cameras = json.loads(files["cameras.json"])
                cameras[0]["image"] = path
                files["cameras.json"] = json.dumps(cameras).encode()
                with self.assertRaisesRegex(ValueError, "relative path"):
                    self.inspect_files(files)

    def test_unsafe_archive_members_are_rejected(self):
        for name in ("../escape", "/absolute", "C:/drive", "frames\\escape"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "relative path"):
                self.inspect_files({**fixture(), name: b"unsafe"}, zipped=True)

    def test_symlinks_and_duplicate_members_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive_path = root / "capture.zip"
            info = zipfile.ZipInfo("Room.json")
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr(info, "../outside")
            with self.assertRaisesRegex(ValueError, "symlinks"):
                MODULE.Export(archive_path)
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("Room.json", "{}")
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    archive.writestr("Room.json", "{}")
            with self.assertRaisesRegex(ValueError, "Duplicate ZIP member"):
                MODULE.Export(archive_path)
            (root / "Room.json").symlink_to("/nonexistent")
            with self.assertRaisesRegex(ValueError, "symlinks"):
                MODULE.Export(root)

    def test_multiple_export_roots_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "one export root"):
            self.inspect_files({"one/Room.json": b"{}", "two/Room.json": b"{}"}, zipped=True)

    def test_metadata_size_is_bounded_before_reading(self):
        class LargeMetadata:
            files = {"Room.json": MODULE.METADATA_LIMIT + 1}
        with self.assertRaisesRegex(ValueError, "metadata limit"):
            MODULE.Export.read_json(LargeMetadata(), "Room.json")

    def test_cli_writes_report_and_preserves_existing_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "Mesh.obj").write_text("# synthetic")
            output = root / "inspection.json"
            args = [sys.executable, str(SCRIPT), str(root), "--report", str(output)]
            result = subprocess.run(args, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            original = output.read_bytes()
            self.assertIn("warnings", json.loads(original))
            result = subprocess.run(args, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("File exists", result.stderr)
            self.assertEqual(output.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
