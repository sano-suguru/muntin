# Must not compile: on the M3-016 spike, a get handler takes one `Headers`
# slot. The inverse, one `Headers`, registers
# (tests/test_spike_get_headers.mojo). Decision: docs/ARCHITECTURE.md,
# "Typed get header access decision (M3-016)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes one Headers, as its last parameter
from muntin import App, Headers

from get_headers_spike import get


def h(a: Headers, b: Headers) -> String:
    return "x"


def main():
    var app = App()
    get["/x"](app, h)
