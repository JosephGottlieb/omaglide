/* SPDX-License-Identifier: MIT
 * Test-only full-US-keymap virtual keyboard for an isolated compositor.
 * Adapted from omadesktop/tests/virtual-keyboard.c for the OmaGlide chord test.
 * Destination guards are unchanged. Never connect to the user desktop.
 */
#define _GNU_SOURCE
#include <linux/input-event-codes.h>
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-keyboard-client-protocol.h"

static struct zwp_virtual_keyboard_manager_v1 *manager;
static struct wl_seat *seat;
static struct wl_display *display;
static struct zwp_virtual_keyboard_v1 *keyboard;
static struct xkb_state *state;
static volatile sig_atomic_t stopped;
enum { SHIFT = 1, SUPER = 2, ALT = 4, CTRL = 8, MAX_EVENTS = 64 };
struct event { unsigned key, modifiers, wait; bool hold; };

static void die(const char *message) {
    fprintf(stderr, "virtual-keyboard: %s\n", message);
    exit(1);
}

static void timeout_handler(int sig) {
    (void)sig;
    static const char message[] = "virtual-keyboard: 15-second safety timeout\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

static void stop_handler(int sig) {
    (void)sig;
    stopped = 1;
}

static unsigned number(const char *text, unsigned maximum) {
    size_t length = strlen(text);
    if (!length || length > 9) die("invalid number");
    unsigned result = 0;
    for (size_t i = 0; i < length; ++i) {
        if (text[i] < '0' || text[i] > '9') die("expected unsigned decimal number");
        result = result * 10 + (unsigned)(text[i] - '0');
        if (result > maximum) die("numeric argument exceeds bound");
    }
    return result;
}

static bool isolated_automatic_socket(const char *runtime, const char *socket) {
    char canonical[PATH_MAX];
    if (!realpath(runtime, canonical) || strcmp(runtime, canonical) ||
        strlen(canonical) != 16 || strncmp(canonical, "/tmp/od.", 8) ||
        strcmp(canonical + 14, "/r") || strncmp(socket, "wayland-", 8) || !socket[8])
        return false;
    for (size_t i = 8; i < 14; ++i)
        if (!((canonical[i] >= 'a' && canonical[i] <= 'z') ||
              (canonical[i] >= 'A' && canonical[i] <= 'Z') ||
              (canonical[i] >= '0' && canonical[i] <= '9'))) return false;
    for (size_t i = 8; socket[i]; ++i)
        if (socket[i] < '0' || socket[i] > '9') return false;
    return true;
}

static void guard_test_socket(void) {
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    const char *expected = getenv("OMADESKTOP_TEST_RUNTIME");
    const char *socket = getenv("WAYLAND_DISPLAY");
    const char prefix[] = "omadesktop-test-";
    if (!runtime || !expected || strcmp(runtime, expected) || runtime[0] != '/' ||
        !socket || strchr(socket, '/')) die("explicit matching isolated runtime and test socket required");
    bool prefixed = !strncmp(socket, prefix, sizeof(prefix) - 1) && socket[sizeof(prefix) - 1];
    if (!prefixed && !isolated_automatic_socket(runtime, socket))
        die("refusing display: expected omadesktop-test-* or wayland-N within /tmp/od.XXXXXX/r");
    struct stat st;
    if (lstat(runtime, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() ||
        (st.st_mode & 0777) != 0700) die("test runtime must be owned, non-symlink and mode 0700");
    char path[PATH_MAX];
    int size = snprintf(path, sizeof(path), "%s/%s", runtime, socket);
    if (size < 0 || (size_t)size >= sizeof(path) || lstat(path, &st) ||
        !S_ISSOCK(st.st_mode) || st.st_uid != getuid())
        die("test display must be an owned non-symlink Unix socket");
}

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data;
    if (!manager && version >= 1 && !strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name))
        manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    else if (!seat && version >= 1 && !strcmp(interface, wl_seat_interface.name))
        seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
}

static void remove_global(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}

static void sync_display(void) {
    if (wl_display_roundtrip(display) < 0) die("isolated compositor disconnected");
}

static uint32_t time_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) die("clock_gettime failed");
    return (uint32_t)((uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000);
}

