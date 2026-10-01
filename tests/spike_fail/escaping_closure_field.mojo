# Must not compile: the old escaping closure type is gone in 1.1.0.
# Expected diagnostic (checked by scripts/check.sh): the 'escaping' function effect is no longer supported


struct Route(Movable):
    var h: def(Int) escaping -> String


def main():
    pass
