# JSON media types decision (M3-094)

> **Current.** Not built yet.

Status: **decision** (M3-094, issue [#193](https://github.com/sano-suguru/muntin/issues/193)). Evidence: its pull request.

**Question and what settles it.** [M3-008](m3-008-json-codec-decision.md) requires exactly one `Content-Type` field of `application/json` on a `Json[T]` body, so a client sending a structured-syntax `+json` type (`application/merge-patch+json`, a vendor type) or no `Content-Type` gets 415, which its revisit condition names. Which of these does a JSON route accept, chosen where (per route or `App`-wide), spelled how, and visible how at registration and in `app.openapi`; and does a `Json` result's media type, today an edit after the conversion that also labels the fixed 500 ([M3-028](m3-028-json-response-status-decision.md)'s third revisit condition), share the choice? Settled by the Fetch standard's rule for which cross-site requests a browser sends without a preflight (the CSRF path M3-008 closed), RFC 6839 and RFC 9110 on what a `+json` type and a missing `Content-Type` say, the existing records ([M3-089](m3-089-text-and-json-body-limits-decision.md)'s room left for this item, [M3-091](m3-091-openapi-output-decision.md)'s media types), and the compile-time `StaticString` parameters production already uses.
