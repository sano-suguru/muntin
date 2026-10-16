# Must not compile: a stateful `post` handler taking a record and a body,
# registered without its state, so its `State` sits in a request slot; the
# State message, not the record's place, names the fault. Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: State is injected application state, not the request body; a stateful post handler takes State first and the body last, and the state is the registration's second argument
from muntin import App, FromBody, RouteValues, State


@fieldwise_init
struct ProjectAt(RouteValues):
    var org_id: Int
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


def h(db: State[Db], at: ProjectAt, body: Note) -> String:
    return ""


def main():
    var app = App()
    app.post["/o/{org_id}/p/{project_id}"](h)
