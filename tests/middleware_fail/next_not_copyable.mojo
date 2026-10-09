# Must not compile (M3-034): `Next`, the rest of the chain, is not `Copyable`,
# so a middleware cannot make a second `Next` to call the rest again.
# Expected diagnostic (checked by scripts/check.sh): value has no attribute 'copy'
from muntin import Request, Response
from middleware_spike import Next


def keep(var request: Request, var next: Next) raises -> Response:
    var copy = next.copy()
    _ = next^.run(request.copy())
    return copy^.run(request^)


def main():
    pass
