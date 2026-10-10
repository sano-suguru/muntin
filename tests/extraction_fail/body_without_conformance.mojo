# Must not compile: an application type used as the request body without
# conforming to the conversion trait. Muntin's registration owns the message.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's parameter is the request body; its type must conform to FromBody or FromBytes

from extraction_spike import ExtractApp


struct Plain(Movable):
    var name: String

    def __init__(out self, name: String):
        self.name = name


def create_plain(body: Plain) -> String:
    return body.name


def main():
    var app = ExtractApp()
    app.post["/users"](create_plain)
