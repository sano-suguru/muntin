# Must not compile: candidate 2 (M2-010), a raising twin next to each
# non-raising overload. A non-raising handler converts to both function
# types, and Mojo 1.1.0 reports the call as ambiguous instead of ranking
# the exact match first. Twins are therefore not a way to add raising
# handlers beside the current overloads.
# Expected diagnostic (checked by scripts/check.sh): ambiguous call to 'get'

from muntin import Response


struct TwinApp:
    def __init__(out self):
        pass

    def get(self, handler: def() thin -> String) -> Response:
        return Response.text(handler())

    def get(self, handler: def() raises thin -> String) raises -> Response:
        return Response.text(handler())


def hello() -> String:
    return "hello"


def main() raises:
    var app = TwinApp()
    _ = app.get(hello)
