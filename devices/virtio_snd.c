#include "virtio_snd.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>

#define CTLQ 0
#define EVENTQ 1
#define TXQ 2
#define RXQ 3

/* request codes */
#define R_JACK_INFO 1
#define R_JACK_REMAP 2
#define R_PCM_INFO 0x0100
#define R_PCM_SET_PARAMS 0x0101
#define R_PCM_PREPARE 0x0102
#define R_PCM_RELEASE 0x0103
#define R_PCM_START 0x0104
#define R_PCM_STOP 0x0105
#define R_CHMAP_INFO 0x0200
/* status codes */
#define S_OK 0x8000
#define S_BAD_MSG 0x8001
#define S_NOT_SUPP 0x8002
#define S_IO_ERR 0x8003

#define CHMAP_FL 3
#define CHMAP_FR 4
#define CHMAP_MONO 2

static int logging(void) {
    static int on = -1;
    if (on < 0) on = getenv("HV_SND_LOG") != NULL;
    return on;
}

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static unsigned format_bytes(unsigned f) {
    return f == HV_VSND_FMT_S16 ? 2 : 4;
}

static uint32_t readable(const HvVirtqElem *e) {
    uint32_t n = 0;
    for (int i = 0; i < e->nseg; i++)
        if (!e->seg[i].write) n += e->seg[i].len;
    return n;
}

static void put32(uint8_t *p, uint32_t v) {
    memcpy(p, &v, 4);
}

/* ---- control queue ---- */

/* Return every posted capture buffer on STOP/RELEASE, including a partial
   period. All callers hold capture_mu; only the CPU touches virtqueues. */
static void capture_release(HvVirtioSnd *d) {
    int any = 0;
    while (d->capture.head != d->capture.tail) {
        HvVirtqElem *e = &d->capture.pending[d->capture.head % HV_VSND_PENDING];
        uint32_t n = d->capture.offset;
        uint32_t st[2] = {S_OK, 0};
        uint32_t room = hv_virtq_writable(e);
        if (room >= 8) hv_virtq_write(&d->vio, e, room - 8, st, 8);
        hv_virtq_push(&d->vio, RXQ, e, room >= 8 ? n + 8 : 0);
        d->capture.offset = 0;
        d->capture.head++;
        any = 1;
    }
    if (any) hv_virtio_interrupt(&d->vio);
}

static uint32_t capture_control(HvVirtioSnd *d, uint32_t code, const uint8_t *req) {
    uint32_t status = S_OK;
    pthread_mutex_lock(&d->capture_mu);
    switch (code) {
    case R_PCM_SET_PARAMS: {
        uint32_t buffer, period;
        memcpy(&buffer, req + 8, 4);
        memcpy(&period, req + 12, 4);
        unsigned fmt = req[21], bytes = format_bytes(fmt);
        fprintf(stderr, "virtio-snd: input parameters ch %u fmt %u rate %u buffer %u period %u features %#x\n",
                req[20], fmt, req[22], buffer, period,
                (unsigned)req[16] | (unsigned)req[17] << 8 | (unsigned)req[18] << 16 | (unsigned)req[19] << 24);
        if (req[20] != 1 || req[22] != HV_VSND_RATE_48000 ||
            (fmt != HV_VSND_FMT_S16 && fmt != HV_VSND_FMT_S32 && fmt != HV_VSND_FMT_FLOAT) ||
            d->capture.running || !period || period % bytes || buffer < period ||
            buffer % period || buffer > HV_VSND_RING || req[16] || req[17] || req[18] || req[19]) {
            status = S_NOT_SUPP;
            break;
        }
        d->capture.format = fmt;
        d->capture.frame_bytes = bytes;
        d->capture.buffer_bytes = buffer;
        d->capture.period_bytes = period;
        d->capture.prepared = 0;
        break;
    }
    case R_PCM_PREPARE:
        if (!d->capture.frame_bytes || d->capture.running) status = S_BAD_MSG;
        else d->capture.prepared = 1;
        break;
    case R_PCM_START:
        if (!d->capture.prepared) status = S_BAD_MSG;
        else if (!d->capture.running) {
            d->capture.written = d->capture.consumed = 0;
            d->capture.delivered = 0;
            d->capture.received = d->capture.silenced = d->capture.underruns = 0;
            d->capture.input_block_frames = 0;
            d->capture.source_active = 0;
            d->capture.start_ns = now_ns();
            d->capture.running = 1;
        }
        break;
    case R_PCM_STOP:
    case R_PCM_RELEASE:
        if (d->capture.running)
            fprintf(stderr, "virtio-snd: input stopped: %llu host frames, %llu silence frames, %llu underruns\n",
                    (unsigned long long)d->capture.received, (unsigned long long)d->capture.silenced,
                    (unsigned long long)d->capture.underruns);
        d->capture.running = 0;
        d->capture.written = d->capture.consumed = 0;
        capture_release(d);
        if (code == R_PCM_RELEASE) d->capture.prepared = 0;
        break;
    default: status = S_NOT_SUPP; break;
    }
    pthread_mutex_unlock(&d->capture_mu);
    return status;
}

