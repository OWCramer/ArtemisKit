# ArtemisKit

Shiori's Artemis engine: an interpreter for Artemis Engine games written in Swift, with Lua 5.1 for the engine's scripts, Metal rendering, Ogg Vorbis audio and Ogg Theora / MPEG-1 movies. Part of [Shiori](https://github.com/OWCramer/shiori).

It plays games you own; no game content is included.

- `Sources/ArtemisKit`: archives (pf6, pf8), scripts, the interpreter, renderer and player.
- `Sources/CLua`, `CVorbis`, `CVideo`: vendored Lua 5.1.5, stb_vorbis, libogg, libtheora and pl_mpeg.
- `artemis-cli`: lists, extracts and inventories a game's archives on the Mac.
- `docs/`: notes on the engine and its tags.

```sh
swift build
swift test
swift run artemis-cli
```

## Licence

ArtemisKit's own code is under the [Mozilla Public License 2.0](LICENSE). Vendored code keeps its licence, beside it: Lua (MIT, `Sources/CLua/COPYRIGHT`), stb_vorbis (public domain / MIT), libogg and libtheora (BSD-3, `COPYING`), pl_mpeg (MIT).
