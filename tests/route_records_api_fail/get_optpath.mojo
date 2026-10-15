# Must not compile: an Optional field at a path placeholder (get). Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field 1 of the RouteValues record, org_id, is an Optional but binds the path parameter {org_id}; an Optional field binds a query parameter
from muntin import App, RouteValues


@fieldwise_init
struct OptPath(RouteValues):
    var org_id: Optional[Int]


def h(at: OptPath) -> String:
    return ""


def main():
    var app = App()
    app.get["/o/{org_id}"](h)
