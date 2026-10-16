# Must not compile: a record that is also a FromBytes, as the body (put).
# Decision: docs/history/architecture-decisions.md, "Route-value records
# decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a parameter's type conforms to RouteValues and to FromRouteValue, FromBody or FromBytes; a route-value record is none of them
from muntin import App, FromBytes, RouteValues


@fieldwise_init
struct OrgBytes(FromBytes, RouteValues):
    comptime max_bytes = 8
    var org_id: Int

    @staticmethod
    def from_bytes(bytes: List[UInt8]) raises -> Self:
        return Self(len(bytes))


def h(body: OrgBytes) -> String:
    return ""


def main():
    var app = App()
    app.put["/x"](h)
