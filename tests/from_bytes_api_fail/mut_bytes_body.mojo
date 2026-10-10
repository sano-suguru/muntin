# Must not compile (M3-041): the handler borrows or owns its bytes body (a
# fresh value per request); a mut parameter matches no registration overload.
# docs/history/architecture-decisions.md, "Typed binary request bodies decision
# (M3-041)".
# Expected diagnostic (checked by scripts/check.sh): no matching method in call to 'post'
from muntin import App, FromBytes


struct Payload(FromBytes):
    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body.copy())


def upload(mut body: Payload) -> String:
    body.data.append(0)
    return String(len(body.data))


def main():
    var app = App()
    app.post["/upload"](upload)
