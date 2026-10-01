# Must not compile: a List of a trait (no existential element type).
# Expected diagnostic (checked by scripts/check.sh): 'List' parameter 'T' has 'AnyType' type, but value has type 'AnyTrait[Invoke]'


trait Invoke(Copyable):
    def invoke(self, x: Int) -> String:
        ...


@fieldwise_init
struct A(Invoke):
    def invoke(self, x: Int) -> String:
        return "a"


def main():
    var l = List[Invoke]()
    l.append(A())
