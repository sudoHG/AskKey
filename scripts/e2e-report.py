"""Reject skipped/empty UI runs and render a reviewable xcresult summary."""
import json
import pathlib
import sys
import hashlib
from importlib.util import module_from_spec, spec_from_file_location

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
