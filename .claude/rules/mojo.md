---
paths:
  - "**/*.mojo"
---

# Mojo code rules

- Use current stable Mojo syntax. Prefer `def`; do not introduce deprecated `fn` except in a minimal compatibility/reproduction test that documents why it is unavoidable.
- Verify uncertain language behavior with the installed toolchain rather than relying on remembered syntax.
- Treat compile-time metaprogramming as a means, not the product. It must buy user-visible correctness, diagnostics, simplicity, or measured runtime value.
- Make ownership, movement, copying, and lifetime decisions explicit when they affect correctness. Do not hide backend lifetime assumptions inside public types.
- Prefer simple concrete code for M0. Introduce generic traits/parameterization only when a current acceptance criterion needs them.
- Keep third-party backend imports out of Muntin core/public modules.
- When a `docs/DX.md` target cannot compile, create a minimal reproduction and record the actual compiler limitation before changing the public design.
