#include "usb_camera.h"

#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#define LO16(n) ((n) & 255), (((n) >> 8) & 255)
#define LO32(n) LO16(n), LO16((n) >> 16)
#define INTERVAL_30 333333u
#define INTERVAL_15 666666u

static const uint8_t device[] = {
    18, 1, 0, 2, 0xef, 2, 1, 64,
    0x09, 0x12, 0x48, 0x48, 0, 1, 1, 2, 3, 1
};
/* Configuration = 9 + IAD 8 + VC interface 9 + VC header 13 + camera
   terminal 18 + output terminal 9 + VS interface 9 + input header 14 +
   YUY2 format 27 + frame 34 + color matching 6 + bulk endpoint 7 = 163.
   Photo Booth needs the 30 fps mode to start; browsers may select 15 fps. */
static const uint8_t configuration[] = {
    9, 2, LO16(163), 2, 1, 0, 0x80, 1,
    8, 11, 0, 2, 14, 3, 0, 2,
    9, 4, 0, 0, 0, 14, 1, 0, 0,
    13, 0x24, 1, 0x10, 1, LO16(40), LO32(90000), 1, 1,
    18, 0x24, 2, 1, LO16(0x0201), 0, 0, LO16(0), LO16(0), LO16(0), 3, 0, 0, 0,
    9, 0x24, 3, 2, LO16(0x0101), 0, 1, 0,
    9, 4, 1, 0, 1, 14, 2, 0, 0,
    14, 0x24, 1, 1, LO16(81), 0x81, 0, 2, 0, 0, 0, 1, 0,
    27, 0x24, 4, 1, 1,
    'Y', 'U', 'Y', '2', 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71,
    16, 1, 0, 0, 0, 0,
    34, 0x24, 5, 1, 0, LO16(HV_CAMERA_WIDTH), LO16(HV_CAMERA_HEIGHT),
    LO32(HV_CAMERA_FRAME_BYTES * 8 * 15), LO32(HV_CAMERA_FRAME_BYTES * 8 * 30),
    LO32(HV_CAMERA_FRAME_BYTES), LO32(INTERVAL_30), 2, LO32(INTERVAL_30), LO32(INTERVAL_15),
    6, 0x24, 13, 1, 1, 4,
    7, 5, 0x81, 2, LO16(512), 0
};
_Static_assert(sizeof configuration == 163, "UVC configuration length");

static uint16_t get16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t get32(const uint8_t *p) { return get16(p) | (uint32_t)get16(p + 2) << 16; }
static void put32(uint8_t *p, uint32_t v) {
    for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i));
}

static unsigned frame_capacity(HvUsbCamera *c) { return c->width * c->height * 2; }

static void defaults(HvUsbCamera *c, uint8_t p[HV_CAMERA_PROBE_BYTES]) {
    memset(p, 0, HV_CAMERA_PROBE_BYTES);
    p[0] = 1; /* fixed frame interval */
    p[2] = p[3] = 1;
    put32(p + 4, INTERVAL_30);
    put32(p + 18, frame_capacity(c));
    put32(p + 22, HV_CAMERA_PAYLOAD);
    put32(p + 26, 90000);
    p[30] = 3; /* FID and EOF payload headers */
    p[31] = p[32] = p[33] = 1;
}

static void black(uint8_t *frame) {
    for (size_t i = 0; i < HV_CAMERA_FRAME_BYTES; i += 4) {
        frame[i] = frame[i + 2] = 16;
        frame[i + 1] = frame[i + 3] = 128;
    }
}

static void reset_locked(HvUsbCamera *c) {
    c->configured = c->committed = c->fid = 0;
    c->next_frame_ns = c->last_read_ns = 0;
    c->error = 0;
    defaults(c, c->probe);
    defaults(c, c->commit);
    if (!c->profile) {
        black(c->latest); black(c->frame);
        c->latest_len = c->frame_len = HV_CAMERA_FRAME_BYTES;
    } else {
        memcpy(c->latest, c->black_jpeg, c->black_len);
        memcpy(c->frame, c->black_jpeg, c->black_len);
        c->latest_len = c->frame_len = c->black_len;
    }
    c->offset = c->frame_len;
}

