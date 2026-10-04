# Must not compile: the carrier is not a `FromBody`, so it has no
# `from_body` and a body alone cannot produce one with the fields silently
# missing. Building one by hand stays possible and takes an explicit
# `Headers` (docs/ARCHITECTURE.md, "Typed header access decision
# (M3-012)").
# Expected diagnostic (checked by scripts/check.sh): 'SpikeWithHeaders[Note]' value has no attribute 'from_body'

from muntin import FromBody, Request, Response

from header_access_spike import SpikeWithHeaders


@fieldwise_init
struct Note(FromBody, Movable):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def raw(req: Request) raises -> Response:
    var n = SpikeWithHeaders[Note].from_body(req.body)
    return Response.text(n.body.text)


def main() raises:
    _ = raw(Request("POST", "/", "x"))
