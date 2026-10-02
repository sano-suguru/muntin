# Must not compile on Mojo 1.1.0: the undocumented `__extension` cannot
# add a trait to a type from another module (the same diagnostic holds for
# an application struct). So the stdlib `Error` (bare `raises`) has no
# explicit opt-in and stays the fixed 500, and an application cannot opt
# in error types it does not own. If this compiles, decide whether a
# conformance of `Error` (one response for every bare-`raises` error, by
# message only) and of foreign types is allowed.
# Expected diagnostic (checked by scripts/check.sh): 'Error' does not implement all requirements for 'ToErrorResponse'

from muntin import Response
from error_response_spike import ToErrorResponse


__extension Error(ToErrorResponse):
    def to_error_response(var self) -> Response:
        return Response.text("mapped", status=400)


def main():
    pass
