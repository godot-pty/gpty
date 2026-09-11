# gPTY License Exceptions

gPTY is free software: you can redistribute it and/or modify it under the terms of
the **GNU General Public License, version 3 or (at your option) any later version**.
The full text is in [LICENSE](LICENSE).

This file states **additional permissions** granted by the gPTY copyright holder
under section 7 of that license. Section 7 allows a licensor to state additional
terms "in the form of a separately written license, or stated as exceptions";
this is that document. The permissions apply to every copy of gPTY distributed
from this repository.

Copyright (C) 2026 Neil Pathare

---

## 1. Plugins, extensions, and adapters are not required to be GPLv3

Code that works with gPTY but is not part of it — plugins, pane types,
extensions, adapters, bridges, and orchestration or automation tools — **may be
licensed under any terms you choose**, including the Apache License 2.0, the MIT
license, or a proprietary license.

You may combine such code with gPTY, load it into a gPTY process, and convey the
two together in one package. Neither the combination nor the use of gPTY's
interfaces places any GPLv3 obligation on your code, and your code does not
become a covered work by being used with, loaded by, or distributed alongside
gPTY. You do not need to publish it, license it under the GPLv3, or grant any
rights you would rather keep.

Writing a program that speaks gPTY's protocols — CLI, JSON-RPC control socket,
MCP tools, the event socket, and the concepts/profiles/workspaces JSON formats —
needs no permission from us and creates no obligation under this license.

**What stays copyleft is gPTY itself.** If you modify gPTY's own source and
convey it, or convey a modified version of a first-party component that ships
under the GPLv3, the GPLv3 applies to that code exactly as it does today.

## 2. Configuration and data files carry no copyleft

The license governs the program, not your data. Files that gPTY reads or writes
— `settings.json`, `workspaces.json`, profiles, layouts, concepts, session and
scrollback databases, and any other configuration or data file — are **not part
of the covered work**, whether you wrote them by hand, exported them from gPTY,
or received them from someone else. They are yours to license under the Apache
License 2.0, under any other license, or under no license at all.

The default data files shipped in this repository (the `*.json` under `godot/`,
including `concepts.default.json` and `profiles.default.json`) are the copyright
holder's own work and are separately licensed to you under the **Apache License
2.0**, so you can copy, adapt, and redistribute them on permissive terms. The
engine and pane code that reads those files remains GPLv3.

## 3. Plugins and data files come with no warranty, no support, and no vetting

The permissions in sections 1 and 2 are granted **as is**, with the same
disclaimers as the rest of gPTY: to the maximum extent permitted by applicable
law there is no warranty of any kind, express or implied — including
merchantability, fitness for a particular purpose, title, and non-infringement —
and the copyright holder is not liable for any damages arising from the use of a
plugin, an extension, an adapter, or any configuration or data file.

For the material the copyright holder licenses in those sections, this paragraph
is an additional term under section 7(a) of the GPLv3. For your own files,
nothing of ours is warranted in the first place.

Beyond the disclaimer itself:

- The gPTY copyright holder does **not** author, review, test, vet, endorse, or
  support third-party plugins, extensions, adapters, or configuration files.
  There is no plugin registry and no review process; shipping a component here
  does not make it reviewed.
- **You decide what runs.** A plugin runs as you with your permissions, and a
  restored profile or workspace can name the program and arguments gPTY will
  spawn. The Workspace Trust prompt exists so that decision is explicit; after
  you approve it, gPTY does exactly what the file asks for.
- **You are responsible for what you load, run, and distribute** — including the
  licenses of the plugins and data files you use, the consequences of running
  them, and any obligation you accept toward your own users by shipping a
  plugin.
- Nothing in this file represents that any plugin or file is safe, correct,
  legal, or fit for any purpose, and no support, update, or fix obligation
  attaches to one.

---

## Notes

- These are additional permissions: they relax the GPLv3, they do not add
  restrictions to it, and they grant nothing beyond the GPLv3 and Apache-2.0
  except the exceptions stated above. They are not an indemnity or a patent
  grant, and they carry no warranty — see section 3.
- Section 7 also lets anyone conveying a copy of a covered work remove
  additional permissions from the copy they convey. A fork or a repackager may
  therefore be stricter than this repository. Copies obtained from the upstream
  repository carry this file and the permission with them.
- Third-party components bundled in this repository keep their own licenses and
  are unaffected by this file — for example `godot/addons/gut` (MIT),
  `extensions/gpty-omp-events` (MIT, distributed under its own permissive
  license as section 1 permits), and the DejaVu Sans Mono fonts (Bitstream
  Vera–derived license). See each directory for its license text.
- Apache-2.0 files and GPLv3 files are compatible in the GPLv3 direction only:
  Apache-2.0 code may be combined into a GPLv3 work, not the reverse. Sections 1
  and 2 above are what make permissively licensed plugins and data files a
  supported configuration rather than an accident.
