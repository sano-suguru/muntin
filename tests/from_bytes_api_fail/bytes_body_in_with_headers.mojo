# Must not compile (M3-041): WithHeaders[B] carries a FromBody text body only;
# a typed bytes body with the request's header fields is not supported (a raw
# handler reads both).
# docs/history/architecture-decisions.md, "Typed binary request bodies decision
# (M3-041)".
# Expected diagnostic (checked by scripts/check.sh): 'WithHeaders' parameter 'B' has 'FromBody' type, but value has type 'AnyStruct[Payload]'
from muntin import App, FromBytes, WithHeaders


struct Payload(FromBytes):
    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body.copy())


def upload(input: WithHeaders[Payload]) -> String:
    return String(len(input.body.data))


def main():
    var app = App()
    app.post["/upload"](upload)
