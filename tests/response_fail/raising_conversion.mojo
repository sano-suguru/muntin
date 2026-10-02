# Must not compile: the conversion requirement does not raise, so a raising
# `to_response` does not conform. What a failed conversion means belongs to
# the application-error model (M2-007). A non-raising implementation also
# satisfies a `raises` requirement (tests/test_spike_response.mojo), so a
# future `raises` requirement would keep existing conformances (callers of
# `to_response()` through the trait may still break).
# Expected diagnostic (checked by scripts/check.sh): no 'to_response' candidates have type 'def(var self: User) thin -> Response'

from muntin import Response
from response_spike import ToResponse


struct User(ToResponse):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    def to_response(var self) raises -> Response:
        return Response.text(self.name^)


def main():
    pass
