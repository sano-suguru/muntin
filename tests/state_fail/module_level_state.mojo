# Must not compile: candidate C has no application pattern. A handler is a
# thin function that cannot capture, and Mojo 1.1.0 rejects module-level
# variables, so a repository built at startup cannot reach it (M2-016,
# M3-001).
# Expected diagnostic (checked by scripts/check.sh): global variables are not supported

var users = List[String]()


def get_user(id: Int) -> String:
    return users[id]


def main():
    print(get_user(0))
