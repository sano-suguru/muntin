# Must not compile: a carrier handler registered on `get`. `get` takes no body,
# so get's one-slot overload reports it; a `get` route that needs header fields
# uses the raw `get` (M3-013, M3-015; docs/history/architecture-decisions.md,
# "Typed header access decision (M3-012)").
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes no request body

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
