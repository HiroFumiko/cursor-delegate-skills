# cursor-delegate

> 日本語版: [README_ja.md](./README_ja.md)

A Claude Code plugin for offloading coding work to the **Cursor CLI** (`agent`).
It bundles two cooperating skills — one to **prepare** the environment, one to
**run** the delegations — so you can hand review / audit / planning /
implementation jobs to Cursor (several in parallel) while Claude keeps working on
something else.

## What's inside

| Skill | Invoke | Role |
|-------|--------|------|
| `cursor-setup` | `/cursor-delegate:cursor-setup` | **Get ready.** Detects the OS, checks every dependency + auth in one pass (no Cursor tokens spent), and wires the read-only permission allowlist. Run once per machine. |
| `cursor` | `/cursor-delegate:cursor` | **Do the work.** Dispatch implement / review / plan / investigate / security tasks to Cursor — single jobs, parallel `fanout`, `resume` / `status` / `cancel`, per-task `preamble`. How to run see [`cursor/README.md`](plugins/cursor-delegate/skills/cursor/README.md).

The two are one unit: `cursor-setup` drives the same engine `cursor` uses
(`lib/setup.sh`), and both resolve to `${CLAUDE_PLUGIN_ROOT}/skills/cursor/…` at
runtime — so setup and delegation always agree on paths, models, and permissions.

## How it fits together

```
   install plugin
        │
        ▼
   /cursor-delegate:cursor-setup        one-time: deps · auth · permissions
        │   READY ✓
        ▼
   /cursor-delegate:cursor <task …>     everyday: delegate to Cursor
        │
        ├─ review / investigate / security / plan   (read-only, auto-approved)
        ├─ implement                                (worktree, prompts first)
        └─ fanout a:… b:…                           (parallel jobs)
```

## Capabilities at a glance

**Delegation (`cursor`)**
- Five explicit task types — `implement` / `review` / `plan` / `investigate` / `security` (never inferred from free text).
- Parallel `fanout`, plus `resume` / `status` / `cancel` and a token-free `--dry-run`.
- Per-task `preamble` to specialize each lens; deterministic config in `.cursor.json` (3-layer deep-merge).
- Read-only lenses run without a prompt; write (`implement`) always prompts.

**Readiness (`cursor-setup`)**
- OS detection (WSL / Linux / macOS; native Windows → WSL) with per-OS fix-it steps.
- Dependency + auth doctor (no `agent` call, zero token cost).
- Generates / audits the `~/.claude/settings.json` permission allowlist.
- macOS stock **bash 3.2** is first-class; BSD-coreutils tolerant.

## Requirements

- `bash` (macOS stock 3.2 is supported), `jq`, `timeout` / `gtimeout` (coreutils)
- Cursor CLI (`agent`) installed and authenticated (`CURSOR_API_KEY` or `agent login`)
- Platforms: WSL Ubuntu / native Linux / macOS are first-class. Native Windows is
  unsupported — use WSL. `cursor-setup` checks all of this for you.

## Quick start

```
# 1. add this marketplace and install the plugin
/plugin marketplace add HiroFumiko/cursor-delegate-skills
/plugin install cursor-delegate@cursor-delegate

# 2. one-time readiness check (verifies deps/auth, offers to wire permissions)
/cursor-delegate:cursor-setup

# 3. delegate
/cursor-delegate:cursor review "audit src/auth.ts"
/cursor-delegate:cursor fanout review:src/a.ts security:src/a.ts
```

Reload after editing the plugin: `/reload-plugins`.

## Choosing a model (`.cursor.json`)

Every task type routes to a `model`, resolved from `.cursor.json`. The shipped
default is **`auto`** — Cursor picks a model server-side — so nothing needs
configuring to get started. To pin a specific model, set `model` in any config
layer.

**Model names come from `agent --list-models`.** Each line is printed as
`<name> - <description>`; the **token to the left of ` - ` is the model name** —
that leading prefix is what you reference in `.cursor.json`. Copy it verbatim:

```
$ agent --list-models
Available models

auto - Auto (current)
gpt-5.3-codex - Codex 5.3
gpt-5.3-codex-high - Codex 5.3 High
claude-opus-4-8-thinking-high - Opus 4.8 1M Thinking
composer-2.5 - Composer 2.5
…
```

| `agent --list-models` line | `"model"` value to use |
|----------------------------|------------------------|
| `auto - Auto (current)`                              | `"auto"`                          |
| `gpt-5.3-codex-high - Codex 5.3 High`                | `"gpt-5.3-codex-high"`            |
| `claude-opus-4-8-thinking-high - Opus 4.8 1M Thinking` | `"claude-opus-4-8-thinking-high"` |

Set it per task type, in whichever layer matches the scope you want:

```jsonc
// <repo>/.cursor.json — pin review + security for this project only
{
  "defaults": {
    "review":   { "model": "gpt-5.3-codex-high" },
    "security": { "model": "claude-opus-4-8-thinking-high" }
  }
}
```

Precedence is **deep-merged, last wins** across three layers:

1. `${CLAUDE_PLUGIN_ROOT}/skills/cursor/config/.cursor.json` — skill default
2. `~/.cursor.json` — user override (applies everywhere)
3. `<cwd>/.cursor.json` — project override (commit it to share with the repo)

Because the merge is per-leaf, a `<repo>/.cursor.json` that only sets
`review.model` keeps every other field (`mode`, `preamble`, `sandbox`, …) from
the layers beneath it.

**Validation.** The resolved model is matched against `agent --list-models` at
launch, anchored to the line-start token (so `composer-2` won't match
`composer-2.5`). An unknown name fails fast with `exit 3` and prints the
available list — nothing is dispatched to Cursor, so a typo never spends a token.

Full schema, routing defaults, and the `auto` mechanics live in
[`skills/cursor/references/configuration.md`](plugins/cursor-delegate/skills/cursor/references/configuration.md).

## Layout

```
cursor-delegate/
├── .claude-plugin/
│   └── marketplace.json                 # marketplace manifest (source -> ./plugins/cursor-delegate)
├── plugins/
│   └── cursor-delegate/
│       ├── .claude-plugin/
│       │   └── plugin.json              # plugin manifest
│       └── skills/                      # auto-discovered
│           ├── cursor/                  # delegation engine (lib/, config/, references/, tests/)
│           └── cursor-setup/            # readiness doctor (shares cursor/lib/setup.sh)
└── README.md                            # this file
```

## Notes

- Skill internals resolve their own location via `BASH_SOURCE`, so the engine is
  path-independent; the launch commands in each `SKILL.md` use
  `${CLAUDE_PLUGIN_ROOT}` to work wherever the plugin installs.
- Each bundled skill keeps its own deep-dive docs: `skills/cursor/README.md` /
  `README_ja.md` (and `references/`). Those describe **manual** installation under
  `~/.claude/skills/`; for plugin use, follow the steps above.
- Unit tests ship with the plugin: `bash skills/cursor/tests/run.sh unit`
  (stub `agent`, no key needed) — 17/17 on macOS bash 3.2.
