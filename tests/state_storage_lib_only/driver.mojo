# Built by scripts/check.sh with only tests/state_storage_spike.mojo beside
# it: the sealed box must store and share a state type the library side has
# never seen (M3-004).
from state_storage_spike import State, box_handler


struct Config(Movable):
    var name: String

    def __init__(out self, name: String):
        self.name = name


def name_of(config: State[Config]) -> String:
    return config[].name


def main() raises:
    var config = State(Config("muntin"))
    var boxed = box_handler(name_of, config)
    var copy = config.copy()
    if boxed.invoke(List[String]()).body != "muntin":
        raise Error("boxed handler did not read the state")
    if config._shared.count() != 3:
        raise Error("expected three handles")
    _ = copy^
    _ = boxed^
    if config._shared.count() != 1:
        raise Error("expected one handle")
    print("ok")
