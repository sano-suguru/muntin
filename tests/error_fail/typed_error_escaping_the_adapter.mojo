# Must not compile: an adapter that lets a handler's application-defined
# error escape, stored in the production `_Erased` box (M2-010). The box's
# call type raises `Error`, and a function raising another error type does
# not convert to it, so a typed error cannot reach `App.handle`'s `except`.
# The adapter that knows `E` must catch it and choose the response itself;
# that is where the handler-error 500 is decided.
# Expected diagnostic (checked by scripts/check.sh): value passed to 'call' cannot be converted from 'def _call_escaping(handler: def() raises NotFound thin -> String, args: List[String], bytes: List[UInt8]) raises NotFound thin -> Response'

from muntin import Response
from muntin._handler_storage import _Erased


@fieldwise_init
struct NotFound(Movable):
    var id: Int


def _call_escaping[
    E: Deinitable
](
    handler: def() thin raises E -> String,
    args: List[String],
    bytes: List[UInt8],
) raises E -> Response:
    return Response.text(handler())


def find() raises NotFound -> String:
    raise NotFound(1)


def main():
    _ = _Erased.__init__[call=_call_escaping[NotFound]](find)
