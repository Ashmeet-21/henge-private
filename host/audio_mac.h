#ifndef HENGEVM_AUDIO_MAC_H
#define HENGEVM_AUDIO_MAC_H

#include "virtio_snd.h"

/* Play the guest's virtio-snd output on the Mac's default output device. */
void hv_audio_attach(HvVirtioSnd *d);

/* Remote desktop: keep a copy of the sound played (on), and play silence here meanwhile (mute_here). */
void hv_audio_tap(int on, int mute_here);
/* Up to max bytes of the copy, whole frames, in the stream's current format (HV_VSND_FMT_*). */
int hv_audio_tap_read(uint8_t *out, int max, unsigned *channels, unsigned *format, unsigned *rate_hz);

#endif
