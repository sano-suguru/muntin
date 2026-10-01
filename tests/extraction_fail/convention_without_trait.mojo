# Must not compile: generic code cannot call a static factory by naming
# convention. Mojo 1.1.0 checks a generic body against the declared bounds
# only, so `B.from_body` needs `B` bound or refined to a trait that declares
# it. If this starts compiling, name-based conversion became possible and the
# argument-extraction decision should be revisited.
# Expected diagnostic (checked by scripts/check.sh): value has no attribute 'from_body'


def convert[B: Movable & Deinitable](raw: String) raises -> B:
    return B.from_body(raw)


def main():
    pass
