# LeakSanitizer positive control (PR #97): leaks allocations, as a
# `__deinit__` in _handler_storage.mojo that skipped a release would.
# `SANITIZE=address ./scripts/test.sh` requires this binary to fail with
# the report below, on Linux only (leak detection is not verified elsewhere
# for this toolchain). Each allocation is made in its own frame and its
# address printed, so the compiler cannot delete it and no live stack slot
# still points to it.
# Expected report: LeakSanitizer: detected memory leaks

from std.memory import OwnedPointer


@no_inline
def leak_one(i: Int) -> Int:
    var values: List[Int] = [i, i + 1]
    var raw = OwnedPointer(values^).unsafe_take_allocation().unsafe_leak()
    print(Int(raw) % 2, end="")
    return len(raw[])


def main():
    var total = 0
    for i in range(10):
        total += leak_one(i)
    print("", total)
