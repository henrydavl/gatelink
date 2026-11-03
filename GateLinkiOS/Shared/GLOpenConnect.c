#include "GLOpenConnect.h"

#include <Security/Security.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

// The iOS SDK lacks <sys/kern_control.h>; these match the macOS definitions.
#define GL_UTUN_CONTROL_NAME "com.apple.net.utun_control"
#define GL_AF_SYSTEM 32
#define GL_MAX_KCTL_NAME 96
struct gl_ctl_info { uint32_t ctl_id; char ctl_name[GL_MAX_KCTL_NAME]; };
struct gl_sockaddr_ctl {
    u_char sc_len; u_char sc_family; uint16_t ss_sysaddr;
    uint32_t sc_id; uint32_t sc_unit; uint32_t sc_reserved[5];
};
#define GL_CTLIOCGINFO _IOWR('N', 3, struct gl_ctl_info)

/// Per-connection state passed to openconnect callbacks as privdata.
struct gl_context {
    struct openconnect_info *vpninfo;
    const char *host;         // login only: the portal the user typed
    const char *username;
    const char *credential;   // login only
    const char *fingerprint;  // tunnel only: the pin to accept
    int answered;
    char error[256];
    gl_log_fn log;
    void *log_context;
};

struct gl_tunnel {
    struct gl_context ctx;
    int cmd_fd;
    pthread_mutex_t lock;
};

static void set_error(struct gl_context *ctx, const char *message) {
    if (!ctx->error[0]) snprintf(ctx->error, sizeof ctx->error, "%s", message);
}

static void copy_error(const struct gl_context *ctx, const char *fallback, char *error, size_t size) {
    if (error && size) snprintf(error, size, "%s", ctx->error[0] ? ctx->error : fallback);
}

static void progress(void *privdata, int level, const char *fmt, ...) {
    struct gl_context *ctx = privdata;
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    size_t n = strlen(line);
    while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
    if (level == PRG_ERR) set_error(ctx, line);
    if (ctx->log && n) ctx->log(ctx->log_context, level, line);
}

/// Fills the gateway login form: username into user*/uname* text fields,
/// password + OTP into the password field. A second password prompt means
/// the gateway rejected it, as on macOS.
static int process_auth_form(void *privdata, struct oc_auth_form *form) {
    struct gl_context *ctx = privdata;
    if (form->error) set_error(ctx, form->error);
    for (struct oc_form_opt *opt = form->opts; opt; opt = opt->next) {
        if (opt->flags & OC_FORM_OPT_IGNORE) continue;
        if (opt->type == OC_FORM_OPT_TEXT) {
            if (strncasecmp(opt->name, "user", 4) && strncasecmp(opt->name, "uname", 5)) {
                set_error(ctx, "The gateway asked for a field GateLink cannot fill.");
                return OC_FORM_RESULT_CANCELLED;
            }
            openconnect_set_option_value(opt, ctx->username);
        } else if (opt->type == OC_FORM_OPT_PASSWORD) {
            if (ctx->answered) {
                set_error(ctx, "Login failed: the gateway asked for the password again. Check the password and OTP.");
                return OC_FORM_RESULT_CANCELLED;
            }
            openconnect_set_option_value(opt, ctx->credential);
            ctx->answered = 1;
        }
    }
    return OC_FORM_RESULT_OK;
}

