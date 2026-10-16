# Must not compile: a WithHeaders around a record that is also a FromBody
# (post). Decision: docs/history/architecture-decisions.md, "Route-value
# records decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a parameter's type conforms to RouteValues and to FromRouteValue, FromBody or FromBytes; a route-value record is none of them
from muntin import App, FromBody, RouteValues, WithHeaders


@fieldwise_init
struct OrgBody(FromBody, RouteValues):
    var org_id: Int

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(Int(body))


def h(input: WithHeaders[OrgBody]) -> String:
    return ""


def main():
    var app = App()
    app.post["/x"](h)
