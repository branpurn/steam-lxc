// Tiny gamescope-control client: send display_sleep(WAKE) (or SLEEP with "sleep") for internal+external displays.
// Used by steam-lxc-display-keepawake to undo Steam's idle display sleep inside an LXC (see NOTES.md).
#include <stdio.h>
#include <string.h>
#include <wayland-client.h>
#include "gamescope-control-client-protocol.h"

static struct gamescope_control *ctl;
static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver) {
    if (strcmp(iface, gamescope_control_interface.name) == 0 && ver >= 4)
        ctl = wl_registry_bind(r, name, &gamescope_control_interface, 4);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t name) {}
static const struct wl_registry_listener reg_l = { reg_global, reg_remove };

int main(int argc, char **argv) {
    int sleep = argc > 1 && strcmp(argv[1], "sleep") == 0;
    struct wl_display *dpy = wl_display_connect(NULL);   // WAYLAND_DISPLAY=gamescope-0
    if (!dpy) { fprintf(stderr, "cannot connect to wayland display\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_l, NULL);
    wl_display_roundtrip(dpy);
    if (!ctl) { fprintf(stderr, "gamescope_control v4+ not available\n"); return 1; }
    gamescope_control_display_sleep(ctl,
        GAMESCOPE_CONTROL_DISPLAY_TYPE_FLAGS_INTERNAL_DISPLAY | GAMESCOPE_CONTROL_DISPLAY_TYPE_FLAGS_EXTERNAL_DISPLAY,
        sleep ? GAMESCOPE_CONTROL_DISPLAY_SLEEP_FLAGS_SLEEP : GAMESCOPE_CONTROL_DISPLAY_SLEEP_FLAGS_WAKE);
    wl_display_roundtrip(dpy);
    wl_display_disconnect(dpy);
    return 0;
}
