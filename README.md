# Strongly — a Claude skill for using the Strongly.AI platform

This repo holds a single [Agent Skill](https://docs.claude.com/en/docs/agents-and-tools/agent-skills)
that teaches Claude how to help a user **use the Strongly.AI platform** — building
and deploying apps, wiring up addons and data sources, running agents and
workflows, and operating MLOps, the model registry, and the AI Gateway — through
the Strongly REST API (`/api/v1`).

It is written for the **end user**: "here is the call to make," not platform
internals. If you maintain Strongly itself, this is not that documentation.

## What's in here

```
strongly/
  SKILL.md              # always-loaded: auth, base URL, the proxy/JWT model, routing
  references/           # loaded on demand, one file per feature area
    apps.md             # proxy, JWT identity, artifacts, deploy via REST
    addons.md           # (coming)
    datasources.md      # (coming)
    agents.md           # (coming)
    workflows.md        # (coming)
    mlops.md            # (coming)
    model-registry.md   # (coming)
    ai-gateway.md       # (coming)
  examples/             # runnable snippets referenced by the guides
```

The skill uses **progressive disclosure**: `SKILL.md` stays small and always
loaded; a feature's full detail lives in `references/<feature>.md` and is only
pulled in when the conversation is about that feature.

## Install

**Claude Code** — copy or symlink the `strongly/` directory into your skills dir:

```bash
# per project
mkdir -p .claude/skills && cp -r strongly .claude/skills/strongly
# or globally
cp -r strongly ~/.claude/skills/strongly
```

Then start Claude in that project; the skill loads when you ask about Strongly.

**Other agents** (Cursor, Windsurf, Codex, OpenCode) — copy `strongly/` into that
agent's skills directory (`.cursor/skills/`, `.windsurf/skills/`, `.agents/skills/`, …).

## Prerequisites for the user

- A Strongly account and the **host URL** of your deployment (e.g. `https://app.strongly.ai`).
- A **platform API key** (Settings → API Keys). The skill never creates keys for you.

## License

MIT — Powered by [Strongly.AI](https://strongly.ai)
