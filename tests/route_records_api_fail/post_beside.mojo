# Must not compile: a bare route value after a record, before a body (post).
# Decision: docs/history/architecture-decisions.md, "Route-value records
# decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a handler that takes a RouteValues record takes no other route value; the record has a field for each
from muntin import App, FromBody, RouteValues


@fieldwise_init
struct OrgAt(RouteValues):
    var org_id: Int


@fieldwise_init
struct Note(FromBody):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(at: OrgAt, project_id: Int, body: Note) -> String:
    return ""


def main():
    var app = App()
    app.post["/o/{org_id}/p/{project_id}"](h)
