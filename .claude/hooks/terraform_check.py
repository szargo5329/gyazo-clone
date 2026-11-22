"""PostToolUse hook: after a .tf edit, run terraform fmt, validate and tflint in that directory.

tflint was added after the M1 retro: skipping it once let an unused variable reach CI.
"""

import json
import pathlib
import shutil
import subprocess
import sys

# Per-call limit stays well under the hook's 180s budget (settings.json), so a slow step
# is reported back as a problem (exit 2) instead of the harness killing the hook silently.
TIMEOUT_S = 40  # up to 4 calls (fmt, init, validate, tflint): 160s < 180s


def run(args: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(  # noqa: S603 - argv from shutil.which, no shell
            args,
            check=False,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        msg = f"{pathlib.Path(args[0]).name} {' '.join(args[1:2])} timed out after {TIMEOUT_S}s"
        return subprocess.CompletedProcess(args, 124, stdout="", stderr=msg)


def tflint(d: pathlib.Path) -> list[str]:
    exe = shutil.which("tflint")
    if not exe:
        print("tflint not on PATH; skipped tflint", file=sys.stderr)
        return []
    root = next((p for p in [d, *d.parents] if (p / ".tflint.hcl").exists()), None)
    args = [exe, "--no-color", f"--chdir={d}"]
    if root:
        args.append(f"--config={root / '.tflint.hcl'}")
    res = run(args, d)
    if res.returncode != 0:
        hint = "tflint failed (run `tflint --init` if plugins are missing):"
        return [f"{hint}\n{res.stdout}{res.stderr}"]
    return []


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
        problems += tflint(d)

    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 2  # feed errors back to Claude so it fixes them
    return 0


if __name__ == "__main__":
    sys.exit(main())
