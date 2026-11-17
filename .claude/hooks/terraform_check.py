"""PostToolUse hook: after a .tf edit, run terraform fmt and validate in that directory."""

import json
import pathlib
import shutil
import subprocess
import sys


def run(args: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess:
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=120)


def main() -> int:
    data = json.load(sys.stdin)
    path = (data.get("tool_input") or {}).get("file_path", "")
    if not path.endswith((".tf", ".tfvars")):
        return 0
    tf = shutil.which("terraform")
    if not tf:
        print("terraform not on PATH; skipped fmt/validate", file=sys.stderr)
        return 0
    d = pathlib.Path(path).parent
    problems = []

    fmt = run([tf, "fmt", path], d)
    if fmt.returncode != 0:
        problems.append("terraform fmt failed:\n" + fmt.stderr)

    if path.endswith(".tf"):
        if not (d / ".terraform").exists():
            init = run([tf, "init", "-backend=false", "-input=false", "-no-color"], d)
            if init.returncode != 0:
                problems.append("terraform init -backend=false failed:\n" + init.stderr)
        if not problems:
            val = run([tf, "validate", "-no-color"], d)
            if val.returncode != 0:
                problems.append("terraform validate failed:\n" + val.stdout + val.stderr)

    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 2  # feed errors back to Claude so it fixes them
    return 0


if __name__ == "__main__":
    sys.exit(main())
