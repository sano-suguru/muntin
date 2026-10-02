# Must not compile: an application-level error mapper as a compile-time
# parameter of the app type (`App[on_error=...]`). The mapped app is a
# different type, so a backend that holds the app (the Flare adapter's
# `MuntinHandler` owns an `App`) or `TestClient` would have to become
# generic over the mapper. Rejected for coupling backends to the
# application's error policy.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'MappedApp[not_found[_]]' to 'MappedApp'

from muntin import Response


def fixed_500[E: Deinitable](var e: E) -> Response:
    return Response.text("Internal Server Error", status=500)


struct MappedApp[
    on_error: def[E: Deinitable](var E) thin -> Response = fixed_500
]:
    def __init__(out self):
        pass

    def get[
        E: Deinitable, //
    ](self, handler: def() thin raises E -> String) -> Response:
        try:
            return Response.text(handler())
        except e:
            return Self.on_error[E](e^)


struct Backend:
    """Stands in for a backend adapter that owns the application."""

    var app: MappedApp[]

    def __init__(out self, var app: MappedApp[]):
        self.app = app^


@fieldwise_init
struct NotFound(Movable):
    var id: Int


def not_found[E: Deinitable](var e: E) -> Response:
    comptime if E == NotFound:
        return Response.text("no user", status=404)
    return Response.text("Internal Server Error", status=500)


def main():
    _ = Backend(MappedApp())
    _ = Backend(MappedApp[not_found]())
