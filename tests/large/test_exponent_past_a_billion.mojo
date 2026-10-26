# A JSON number at the widest `Json[T, limit=n]` (M3-089) whose exponent
# passes 10^9, the cut `_to_float64` once made for a 1 MiB body. It builds a
# 10^9-digit literal, so it needs about 2 GB of memory: neither
# `./scripts/test.sh` without arguments nor CI runs it. Run it with
# `./scripts/test.sh tests/large/test_exponent_past_a_billion.mojo` when
# changing `_to_float64`'s exponent reading or `_LARGEST_LIMIT`. The normal
# suite's small cases are in tests/test_json.mojo's `test_number_limits`, and
# the compile-time assert beside `_EXPONENT_CAP` keeps the cap above the limit.

from std.memory import bitcast
from std.testing import assert_equal, TestSuite

from muntin.json import _to_float64


def _long_literal(zeros: Int, exponent: String) -> String:
    """`1`, `zeros` zeros, then `exponent`."""
    var b = List[UInt8](length=zeros + 1, fill=UInt8(0x30))
    b[0] = 0x31
    b.extend(Span(exponent.as_bytes()))
    return String(unsafe_from_utf8=b^)


def test_an_exponent_past_a_billion_reads_within_the_widest_limit() raises:
    # 1,000,000,014 bytes, within `limit=4_294_967_295`: 10^(10^9 - 10^10)
    # is 0.0. Read only up to 10^9, the exponent would be cancelled by the
    # digits and the result 1.0.
    var t = _long_literal(1_000_000_000, "e-10000000000")
    assert_equal(t.byte_length(), 1_000_000_014)
    assert_equal(bitcast[DType.uint64](_to_float64(t)), UInt64(0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
