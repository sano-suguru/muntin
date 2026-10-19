#!/usr/bin/env python3
"""Checks that `JsonValue.float()` reads JSON number literals as Python's
`float()` does: the value rounded to the nearest double, ties to even, or
`raise` where Python gives infinity (M3-078).

It writes a corpus of literals, builds tests/json_float_oracle/driver.mojo,
runs it on the corpus and compares its bits with Python's. The corpus:

  - for every binary exponent of a double, subnormals included, a random
    double and its neighbour, and the exact decimal halfway between them
    (up to 768 significant digits), the literal one unit below it in its
    last digit, and the halfway point followed past the 800th significant
    digit by a nonzero one;
  - fixed edges: the halfway points at both ends of the range, 2^-1075, the
    subnormal/normal boundary, signed zeros, exponents past the range;
  - random doubles as Python prints them (shortest, %.17g, %.16e), random
    16-60 digit integers and random long decimals.

Every literal is valid JSON. Deterministic for a seed; check.sh runs the
default. Usage:

    python3 -I scripts/check_json_float.py [--seed N] [--random N] [--binades N]

--random sets the count of each random kind (default 600) and --binades how
many random doubles per binary exponent (default 1). Exits nonzero on any
mismatch, printing the first few. Needs pixi with Mojo; Python standard
library only.
"""

import argparse
import random
import struct
import subprocess
import sys
import tempfile
from decimal import Decimal, getcontext
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DRIVER = ROOT / "tests" / "json_float_oracle" / "driver.mojo"
KEPT = 800  # src/muntin/json.mojo, _MAX_DIGITS

getcontext().prec = 2000


def bits_of(x: float) -> int:
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def double(b: int) -> float:
    return struct.unpack("<d", struct.pack("<Q", b))[0]


def expected(literal: str) -> str:
    x = float(literal)
    if x in (float("inf"), float("-inf")):
        return "raise"
    return hex(bits_of(x))


def exact(d: Decimal) -> str:
    """`d` as a JSON literal with every significant digit."""
    if d == 0:
        return "0"
    text = format(d, "e")  # exact for a Decimal: d.ddd...e+N
    mantissa, exponent = text.split("e")
    return mantissa + "e" + exponent


def significand_digits(literal: str) -> int:
    mantissa = literal.split("e")[0].lstrip("-")
    return len(mantissa.replace(".", "").lstrip("0"))


def around_halfway(lo_bits: int, rng: random.Random) -> list[str]:
    """The halfway point between the double `lo_bits` and the next one up,
    one unit below it, and it with a nonzero digit past the 800th."""
    lo, hi = double(lo_bits), double(lo_bits + 1)
    if hi == float("inf"):
        hi_exact = Decimal(2) ** 1024
    else:
        hi_exact = Decimal(hi)
    mid = ((Decimal(lo) + hi_exact) / 2).normalize()
    last = Decimal((0, (1,), mid.as_tuple().exponent))  # one unit of its last digit
    sign = "-" if rng.random() < 0.5 else ""
    m = exact(mid)
    mantissa, exponent = m.split("e")
    if "." not in mantissa:
        mantissa += "."
    pad = "0" * max(KEPT + 5 - significand_digits(m), 1)
    return [
        sign + m,
        sign + exact(mid - last),
        sign + mantissa + pad + "1e" + exponent,
    ]


def corpus(seed: int, per_binade: int, randoms: int) -> list[str]:
    rng = random.Random(seed)
    out: list[str] = []
    # Halfway points in every binade: biased exponent 0 (subnormal) to 2046.
    for biased in range(0, 2047):
        for _ in range(per_binade):
            mantissa = rng.randrange(0, 1 << 52)
            b = (biased << 52) | mantissa
            if b == 0:
                b = 1
            out += around_halfway(b, rng)
    # Fixed edges.
    largest_subnormal = (1 << 52) - 1
    out += around_halfway(largest_subnormal, rng)  # to the smallest normal
    out += around_halfway((1 << 52) - 2, rng)  # ties down, to an even subnormal
    out += around_halfway(0x7FEFFFFFFFFFFFFF, rng)  # past it: infinity
    out += around_halfway(0x7FEFFFFFFFFFFFFE, rng)
    out += around_halfway(0, rng)  # 2^-1075: zero and the smallest subnormal
    out += [
        "0", "-0", "0.0", "-0.0e5", "0e999999999999", "1e-400", "-1e-400",
        "1e400", "-1e400", "1E5", "1e+5", "1e-5", "5e-324", "2.5e-324",
        "1.7976931348623157e308", "1.7976931348623158e308",
        "1.7976931348623159e308", "2.2250738585072011e-308",
        "2.2250738585072014e-308", "9007199254740993", "123456789012345678",
        "0." + "0" * 5000 + "1", "1" + "0" * 309, "1" + "0" * 308,
        "0." + "0" * 323 + "25", "3" * 2000, "0." + "3" * 2000,
        "0.00000000000000000000000000000000000001e350",
    ]
    # Random doubles as clients print them.
    for _ in range(randoms):
        while True:
            x = double(rng.getrandbits(64))
            if x == x and x not in (float("inf"), float("-inf")):
                break
        out += [repr(x), "%.17g" % x, "%.16e" % x]
    for _ in range(randoms):
        out.append(str(rng.randrange(10**15, 10**60)))
    for _ in range(randoms):
        digits = "".join(rng.choice("0123456789") for _ in range(rng.randrange(20, 900)))
        point = rng.randrange(1, len(digits))
        literal = digits[:point].lstrip("0") or "0"
        literal += "." + digits[point:] + "e" + str(rng.randrange(-700, 330))
        out.append(literal)
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=78)
    parser.add_argument("--random", type=int, default=600)
    parser.add_argument("--binades", type=int, default=1)
    args = parser.parse_args()

    literals = corpus(args.seed, args.binades, args.random)
    want = [expected(s) for s in literals]
    with tempfile.TemporaryDirectory() as tmp:
        corpus_path = Path(tmp) / "corpus.txt"
        corpus_path.write_text("\n".join(literals) + "\n")
        driver = Path(tmp) / "driver"
        build = subprocess.run(
            ["pixi", "run", "--frozen", "mojo", "build", "--Werror", "-I", "src",
             str(DRIVER), "-o", str(driver)],
            cwd=ROOT, capture_output=True, text=True,
        )
        if build.returncode != 0:
            sys.stderr.write(build.stdout + build.stderr)
            print("error: tests/json_float_oracle/driver.mojo failed to build", file=sys.stderr)
            return 1
        run = subprocess.run([str(driver), str(corpus_path)], capture_output=True, text=True)
        if run.returncode != 0:
            sys.stderr.write(run.stdout[-2000:] + run.stderr)
            print("error: the driver failed", file=sys.stderr)
            return 1
    got = run.stdout.splitlines()
    if len(got) != len(want):
        print(f"error: {len(literals)} literals, {len(got)} answers", file=sys.stderr)
        return 1
    bad = [(s, w, g) for s, w, g in zip(literals, want, got) if w != g]
    for s, w, g in bad[:10]:
        shown = s if len(s) <= 80 else s[:40] + "..." + s[-30:]
        print(f"error: {shown}: Python {w}, float() {g}", file=sys.stderr)
    if bad:
        print(f"error: {len(bad)} of {len(literals)} literals differ (seed {args.seed})", file=sys.stderr)
        return 1
    print(f"ok: {len(literals)} literals read as Python reads them (seed {args.seed})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
