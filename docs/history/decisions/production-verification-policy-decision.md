# Production verification policy decision

> **Current.** Now described in [DEVELOPMENT, "3. Verify with the strongest available oracle"](../../DEVELOPMENT.md#3-verify-with-the-strongest-available-oracle) and [DEVELOPMENT, "2. Pick one increment"](../../DEVELOPMENT.md#2-pick-one-increment).
> Changed in part since:
> - [Local flare run decision](local-flare-run-decision.md): dropped the required local `check_flare.sh` run from the wire trigger; loopback coverage kept.
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

Status: **decision** (PR #48; `src/muntin`, `adapters/`, `tests/`, `scripts/` and CI are unchanged in it, and it is settled from existing evidence, with no spike). It decides which recurring verification a production item needs. The case is M3-017 (PR #47): a small change whose verification ran the three suites locally, compared every fixture's compiler output and the new fixtures against the base, ran the slice's mutation list, and took two review rounds.

**Question.** Which of these mechanisms protect against something no other required check covers, and which repeat one? Settled by, for each mechanism: the failure class it targets, whether it caught anything in M3-017 (PR #47's Verification section) or in a contrasting item, and which other required check covers the same class.

**Where the cost came from.** `docs/DEVELOPMENT.md` required none of the heavy steps. Decision records prescribed them in their "Next production slice" (M3-016's Diagnostics, Mutations and Done lines, the pattern of M3-014's slice), and most production items since M2-006 added their own route to `adapters/flare/test_localhost_roundtrip.mojo`.

**Evidence, per mechanism:**

- `check.sh`. It holds protection no other check supplies: unsafe confinement and the architecture boundary are the only checks of their invariants, and the expected texts are the only pins of user-facing diagnostics. This decision keeps the script whole rather than weighing each of its steps. In M3-017 the expected texts carried the two re-pins and turned the acceptance and rule-order mutations red. CI runs it on both systems in a few minutes.
- `test.sh`. In M3-017 the tests turned the flag, rebuild and guard mutations red; no fixture covers runtime behavior. CI runs it.
- `check_flare.sh`. A `src` change can break the adapter's build, which only this script sees, and CI runs it on every code pull request. M3-017's new route (`GET /signed/{id}`) proved nothing beyond `App.handle`: the adapter converts every field of every request (`to_muntin_headers`) and does not route, `App.handle` decides per route whether the fields reach the handler, and M3-005's route already proves on the wire that repeated fields keep their order and casing.
- Base-wide diagnostic comparison. In M3-017 it found nothing: every fixture but the two re-pins was byte-identical, and those two differed only in the message line the re-pins check. What it can see that the expected texts cannot is the rest of the output: call-chain frames and overload notes. A rule's branch or message is evaluated in `_check`, after overload resolution (the `where` clauses constrain only the result type), so it changes only the message line. Where overloads or the call chain changed, the comparison found what the pins could not: in M3-015, 77 fixtures gained `_check` frames and 14 changed their candidate notes (that record, "Diagnostics"); in M3-003, 8 failing `get` calls gained the stateful candidates' notes.
- New fixtures against the base. It separated M3-017's fixtures that pin the change (four fail on the base with the old message) from regression pins (the rest fail with the same text). One build per new fixture.
- Mutations. The slice's ten were red, as M3-016 had measured them on its spike, which modeled production's registration, and on a scratch copy of production; production repeated those measurements on the code the slice described. The one that found a gap came from the review asking which DX statement had no pin: with both `Headers` placeholder checks returning `_OK`, every test and fixture still passed, though DX said the fixtures prove those rules.
- Fresh-context review. It found that gap (material), two stale comments and the README point; the review scoped to the fixes found nothing. M3-017 changed the public API, so section 5's trigger already covered it.

**Candidates:**

| Candidate | Result |
|---|---|
| 1. keep: slices go on prescribing local suites, a base-wide comparison, a mutation list and a loopback route | rejected: in M3-017 the comparison, the slice mutations and the route repeated measured results and found nothing; the gap was found by a question none of them asks |
| 2. keep what is unique everywhere; make the rest conditional on a stated trigger | **chosen** |
| 3. drop the base-wide comparison and mutations | rejected: M3-015 shows what the comparison alone sees when overloads or the call chain change, and M3-017 shows a targeted mutation finding an unpinned claim |

**Selected** (written into `docs/DEVELOPMENT.md` sections 2, 3 and 5):

- Universal for a pull request that changes code, unchanged: CI's `verify` and `flare` on both systems (all of `check.sh`, `test.sh` and `check_flare.sh`) and `git diff --check`, as the merge gate; tests and fixtures for the new behavior; for each behavior, diagnostic or invariant the item newly documents as guaranteed, executable evidence that fails if the claim stops being true (rationale, costs and implementation descriptions are not such claims); each new must-not-build fixture that pins the change built against the base's `src`.
- Conditional, each with its trigger:
  - base-wide comparison: a change that can alter compiler output outside the checked expected texts (overload resolution or the candidate set, the signatures candidate notes print, instantiation or call-chain frames, the compiler itself). Examples: a `get` or `post` overload added or removed, an overload's signature or `where` clause, `_check`'s parameters or the call chain to it, the Mojo version. It fires for M3-003 and M3-015, not for M3-017;
  - a local `check_flare.sh` and loopback coverage of the changed wire behavior, preferably by extending an existing case: a change that can reach the wire (`adapters/`, `compat/`, the `Request`, `Response` or `Headers` types or their conversion, how `App.handle` reads the request or builds the response, a backend-dependent limit or status). A new route is a means, not a requirement;
  - a mutation: a documented guarantee that no test or fixture plainly targets. No count;
  - fresh-context review: section 5's trigger, unchanged. The reviewer also checks newly documented guarantees against executable evidence; if the full round produces fixes, one review scoped to them follows.
- A slice may require more only for a concrete risk the list does not cover, and names that risk. The check belongs to that item; later items inherit it only if section 3 is changed to say so. Old one-off checks are not carried forward by default.
- A decision item is settled with evidence suited to its question: existing records and pull requests where they suffice, spikes and fixtures where compiler or runtime behavior must be measured. This decision is the first case of the former.
- No longer required: local runs of the three suites as a completion criterion (CI on the final HEAD is the evidence), a slice's mutation list repeating its decision's measurements, and a loopback route for each handler shape.

**Invariants not weakened.** Unsafe confinement (one `rebind_var[` in `src/muntin`), the architecture boundary, every expected diagnostic text, the known-gap and toolchain-gap fixtures, the State guarantee's pins, and `ci-ok` requiring every suite on both systems. No test, fixture, script or CI job changes.

**Cost and risk.** A change outside the comparison trigger that alters frames or notes reaches `main` unnoticed; the rule message, which DX documents, is still checked. The trigger is judged by the author and the reviewer, so a missed trigger is the main risk. An adapter defect that depends on the route would need loopback coverage for that route; the adapter does not depend on the route today. Without required local runs, a failure can show up in CI after the push instead of before it.

**Revisit when:** a defect reaches `main` that a skipped base-wide comparison, loopback case or slice mutation would have caught; the adapter starts depending on the route (for example, converting header fields only for routes that read them); or a production item outside the trigger still needs the base-wide comparison to settle a question.

**Next action: deferral.** There is no production slice: this record's pull request writes the policy into `docs/DEVELOPMENT.md`, and the next production item follows it. Revisit under the conditions above.
