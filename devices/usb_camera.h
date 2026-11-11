#ifndef HENGE_USB_CAMERA_H
#define HENGE_USB_CAMERA_H

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>

/* UVC 1.1, high-speed bulk IN: VGA YUY2, or 720p/1080p MJPEG so HD
   stays within USB 2 bandwidth. Every profile supports 15/30 fps. */
#define HV_CAMERA_WIDTH 640
#define HV_CAMERA_HEIGHT 480
#define HV_CAMERA_FRAME_BYTES (HV_CAMERA_WIDTH * HV_CAMERA_HEIGHT * 2)
#define HV_CAMERA_MAX_FRAME_BYTES (1920 * 1080 * 2)
#define HV_CAMERA_BLACK_BYTES 65536
#define HV_CAMERA_PAYLOAD 16384
#define HV_CAMERA_PROBE_BYTES 34

typedef struct HvUsbCamera {
    pthread_mutex_t mu;
    int configured, committed, enabled, fid;
    uint8_t error;
    uint8_t probe[HV_CAMERA_PROBE_BYTES], commit[HV_CAMERA_PROBE_BYTES];
    unsigned profile, requested_profile;
    unsigned width, height;
    uint8_t latest[HV_CAMERA_MAX_FRAME_BYTES], frame[HV_CAMERA_MAX_FRAME_BYTES];
    uint8_t black_jpeg[HV_CAMERA_BLACK_BYTES], requested_black[HV_CAMERA_BLACK_BYTES];
    uint32_t latest_len, frame_len, black_len, requested_black_len;
    uint32_t offset, pts;
    uint64_t next_frame_ns, last_read_ns, frames;
} HvUsbCamera;

void hv_usb_camera_init(HvUsbCamera *c);
void hv_usb_camera_reset(HvUsbCamera *c);
/* Resume the guest's USB stream with black frames until host permission is
   republished. Preserve its probe, commit, profile and FID. */
void hv_usb_camera_resume(HvUsbCamera *c);
void hv_usb_camera_destroy(HvUsbCamera *c);
/* USB CPU thread. -1 stalls. SET_CUR data is applied separately after its OUT
   data stage, so split doorbells and chained data stages work correctly. */
int hv_usb_camera_control(HvUsbCamera *c, const uint8_t setup[8], uint8_t *out, size_t capacity);
int hv_usb_camera_control_out(HvUsbCamera *c, const uint8_t setup[8], const uint8_t *data, size_t len);
/* One bulk payload, or zero to NAK until the next frame. now_ns is monotonic. */
size_t hv_usb_camera_read(HvUsbCamera *c, void *out, size_t capacity, uint64_t now_ns);
void hv_usb_camera_enable(HvUsbCamera *c, int enabled);
int hv_usb_camera_requested(HvUsbCamera *c, uint64_t now_ns);
unsigned hv_usb_camera_frame_rate(HvUsbCamera *c);
/* Host thread: queue 0 VGA, 1 720p, 2 1080p. HD needs a matching black JPEG.
   CPU thread: apply the profile while reconnecting the USB camera. */
int hv_usb_camera_set_profile(HvUsbCamera *c, unsigned profile, const uint8_t *black, size_t len);
int hv_usb_camera_apply_profile(HvUsbCamera *c);
unsigned hv_usb_camera_profile(HvUsbCamera *c);
void hv_usb_camera_jpeg(HvUsbCamera *c, const uint8_t *jpeg, size_t len, unsigned profile);
/* Host input, video-range NV12 (420v). Strides include pixel-buffer padding.
   Frames are aspect-fitted and converted to YUY2 in a bounded latest-frame slot.
   mirrored flips the oriented source horizontally, for either host camera. */
void hv_usb_camera_nv12(HvUsbCamera *c, const uint8_t *y, size_t y_stride,
                        const uint8_t *uv, size_t uv_stride, unsigned width, unsigned height, int mirrored);

#endif