void hv_usb_camera_reset(HvUsbCamera *c) {
    pthread_mutex_lock(&c->mu);
    reset_locked(c);
    pthread_mutex_unlock(&c->mu);
}

void hv_usb_camera_resume(HvUsbCamera *c) {
    pthread_mutex_lock(&c->mu);
    c->enabled = 0;
    c->next_frame_ns = c->last_read_ns = 0;
    memset(c->latest, 0, sizeof c->latest);
    memset(c->frame, 0, sizeof c->frame);
    if (c->profile) {
        memcpy(c->latest, c->black_jpeg, c->black_len);
        c->latest_len = c->black_len;
    } else {
        black(c->latest);
        c->latest_len = HV_CAMERA_FRAME_BYTES;
    }
    c->frame_len = c->offset = 0; /* next transfer starts a new FID */
    pthread_mutex_unlock(&c->mu);
}

void hv_usb_camera_init(HvUsbCamera *c) {
    memset(c, 0, sizeof *c);
    c->width = HV_CAMERA_WIDTH; c->height = HV_CAMERA_HEIGHT;
    pthread_mutex_init(&c->mu, NULL);
    hv_usb_camera_reset(c);
}
void hv_usb_camera_destroy(HvUsbCamera *c) { pthread_mutex_destroy(&c->mu); }

static size_t configuration_descriptor(HvUsbCamera *c, uint8_t *out) {
    if (!c->profile) { memcpy(out, configuration, sizeof configuration); return sizeof configuration; }
    /* MJPEG's format descriptor is 11 bytes instead of YUY2's 27. The
       frame descriptor keeps the same two discrete frame intervals. */
    memcpy(out, configuration, 89);
    out[2] = 147; out[3] = 0;
    out[79] = 65; out[80] = 0; /* VS class-specific total */
    const uint8_t format[] = {11, 0x24, 6, 1, 1, 0, 1, 0, 0, 0, 0};
    memcpy(out + 89, format, sizeof format);
    uint8_t *f = out + 100;
    memcpy(f, configuration + 116, 34);
    f[2] = 7;
    f[5] = c->width & 255; f[6] = c->width >> 8;
    f[7] = c->height & 255; f[8] = c->height >> 8;
    put32(f + 9, c->width * c->height * 15 / 2);
    put32(f + 13, 400000000); /* conservative compressed-stream bound */
    put32(f + 17, frame_capacity(c));
    memcpy(out + 134, configuration + 150, 13);
    return 147;
}

static int reply(uint8_t *out, size_t capacity, uint16_t requested, const void *data, size_t len) {
    if (len > capacity) len = capacity;
    if (len > requested) len = requested;
    if (len) memcpy(out, data, len);
    return (int)len;
}

