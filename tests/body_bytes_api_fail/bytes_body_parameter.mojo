# Must not compile (M3-040, kept by M3-041): `List[UInt8]` is the raw body
# representation, not a typed body: a typed `post` body is a `FromBody` text
# conversion or a `FromBytes` bytes conversion, and `List[UInt8]` is neither,
# so a handler that takes the bytes directly is rejected by the body rule. An
# application declares its own `FromBytes` type (`body.copy()` in
# `from_bytes` to keep them) or a raw handler reads `req.body`
# (docs/history/architecture-decisions.md, "Typed binary request bodies
# decision (M3-041)").
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's parameter is the request body; its type must conform to FromBody or FromBytes
from muntin import App


def upload(body: List[UInt8]) -> String:
    return String(len(body))


def main():
    var app = App()
    app.post["/upload"](upload)
