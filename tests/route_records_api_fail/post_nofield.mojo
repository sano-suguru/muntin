# Must not compile: a record with no field, before a body (post). Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the RouteValues record has no field; a record has one field per path or query parameter
from muntin import App, FromBody, RouteValues


struct Empty(RouteValues):
    def __init__(out self):
        pass


@fieldwise_init
struct Note(FromBody):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(at: Empty, body: Note) -> String:
    return ""


def main():
    var app = App()
    app.post["/x"](h)
