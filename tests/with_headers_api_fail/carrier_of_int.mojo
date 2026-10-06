# Must not compile: `Int` is a route-value type, never a body, also inside the
# carrier: the body type of `WithHeaders` must conform to `FromBody` (M3-013;
# docs/history/architecture-decisions.md, "Typed header access decision
# (M3-012)").
# Expected diagnostic (checked by scripts/check.sh): 'WithHeaders' parameter 'B' has 'FromBody' type, but value has type 'AnyStruct[Int]'

from muntin import WithHeaders


def h(input: WithHeaders[Int]) -> String:
    return ""


def main():
    pass
