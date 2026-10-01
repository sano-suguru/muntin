# Built by scripts/check.sh from a directory holding only this file and
# tests/extraction_spike.mojo, so the application module
# (tests/test_spike_extraction.mojo) is not on the include path. It
# registers and dispatches a body type the library has never seen; if the
# library named an application type in the code this instantiates, the
# build fails. (Mojo 1.1.0 resolves imports lazily: an import that nothing
# uses is not an error, so a bare `import` would not catch that.)

from extraction_spike import ExtractApp, FromBody
from muntin import Request


struct Note(FromBody):
    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def add_note(body: Note) -> String:
    return body.text


def edit_note(id: Int, var body: Note) -> String:
    return String(id) + body.text


def main():
    var app = ExtractApp()
    app.post["/notes"](add_note)
    app.post["/notes/{id}"](edit_note)
    if app.handle(Request("POST", "/notes/1", "x")).body != "1x":
        print("unexpected response")
