# Local flare run decision

> **Current.** Now described in [DEVELOPMENT, "3. Verify with the strongest available oracle"](../../DEVELOPMENT.md#3-verify-with-the-strongest-available-oracle).

Status: **decision, standing constraint** (pull request #105; `src/muntin`, `adapters/`, `tests/`, `scripts/` and CI unchanged). It changes one trigger of the [production verification policy](production-verification-policy-decision.md).

**Question and what settles it.** The wire trigger in `docs/DEVELOPMENT.md` section 3 required a local `check_flare.sh` run before pushing, because a failure in the `flare` environment was slow to iterate on through CI. Does that run protect against anything CI's `flare` job does not? Settled by what the job runs and how long it takes, and by whether the authors who push can run the script.

**Choice: drop the required local run; CI's `flare` job is the run the trigger needs.** The job runs the same `check_flare.sh` on ubuntu-latest and macos-latest for every pull request that changes code, and `ci-ok` requires it. In CI run 414 the job took about 8 minutes on ubuntu (the longest job in the run) and 4.4 on macOS, and the whole run about 8. Agent sessions in the project's cloud environment have no pixi or Mojo, so the rule could not be followed there. A local run before pushing stays the author's choice, as for the other two scripts. The loopback coverage the trigger requires is unchanged.

**Rejected.**
- Keep it required: a local run finds a failure before the push, which is worth having where the environment exists, but it repeats a CI job on fewer systems and cannot run in the cloud sessions, so requiring it of every author costs more than the earlier signal is worth.
- Keep it as a recommendation: section 3 already makes every local run the author's choice; a separate recommendation would restate that.

**Revisit when:** CI stops running `check_flare.sh` on every pull request that changes code; or the `flare` job grows so slow that fixing a wire change through CI holds items up.

**Next production slice:** none (a standing constraint). Its owner is `docs/DEVELOPMENT.md` section 3, which this record's pull request changes. Records written before it that name a local `check_flare.sh` in their slice stay as they are.
