/* The guest's network: user-mode NAT through libslirp (as QEMU's -netdev user),
   so it needs no root and no entitlement. 10.0.2.0/24: the host is 10.0.2.2,
   DNS 10.0.2.3, the guest gets 10.0.2.15 by DHCP. DNS over UDP is answered through the
   host's own resolver (dns_proxy.c), not libslirp's choice of name server.

   libslirp is not thread-safe, so it lives on one thread with its sockets and
   timers. Frames the guest sends are queued to it (and the thread woken through
   a pipe); frames for the guest are queued the other way and handed to the
   virtio-net device on the CPU thread (hv_net_poll), which may only take them
   when the guest has posted receive buffers. */
#include "net_slirp.h"
#include "dns_proxy.h"
#include "share.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <libslirp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define QUEUE 512
#define MAX_FRAME 65550
#define MAX_TIMERS 64
#define MAX_POLL 1024

typedef struct Frame {
    uint32_t len;
    uint8_t *data;
} Frame;

typedef struct Queue {
    Frame f[QUEUE];
    uint32_t head, tail;
    pthread_mutex_t mu;
} Queue;

typedef struct Timer {
    int used;
    SlirpTimerId id;
    void *cb_opaque;
    int64_t expire_ms; /* -1: not armed */
} Timer;

static Slirp *slirp;
static HvVirtioNet *net;
static HvMachine *machine;
static Queue to_guest, to_host;
static int wake_pipe[2] = {-1, -1};
static pthread_t network_thread;
static int thread_started, queues_initialized;
static _Atomic int stopping;
static Timer timers[MAX_TIMERS];
static struct pollfd pfds[MAX_POLL];
static int npfd;
uint64_t hv_net_tx_frames, hv_net_rx_frames;

static char share_socket[256];

void hv_net_set_share_socket(const char *path) {
    snprintf(share_socket, sizeof share_socket, "%s", path ? path : "");
}

/* ---- Wi-Fi posture: DNS search domains + hostfwds ----
 * hv_net_set_search_domains() is the app layer's entry point: the app passes
 * the host resolver's search domains (comma-separated) and domain name, from
 * Network.framework / resolver state. In the host build the defaults come
 * from HV_NET_SEARCH / HV_NET_DOMAIN. Storage is process-lifetime (the vec
 * must outlive slirp_new, which keeps the pointers). */
static char **g_search_vec;      /* NULL-terminated, owned */
static char *g_search_storage;   /* owned backing for the strings */
static char g_domain[256];
static int g_search_set_by_app;

void hv_net_set_search_domains(const char *comma_list, const char *domain) {
    free(g_search_vec); free(g_search_storage);
    g_search_vec = NULL; g_search_storage = NULL; g_domain[0] = 0;
    if (domain) snprintf(g_domain, sizeof g_domain, "%s", domain);
    if (comma_list && comma_list[0]) {
        g_search_storage = strdup(comma_list);
        int n = 1;
        for (const char *c = comma_list; *c; c++) if (*c == ',') n++;
        g_search_vec = calloc((size_t)n + 1, sizeof(char *));
        int i = 0;
        char *save = NULL;
        for (char *tok = strtok_r(g_search_storage, ",", &save); tok && i < n; tok = strtok_r(NULL, ",", &save))
            g_search_vec[i++] = tok;
        g_search_vec[i] = NULL;
    }
    g_search_set_by_app = 1;
}
static void load_search_from_env(void) {
    if (g_search_set_by_app) return;
    const char *sl = getenv("HV_NET_SEARCH"), *dm = getenv("HV_NET_DOMAIN");
    if (sl || dm) hv_net_set_search_domains(sl, dm);
}

/* Deliberate hostfwd set: SSH and Screen Sharing on host loopback only.
 * Installs immediately if slirp exists, otherwise at attach time. */
static int g_default_fwds_pending;
static void install_default_fwds_now(void) {
    struct in_addr h, g;
    inet_pton(AF_INET, "127.0.0.1", &h);
    inet_pton(AF_INET, "10.0.2.15", &g);
    if (slirp_add_hostfwd(slirp, 0, h, 2222, g, 22) != 0)
        fprintf(stderr, "hengevm: no forward for port 2222\n");
    if (slirp_add_hostfwd(slirp, 0, h, 5900, g, 5900) != 0)
        fprintf(stderr, "hengevm: no forward for port 5900\n");
}
void hv_net_install_default_fwds(void) {
    if (slirp) install_default_fwds_now();
    else g_default_fwds_pending = 1;
}

