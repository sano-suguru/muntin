# Built by scripts/check.sh from a directory holding only this file and
# tests/response_spike.mojo, so the application module
# (tests/test_spike_response.mojo) is not on the include path. It registers
# and dispatches return types the library has never seen, next to `String`
# handlers; if the library named an application type in the code this
# instantiates, the build fails. (Mojo 1.1.0 resolves imports lazily: an
# import that nothing uses is not an error, so a bare `import` would not
# catch that.)

from std.os import abort

from muntin import FromBody, Request, Response
from response_spike import ResponseApp, ToResponse


struct Note(ToResponse):
    var text: String

    def __init__(out self, text: String):
        self.text = text

    def to_response(var self) -> Response:
        return Response.text(self.text^, status=202)


struct Draft(FromBody):
    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def hello() -> String:
    return "hello"


def get_note(id: Int) -> Note:
    return Note("note " + String(id))


def save_note(body: Draft) -> Note:
    return Note(body.text)


def main():
    var app = ResponseApp()
    app.get["/hello"](hello)
    app.get["/notes/{id}"](get_note)
    app.post["/notes"](save_note)
    var got = app.handle(Request("GET", "/notes/1"))
    var saved = app.handle(Request("POST", "/notes", "x"))
    var plain = app.handle(Request("GET", "/hello"))
    if (
        got.status != 202
        or got.body != "note 1"
        or saved.body != "x"
        or plain.body != "hello"
    ):
        print("unexpected response")
        abort()
