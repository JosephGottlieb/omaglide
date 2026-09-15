/* SPDX-License-Identifier: MIT
 * Isolated-compositor pointer integration helper; NEVER targets the desktop.
 * Generate wlr-virtual-pointer-client-protocol.h and protocol C in .local/.
 * See virtual-pointer.md for the build and test-only environment contract.
 */
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include <errno.h>
#include <limits.h>
#include <linux/input-event-codes.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include "wlr-virtual-pointer-client-protocol.h"

enum { MAX_EVENTS = 256, MAX_PAUSE_MS = 1000, MAX_DURATION_MS = 10000 };
enum action { MOVE, DOWN, UP, PAUSE };
struct event { enum action action; uint32_t x, y; };
static struct zwlr_virtual_pointer_manager_v1 *manager;
static volatile sig_atomic_t stopped;

static void die(const char *message) {
    fprintf(stderr, "virtual-pointer: %s\n", message);
    exit(1);
}

static void timeout_handler(int sig) {
    (void)sig;
    static const char message[] = "virtual-pointer: safety timeout\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

static void stop_handler(int sig) {
    (void)sig;
    stopped = 1;
}

static uint32_t number(const char *text, size_t length, uint32_t maximum) {
    if (!length || length > 9) die("invalid numeric argument");
    uint32_t result = 0;
    for (size_t i = 0; i < length; ++i) {
        if (text[i] < '0' || text[i] > '9') die("expected an unsigned decimal integer");
        result = result * 10 + (uint32_t)(text[i] - '0');
        if (result > maximum) die("numeric argument exceeds its bound");
    }
    return result;
}

static bool isolated_automatic_socket(const char *runtime, const char *display) {
    /* Hyprland assigns wayland-N itself. Accept it only under this exact,
       canonical mktemp harness path, never the user's ordinary runtime. */
    char canonical[PATH_MAX];
    if (!realpath(runtime, canonical) || strcmp(runtime, canonical) ||
        strlen(canonical) != 16 || strncmp(canonical, "/tmp/od.", 8) ||
        strcmp(canonical + 14, "/r") || strncmp(display, "wayland-", 8) || !display[8])
        return false;
    for (size_t i = 8; i < 14; ++i)
        if (!((canonical[i] >= 'a' && canonical[i] <= 'z') ||
              (canonical[i] >= 'A' && canonical[i] <= 'Z') ||
              (canonical[i] >= '0' && canonical[i] <= '9'))) return false;
    for (size_t i = 8; display[i]; ++i)
        if (display[i] < '0' || display[i] > '9') return false;
    return true;
}

static void guard_test_socket(void) {
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    const char *expected = getenv("OMADESKTOP_TEST_RUNTIME");
    const char *display = getenv("WAYLAND_DISPLAY");
    const char prefix[] = "omadesktop-test-";
    if (!runtime || !expected || strcmp(runtime, expected) || runtime[0] != '/' ||
        !display || strchr(display, '/'))
        die("refusing non-test display: explicit matching isolated runtime and test socket required");
    bool prefixed = !strncmp(display, prefix, sizeof(prefix) - 1) &&
                    display[sizeof(prefix) - 1];
    if (!prefixed && !isolated_automatic_socket(runtime, display))
        die("refusing display: expected omadesktop-test-* or wayland-N within /tmp/od.XXXXXX/r");
    /* Private directory and socket ownership checks catch accidental or shared
       destinations. This helper is not a security boundary against its owner. */
    struct stat st;
    if (lstat(runtime, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() ||
        (st.st_mode & 0777) != 0700)
        die("test runtime must be an owned, non-symlink directory with mode 0700");
    char path[PATH_MAX];
    int size = snprintf(path, sizeof(path), "%s/%s", runtime, display);
    if (size < 0 || (size_t)size >= sizeof(path) || lstat(path, &st) ||
        !S_ISSOCK(st.st_mode) || st.st_uid != getuid())
        die("test display must be an owned, non-symlink Unix socket");
}

static void registry_global(void *data, struct wl_registry *registry,
                            uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (!manager && version >= 1 &&
        !strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name))
        manager = wl_registry_bind(registry, name,
                                   &zwlr_virtual_pointer_manager_v1_interface, 1);
}

static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}

static uint32_t time_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) die("clock_gettime failed");
    return (uint32_t)((uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000);
}

