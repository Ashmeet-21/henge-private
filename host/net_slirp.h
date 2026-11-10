#ifndef HENGEVM_NET_SLIRP_H
#define HENGEVM_NET_SLIRP_H

#include "machine.h"
#include "virtio_net.h"

/* Before hv_net_attach: the Unix socket behind the guest's 10.0.2.4:80 (share.c). */
void hv_net_set_share_socket(const char *path);
/* App layer: DNS search domains (comma-separated) + domain name to
   propagate into the guest via slirp DHCP. Call before hv_net_attach.
   Host-build defaults: env HV_NET_SEARCH / HV_NET_DOMAIN. */
void hv_net_set_search_domains(const char *comma_list, const char *domain);
/* Install the deliberate hostfwd set (SSH 127.0.0.1:2222 -> guest :22,
   Screen Sharing 127.0.0.1:5900 -> guest :5900). Safe before or after attach.
   Host build also installs it when HV_NET_FWD_SET=on. */
void hv_net_install_default_fwds(void);
/* User-mode NAT for the guest's virtio-net (see net_slirp.c). Returns 0 on success. */
int hv_net_attach(HvMachine *m, HvVirtioNet *n);
/* CPUs must be stopped. Joins the network worker before its machine is freed. */
void hv_net_detach(void);
/* CPU thread, from the board's tick: hand frames for the guest to the device. */
void hv_net_poll(void);

extern uint64_t hv_net_tx_frames, hv_net_rx_frames;

#endif