static int push(Queue *q, const uint8_t *data, uint32_t len) {
    pthread_mutex_lock(&q->mu);
    int ok = q->tail - q->head < QUEUE;
    if (ok) {
        Frame *f = &q->f[q->tail % QUEUE];
        f->data = malloc(len);
        memcpy(f->data, data, len);
        f->len = len;
        q->tail++;
    }
    pthread_mutex_unlock(&q->mu);
    return ok;
}

/* HV_NET_LOG: one line per frame (ethertype, IP protocol, ports). */
static void log_frame(const char *dir, const uint8_t *p, uint32_t len) {
    static int on = -1;
    if (on < 0) on = getenv("HV_NET_LOG") != NULL;
    if (!on || len < 14) return;
    unsigned et = p[12] << 8 | p[13];
    if (et == 0x0800 && len >= 34) {
        unsigned ihl = (p[14] & 15) * 4, proto = p[23];
        unsigned sp = 0, dp = 0;
        if ((proto == 6 || proto == 17) && len >= 14 + ihl + 4) {
            sp = p[14 + ihl] << 8 | p[15 + ihl];
            dp = p[16 + ihl] << 8 | p[17 + ihl];
        }
        fprintf(stderr, "net %s ipv4 %u.%u.%u.%u:%u -> %u.%u.%u.%u:%u proto %u len %u\n", dir, p[26], p[27], p[28],
                p[29], sp, p[30], p[31], p[32], p[33], dp, proto, len);
    } else {
        fprintf(stderr, "net %s ethertype %#06x len %u\n", dir, et, len);
    }
}

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ---- slirp callbacks (all on the network thread) ---- */

static slirp_ssize_t send_packet(const void *buf, size_t len, void *opaque) {
    (void)opaque;
    if (len > MAX_FRAME) return (slirp_ssize_t)len;
    log_frame("rx", buf, (uint32_t)len);
    if (push(&to_guest, buf, (uint32_t)len)) hv_machine_wake(machine);
    return (slirp_ssize_t)len;
}

static void guest_error(const char *msg, void *opaque) {
    (void)opaque;
    fprintf(stderr, "hengevm: net: %s\n", msg);
}

