# Orchestrate Protocol — Detailed Reference

Full execution protocol, capability map, examples, and anti-patterns for
the `/cursor orchestrate` Claude-internal delegation protocol.

For the core delegation criteria (D1–D5) and blockers (B1–B6), see SKILL.md.

## Cursor's strengths (prefer delegation for these)

- **Parallel code review** of independent files — Cursor reads the full file
  with its own context window, often catching different issues than Claude
- **Security audit** — focused, file-scoped, self-contained by nature
- **Investigation** of isolated subsystems — "explain how X works"
- **Implementation** of well-specified, bounded changes — isolated worktree
  makes it safe
- **Plan generation** for scoped features — Cursor can draft a plan that Claude
  then reviews

## Cursor's weaknesses (keep these for Claude)

- No conversation memory — can't reference "what we discussed earlier"
- No tool access — can't search the web, call MCP, run git, spawn agents
- No cross-task coordination — each job is independent
- Shallow on architecture — follows instructions rather than making design
  trade-offs
- Single-shot — can't iterate based on feedback (use `resume` for multi-turn)

## Execution protocol

```
Step 1: Decompose
  Claude analyzes the user's request → list of sub-tasks

Step 2: Classify
  For each sub-task, apply D1–D5 and B1–B6
  → cursor_tasks: list of (task_type, prompt, target_files)
  → claude_tasks: list of tasks Claude handles directly

Step 3: Present split (if non-obvious or first time)
  "Cursor に移譲: review src/auth.ts, security src/api.ts
   Claude で実行: アーキテクチャ判断, git 操作"

Step 4: Execute in parallel
  - cursor_tasks → /cursor fanout <task1>:<prompt1> <task2>:<prompt2> ...
  - claude_tasks → Claude handles directly (can overlap with Cursor fanout)

Step 5: Integrate
  - Read fanout synthesis
  - Combine with Claude's own results
  - Present unified answer to user
```

## Examples

**Good orchestration:**
```
User: "src/auth.ts と src/payment.ts をそれぞれレビューして、
       あとこのブランチの全体的なアーキテクチャ評価もして"

Split:
  → Cursor: review:src/auth.ts  review:src/payment.ts    (D1-D5 ✓)
  → Claude: architecture evaluation                       (B6: design judgment)
```

**Good orchestration (implement + review):**
```
User: "healthz エンドポイント追加して、既存の auth.ts もセキュリティレビューして"

Split:
  → Cursor: implement:"add /healthz endpoint with 200 OK json"  (isolated worktree)
            security:src/auth.ts                                  (read-only)
  → Claude: diff review of implement result after Cursor finishes
```

**NOT orchestrated (keep all for Claude):**
```
User: "さっき議論した認証フローのリファクタリングをして"

All Claude — B1 (conversation context required) + B2 (cross-file refactoring)
```

**NOT orchestrated (single focused task):**
```
User: "src/auth.ts をレビューして"

Single task — no decomposition benefit. Direct: /cursor review "src/auth.ts"
```

## Anti-patterns

- **Don't split what's naturally one task.** If the user asks to review one
  file, send it to Cursor directly. Orchestrate adds value only when there are
  2+ independent pieces.
- **Don't delegate the judgment call.** Cursor executes; Claude decides what
  to do with results. Never delegate "decide whether we should refactor" to
  Cursor.
- **Don't chain Cursor tasks.** If task B needs task A's output, keep B for
  Claude (or run A first, then B in a second fanout round).
- **Don't over-orchestrate.** If the total work is small (< 2 min for Claude),
  just do it. Orchestration overhead (fanout setup, synthesis, context switch)
  isn't free.
