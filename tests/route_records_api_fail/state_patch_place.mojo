# Must not compile: a record after a bare route value, in the stateful form,
# before a body (patch). Decision: docs/history/architecture-decisions.md,
# "Route-value records decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a handler takes at most one RouteValues record, as its first parameter after any State
from muntin import App, FromBody, RouteValues, State


@fieldwise_init
struct ProjectAt(RouteValues):
    var project_id: Int


@fieldwise_init
struct Db(Movable):
    var n: Int


@fieldwise_init
struct Note(FromBody):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(db: State[Db], org_id: Int, at: ProjectAt, body: Note) -> String:
    return ""


def main():
    var app = App()
    app.patch["/o/{org_id}/p/{project_id}"](h, State(Db(1)))
