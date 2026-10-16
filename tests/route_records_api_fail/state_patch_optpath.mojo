# Must not compile: an Optional field at a path placeholder, in the stateful
# form, before a body (patch). Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field 1 of the RouteValues record, org_id, is an Optional but binds the path parameter {org_id}; an Optional field binds a query parameter
from muntin import App, FromBody, RouteValues, State


@fieldwise_init
struct OptPath(RouteValues):
    var org_id: Optional[Int]


@fieldwise_init
struct Db(Movable):
    var n: Int


@fieldwise_init
struct Note(FromBody):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(db: State[Db], at: OptPath, body: Note) -> String:
    return ""


def main():
    var app = App()
    app.patch["/o/{org_id}"](h, State(Db(1)))