static uint32_t control(HvVirtioSnd *d, const HvVirtqElem *e) {
    HvVirtio *v = &d->vio;
    uint8_t req[32] = {0}, resp[4 + 64];
    uint32_t got = hv_virtq_read(v, e, 0, req, sizeof req);
    uint32_t code, status = S_OK, rlen = 4;
    memcpy(&code, req, 4);
    memset(resp, 0, sizeof resp);
    uint32_t start, count, size, stream;
    memcpy(&start, req + 4, 4);
    memcpy(&count, req + 8, 4);
    memcpy(&size, req + 12, 4);
    stream = start; /* virtio_snd_pcm_hdr: stream_id at the same place */
    if (got < 8 || ((code == R_PCM_INFO || code == R_CHMAP_INFO || code == R_JACK_INFO) && got < 16) ||
        (code == R_PCM_SET_PARAMS && got < 24)) {
        put32(resp, S_BAD_MSG);
        return hv_virtq_write(v, e, 0, resp, 4);
    }
    if (code >= R_PCM_SET_PARAMS && code <= R_PCM_STOP && stream == 1) {
        uint32_t result = capture_control(d, code, req);
        fprintf(stderr, "virtio-snd: input request %#x -> %#x\n", code, result);
        put32(resp, result);
        return hv_virtq_write(v, e, 0, resp, 4);
    }
    switch (code) {
    case R_PCM_INFO:
    case R_CHMAP_INFO:
        if (start >= 2 || !count || count > 2 - start || size != (code == R_PCM_INFO ? 32u : 24u)) {
            status = S_BAD_MSG;
            break;
        }
        for (uint32_t i = 0; i < count; i++) {
          uint8_t *item = resp + 4 + i * size;
          int input = start + i == 1;
          if (code == R_PCM_INFO) {
            uint64_t formats = 1ull << HV_VSND_FMT_S16 | 1ull << HV_VSND_FMT_S32 | 1ull << HV_VSND_FMT_FLOAT;
            uint64_t rates = (input ? 0 : 1ull << HV_VSND_RATE_44100) | 1ull << HV_VSND_RATE_48000;
            memcpy(item + 8, &formats, 8);
            memcpy(item + 16, &rates, 8);
            item[24] = input;
            item[25] = 1;
            item[26] = input ? 1 : 2;
        } else {
            item[4] = input;
            item[5] = input ? 1 : 2;
            item[6] = input ? CHMAP_MONO : CHMAP_FL;
            item[7] = input ? 0 : CHMAP_FR;
          }
        }
        rlen = 4 + size * count;
        break;
    case R_JACK_INFO: /* one line-out jack, always connected */
        if (start != 0 || count != 1 || size == 0 || size > 32) {
            status = S_BAD_MSG;
            break;
        }
        put32(resp + 4 + 8, 0x01014010); /* HDA pin default config: line out, rear, green jack */
        put32(resp + 4 + 12, 0x10);      /* pin capabilities: output */
        resp[4 + 16] = 1;                /* connected */
        rlen = 4 + size;
        break;
    case R_JACK_REMAP:
        break;
    case R_PCM_SET_PARAMS: {
        uint32_t buffer_bytes, period_bytes;
        memcpy(&buffer_bytes, req + 8, 4);
        memcpy(&period_bytes, req + 12, 4);
        unsigned ch = req[20], fmt = req[21], rate = req[22];
        if (stream != 0 || ch < 1 || ch > 2 || (fmt != HV_VSND_FMT_S16 && fmt != HV_VSND_FMT_S32 && fmt != HV_VSND_FMT_FLOAT) ||
            (rate != HV_VSND_RATE_44100 && rate != HV_VSND_RATE_48000) || d->running) {
            status = S_NOT_SUPP;
            break;
        }
        d->channels = ch;
        d->format = fmt;
        d->rate = rate;
        d->rate_hz = rate == HV_VSND_RATE_44100 ? 44100 : 48000;
        d->frame_bytes = ch * format_bytes(fmt);
        d->buffer_bytes = buffer_bytes;
        d->period_bytes = period_bytes;
        break;
    }
    case R_PCM_PREPARE:
        if (stream != 0 || !d->frame_bytes) status = S_BAD_MSG;
        else d->prepared = 1;
        break;
    case R_PCM_START:
        if (stream != 0 || !d->prepared) {
            status = S_BAD_MSG;
            break;
        }
        if (!d->running) {
            d->running = 1;
            d->clock_start_ns = now_ns();
            d->clock_start_consumed = atomic_load(&d->consumed);
            if (d->backend.start && d->backend.start(d->backend.opaque, d->channels, d->format, d->rate_hz) != 0)
                d->backend.start = NULL; /* the host cannot play it: drain by the clock instead */
        }
        break;
    case R_PCM_STOP:
        if (stream != 0) {
            status = S_BAD_MSG;
            break;
        }
        if (d->running && d->backend.stop) d->backend.stop(d->backend.opaque);
        d->running = 0;
        break;
    case R_PCM_RELEASE:
        if (stream != 0) {
            status = S_BAD_MSG;
            break;
        }
        if (d->running && d->backend.stop) d->backend.stop(d->backend.opaque);
        d->running = 0;
        d->prepared = 0;
        /* Every buffer still held goes back now (the spec requires it). */
        for (; d->pcopy != d->ptail; d->pcopy++) d->pending_end[d->pcopy % HV_VSND_PENDING] = atomic_load(&d->written);
        atomic_store(&d->consumed, atomic_load(&d->written));
        break;
    default:
        status = S_NOT_SUPP;
        break;
    }
    if (logging())
        fprintf(stderr, "virtio-snd: request %#x [%u %u %u] -> %#x (ch %u fmt %u rate %u buffer %u period %u)\n", code, start, count, size, status,
                d->channels, d->format, d->rate_hz, d->buffer_bytes, d->period_bytes);
    put32(resp, status);
    return hv_virtq_write(v, e, 0, resp, rlen);
}

