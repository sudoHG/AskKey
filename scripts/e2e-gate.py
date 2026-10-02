"""Bind a local UI test receipt to the exact source inputs, never just HEAD."""
import hashlib
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def validate_results(summary, tree, required):
    cases = []

    def visit(nodes):
        for node in nodes:
            if node.get("nodeType") == "Test Case":
                cases.append(node)
            visit(node.get("children", []))

    visit(tree.get("testNodes", []))
    missing = [name for name in required if not any(
        case.get("name", "").removesuffix("()") == name and case.get("result") == "Passed"
        for case in cases
    )]
    if (not required or summary.get("passedTests", 0) < len(required)
            or summary.get("failedTests", 0) or summary.get("skippedTests", 0)
            or summary.get("expectedFailures", 0)
            or missing or summary.get("result") != "Passed"
            or any(case.get("result") != "Passed" for case in cases)):
        raise ValueError(f"基础流程未完整通过；missing={missing}, summary={summary.get('result')}")


def load_results(output):
    """Read Apple's result bundle again; a hand-written JSON is not evidence."""
    results = []
    for kind, name in [("summary", "summary.json"), ("tests", "tests.json")]:
        raw = subprocess.check_output([
            "xcrun", "xcresulttool", "get", "test-results", kind,
            "--path", str(output / "basic-flows.xcresult"),
        ], text=True, timeout=30)
        actual = json.loads(raw)
        if actual != json.loads((output / name).read_text()):
            raise ValueError(f"{name} 与原始 xcresult 不一致")
        results.append(actual)
    return results


def invalidate():
    (ROOT / "Tests/UI/output/passing-receipt.json").unlink(missing_ok=True)


def fingerprint():
    paths = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT
    ).decode().split("\0")
    digest = hashlib.sha256()
    for name in sorted(set(paths)):
        if not name or not (
            name.startswith(("Sources/", "Tests/", "scripts/", ".github/workflows/"))
            or name in {"Package.swift", "Package.resolved", "Tests/UI/project.yml", "Tests/UI/required-flows.json"}
        ):
            continue
        path = ROOT / name
        digest.update(name.encode() + b"\0")
        digest.update(path.read_bytes() if path.is_file() else b"DELETED")
        digest.update(b"\0")
    return digest.hexdigest()


def verify():
    latest = ROOT / "Tests/UI/output/passing-receipt.json"
    if not latest.is_file():
        raise SystemExit("缺少基础 E2E 通过记录；请先运行 bash scripts/run-e2e.sh。")
    receipt = json.loads(latest.read_text())
    if receipt.get("sourceFingerprint") != fingerprint():
        raise SystemExit("源码已改变，E2E 记录过期；请重新运行基础流程。")
    output = pathlib.Path(receipt["output"])
    for name, expected in receipt["evidenceHashes"].items():
        path = output / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise SystemExit(f"E2E 证据缺失或改变：{name}")
    if not (output / "basic-flows.xcresult").is_dir():
        raise SystemExit("缺少原始 xcresult。")
    summary, tree = load_results(output)
    validate_results(summary, tree, json.loads((ROOT / "Tests/UI/required-flows.json").read_text()))
    print(f"基础 E2E 门槛通过：{output}")


if __name__ == "__main__":
    if sys.argv[1:] == ["invalidate"]:
        invalidate()
    elif sys.argv[1:] == ["fingerprint"]:
        print(fingerprint())
    else:
        verify()
