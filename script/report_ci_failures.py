#!/usr/bin/env python3
"""Keep one GitHub issue for unresolved failures on main CI runs."""

import json
import os
import pathlib
import subprocess
import tempfile


TITLE = "CI failures on main (consolidated)"


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True).strip()


def failed_jobs(needs):
    return sorted(
        name for name, job in needs.items()
        if job.get("result") not in ("success", "skipped")
    )


def main():
    repository = os.environ["GITHUB_REPOSITORY"]
    run_url = f"{os.environ['GITHUB_SERVER_URL']}/{repository}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    failures = failed_jobs(json.loads(os.environ["NEEDS_JSON"]))
    issues = json.loads(gh("issue", "list", "--repo", repository, "--state", "all",
                           "--limit", "100", "--json", "number,title,state"))
    issue = next((item for item in issues if item["title"] == TITLE), None)
    if not failures:
        if issue and issue["state"] == "OPEN":
            subprocess.run(["gh", "issue", "close", str(issue["number"]), "--repo", repository,
                            "--comment", f"All monitored jobs passed in {run_url}."], check=True)
        return

    body = ("This issue tracks the latest unresolved failures on `main`. "
            "CI results remain visible and do not prevent direct development pushes.\n\n"
            f"Latest run: {run_url}\n\nFailed jobs:\n" +
            "".join(f"- `{name}`\n" for name in failures) +
            "\nInspect the run for matrix targets and logs. The next main run updates this issue.\n")
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / "issue.md"
        path.write_text(body)
        if issue:
            subprocess.run(["gh", "issue", "edit", str(issue["number"]), "--repo", repository,
                            "--body-file", str(path)], check=True)
            if issue["state"] != "OPEN":
                subprocess.run(["gh", "issue", "reopen", str(issue["number"]),
                                "--repo", repository], check=True)
        else:
            subprocess.run(["gh", "issue", "create", "--repo", repository,
                            "--title", TITLE, "--body-file", str(path)], check=True)


if __name__ == "__main__":
    main()
