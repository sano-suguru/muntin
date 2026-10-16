# Must not compile: a record in a WithHeaders, which carries a body (post).
# Decision: docs/history/architecture-decisions.md, "Route-value records
# decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): 'WithHeaders' parameter 'B' has '_FromBodyOrBytes' type, but value has type 'AnyStruct[OrgAt]'
from muntin import App, RouteValues, WithHeaders


@fieldwise_init
struct OrgAt(RouteValues):
    var org_id: Int


def h(input: WithHeaders[OrgAt]) -> String:
    return ""


def main():
    var app = App()
    app.post["/x"](h)
