# Must not compile: an error type that conforms to `ToErrorResponse` but not
# `ToResponse`, returned from a handler (M2-013). The error contract never
# makes a type a result: returning it needs `ToResponse`, as for any result
# type, so the result is outside every overload's `where` clause (M3-015).
# Expected diagnostic (checked by scripts/check.sh): identical(R, StringSpan[ImmStaticOrigin])

from muntin import App, Response, ToErrorResponse


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):
    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("no user " + String(self.id), status=404)


def find(id: Int) -> NotFound:
    return NotFound(id)


def main():
    var app = App()
    app.get["/users/{id}"](find)
