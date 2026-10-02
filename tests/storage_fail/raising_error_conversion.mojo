# Must not compile: a raising `to_error_response`. The ToErrorResponse
# requirement is non-raising (M2-013), so a fallible error conversion cannot
# opt in; what a failed conversion answers is undecided.
# Expected diagnostic (checked by scripts/check.sh): 'NotFound' does not implement all requirements for 'ToErrorResponse'

from muntin import Response, ToErrorResponse


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):
    var id: Int

    def to_error_response(var self) raises -> Response:
        if self.id < 0:
            raise Error("cannot render")
        return Response.text("no user", status=404)


def main():
    pass
