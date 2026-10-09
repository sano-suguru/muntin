# Must not compile (M3-034): `Next.run` consumes the `Next`, so a middleware
# cannot run the rest of the chain twice.
# Expected diagnostic (checked by scripts/check.sh): use of uninitialized value 'next'
from muntin import Request, Response
from middleware_spike import Next


def twice(var request: Request, var next: Next) raises -> Response:
    _ = next^.run(request.copy())
    return next^.run(request^)


def main():
    pass
