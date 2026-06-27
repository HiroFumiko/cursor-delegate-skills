# cursor-delegate

A Claude Code plugin for offloading coding work to the **Cursor CLI** (`agent`).
It bundles two cooperating skills — one to **prepare** the environment, one to
**run** the delegations — so you can hand review / audit / planning /
implementation jobs to Cursor (several in parallel) while Claude keeps working on
something else.

## What's inside

| Skill | Invoke | Role |
|-------|--------|------|
| `cursor-setup` | `/cursor-delegate:cursor-setup` | **Get ready.** Detects the OS, checks every dependency + auth in one pass (no Cursor tokens spent), and wires the read-only permission allowlist. Run once per machine. |
| `cursor` | `/cursor-delegate:cursor` | **Do the work.** Dispatch implement / review / plan / investigate / security tasks to Cursor — single jobs, parallel `fanout`, `resume` / `status` / `cancel`, per-task `preamble`. |

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
