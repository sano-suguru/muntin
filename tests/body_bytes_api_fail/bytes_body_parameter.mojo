# Must not compile (M3-040): a typed `post` body is a `FromBody` text
# conversion; `List[UInt8]` is the raw body representation, not a typed body,
# so a handler that takes the bytes directly is rejected by the body rule. A
# typed binary body is its own decision (docs/history/architecture-decisions.md,
# "Binary request and response bodies decision (M3-040)"); a raw handler
# reads `req.body`.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's parameter is the request body; its type must conform to FromBody
from muntin import App


def upload(body: List[UInt8]) -> String:
    return String(len(body))


def main():
    var app = App()
    app.post["/upload"](upload)
