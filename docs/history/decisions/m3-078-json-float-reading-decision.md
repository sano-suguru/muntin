# JSON float reading decision (M3-078)

> **Current.** Now described in [bodies reference, "JSON (`Json[T]`)"](../../reference/bodies.md#json-jsont) and [ARCHITECTURE, "JSON"](../../ARCHITECTURE.md#json).

Status: **decision and production** (M3-078; its pull request holds the comparison against Python and the cost measurements). It changes part of [M3-008](m3-008-json-codec-decision.md), which read floats through Mojo 1.1.0's `atof`.

**Question and what settles it.** `JsonValue.float()` went through `atof`, which is not correctly rounded (`123456789012345678` and shortest-repr doubles such as `-2.7546748226290886e+20` came back 1 ulp off, silently) and raises on long valid literals (`123456789012345678901234`, 400). M3-008 accepted these as toolchain limits; a review counted the silent error as a correctness defect, not a limit to document. Settled by every literal reading as the nearest double, ties to even, with no signature change and no unsafe code: Python's `float()` as the oracle on random doubles, long integers, exact and near halfway points, subnormals and both ends of the range.

**Choice: Muntin converts the literal itself, in `json.mojo`.** Clinger's fast path when the significand is at most 2^53 and the power of ten at most 22 (one correctly rounded operation); otherwise exact whole-number arithmetic on the first 800 significant digits, plus whether a nonzero digit follows them (a halfway point has at most 767), with the leading 64 bits of the quotient estimated in 128 bits and corrected exactly. The double is built by multiplying by exact powers of two, since `bitcast` is confined to the storage module and `ldexp` is wrong for subnormals on Mojo 1.1.0. Overflow still raises (400); underflow is a signed zero.

**Rejected.**
- Keeping `atof` and documenting the gap: a silent wrong value in shipped code.
- Eisel–Lemire: faster on 17–19 digits, but needs a table of 128-bit powers of five and still a slow path for ties.
- Bit-by-bit long division: correct, but 10–15 µs for exponents near the ends of the range, against about 2 µs here.

**Revisit when:**
- Mojo's `atof` becomes correctly rounded and accepts long literals: compare cost, and drop the converter if `atof` is no slower.
- The writer: `String(Float64)` still prints some doubles as text that reads back as a neighbour (`test_float_writer_gap_on_mojo_1_1_0`); that stays M3-008's revisit condition.

**Next production slice:** none; this pull request is the production.
