"""Reject skipped/empty UI runs and render a reviewable xcresult summary."""
import json
import pathlib
import sys
import hashlib
import re
import shutil
import subprocess
import tempfile
from importlib.util import module_from_spec, spec_from_file_location

SCREENSHOTS = [
    "01-welcome-first-launch", "02-welcome-after-first-save", "03-all-credentials",
    "04-template-chooser", "05-new-credential", "06-import-preview", "07-agent-access",
    "08-pending-requests", "09-access-records", "10-settings", "11-locked",
    "12-approval-default", "13-approval-details", "14-approval-cancelled-authentication",
    "15-approval-credential-metadata",
]


def export_screenshots(bundle, destination):
    """Use Apple's attachment manifest to retain the authored PNG names."""
    destination.mkdir(parents=True, exist_ok=True)
    exported = set()
    with tempfile.TemporaryDirectory(prefix="askkey-attachments-") as temporary:
        raw = pathlib.Path(temporary)
        subprocess.run([
            "xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
            "--output-path", str(raw),
        ], check=True, timeout=120)
        for test in json.loads((raw / "manifest.json").read_text()):
            for attachment in test["attachments"]:
                name = attachment["suggestedHumanReadableName"]
                # XCTest strips the authored extension and appends a run suffix.
                match = re.match(r"^(\d{2}-[a-z-]+)(?:\.png)?(?:$|[_. ])", name)
                if not match or match[1] not in SCREENSHOTS:
                    continue
                filename = match[1] + ".png"
                if filename in exported:
                    raise ValueError(f"Duplicate screenshot attachment: {filename}")
                source = raw / attachment["exportedFileName"]
                if source.parent != raw or source.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
                    raise ValueError(f"Invalid PNG attachment: {filename}")
                shutil.copyfile(source, destination / filename)
                exported.add(filename)
    missing = sorted({name + ".png" for name in SCREENSHOTS} - exported)
    if missing:
        raise ValueError(f"Screenshot flow is incomplete; missing={missing}")
    print(f"Exported {len(exported)} window screenshots to {destination}")


if sys.argv[1:2] == ["--export-screenshots"]:
    export_screenshots(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
    raise SystemExit(0)

spec = spec_from_file_location("e2e_gate", pathlib.Path(__file__).with_name("e2e-gate.py"))
gate = module_from_spec(spec)
spec.loader.exec_module(gate)

output = pathlib.Path(sys.argv[1])
summary, tree = gate.load_results(output)
passed = summary.get("passedTests", 0)
failed = summary.get("failedTests", 0)
skipped = summary.get("skippedTests", 0)
required = json.loads((gate.ROOT / "Tests/UI/required-flows.json").read_text())
gate.validate_results(summary, tree, required)
source = (output / "source-fingerprint.txt").read_text().strip()
if source != gate.fingerprint():
    raise SystemExit("Source changed during testing; this run is diagnostic only and produces no delivery receipt.")
report = (
    "# Basic flow automated acceptance\n\n"
    f"Passed {passed}, failed {failed}, skipped {skipped}.\n\n"
    "Target: a separate isolated bundle; XCUITest operates visible controls.\n"
    "This result does not verify real Touch ID or external client environments.\n\n"
    "See basic-flows.xcresult in the same directory for actions, failure details, and screenshots.\n"
)
(output / "acceptance-result.md").write_text(report)
receipt = {
    "sourceFingerprint": source,
    "output": str(output.resolve()),
    "required": required,
    "evidenceHashes": {name: hashlib.sha256((output / name).read_bytes()).hexdigest()
                       for name in ["summary.json", "tests.json", "source-fingerprint.txt"]},
}
(gate.ROOT / "Tests/UI/output/passing-receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
gate.verify()
print(report)
