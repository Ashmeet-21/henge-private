#include "native_touch.h"
#include "share.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static char json[1024];
static void next(void) { assert(hv_native_touch_next(json, sizeof json) > 0); }
static void submit(uint32_t e, size_t n, double position) {
    uint8_t ids[] = {1, 2}; double xy[] = {position, position};
    assert(hv_native_touch_submit(e, ids, xy, xy, n));
}
static double monotonic_time(void) {
    struct timespec time;
    assert(clock_gettime(CLOCK_MONOTONIC, &time) == 0);
    return time.tv_sec + time.tv_nsec / 1e9;
}
static void *idle_sender(void *generation) {
    uint32_t e = *(uint32_t *)generation;
    for (int i = 0; i < 12; i++) {
        usleep(100000);
        assert(hv_native_touch_submit(e, NULL, NULL, NULL, 0));
    }
    return NULL;
}
static void *delayed_contact(void *generation) {
    usleep(30000);
    submit(*(uint32_t *)generation, 1, 0.6);
    return NULL;
}
static void http(const char *path, const char *body, char *result, size_t size, const char *socket_path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0); assert(fd >= 0);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    snprintf(address.sun_path, sizeof address.sun_path, "%s", socket_path);
    assert(connect(fd, (struct sockaddr *)&address, sizeof address) == 0);
    char request[1024];
    int n = snprintf(request, sizeof request,
        "%s %s HTTP/1.1\r\nHost: 10.0.2.4\r\nConnection: close\r\nContent-Length: %zu\r\n\r\n%s",
        body ? "PUT" : "GET", path, body ? strlen(body) : 0, body ? body : "");
    assert(write(fd, request, (size_t)n) == n);
    size_t at = 0; ssize_t read_count;
    while ((read_count = read(fd, result+at, size-at-1)) > 0) { at += (size_t)read_count; assert(at < size-1); }
    result[at] = 0; close(fd);
}
int main(void) {
    assert(hv_native_touch_status() == HV_TOUCH_OFF);
    uint32_t e = hv_native_touch_enable(1);
    assert(hv_native_touch_status() == HV_TOUCH_WAITING);
    assert(!hv_native_touch_submit(e, NULL, NULL, NULL, 0));
    hv_native_touch_report(e-1, HV_TOUCH_READY);
    assert(hv_native_touch_status() == HV_TOUCH_WAITING);
    hv_native_touch_report(e, HV_TOUCH_READY);
    uint8_t duplicate[] = {1,1}; double xy[] = {0.5,0.5};
    assert(!hv_native_touch_submit(e, duplicate, xy, xy, 2));
    xy[0] = NAN; assert(!hv_native_touch_submit(e, duplicate, xy, xy, 1));
    xy[0] = 1.1; assert(!hv_native_touch_submit(e, duplicate, xy, xy, 1));
    submit(e, 1, 0.2); submit(e, 1, 0.8); submit(e, 0, 0);
    next(); assert(strstr(json, "0.800000000")); assert(strstr(json, "\"id\":1"));
    next(); assert(strstr(json, "\"contacts\":[]"));
    submit(e, 1, 0.3);
    uint32_t fresh = hv_native_touch_reset(); assert(fresh != e);
    assert(!hv_native_touch_submit(e, NULL, NULL, NULL, 0));
    next(); assert(strstr(json, "\"contacts\":[]"));
    hv_native_touch_report(e, HV_TOUCH_READY); assert(hv_native_touch_status() == HV_TOUCH_WAITING);
    hv_native_touch_report(fresh, HV_TOUCH_PERMISSION); assert(hv_native_touch_status() == HV_TOUCH_PERMISSION);
    next(); assert(strstr(json, "\"enabled\":false"));

    // Neutral heartbeats maintain readiness without shortening the idle long poll.
    e = hv_native_touch_enable(1); hv_native_touch_report(e, HV_TOUCH_READY);
    pthread_t sender;
    assert(pthread_create(&sender, NULL, idle_sender, &e) == 0);
    for (int i = 0; i < 3; i++) {
        double started = monotonic_time();
        next();
        assert(monotonic_time() - started >= 0.2);
        assert(strstr(json, "\"contacts\":[]"));
        hv_native_touch_report(e, HV_TOUCH_READY);
    }
    assert(pthread_join(sender, NULL) == 0);
    assert(hv_native_touch_status() == HV_TOUCH_READY);

    // A real contact wakes the long poll, and its lift still reaches the guest.
    hv_native_touch_report(e, HV_TOUCH_READY);
    assert(pthread_create(&sender, NULL, delayed_contact, &e) == 0);
    double started = monotonic_time();
    next();
    assert(monotonic_time() - started < 0.2);
    assert(strstr(json, "\"id\":1"));
    assert(pthread_join(sender, NULL) == 0);
    submit(e, 0, 0);
    next(); assert(strstr(json, "\"contacts\":[]"));

    e = hv_native_touch_enable(1); hv_native_touch_report(e, HV_TOUCH_READY);
    // Alternating membership cannot be coalesced. Overflow releases instead of dropping a lift.
    for (int i=0; i<64; i++) submit(e, (size_t)(i%2 + 1), 0.5);
    assert(!hv_native_touch_submit(e, duplicate, xy, xy, 0));
    assert(hv_native_touch_status() == HV_TOUCH_DEVICE);
    next(); assert(strstr(json, "\"contacts\":[]"));
    e = hv_native_touch_enable(1); hv_native_touch_report(e, HV_TOUCH_READY); submit(e, 1, 0.5);
    usleep(800000); assert(hv_native_touch_status() == HV_TOUCH_TIMEOUT);
    assert(hv_native_touch_epoch() != e); next(); assert(strstr(json, "\"enabled\":false"));

    // An absent companion must also fall back without ever advertising readiness.
    e = hv_native_touch_enable(1);
    usleep(5100000);
    assert(hv_native_touch_status() == HV_TOUCH_TIMEOUT);
    assert(hv_native_touch_epoch() != e);

    // Exercise the real guest HTTP endpoints and their status validation.
    char directory[] = "/tmp/henge-touch-test-XXXXXX"; assert(mkdtemp(directory));
    char socket_path[108]; snprintf(socket_path, sizeof socket_path, "%s/s", directory);
    assert(hv_share_start(directory, socket_path, NULL) == 0);
    char response[4096], body[64];
    e = hv_native_touch_enable(1);
    http("/.henge/native-touch", NULL, response, sizeof response, socket_path);
    assert(strstr(response, "200 OK") && strstr(response, "\"version\":1"));
    snprintf(body, sizeof body, "%u 2", e);
    http("/.henge/native-touch", body, response, sizeof response, socket_path);
    assert(strstr(response, "204 No Content") && hv_native_touch_status() == HV_TOUCH_READY);
    http("/.henge/native-touch", "1 99", response, sizeof response, socket_path);
    assert(strstr(response, "400 Bad Request"));
    submit(e, 1, 0.25);
    http("/.henge/native-touch", NULL, response, sizeof response, socket_path);
    assert(strstr(response, "0.250000000"));
    hv_native_touch_enable(0);
    http("/.henge/native-touch", NULL, response, sizeof response, socket_path);
    assert(strstr(response, "\"enabled\":false") && strstr(response, "\"contacts\":[]"));
    unlink(socket_path); rmdir(directory);
    puts("native touch: idle polling, immediate wake, transitions, validation, generations, fallback, timeout and HTTP passed");
}
