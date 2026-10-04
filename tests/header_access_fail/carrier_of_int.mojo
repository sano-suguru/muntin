# Must not compile: `Int` is a route-value type, never a body, also inside
# the carrier: its body type must conform to `FromBody`
# (docs/ARCHITECTURE.md, "Typed header access decision (M3-012)").
# Expected diagnostic (checked by scripts/check.sh): 'SpikeWithHeaders' parameter 'B' has 'FromBody' type, but value has type 'AnyStruct[Int]'

from header_access_spike import SpikeWithHeaders


def h(input: SpikeWithHeaders[Int]) -> String:
    return ""


def main():
    pass
