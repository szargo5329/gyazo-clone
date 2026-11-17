# Handoff: Gyazo-style image sharing platform on Azure (platform engineering portfolio project)

Read this fully before doing anything. Then work in plan mode and do not edit files until I approve a plan.

## Who I am and why this exists

- I'm a software engineer (QA/test automation at my day job; app-dev background in Python/FastAPI and Angular/TypeScript/.NET) pivoting into cloud / DevOps / platform engineering.
- This is a portfolio project. The goal is to demonstrate platform engineering competence, not to build a great product.
- The application layer is deliberately thin. The infrastructure, delivery pipeline, observability, and failure handling are the point.
- I have built a production-style AWS serverless project (a URL shortener with Terraform and GitHub Actions OIDC). I am new to Azure, so explain Azure-specific concepts (Entra ID, RBAC, managed identity, AKS networking) as you introduce them.
- I need to be able to explain and defend every design decision in an interview. If you make a choice, tell me why and what the alternatives were.

## The product

A Gyazo-style app: upload an image (or screenshot), get a short shareable link, and view the image at that link.

- Framing: an "image processing platform". The processing step is a trivial stub (for example, generate a thumbnail or read metadata). It exists to give the system an async worker and a queue, not to be interesting.
- Explicitly out of scope: user login, streaks, gamification, social features, editing tools. Do not add them. Resist feature creep.
- Keep the app small: an API (Python/FastAPI is fine), a minimal frontend, Blob Storage for images, a simple database for metadata.

## Target architecture (propose, don't assume)

- Azure: AKS, ACR, Blob Storage, Key Vault, managed identities / workload identity, a simple networking setup.
- Provisioning with Terraform. Ansible only where OS-level configuration genuinely applies (an earlier design had a deliberate small VM exception to give Ansible real work; propose whether that still makes sense here).
- Kubernetes delivery progression, one layer at a time: raw manifests, then Helm, then ArgoCD (GitOps). I am still learning Helm and ArgoCD, so explain what each layer adds before introducing it.
- CI/CD with GitHub Actions using OIDC federation to Azure (no long-lived secrets).
- Observability is cross-cutting and gets built in from the first slice, not bolted on at the end: metrics (Prometheus), dashboards (Grafana), logs, tracing (OpenTelemetry), and at least one SLO with alerting.
- Failure scenario planning is the strongest part of the design and must not be cut: define and run experiments (kill a pod, break storage access, saturate the worker queue, bad deploy and rollback) and document what the dashboards showed and how the system recovered.

## Known risks (please help me manage these)

- Scope creep: many technologies, easy to sprawl.
- Observability treated as a final add-on.
- My Python is application-oriented; infrastructure-style Python (operational scripts, glue code) is a skill I want practice in.
- Cost: AKS nodes bill while running. Use small node pools, auto-shutdown where possible, and document teardown. I tore down my previous project after verifying it, so plan for the same here.

## How I want to work with you

- You are the orchestrator. Plan, break work into tasks with acceptance checks, delegate to subagents where it helps (researcher, infra-writer, reviewer), and verify before reporting done.
- Be direct and honest. Tell me when a choice is questionable, over-engineered, or wrong. Do not just validate.
- Keep me in the loop at these gates, and stop for my approval at each:
  1. Before work starts: I approve the plan.
  2. Before merge: I review the diff and the `terraform plan` output.
  3. Before any `terraform apply`, and before anything that creates, deletes, or changes cloud resources or spends money.
  4. Always: secrets, IAM/role changes, and deletions.
- Never run `terraform apply` or `destroy`, or create Azure resources, without explicit approval in this session. Never commit secrets.
- Prove your work: run `terraform fmt` / `validate`, tests, and linters, and show me results rather than asserting things work.
- Keep sessions focused: one task per session where possible, short `CLAUDE.md`, decisions recorded in `docs/decisions.md`.

## What I want from this first session

1. Read this handoff. Ask me any blocking questions (at most a few). Examples worth confirming: Azure subscription and region, whether I have a budget cap set, preferred app language, GitHub repo name.
2. Create (after I approve the plan):
   - `CLAUDE.md`: commands, repo layout, conventions, hard guardrails from above.
   - `docs/spec.md`: goals, scope, non-goals, success criteria.
   - `docs/decisions.md`: a running log of architecture decisions (context, decision, alternatives, why).
   - `.claude/agents/`: a `reviewer` (security, IAM, cost), a `researcher` (read-only, reads Azure docs), and an `infra-writer` (Terraform and manifests per our conventions).
   - Hooks: run `terraform fmt`/`validate` after Terraform edits; block writes to secret files.
   - A GitHub Actions workflow running plan, tests, and lint on PRs.
3. Set up the AI-augmented workflow itself, not just the project. I also want to learn this process, so for each item explain what it is and why you chose it:
   - A permissions allowlist in `.claude/settings.json`: safe read/test/validate commands pre-approved, anything that changes cloud state still prompts.
   - MCP servers worth connecting (GitHub, Azure docs/resources, Grafana or Prometheus), with the least privilege that works. Tell me which ones need credentials from me.
   - A git worktree convention so parallel tasks run on separate branches without colliding.
   - A PR review step (reviewer subagent locally, and optionally automated review on PRs) before I look at anything.
   - A lightweight retrospective habit: after each milestone, propose edits to `CLAUDE.md`, skills, or hooks based on what went wrong, and let me approve them.
   - Candidate skills to write once a procedure repeats (for example "add a Terraform module" or "add a Grafana dashboard").
   - Tell me what you cannot set up yourself and need me to do (installs, Azure subscription, billing alerts, GitHub repo settings, secrets).
4. Propose a milestone plan with a first vertical slice: upload an image, store it in Blob Storage, return a shareable link, serve it, deployed on AKS, with basic metrics and one dashboard. Include rough effort per milestone and the verification step for each.

## Definition of done for the whole project

- Reproducible from a clean Azure subscription with Terraform plus documented steps.
- Delivered via GitOps (ArgoCD) with a working CI pipeline using OIDC.
- Dashboards, alerts, and at least one SLO working against real traffic.
- A documented set of failure experiments with results.
- A README with an architecture diagram, cost notes, teardown steps, and a decisions log I can walk through in an interview.
