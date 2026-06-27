# cursor skill — maintainer reference

Test harness, CI invocation, manual-QA checklist, and the v1 "done" definition.
This is **maintainer-facing** documentation — it is not needed to *run* a
delegation at conversation time, so it lives here instead of in `SKILL.md`
(which stays focused on what Claude needs while performing a task).

## Testing

### Quick check (no network, always safe)

```bash
bash tests/run.sh unit
```

Unit tests use a stub `agent` binary — no `CURSOR_API_KEY` needed. All
non-skipped tests should pass in < 5 seconds. Tests requiring `jq` are skipped
with `exit 77` if `jq` is not installed (all others still run).

### Integration tests (live Cursor CLI, needs CURSOR_API_KEY)

```bash
CURSOR_API_KEY=<your-key> bash tests/run.sh integration
```

Runs one test per task type plus config-override and resume tests. Each test
is gated: missing key → `SKIP (no CURSOR_API_KEY)` with `exit 77`.

### Full suite

```bash
bash tests/run.sh all           # unit + integration
NO_COLOR=1 bash tests/run.sh unit  # CI-friendly (no ANSI codes)
VERBOSE=1  bash tests/run.sh unit  # show per-assertion lines on PASS
```

### Manual QA (human-verified, AC2 / AC3 / AC7)

See **`tests/manual-qa.md`** for the 5 items that require a live Claude Code
session or real `~/.cursor/hooks.json`:

| Check | AC/Risk |
|-------|---------|
| MQ-1: Claude-driven fanout wall-clock | AC2 |
| MQ-2: Resume context preservation | AC3 |
| MQ-3: Cross-session Skill() invocation | AC7 |
| MQ-4: Hooks quarantine live round-trip | R2 |
| MQ-5: Local-parallel auto-detect flip | AC2 / R4 |

## Branch model & publishing to `main`

`develop` is the source of truth and holds **everything** (tests, dev docs,
tooling). `main` is the **distribution branch** users install from
(`/plugin marketplace add HiroFumiko/cursor-delegate-skills`) and must stay
clean — no tests, no maintainer-only files.

`.gitignore` cannot do this: it only affects *untracked* files, so a file once
committed on `develop` cannot be auto-ignored on `main`. Instead, `main` is
**regenerated as a snapshot** of `develop` minus an explicit exclude list:

```bash
scripts/publish-main.sh            # rebuild main locally from develop
scripts/publish-main.sh --push     # ...and push main to origin
```

The script loads `develop`'s committed tree into a throwaway index, strips the
excluded paths, and commits the result onto `main` — your working tree is never
touched, and there are no merge conflicts to resolve.

**Excluded from `main`** (edit the `EXCLUDES` array in `scripts/publish-main.sh`
to change): `…/tests/**`, `…/TODO.md`, this `maintainers.md`, and `scripts/`
itself.

Typical release flow:

```bash
git switch develop && git push origin develop   # land work on develop first
scripts/publish-main.sh --push                   # publish a clean main snapshot
```

> Note: the script reads the **committed** tree of `develop`, so commit your
> changes before publishing — uncommitted edits are not included.

## Plan-done definition (v1.0.0)

The skill is considered **done** when:

1. `bash tests/run.sh unit` — all non-skipped tests pass.
2. `bash tests/run.sh integration` — all non-skipped tests pass (in an env
   with `CURSOR_API_KEY`).
3. All 5 items in `tests/manual-qa.md` are checked off with recorded
   observations.
