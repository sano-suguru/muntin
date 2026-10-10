# Must not compile (M3-042): a type conforming only to the carrier's private bound has no
# conversion; as a carrier's body it is rejected at registration as a body of
# no conversion is.
# docs/history/architecture-decisions.md, "Typed binary request bodies with
# header fields decision (M3-042)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's parameter is the request body; its type must conform to FromBody or FromBytes
from muntin import App, WithHeaders
from muntin.body import _FromBodyOrBytes


struct Neither(_FromBodyOrBytes):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def upload(input: WithHeaders[Neither]) -> String:
    return String(input.body.n)


def main():
    var app = App()
    app.post["/upload"](upload)
