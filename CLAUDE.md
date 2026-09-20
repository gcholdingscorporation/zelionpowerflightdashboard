# Working in this repository

ZelionDash is a full-screen EdgeTX telemetry widget for Rotorflight electric
helicopters, written in Lua and installed by copying a `WIDGETS` folder onto the
radio's SD card. It runs unattended with a helicopter in the air, which is the
reason for most of the rules below.

## Build and test

Lua 5.4 is required and is not installed by default:

```
sudo apt-get install -y lua5.4
lua5.4 tools/build.lua     # amalgamates src/ into dist/WIDGETS/ZelionDash/main.lua
lua5.4 tests/run.lua       # the whole suite, seconds
```

**`dist/` is committed, and it is the file that flies.** A change under `src/`
without a rebuild ships stale code to the aircraft while every test still
passes, so rebuild and commit `dist/` in the same commit as the source change.
CI rebuilds and diffs `dist/` on every run and fails if it moved.

`git diff --exit-code -- dist/` only means anything on a committed tree. Commit
first, then rebuild and check.

## `src/widget.lua` is invisible to the loader

`tools/loader.lua` lists the modules tests load, and `widget` is not among them —
the build appends it instead. So `ZD.Widget` is nil in any test that goes through
the loader, and anything in `widget.lua` is reachable only from
`tests/test_build.lua`, which loads the built `dist/` file. That also means
`dist/` has to be rebuilt before `test_build` can see a source change.

## Branches

- `main` is the released branch. Every release tag is cut from it.
- `claude/rc-heli-widget-b1zu1o` is the development branch.
- Work happens on a branch off the development branch, and its pull request
  targets the development branch — not `main`.
- `main` receives work through one pull request per version, titled
  `ZelionDash <version>`, merged with a merge commit.

A branch that has been merged is finished. Restart from the current development
branch rather than stacking new commits on merged history.

## Releasing

Four places carry the version and the release workflow greps all four before it
will tag. They move together or the run refuses:

1. `tools/build.lua` — `VERSION`
2. `tools/loader.lua` — `VERSION`
3. `dist/WIDGETS/ZelionDash/main.lua` — written by the build, so rebuild after 1
4. `RELEASE_NOTES.md` — must name `ZelionDash-<version>.zip`

Then dispatch `.github/workflows/release.yml` **with the ref set to `main`**,
typing the same version as the input. The workflow re-runs the build, the
`dist/` check and the suite before it tags, so a bad tree stops the release
rather than shipping it.

`RELEASE_NOTES.md` is the body of the next release, not a changelog. It is
replaced wholesale each time; past notes live on the releases page.

## Configuration

`docs/sensors.cfg` is the ready-to-install reference config. `sensors.cfg` on a
radio is per-pilot, so the release zip ships the example as
`sensors.cfg.example` and **never** as `sensors.cfg` — merging a folder onto a
card does not ask before overwriting, and a live config in the download would
silently replace a pilot's own settings on every upgrade.

Settings resolve through the bindings' chain, `[*]` → `[model]` → `[cells:N]` →
`[craft]`, with `[battery]` as the radio-wide base. A `[craft]` section binds on
the name the flight controller reports; a name that does not match makes the
section inert rather than wrong, and that aircraft falls back to `[battery]`.

## Settled requirements

These have been decided and are not open unless the maintainer reopens them:
EdgeTX 2.11+; RadioMaster TX16S Mk3 (800×480) and TX15 (480×320); full-screen
widget only; Rotorflight electric helicopters plus the OMPHOBBY OSF03; one
screen with no modes, weighted left; StacyDash-style session min/max; Zelion
Power branding.

## Credits

No third-party code is vendored here. The projects in the README's credits
section are behaviour that was checked against, not code that was copied — keep
it that way, and keep the credits accurate if that changes.
