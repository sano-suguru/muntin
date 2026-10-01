# Must not compile: `Some[Trait]` is a hidden type parameter, not a storable
# type.
# Expected diagnostic (checked by scripts/check.sh): is not a concrete type


trait Invoke:
    def invoke(self, x: Int) -> String:
        ...


struct Route(Movable):
    var h: Some[Invoke]


def main():
    pass
