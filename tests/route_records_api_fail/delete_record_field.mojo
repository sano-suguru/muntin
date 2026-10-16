# Must not compile: a field that is a record (delete). Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field 1 of the RouteValues record, org, is not a bare route value: a field is an Int, a String, an Optional of either or a FromRouteValue type, never a Param or a record
from muntin import App, RouteValues


@fieldwise_init
struct OrgAt(RouteValues):
    var org_id: Int


@fieldwise_init
struct RecordField(RouteValues):
    var org: OrgAt


def h(at: RecordField) -> String:
    return ""


def main():
    var app = App()
    app.delete["/o/{org}"](h)
