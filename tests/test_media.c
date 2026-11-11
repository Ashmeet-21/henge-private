#include "machine.h"
#include "gicv3.h"
#include "pcie.h"
#include "virtio_snd.h"
#include "xhci.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static HvMachine machine;
static uint8_t *memory;
static int checks, failures;
#define RAM 0x80000000ull
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); failures++; } } while (0)
static uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
static void *at(uint64_t pa) { return memory + (pa - RAM); }
static uint32_t u32(const void *p) { uint32_t n; memcpy(&n, p, 4); return n; }
static uint16_t u16(const void *p) { uint16_t n; memcpy(&n, p, 2); return n; }
static void put(uint64_t pa, uint64_t value, unsigned size) { memcpy(at(pa), &value, size); }
struct Desc { uint64_t address; uint32_t length; uint16_t flags, next; };

static void queue(HvVirtio *v, unsigned q) {
    uint64_t base = RAM + q * 0x4000;
    v->q[q].size = 16;
    v->q[q].enabled = 1;
    v->q[q].desc = base;
    v->q[q].avail = base + 0x1000;
    v->q[q].used = base + 0x2000;
}
static void post(HvVirtio *v, unsigned q, const struct Desc *desc, unsigned count) {
    HvVirtq *vq = &v->q[q];
    memcpy(at(vq->desc), desc, count * sizeof *desc);
    uint16_t n = u16(at(vq->avail + 2));
    put(vq->avail + 4 + 2 * (n % 16), 0, 2);
    put(vq->avail + 2, n + 1, 2);
    v->notify(v, (int)q);
}
static uint32_t command(HvVirtioSnd *s, uint32_t code, unsigned stream, unsigned format) {
    const uint64_t request = RAM + 0x18000, response = RAM + 0x19000;
    uint8_t req[32] = {0};
    memcpy(req, &code, 4); memcpy(req + 4, &stream, 4);
    unsigned size = 8;
    if (code == 0x100 || code == 0x200) {
        uint32_t n = 2, item = code == 0x100 ? 32 : 24;
        memcpy(req + 8, &n, 4); memcpy(req + 12, &item, 4); size = 16;
    } else if (code == 0x101) {
        uint32_t buffer = 3840, period = 960;
        memcpy(req + 8, &buffer, 4); memcpy(req + 12, &period, 4);
        req[20] = 1; req[21] = (uint8_t)format; req[22] = HV_VSND_RATE_48000; size = 24;
    }
    memcpy(at(request), req, size);
    memset(at(response), 0xcc, 128);
    struct Desc d[] = {{request, size, 1, 1}, {response, 128, 2, 0}};
    post(&s->vio, 0, d, 2);
    return u32(at(response));
}
static void capture(HvVirtioSnd *s, unsigned bytes) {
    put(RAM + 0x20000, 1, 4);
    memset(at(RAM + 0x21000), 0xa5, bytes + 8);
    struct Desc d[] = {{RAM + 0x20000, 4, 1, 1}, {RAM + 0x21000, bytes, 3, 2}, {RAM + 0x21000 + bytes, 8, 2, 0}};
    post(&s->vio, 3, d, 3);
}
static void sound_test(HvPcie *pci) {
    HvVirtioSnd *s = hv_virtio_snd_create(&machine, pci);
    CHECK(s != NULL);
    queue(&s->vio, 0); queue(&s->vio, 2); queue(&s->vio, 3);
    s->vio.status = 15;
    CHECK(u32(s->vio.config + 4) == 2);
    CHECK(command(s, 0x100, 0, 0) == 0x8000);
    const uint8_t *info = at(RAM + 0x19000 + 4);
    CHECK(info[24] == 0 && info[32 + 24] == 1 && info[32 + 26] == 1);
    CHECK(command(s, 0x200, 0, 0) == 0x8000);
    info = at(RAM + 0x19000 + 4);
    CHECK(info[4] == 0 && info[24 + 4] == 1 && info[24 + 5] == 1);
    for (unsigned f = 0; f < 3; f++) {
        const unsigned formats[] = {HV_VSND_FMT_S16, HV_VSND_FMT_S32, HV_VSND_FMT_FLOAT};
        unsigned format = formats[f], bytes = format == HV_VSND_FMT_S16 ? 2 : 4;
        CHECK(command(s, 0x101, 1, format) == 0x8000);
        CHECK(command(s, 0x102, 1, 0) == 0x8000);
        hv_virtio_snd_capture_enable(s, 1);
        CHECK(command(s, 0x104, 1, 0) == 0x8000);
        CHECK(hv_virtio_snd_capture_requested(s));
        unsigned used = u16(at(s->vio.q[3].used + 2));
        capture(s, 480 * bytes);
        CHECK(u16(at(s->vio.q[3].used + 2)) == used); /* no early/empty period */
        float samples[480];
        for (unsigned i = 0; i < 480; i++) samples[i] = 0.5f;
        samples[0] = -1; samples[1] = 1; samples[2] = NAN;
        hv_virtio_snd_capture_push(s, samples, 480);
        hv_virtio_snd_capture_push(s, samples, 480); /* prime the input jitter buffer */
        s->capture.start_ns = now_ns() - 20000000;
        hv_virtio_snd_poll(s);
        CHECK(u16(at(s->vio.q[3].used + 2)) == used + 1);
        CHECK(u32(at(RAM + 0x21000 + 480 * bytes)) == 0x8000);
        if (bytes == 2) {
            int16_t *pcm = at(RAM + 0x21000);
            CHECK(pcm[0] == INT16_MIN && pcm[1] == INT16_MAX && pcm[2] == 0 && pcm[3] == 16383);
        } else if (format == HV_VSND_FMT_FLOAT) {
            float *pcm = at(RAM + 0x21000);
            CHECK(pcm[0] == -1 && pcm[1] == 1 && pcm[2] == 0 && pcm[3] == 0.5f);
        } else {
            int32_t *pcm = at(RAM + 0x21000);
            CHECK(pcm[0] == INT32_MIN && pcm[1] == INT32_MAX && pcm[2] == 0 && pcm[3] == 1073741823);
        }
        hv_virtio_snd_capture_enable(s, 0);
        hv_virtio_snd_capture_push(s, samples, 480);
        capture(s, 480 * bytes);
        s->capture.start_ns = now_ns() - 40000000;
        hv_virtio_snd_poll(s);
        const uint8_t *zero = at(RAM + 0x21000);
        int silent = 1;
        for (unsigned i = 0; i < 480 * bytes; i++) if (zero[i]) silent = 0;
        CHECK(silent);
        CHECK(command(s, 0x105, 1, 0) == 0x8000);
        CHECK(!hv_virtio_snd_capture_requested(s));
        CHECK(command(s, 0x103, 1, 0) == 0x8000);
    }
    /* Host taps arrive in blocks, while guest periods keep a stable clock.
       A one-block reserve bridges their boundaries without splicing silence. */
    CHECK(command(s, 0x101, 1, HV_VSND_FMT_FLOAT) == 0x8000);
    CHECK(command(s, 0x102, 1, 0) == 0x8000);
    CHECK(command(s, 0x104, 1, 0) == 0x8000);
    hv_virtio_snd_capture_enable(s, 1);
    unsigned used = u16(at(s->vio.q[3].used + 2));
    capture(s, 960 * 4);
    float blocks[960];
    for (unsigned i = 0; i < 960; i++) blocks[i] = 0.25f * sinf((float)i * 0.057595865f);
    uint64_t epoch = s->capture.start_ns;
    hv_virtio_snd_capture_push(s, blocks, 480);
    hv_virtio_snd_capture_push(s, blocks + 480, 480);
    CHECK(s->capture.start_ns == epoch); /* callbacks cannot move the guest clock */
    s->capture.start_ns = now_ns() - 10000000;
    hv_virtio_snd_poll(s);
    CHECK(u16(at(s->vio.q[3].used + 2)) == used);
    CHECK(s->capture.offset == 480 * 4);
    hv_virtio_snd_capture_push(s, blocks, 480);
    s->capture.start_ns = now_ns() - 20000000;
    hv_virtio_snd_poll(s);
    CHECK(u16(at(s->vio.q[3].used + 2)) == used + 1);
    CHECK(!memcmp(at(RAM + 0x21000), blocks, sizeof blocks));
    /* An available block must not make the next period complete early. */
    capture(s, 480 * 4);
    CHECK(u16(at(s->vio.q[3].used + 2)) == used + 1);
    s->capture.start_ns = now_ns() - 30000000;
    hv_virtio_snd_poll(s);
    CHECK(u16(at(s->vio.q[3].used + 2)) == used + 2);
    CHECK(!memcmp(at(RAM + 0x21000), blocks, 480 * 4));
    /* A failed source supplies paced silence, and fresh audio can re-prime. */
    s->capture.start_ns = now_ns() - 40000000;
    capture(s, 480 * 4);
    CHECK(u16(at(s->vio.q[3].used + 2)) == used + 3);
    const float *silence = at(RAM + 0x21000);
    int all_zero = 1;
    for (unsigned i = 0; i < 480; i++) if (silence[i] != 0) all_zero = 0;
    CHECK(all_zero);
    hv_virtio_snd_capture_push(s, blocks, 480);
    hv_virtio_snd_capture_push(s, blocks + 480, 1);
    hv_virtio_snd_poll(s);
    CHECK(!s->capture.source_active && s->capture.input_block_frames == 480);
    hv_virtio_snd_capture_push(s, blocks + 481, 479);
    capture(s, 480 * 4);
    CHECK(u16(at(s->vio.q[3].used + 2)) == used + 3);
    s->capture.start_ns = now_ns() - 50000000;
    hv_virtio_snd_poll(s);
    CHECK(u16(at(s->vio.q[3].used + 2)) == used + 4);
    CHECK(!memcmp(at(RAM + 0x21000), blocks, 480 * 4));
    CHECK(command(s, 0x105, 1, 0) == 0x8000);
    CHECK(command(s, 0x103, 1, 0) == 0x8000);
    /* Output still transfers and completes only after playback consumes PCM. */
    CHECK(command(s, 0x101, 0, HV_VSND_FMT_S16) == 0x8000);
    CHECK(command(s, 0x102, 0, 0) == 0x8000);
    CHECK(command(s, 0x104, 0, 0) == 0x8000);
    uint8_t tx[36] = {0}, played[32];
    for (unsigned i = 4; i < sizeof tx; i++) tx[i] = (uint8_t)i;
    memcpy(at(RAM + 0x22000), tx, sizeof tx);
    struct Desc out[] = {{RAM + 0x22000, sizeof tx, 1, 1}, {RAM + 0x23000, 8, 2, 0}};
    post(&s->vio, 2, out, 2);
    CHECK(hv_virtio_snd_pull(s, played, sizeof played) == sizeof played);
    CHECK(!memcmp(played, tx + 4, sizeof played));
    hv_virtio_snd_poll(s);
    CHECK(u16(at(s->vio.q[2].used + 2)) == 1);
    CHECK(command(s, 0x101, 1, HV_VSND_FMT_FLOAT) == 0x8000);
    CHECK(command(s, 0x102, 1, 0) == 0x8000);
    CHECK(command(s, 0x104, 1, 0) == 0x8000);
    hv_virtio_snd_capture_enable(s, 1);
    float *overflow = calloc(HV_VSND_CAPTURE_FRAMES + 128, sizeof(float));
    hv_virtio_snd_capture_push(s, overflow, HV_VSND_CAPTURE_FRAMES + 128);
    CHECK(s->capture.written - s->capture.consumed == HV_VSND_CAPTURE_FRAMES);
    hv_virtio_snd_capture_push(s, overflow, 128);
    CHECK(s->capture.written - s->capture.consumed == HV_VSND_CAPTURE_FRAMES);
    free(overflow);
    capture(s, 1920);
    CHECK(command(s, 0x105, 1, 0) == 0x8000);
    CHECK(s->capture.head == s->capture.tail);
    CHECK(u32(at(RAM + 0x21000 + 1920)) == 0x8000);
    CHECK(command(s, 0x104, 1, 0) == 0x8000);
    s->vio.pci.bar_write(&s->vio.pci, 4, 0x14, 0, 1);
    CHECK(!s->capture.running && s->capture.head == s->capture.tail && !s->running);
    hv_virtio_snd_destroy(s);
}

