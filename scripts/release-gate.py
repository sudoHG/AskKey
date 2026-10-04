"""Require the checkout's latest push-to-main CI attempt before local releases."""

import argparse
import json
import re
import subprocess
import sys

COMMAND_TIMEOUT = 60
REQUIRED_JOBS = ("build-and-test", "basic-ui-flows")


class GateError(Exception):
    pass


def run_command(arguments, failure):
    """Run every external command in the checkout with a bounded wait."""
    try:
        return subprocess.check_output(arguments, text=True, stderr=subprocess.PIPE,
                                       timeout=COMMAND_TIMEOUT).strip()
    except subprocess.TimeoutExpired:
        raise GateError(f"{failure} Command timed out.") from None
    except (subprocess.CalledProcessError, OSError):
        raise GateError(failure) from None


def read_json(arguments, failure):
    try:
        return json.loads(run_command(arguments, failure))
    except (ValueError, TypeError):
        raise GateError(f"{failure} Invalid JSON response.") from None


def api_items(endpoint, key, failure, fields=()):
    arguments = ["gh", "api", endpoint, "--method", "GET", "--paginate", "--slurp",
                 "-f", "per_page=100"]
    for field in fields:
        arguments.extend(["-f", field])
    pages = read_json(arguments, failure)
    if not isinstance(pages, list) or not pages:
        raise GateError(f"{failure} Invalid paginated response.")
    items = []
    for page in pages:
        if (not isinstance(page, dict) or not isinstance(page.get(key), list)
                or any(not isinstance(item, dict) for item in page[key])):
            raise GateError(f"{failure} Invalid paginated response.")
        items.extend(page[key])
    return items


def check_release(require_tag=False):
    if run_command(["git", "status", "--porcelain"], "Unable to inspect the checkout."):
        raise GateError("Checkout is not clean (tracked or untracked changes).")

    run_command(["git", "fetch", "origin", "main"], "Unable to fetch origin/main.")
    head = run_command(["git", "rev-parse", "HEAD"], "Unable to resolve HEAD.")
    run_command(["git", "merge-base", "--is-ancestor", head, "origin/main"],
                "HEAD is not reachable from origin/main.")

    repository = read_json(["gh", "repo", "view", "--json", "nameWithOwner"],
                           "Unable to identify the repository.")
    repository = repository.get("nameWithOwner") if isinstance(repository, dict) else None
    if (not isinstance(repository, str)
            or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)):
        raise GateError("Unable to identify the repository: nameWithOwner is missing or invalid.")

    runs = api_items(f"repos/{repository}/actions/workflows/ci.yml/runs", "workflow_runs",
                     "Unable to read CI workflow runs.",
                     (f"head_sha={head}", "event=push", "branch=main"))
    runs = [run for run in runs if run.get("name") == "CI"
            and run.get("head_sha") == head and run.get("event") == "push"
            and run.get("head_branch") == "main"]
    if not runs:
        raise GateError("No push-to-main CI run exists for HEAD.")
    for run in runs:
        if (not isinstance(run.get("created_at"), str)
                or type(run.get("id")) is not int
                or type(run.get("run_attempt")) is not int or run["run_attempt"] < 1):
            raise GateError("CI workflow run metadata is incomplete.")
    latest = max(runs, key=lambda run: (run["created_at"], run["id"]))
    if latest.get("status") != "completed":
        raise GateError("Latest push-to-main CI run is not completed.")
    if latest.get("conclusion") != "success":
        raise GateError("Latest push-to-main CI run did not succeed.")
    if not isinstance(latest.get("html_url"), str) or not latest["html_url"]:
        raise GateError("CI workflow run URL is missing.")

    jobs = api_items(
        f"repos/{repository}/actions/runs/{latest['id']}/attempts/{latest['run_attempt']}/jobs",
        "jobs", "Unable to read CI jobs for the latest attempt."
    )
    for name in REQUIRED_JOBS:
        matching = [job for job in jobs if job.get("name") == name]
        if not matching:
            raise GateError(f"Required CI job {name} is missing.")
        if any(job.get("status") != "completed" or job.get("conclusion") != "success"
               for job in matching):
            raise GateError(f"Required CI job {name} did not succeed.")

    if require_tag:
        version = run_command(["bash", "scripts/product-version.sh"],
                              "Unable to read the product version.")
        tag = f"v{version}"
        tagged = run_command(["git", "rev-parse", f"{tag}^{{commit}}"], f"Tag {tag} is missing.")
        if tagged != head:
            raise GateError(f"Tag {tag} does not point to HEAD.")

    return f"Release gate passed: {head[:7]}, CI run {latest['html_url']}"


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-tag", action="store_true",
                        help="also require the product version tag to point at HEAD")
    options = parser.parse_args(arguments)
    try:
        print(check_release(options.require_tag))
    except GateError as error:
        print(f"Release gate failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
