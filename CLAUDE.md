# Muntin

Mojo 1.1 (stable) project managed with pixi. Core library in `src/muntin/`, app entry point in `main.mojo`.

## Commands (always via `pixi run`)
- `pixi run run` — run `main.mojo`
- `pixi run build` — build binary to `build/muntin`
- `pixi run package` — precompile library to `build/muntin.mojoc`
- `pixi run test` — run tests (`std.testing.TestSuite`; there is no `mojo test` in 1.x)
- `pixi run format` — `mojo format`; also runs via pre-commit

## Notes
- Mojo syntax changes between versions: check the installed version (`pixi run mojo --version`) and docs at https://mojolang.org/docs before writing code from memory.
- Functions are declared with `def`; test files expose `main()` calling `TestSuite.discover_tests`.
- New test files must be added to the `test` task in `pixi.toml`.
- Python interop is not installed; add with `pixi add python` if needed.
