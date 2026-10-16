# Must not compile: more fields than placeholders (get). Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the RouteValues record has 3 fields but the route declares 2 path and query parameters; a record has one field per parameter
from muntin import App, RouteValues


@fieldwise_init
struct TaskAt(RouteValues):
    var org_id: Int
    var project_id: Int
    var task_id: Int


def h(at: TaskAt) -> String:
    return ""


def main():
    var app = App()
    app.get["/o/{org_id}/p/{project_id}"](h)
