# Must not compile (M3-034): `Next`, the rest of the chain, is not `Copyable`,
# so a middleware cannot keep a copy of it past its call.
# Expected diagnostic (checked by scripts/check.sh): cannot be implicitly copied, it does not conform to 'ImplicitlyCopyable'
from muntin import Request, Response
from middleware_spike import Next


def keep(var request: Request, next: Next) raises -> Response:
    var copy = next
    return copy(request^)


def main():
    pass
