# gyazo-clone — platform engineering portfolio project

Gyazo-style image sharing (upload → short link → view) on Azure. **The app is deliberately thin; infra, delivery, observability and failure handling are the point.** Full brief: `HANDOFF.md`. Scope: `docs/spec.md`. Decisions: `docs/decisions.md` (add an entry for every non-trivial choice: context, decision, alternatives, why).

## Hard guardrails (never violate)
- Never run `terraform apply`/`destroy`, or any command that creates, changes or deletes Azure resources or spends money, without the user's explicit approval **in the current session**.
- Never commit secrets. No keys in code, tfvars, manifests or provenance. Use workload identity / OIDC; secrets live in Key Vault.
- **Ask the user only for:** `terraform apply`/`destroy` and any other cloud change (show the `terraform plan` first); spending money; secrets; IAM/role assignments; deleting data or resources. Everything else — branches, commits, PRs, merging green+reviewed PRs, repo settings, tool installs, routine decisions — proceed and report. Record non-trivial decisions in `docs/decisions.md`.
- Prove work: run fmt/validate/tests/lint and show output. Never claim "works" without evidence.
- Resist scope creep: no login, social, editing, video. Out-of-scope ideas go to `docs/spec.md` → "Later".

## Repo layout
```
app/api/          FastAPI service (+ built React static files)
app/web/          React (Vite) frontend
app/worker/       queue worker (thumbnail/metadata; pluggable processor)
infra/bootstrap/  one-time Terraform state backend
infra/terraform/  main Terraform (modules/ + envs/dev)
deploy/manifests/ raw k8s manifests (M3) → deploy/helm/ (M5) → deploy/argocd/ (M6)
observability/    dashboards, alert rules, SLO definitions
experiments/      failure experiments: plan + results per experiment
ansible/          M8 optional runner VM config
docs/             spec, decisions, diagrams/, runbooks
```

## Commands
- Terraform: `terraform -chdir=infra/terraform/envs/dev fmt -recursive && terraform -chdir=... validate`; `tflint --recursive`
- Python (uv): `uv run pytest`, `uv run ruff check .`, `uv run ruff format --check .`
- Web: `npm --prefix app/web run lint|test|build`
- K8s: `kubectl apply --dry-run=server -f ...` (prompt), `helm lint deploy/helm/*`
- Workflows: `MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W):/repo" -w /repo rhysd/actionlint:1.7.7` — same image as CI, includes shellcheck (YAML parsing alone misses expression/context errors)
- IaC scan: `uvx --python 3.12 --from checkov python -m checkov.main -d . --compact` (`uvx checkov` fails on Windows)

## Conventions
- Azure naming: `<type>-gyazo-<env>` (e.g. `rg-gyazo-dev`); storage/ACR: `stgyazo<env><suffix>`. Tags on everything: `project=gyazo-clone`, `env`, `owner`, `managed_by=terraform`.
- Region: set in `envs/dev/terraform.tfvars` (non-secret only).
- Pin provider and chart versions. Prefer AKS add-ons/managed options over self-installed when equivalent.
- Branch per task, worktree per parallel task: `git worktree add ../gyazo-clone-<task> -b <type>/<task>` (`feat|infra|fix|docs|exp`). One writer per set of files.
- Commits: conventional (`infra: add network module`). Small PRs; CI must be green.
- Before reporting a PR ready: run the `reviewer` subagent on the diff and fix findings. For changes under `app/` (and the M-AI processor), also run the built-in `/security-review` and fix or record its findings.
- After each milestone: retro — propose edits to this file, hooks, or skills; user approves.

## Agents (`.claude/agents/`)
- `researcher` — read-only; verify Azure/K8s facts against current docs before decisions.
- `infra-writer` — writes Terraform/manifests/Helm per these conventions; runs fmt/validate.
- `reviewer` — read-only review of a diff for security, IAM, cost, correctness.
- `auditor` — read-only check of the orchestrator's *process* (delegation, review coverage, evidence behind claims) before anything is presented for approval.

## Orchestration rules (from the M1 lessons)
- Researcher before any decision or unfamiliar API. Infra-writer makes Terraform/manifest edits; the orchestrator doesn't hand-edit IaC except trivial typos, and those still get reviewed.
- **Any commit after the reviewer's last approval goes back to the reviewer**, including "small" fixes made during an apply.
- After any `.tf` edit, run the full suite (fmt, validate both roots, tflint, checkov) before committing, not just the check you think is relevant.
- Auditor sign-off before presenting a plan for apply, a merge, or a milestone as done.
- Live verification (apply, drift re-plan, CI OIDC run) is a required step: some bugs only show up there.

## Retro rules (from M1)
- Label every claim: **verified** (evidence: run ID, command output), **design-verified** (read the code/docs only) or **untested**. A no-op apply proves "no drift", never "CI created it" or "the write path works".
- Dependabot: major-version action bumps go to the reviewer. Anything touching `apply.yml` also needs one manual `workflow_dispatch` apply run (owner approves the gate) before it counts as proven.
- New CI job → decide in the same PR whether it is a required check on `main`, and record why. Keep required-check names equal to job `name:` fields.
- Milestone close: `docs/spec.md` → "Milestone status" gets an evidence list and a known-gaps table (each gap has an owner and a "close by" trigger, e.g. "before M3 creates AKS"). The auditor checks it exists before sign-off.