int hv_usb_camera_control(HvUsbCamera *c, const uint8_t s[8], uint8_t *out, size_t capacity) {
    uint8_t type = s[0], request = s[1], selector = s[3];
    uint16_t value = get16(s + 2), index = get16(s + 4), len = get16(s + 6);
    uint8_t tmp[128] = {0};
    int result = -1;
    pthread_mutex_lock(&c->mu);
    if (type == 0x80 && request == 6) {
        if (selector == 1) {
            uint8_t d[sizeof device]; memcpy(d, device, sizeof d);
            d[10] += c->profile; /* stable identity per resolution, separate cached formats */
            result = reply(out, capacity, len, d, sizeof d);
        }
        else if (selector == 2 || selector == 7) {
            uint8_t config[sizeof configuration];
            size_t count = configuration_descriptor(c, config);
            config[1] = selector;
            result = reply(out, capacity, len, config, count);
        } else if (selector == 6) {
            const uint8_t qualifier[] = {10, 6, 0, 2, 0xef, 2, 1, 64, 1, 0};
            result = reply(out, capacity, len, qualifier, sizeof qualifier);
        } else if (selector == 3) {
            unsigned id = value & 255;
            if (!id) { const uint8_t lang[] = {4, 3, 9, 4}; result = reply(out, capacity, len, lang, 4); }
            else if (id <= 3) {
                const char *names[] = {"", "Henge", "Henge Camera", "henge-camera-1"};
                size_t n = strlen(names[id]);
                tmp[0] = (uint8_t)(n * 2 + 2); tmp[1] = 3;
                for (size_t i = 0; i < n; i++) tmp[2 + 2 * i] = (uint8_t)names[id][i];
                result = reply(out, capacity, len, tmp, tmp[0]);
            }
        }
    } else if ((type == 0x80 || type == 0x81 || type == 0x82) && request == 0) {
        result = reply(out, capacity, len, tmp, 2);
    } else if (type == 0x80 && request == 8) {
        tmp[0] = (uint8_t)c->configured;
        result = reply(out, capacity, len, tmp, 1);
    } else if (type == 0 && request == 5 && value <= 127 && !len) result = 0;
    else if (type == 0 && request == 9 && value <= 1 && !len) {
        c->configured = value;
        c->committed = 0;
        c->offset = c->frame_len;
        c->last_read_ns = 0;
        result = 0;
    } else if (type == 0x81 && request == 10 && index <= 1) {
        result = reply(out, capacity, len, tmp, 1);
    } else if (type == 1 && request == 11 && index <= 1 && !value && !len) result = 0;
    else if (type == 2 && request == 1 && value == 0 && index == 0x81 && !len) result = 0;
    else if ((type == 0xa1 || type == 0x21) && index == 1 && (selector == 1 || selector == 2)) {
        uint8_t *p = selector == 1 ? c->probe : c->commit;
        if (type == 0x21 && request == 1 && (len == 26 || len == 34)) result = 0;
        else if (type == 0xa1) {
            if (request == 0x85) { tmp[0] = HV_CAMERA_PROBE_BYTES; result = reply(out, capacity, len, tmp, 2); }
            else if (request == 0x86) { tmp[0] = 3; result = reply(out, capacity, len, tmp, 1); }
            else if (request == 0x81) result = reply(out, capacity, len, p, HV_CAMERA_PROBE_BYTES);
            else if (request >= 0x82 && request <= 0x84) {
                defaults(c, tmp);
                if (request == 0x83) put32(tmp + 4, INTERVAL_15); /* maximum frame interval */
                if (request == 0x84) memset(tmp, 0, HV_CAMERA_PROBE_BYTES);
                result = reply(out, capacity, len, tmp, HV_CAMERA_PROBE_BYTES);
            } else if (request == 0x87) { defaults(c, tmp); result = reply(out, capacity, len, tmp, HV_CAMERA_PROBE_BYTES); }
        }
    } else if (type == 0xa1 && index == 0 && selector == 2 && request == 0x81) {
        tmp[0] = c->error; c->error = 0;
        result = reply(out, capacity, len, tmp, 1);
    }
    if (result < 0) c->error = 6; /* invalid control */
    /* Control traffic is infrequent and carries no images. Keep the complete
       handshake in device logs, including failures before PROBE/COMMIT. */
    fprintf(stderr, "uvc: control %02x %02x value %04x index %04x length %u -> %d\n",
            type, request, value, index, len, result);
    pthread_mutex_unlock(&c->mu);
    return result;
}

