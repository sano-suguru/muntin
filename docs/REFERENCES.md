# Authoritative references

Upstream sources behind assumptions that may change. Re-check them when toolchain or dependency behavior matters to a decision; examples in `docs/DX.md` hold only once they compile on the pinned toolchain.

## Mojo

- Function syntax (`def`; `fn` deprecation): https://docs.modular.com/mojo/manual/functions/
- Compile-time parameterization: https://docs.modular.com/mojo/manual/parameters/
- Structs and `@fieldwise_init`: https://docs.modular.com/mojo/manual/structs/
- Error handling and typed-error constraints: https://docs.modular.com/mojo/manual/errors/
- Changelog (reflection, language evolution): https://docs.modular.com/mojo/changelog

## URLs

- Percent-encoding (RFC 3986, section 2.1): https://www.rfc-editor.org/rfc/rfc3986#section-2.1
- WHATWG URL Standard, `application/x-www-form-urlencoded` parser (Muntin takes only its `+` rule; M3-018 lists the differences): https://url.spec.whatwg.org/#concept-urlencoded-parser

## HTTP

- HTTP Semantics (RFC 9110): methods servers support (section 9.1), method content rules (sections 9.3.1, 9.3.4, 9.3.5), 404 and 405 (sections 15.5.5, 15.5.6): https://www.rfc-editor.org/rfc/rfc9110
- `PATCH` (RFC 5789): https://www.rfc-editor.org/rfc/rfc5789

## Flare

- Repository: https://github.com/ehsanmok/flare
- Pinned release: `v0.11.0` (commit `59bda50f46853f7351eef12f1737f7fb2287de71`), MIT license, declaring `mojo >=1.1.0,<2.0.0`; release notes: https://github.com/ehsanmok/flare/releases/tag/v0.11.0

Flare is installed as a pixi-build git source dependency. The GitHub release is not marked immutable, so the commit in `pixi.lock` is the reproducible reference. Flare's build backend (`pixi-build-rattler-build`) is resolved at install time and is not recorded in `pixi.lock`. Before upgrading, re-check the license, the supported Mojo range and the adapter-relevant API.
