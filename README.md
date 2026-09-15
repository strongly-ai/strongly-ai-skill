<div align="center">

# Strongly Skill

**Teach Claude to use the [Strongly.AI](https://strongly.ai) platform.**

A single [Agent Skill](https://docs.claude.com/en/docs/agents-and-tools/agent-skills)
that gives Claude everything it needs to build on Strongly through the REST API:
deploy apps behind the proxy, provision addons and data sources, run agents and
workflows, and operate MLOps, the model registry, and the AI Gateway.

[![License: MIT](https://img.shields.io/badge/License-MIT-black.svg)](LICENSE)
[![Works with Claude Code](https://img.shields.io/badge/Works%20with-Claude%20Code-6571ff.svg)](https://claude.com/claude-code)
[![Strongly.AI](https://img.shields.io/badge/Powered%20by-Strongly.AI-060c17.svg)](https://strongly.ai)

</div>

---

## What this is

Strongly is a platform for deploying apps, data, models, agents, and workflows on
managed Kubernetes. Everything you can do in the Strongly UI is also reachable
through one REST API at `/api/v1`.

This skill teaches Claude to drive that API correctly, the way an expert operator
would: real endpoints only, answers grounded in the resources you actually have,
async operations polled to completion, and the proxy, identity, and manifest
details that trip most people up handled right the first time.

It is written for **you, the Strongly user**. It is a how-to, not internal
platform documentation.

## Who it's for

Anyone using Claude (Claude Code, Claude in your IDE, or a coding agent) who wants
help getting work done on Strongly, whether you are:

- building and deploying an app,
- wiring up a managed database or an external data source,
- standing up an agent or a workflow,
- training a model, registering it, and serving it,
- or calling third-party and self-hosted models through the AI Gateway.

## What's covered

| Area | Reference |
|------|-----------|
| Apps: proxy, JWT identity, the manifest, artifacts, deploy via REST | [`apps.md`](strongly/references/apps.md) |
| Addons: managed Postgres, Mongo, Redis, and more | [`addons.md`](strongly/references/addons.md) |
| Data sources: connect external DBs, warehouses, object stores | [`datasources.md`](strongly/references/datasources.md) |
| Agents: deploy and chat with Strongly Agents | [`agents.md`](strongly/references/agents.md) |
| Workflows: build and run node graphs, batch and streaming | [`workflows.md`](strongly/references/workflows.md) |
| MLOps: AutoML, experiments, drift, fine-tuning, feature store | [`mlops.md`](strongly/references/mlops.md) |
| Model Registry: register, version, deploy models | [`model-registry.md`](strongly/references/model-registry.md) |
| AI Gateway: third-party and self-hosted models, keys, guardrails | [`ai-gateway.md`](strongly/references/ai-gateway.md) |
| Compute: workspaces, environments, clusters, volumes, code sessions | [`compute.md`](strongly/references/compute.md) |
| Projects: project filesystem and Kanban board | [`projects.md`](strongly/references/projects.md) |
| Governance: policies, gates, evidence, guardrails | [`governance.md`](strongly/references/governance.md) |
| FinOps: costs, budgets, resource groups, schedules | [`finops.md`](strongly/references/finops.md) |
| Marketplace: browse and deploy offerings | [`marketplace.md`](strongly/references/marketplace.md) |
| Library: memory, rules, prompts, tasks, skills, preferences, pools | [`library.md`](strongly/references/library.md) |
| Imprints: installable skill + memory bundles | [`imprints.md`](strongly/references/imprints.md) |
| A/B testing: compare model variants with live traffic | [`ab-testing.md`](strongly/references/ab-testing.md) |
| Avatars: 3D, portrait, and real-time lip-sync avatars | [`avatars.md`](strongly/references/avatars.md) |
| Account, org, and notifications | [`account.md`](strongly/references/account.md) |
| Python SDK: the `strongly` package, the same API in Python | [`python-sdk.md`](strongly/references/python-sdk.md) |

## How it works

The skill uses **progressive disclosure**. A small always-loaded
[`SKILL.md`](strongly/SKILL.md) teaches the essentials once (how to authenticate,
the base URL, the proxy and identity model, and how to find things), then routes
to one reference file per feature that is pulled in only when the conversation is
about that feature. This keeps the always-on footprint small while giving Claude
deep, accurate detail on demand.

```
strongly/
  SKILL.md              always loaded: auth, base URL, proxy/JWT model, routing
  references/           loaded on demand, one file per feature area
  examples/             runnable snippets
```

## Authentication in two words: it depends where you run

The skill teaches Claude to detect its context automatically:

- **Inside Strongly** (an app, or Claude Code / Codex in a Strongly workspace):
  the platform URL is in the environment and a bearer token is injected for you.
  Nothing to configure.
- **Outside Strongly** (your laptop, CI, any external client): you provide your
  Strongly host and a platform **API key** (`Settings -> API Keys`), sent as an
  `X-API-Key` header.

## Install

**Claude Code**, copy or symlink the `strongly/` directory into your skills folder:

```bash
# per project
mkdir -p .claude/skills && cp -r strongly .claude/skills/strongly
# or globally
cp -r strongly ~/.claude/skills/strongly
```

Then start Claude in that project and ask about Strongly. The skill loads itself.

**Other agents** (Cursor, Windsurf, Codex, OpenCode), copy `strongly/` into that
agent's skills directory (`.cursor/skills/`, `.windsurf/skills/`,
`.agents/skills/`, and so on).

**In a Strongly workspace**, this skill is installed automatically for the coding
assistants you enable (Claude Code, Codex), so Claude already knows the platform
the moment your workspace starts. Nothing to do.

## Requirements

- A Strongly account and the host URL of your deployment (for example
  `https://app.strongly.ai`), when working from outside Strongly.
- A platform API key, created under `Settings -> API Keys`. This skill never
  creates keys for you and never handles your passwords.

## Contributing

Issues and pull requests are welcome. Keep contributions user-facing (how to use
the platform through the API), grounded in real `/api/v1` endpoints, and matched
to the style of the existing references.

## Support

Questions, problems, or ideas: [support@strongly.ai](mailto:support@strongly.ai).

## License

[MIT](LICENSE). Powered by [Strongly.AI](https://strongly.ai).
