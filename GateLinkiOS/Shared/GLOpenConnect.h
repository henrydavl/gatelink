// GLOpenConnect — the small C layer between Swift and libopenconnect.
//
// The app logs in with gl_login (like `openconnect --authenticate` on macOS)
// and hands the cookie and certificate pin to the Packet Tunnel extension,
// which runs the tunnel with gl_tunnel_*. C is needed because openconnect's
// log callback is variadic, which Swift cannot implement.

#ifndef GLOpenConnect_h
#define GLOpenConnect_h

#include <stddef.h>
#include <openconnect.h>

/// Receives one log line at an openconnect PRG_* level.
typedef void (*gl_log_fn)(void *context, int level, const char *line);

/// Logs in to a GlobalProtect gateway (`--usergroup=gateway`), answering the
/// single credential prompt with `credential` (password + OTP). The server
/// certificate must be trusted by iOS. On success returns 0 and sets
/// *cookie and *fingerprint (free both with free()); on failure returns -1
/// with a message in `error`.
int gl_login(const char *host, const char *username, const char *credential,
             char **cookie, char **fingerprint,
             gl_log_fn log, void *log_context, char *error, size_t error_size);

typedef struct gl_tunnel gl_tunnel;

/// A tunnel to `host` with a cookie from gl_login. Only a server certificate
/// matching `fingerprint` is accepted.
gl_tunnel *gl_tunnel_new(const char *host, const char *cookie, const char *fingerprint,
                         gl_log_fn log, void *log_context);

/// Opens the SSL tunnel connection. Returns 0, or -1 with `error` set.
int gl_tunnel_connect(gl_tunnel *tunnel, char *error, size_t error_size);

/// Addresses, routes and DNS the gateway assigned. Valid until gl_tunnel_run.
const struct oc_ip_info *gl_tunnel_ip_info(gl_tunnel *tunnel);

/// The utun socket iOS opened for this Packet Tunnel, or -1.
int gl_find_utun_fd(void);

/// Moves packets between `tun_fd` and the gateway until gl_tunnel_cancel or a
/// fatal error; reconnects on its own for up to five minutes. Blocks. Returns
/// 0 when cancelled, otherwise -1 with `error` set.
int gl_tunnel_run(gl_tunnel *tunnel, int tun_fd, char *error, size_t error_size);

/// Makes gl_tunnel_run return. Safe from any thread.
void gl_tunnel_cancel(gl_tunnel *tunnel);

/// Frees the tunnel once gl_tunnel_run has returned (or was never called).
void gl_tunnel_free(gl_tunnel *tunnel);

#endif
