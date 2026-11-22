"""PreToolUse hook: block Claude from writing to secret-bearing files."""

import json
import re
import sys

BLOCKED = [
    r"(^|[\\/])\.env(\..*)?$",
    r"\.tfvars$",  # except allowlisted non-secret file below
    r"\.tfstate(\.backup)?$",
    r"\.(pem|key|pfx|p12)$",
    r"(^|[\\/])\.?kubeconfig$",
    r"(^|[\\/])\.kube[\\/]config$",
    r"(^|[\\/])id_(rsa|ed25519)$",
    r"secret[^\\/]*\.(ya?ml|json)$",
]
ALLOWED = [r"\.env\.example$", r"[\\/]envs[\\/][^\\/]+[\\/]terraform\.tfvars$"]


def main() -> int:
    data = json.load(sys.stdin)
    path = (data.get("tool_input") or {}).get("file_path", "")
    if not path or any(re.search(p, path, re.IGNORECASE) for p in ALLOWED):
        return 0
    if any(re.search(p, path, re.IGNORECASE) for p in BLOCKED):
        print(
            f"Blocked: '{path}' looks like a secret file. Secrets go in Key Vault; "
            "ask the user to handle this file themselves.",
            file=sys.stderr,
        )
        return 2  # exit 2 = block the tool call, stderr shown to Claude
    return 0


if __name__ == "__main__":
    sys.exit(main())
