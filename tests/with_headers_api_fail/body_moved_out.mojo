# Must not compile: moving the body field out of a carrier. Mojo 1.1.0 does not
# move a field out of the middle of a value, so `WithHeaders` has
# `take_body(deinit self)`, as `Json` has `take` (M3-013;
# docs/history/architecture-decisions.md, "Typed header access decision
# (M3-012)").
# Expected diagnostic (checked by scripts/check.sh): field 'input.body.text' destroyed out of the middle of a value

from muntin import FromBody, WithHeaders


@fieldwise_init
struct Note(FromBody, Movable):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(var input: WithHeaders[Note]) -> String:
    var b = input.body^
    return b.text


def main():
    pass
