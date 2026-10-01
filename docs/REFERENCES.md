# Authoritative references

This file records upstream sources behind assumptions that may change. Re-check them when toolchain/model behavior matters to an implementation decision.

Last reviewed: 2026-10-01.

## Anthropic / Claude Code

- Claude Code commands, including `/goal`:
  https://code.claude.com/docs/zh-CN/commands
- Claude Code feature overview / `CLAUDE.md` and `.claude/rules/` guidance:
  https://code.claude.com/docs/id/features-overview
- Anthropic engineering: Effective harnesses for long-running agents:
  https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
- Anthropic engineering: Harness design for long-running application development:
  https://www.anthropic.com/engineering/harness-design-long-running-apps
- Prompting Claude Opus 5.5:
  https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5-5
- Prompting Claude Sonnet 5.5:
  https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-sonnet-5-5
- Claude effort guidance:
  https://platform.claude.com/docs/en/build-with-claude/effort
- General prompting best practices:
  https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices

## Mojo

- Function syntax (`def`; `fn` deprecation):
  https://docs.modular.com/mojo/manual/functions/
- Compile-time parameterization:
  https://docs.modular.com/mojo/manual/parameters/
- Structs and `@fieldwise_init`:
  https://docs.modular.com/mojo/manual/structs/
- Error handling and current typed-error constraints:
  https://docs.modular.com/mojo/manual/errors/
- Changelog / reflection and language evolution:
  https://docs.modular.com/mojo/changelog

Important policy: examples in `docs/DX.md` are targets until compiled against the supported toolchain. Do not infer that a conceptually plausible Mojo syntax is supported merely because it resembles another language.

## Flare

- Flare repository:
  https://github.com/ehsanmok/flare

As reviewed, Flare describes itself as a full Mojo networking stack with HTTP/1.1, HTTP/2, HTTP/3/QUIC, WebSocket, TLS and other networking facilities, and provides its own Router/Request/Response/Handler abstractions. This is precisely why Muntin treats it as a backend rather than adopting those types as Muntin's public application contract.

When M1 begins, pin a released tag and verify its current license, supported Mojo version, package instructions, and adapter-relevant API from the repository at that time.

Pinned (M1-001, checked 2026-10-01): release `v0.11.0` (tag object `50fac2b6`, commit `59bda50f46853f7351eef12f1737f7fb2287de71`), MIT license. Its `pixi.toml` and `recipe.yaml` declare `mojo >=1.1.0,<2.0.0`; it is installed as a pixi-build git source dependency as its README describes. The GitHub release is not marked immutable, so `pixi.lock`'s commit hash is the reproducible reference.
- Release notes: https://github.com/ehsanmok/flare/releases/tag/v0.11.0
