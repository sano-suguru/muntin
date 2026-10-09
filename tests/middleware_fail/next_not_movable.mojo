# Must not compile (M3-034): a middleware receives `Next` by borrow and `Next`
# is not `Movable`, so it cannot move it out of its call.
# Expected diagnostic (checked by scripts/check.sh): cannot transfer out of immutable reference
from muntin import Request, Response
from middleware_spike import Next


def keep(var request: Request, next: Next) raises -> Response:
    var moved = next^
    return moved(request^)


def main():
    pass
