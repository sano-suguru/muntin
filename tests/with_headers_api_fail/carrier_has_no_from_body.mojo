# Must not compile: `WithHeaders` is not a `FromBody`, so it has no `from_body`
# and a body alone cannot produce one with the fields silently missing. Building
# one by hand stays possible and takes an explicit `Headers` (M3-013;
# docs/history/architecture-decisions.md, "Typed header access decision
# (M3-012)").
# Expected diagnostic (checked by scripts/check.sh): 'WithHeaders[Note]' value has no attribute 'from_body'

from muntin import FromBody, Request, Response, WithHeaders


@fieldwise_init
struct Note(FromBody, Movable):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def raw(req: Request) raises -> Response:
    var n = WithHeaders[Note].from_body(req.body)
    return Response.text(n.body.text)


def main() raises:
    _ = raw(Request("POST", "/", "x"))
