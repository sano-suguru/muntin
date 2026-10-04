# Must not compile: a carrier inside a carrier. The carrier's body type
# must conform to `FromBody`, and a carrier does not, so the handler's
# signature is rejected where it is declared (docs/ARCHITECTURE.md,
# "Typed header access decision (M3-012)").
# Expected diagnostic (checked by scripts/check.sh): 'SpikeWithHeaders' parameter 'B' has 'FromBody' type, but value has type 'AnyStruct[SpikeWithHeaders[Note]]'

from muntin import FromBody

from header_access_spike import SpikeWithHeaders


@fieldwise_init
struct Note(FromBody, Movable):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def nested(input: SpikeWithHeaders[SpikeWithHeaders[Note]]) -> String:
    return ""


def main():
    pass
