// Shiori's video decoding for Artemis games: Ogg Theora (video layers) through libtheora,
// and MPEG-1 (full-screen movies) through pl_mpeg, whose API Swift calls directly.
#pragma once
#include <stddef.h>
#include <stdio.h>
// pl_mpeg uses FILE without including stdio.h itself.
#include "../mpeg/pl_mpeg.h"

/// One decoded frame, YCbCr 4:2:0, pointers already offset to the picture region.
typedef struct ShioriPlanes {
    const unsigned char *y, *cb, *cr;
    int y_stride, c_stride;
    int width, height;
} ShioriPlanes;

typedef struct ShioriTheora ShioriTheora;

/// Reads the Theora headers from an Ogg file held in memory (copied). NULL if there's no
/// Theora stream or it isn't 4:2:0.
ShioriTheora *shiori_theora_open(const unsigned char *data, size_t length);
void shiori_theora_close(ShioriTheora *video);
int shiori_theora_width(const ShioriTheora *video);
int shiori_theora_height(const ShioriTheora *video);
double shiori_theora_fps(const ShioriTheora *video);
/// Decodes the next frame into `planes` (valid until the next call). 0 at the end.
int shiori_theora_next(ShioriTheora *video, ShioriPlanes *planes);
/// Back to the first frame.
void shiori_theora_rewind(ShioriTheora *video);
