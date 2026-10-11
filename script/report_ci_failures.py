#!/usr/bin/env python3
"""Maintain one issue for unresolved main-build and tag-release failures."""

import json
import os
import pathlib
import re
import subprocess
import tempfile


TITLE = "CI/CD failures (consolidated)"
LEGACY_TITLE = "CI failures on main (consolidated)"
STATE_PATTERN = re.compile(r"<!-- fillr-ci-state:(.*?) -->", re.S)


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True).strip()


def failed_jobs(needs):
    return sorted(name for name, job in needs.items()
                  if job.get("result") not in ("success", "skipped"))


def read_state(body):
    match = STATE_PATTERN.search(body)
    if match:
        return json.loads(match.group(1))
    legacy_run = re.search(r"Latest run: (https://\S+)", body)
    legacy_jobs = re.findall(r"^- `([^`]+)`$", body, re.M)
    if legacy_run and legacy_jobs:
        return {"main": {"run_url": legacy_run.group(1), "failed_jobs": legacy_jobs}}
    return {}


def render(state):
    lines = ["Unresolved CI/CD failures remain visible without blocking development or",
             "publication by other verified platforms.", ""]
    for ref, item in sorted(state.items()):
        lines += [f"### `{ref}`", "", f"Run: {item['run_url']}", "", "Failed jobs:", ""]
        lines += [f"- `{name}`" for name in item["failed_jobs"]]
        lines.append("")
    lines.append("Inspect each run for test, package, security, and publisher logs.")
    lines += ["", f"<!-- fillr-ci-state:{json.dumps(state, sort_keys=True)} -->", ""]
    return "\n".join(lines)


def main():
    repository = os.environ["GITHUB_REPOSITORY"]
    ref = os.environ["GITHUB_REF"]
    key = "main" if ref == "refs/heads/main" else ref.removeprefix("refs/tags/")
    run_url = f"{os.environ['GITHUB_SERVER_URL']}/{repository}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    failures = failed_jobs(json.loads(os.environ["NEEDS_JSON"]))
    issues = json.loads(gh("issue", "list", "--repo", repository, "--state", "all",
                           "--limit", "100", "--json", "number,title,state,body"))
    issue = next((item for item in issues if item["title"] in (TITLE, LEGACY_TITLE)), None)
    state = read_state(issue["body"]) if issue and issue["state"] == "OPEN" else {}
    if failures:
        state[key] = {"run_url": run_url, "failed_jobs": failures}
    else:
        state.pop(key, None)
    if not state:
        if issue and issue["state"] == "OPEN":
            subprocess.run(["gh", "issue", "close", str(issue["number"]), "--repo", repository],
                           check=True)
        return
    body = render(state)
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / "issue.md"
        path.write_text(body)
        if issue:
            if issue["body"].strip() != body.strip() or issue["title"] != TITLE:
                subprocess.run(["gh", "issue", "edit", str(issue["number"]), "--repo", repository,
                                "--title", TITLE, "--body-file", str(path)], check=True)
            if issue["state"] != "OPEN":
                subprocess.run(["gh", "issue", "reopen", str(issue["number"]),
                                "--repo", repository], check=True)
        else:
            subprocess.run(["gh", "issue", "create", "--repo", repository,
                            "--title", TITLE, "--body-file", str(path)], check=True)


if __name__ == "__main__":
    main()