int hv_usb_camera_control_out(HvUsbCamera *c, const uint8_t s[8], const uint8_t *data, size_t len) {
    if (s[0] != 0x21 || s[1] != 1 || get16(s + 4) != 1 || (s[3] != 1 && s[3] != 2) ||
        (len != 26 && len != 34) || len != get16(s + 6)) return -1;
    pthread_mutex_lock(&c->mu);
    int result = 0;
    if (!c->configured || data[2] > 1 || data[3] > 1) { c->error = 4; result = -1; }
    else {
        /* PROBE rounds to the supported frame intervals. COMMIT uses the
           result, with a bounded payload even for a malformed request. */
        uint8_t *p = s[3] == 1 ? c->probe : c->commit;
        defaults(c, p);
        uint32_t interval = get32(data + 4);
        put32(p + 4, interval > (INTERVAL_30 + INTERVAL_15) / 2 ? INTERVAL_15 : INTERVAL_30);
        uint32_t payload = get32(data + 22);
        if (payload >= 512 && payload < HV_CAMERA_PAYLOAD) put32(p + 22, payload);
        if (s[3] == 2) {
            c->committed = 1;
            c->offset = c->frame_len;
            c->next_frame_ns = c->last_read_ns = 0;
            fprintf(stderr, "uvc: committed %ux%u %s at %u fps, payload %u\n",
                    c->width, c->height, c->profile ? "MJPEG" : "YUY2", get32(p + 4) == INTERVAL_15 ? 15 : 30, get32(p + 22));
        }
    }
    pthread_mutex_unlock(&c->mu);
    if (s[3] == 2 || result || getenv("HV_UVC_LOG"))
        fprintf(stderr, "uvc: SET_CUR selector %u length %zu -> %d\n", s[3], len, result);
    return result;
}

size_t hv_usb_camera_read(HvUsbCamera *c, void *output, size_t capacity, uint64_t now) {
    if (capacity < 7) return 0;
    pthread_mutex_lock(&c->mu);
    size_t n = 0;
    if (!c->configured || !c->committed) goto done;
    c->last_read_ns = now;
    if (c->offset == c->frame_len) {
        if (now < c->next_frame_ns) goto done;
        c->next_frame_ns = now + (uint64_t)get32(c->commit + 4) * 100;
        memcpy(c->frame, c->latest, c->latest_len);
        c->frame_len = c->latest_len;
        c->offset = 0;
        c->fid ^= 1;
        c->pts = (uint32_t)(now / 1000 * 9 / 100);
        c->frames++;
    }
    size_t payload = get32(c->commit + 22);
    if (capacity > payload) capacity = payload;
    n = c->frame_len - c->offset;
    if (n > capacity - 6) n = capacity - 6;
    uint8_t *out = output;
    out[0] = 6;
    out[1] = (uint8_t)(0x84 | c->fid | (n == c->frame_len - c->offset ? 2 : 0));
    put32(out + 2, c->pts);
    memcpy(out + 6, c->frame + c->offset, n);
    c->offset += (uint32_t)n;
    n += 6;
done:
    pthread_mutex_unlock(&c->mu);
    return n;
}

void hv_usb_camera_enable(HvUsbCamera *c, int enabled) {
    pthread_mutex_lock(&c->mu);
    c->enabled = !!enabled;
    if (!enabled) {
        if (c->profile) { memcpy(c->latest, c->black_jpeg, c->black_len); c->latest_len = c->black_len; }
        else { black(c->latest); c->latest_len = HV_CAMERA_FRAME_BYTES; }
        c->offset = c->frame_len; /* discard a partial image; next FID is black */
    }
    pthread_mutex_unlock(&c->mu);
}

int hv_usb_camera_requested(HvUsbCamera *c, uint64_t now) {
    pthread_mutex_lock(&c->mu);
    /* The caller samples the clock before taking this mutex. A CPU read can
       update last_read_ns while it waits, so a newer timestamp is fresh too. */
    int requested = c->configured && c->committed && c->last_read_ns &&
        (now <= c->last_read_ns || now - c->last_read_ns < 1000000000ull);
    pthread_mutex_unlock(&c->mu);
    return requested;
}

unsigned hv_usb_camera_frame_rate(HvUsbCamera *c) {
    pthread_mutex_lock(&c->mu);
    unsigned rate = get32(c->commit + 4) == INTERVAL_15 ? 15 : 30;
    pthread_mutex_unlock(&c->mu);
    return rate;
}

