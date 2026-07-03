# cursor skill — configuration reference (canonical)

This is the **single source of truth** for the `.cursor.json` schema, the
config precedence chain, the routing defaults, and the `preamble` mechanics.
SKILL.md and the READMEs keep only a compact summary and link here for the full
detail — so the schema lives in one place and can't drift across docs.

## Table of contents

- [File precedence](#file-precedence)
- [Schema](#schema)
- [Task routing defaults](#task-routing-defaults)
- [`auto` model](#auto-model)
- [`preamble` — per-task prompt](#preamble--per-task-prompt)

## File precedence

**Deep-merged, last wins.** Layers in ascending precedence:

1. `${CLAUDE_PLUGIN_ROOT}/skills/cursor/config/.cursor.json` — skill default
2. `~/.cursor.json` — user override
3. **project** — discovered via git (see below), in ascending precedence:
   1. `<main-checkout-root>/.cursor.json` — shared baseline across all git
      worktrees (resolved from `git rev-parse --git-common-dir`)
   2. `<current-worktree-root>/.cursor.json` — per-worktree override
      (`git rev-parse --show-toplevel`)
   3. `$PWD/.cursor.json` — non-git fallback, or the closest config when the run
      starts in a repo subdirectory
4. `$CURSOR_DELEGATE_PROJECT_CONFIG` — explicit override path, **highest**
   precedence (an escape hatch for wrappers/CI; wins over all discovery)

All share the same `.cursor.json` shape. The merge is a recursive jq object
merge (`reduce .[] as $x ({}; . * $x)`): leaf collisions take the deeper layer;
a scalar/array value is **replaced** (not concatenated) by a deeper layer.

### git worktree discovery

The project layer is resolved against the **git repository**, not a bare `$PWD`.
This is what lets git worktrees work: a project config committed to — or living
untracked in — the **main checkout** is picked up from every linked worktree
(via `--git-common-dir`), and a worktree may override it with its own
root-level `.cursor.json` (via `--show-toplevel`). Anchoring at the git boundary
also avoids ever walking up into `~/.cursor.json` and double-counting the user
layer as a project layer.

- **git is a soft dependency.** Outside a git work tree — or if `git` is not
  installed — the project layer is simply `$PWD/.cursor.json`, i.e. the
  historical behavior, with no error.
- In a **plain checkout started at its root**, layers 3.1/3.2/3.3 are the same
  file and collapse (de-duplicated) to a single project layer. Paths are
  canonicalized to their physical (symlink-resolved) form so duplicates de-dupe
  reliably (e.g. macOS `/var` → `/private/var`).
- Bare repositories are not work trees, so discovery is skipped there.

The merged result is snapshotted **per JOB_ID** to
`.cursor/delegate/state/resolved-config-<JOB_ID>.json` at invocation time — no
shared path, no cross-job TOCTOU. The state dir stays `$PWD`-relative, so each
worktree keeps its own runtime state.

## Schema

```jsonc
{
  "version": 1,
  "defaults": {
    "implement":   { "model": "auto", "force": true,  "worktree": true,  "sandbox": "enabled" },
    "review":      { "model": "auto", "mode": "ask",  "sandbox": "enabled",
                     "preamble": ["You are a code reviewer…", "{{prompt}}"] },
    "plan":        { "model": "auto", "mode": "plan", "sandbox": "enabled" },
    "investigate": { "model": "auto", "mode": "ask",  "sandbox": "enabled" },
    "security":    { "model": "auto", "mode": "ask",  "sandbox": "enabled" }
  },
  "retry":       { "max_attempts": 3, "initial_delay_ms": 1000, "backoff": "exponential" },
  "timeout_sec": 590,
  "max_fanout":  4
}
```

`taskRoute` fields: `model` (required), `mode` (`ask|plan|agent|edit`), `force`
(bool), `worktree` (bool), `sandbox` (`enabled|disabled`), `preamble`
(string or array-of-strings). The machine-readable JSON Schema is
`config/schema.json`.

A fully annotated, copy-pasteable version of this schema — every field with an
inline comment — ships as [`config/.cursor.example.json`](../config/.cursor.example.json).
It is a reference only (never loaded by the skill): strip the `//` comments,
keep only the keys you override, and save the result as `~/.cursor.json` or
`<repo>/.cursor.json`. To generate a ready-to-use config instead, run
`bash lib/setup.sh --init-config user|project` — it writes a copy of the shipped
defaults you can edit in place. (A full copy pins those values into the override
layer, so a field you keep no longer tracks future skill-default updates; delete
a field to re-enable default tracking, or empty `defaults` for a diff-only file.)

## Task routing defaults

| task_type    | model | mode | force | worktree | sandbox | preamble |
|--------------|-------|------|-------|----------|---------|----------|
| implement    | auto  | —    | true  | **true** | enabled | —        |
| review       | auto  | ask  | false | false    | enabled | ✓        |
| plan         | auto  | plan | false | false    | enabled | —        |
| investigate  | auto  | ask  | false | false    | enabled | ✓        |
| security     | auto  | ask  | false | false    | enabled | ✓        |

`implement` **always** appends `--worktree impl-<short-id>` (no opt-out in v1).
The read-only lenses (review / investigate / security) are otherwise identical
at the `agent` argv level; their **`preamble`** is the only differentiator.

## `auto` model

The shipped default is `auto` for every task type — Cursor's "Auto" picks a
model server-side (`agent --model auto`; `auto` is a valid entry in
`agent --list-models`). To pin a model, set `model` in any layer to a name from
`agent --list-models`.

## `preamble` — per-task prompt

A `preamble` is task-specific text combined with the user prompt before it is
handed to `agent`. (Cursor's `agent` has no system-prompt flag — the prompt is a
single positional argument — so a per-task instruction is necessarily *prepended
to* the user prompt.)

- **Type:** a `string`, or an **array of strings** joined with `\n` (the array
  form keeps multi-line prompts readable in JSON).
- **`{{prompt}}` placeholder:** if the preamble contains `{{prompt}}`, the user
  prompt is substituted at that exact spot (so the preamble can wrap text
  *before and after*). If absent, the preamble is prepended with a `\n\n---\n\n`
  separator.
- **No preamble → verbatim:** a task without a `preamble` passes the user prompt
  through unchanged (fully backward compatible).
- **Merge & override:** `preamble` follows the same layered deep-merge as every
  other field — a deeper layer **replaces** it. Disable a shipped default with
  `"preamble": ""`, or retune it per-repo in the repo-root `.cursor.json`.
- **Composition is done in jq** (`join` / `gsub`), not bash parameter expansion,
  so arbitrary prompt text (backslashes, quotes) is handled safely on bash 3.2.

```jsonc
"security": {
  "model": "auto", "mode": "ask",
  "preamble": [
    "You run the security audit. Analyze the target centered on the OWASP Top 10,",
    "and report findings with severity. Do not modify any code.",
    "{{prompt}}"
  ]
}
```

Inspect the composed result without spending a token: `--dry-run` with
`CURSOR_DELEGATE_DEBUG_PROMPT=1` renders the final *preamble + user prompt* into
the summary's "Final prompt preview" block.
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/cursor/lib/cursor.sh --dry-run security "src/auth.ts を見て"
```
