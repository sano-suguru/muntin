# Must not compile: a capturing closure as the state carrier (a probe beyond
# A/B/C). A closure passes through a parameter bounded by its function
# trait, but a function generic over that trait is itself `capturing`, so
# it does not convert to the thin trampoline `_Call[F]` that the unchanged
# `_Erased` stores. Using closures would change `_Call`/`_Erased` and every
# M2 registration signature (thin function types) (M3-001).
# Expected diagnostic (checked by scripts/check.sh): capturing thin -> Response' to 'def(F, List[String]) raises thin -> Response'

from muntin import Response
from muntin._handler_storage import _Erased


def _call[F: def() -> String](f: F, args: List[String]) raises -> Response:
    return Response.text(f())


def register[F: def() -> String](var f: F) -> _Erased:
    return _Erased.__init__[call=_call[F]](f^)


def main() raises:
    var greeting = String("hi")

    def hello() {var greeting} -> String:
        return greeting

    var box = register(hello^)
    print(box.invoke(List[String]()).body)
