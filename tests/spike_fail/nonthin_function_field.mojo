# Must not compile: a function type without `thin` is a trait, so it cannot be
# a field type.
# Expected diagnostic (checked by scripts/check.sh): struct fields do not support trait types; 'def(Int) -> String' is a trait


struct Route(Movable):
    var h: def(Int) -> String


def main():
    pass
