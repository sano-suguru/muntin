# Must not compile (M3-002): a raw handler that borrows its request cannot
# change the request's headers; one that declares `var req` owns a fresh
# copy and can.
# Expected diagnostic (checked by scripts/check.sh): invalid use of mutating method on rvalue of type 'Headers'
from headers_spike import HRequest


def handler(req: HRequest):
    req.headers.add("X-A", "1")


def main():
    handler(HRequest("GET", "/x"))
