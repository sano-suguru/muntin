# Must not compile: a raw handler returning String on POST. The raw
# overload is not viable (Response only), so the call reaches the String
# body overload with B = Request, whose type-equality guard names the raw
# shape instead of reporting the FromBody constraint (M2-014).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: Request is the whole request, not a body; a raw handler takes only the Request and returns Response

from muntin import Request, Response
from raw_spike import RawApp


def h(req: Request) -> String:
    return req.path


def main():
    var app = RawApp()
    app.post["/hooks"](h)