static void camera_test(void) {
    HvUsbCamera *c = calloc(1, sizeof *c);
    hv_usb_camera_init(c);
    uint8_t reply[512];
    uint8_t descriptor[] = {0x80, 6, 0, 2, 0, 0, 255, 1};
    int length = hv_usb_camera_control(c, descriptor, reply, sizeof reply);
    CHECK(length == 163 && u16(reply + 2) == length);
    unsigned offset = 0, interfaces = 0;
    while (offset < (unsigned)length && reply[offset] >= 2) {
        if (reply[offset + 1] == 4) interfaces++;
        if (reply[offset + 1] == 0x24 && reply[offset + 2] == 5) {
            CHECK(reply[offset] == 34 && reply[offset + 25] == 2);
            CHECK(u32(reply + offset + 21) == 333333);
            CHECK(u32(reply + offset + 26) == 333333 && u32(reply + offset + 30) == 666666);
        }
        offset += reply[offset];
    }
    CHECK(offset == (unsigned)length && interfaces == 2);
    uint8_t config[] = {0, 9, 1, 0, 0, 0, 0, 0};
    CHECK(hv_usb_camera_control(c, config, reply, sizeof reply) == 0);
    uint8_t get[] = {0xa1, 0x87, 0, 1, 1, 0, 34, 0};
    get[1] = 0x82;
    CHECK(hv_usb_camera_control(c, get, reply, sizeof reply) == 34 && u32(reply + 4) == 333333);
    get[1] = 0x83;
    CHECK(hv_usb_camera_control(c, get, reply, sizeof reply) == 34 && u32(reply + 4) == 666666);
    get[1] = 0x87;
    CHECK(hv_usb_camera_control(c, get, reply, sizeof reply) == 34);
    CHECK(reply[2] == 1 && reply[3] == 1 && u32(reply + 18) == HV_CAMERA_FRAME_BYTES && u32(reply + 4) == 333333);
    uint8_t commit[] = {0x21, 1, 0, 2, 1, 0, 34, 0};
    CHECK(hv_usb_camera_control_out(c, commit, reply, 33) == -1);
    CHECK(hv_usb_camera_control_out(c, commit, reply, 34) == 0);
    CHECK(hv_usb_camera_frame_rate(c) == 30);
    uint8_t y[72] = {0}, uv[36] = {0};
    for (unsigned row = 0; row < 6; row++) memset(y + row * 12, 90, 8);
    for (unsigned row = 0; row < 3; row++) for (unsigned col = 0; col < 8; col += 2) {
        uv[row * 12 + col] = 40; uv[row * 12 + col + 1] = 200;
    }
    hv_usb_camera_enable(c, 1);
    hv_usb_camera_nv12(c, y, 12, uv, 12, 8, 6, 0);
    uint8_t payload[HV_CAMERA_PAYLOAD];
    uint64_t now = now_ns();
    size_t sum = 0, packets = 0;
    unsigned fid = 0, pts = 0, eof = 0;
    do {
        size_t n = hv_usb_camera_read(c, payload, sizeof payload, now);
        CHECK(n > 6 && n <= HV_CAMERA_PAYLOAD && payload[0] == 6);
        if (n <= 6) break;
        if (!packets) { fid = payload[1] & 1; pts = u32(payload + 2); }
        CHECK((payload[1] & 1) == fid && u32(payload + 2) == pts);
        const uint8_t pattern[] = {90,40,90,200};
        int correct = 1;
        for (size_t i = 6; i < n; i++) if (payload[i] != pattern[(sum + i - 6) % 4]) correct = 0;
        CHECK(correct);
        sum += n - 6; packets++; eof = payload[1] & 2;
    } while (!eof && packets < 100);
    CHECK(sum == HV_CAMERA_FRAME_BYTES && eof && packets > 1);
    CHECK(hv_usb_camera_read(c, payload, sizeof payload, now + 1) == 0);
    CHECK(hv_usb_camera_requested(c, now + 1));
    CHECK(hv_usb_camera_requested(c, now - 1)); /* clock sampled before a concurrent USB read */
    CHECK(!hv_usb_camera_requested(c, now + 2000000000));
    /* Padded NV12 with different columns: flip luma and its chroma together,
       and switch back without reconnecting or changing the negotiated stream. */
    for (unsigned row = 0; row < 6; row++)
        for (unsigned col = 0; col < 8; col++) y[row * 12 + col] = 16 + col;
    for (unsigned row = 0; row < 3; row++) for (unsigned col = 0; col < 8; col += 2) {
        uv[row * 12 + col] = 40 + col; uv[row * 12 + col + 1] = 200 + col;
    }
    hv_usb_camera_nv12(c, y, 12, uv, 12, 8, 6, 1);
    CHECK(c->latest[0] == 23 && c->latest[1] == 46 && c->latest[2] == 23 && c->latest[3] == 206);
    unsigned end = (HV_CAMERA_WIDTH - 2) * 2;
    CHECK(c->latest[end] == 16 && c->latest[end + 1] == 40 && c->latest[end + 3] == 200);
    hv_usb_camera_nv12(c, y, 12, uv, 12, 8, 6, 0);
    CHECK(c->latest[0] == 16 && c->latest[1] == 40 && c->latest[end] == 23 && c->latest[end + 1] == 46);
    CHECK(c->configured && c->committed && c->offset == c->frame_len);
    hv_usb_camera_enable(c, 0);
    hv_usb_camera_nv12(c, y, 12, uv, 12, 8, 6, 1);
    CHECK(hv_usb_camera_read(c, payload, sizeof payload, now + 100000000) > 6);
    CHECK(payload[6] == 16 && payload[7] == 128 && payload[8] == 16 && payload[9] == 128);
    CHECK((payload[1] & 1) != fid);
    /* Complete this frame, then verify the advertised fast mode is actually
       paced at 30 fps, rather than just changing the descriptor. */
    for (unsigned i = 0; !(payload[1] & 2) && i < 100; i++)
        CHECK(hv_usb_camera_read(c, payload, sizeof payload, now + 100000000) > 6);
    CHECK(hv_usb_camera_read(c, payload, sizeof payload, now + 130000000) == 0);
    CHECK(hv_usb_camera_read(c, payload, sizeof payload, now + 134000000) > 6);
    /* A caller can still explicitly select the lower-bandwidth 15 fps mode. */
    uint32_t slow = 666666;
    memcpy(reply + 4, &slow, 4);
    uint8_t probe[] = {0x21, 1, 0, 1, 1, 0, 34, 0};
    CHECK(hv_usb_camera_control_out(c, probe, reply, 34) == 0);
    get[1] = 0x81;
    CHECK(hv_usb_camera_control(c, get, reply, sizeof reply) == 34 && u32(reply + 4) == slow);
    CHECK(hv_usb_camera_control_out(c, commit, reply, 34) == 0 && hv_usb_camera_frame_rate(c) == 15);
    CHECK(hv_usb_camera_read(c, payload, sizeof payload, now + 1000000000) > 6);
    for (unsigned i = 0; !(payload[1] & 2) && i < 100; i++)
        CHECK(hv_usb_camera_read(c, payload, sizeof payload, now + 1000000000) > 6);
    CHECK(hv_usb_camera_read(c, payload, sizeof payload, now + 1040000000) == 0);
    CHECK(hv_usb_camera_read(c, payload, sizeof payload, now + 1070000000) > 6);
    hv_usb_camera_reset(c);
    CHECK(hv_usb_camera_read(c, payload, sizeof payload, now + 200000000) == 0);
    /* HD is a real MJPEG USB profile, including descriptor dimensions and
       variable-length payloads. These bytes test transport, not JPEG decoding. */
    const uint8_t dark[] = {0xff, 0xd8, 0xff, 0xd9};
    CHECK(hv_usb_camera_set_profile(c, 3, dark, sizeof dark) == -1);
    CHECK(hv_usb_camera_set_profile(c, 1, NULL, 0) == -1);
    CHECK(hv_usb_camera_set_profile(c, 1, dark, sizeof dark) == 0);
    CHECK(hv_usb_camera_profile(c) == 0 && hv_usb_camera_apply_profile(c));
    CHECK(hv_usb_camera_profile(c) == 1 && !hv_usb_camera_apply_profile(c));
    length = hv_usb_camera_control(c, descriptor, reply, sizeof reply);
    CHECK(length == 147 && u16(reply + 2) == 147 && u16(reply + 79) == 65);
    CHECK(reply[89] == 11 && reply[91] == 6 && reply[102] == 7);
    CHECK(u16(reply + 105) == 1280 && u16(reply + 107) == 720);
    CHECK(u32(reply + 117) == 1280 * 720 * 2);
    CHECK(hv_usb_camera_control(c, config, reply, sizeof reply) == 0);
    get[1] = 0x87;
    CHECK(hv_usb_camera_control(c, get, reply, sizeof reply) == 34 && u32(reply + 18) == 1280 * 720 * 2);
    CHECK(hv_usb_camera_control_out(c, commit, reply, 34) == 0);
    uint8_t jpeg[HV_CAMERA_PAYLOAD + 128], assembled[sizeof jpeg];
    memset(jpeg, 0x73, sizeof jpeg);
    memcpy(jpeg, dark, 2); memcpy(jpeg + sizeof jpeg - 2, dark + 2, 2);
    hv_usb_camera_enable(c, 1);
    hv_usb_camera_jpeg(c, jpeg, sizeof jpeg, 1);
    size_t received = 0;
    do {
        size_t n = hv_usb_camera_read(c, payload, sizeof payload, now + 2000000000);
        CHECK(n > 6 && received + n - 6 <= sizeof assembled);
        if (n <= 6 || received + n - 6 > sizeof assembled) break;
        memcpy(assembled + received, payload + 6, n - 6); received += n - 6;
    } while (!(payload[1] & 2));
    CHECK(received == sizeof jpeg && !memcmp(assembled, jpeg, sizeof jpeg));
    hv_usb_camera_enable(c, 0);
    CHECK(hv_usb_camera_read(c, payload, sizeof payload, now + 2100000000) == 10);
    CHECK(!memcmp(payload + 6, dark, sizeof dark));
    CHECK(hv_usb_camera_set_profile(c, 2, dark, sizeof dark) == 0 && hv_usb_camera_apply_profile(c));
    CHECK(hv_usb_camera_control(c, descriptor, reply, sizeof reply) == 147);
    CHECK(u16(reply + 105) == 1920 && u16(reply + 107) == 1080);
    hv_usb_camera_reset(c);
    CHECK(hv_usb_camera_profile(c) == 2); /* bus resets preserve the user's choice */
    CHECK(hv_usb_camera_set_profile(c, 0, NULL, 0) == 0 && hv_usb_camera_apply_profile(c));
    CHECK(hv_usb_camera_control(c, descriptor, reply, sizeof reply) == 163);
    hv_usb_camera_destroy(c); free(c);
}

