# Must not compile: a carrier handler registered on `get`. `get` has no
# body slot, so no `get` overload takes `WithHeaders[B]`; a `get` route
# that needs header fields uses the raw `get` (M3-013; docs/ARCHITECTURE.md,
# "Typed header access decision (M3-012)").
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def read_note(input: WithHeaders[Note]) thin -> String' to 'def() raises Never thin -> String'

from muntin import App, FromBody, WithHeaders


@fieldwise_init
struct Note(FromBody, Movable):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def read_note(input: WithHeaders[Note]) -> String:
    return input.body.text


def main():
    var app = App()
    app.get["/notes"](read_note)