static int64_t clock_get_ns(void *opaque) {
    (void)opaque;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static void *timer_new_opaque(SlirpTimerId id, void *cb_opaque, void *opaque) {
    (void)opaque;
    for (int i = 0; i < MAX_TIMERS; i++)
        if (!timers[i].used) {
            timers[i] = (Timer){1, id, cb_opaque, -1};
            return &timers[i];
        }
    return NULL;
}

static void timer_free(void *timer, void *opaque) {
    (void)opaque;
    if (timer) ((Timer *)timer)->used = 0;
}

static void timer_mod(void *timer, int64_t expire_ms, void *opaque) {
    (void)opaque;
    if (timer) ((Timer *)timer)->expire_ms = expire_ms;
}

static void register_poll_socket(slirp_os_socket fd, void *opaque) {
    (void)fd, (void)opaque;
}

static void unregister_poll_socket(slirp_os_socket fd, void *opaque) {
    (void)fd, (void)opaque;
}

static void notify(void *opaque) {
    (void)opaque;
    char c = 0;
    (void)!write(wake_pipe[1], &c, 1);
}

static int add_poll(slirp_os_socket fd, int events, void *opaque) {
    (void)opaque;
    if (npfd == MAX_POLL) return -1;
    short ev = 0;
    if (events & SLIRP_POLL_IN) ev |= POLLIN;
    if (events & SLIRP_POLL_OUT) ev |= POLLOUT;
    if (events & SLIRP_POLL_PRI) ev |= POLLPRI;
    pfds[npfd] = (struct pollfd){fd, ev, 0};
    return npfd++;
}

static int get_revents(int idx, void *opaque) {
    (void)opaque;
    short r = pfds[idx].revents;
    int ev = 0;
    if (r & POLLIN) ev |= SLIRP_POLL_IN;
    if (r & POLLOUT) ev |= SLIRP_POLL_OUT;
    if (r & POLLPRI) ev |= SLIRP_POLL_PRI;
    if (r & POLLERR) ev |= SLIRP_POLL_ERR;
    if (r & POLLHUP) ev |= SLIRP_POLL_HUP;
    return ev;
}

static const SlirpCb callbacks = {
    .send_packet = send_packet,
    .guest_error = guest_error,
    .clock_get_ns = clock_get_ns,
    .timer_free = timer_free,
    .timer_mod = timer_mod,
    .notify = notify,
    .timer_new_opaque = timer_new_opaque,
    .register_poll_socket = register_poll_socket,
    .unregister_poll_socket = unregister_poll_socket,
};

/* ---- the network thread ---- */

static void *net_thread(void *unused) {
    (void)unused;
    while (!atomic_load(&stopping)) {
        uint32_t timeout = 1000;
        int64_t now = now_ms();
        for (int i = 0; i < MAX_TIMERS; i++)
            if (timers[i].used && timers[i].expire_ms >= 0) {
                int64_t left = timers[i].expire_ms - now;
                if (left < 0) left = 0;
                if ((uint64_t)left < timeout) timeout = (uint32_t)left;
            }
        npfd = 0;
        pfds[npfd++] = (struct pollfd){wake_pipe[0], POLLIN, 0};
        slirp_pollfds_fill_socket(slirp, &timeout, add_poll, NULL);
        int r = poll(pfds, (nfds_t)npfd, (int)timeout);
        if (pfds[0].revents & POLLIN) {
            char buf[64];
            while (read(wake_pipe[0], buf, sizeof buf) > 0) {}
        }
        slirp_pollfds_poll(slirp, r < 0, get_revents, NULL);
        now = now_ms();
        for (int i = 0; i < MAX_TIMERS; i++)
            if (timers[i].used && timers[i].expire_ms >= 0 && timers[i].expire_ms <= now) {
                timers[i].expire_ms = -1;
                slirp_handle_timer(slirp, timers[i].id, timers[i].cb_opaque);
            }
        /* What the guest sent since. */
        for (;;) {
            pthread_mutex_lock(&to_host.mu);
            Frame f = {0, NULL};
            if (to_host.head != to_host.tail) f = to_host.f[to_host.head++ % QUEUE];
            pthread_mutex_unlock(&to_host.mu);
            if (!f.data) break;
            slirp_input(slirp, f.data, (int)f.len);
            free(f.data);
        }
    }
    return NULL;
}

/* A DNS lookup's thread (dns_proxy.c): its answer for the guest, or the query back for libslirp. */
static void dns_send(const uint8_t *frame, uint32_t len, int guest) {
    if (guest) {
        log_frame("rx dns", frame, len);
        if (push(&to_guest, frame, len)) hv_machine_wake(machine);
    } else if (push(&to_host, frame, len)) {
        char c = 0;
        (void)!write(wake_pipe[1], &c, 1);
    }
}

/* CPU thread: the guest sent a frame. */
static void transmit(void *opaque, const uint8_t *frame, uint32_t len) {
    (void)opaque;
    hv_net_tx_frames++;
    log_frame("tx", frame, len);
    if (hv_dns_proxy_take(frame, len, dns_send)) return;
    if (push(&to_host, frame, len)) {
        char c = 0;
        (void)!write(wake_pipe[1], &c, 1);
    }
}

void hv_net_poll(void) {
    if (!net) return;
    for (;;) {
        pthread_mutex_lock(&to_guest.mu);
        Frame f = {0, NULL};
        if (to_guest.head != to_guest.tail) f = to_guest.f[to_guest.head % QUEUE];
        pthread_mutex_unlock(&to_guest.mu);
        if (!f.data) return;
        if (!hv_virtio_net_receive(net, f.data, f.len)) return; /* no buffer posted yet: try again later */
        hv_net_rx_frames++;
        pthread_mutex_lock(&to_guest.mu);
        to_guest.head++;
        pthread_mutex_unlock(&to_guest.mu);
        free(f.data);
    }
}

int hv_net_attach(HvMachine *m, HvVirtioNet *n) {
    if (machine) return -1;
    machine = m;
    atomic_store(&stopping, 0);
    hv_dns_proxy_start();
    hv_net_tx_frames = hv_net_rx_frames = 0;
    pthread_mutex_init(&to_guest.mu, NULL);
    pthread_mutex_init(&to_host.mu, NULL);
    queues_initialized = 1;
    if (pipe(wake_pipe) != 0) { hv_net_detach(); return -1; }
    fcntl(wake_pipe[0], F_SETFL, O_NONBLOCK);
    fcntl(wake_pipe[1], F_SETFL, O_NONBLOCK);
    SlirpConfig cfg;
    memset(&cfg, 0, sizeof cfg);
    cfg.version = 6; /* below 6 it calls the old register_poll_fd, which we leave unset */
    cfg.in_enabled = true;
    cfg.disable_host_loopback = true; /* 10.0.2.2 is not this device's 127.0.0.1: nothing in the guest needs its services */
    inet_pton(AF_INET, "10.0.2.0", &cfg.vnetwork);
    inet_pton(AF_INET, "255.255.255.0", &cfg.vnetmask);
    inet_pton(AF_INET, "10.0.2.2", &cfg.vhost);
    inet_pton(AF_INET, "10.0.2.15", &cfg.vdhcp_start);
    inet_pton(AF_INET, "10.0.2.3", &cfg.vnameserver);
    /* IPv6 on: fd00::/64 mirroring the v4 layout (.2 host, .3 DNS).
     * Field names/semantics verified against libslirp.h (Homebrew 4.9.7
     * header, SlirpConfig v1 fields): in6_enabled bool, vprefix_addr6
     * struct in6_addr, vprefix_len uint8_t, vhost6 / vnameserver6 in6_addr,
     * vdnssearch const char **, vdomainname const char *. */
    cfg.in6_enabled = true;
    inet_pton(AF_INET6, "fd00::", &cfg.vprefix_addr6);
    cfg.vprefix_len = 64;
    inet_pton(AF_INET6, "fd00::2", &cfg.vhost6);
    inet_pton(AF_INET6, "fd00::3", &cfg.vnameserver6);
    load_search_from_env();
    if (g_search_vec) cfg.vdnssearch = (const char **)g_search_vec;
    if (g_domain[0]) cfg.vdomainname = g_domain;
    cfg.vhostname = "hengevm";
    cfg.if_mtu = 1500;
    cfg.if_mru = 1500;
    slirp = slirp_new(&cfg, &callbacks, NULL);
    if (!slirp) { hv_net_detach(); return -1; }
    if (getenv("HV_NET_LOG")) {
        fprintf(stderr, "hengevm: net cfg v4 10.0.2.0/24 host 10.0.2.2 dhcp 10.0.2.15 dns 10.0.2.3 "
                        "v6 fd00::/64 host6 fd00::2 dns6 fd00::3 domain %s search",
                g_domain[0] ? g_domain : "(none)");
        if (g_search_vec) for (int i = 0; g_search_vec[i]; i++) fprintf(stderr, " %s", g_search_vec[i]);
        fprintf(stderr, "\n");
    }
    if (g_default_fwds_pending) { install_default_fwds_now(); g_default_fwds_pending = 0; }
    { const char *fs = getenv("HV_NET_FWD_SET"); /* host-build gate; the app build flips the default */
      if (fs && strcmp(fs, "on") == 0) install_default_fwds_now(); }
    if (getenv("HV_NET_FWD")) { /* debugging: "hostport:guestport" or a comma list
                                   "hostport:guestport,...", from this Mac's loopback into the guest */
        struct in_addr h, g;
        inet_pton(AF_INET, "127.0.0.1", &h);
        inet_pton(AF_INET, "10.0.2.15", &g);
        char *copy = strdup(getenv("HV_NET_FWD")), *save = NULL;
        for (char *tok = copy ? strtok_r(copy, ",", &save) : NULL; tok; tok = strtok_r(NULL, ",", &save)) {
            int hp, gp;
            if (sscanf(tok, "%d:%d", &hp, &gp) == 2) {
                if (slirp_add_hostfwd(slirp, 0, h, hp, g, gp) != 0) fprintf(stderr, "hengevm: no forward for port %d\n", hp);
            }
        }
        free(copy);
    }
    if (share_socket[0]) { /* 10.0.2.4:80 is the shared folder and clipboard: see share.c */
        struct in_addr addr;
        inet_pton(AF_INET, HV_SHARE_ADDR, &addr);
        if (slirp_add_unix(slirp, share_socket, &addr, 80) != 0) fprintf(stderr, "hengevm: net: no route to the shared folder\n");
    }
    net = n;
    n->transmit = transmit;
    if (pthread_create(&network_thread, NULL, net_thread, NULL) != 0) { hv_net_detach(); return -1; }
    thread_started = 1;
    return 0;
}

void hv_net_detach(void) {
    atomic_store(&stopping, 1);
    hv_dns_proxy_stop();
    if (thread_started) {
        char byte = 0;
        (void)!write(wake_pipe[1], &byte, 1);
        pthread_join(network_thread, NULL);
        thread_started = 0;
    }
    if (net) net->transmit = NULL;
    if (slirp) slirp_cleanup(slirp);
    slirp = NULL;
    if (queues_initialized) {
        Queue *queues[] = {&to_guest, &to_host};
        for (int i = 0; i < 2; i++) {
            Queue *q = queues[i];
            while (q->head != q->tail) free(q->f[q->head++ % QUEUE].data);
            pthread_mutex_destroy(&q->mu);
            memset(q, 0, sizeof *q);
        }
        queues_initialized = 0;
    }
    for (int i = 0; i < 2; i++) {
        if (wake_pipe[i] >= 0) close(wake_pipe[i]);
        wake_pipe[i] = -1;
    }
    memset(timers, 0, sizeof timers);
    net = NULL;
    machine = NULL;
}
