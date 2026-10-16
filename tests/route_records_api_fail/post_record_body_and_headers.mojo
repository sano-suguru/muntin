# Must not compile: a record, a body and Headers together (WithHeaders
# carries both) (post). Decision: docs/history/architecture-decisions.md,
# "Route-value records decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a post handler takes one request body, as its last parameter
from muntin import App, FromBody, Headers, RouteValues


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


def h(at: TaskAt, body: Note, headers: Headers) -> String:
    return ""


def main():
    var app = App()
    app.post["/o/{org_id}/p/{project_id}/t/{task_id}"](h)
