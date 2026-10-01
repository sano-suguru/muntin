---
paths:
  - "src/**/*.mojo"
  - "muntin/**/*.mojo"
  - "examples/**/*.mojo"
  - "tests/**/*.mojo"
---

# Public API guardrails

When adding or changing application-facing APIs:

- Read `docs/DX.md` and `docs/ARCHITECTURE.md` first.
- Optimize ordinary application code, not adapter implementation convenience.
- Do not expose Flare or any backend-specific Request, Response, Router, Handler, middleware, cancellation, reactor, or lifecycle type.
- Keep raw Muntin `Request -> Response` handling available as an escape hatch even when high-level typed handlers exist.
- Avoid adding public abstractions for hypothetical future needs.
- Add/adjust an executable canonical example or test for every public behavior that becomes a compatibility promise.
- If changing the canonical syntax due to a Mojo limitation, attach a minimal compiler reproduction/evidence and update `docs/DX.md` deliberately.
