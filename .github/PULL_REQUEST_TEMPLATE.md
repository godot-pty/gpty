## Summary

<!-- What changed, why, and which roadmap row or issue it closes. -->

## Checks

- [ ] `./scripts/ci-check` passes.
- [ ] The change is covered by a test, or this PR says why a test is impractical.
- [ ] Docs and the roadmap are updated when behavior changes.
- [ ] No secrets, credentials, private paths, or captured program output are added.
- [ ] Commits are Conventional Commits and carry a DCO `Signed-off-by` trailer (`git commit -s`).

## Security

- [ ] The change adds no new untrusted-input path, or it names the bound and the test that exercises it.
- [ ] IPC, PTY, filesystem, plugin, networking or secret-handling changes: the relevant rules in [`docs/content/docs/agents/security.md`](https://github.com/godot-pty/gpty/blob/main/docs/content/docs/agents/security.md) were read.