static void keep_pointer(struct wl_display *display, unsigned seconds) {
    signal(SIGINT, stop_handler);
    signal(SIGTERM, stop_handler);
    uint32_t start = time_ms();
    while (!stopped && (uint32_t)(time_ms() - start) < seconds * 1000) {
        if (wl_display_dispatch_pending(display) < 0) die("isolated compositor disconnected");
        if (wl_display_flush(display) < 0 && errno != EAGAIN)
            die("cannot flush isolated display");
        struct pollfd fd = { .fd = wl_display_get_fd(display), .events = POLLIN };
        int ready = poll(&fd, 1, 250);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0 || (fd.revents & (POLLERR | POLLHUP | POLLNVAL)))
            die("isolated compositor disconnected");
        if (ready && (fd.revents & POLLIN) && wl_display_dispatch(display) < 0)
            die("isolated compositor disconnected");
    }
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--help")) {
        puts("Usage: virtual-pointer --width N --height N move:X:Y [down|up|pause:MS|move:X:Y]...\n"
             "Or --keep-alive SECONDS (1..90): retain an idle pointer without input events.\n"
             "Test-only: XDG_RUNTIME_DIR must equal OMADESKTOP_TEST_RUNTIME;\n"
             "WAYLAND_DISPLAY must be omadesktop-test-*; wayland-N allowed only in /tmp/od.XXXXXX/r.\n"
             "Max 256 events, 1000 ms/pause, 10000 ms total; down/up must balance.");
        return 0;
    }
    bool keep_alive = argc == 3 && !strcmp(argv[1], "--keep-alive");
    unsigned keep_seconds = keep_alive ? number(argv[2], strlen(argv[2]), 90) : 0;
    if (keep_alive && !keep_seconds) die("keep-alive duration must be 1..90 seconds");
    if (!keep_alive && (argc < 6 || argc > MAX_EVENTS + 5 || strcmp(argv[1], "--width") ||
        strcmp(argv[3], "--height")))
        die("expected --width N --height N and 1..256 events; see --help");
    const uint32_t width = keep_alive ? 0 : number(argv[2], strlen(argv[2]), 16384);
    const uint32_t height = keep_alive ? 0 : number(argv[4], strlen(argv[4]), 16384);
    if (!keep_alive && (width < 16 || height < 16)) die("width and height must be between 16 and 16384");

    struct event events[MAX_EVENTS];
    uint32_t duration = 0;
    bool pressed = false;
    const size_t count = keep_alive ? 0 : (size_t)(argc - 5);
    /* Validate the complete sequence before connecting or generating input. */
    for (size_t i = 0; i < count; ++i) {
        const char *arg = argv[i + 5];
        events[i] = (struct event){ .action = MOVE, .x = 0, .y = 0 };
        if (!strncmp(arg, "move:", 5)) {
            const char *colon = strchr(arg + 5, ':');
            if (!colon) die("move requires X:Y");
            events[i].x = number(arg + 5, (size_t)(colon - arg - 5), width - 1);
            events[i].y = number(colon + 1, strlen(colon + 1), height - 1);
        } else if (!strcmp(arg, "down")) {
            if (pressed) die("duplicate down event");
            events[i].action = DOWN;
            pressed = true;
        } else if (!strcmp(arg, "up")) {
            if (!pressed) die("up without down");
            events[i].action = UP;
            pressed = false;
        } else if (!strncmp(arg, "pause:", 6)) {
            events[i].action = PAUSE;
            events[i].x = number(arg + 6, strlen(arg + 6), MAX_PAUSE_MS);
            duration += events[i].x;
            if (duration > MAX_DURATION_MS) die("combined pauses exceed 10 seconds");
        } else {
            die("unknown event; only move:X:Y, down, up, pause:MS supported");
        }
    }
    if (pressed) die("sequence must release the button before ending");
    guard_test_socket();
    signal(SIGALRM, timeout_handler);
    signal(SIGPIPE, SIG_IGN);
    alarm(keep_alive ? keep_seconds + 3 : 15);
    /* An explicit socket name also prevents inherited WAYLAND_SOCKET file
       descriptors from bypassing the validated isolated destination. */
    struct wl_display *display = wl_display_connect(getenv("WAYLAND_DISPLAY"));
    if (!display) die("cannot connect to isolated compositor");
    struct wl_registry *registry = wl_display_get_registry(display);
    static const struct wl_registry_listener listener = {
        .global = registry_global, .global_remove = registry_remove
    };
    wl_registry_add_listener(registry, &listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !manager)
        die("isolated compositor does not offer wlr virtual pointer v1");
    struct zwlr_virtual_pointer_v1 *pointer =
        zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, NULL);
    if (!pointer || wl_display_roundtrip(display) < 0)
        die("could not create test pointer");

    if (keep_alive) {
        printf("Pointer ready; retaining idle test seat for up to %u seconds.\n", keep_seconds);
        fflush(stdout);
        keep_pointer(display, keep_seconds);
    }

    for (size_t i = 0; i < count; ++i) {
        const struct event event = events[i];
        if (event.action == PAUSE) {
            struct timespec wait = {
                .tv_sec = event.x / 1000, .tv_nsec = (event.x % 1000) * 1000000L
            };
            while (nanosleep(&wait, &wait) && errno == EINTR) {}
            continue;
        }
        if (event.action == MOVE)
            zwlr_virtual_pointer_v1_motion_absolute(pointer, time_ms(),
                                                    event.x, event.y, width, height);
        else
            zwlr_virtual_pointer_v1_button(pointer, time_ms(), BTN_LEFT,
                event.action == DOWN ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
        zwlr_virtual_pointer_v1_frame(pointer);
        if (wl_display_roundtrip(display) < 0) die("test compositor disconnected");
    }
    zwlr_virtual_pointer_v1_destroy(pointer);
    zwlr_virtual_pointer_manager_v1_destroy(manager);
    wl_registry_destroy(registry);
    (void)wl_display_flush(display);
    wl_display_disconnect(display);
    alarm(0);
    printf("Completed %zu pointer events in isolated compositor.\n", count);
    return 0;
}
