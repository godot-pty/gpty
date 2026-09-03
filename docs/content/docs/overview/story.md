---
title: gPTY
weight: 2
date: 2026-09-03
---

The origin story; mostly told through the questions I was prompting along the way.

## The off-hand thought

It started as a shower thought: could Flutter show an OS's CLI inside a widget?
I'd built a handful of small things in Flutter before - nothing serious, a tip calculator; before that, an Electron app that wired up jdoodle for algorithm practice; and even before that, a basic Android app that pulled a list of similar movies off the Rotten Tomatoes API. More recently I'd been using AI to help build a media manager and a finance manager in Rust + Flutter, and that's probably where the idea came from. I had zero background in CLI tools, terminal emulators - I wasn't even using Linux yet, though I knew I was about to be.
So the first real question wasn't "how do I build this," it was "is this even the right stack." I prompted Gemini about backend alternatives to Dart, poked at the idea of an IDE-like tool that could interact with the OS, tried "what if I just launch PowerShell Core inside a widget," then started thinking about multiple interactive terminal sessions that could be resized and snapped to a grid. At one point I even considered building the whole thing as a Zed extension instead of a standalone app.

## The wrong engine before the the right one

The pivot that actually stuck was asking: how would this differ if I swapped Flutter for a game engine, specifically Godot? I wanted this to be a real desktop app, targeting 60+ FPS with a configurable ceiling (120, 144 if I could manage it) - more of a "why not treat this like a game" idea than anything principled at first.
Godot pointed me at `GodotXterm` as the obvious plugin path. I looked it over, and it hadn't had a commit in months and didn't support newer Godot versions. So the next question was; how hard would a custom Rust backend actually be? Fecided to follow through and do it anyway, partly because it seemed like the better long-term choice, and partly because I wanted the learning experience of not just leaning on someone else's library (spoiler alert, I ended up relying heavily on a LOT of libraries as the project progressed - resting on the shoulders of giants).

Somewhere in here I also found out I wasn't the only one thinking along these lines - a project called Cate (I blanked on the name for a while and only found it after fixing my search terms) does something similar: an infinite canvas you lay terminals and other panels onto (this might've also been the seed for gPTY's origin that was planted when I might've stumbled across while doomscrolling tech. sub-reddits and days later thought of creating a Flutter widget to surface an OS's CLI). The rediscovery was useful both as validation and as a way to sharpen what I actually wanted to build differently.

## Figuring out what this even was

Most of the early "architecture" was really just me negotiating scope with myself.
- Infinite canvas (like Cate) or a fixed grid? I went with a grid - best balance between power users and newcomers, with min/max container sizes based on screen resolution.
- Should there be a file tree? Sure, Godot makes that easy.
- A full code editor? No - that's reinventing an IDE, and not worth it. And if I wanted to, I had Electron; but I didn't want to - because.. Electron.
- Pull a browser tab into the canvas to preview a frontend, like Cate does? Also, no. RE: Electron.
- Instead of a full editor, what about a pane that just shows you a file's contents - basically a terminal running `cat`? That one stuck, and became the code viewer pane.

## Concepts: How panes talk without talking

Once I had terminals in a grid, the obvious next question was AI agents - if someone's running an agent CLI in one pane, should it be able to send input to another pane? I went back and forth on this. Direct pane-to-pane awareness felt like the wrong call, both for security and for keeping panes simple, so I pushed the problem down to the Rust layer instead: an IFTTT-esque, pub-sub hybrid where a terminal can broadcast events based on user-defined regex, and other terminals can be configured to react to them. Seemed like a cool idea.

That evolved into what's now the concept (yes, that is the best name I could think of) engine: a two-tier system. The base tier assigns each terminal as a source and/or destination for named "concepts." The core tier defines each concept - a regex trigger, and one or more labeled actions that only fire on terminals carrying that specific label. It's a small idea, but it took a few iterations to land on something that felt clean. Not sure if it's bullet-proof yet, but time (and commits) will tell.

I also spent a while deep in the weeds comparing how much scrollback context a native terminal, and `tmux` (also something I had recently discovered, soon after ditching Windows for Linux), and this tool could realistically offer, and had a good self-check moment realizing that moving history to a SQLite-backed store on disk doesn't actually save space by itself - it's the same bytes, just moved, and the real win would only come from decent indexing. A small thing, but it's the kind of gap in my ecosystem knowledge that came up constantly (Note: SQLite is not really implemented (as of 0.5.0), regardless of what the CHANGELOG might say).

