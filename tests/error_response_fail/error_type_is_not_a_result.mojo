# Must not compile: an error type that opts into `ToErrorResponse` but not
# `ToResponse`, returned from a handler. The error contract never makes a
# type a result: returning it needs `ToResponse`, as for any result type.
# Expected diagnostic (checked by scripts/check.sh): does not conform to trait 'ToResponse'

from muntin import Response
from error_response_spike import ErrorResponseApp, ToErrorResponse


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):
    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("no user", status=404)


def find(id: Int) -> NotFound:
    return NotFound(id)


def main():
    var app = ErrorResponseApp()
    app.get["/users/{id}"](find)
