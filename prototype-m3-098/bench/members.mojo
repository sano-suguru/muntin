# Per-read cost of defaulted members: absent (default parsed) vs present.
from std.sys import argv
from std.time import perf_counter_ns
from muntin import Json, JsonMember, JsonMembers


@fieldwise_init
struct Q(JsonMembers):
    var text: String
    var limit: Int
    var ratio: Float64
    var on: Bool
    var flags: List[String]

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [
            JsonMember("limit", default="20"),
            JsonMember("ratio", default="0.5"),
            JsonMember("on", default="true"),
            JsonMember("flags", default='["a","b"]'),
        ]


def main() raises:
    var n = Int(argv()[1])
    var body = String(
        '{"text":"q"}' if argv()[2] == "absent" else '{"text":"q","limit":20,"ratio":0.5,"on":true,"flags":["a","b"]}'
    )
    var sink = 0
    var t = perf_counter_ns()
    for _ in range(n):
        var q = Json[Q].from_body(body).take()
        sink += q.limit + len(q.flags)
    var dt = perf_counter_ns() - t
    print(argv()[2], "ns/op", Float64(dt) / Float64(n), "sink", sink)
