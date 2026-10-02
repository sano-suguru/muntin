# Must not compile: a route value and a Request on POST. Raw handlers take
# only the Request; the (Int, B) overload's guard names the raw shape.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: Request is the whole request, not a body; a raw handler takes only the Request and returns Response

from muntin import Request, Response
from raw_spike import RawApp


def h(id: Int, req: Request) -> Response:
    return Response.text(req.body)


def main():
    var app = RawApp()
    app.post["/hooks/{id}"](h)
