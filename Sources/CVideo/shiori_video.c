// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#include "shiori_video.h"

#include <stdlib.h>
#include <string.h>

#include <ogg/ogg.h>
#include <theora/theoradec.h>

struct ShioriTheora {
    unsigned char *data;
    size_t length;
    ogg_sync_state sync;
    ogg_stream_state stream;
    int has_stream;
    th_info info;
    th_comment comment;
    th_setup_info *setup;
    th_dec_ctx *decoder;
    /// A data packet read while looking for headers, decoded first.
    ogg_packet pending;
    int has_pending;
    th_ycbcr_buffer frame;
    int has_frame;
};

/// Next page from the in-memory file. 0 at the end.
static int next_page(ShioriTheora *v, ogg_page *page) {
    while (ogg_sync_pageout(&v->sync, page) != 1) {
        // Everything was handed over at start; nothing more to feed.
        return 0;
    }
    return 1;
}

/// Next packet of the Theora stream. 0 at the end.
static int next_packet(ShioriTheora *v, ogg_packet *packet) {
    for (;;) {
        if (v->has_stream && ogg_stream_packetout(&v->stream, packet) == 1) return 1;
        ogg_page page;
        if (!next_page(v, &page)) return 0;
        if (!v->has_stream) {
            if (!ogg_page_bos(&page)) continue;
            ogg_stream_init(&v->stream, ogg_page_serialno(&page));
            v->has_stream = 1;
        }
        // Pages of other streams (audio) don't belong to ours and are refused here.
        ogg_stream_pagein(&v->stream, &page);
    }
}

static void feed(ShioriTheora *v) {
    ogg_sync_init(&v->sync);
    char *buffer = ogg_sync_buffer(&v->sync, (long)v->length);
    memcpy(buffer, v->data, v->length);
    ogg_sync_wrote(&v->sync, (long)v->length);
}

/// Finds the Theora stream among the file's first pages and reads its three headers.
static int read_headers(ShioriTheora *v) {
    th_info_init(&v->info);
    th_comment_init(&v->comment);
    ogg_page page;
    // Beginning-of-stream pages come first; pick the one that starts a Theora stream.
    while (next_page(v, &page)) {
        if (!ogg_page_bos(&page)) break;
        ogg_stream_state candidate;
        ogg_stream_init(&candidate, ogg_page_serialno(&page));
        ogg_stream_pagein(&candidate, &page);
        ogg_packet packet;
        if (ogg_stream_packetout(&candidate, &packet) == 1 &&
            th_decode_headerin(&v->info, &v->comment, &v->setup, &packet) > 0) {
            v->stream = candidate;
            v->has_stream = 1;
            break;
        }
        ogg_stream_clear(&candidate);
    }
    if (!v->has_stream) return 0;
    for (;;) {
        ogg_packet packet;
        if (ogg_stream_packetout(&v->stream, &packet) != 1) {
            if (!next_page(v, &page)) return 0;
            ogg_stream_pagein(&v->stream, &page);
            continue;
        }
        int result = th_decode_headerin(&v->info, &v->comment, &v->setup, &packet);
        if (result < 0) return 0;
        if (result == 0) {
            // First video packet: headers are complete.
            v->pending = packet;
            v->has_pending = 1;
            return 1;
        }
    }
}

static int start(ShioriTheora *v) {
    feed(v);
    if (!read_headers(v)) return 0;
    if (v->info.pixel_fmt != TH_PF_420) return 0;
    v->decoder = th_decode_alloc(&v->info, v->setup);
    return v->decoder != NULL;
}

static void stop(ShioriTheora *v) {
    if (v->decoder) th_decode_free(v->decoder);
    v->decoder = NULL;
    if (v->setup) th_setup_free(v->setup);
    v->setup = NULL;
    th_comment_clear(&v->comment);
    th_info_clear(&v->info);
    if (v->has_stream) ogg_stream_clear(&v->stream);
    v->has_stream = 0;
    v->has_pending = 0;
    v->has_frame = 0;
    ogg_sync_clear(&v->sync);
}

ShioriTheora *shiori_theora_open(const unsigned char *data, size_t length) {
    ShioriTheora *v = calloc(1, sizeof *v);
    v->data = malloc(length ? length : 1);
    memcpy(v->data, data, length);
    v->length = length;
    if (!start(v)) {
        shiori_theora_close(v);
        return NULL;
    }
    return v;
}

void shiori_theora_close(ShioriTheora *v) {
    if (!v) return;
    stop(v);
    free(v->data);
    free(v);
}

int shiori_theora_width(const ShioriTheora *v) { return (int)v->info.pic_width; }
int shiori_theora_height(const ShioriTheora *v) { return (int)v->info.pic_height; }
double shiori_theora_fps(const ShioriTheora *v) {
    return v->info.fps_denominator ? (double)v->info.fps_numerator / v->info.fps_denominator : 30;
}

int shiori_theora_next(ShioriTheora *v, ShioriPlanes *planes) {
    for (;;) {
        ogg_packet packet;
        if (v->has_pending) {
            packet = v->pending;
            v->has_pending = 0;
        } else if (!next_packet(v, &packet)) {
            return 0;
        }
        ogg_int64_t granule;
        int result = th_decode_packetin(v->decoder, &packet, &granule);
        if (result == 0) {
            th_decode_ycbcr_out(v->decoder, v->frame);
            v->has_frame = 1;
        } else if (result == TH_DUPFRAME && v->has_frame) {
            // Same picture as the last frame.
        } else {
            continue;
        }
        int x = (int)v->info.pic_x, y = (int)v->info.pic_y;
        planes->y_stride = v->frame[0].stride;
        planes->c_stride = v->frame[1].stride;
        planes->y = v->frame[0].data + y * v->frame[0].stride + x;
        planes->cb = v->frame[1].data + (y / 2) * v->frame[1].stride + x / 2;
        planes->cr = v->frame[2].data + (y / 2) * v->frame[2].stride + x / 2;
        planes->width = (int)v->info.pic_width;
        planes->height = (int)v->info.pic_height;
        return 1;
    }
}

void shiori_theora_rewind(ShioriTheora *v) {
    stop(v);
    start(v);
}