int hv_usb_camera_set_profile(HvUsbCamera *c, unsigned profile, const uint8_t *jpeg, size_t len) {
    if (profile > 2 || (profile && (!jpeg || len < 4 || len > HV_CAMERA_BLACK_BYTES ||
        jpeg[0] != 0xff || jpeg[1] != 0xd8 || jpeg[len - 2] != 0xff || jpeg[len - 1] != 0xd9))) return -1;
    pthread_mutex_lock(&c->mu);
    c->requested_profile = profile;
    c->requested_black_len = profile ? (uint32_t)len : 0;
    if (profile) memcpy(c->requested_black, jpeg, len);
    pthread_mutex_unlock(&c->mu);
    return 0;
}

int hv_usb_camera_apply_profile(HvUsbCamera *c) {
    pthread_mutex_lock(&c->mu);
    int changed = c->profile != c->requested_profile;
    if (changed) {
        static const unsigned widths[] = {640, 1280, 1920}, heights[] = {480, 720, 1080};
        c->profile = c->requested_profile;
        c->width = widths[c->profile]; c->height = heights[c->profile];
        c->black_len = c->requested_black_len;
        memcpy(c->black_jpeg, c->requested_black, c->black_len);
        reset_locked(c);
    }
    pthread_mutex_unlock(&c->mu);
    return changed;
}

unsigned hv_usb_camera_profile(HvUsbCamera *c) {
    pthread_mutex_lock(&c->mu);
    unsigned profile = c->profile;
    pthread_mutex_unlock(&c->mu);
    return profile;
}

void hv_usb_camera_jpeg(HvUsbCamera *c, const uint8_t *jpeg, size_t len, unsigned profile) {
    if (!jpeg || len < 4 || len > HV_CAMERA_MAX_FRAME_BYTES || jpeg[0] != 0xff || jpeg[1] != 0xd8 ||
        jpeg[len - 2] != 0xff || jpeg[len - 1] != 0xd9) return;
    pthread_mutex_lock(&c->mu);
    if (c->enabled && c->profile && c->profile == profile && len <= frame_capacity(c)) {
        memcpy(c->latest, jpeg, len);
        c->latest_len = (uint32_t)len;
    }
    pthread_mutex_unlock(&c->mu);
}

void hv_usb_camera_nv12(HvUsbCamera *c, const uint8_t *y, size_t ys, const uint8_t *uv, size_t uvs,
                        unsigned width, unsigned height, int mirrored) {
    if (!y || !uv || width < 2 || height < 2 || width > 8192 || height > 8192 ||
        width % 2 || height % 2 || ys < width || uvs < width) return;
    pthread_mutex_lock(&c->mu);
    if (!c->enabled || c->profile) { pthread_mutex_unlock(&c->mu); return; }
    unsigned dw = HV_CAMERA_WIDTH, dh = HV_CAMERA_HEIGHT;
    if ((uint64_t)width * dh > (uint64_t)height * dw) dh = (unsigned)((uint64_t)height * dw / width) & ~1u;
    else dw = (unsigned)((uint64_t)width * dh / height) & ~1u;
    if (!dw || !dh) { pthread_mutex_unlock(&c->mu); return; }
    unsigned left = ((HV_CAMERA_WIDTH - dw) / 2) & ~1u, top = (HV_CAMERA_HEIGHT - dh) / 2;
    black(c->latest);
    for (unsigned row = 0; row < dh; row++) {
        unsigned sy = (unsigned)((uint64_t)row * height / dh);
        uint8_t *out = c->latest + ((top + row) * HV_CAMERA_WIDTH + left) * 2;
        for (unsigned col = 0; col < dw; col += 2) {
            unsigned sx = (unsigned)((uint64_t)col * width / dw);
            unsigned sx2 = (unsigned)((uint64_t)(col + 1) * width / dw);
            if (mirrored) { sx = width - 1 - sx; sx2 = width - 1 - sx2; }
            unsigned chroma = sx & ~1u;
            *out++ = y[sy * ys + sx];
            *out++ = uv[(sy / 2) * uvs + chroma];
            *out++ = y[sy * ys + sx2];
            *out++ = uv[(sy / 2) * uvs + chroma + 1];
        }
    }
    pthread_mutex_unlock(&c->mu);
}