static void wait_ms(unsigned duration) {
    struct timespec wait = { .tv_sec = duration / 1000, .tv_nsec = (duration % 1000) * 1000000L };
    while (nanosleep(&wait, &wait) && errno == EINTR) {}
}

static void keep_keyboard(unsigned seconds) {
    /* Keep the full-keymap virtual device present without sending any keys.
       Unlike event mode, this mode permits up to 90 seconds and exits cleanly
       on SIGINT/SIGTERM so headless pointer tests can share a populated seat. */
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

static void key(unsigned evdev, bool pressed) {
    xkb_state_update_key(state, evdev + 8, pressed ? XKB_KEY_DOWN : XKB_KEY_UP);
    zwp_virtual_keyboard_v1_key(keyboard, time_ms(), evdev,
                                pressed ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
    zwp_virtual_keyboard_v1_modifiers(keyboard,
        xkb_state_serialize_mods(state, XKB_STATE_MODS_DEPRESSED),
        xkb_state_serialize_mods(state, XKB_STATE_MODS_LATCHED),
        xkb_state_serialize_mods(state, XKB_STATE_MODS_LOCKED),
        xkb_state_serialize_layout(state, XKB_STATE_LAYOUT_EFFECTIVE));
    sync_display();
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--help")) {
        puts("Test-only: virtual-keyboard key:EVDEV super:WORKSPACE shift-key:EVDEV super-key:EVDEV\n"
             "Also alt-key:EVDEV, alt-workspaces (Tab then W with Alt held),\n"
             "super-ctrl-key:EVDEV (holds 1500ms), super-shift-key:EVDEV, super-alt-key:EVDEV.\n"
             "Also shift:MS (hold Shift), pause:MS.\n"
             "Or --keep-alive SECONDS (1..90): keep an unmodified keyboard without sending keys.\n"
             "Full standard US keymap; key:1=Escape, key:15=Tab, super:2=Super+2.\n"
             "Requires matching XDG_RUNTIME_DIR/OMADESKTOP_TEST_RUNTIME and isolated test socket.");
        return 0;
    }
    bool keep_alive = argc == 3 && !strcmp(argv[1], "--keep-alive");
    unsigned keep_seconds = keep_alive ? number(argv[2], 90) : 0;
    if (keep_alive && !keep_seconds) die("keep-alive duration must be 1..90 seconds");
    if (argc < 2 || argc > MAX_EVENTS + 1) die("expected 1..64 events; see --help");
    int event_count = keep_alive ? 0 : argc - 1;
    struct event events[MAX_EVENTS];
    unsigned duration = 0;
    for (int i = 1; i <= event_count; ++i) {
        const char *arg = argv[i];
        struct event event = {0};
        if (!strncmp(arg, "key:", 4)) event.key = number(arg + 4, 255);
        else if (!strncmp(arg, "super:", 6)) {
            unsigned workspace = number(arg + 6, 10);
            if (!workspace) die("workspace must be 1..10");
            event.key = workspace == 10 ? KEY_0 : KEY_1 + workspace - 1;
            event.modifiers = SUPER;
        } else if (!strncmp(arg, "shift-key:", 10)) {
            event.key = number(arg + 10, 255); event.modifiers = SHIFT;
        } else if (!strncmp(arg, "super-key:", 10)) {
            event.key = number(arg + 10, 255); event.modifiers = SUPER;
        } else if (!strncmp(arg, "super-shift-key:", 16)) {
            event.key = number(arg + 16, 255); event.modifiers = SUPER | SHIFT;
        } else if (!strncmp(arg, "super-alt-key:", 14)) {
            event.key = number(arg + 14, 255); event.modifiers = SUPER | ALT;
        } else if (!strncmp(arg, "super-ctrl-key:", 15)) {
            event.key = number(arg + 15, 255); event.modifiers = SUPER | CTRL; event.wait = 1500;
        } else if (!strncmp(arg, "alt-key:", 8)) {
            event.key = number(arg + 8, 255); event.modifiers = ALT; event.wait = 1500;
        } else if (!strcmp(arg, "alt-workspaces")) {
            event.key = KEY_TAB; event.modifiers = ALT; event.wait = 1500;
        } else if (!strncmp(arg, "hold-super:", 11)) {
            event.wait = number(arg + 11, 10000); event.hold = true; event.modifiers = SUPER;
        } else if (!strncmp(arg, "shift:", 6)) {
            event.wait = number(arg + 6, 10000); event.hold = true; event.modifiers = SHIFT;
        } else if (!strncmp(arg, "pause:", 6)) event.wait = number(arg + 6, 1000);
        else die("unsupported event; see --help");
        if (!event.wait && !event.key) die("zero duration or key code is not supported");
        duration += event.wait;
        if (duration > 10000) die("combined pauses exceed 10 seconds");
        events[i - 1] = event;
    }
    guard_test_socket();
    signal(SIGALRM, timeout_handler); signal(SIGPIPE, SIG_IGN);
    /* The separate no-input mode gets its declared lifetime plus cleanup slack. */
    alarm(keep_alive ? keep_seconds + 3 : 15);
    display = wl_display_connect(getenv("WAYLAND_DISPLAY")); /* ignores inherited WAYLAND_SOCKET */
    if (!display) die("cannot connect to isolated compositor");
    struct wl_registry *registry = wl_display_get_registry(display);
    static const struct wl_registry_listener listener = { .global = global, .global_remove = remove_global };
    wl_registry_add_listener(registry, &listener, NULL);
    sync_display();
    if (!manager || !seat) die("virtual keyboard manager or seat unavailable");
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_ENVIRONMENT_NAMES);
    if (!context) die("cannot create xkb context");
    struct xkb_rule_names names = { .rules = "evdev", .model = "pc105", .layout = "us", .variant = "", .options = "" };
    struct xkb_keymap *keymap = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!keymap) die("cannot compile full US keymap");
    state = xkb_state_new(keymap);
    char *map = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    if (!state || !map) die("cannot serialize US keymap");
    size_t size = strlen(map) + 1;
    if (size > 1024 * 1024) die("keymap unexpectedly large");
    int fd = memfd_create("omadesktop-test-us-keymap", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)size)) die("cannot create keymap memfd");
    size_t written = 0;
    while (written < size) {
        ssize_t count = write(fd, map + written, size - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) die("cannot write keymap memfd");
        written += (size_t)count;
    }
    keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat);
    zwp_virtual_keyboard_v1_keymap(keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)size);
    sync_display(); close(fd); free(map);
    if (keep_alive) {
        printf("Keyboard ready; retaining unmodified test seat for up to %u seconds.\n", keep_seconds);
        fflush(stdout);
        keep_keyboard(keep_seconds);
    }
    for (int i = 0; i < event_count; ++i) {
        const struct event event = events[i];
        if (event.modifiers & CTRL) key(KEY_LEFTCTRL, true);
        if (event.modifiers & SHIFT) key(KEY_LEFTSHIFT, true);
        if (event.modifiers & SUPER) key(KEY_LEFTMETA, true);
        if (event.modifiers & ALT) key(KEY_LEFTALT, true);
        if (event.key) { key(event.key, true); wait_ms(25); key(event.key, false); }
        if (!strcmp(argv[i + 1], "alt-workspaces")) {
            wait_ms(500); key(KEY_W, true); wait_ms(25); key(KEY_W, false);
        }
        if (event.wait) wait_ms(event.wait);
        if (event.modifiers & ALT) key(KEY_LEFTALT, false);
        if (event.modifiers & SUPER) key(KEY_LEFTMETA, false);
        if (event.modifiers & SHIFT) key(KEY_LEFTSHIFT, false);
        if (event.modifiers & CTRL) key(KEY_LEFTCTRL, false);
    }
    zwp_virtual_keyboard_v1_modifiers(keyboard, 0, 0, 0, 0);
    sync_display();
    zwp_virtual_keyboard_v1_destroy(keyboard);
    wl_seat_destroy(seat); wl_registry_destroy(registry);
    (void)wl_display_flush(display); wl_display_disconnect(display);
    xkb_state_unref(state); xkb_keymap_unref(keymap); xkb_context_unref(context);
    alarm(0);
    printf("Completed %d keyboard events in isolated compositor.\n", event_count);
    return 0;
}