/* ---- transmit ---- */

/* Copy waiting buffers' audio into the ring while there is room. Their data is
   still in guest memory, so copying can wait. */

static void fill_ring(HvVirtioSnd *d) {
    HvVirtio *v = &d->vio;
    while (d->pcopy != d->ptail) {
        HvVirtqElem *e = &d->pending[d->pcopy % HV_VSND_PENDING];
        uint32_t len = readable(e);
        len = len > 4 ? len - 4 : 0;
        uint64_t w = atomic_load(&d->written);
        if (len > HV_VSND_RING) len = HV_VSND_RING;
        if (w + len - atomic_load(&d->consumed) > HV_VSND_RING) return; /* full: later */
        uint32_t off = 0;
        while (off < len) {
            uint32_t at = (uint32_t)((w + off) % HV_VSND_RING), n = len - off;
            if (n > HV_VSND_RING - at) n = HV_VSND_RING - at;
            hv_virtq_read(v, e, 4 + off, d->ring + at, n);
            off += n;
        }
        atomic_store_explicit(&d->written, w + len, memory_order_release);
        d->pending_end[d->pcopy % HV_VSND_PENDING] = w + len;
        d->pcopy++;
        d->xfers++;
    }
}

static void take_tx(HvVirtioSnd *d) {
    HvVirtio *v = &d->vio;
    if (!(v->status & 4) || !v->q[TXQ].enabled) return;
    while (d->ptail - d->phead < HV_VSND_PENDING) {
        if (hv_virtq_pop(v, TXQ, &d->pending[d->ptail % HV_VSND_PENDING]) <= 0) break;
        d->ptail++;
    }
    fill_ring(d);
}

