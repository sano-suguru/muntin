# Must not compile (M3-040): `Request.body` holds bytes, so text is never
# converted into it implicitly; a middleware or handler that replaces the body
# writes bytes (`List("x".as_bytes())`).
# Expected diagnostic (checked by scripts/check.sh): cannot implicitly convert 'StringLiteral["taken"]' value to 'List[UInt8]'
from muntin import Request


def main():
    var req = Request("POST", "/x", "body")
    req.body = "taken"
    _ = req^
