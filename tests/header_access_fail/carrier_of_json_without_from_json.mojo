# Must not compile: `Json[T]` is a body only when `T: FromJson`, also
# inside the carrier, so the handler's signature is rejected where it is
# declared (docs/ARCHITECTURE.md, "Typed header access decision (M3-012)").
# Expected diagnostic (checked by scripts/check.sh): 'SpikeWithHeaders' parameter 'B' has 'FromBody' type

from muntin import Json

from header_access_spike import SpikeWithHeaders


@fieldwise_init
struct In(Movable):
    var name: String


def h(input: SpikeWithHeaders[Json[In]]) -> String:
    return ""


def main():
    pass
