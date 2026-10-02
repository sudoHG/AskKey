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
    raise SystemExit("源码在测试期间发生变化，本轮仅供诊断，不生成交付凭证。")
report = (
    "# 基础流程自动验收\n\n"
    f"通过 {passed} 项，失败 {failed} 项，跳过 {skipped} 项。\n\n"
    "对象：独立隔离包；操作由 XCUITest 通过可见控件执行。\n"
    "此结果不代表真实 Touch ID 或外部客户端环境已通过验收。\n\n"
    "操作记录、失败详情与截图见同目录的 basic-flows.xcresult。\n"
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
