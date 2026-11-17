# AI-augmented workflow

How this repo is built with agents, and why each piece exists.

| Piece | What | Why |
|---|---|---|
| `CLAUDE.md` | Rules, layout, commands every session reads | Consistent behaviour without re-explaining |
| Subagents (`.claude/agents/`) | researcher (read-only), infra-writer, reviewer (read-only) | Narrow tools = narrow blast radius; fresh context per job |
| Permissions (`.claude/settings.json`) | allow: read/test/validate/plan · ask: `az`, `kubectl`, `init`, `apply`, push · deny: `destroy`, force-push, reading state | Agents move fast on safe things; anything touching cloud/IAM stops for a human |
| Hooks | PreToolUse blocks secret files; PostToolUse runs `terraform fmt`+`validate` after `.tf` edits | Mechanical guardrails beat instructions |
| CI (`.github/workflows/pr.yml`) | fmt/validate/tflint, plan via OIDC, ruff/pytest, web build, gitleaks | Same checks whether a human or an agent wrote the code |
| Worktrees | `git worktree add ../gyazo-clone-<task> -b <type>/<task>` | Parallel agent sessions on separate branches, no file collisions |
| Review | reviewer subagent before every PR; optional Claude GitHub App review on PRs | Findings fixed before the human looks |
| Retro | After each milestone: what went wrong → proposed edits to CLAUDE.md/hooks/skills | The system learns; mistakes don't repeat |

## Task loop
spec + acceptance check → researcher (if a decision) → build on a branch → hooks/tests prove it → reviewer → PR + CI → **human gate** → (cloud change: **human approves apply**) → retro at milestone end.

## MCP servers (proposed, least privilege)
- **GitHub** — PRs/issues/CI. Needs a fine-grained PAT scoped to this repo only (or reuse `gh` CLI, which already works — preferred, no new credential).
- **Microsoft Learn docs MCP** — `https://learn.microsoft.com/api/mcp`, read-only, no credentials. Best value.
- **Azure MCP** — reads resources via your `az login`; add after M1 and keep to Reader on the RG.
- **Grafana MCP** — query dashboards/Prometheus during experiments; service account token with Viewer role. M3+.

## Candidate skills (write when the procedure repeats)
add-terraform-module · add-grafana-dashboard · add-alert-rule/SLO · run-failure-experiment (template + write-up) · aks-start-stop (cost) · teardown-and-verify.
