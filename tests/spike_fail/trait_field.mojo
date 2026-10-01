# Must not compile: a trait as a struct field type (no existential storage).
# Expected diagnostic (checked by scripts/check.sh): struct fields do not support trait types; 'Invoke' is a trait


trait Invoke:
    def invoke(self, x: Int) -> String:
        ...


struct Route(Movable):
    var h: Invoke


def main():
    pass