At one point I made the AI prompts play devil's advocate against the entire idea - is this actually a good use of time, what happens when I compare it to something like Zed that already exists. And that turned out to be an useful exercise.

## Getting to something real, and the inevitable naming saga

Naming might actually be as hard as implementing, or might come easy to some and not others. The working title for a long time was GodoPTY (silent d - "goh-doh-tee"). I eventually got to a working state: a strict 2x6 tiling grid, terminal/code-viewer/file-tree panes, basic settings for color scheme, cursor, font size (and you can download the early releases to test! Maybe it'll be nostalgic a few years down the line). And that's when a more important realization started to form; this can't *just* be a niche AI-orchestration toy. If it can't replace `tmux` or `Ghostty` as a daily driver, nobody has a reason to switch - they'll just keep bolting AI workflows onto tools they already use. Although this is a hobby project that I'm well aware that probably only I would ever use, I still wanted to give it the best (best ~~prompts?~~ chance at a broader ( >1 ) usability).

I also decided fairly deliberately *not* to let it autonomously spawn or manage agents - that felt like a slippery slope on the safety/policy side, and the agent CLIs I cared about (Gemini, Claude, OMP) already handle their own sub-agents and loops fine on their own. gPTY's job is the pub-sub/UX layer around them, not another orchestrator.
Eventually "GodoPTY" got old, I realized it was poorly named (and even poorly pronounced), so the hunt was on - for a new name. I ran through & checked `gTerm` (already crowded), `gtx` (too close to other trademarks, and also not an nVIDIA graphics card), and landed on `gPTY`: Godot + PTY (the GPT resonance since AI tooling is a big part of the use case was not intended). Around the same time I decided to make the same call for every AI CLI I wanted to support well: rather than hardcoding first-class integrations for OMP, Gemini, and Claude and chasing their APIs forever, build gPTY's own CLI and let those tools discover and drive it themselves - an OMP skill, prompt/system-prompt guidance for Gemini and Claude, all built on the same underlying control surface. The thought was to shift from traditional wiring and make more use of agentic reasoning and "thinking" to let people do what they wanted - avoids restrictiveness on my part.

## Almost quitting

Right after landing v0.4.0 - with a dedicated OMP-focused workspace that I thought could actually maybe be ued by one other person - I found `herdr` (https://herdr.dev/  -if you haven't seen it yet, go check it out!). It's a terminal multiplexer built specifically for AI coding agents, and it was already well ahead of anything I had in terms of polish and feature completeness. I felt somewhat deflated, and wondered whether this hobby project was worth continuing (well, that hasn't really stopped).

My first instinct was to avoid competing with it directly (let's be honest, I couldn't (maybe if I had years and a trillion tokens - then *maybe*)) - could I make gPTY's backend headless and integrate with herdr instead of duplicating it? I went back and forth on how much of my own backend to give up for a minute before landing on the simplest, most decoupled answer: just launch herdr inside a gPTY pane. herdr needs a terminal; gPTY supplies terminals. If someone wants herdr's session management, they get a pane and let herdr own it.

What got me unstuck (read: made me want to continue the project), though, was asking a different question: what can Godot's side of this endeavor do that a text-based TUI fundamentally cannot? herdr is, and probably always will be, constrained to what you can draw in a terminal. gPTY has an actual rendering engine underneath - real GUI panes, not just characters - which opens the door to things like a native video pane, or a visual node-graph view of how panes and concepts connect, that a TUI can't touch (none of which I've done yet, but the thought is there). That reframed the 0.5.0 roadmap: stop trying to out-multiplex a mature multiplexer, and lean into the visual, Godot-native side instead.

## Where it's at now

gPTY today is a tiling-grid terminal emulator built on `alacritty_terminal` + `portable-pty` in Rust, rendered through Godot, with a CLI/MCP control surface and a concept engine for cross-pane automation. It's Apache 2.0, it's a solo hobby project, and it's still rough in plenty of places - a lot of my ecosystem and architecture knowledge got built *while* building this, not before, and that shows if you read the commits closely.

There's a native video pane and SSH support on the (seemingly never-ending) to-do list that haven't landed yet. If any of this sounds useful or interesting, the source over is at [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
