# CVideo

Video decoding for Artemis games.

- **libogg 1.3.5** (`ogg/`, `include/ogg/`) from https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz
  (SHA-256 0eb4b4b9420a0f51db142ba3f9c64b333f826532dc0f48c6410ae51f4799b664, matching Xiph's SHA256SUMS).
  BSD-3-Clause, see `ogg/COPYING`. Only `bitwise.c` and `framing.c`; `config_types.h` is written by hand.
- **libtheora 1.2.0** (`theora/`, `include/theora/`) from https://downloads.xiph.org/releases/theora/libtheora-1.2.0.tar.gz
  (SHA-256 279327339903b544c28a92aeada7d0dcfd0397b59c2f368cc698ac56f515906e, matching Xiph's SHA256SUMS).
  BSD-3-Clause, see `theora/COPYING`. Only the decoder's C sources, no assembly.
- **pl_mpeg** (`mpeg/pl_mpeg.h`) from https://github.com/phoboslab/pl_mpeg at commit
  c871f2be022ece7ef4f64230b4fb8e1fb9eb6023 (SHA-256 3a8cb30c83c2a1147719c30fe0c8b93da2987aa43140077c575b39aaa75fc2c9).
  MIT (in the header). MPEG-1 video and MP2 audio.

All unmodified. `shiori_video.c` is Shiori's wrapper over libtheora.
