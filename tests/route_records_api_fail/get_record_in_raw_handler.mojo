# Must not compile: a record in a raw handler (get). Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a raw get handler takes only the Request and returns Response
from muntin import App, Request, RouteValues


@fieldwise_init
struct OrgAt(RouteValues):
    var org_id: Int


def h(at: OrgAt, request: Request) -> String:
    return ""


def main():
    var app = App()
    app.get["/o/{org_id}"](h)