static void trb(uint64_t pa, uint64_t address, uint32_t length, unsigned type, uint32_t flags) {
    put(pa, address, 8); put(pa + 8, length, 4); put(pa + 12, (type << 10) | flags | 1, 4);
}
static void xhci_test(HvPcie *pci) {
    HvXhci *x = hv_xhci_create(&machine, pci);
    CHECK(x && x->pci.bar_read(&x->pci, 0, 4, 4) >> 24 == 3);
    CHECK((x->pci.bar_read(&x->pci, 0, 0x808, 4) >> 8 & 255) == 3);
    CHECK((x->pci.bar_read(&x->pci, 0, 0x440, 4) >> 10 & 15) == 1);
    CHECK((x->pci.bar_read(&x->pci, 0, 0x460, 4) >> 10 & 15) == 3); /* high speed, not low speed (2) */
    x->slots[1].dev = 2;
    x->slots[1].ep[1] = (HvXhciRing){RAM + 0x50000, 1};
    x->slots[1].ep_running[1] = 1;
    x->dcbaap = RAM + 0x58000;
    put(x->dcbaap + 8, RAM + 0x59000, 8);
    x->intr[0].erstsz = 1; x->intr[0].seg_size = 64;
    x->intr[0].seg_base = RAM + 0x60000; x->intr[0].pcs = 1;
    uint8_t output[64];
    uint8_t config[] = {0,9,1,0,0,0,0,0};
    CHECK(hv_usb_camera_control(&x->camera, config, output, sizeof output) == 0);
    uint8_t get[] = {0xa1,0x87,0,1,1,0,34,0};
    CHECK(hv_usb_camera_control(&x->camera, get, output, sizeof output) == 34);
    memcpy(at(RAM + 0x55000), output, 34);
    uint8_t setup[] = {0x21,1,0,2,1,0,34,0}; uint64_t bits; memcpy(&bits, setup, 8);
    /* Setup, OUT data and status arrive in three different doorbells. */
    trb(RAM + 0x50000, bits, 8, 2, 1u << 6);
    x->pci.bar_write(&x->pci, 0, 0x2004, 1, 4);
    CHECK(!x->camera.committed);
    trb(RAM + 0x50010, RAM + 0x55000, 34, 3, 0);
    x->pci.bar_write(&x->pci, 0, 0x2004, 1, 4);
    CHECK(!x->camera.committed);
    trb(RAM + 0x50020, 0, 0, 4, (1u << 16) | 32);
    x->pci.bar_write(&x->pci, 0, 0x2004, 1, 4);
    CHECK(x->camera.committed);
    x->slots[1].ep[3] = (HvXhciRing){RAM + 0x70000,1};
    x->slots[1].ep_running[3] = 1;
    trb(RAM + 0x70000, RAM + 0x80000, 10000, 1, 16 | 4);
    trb(RAM + 0x70010, RAM + 0x83000, 10000, 1, 16 | 4);
    trb(RAM + 0x70020, 0xdecafbad11112222ull, 0, 7, 32);
    unsigned event_index = x->intr[0].index;
    x->pci.bar_write(&x->pci, 0, 0x2004, 3, 4);
    CHECK(x->slots[1].ep[3].dequeue == RAM + 0x70030);
    CHECK(*(uint8_t *)at(RAM + 0x80000) == 6);
    uint32_t *event = at(RAM + 0x60000 + event_index * 16);
    CHECK(event[0] == 0x11112222 && event[1] == 0xdecafbad);
    CHECK((event[3] & 4) && (event[2] >> 24) == 13 && (event[2] & 0xffffff) == HV_CAMERA_PAYLOAD);
    /* A malformed IN data stage for an OUT setup must stall without reading
       past the control buffer or committing any host memory into the guest. */
    trb(RAM + 0x50030, bits, 8, 2, 1u << 6);
    trb(RAM + 0x50040, RAM + 0x55000, 34, 3, 1u << 16);
    x->pci.bar_write(&x->pci, 0, 0x2004, 1, 4);
    CHECK(x->slots[1].control_stalled && !x->slots[1].ep_running[1]);
    /* Only the camera reconnects; keyboard and trackpad keep their ports. */
    uint32_t keyboard = x->portsc[0], trackpad = x->portsc[1];
    x->usbcmd |= 1;
    const uint8_t dark[] = {0xff, 0xd8, 0xff, 0xd9};
    CHECK(hv_usb_camera_set_profile(&x->camera, 1, dark, sizeof dark) == 0);
    hv_xhci_poll(x);
    CHECK(!(x->portsc[2] & 1) && (x->portsc[2] & (1u << 17)) && x->camera_reconnect_ns);
    CHECK(x->portsc[0] == keyboard && x->portsc[1] == trackpad);
    x->camera_reconnect_ns = now_ns() - 1;
    hv_xhci_poll(x);
    CHECK(!(x->portsc[2] & 1)); /* a late guest must still see the disconnect */
    x->pci.bar_write(&x->pci, 0, 0x460, (1u << 17) | (1u << 9), 4);
    hv_xhci_poll(x);
    CHECK((x->portsc[2] & 1) && !x->camera_reconnect_ns && hv_usb_camera_profile(&x->camera) == 1);
    CHECK(x->portsc[0] == keyboard && x->portsc[1] == trackpad);
    CHECK(hv_usb_camera_control(&x->camera, config, output, sizeof output) == 0);
    CHECK(hv_usb_camera_control(&x->camera, get, output, sizeof output) == 34);
    CHECK(hv_usb_camera_control_out(&x->camera, setup, output, 34) == 0);
    x->slot_used[1] = 1;
    x->cmd = (HvXhciRing){RAM + 0xa0000, 1};
    trb(RAM + 0xa0000, 0, 0, 10, 1u << 24); /* disable the old camera slot */
    x->pci.bar_write(&x->pci, 0, 0x2000, 0, 4);
    CHECK(x->camera.committed && !x->slot_used[1]);
    hv_xhci_destroy(x);
}

int main(void) {
    if (hv_machine_init(&machine, 4 << 20)) return 1;
    memory = aligned_alloc(16384, 2 << 20);
    if (!memory) return 1;
    memset(memory, 0, 2 << 20);
    CHECK(!hv_machine_add_ram(&machine, RAM, 2 << 20, memory, 0));
    HvGic *gic = hv_gicv3_create(&machine, 0x1000000, 0x2000000);
    HvPcie *pci = hv_pcie_create(&machine, gic, 0x3000000, 1 << 20, 0x10000000, 0x10000000, 32);
    CHECK(gic && pci);
    camera_test(); sound_test(pci); xhci_test(pci);
    hv_machine_free(&machine); free(pci); free(gic); free(memory);
    printf("media: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
