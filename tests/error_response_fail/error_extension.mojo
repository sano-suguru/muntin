# Must not compile on Mojo 1.1.0: an application module cannot give the
# stdlib `Error` (bare `raises`) the error trait with the undocumented
# `__extension`. Bare `raises` therefore has no explicit opt-in and stays
# the fixed 500. If this compiles, decide whether a conformance of `Error`
# (one response for every bare-`raises` error, by message only) is allowed.
# Expected diagnostic (checked by scripts/check.sh): 'Error' does not implement all requirements for 'ToErrorResponse'

from muntin import Response
from error_response_spike import ToErrorResponse


__extension Error(ToErrorResponse):
    def to_error_response(var self) -> Response:
        return Response.text("mapped", status=400)


def main():
    pass
