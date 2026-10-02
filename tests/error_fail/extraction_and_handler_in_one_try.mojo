# Must not compile: an adapter that converts the route value and calls a
# handler with an inferred error type `E` inside one `try` (M2-010).
# `_parse_int` raises `Error`, the handler raises `E`, and a `try` block
# has one error type, so Mojo 1.1.0 rejects the mix. The request-side
# catch (400) and the handler catch (500) cannot be merged by accident.
# Expected diagnostic (checked by scripts/check.sh): cannot call function that may raise 'E' in context that supports an error type of 'Error'

from muntin import Response
from muntin.app import _parse_int


def call_int[
    E: Deinitable, //
](handler: def(Int) thin raises E -> String, arg: String) -> Response:
    try:
        return Response.text(handler(_parse_int(arg)))
    except:
        return Response.text("Bad Request", status=400)


def get_name(id: Int) -> String:
    return String(id)


def main():
    _ = call_int(get_name, "42")
