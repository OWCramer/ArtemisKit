// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

// stb_vorbis v1.22 (public domain, https://nothings.org/stb_vorbis/), vendored for Artemis
// games' Ogg Vorbis music, effects and voices, which iOS can't decode itself.
#pragma once

/// Decodes a whole Ogg Vorbis file to interleaved 16-bit PCM. Returns the number of frames
/// (or -1); `*output` is malloc'd and owned by the caller.
int stb_vorbis_decode_memory(const unsigned char *mem, int len, int *channels, int *sample_rate, short **output);
