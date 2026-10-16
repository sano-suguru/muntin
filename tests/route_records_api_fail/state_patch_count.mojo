# Must not compile: more fields than placeholders, in the stateful form,
# before a body (patch). Decision: docs/history/architecture-decisions.md,
# "Route-value records decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the RouteValues record has 3 fields but the route declares 2 path and query parameters; a record has one field per parameter
from muntin import App, FromBody, RouteValues, State


@fieldwise_init
struct TaskAt(RouteValues):
    var org_id: Int
    var project_id: Int
    var task_id: Int


@fieldwise_init
struct Db(Movable):
    var n: Int


@fieldwise_init
struct Note(FromBody):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(db: State[Db], at: TaskAt, body: Note) -> String:
    return ""


def main():
    var app = App()
    app.patch["/o/{org_id}/p/{project_id}"](h, State(Db(1)))
