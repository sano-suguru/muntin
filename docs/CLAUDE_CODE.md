# Claude Code workflow for Muntin

This document describes how to drive Muntin development with Claude Code while keeping the repository, not the chat transcript, as the durable source of state.

## `/goal` is a completion condition

Claude Code's `/goal [condition]` continues work across turns until a goal condition is met. Use it to state **what must be demonstrably true when the run ends**, not to duplicate the entire product specification.

Detailed requirements live in repository files. A good Muntin `/goal` names the milestone, points to those files, defines executable success checks, names architectural prohibitions that must not be violated, and requires evidence in the final turn.

Ready-to-paste conditions are in `docs/GOALS.md`.

## Repository state beats conversational memory

The durable loop uses distinct artifacts:

```text
AGENTS.md
  always-on project rules (CLAUDE.md imports it with @AGENTS.md)

docs/DX.md
  desired public API and ergonomics

docs/ARCHITECTURE.md
  invariants, dependency boundaries, current architecture, decision index

docs/history/
  decision records and earlier progress (read through the indexes)

docs/SPEC.md
  milestone scope and acceptance

feature_list.json
  machine-readable pass/fail state

AGENT_PROGRESS.md
  concise cross-session handoff
```

Keep `AGENTS.md` short. Put detailed reference material in `docs/` or path-specific `.claude/rules/` so every session is not burdened with the whole design history.

## Feature-list discipline

`feature_list.json` is deliberately JSON rather than prose. Coding agents may change a feature's `passes` field and append concrete evidence after verification. They must not casually rewrite descriptions or acceptance criteria to fit implementation.

Work on one coherent failing feature at a time. This reduces the chance of a broad half-finished rewrite and makes handoffs recoverable.

## Verification instruction

For executable code changes, require a real build/test/type-check or changed command before completion. A syntax-only check or a command that never successfully starts is not proof.

Muntin reinforces this in `AGENTS.md`, `docs/DEVELOPMENT.md`, `/goal`, and the JSON acceptance list so completion does not depend on the agent deciding that its own output looks correct.

## Independent evaluation

For ordinary bounded tasks, one capable agent plus real tests may be enough. For work near the capability boundary—public API, lifetime design, unsafe code, backend abstraction, broad refactors—use a fresh-context skeptical reviewer after implementation.

The reviewer should grade concrete criteria and inspect executable evidence rather than merely praising the implementation.

Do not add multi-agent complexity by default. Add it only when the work benefits from independent judgment.

## Model and effort guidance

Treat model/effort choice as an empirical knob, not a permanent project rule.

### Claude Opus 5.5

Use Opus 5.5 for the hardest architecture work, long-horizon autonomous changes, difficult debugging, and independent review where mistakes are expensive. Anthropic positions it for long-running agentic coding and recommends starting at `medium` effort, then increasing only where evaluation shows a quality benefit.

For Muntin, a sensible default is Opus 5.5 `medium` for M0 architecture formation, backend-seam changes, ownership/lifetime decisions, and hard cross-cutting refactors. Move to `high`/`xhigh` only when the task actually benefits.

### Claude Sonnet 5.5

Use Sonnet 5.5 for well-specified coding increments once architecture and acceptance criteria are clear. Anthropic recommends `medium` effort for well-specified agentic coding/multistep tool use and `high` for harder or longer work. For the hardest long-horizon work, prefer an Opus model.

For Muntin, Sonnet 5.5 `medium` is a good fit for focused features with strong tests; use `high` when the increment is harder, longer, or repeatedly fails verification.

### Do not optimize the harness for one model forever

Model behavior changes. Re-evaluate scaffolding as models improve. Keep the harness as simple as possible while preserving measurable reliability.

## Recommended M0 session

1. Start from a clean local repository state.
2. Select Opus 5.5 at medium effort for the first architecture/bootstrap run.
3. Read the repository docs rather than pasting them into chat.
4. Set the M0 condition from `docs/GOALS.md` using `/goal`.
5. Let Claude work until the completion condition is actually verified.
6. Inspect the diff and test output.
7. Run a fresh-context architecture/public-API review before accepting a substantial M0 seam change.
8. Commit only the verified coherent increment.

Once the public/core shape stabilizes, smaller features can move to Sonnet 5.5 medium with the same repository-level oracles.

## Avoid these prompt patterns

Do not ask the model to "build the entire framework" without milestone boundaries. Do not make a long chat prompt the only copy of requirements. Do not ask for hidden reasoning or chain-of-thought. Do not treat a text summary or `end_turn` as completion evidence. Do not tell the agent to minimize tool calls when up-to-date verification is important.

The goal is not maximal autonomy. The goal is a loop that keeps producing auditable, verified increments.
