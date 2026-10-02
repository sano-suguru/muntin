# Must not compile: the typed-return overloads take non-raising handlers,
# like the String ones; raising handlers wait for the application-error
# model (M2-007).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def get_user(id: Int) raises thin -> User' to 'def(Int) thin -> User'

from muntin import Response
from response_spike import ResponseApp, ToResponse


struct User(ToResponse):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    def to_response(var self) -> Response:
        return Response.text(self.name^)


def get_user(id: Int) raises -> User:
    return User("Ada")


def main():
    var app = ResponseApp()
    app.get["/users/{id}"](get_user)
