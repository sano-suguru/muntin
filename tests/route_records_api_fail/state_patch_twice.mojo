# Must not compile: a placeholder named twice, in the stateful form, before a
# body (patch). Decision: docs/history/architecture-decisions.md,
# "Route-value records decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the route declares the parameter {id} twice; a RouteValues record binds each parameter to the field of its name
from muntin import App, FromBody, RouteValues, State


@fieldwise_init
struct Twice(RouteValues):
    var id: Int
    var other: Int


@fieldwise_init
struct Db(Movable):
    var n: Int


@fieldwise_init
struct Note(FromBody):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(db: State[Db], at: Twice, body: Note) -> String:
    return ""


def main():
    var app = App()
    app.patch["/a/{id}/b/{id}"](h, State(Db(1)))