void hv_virtio_snd_poll(HvVirtioSnd *d) {
    if (!d) return;
    HvVirtio *v = &d->vio;
    /* Input periods are paced by sample time, including when the host mic is
       muted or unavailable. Never complete an empty period in a busy loop. */
    pthread_mutex_lock(&d->capture_mu);
    if ((v->status & 4) && v->q[RXQ].enabled) {
        while (d->capture.tail - d->capture.head < HV_VSND_PENDING) {
            HvVirtqElem *e = &d->capture.pending[d->capture.tail % HV_VSND_PENDING];
            if (hv_virtq_pop(v, RXQ, e) <= 0) break;
            uint32_t stream = UINT32_MAX;
            hv_virtq_read(v, e, 0, &stream, 4);
            uint32_t room = hv_virtq_writable(e), frame = d->capture.frame_bytes;
            if (stream != 1 || readable(e) != 4 || room < 8 || !frame || (room - 8) % frame) {
                uint32_t st[2] = {S_BAD_MSG, 0};
                if (room >= 8) hv_virtq_write(v, e, room - 8, st, 8);
                hv_virtq_push(v, RXQ, e, room >= 8 ? 8 : 0);
                hv_virtio_interrupt(v);
                continue;
            }
            d->capture.tail++;
        }
    }
    /* Keep the guest's 48-kHz clock steady. Completing periods in host-tap
       bursts gives voice-processing clients a jittery input clock. Hold two
       host blocks before playing real input, so callback jitter doesn't cut
       silence into otherwise continuous speech. */
    uint64_t due = d->capture.running ? (now_ns() - d->capture.start_ns) / 1000 * 48 / 1000 : 0;
    /* Bound recovery after the VM was descheduled; discard stale capture too. */
    if (due > d->capture.delivered + HV_VSND_CAPTURE_FRAMES) {
        d->capture.delivered = due - HV_VSND_CAPTURE_FRAMES;
        d->capture.consumed = d->capture.written;
        d->capture.source_active = 0;
    }
    if (d->capture.enabled && !d->capture.source_active && d->capture.input_block_frames &&
        d->capture.written - d->capture.consumed >= 2u * d->capture.input_block_frames)
        d->capture.source_active = 1;
    while (d->capture.running && d->capture.head != d->capture.tail && d->capture.delivered < due) {
        HvVirtqElem *e = &d->capture.pending[d->capture.head % HV_VSND_PENDING];
        uint32_t room = hv_virtq_writable(e), bytes = d->capture.frame_bytes;
        uint32_t left = room - 8 - d->capture.offset;
        uint8_t pcm[1024];
        uint32_t frames = left / bytes;
        if (frames > sizeof pcm / bytes) frames = sizeof pcm / bytes;
        if (frames > due - d->capture.delivered) frames = (uint32_t)(due - d->capture.delivered);
        for (uint32_t i = 0; i < frames; i++) {
            float sample = 0;
            if (d->capture.enabled && d->capture.source_active && d->capture.consumed != d->capture.written)
                sample = d->capture.samples[d->capture.consumed++ % HV_VSND_CAPTURE_FRAMES];
            else {
                if (d->capture.source_active) { d->capture.underruns++; d->capture.source_active = 0; }
                d->capture.silenced++;
            }
            if (!isfinite(sample)) sample = 0;
            if (sample > 1) sample = 1;
            if (sample < -1) sample = -1;
            if (d->capture.format == HV_VSND_FMT_FLOAT) memcpy(pcm + i * bytes, &sample, 4);
            else if (bytes == 2) {
                int16_t n = sample <= -1 ? INT16_MIN : (int16_t)(sample * INT16_MAX);
                memcpy(pcm + i * bytes, &n, 2);
            } else {
                int32_t n = sample <= -1 ? INT32_MIN : sample >= 1 ? INT32_MAX : (int32_t)((double)sample * INT32_MAX);
                memcpy(pcm + i * bytes, &n, 4);
            }
        }
        hv_virtq_write(v, e, d->capture.offset, pcm, frames * bytes);
        d->capture.offset += frames * bytes;
        d->capture.delivered += frames;
        if (d->capture.offset == room - 8) {
            uint32_t st[2] = {S_OK, (uint32_t)(d->capture.written - d->capture.consumed) * bytes};
            hv_virtq_write(v, e, room - 8, st, 8);
            hv_virtq_push(v, RXQ, e, room);
            d->capture.offset = 0;
            d->capture.head++;
            hv_virtio_interrupt(v);
        }
    }
    pthread_mutex_unlock(&d->capture_mu);
    /* No backend: the stream plays at its rate by the wall clock. */
    if (d->running && !d->backend.start && d->frame_bytes) {
        uint64_t now = now_ns();
        uint64_t target = d->clock_start_consumed +
                          (now - d->clock_start_ns) * d->rate_hz / 1000000000ull * d->frame_bytes;
        uint64_t w = atomic_load(&d->written);
        if (target > w) { /* ran dry: restart the clock from here */
            target = w;
            d->clock_start_ns = now;
            d->clock_start_consumed = w;
        }
        if (target > atomic_load(&d->consumed)) atomic_store(&d->consumed, target);
    }
    take_tx(d);
    uint64_t c = atomic_load_explicit(&d->consumed, memory_order_acquire);
    int any = 0;
    while (d->phead != d->pcopy && d->pending_end[d->phead % HV_VSND_PENDING] <= c) {
        HvVirtqElem *e = &d->pending[d->phead % HV_VSND_PENDING];
        uint8_t st[8] = {0};
        put32(st, S_OK);
        uint64_t queued = atomic_load(&d->written) - c;
        put32(st + 4, (uint32_t)queued); /* latency_bytes */
        hv_virtq_write(v, e, 0, st, 8);
        hv_virtq_push(v, TXQ, e, 8);
        d->phead++;
        any = 1;
    }
    if (any) {
        hv_virtio_interrupt(v);
        take_tx(d); /* room for more */
    }
}

