---
name: gpty-external-scanners
description: "Update gPTY's enrolments in anthropics/oss-scanner or google/oss-fuzz: the project files, the local build proof without Docker, and the PR checks each repository runs."
---

# gPTY in external scanners

Two enrolments live in other repositories. Neither is synced from this one: a change to them is a pull request of its own.

## oss-scanner (anthropics/oss-scanner)

`projects/gpty/` holds `project.yaml`, `Dockerfile`, `threat_model.md`, `report_guidelines.md` and `patch_guidelines.md`, all beside `project.yaml` (so none of the path keys is set).

- `repo: https://github.com/godot-pty/gpty#main`, `primary_contact: gpty.dev@outlook.com`; email at `low`+, GitHub advisory drafts at `high`+.
- Validate with `python3 tools/validate.py` in a clone (PyYAML); the PR's `Build` workflow then runs `tools/check --no-shell gpty` in a Docker runner and comments the verdict.
- The PR also runs `Terms` (the description must contain the byte-exact `- [x] I accept the [OSS Scanner terms](https://red.anthropic.com/oss-scanner/terms/)` line), a CLA comment, the checklist bot, and `trusted-reporter`.
- `trusted-reporter` only reads **issue comments** on the PR, not review comments: add `oss-scanner` as a trusted reporter under repository Settings > Advanced Security > Private vulnerability reporting > Settings, then comment exactly `I have added oss-scanner as a trusted reporter on godot-pty/gpty`. Private vulnerability reporting itself is enabled with `gh api -X PATCH repos/godot-pty/gpty -f 'security_and_analysis[private_vulnerability_reporting][status]=enabled'` (read it back at `/repos/godot-pty/gpty/private-vulnerability-reporting`; the `security_and_analysis` field does not show it).
- Build changes need a new PR here; the Dockerfile is not in this repository. Its steps: `rust:1.96.0-bookworm`, pinned Godot 4.7.2 (SHA512 from `ci.yml`), `./scripts/media-deps`, `cargo build --workspace --bins --tests` **plus** `cargo build -p gpty-gdext` (the `--tests` build does not emit `target/debug/libgpty_gdext.so`), then GUT and the Node extension tests as non-fatal warnings.

## oss-fuzz (google/oss-fuzz)

`projects/gpty/` holds `project.yaml`, `Dockerfile` and `build.sh`.

- `base_os_version: ubuntu-24-04` must match `FROM gcr.io/oss-fuzz-base/base-builder-rust:ubuntu-24-04` (`infra/ci/check_base_os.py` reads the tag).
- `Dockerfile` and `build.sh` headers must say `Copyright <year> Google LLC`; `header-check` allows no other holder.
- `project.yaml`: `language: rust`, `sanitizers: [address]`, `fuzzing_engines: [libfuzzer]`, `architectures: [x86_64]`, `file_github_issue: true`, `main_repo` with `.git`.
- The image pins `ENV RUSTUP_TOOLCHAIN=nightly-2026-11-01` because `rust-toolchain.toml` pins stable and cargo-fuzz needs nightly. Bump it together with `ci.yml`'s `fuzz-build` toolchain.
- The Dockerfile runs `./scripts/media-deps` (the SHA256-pinned FFmpeg); `build.sh` copies the soname files (`lib*.so.[0-9]*` without `*.so.*.*`) into `$OUT` and sets `patchelf --set-rpath '$ORIGIN/'` on each fuzzer, zips `fuzz/corpus/<target>/` as `<target>_seed_corpus.zip`, and copies every `fuzz/fuzz_targets/*.rs` binary. A new target needs no `build.sh` change; it needs a `fuzz/corpus/<target>/` directory to get seeds.

## Prove it without Docker

Docker is not installed on the maintainer's machine; run the script itself:

```bash
rustup toolchain install nightly-2026-11-01 --profile minimal
SRC=<parent-of-gpty> OUT=/tmp/gpty-out RUSTUP_TOOLCHAIN=nightly-2026-11-01 bash projects/gpty/build.sh
readelf -d /tmp/gpty-out/media_probe | grep -E 'RUNPATH|NEEDED'
cd /tmp/gpty-out && ASAN_OPTIONS=detect_odr_violation=0:detect_leaks=1 ./line_parser -runs=50 <repo>/fuzz/corpus/line_parser
```

`patchelf` must be on `PATH` (a pip/venv install is enough for the test). The ODR option is required: the bundled SQLite trips ASAN's default ODR check, and OSS-Fuzz's runner already disables it. Run every target over its own corpus; expect exit 0 and no LeakSanitizer report.

The real container proof is the PR's `Project tests` workflow. GitHub holds it as `action_required` for a first-time contributor until an OSS-Fuzz maintainer approves; the Google CLA must be signed once at cla.developers.google.com.
