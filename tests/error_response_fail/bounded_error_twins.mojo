# Must not compile: an overload bounded by the error trait
# (`E: ToErrorResponse`) beside the existing inferred `E: Deinitable` one.
# An opted-in error type satisfies both, and Mojo 1.1.0 reports the call as
# ambiguous instead of preferring the more constrained candidate. Per-type
# conversion is therefore decided inside one function
# (`comptime if conforms_to(E, ToErrorResponse)`), not by overloads.
# Expected diagnostic (checked by scripts/check.sh): ambiguous call to 'get'

from muntin import Response
from error_response_spike import ToErrorResponse


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):
    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("no user", status=404)


struct TwinApp:
    def __init__(out self):
        pass

    def get[
        E: Deinitable, //
    ](self, handler: def() thin raises E -> String) -> Response:
        return Response.text("fixed 500")

    def get[
        E: ToErrorResponse, //
    ](self, handler: def() thin raises E -> String) -> Response:
        return Response.text("converted")


def find() raises NotFound -> String:
    raise NotFound(0)


def main():
    var app = TwinApp()
    _ = app.get(find)
