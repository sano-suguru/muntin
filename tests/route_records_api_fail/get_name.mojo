# Must not compile: fields in the other order than the placeholders (get).
# Decision: docs/history/architecture-decisions.md, "Route-value records
# decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field 1 of the RouteValues record is project_id but binds {org_id}; route values bind the path parameters left to right, then the query parameters
from muntin import App, RouteValues


@fieldwise_init
struct Swapped(RouteValues):
    var project_id: Int
    var org_id: Int
    var task_id: Int


def h(at: Swapped) -> String:
    return ""


def main():
    var app = App()
    app.get["/o/{org_id}/p/{project_id}/t/{task_id}"](h)
