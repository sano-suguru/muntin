# Must not compile: a `to_error_response` that raises does not satisfy the
# non-raising requirement, so a fallible error conversion cannot opt in
# (deferred, as for `ToResponse` in M2-007).
# Expected diagnostic (checked by scripts/check.sh): does not implement all requirements for 'ToErrorResponse'

from muntin import Response
from error_response_spike import ToErrorResponse


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):
    var id: Int

    def to_error_response(var self) raises -> Response:
        raise Error("cannot render")


def main():
    pass