uint32_t hv_virtio_snd_pull(HvVirtioSnd *d, void *buf, uint32_t len) {
    uint64_t c = atomic_load_explicit(&d->consumed, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&d->written, memory_order_acquire);
    uint32_t n = w - c < len ? (uint32_t)(w - c) : len;
    uint32_t off = 0;
    while (off < n) {
        uint32_t at = (uint32_t)((c + off) % HV_VSND_RING), k = n - off;
        if (k > HV_VSND_RING - at) k = HV_VSND_RING - at;
        memcpy((uint8_t *)buf + off, d->ring + at, k);
        off += k;
    }
    if (n < len) {
        memset((uint8_t *)buf + n, 0, len - n);
        if (d->running) d->underruns++;
    }
    /* compare-exchange: a release on the CPU thread may have moved it on */
    atomic_compare_exchange_strong(&d->consumed, &c, c + n);
    if (n) hv_machine_wake(d->vio.m);
    return n;
}

static void notify(HvVirtio *v, int q) {
    HvVirtioSnd *d = v->dev;
    static HvVirtqElem e;
    if (q == CTLQ) {
        int any = 0;
        while (hv_virtq_pop(v, q, &e) > 0) {
            hv_virtq_push(v, q, &e, control(d, &e));
            any = 1;
        }
        if (any) hv_virtio_interrupt(v);
        hv_virtio_snd_poll(d); /* a release may have freed buffers */
    } else if (q == TXQ) {
        take_tx(d);
    } else if (q == RXQ) {
        hv_virtio_snd_poll(d);
    } /* event queue: kept for events we never send */
}

static void reset_device(HvVirtio *v) {
    HvVirtioSnd *d = v->dev;
    if (d->running && d->backend.stop) d->backend.stop(d->backend.opaque);
    d->prepared = d->running = 0;
    d->phead = d->pcopy = d->ptail = 0;
    atomic_store(&d->written, 0);
    atomic_store(&d->consumed, 0);
    pthread_mutex_lock(&d->capture_mu);
    d->capture.prepared = d->capture.running = 0;
    d->capture.frame_bytes = 0;
    d->capture.head = d->capture.tail = d->capture.offset = 0;
    d->capture.written = d->capture.consumed = d->capture.delivered = 0;
    memset(d->capture.samples, 0, sizeof d->capture.samples);
    pthread_mutex_unlock(&d->capture_mu);
}

