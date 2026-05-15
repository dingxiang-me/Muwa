#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

resolved_files = [
    root / "Packages/OsaurusCore/Package.resolved",
    root / "App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    root / "osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved",
]

expected = {
    "vmlx-swift-lm": (
        "https://github.com/osaurus-ai/vmlx-swift-lm",
        "c90898fb41955578d546cf8936acc813a53b0294",
    ),
    "mlx-swift": (
        "https://github.com/osaurus-ai/mlx-swift",
        "0a56f9041d56b4b8161f67a6cbd540ae66efc9fd",
    ),
    "jinja": (
        "https://github.com/osaurus-ai/Jinja.git",
        "58d21aa5b69fdd9eb7e23ce2c3730f47db8e0c9d",
    ),
    "swift-transformers": (
        "https://github.com/osaurus-ai/swift-transformers",
        "087a66b17e482220b94909c5cf98688383ae481a",
    ),
}

errors = []
seen_by_file = {}

for path in resolved_files:
    if not path.exists():
        errors.append(f"missing Package.resolved: {path.relative_to(root)}")
        continue
    data = json.loads(path.read_text())
    pins = {pin["identity"]: pin for pin in data.get("pins", [])}
    seen_by_file[path.relative_to(root).as_posix()] = {}
    for identity, (expected_location, expected_revision) in expected.items():
        pin = pins.get(identity)
        if pin is None:
            errors.append(f"{path.relative_to(root)}: missing pin {identity}")
            continue
        location = pin.get("location")
        revision = pin.get("state", {}).get("revision")
        seen_by_file[path.relative_to(root).as_posix()][identity] = (location, revision)
        if location != expected_location:
            errors.append(
                f"{path.relative_to(root)}: {identity} location {location!r} != {expected_location!r}"
            )
        if revision != expected_revision:
            errors.append(
                f"{path.relative_to(root)}: {identity} revision {revision!r} != {expected_revision!r}"
            )

for rel, pins in seen_by_file.items():
    for identity, (location, revision) in pins.items():
        if "/Users/" in str(location) or "/Users/" in str(revision):
            errors.append(f"{rel}: {identity} contains a local path")

package_swift = root / "Packages/OsaurusCore/Package.swift"
if package_swift.exists():
    text = package_swift.read_text()
    if "/Users/" in text:
        errors.append("Packages/OsaurusCore/Package.swift contains a local /Users/ path")
    if "github.com/huggingface/swift-transformers" in text:
        errors.append("Packages/OsaurusCore/Package.swift points swift-transformers at upstream huggingface")
    if "github.com/huggingface/swift-jinja" in text:
        errors.append("Packages/OsaurusCore/Package.swift points Jinja at upstream huggingface")

if errors:
    print("Runtime pin check failed:", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    sys.exit(1)

print("Runtime pin check passed:")
for identity, (location, revision) in expected.items():
    print(f"  {identity}\t{location}\t{revision}")
PY
