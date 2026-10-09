---
title: Plugins
weight: 2
---

A gpty plugin is a repository containing a `gpty-plugin.toml` manifest. It can
ship pure data — profiles (named layouts) and concepts (terminal-output
triggers), both delivered to the running GUI — or name programs to run.

Two sections are **declarations, never delivery**. Events: gpty dispatches
nothing to plugins, so a plugin that wants them reads the event socket itself —
a program launched in a pane already has `GPTY_EVENT_SOCKET`, and
`subscribe`/`eventsPoll` are open to same-UID processes. Link handlers: nothing
runs them; the Markdown view opens `http(s)`/`mailto` links through the OS
after a confirmation and ignores every other scheme. `build`/`startup` are
shown for review and run by nobody. The install review prints each of these
sections as the declaration it is. The manifest schema is the plugin-manifest
section of the [agent guide](/docs/agents/). Installing one is explicit:

```sh
gpty plugin install <id>
```

The command clones the repo, validates the manifest with the shipped validator,
and asks you to review the plugin in the GUI before anything installs — a
plugin's content runs as you, so acceptance is pinned to the revision you
reviewed, and a newer revision asks again. The index below is a catalog:
display data only, and nothing in it executes.

{{< plugin-registry >}}

## Submitting a plugin

The index lives in
[godot-pty/gpty-plugins](https://github.com/godot-pty/gpty-plugins). Open a pull
request there adding one entry to `registry.json`; its CI validates the index
and fetches every listed repo's manifest to confirm the entry agrees with it
(id, name, version floor, platforms). Run the same check locally with
`python3 validate.py --check-repos`. The full entry schema, the category list,
and the registry's policies — an id is owned by its repo and does not change,
`min_gpty_version` is a floor the registry states rather than an install gate,
and removing an entry stops new installs only because every install is pinned
to a commit — are documented in that repo's README.
