# Must not compile: moving the body field out of a carrier. Mojo 1.1.0
# does not move a field out of the middle of a value, so the carrier has
# `take_body(deinit self)`, as `Json` has `take` (docs/ARCHITECTURE.md,
# "Typed header access decision (M3-012)").
# Expected diagnostic (checked by scripts/check.sh): field 'input.body.text' destroyed out of the middle of a value

from muntin import FromBody

from header_access_spike import SpikeWithHeaders


@fieldwise_init
struct Note(FromBody, Movable):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(var input: SpikeWithHeaders[Note]) -> String:
    var b = input.body^
    return b.text


def main():
    pass
