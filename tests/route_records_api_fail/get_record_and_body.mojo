# Must not compile: a get handler with a record and a body (get). Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes no request body
from muntin import App, FromBody, RouteValues


@fieldwise_init
struct TaskAt(RouteValues):
    var org_id: Int
    var project_id: Int
    var task_id: Int


@fieldwise_init
struct Note(FromBody):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(at: TaskAt, body: Note) -> String:
    return ""


def main():
    var app = App()
    app.get["/o/{org_id}/p/{project_id}/t/{task_id}"](h)
