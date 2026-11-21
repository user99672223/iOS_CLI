// cli_stubs.c - Symbols the Wine unix side expects from Madeira's app layer
// (graphics, controllers) or from unix libraries this CLI build leaves out.
//
// Weakly declared hooks (winios_p*, cursor, swapchain and window hooks) are
// NOT defined here: they stay undefined (-Wl,-U in project.yml), resolve to
// NULL, and the display driver keeps its "no driver" paths.

#include <stdint.h>
#include <string.h>

/* ---- unix call tables of libraries this build does not include ----------
 * A PE module that loads one of these gets STATUS_NOT_SUPPORTED from every
 * call (its process_attach fails), the same as a Wine build without the
 * library: bcrypt/secur32 lose GnuTLS ciphers and Schannel (Bun and Git use
 * their own TLS), dwrite/gstreamer/opengl32/winevulkan/DXMT have no backend. */
typedef unsigned int NTSTATUS_T;
static NTSTATUS_T cli_unix_not_supported(void *args) { (void)args; return 0xC00000BBu; }

#define CLI_TABLE(name) \
    const void *name[256] = { [0 ... 255] = (const void *)cli_unix_not_supported };

CLI_TABLE(bcrypt_unix_call_funcs)
CLI_TABLE(bcrypt_unix_call_wow64_funcs)
CLI_TABLE(secur32_unix_call_funcs)
CLI_TABLE(secur32_unix_call_wow64_funcs)
CLI_TABLE(dwrite_unix_call_funcs)
CLI_TABLE(dwrite_unix_call_wow64_funcs)
CLI_TABLE(winegstreamer_unix_call_funcs)
CLI_TABLE(winegstreamer_unix_call_wow64_funcs)
CLI_TABLE(opengl32_unix_call_funcs)
CLI_TABLE(opengl32_unix_call_wow64_funcs)
CLI_TABLE(winevulkan_unix_call_funcs)
CLI_TABLE(dxmt_winemetal_unix_call_funcs)
CLI_TABLE(dxmt_winemetal_unix_call_wow64_funcs)
CLI_TABLE(dxmt_d3d9_unix_call_wow64_funcs)

/* ---- OpenGL / Zink / Vulkan presentation (Madeira's Winios) -------------- */
void *madeira_gl_context_create(void *share, int *major) { (void)share; if (major) *major = 0; return 0; }
void madeira_gl_context_release(void *context) { (void)context; }
int madeira_gl_make_current(void *context) { (void)context; return 0; }
int madeira_gl_present(void **state, void *hwnd, unsigned int fbo, int width, int height)
{ (void)state; (void)hwnd; (void)fbo; (void)width; (void)height; return 0; }
void madeira_gl_present_release(void *state) { (void)state; }
void madeira_gl_wait_active(void) {}
void *madeira_vulkan_layer_acquire(void *hwnd) { (void)hwnd; return 0; }
void madeira_vulkan_layer_release(void *layer) { (void)layer; }
void *madeira_zink_target_bind(void **state, void *hwnd, int width, int height, int *row_pixels)
{ (void)state; (void)hwnd; (void)width; (void)height; if (row_pixels) *row_pixels = 0; return 0; }
void *madeira_zink_target_present(void **state, void *hwnd, int *row_pixels)
{ (void)state; (void)hwnd; if (row_pixels) *row_pixels = 0; return 0; }
void madeira_zink_target_release(void *state) { (void)state; }

/* ---- controllers: none attached ------------------------------------------ */
struct winios_gamepad; struct winios_gamepad_battery; struct winios_hidpad; struct winios_hidpad_output;
int winios_gamepad_get_state(int index, struct winios_gamepad *out) { (void)index; (void)out; return 0; }
int winios_gamepad_get_battery(int index, struct winios_gamepad_battery *out) { (void)index; (void)out; return 0; }
int winios_gamepad_rumble_caps(void) { return 0; }
void winios_gamepad_set_vibration(int index, uint16_t left, uint16_t right) { (void)index; (void)left; (void)right; }
int winios_hidpad_get_state(struct winios_hidpad *out) { (void)out; return 0; }
void winios_hidpad_set_output(const struct winios_hidpad_output *output) { (void)output; }

/* ---- diagnostics hooks ----------------------------------------------------- */
void winios_phase(const char *name) { (void)name; }
