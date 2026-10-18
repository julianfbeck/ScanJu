#!/usr/bin/env python3
"""Drive ScanJu through the already-running WebDriverAgent; never restarts the runner."""
import argparse
import base64
import json
import os
from pathlib import Path
import urllib.request

BASE = os.environ.get("SCANJU_WDA_URL", "").rstrip("/")
BUNDLE_ID = os.environ.get("SCANJU_BUNDLE_ID", "com.julianbeck.ScanJu")
OUT = Path(__file__).resolve().parents[1] / "DeviceEvidence"

def call(method, path, body=None):
    request = urllib.request.Request(BASE + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=45) as response:
        result = json.load(response)
    if isinstance(result.get("value"), dict) and "error" in result["value"]:
        raise RuntimeError(result["value"])
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["launch", "tree", "shot", "tap", "tapxy", "swipe", "label", "accept", "alert", "status"])
    parser.add_argument("value", nargs="?", default="scanju")
    args = parser.parse_args()
    if not BASE:
        parser.error("Set SCANJU_WDA_URL to your existing WebDriverAgent endpoint before using this tool.")
    status = call("GET", "/status")
    if args.command == "status":
        print(json.dumps(status, indent=2)); return
    session = status["sessionId"]
    prefix = "/session/" + session
    if args.command == "launch":
        print(call("POST", prefix + "/wda/apps/launch", {"bundleId": BUNDLE_ID, "shouldWaitForQuiescence": False, "asAppUnderTest": True})); return
    if args.command == "tree":
        result = call("GET", prefix + "/source?format=json")["value"]
        def walk(node):
            label = node.get("label", "")
            identifier = node.get("rawIdentifier", "")
            if label or identifier:
                print(node.get("type"), repr(identifier), repr(label), node.get("rect"))
            for child in node.get("children", []): walk(child)
        walk(result); return
    if args.command == "shot":
        OUT.mkdir(exist_ok=True)
        path = OUT / (args.value + ".png")
        path.write_bytes(base64.b64decode(call("GET", "/screenshot")["value"]))
        print(path); return
    if args.command == "tapxy":
        x, y = map(float, args.value.split(","))
        actions = {"actions": [{"type": "pointer", "id": "scanju-finger", "parameters": {"pointerType": "touch"}, "actions": [
            {"type": "pointerMove", "duration": 0, "x": x, "y": y}, {"type": "pointerDown", "button": 0},
            {"type": "pause", "duration": 80}, {"type": "pointerUp", "button": 0}]}]}
        print(call("POST", prefix + "/actions", actions)); return
    if args.command == "swipe":
        x1, y1, x2, y2 = map(float, args.value.split(","))
        actions = {"actions": [{"type": "pointer", "id": "scanju-finger", "parameters": {"pointerType": "touch"}, "actions": [
            {"type": "pointerMove", "duration": 0, "x": x1, "y": y1}, {"type": "pointerDown", "button": 0},
            {"type": "pause", "duration": 100}, {"type": "pointerMove", "duration": 500, "x": x2, "y": y2},
            {"type": "pointerUp", "button": 0}]}]}
        print(call("POST", prefix + "/actions", actions)); return
    if args.command in ("tap", "label"):
        using = "accessibility id" if args.command == "tap" else "predicate string"
        value = args.value if args.command == "tap" else "label == " + json.dumps(args.value)
        result = call("POST", prefix + "/element", {"using": using, "value": value})["value"]
        element = result.get("ELEMENT") or result.get("element-6066-11e4-a52e-4f735466cecf")
        print(call("POST", prefix + "/element/" + element + "/click")); return
    if args.command == "alert": print(call("GET", prefix + "/alert/text"))
    if args.command == "accept": print(call("POST", prefix + "/alert/accept"))

if __name__ == "__main__": main()