HvVirtioSnd *hv_virtio_snd_create(HvMachine *m, HvPcie *bus) {
    HvVirtioSnd *d = calloc(1, sizeof *d);
    HvVirtio *v = &d->vio;
    hv_virtio_init(v, m, 25, 0x040100, 4, 0); /* sound device, multimedia audio */
    v->dev = d;
    v->notify = notify;
    v->reset_device = reset_device;
    uint32_t jacks = 1, streams = 2, chmaps = 2;
    memcpy(v->config, &jacks, 4);
    memcpy(v->config + 4, &streams, 4);
    memcpy(v->config + 8, &chmaps, 4);
    v->config_len = 12;
    d->ring = calloc(1, HV_VSND_RING);
    pthread_mutex_init(&d->capture_mu, NULL);
    hv_pcie_attach(bus, &v->pci);
    return d;
}

void hv_virtio_snd_capture_enable(HvVirtioSnd *d, int enabled) {
    if (!d) return;
    pthread_mutex_lock(&d->capture_mu);
    if (d->capture.enabled == !!enabled) { pthread_mutex_unlock(&d->capture_mu); return; }
    d->capture.enabled = !!enabled;
    d->capture.written = d->capture.consumed = 0;
    d->capture.input_block_frames = 0;
    d->capture.source_active = 0;
    memset(d->capture.samples, 0, sizeof d->capture.samples);
    pthread_mutex_unlock(&d->capture_mu);
}

int hv_virtio_snd_capture_requested(HvVirtioSnd *d) {
    if (!d) return 0;
    pthread_mutex_lock(&d->capture_mu);
    int active = d->capture.running;
    pthread_mutex_unlock(&d->capture_mu);
    return active;
}

void hv_virtio_snd_capture_push(HvVirtioSnd *d, const float *mono, uint32_t frames) {
    if (!d || !mono || !frames) return;
    pthread_mutex_lock(&d->capture_mu);
    if (d->capture.running && d->capture.enabled) {
        if (frames > HV_VSND_CAPTURE_FRAMES) { mono += frames - HV_VSND_CAPTURE_FRAMES; frames = HV_VSND_CAPTURE_FRAMES; }
        if (d->capture.written + frames - d->capture.consumed > HV_VSND_CAPTURE_FRAMES)
            d->capture.consumed = d->capture.written + frames - HV_VSND_CAPTURE_FRAMES;
        for (uint32_t i = 0; i < frames; i++) d->capture.samples[d->capture.written++ % HV_VSND_CAPTURE_FRAMES] = mono[i];
        d->capture.received += frames;
        uint32_t block = frames < HV_VSND_CAPTURE_FRAMES / 2 ? frames : HV_VSND_CAPTURE_FRAMES / 2;
        if (block > d->capture.input_block_frames) d->capture.input_block_frames = block;
    }
    pthread_mutex_unlock(&d->capture_mu);
    hv_machine_wake(d->vio.m);
}

void hv_virtio_snd_destroy(HvVirtioSnd *d) {
    if (!d) return;
    pthread_mutex_destroy(&d->capture_mu);
    free(d->ring);
    free(d);
}

/* After a pause or a restore: the host's player again for a stream that was playing, and the clock that drains it
   without one starts from now (host times from before mean nothing). */
void hv_virtio_snd_resume(HvVirtioSnd *d) {
    if (!d) return;
    d->clock_start_ns = now_ns();
    d->clock_start_consumed = atomic_load(&d->consumed);
    if (d->running && d->backend.start && d->backend.start(d->backend.opaque, d->channels, d->format, d->rate_hz) != 0)
        d->backend.start = NULL;
    pthread_mutex_lock(&d->capture_mu);
    /* Guest RX descriptors and their partial period survive; host samples and
       permission do not. Start a fresh clock, without a burst of catch-up PCM. */
    d->capture.enabled = 0;
    d->capture.start_ns = now_ns();
    d->capture.delivered = d->capture.written = d->capture.consumed = 0;
    d->capture.input_block_frames = 0;
    d->capture.source_active = 0;
    memset(d->capture.samples, 0, sizeof d->capture.samples);
    pthread_mutex_unlock(&d->capture_mu);
}
