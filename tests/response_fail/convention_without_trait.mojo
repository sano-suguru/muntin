# Must not compile: generic code cannot call a conversion method by naming
# convention. Mojo 1.1.0 checks a generic body against the declared bounds
# only, so `result.to_response()` needs `R` bound or refined to a trait that
# declares it (candidate 3 of the typed-response decision, M2-007). If this
# starts compiling, convention-based conversion became possible and the
# decision should be revisited.
# Expected diagnostic (checked by scripts/check.sh): value has no attribute 'to_response'

from muntin import Response


def respond[R: Movable & Deinitable](var result: R) -> Response:
    return result^.to_response()


def main():
    pass
