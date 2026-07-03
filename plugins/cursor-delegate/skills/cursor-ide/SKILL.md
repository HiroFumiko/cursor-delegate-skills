---
name: cursor-ide
description: Launch the Cursor IDE (GUI editor) at a directory or file via the `cursor` shell command — no separate terminal needed. Use when the user wants to OPEN / LAUNCH the Cursor app/editor at a path they name in natural language (this is NOT delegating a coding task — that is the `cursor` skill). Resolves the path and runs `cursor <path>`. Triggers on "launch cursor", "open cursor", "open in cursor", "open this in the Cursor IDE", "cursor ide", 「cursorを立ち上げ」「cursor起動」「cursorを開く」「cursorでこのディレクトリを開いて」「cursorでフォルダを開く」.
argument-hint: "[path] [-n|--new-window] [-r|--reuse-window] [--mkdir]"
level: 1
version: 1.0.0
---

# cursor-ide

Open the **Cursor IDE (GUI)** at a directory (or file) without leaving Claude
Code — so you never have to open a separate terminal just to type `cursor .`.

This wraps the VS Code-family launcher `cursor <path>`. It is a **different
binary** from the `agent` / `cursor-agent` CLI that the sibling
[`cursor`](../cursor/SKILL.md) delegation skill drives:

| Intent | Skill | Underlying command |
|--------|-------|--------------------|
| **Open the editor GUI at a path** | `cursor-ide` (this) | `cursor <path>` |
| Delegate a coding task headlessly | `cursor` | `agent -p …` |

So "cursorでレビューして" → the `cursor` skill; "cursorでこのディレクトリを開いて"
/ "launch cursor here" → this skill.

## Engine

```
bash ${CLAUDE_PLUGIN_ROOT}/skills/cursor-ide/lib/launch.sh [options] [PATH]
```

| Option | Effect |
|--------|--------|
| `PATH` (positional) | directory or file to open; **defaults to the current directory** when omitted |
| `-n`, `--new-window` | force a new window |
| `-r`, `--reuse-window` | open in the most recently active window |
| `--mkdir` | create `PATH` (as a directory) if it does not exist, then open it |
| `--dry-run` | print the resolved `cursor …` command without launching |
| `-h`, `--help` | usage |

## Protocol (how Claude should run this)

1. **Resolve the directory from natural language to a concrete path.** The user
   names the target in prose ("開いて ~/Workspace/foo", "このリポジトリを cursor で",
   "open the parent dir"). Claude turns that into an absolute path (or leaves it
   empty to mean the current directory) and passes it as `PATH`. The script also
   expands a leading `~` and absolutizes relative paths as a safety net.
2. **Run the engine** with that path and any window flag the user asked for.
3. **Report the result** from stdout: `LAUNCHED\t<abspath>` on success. Relay the
   opened path; the GUI launches in the background and the command returns
   immediately.

If the user references a not-yet-existing directory, add `--mkdir` (only after
it is clear they want it created).

## Preflight & fallback

Before launching, the engine checks `command -v cursor`. If the `cursor`
launcher is **not on PATH**, it exits `2` and prints OS-aware install guidance
(macOS / Linux / WSL) instead of failing silently:

- **macOS** — install the Cursor app from <https://cursor.com>, then run
  `Cmd+Shift+P → "Shell Command: Install 'cursor' command in PATH"` and restart
  the shell.
- **Linux** — install the Cursor app (`.AppImage` / `.deb` ships the `cursor`
  launcher); put its bin dir on PATH.
- **WSL** — install Cursor on Windows and make `cursor` resolve inside WSL
  (Windows PATH interop or Cursor's "Install 'cursor' command").

Relay the printed hint to the user; do not attempt to auto-install.

## Platform support

macOS, native Linux, and Linux on WSL — anywhere the `cursor` launcher is on
PATH. Existence is checked with `command -v cursor` (portable; consistent with
the rest of this plugin). Native Windows is unsupported → use WSL.

## Permissions

Launching a GUI is a benign, non-destructive side-effect, but by default a
`bash …/launch.sh …` call still prompts. To run it without a prompt, add an
allow rule to `~/.claude/settings.json`, e.g.:

```
Bash(bash *skills/cursor-ide/lib/launch.sh:*)
```

## Examples

```bash
# open the current directory
bash ${CLAUDE_PLUGIN_ROOT}/skills/cursor-ide/lib/launch.sh

# open a specific directory in a new window
bash ${CLAUDE_PLUGIN_ROOT}/skills/cursor-ide/lib/launch.sh -n ~/Workspace/foo

# create a scratch dir then open it
bash ${CLAUDE_PLUGIN_ROOT}/skills/cursor-ide/lib/launch.sh --mkdir ~/Workspace/new-project

# preview the command without launching
bash ${CLAUDE_PLUGIN_ROOT}/skills/cursor-ide/lib/launch.sh --dry-run ~/Workspace/foo
```

## Testing

`bash tests/unit/test_launch.sh` — self-contained (fake `cursor` stub, no GUI,
no network). Covers path resolution, default-to-cwd, `--dry-run`, `--mkdir`, and
the missing-`cursor` fallback.
