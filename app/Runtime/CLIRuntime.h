// CLIRuntime.h - Minimal Wine launcher for console programs (aarch64 session).
// Derived from Madeira's WineProcessBridge.m: same start-up order (prefix,
// wineserver thread, socketpair, __wine_main on its own pthread), without
// graphics, FEX, ARM64EC or WoW64.
#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- JIT ---------------------------------------------------------------- */

typedef struct {
    int      cs_debugged;          /* CS_DEBUGGED set on this process */
    int      simulator;            /* built for the iOS Simulator */
    int      pool_ready;           /* WINE_IOS_JIT_* exported */
    uint64_t pool_rx, pool_rw, pool_size;
    uint64_t window_base, window_size;   /* early 0x140000000 reservation */
    uint64_t placeholder_base, placeholder_size;
    uint64_t map_min, map_max;     /* TASK_VM_INFO address range */
    char     method[64];           /* "debugger", "simulator-dualmap", ... */
    char     error[256];
} cli_jit_info;

/* Create the dual-mapped JIT pool (RX for execution, RW alias for writes) and
 * export WINE_IOS_JIT_RX/RW/SIZE. Device: the attached debugger (StikDebug
 * running madeira-jit.js) prepares the RX region through BRK #0xf00d and is
 * then told to detach. Simulator: vm_allocate + vm_protect RX + vm_remap RW.
 * Returns 0 on success. Idempotent. */
int cli_jit_setup(size_t pool_mb, cli_jit_info *info);
void cli_jit_query(cli_jit_info *info);
/* 1 when CS_DEBUGGED is set (device) or always on the simulator. */
int cli_jit_available(void);
/* Ask StikDebug/LiveContainer's attached debugger for nothing: just whether a
 * debugger is attached right now (P_TRACED). */
int cli_debugger_attached(void);
/* libproc (not in the iOS SDK headers). */
int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

/* ---- Session ------------------------------------------------------------ */

typedef struct {
    const char *prefix;        /* unix path of the Wine prefix */
    const char *exe;           /* Windows path, or bare name in system32 */
    const char *args;          /* Windows command-line style arguments (may be NULL) */
    const char *workdir;       /* C:\... working folder (may be NULL) */
    const char *log_path;      /* unix path for stderr / Wine log */
    const char *const *env;    /* NULL-terminated "NAME=value" list (may be NULL) */
    int stdin_pipe;            /* give the program a stdin pipe */
    int stdout_pipe;           /* give the program a stdout pipe */
} cli_session_params;

/* Start wineserver (if not running) and the program. Returns 0 on success. */
int  cli_session_start(const cli_session_params *p);
int  cli_session_running(void);
int  cli_session_exit_code(void);       /* valid once not running */
uint32_t cli_session_crash_status(void); /* NTSTATUS error, or 0 */
/* stdout: non-blocking read; returns bytes, 0 at EOF, -1 (errno EAGAIN) if none. */
long cli_stdout_read(void *buf, unsigned long len);
int  cli_stdout_fd(void);
/* stdin: blocking write of all bytes; returns bytes written or -1. */
long cli_stdin_write(const void *buf, unsigned long len);
void cli_stdin_close(void);
/* Stop the wineserver (ends all Windows processes). */
void cli_session_shutdown(void);

/* ---- Prefix ------------------------------------------------------------- */
void cli_seed_prefix_if_needed(const char *prefix);
/* Link every file in <bundle>/aarch64-windows into drive_c/windows/system32. */
int  cli_link_dll_farm(const char *prefix);

/* ---- Pseudo-processes --------------------------------------------------- */
/* Fills buf with one line per live Windows process: "pid\tname\tcmdline\n". */
int  cli_list_processes(char *buf, int len);

#ifdef __cplusplus
}
#endif
