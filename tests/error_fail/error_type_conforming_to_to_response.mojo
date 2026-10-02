# Must not compile: a handler error type that conforms to ToResponse
# (M2-010). Such a type asks to be answered with its own response, the
# application-defined conversion this decision defers; it is rejected at
# registration so that adding that conversion later changes no handler that
# compiles today from 500 to another response.
# Expected diagnostic (checked by scripts/check.sh): a handler error type that conforms to ToResponse is not supported yet; return the response from the handler instead of raising it

from muntin import Response, ToResponse
from error_spike import ErrorApp


@fieldwise_init
struct Gone(Movable, ToResponse):
    var id: Int

    def to_response(var self) -> Response:
        return Response.text("gone", status=410)


def find_user(id: Int) raises Gone -> String:
    raise Gone(id)


def main():
    var app = ErrorApp()
    app.get["/users/{id}"](find_user)
