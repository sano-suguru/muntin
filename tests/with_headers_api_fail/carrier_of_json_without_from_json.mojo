# Must not compile: `Json[T]` is a body only when `T: FromJson`, also
# inside the carrier, so the handler's signature is rejected where it is
# declared (M3-013; docs/ARCHITECTURE.md, "Typed header access decision
# (M3-012)").
# Expected diagnostic (checked by scripts/check.sh): 'WithHeaders' parameter 'B' has 'FromBody' type, but value has type 'AnyStruct[Json[In]]'

from muntin import Json, WithHeaders


@fieldwise_init
struct In(Movable):
    var name: String


def h(input: WithHeaders[Json[In]]) -> String:
    return ""


def main():
    pass
