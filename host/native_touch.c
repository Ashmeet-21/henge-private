#include "native_touch.h"
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define QUEUE_SIZE 64
#define MAX_CONTACTS 5
typedef struct { size_t count; uint8_t ids[5]; double x[5], y[5]; } Frame;
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static Frame queue[QUEUE_SIZE], current;
static size_t queued;
static uint32_t epoch = 1;
static int enabled, status;
static double last_sender, last_helper, started;
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static void reset_locked(void) {
    if (++epoch == 0) epoch = 1;
    queued = 0; memset(&current, 0, sizeof current);
    started = last_sender = now(); last_helper = 0;
    status = enabled ? HV_TOUCH_WAITING : HV_TOUCH_OFF;
    pthread_cond_broadcast(&changed);
}
static void expire_locked(void) {
    double t = now();
    if (enabled && ((status == HV_TOUCH_READY && (t-last_helper > 0.7 || t-last_sender > 0.7)) ||
                    (status == HV_TOUCH_WAITING && t-started > 5))) {
        enabled = 0; reset_locked(); status = HV_TOUCH_TIMEOUT;
    }
}
uint32_t hv_native_touch_enable(int on) {
    pthread_mutex_lock(&mutex);
    if (enabled != !!on || (!on && status != HV_TOUCH_OFF)) { enabled = !!on; reset_locked(); }
    uint32_t value = epoch; pthread_mutex_unlock(&mutex); return value;
}
uint32_t hv_native_touch_reset(void) {
    pthread_mutex_lock(&mutex); reset_locked(); uint32_t value = epoch;
    pthread_mutex_unlock(&mutex); return value;
}
uint32_t hv_native_touch_epoch(void) {
    pthread_mutex_lock(&mutex); uint32_t value = epoch; pthread_mutex_unlock(&mutex); return value;
}
int hv_native_touch_status(void) {
    pthread_mutex_lock(&mutex); expire_locked(); int value = status; pthread_mutex_unlock(&mutex); return value;
}
int hv_native_touch_submit(uint32_t generation, const uint8_t *ids, const double *x, const double *y, size_t count) {
    if (count > MAX_CONTACTS || (count && (!ids || !x || !y))) return 0;
    Frame frame = {.count = count};
    for (size_t i = 0; i < count; i++) {
        if (!ids[i] || ids[i] > 127 || !isfinite(x[i]) || !isfinite(y[i]) || x[i] < 0 || x[i] > 1 || y[i] < 0 || y[i] > 1) return 0;
        for (size_t j = 0; j < i; j++) if (ids[j] == ids[i]) return 0;
        frame.ids[i] = ids[i]; frame.x[i] = x[i]; frame.y[i] = y[i];
    }
    pthread_mutex_lock(&mutex); expire_locked();
    if (!enabled || status != HV_TOUCH_READY || generation != epoch) { pthread_mutex_unlock(&mutex); return 0; }
    last_sender = now();
    // Keep the sender watchdog alive without waking the helper for an unchanged idle frame.
    if (!count && !queued && !current.count) {
        pthread_mutex_unlock(&mutex);
        return 1;
    }
    /* Only coalesce motion: preserve every change in contact membership, including short taps. */
    if (queued && queue[queued-1].count == count && !memcmp(queue[queued-1].ids, frame.ids, count)) queue[queued-1] = frame;
    else if (queued < QUEUE_SIZE) queue[queued++] = frame;
    else { enabled = 0; reset_locked(); status = HV_TOUCH_DEVICE; pthread_mutex_unlock(&mutex); return 0; }
    pthread_cond_signal(&changed); pthread_mutex_unlock(&mutex); return 1;
}
void hv_native_touch_report(uint32_t generation, int value) {
    pthread_mutex_lock(&mutex); expire_locked();
    if (enabled && generation == epoch && value >= HV_TOUCH_READY && value <= HV_TOUCH_DEVICE) {
        last_helper = now(); if (status == HV_TOUCH_WAITING) last_sender = last_helper; status = value;
        if (value != HV_TOUCH_READY) { enabled = 0; queued = 0; memset(&current, 0, sizeof current); }
    }
    pthread_mutex_unlock(&mutex);
}
size_t hv_native_touch_next(char *json, size_t capacity) {
    if (capacity < 1024) return 0;
    pthread_mutex_lock(&mutex); expire_locked();
    if (!queued) {
        struct timespec until; clock_gettime(CLOCK_REALTIME, &until);
        until.tv_nsec += 250000000;
        if (until.tv_nsec >= 1000000000) { until.tv_sec++; until.tv_nsec -= 1000000000; }
        pthread_cond_timedwait(&changed, &mutex, &until); expire_locked();
    }
    if (queued) { current = queue[0]; memmove(queue, queue+1, (--queued)*sizeof(Frame)); }
    size_t n = (size_t)snprintf(json, capacity, "{\"version\":1,\"epoch\":%u,\"enabled\":%s,\"contacts\":[", epoch, enabled ? "true" : "false");
    for (size_t i = 0; i < current.count; i++) n += (size_t)snprintf(json+n, capacity-n,
        "%s{\"id\":%u,\"x\":%.9f,\"y\":%.9f}", i ? "," : "", current.ids[i], current.x[i], current.y[i]);
    n += (size_t)snprintf(json+n, capacity-n, "]}");
    pthread_mutex_unlock(&mutex); return n;
}
