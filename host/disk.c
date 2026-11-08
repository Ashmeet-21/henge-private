#include <fcntl.h>
#include <errno.h>
#include "../core/machine.h"
#include "disk.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#define DISK_IO_CHUNK (128u << 20)

int hv_disk_open(HvDisk *d, const char *path, uint64_t offset, int readonly) {
    d->fd = open(path, readonly ? O_RDONLY : O_RDWR);
    if (d->fd < 0) return -1;
    struct stat st;
    if (fstat(d->fd, &st) != 0 || (uint64_t)st.st_size < offset) {
        close(d->fd);
        return -1;
    }
    d->offset = offset;
    d->size = (uint64_t)st.st_size - offset;
    d->readonly = readonly;
    return 0;
}

void hv_disk_close(HvDisk *d) {
    if (d->fd >= 0) close(d->fd);
    d->fd = -1;
}

int hv_disk_read(HvDisk *d, uint64_t off, void *buf, uint64_t len) {
    if (off > d->size || len > d->size - off) return -1;
    uint8_t *p = buf;
    while (len) {
        size_t count = len > DISK_IO_CHUNK ? DISK_IO_CHUNK : (size_t)len;
        ssize_t n = pread(d->fd, p, count, (off_t)(d->offset + off));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        off += (uint64_t)n;
        len -= (uint64_t)n;
    }
    return 0;
}

int hv_disk_write(HvDisk *d, uint64_t off, const void *buf, uint64_t len) {
    if (d->readonly || off > d->size || len > d->size - off) return -1;
    const uint8_t *p = buf;
    while (len) {
        size_t count = len > DISK_IO_CHUNK ? DISK_IO_CHUNK : (size_t)len;
        ssize_t n = pwrite(d->fd, p, count, (off_t)(d->offset + off));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        off += (uint64_t)n;
        len -= (uint64_t)n;
    }
    return 0;
}

static int write_zeros(HvDisk *d, uint64_t at, uint64_t len) {
    static const uint8_t zeros[64 * 1024];
    while (len) {
        size_t n = len < sizeof zeros ? (size_t)len : sizeof zeros;
        ssize_t w = pwrite(d->fd, zeros, n, (off_t)at);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        at += (uint64_t)w, len -= (uint64_t)w;
    }
    return 0;
}

int hv_disk_discard(HvDisk *d, uint64_t off, uint64_t len, int zero) {
    if (d->readonly || off > d->size || len > d->size - off) return -1;
    if (!len) return 0;
    uint64_t at = d->offset + off, end = at + len;
    const uint64_t blk = 4096; /* APFS block: F_PUNCHHOLE wants offset and length in whole blocks */
    uint64_t a = (at + blk - 1) / blk * blk, z = end / blk * blk;
    int punched = 0;
#ifdef F_PUNCHHOLE
    if (a < z) {
        struct fpunchhole ph = {0};
        ph.fp_offset = (off_t)a;
        ph.fp_length = (off_t)(z - a);
        punched = fcntl(d->fd, F_PUNCHHOLE, &ph) == 0;
    }
#endif
    if (!zero) return 0;
    if (!punched) return write_zeros(d, at, len);
    if (write_zeros(d, at, a - at) != 0) return -1;
    return write_zeros(d, z, end - z);
}

/* HV_FLUSH: 0 fsync; 1 nothing here, what was written is safe in the host's cache as long as the
   host runs; 2 fcntl(F_BARRIERFSYNC). */
int hv_disk_flush(HvDisk *d) {
    if (d->readonly) return 0;
    switch (hv_knob[HV_K_FLUSH]) {
    case 1: return 0;
    case 2: return fcntl(d->fd, F_BARRIERFSYNC) == -1 ? -1 : 0;
    default: return fsync(d->fd);
    }
}
