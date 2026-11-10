/* The guest's sound on the host (Mac or iOS): the default output device through an AudioUnit
   whose render callback pulls PCM straight from the virtio-snd ring. The unit
   is set to the stream's own format, and CoreAudio converts to the device. */
#include "audio_mac.h"

#include <AudioToolbox/AudioToolbox.h>
#include <TargetConditionals.h>

/* The Mac's default output device, or the iOS app's own output (the app sets its audio session to playback). */
#if TARGET_OS_IPHONE
#define HV_OUTPUT_UNIT kAudioUnitSubType_RemoteIO
#else
#define HV_OUTPUT_UNIT kAudioUnitSubType_DefaultOutput
#endif
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>

static AudioComponentInstance unit;
static int unit_running;
static unsigned cur_channels, cur_format, cur_rate;

/* Remote desktop: a copy of what is played, for a computer to play instead. One writer (the render callback),
   one reader (hv_audio_tap_read); about a second at 48 kHz stereo float. When full, new sound is dropped. */
#define TAP_SIZE (1u << 19)
static uint8_t tap_buf[TAP_SIZE];
static _Atomic uint32_t tap_w, tap_r;
static _Atomic int tap_on, tap_mute;

static void tap_put(const uint8_t *p, uint32_t n) {
    uint32_t w = atomic_load_explicit(&tap_w, memory_order_relaxed), r = atomic_load_explicit(&tap_r, memory_order_acquire);
    if (TAP_SIZE - (w - r) < n) return;
    uint32_t at = w & (TAP_SIZE - 1), first = n < TAP_SIZE - at ? n : TAP_SIZE - at;
    memcpy(tap_buf + at, p, first);
    memcpy(tap_buf, p + first, n - first);
    atomic_store_explicit(&tap_w, w + n, memory_order_release);
}

void hv_audio_tap(int on, int mute_here) {
    if (on && !atomic_load(&tap_on)) atomic_store(&tap_r, atomic_load(&tap_w)); /* start from now, not old sound */
    atomic_store(&tap_mute, on && mute_here);
    atomic_store(&tap_on, on);
}

int hv_audio_tap_read(uint8_t *out, int max, unsigned *channels, unsigned *format, unsigned *rate_hz) {
    *channels = cur_channels, *format = cur_format, *rate_hz = cur_rate;
    unsigned frame = (cur_format == HV_VSND_FMT_S16 ? 2 : 4) * (cur_channels ? cur_channels : 1);
    uint32_t r = atomic_load_explicit(&tap_r, memory_order_relaxed), w = atomic_load_explicit(&tap_w, memory_order_acquire);
    uint32_t n = w - r < (uint32_t)max ? w - r : (uint32_t)max;
    n -= n % frame; /* whole frames: the writer only ever adds whole buffers of them */
    uint32_t at = r & (TAP_SIZE - 1), first = n < TAP_SIZE - at ? n : TAP_SIZE - at;
    memcpy(out, tap_buf + at, first);
    memcpy(out + first, tap_buf, n - first);
    atomic_store_explicit(&tap_r, r + n, memory_order_release);
    return (int)n;
}

static OSStatus render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                       UInt32 frames, AudioBufferList *io) {
    (void)flags, (void)ts, (void)bus, (void)frames;
    HvVirtioSnd *d = ref;
    int tapping = atomic_load_explicit(&tap_on, memory_order_relaxed), mute = atomic_load_explicit(&tap_mute, memory_order_relaxed);
    for (UInt32 i = 0; i < io->mNumberBuffers; i++) {
        hv_virtio_snd_pull(d, io->mBuffers[i].mData, io->mBuffers[i].mDataByteSize);
        if (tapping) tap_put(io->mBuffers[i].mData, io->mBuffers[i].mDataByteSize);
        if (mute) memset(io->mBuffers[i].mData, 0, io->mBuffers[i].mDataByteSize);
    }
    return noErr;
}

static int start(void *opaque, unsigned channels, unsigned format, unsigned rate_hz) {
    HvVirtioSnd *d = opaque;
    if (unit && (channels != cur_channels || format != cur_format || rate_hz != cur_rate)) {
        AudioOutputUnitStop(unit);
        AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
        unit = NULL;
        unit_running = 0;
    }
    if (!unit) {
        AudioComponentDescription desc = {kAudioUnitType_Output, HV_OUTPUT_UNIT,
                                          kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent comp = AudioComponentFindNext(NULL, &desc);
        if (!comp || AudioComponentInstanceNew(comp, &unit) != noErr) return -1;
        unsigned bytes = format == HV_VSND_FMT_S16 ? 2 : 4;
        AudioStreamBasicDescription f = {0};
        f.mSampleRate = rate_hz;
        f.mFormatID = kAudioFormatLinearPCM;
        f.mFormatFlags = (format == HV_VSND_FMT_FLOAT ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) |
                         kAudioFormatFlagIsPacked;
        f.mBytesPerPacket = f.mBytesPerFrame = bytes * channels;
        f.mFramesPerPacket = 1;
        f.mChannelsPerFrame = channels;
        f.mBitsPerChannel = bytes * 8;
        AURenderCallbackStruct cb = {render, d};
        if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f) != noErr ||
            AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb) != noErr ||
            AudioUnitInitialize(unit) != noErr) {
            fprintf(stderr, "hengevm: sound: the output device refused %u ch, format %u, %u Hz\n", channels, format, rate_hz);
            AudioComponentInstanceDispose(unit);
            unit = NULL;
            return -1;
        }
        cur_channels = channels, cur_format = format, cur_rate = rate_hz;
    }
    if (!unit_running && AudioOutputUnitStart(unit) == noErr) unit_running = 1;
    return unit_running ? 0 : -1;
}

static void stop(void *opaque) {
    (void)opaque;
    if (unit && unit_running) AudioOutputUnitStop(unit); /* waits for the render callback to finish */
    unit_running = 0;
}

void hv_audio_attach(HvVirtioSnd *d) {
    d->backend = (HvVirtioSndBackend){start, stop, d};
}
