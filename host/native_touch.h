#ifndef HENGE_NATIVE_TOUCH_H
#define HENGE_NATIVE_TOUCH_H
#include <stddef.h>
#include <stdint.h>
/* Prototype protocol v1. Contacts are normalized to the guest display, not the host view. */
enum { HV_TOUCH_OFF, HV_TOUCH_WAITING, HV_TOUCH_READY, HV_TOUCH_VERSION,
       HV_TOUCH_PERMISSION, HV_TOUCH_DEVICE, HV_TOUCH_TIMEOUT };
uint32_t hv_native_touch_enable(int enabled);
uint32_t hv_native_touch_epoch(void);
uint32_t hv_native_touch_reset(void);
int hv_native_touch_status(void);
int hv_native_touch_submit(uint32_t epoch, const uint8_t *ids, const double *x, const double *y, size_t count);
/* Guest helper transport. next waits at most 250 ms; new input wakes it immediately. */
size_t hv_native_touch_next(char *json, size_t capacity);
void hv_native_touch_report(uint32_t epoch, int status);
#endif
