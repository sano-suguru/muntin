# Must not compile: a raising `to_response`. The ToResponse requirement is
# non-raising (M2-008); fallible conversion waits for the application-error
# model.
# Expected diagnostic (checked by scripts/check.sh): 'User' does not implement all requirements for 'ToResponse'

from muntin import Response, ToResponse


struct User(ToResponse):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    def to_response(var self) raises -> Response:
        if self.name.byte_length() == 0:
            raise Error("no name")
        return Response.text(self.name)


def main():
    pass
