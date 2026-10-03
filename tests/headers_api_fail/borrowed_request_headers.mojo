# Must not compile (M3-005): a raw handler that borrows its request cannot
# change the request's headers; one that declares `var req` owns a fresh
# copy and can.
# Expected diagnostic (checked by scripts/check.sh): invalid use of mutating method on rvalue of type 'Headers'
from muntin import Request


def handler(req: Request):
    req.headers.add("X-A", "1")


def main():
    handler(Request("GET", "/x"))