/// Login: trust what iOS trusts. Tunnel: accept only the pinned certificate.
static int validate_peer_cert(void *privdata, const char *reason) {
    struct gl_context *ctx = privdata;
    if (ctx->fingerprint) {
        if (openconnect_check_peer_cert_hash(ctx->vpninfo, ctx->fingerprint) == 0) return 0;
        set_error(ctx, "The gateway's certificate changed since login; refusing to connect.");
        return 1;
    }

    struct oc_cert *chain = NULL;
    int count = openconnect_get_peer_cert_chain(ctx->vpninfo, &chain);
    if (count <= 0) {
        set_error(ctx, "The gateway sent no certificate.");
        return 1;
    }
    CFMutableArrayRef certs = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (int i = 0; i < count; i++) {
        CFDataRef der = CFDataCreate(NULL, chain[i].der_data, chain[i].der_len);
        SecCertificateRef cert = der ? SecCertificateCreateWithData(NULL, der) : NULL;
        if (der) CFRelease(der);
        if (cert) {
            CFArrayAppendValue(certs, cert);
            CFRelease(cert);
        }
    }
    openconnect_free_peer_cert_chain(ctx->vpninfo, chain);

    // The typed portal, not openconnect's hostname: on NAT64 networks the GP
    // login switches that to the gateway's IPv6 address, which no certificate names.
    CFStringRef host = CFStringCreateWithCString(NULL, ctx->host, kCFStringEncodingUTF8);
    SecPolicyRef policy = SecPolicyCreateSSL(true, host);
    SecTrustRef trust = NULL;
    CFErrorRef trust_error = NULL;
    bool trusted = false;
    if (SecTrustCreateWithCertificates(certs, policy, &trust) == errSecSuccess) {
        trusted = SecTrustEvaluateWithError(trust, &trust_error);
        CFRelease(trust);
    }
    CFRelease(policy);
    if (host) CFRelease(host);
    CFRelease(certs);

    if (trusted) return 0;
    // iOS's reason names the certificate and the problem; OpenSSL's only says it had no CA store.
    char detail[160] = "";
    if (trust_error) {
        CFStringRef description = CFErrorCopyDescription(trust_error);
        if (description) {
            CFStringGetCString(description, detail, sizeof detail, kCFStringEncodingUTF8);
            CFRelease(description);
        }
        CFRelease(trust_error);
    }
    char message[256];
    snprintf(message, sizeof message, "iOS does not trust the certificate %s presented: %s",
             ctx->host, detail[0] ? detail : reason);
    set_error(ctx, message);
    return 1;
}

static int write_new_config(void *privdata, const char *buf, int buflen) {
    return 0;
}

static struct openconnect_info *new_vpninfo(struct gl_context *ctx, const char *host) {
    static pthread_once_t ssl_once = PTHREAD_ONCE_INIT;
    pthread_once(&ssl_once, (void (*)(void))openconnect_init_ssl);

    // Same agent string as the openconnect CLI the macOS app runs.
    struct openconnect_info *vpninfo = openconnect_vpninfo_new(
        "AnyConnect-compatible OpenConnect VPN Agent",
        validate_peer_cert, write_new_config, process_auth_form, progress, ctx);
    if (!vpninfo) return NULL;
    ctx->vpninfo = vpninfo;
    openconnect_set_loglevel(vpninfo, PRG_INFO);
    // Let validate_peer_cert decide; the bundled OpenSSL has no CA store.
    openconnect_set_system_trust(vpninfo, 0);
    if (openconnect_set_protocol(vpninfo, "gp") || openconnect_set_hostname(vpninfo, host)) {
        openconnect_vpninfo_free(vpninfo);
        ctx->vpninfo = NULL;
        return NULL;
    }
    return vpninfo;
}

int gl_login(const char *host, const char *username, const char *credential,
             char **cookie, char **fingerprint,
             gl_log_fn log, void *log_context, char *error, size_t error_size) {
    struct gl_context ctx = { .host = host, .username = username, .credential = credential, .log = log, .log_context = log_context };
    struct openconnect_info *vpninfo = new_vpninfo(&ctx, host);
    if (!vpninfo) {
        copy_error(&ctx, "Could not set up OpenConnect.", error, error_size);
        return -1;
    }
    // --usergroup=gateway: the portal endpoint loops with HTTP 512.
    openconnect_set_urlpath(vpninfo, "gateway");

    int ret = -1;
    if (openconnect_obtain_cookie(vpninfo) == 0 && openconnect_get_cookie(vpninfo)) {
        const char *hash = openconnect_get_peer_cert_hash(vpninfo);
        *cookie = strdup(openconnect_get_cookie(vpninfo));
        *fingerprint = hash ? strdup(hash) : NULL;
        ret = (*cookie && *fingerprint) ? 0 : -1;
        if (ret) set_error(&ctx, "The gateway did not return a valid certificate fingerprint; refusing to connect.");
    }
    if (ret) copy_error(&ctx, "Login failed. Check the username, password and OTP.", error, error_size);
    openconnect_vpninfo_free(vpninfo);
    return ret;
}

