# Harbor

Claude Code on an iPhone, as a native chat app. Harbor runs the **Windows ARM64
build of Claude Code** through an iOS port of **Wine** (from
[Madeira](https://github.com/willfaust/Madeira)), inside one app, and talks to
it over Claude Code's headless stream-json protocol.

- Native SwiftUI chat: streamed Markdown, command cards with live output,
  diffs for edits, compact rows for reads and searches, nested sub-agents, a
  pinned plan checklist, and a footer per turn with duration and cost.
- Claude's shell commands run in a native ARM64 busybox shell with Git for
  Windows (ARM64).
- Sign in once with your Claude subscription; sessions are saved and the last
  one reopens on launch.
- Diagnostics: JIT, memory, CPU per thread, thermal state, the running Windows
  processes and the log.

Install: see [docs/INSTALL.md](docs/INSTALL.md) (LiveContainer + JIT).

## Layout

| Path | What |
|---|---|
| `wine/` | Wine 11.4 iOS fork (submodule, Madeira's pin) |
| `build/` | Wine unix side for iOS (from Madeira), trimmed to a CLI; DLL farm builder |
| `app/Runtime/` | In-process Wine launcher, JIT pool, wineserver bridge |
| `app/Sources/` | SwiftUI app |
| `app/Packages/HarborKit/` | Protocol parser and chat state (unit-tested on Linux) |
| `tools/ci/` | CI scripts (native libs, farm, self-test, IPA) |

Claude Code itself is never bundled: the app downloads it on first run from
Anthropic's release server and verifies it against the release manifest.

## License

GPL-3.0-or-later (`LICENSE`), as Madeira, whose runtime code this builds on.
Wine (the `wine/` submodule and the files derived from it under `build/`) is
LGPL-2.1-or-later (`LICENSES/LGPL-2.1.txt`). Third-party Swift packages keep
their own licenses (ZIPFoundation: MIT; SwiftStreamingMarkdown: MIT).
