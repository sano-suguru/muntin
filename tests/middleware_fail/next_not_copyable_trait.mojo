# Must not compile (M3-034): `Next` does not conform to `Copyable`, checked by
# conformance rather than by a missing method: a function that requires
# `Copyable` does not accept it.
# Expected diagnostic (checked by scripts/check.sh): argument type 'Next[o]' does not conform to trait 'Copyable'
from muntin import Request, Response
from middleware_spike import Next


def keep[T: Copyable](value: T) -> T:
    return value.copy()


def copying(var request: Request, var next: Next) raises -> Response:
    var copy = keep(next)
    _ = next^.run(request.copy())
    return copy^.run(request^)


def main():
    pass