gl_tunnel *gl_tunnel_new(const char *host, const char *cookie, const char *fingerprint,
                         gl_log_fn log, void *log_context) {
    gl_tunnel *tunnel = calloc(1, sizeof *tunnel);
    if (!tunnel) return NULL;
    tunnel->ctx.fingerprint = strdup(fingerprint);
    tunnel->ctx.log = log;
    tunnel->ctx.log_context = log_context;
    tunnel->cmd_fd = -1;
    pthread_mutex_init(&tunnel->lock, NULL);
    if (!tunnel->ctx.fingerprint || !new_vpninfo(&tunnel->ctx, host) ||
        openconnect_set_cookie(tunnel->ctx.vpninfo, cookie)) {
        gl_tunnel_free(tunnel);
        return NULL;
    }
    // Same as --no-dtls on macOS: the tunnel runs over SSL only.
    openconnect_disable_dtls(tunnel->ctx.vpninfo);
    tunnel->cmd_fd = openconnect_setup_cmd_pipe(tunnel->ctx.vpninfo);
    return tunnel;
}

int gl_tunnel_connect(gl_tunnel *tunnel, char *error, size_t error_size) {
    if (tunnel->cmd_fd < 0) {
        copy_error(&tunnel->ctx, "Could not set up OpenConnect.", error, error_size);
        return -1;
    }
    if (openconnect_make_cstp_connection(tunnel->ctx.vpninfo) == 0) return 0;
    copy_error(&tunnel->ctx, "The tunnel did not come up.", error, error_size);
    return -1;
}

const struct oc_ip_info *gl_tunnel_ip_info(gl_tunnel *tunnel) {
    const struct oc_ip_info *info = NULL;
    openconnect_get_ip_info(tunnel->ctx.vpninfo, &info, NULL, NULL);
    return info;
}

int gl_find_utun_fd(void) {
    struct gl_ctl_info info = { 0 };
    for (int fd = 0; fd <= 1024; fd++) {
        struct gl_sockaddr_ctl addr = { 0 };
        socklen_t len = sizeof addr;
        if (getpeername(fd, (struct sockaddr *)&addr, &len) != 0 || addr.sc_family != GL_AF_SYSTEM) continue;
        if (!info.ctl_id) {
            strncpy(info.ctl_name, GL_UTUN_CONTROL_NAME, sizeof info.ctl_name - 1);
            if (ioctl(fd, GL_CTLIOCGINFO, &info) != 0) continue;
        }
        if (addr.sc_id == info.ctl_id) return fd;
    }
    return -1;
}

int gl_tunnel_run(gl_tunnel *tunnel, int tun_fd, char *error, size_t error_size) {
    if (openconnect_setup_tun_fd(tunnel->ctx.vpninfo, tun_fd)) {
        copy_error(&tunnel->ctx, "Could not attach to the VPN interface.", error, error_size);
        return -1;
    }
    tunnel->ctx.error[0] = 0;
    int ret;
    // 0 means paused; keep going. Reconnects for up to 5 minutes, like macOS.
    while ((ret = openconnect_mainloop(tunnel->ctx.vpninfo, 300, 10)) == 0) {}
    if (ret == -EINTR) return 0;
    copy_error(&tunnel->ctx, "The VPN connection was lost.", error, error_size);
    return -1;
}

void gl_tunnel_cancel(gl_tunnel *tunnel) {
    pthread_mutex_lock(&tunnel->lock);
    if (tunnel->cmd_fd >= 0) {
        char cmd = OC_CMD_CANCEL;
        if (write(tunnel->cmd_fd, &cmd, 1) < 0) { /* the loop has already ended */ }
    }
    pthread_mutex_unlock(&tunnel->lock);
}

void gl_tunnel_free(gl_tunnel *tunnel) {
    if (!tunnel) return;
    pthread_mutex_lock(&tunnel->lock);
    tunnel->cmd_fd = -1;
    pthread_mutex_unlock(&tunnel->lock);
    if (tunnel->ctx.vpninfo) openconnect_vpninfo_free(tunnel->ctx.vpninfo);
    free((void *)tunnel->ctx.fingerprint);
    pthread_mutex_destroy(&tunnel->lock);
    free(tunnel);
}
