// CLIRuntime.m - Minimal Wine launcher for console programs (aarch64 session).
//
// Start-up order follows Madeira's WineProcessBridge.m (see its comments for
// the reasons): seed the prefix BEFORE the wineserver loads the registry,
// start the wineserver thread, connect the client through a socketpair
// (accept() on a UNIX socket is broken on iOS), then run __wine_main on its
// own pthread with a setjmp so ntdll's exit() unwinds back here.

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#include <pthread.h>
#include <setjmp.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <mach/mach.h>
#include <os/log.h>

#include "CLIRuntime.h"
#include "JITAllocator.h"
#include "PrefixExtractor.h"
#include "WineServerBridge.h"

extern void __wine_main(int argc, char *argv[]);
extern void wine_log_set_file(const char *path);
extern int ios_main_image_i386;
extern int cli_list_children(char *buf, int len);

/* Globals the wineserver / ntdll objects reference (WineProcessBridge.m). */
volatile int g_madeira_srv_fgetpath = 0;
volatile int g_madeira_srv_eco_follow = 0;
volatile int g_madeira_srv_direct = 0;
volatile int g_madeira_srv_idle_us = 0;
volatile int g_madeira_srv_log_all = 0;

_Thread_local jmp_buf wine_ios_exit_jmpbuf;
_Thread_local volatile int wine_ios_exit_code = 0;
_Thread_local pthread_t wine_ios_main_thread;
_Thread_local int wine_ios_exit_initialized = 0;

static int g_exit_code = 0;
static volatile int g_running = 0;
static uint64_t g_launch_exit = 0;
static int g_stdin_w = -1, g_stdout_r = -1;

static os_log_t rt_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("cli.runtime", "wine"); });
    return log;
}
#define LOG(fmt, ...) do { os_log(rt_log(), fmt, ##__VA_ARGS__); dprintf(STDERR_FILENO, "[cli] " fmt "\n", ##__VA_ARGS__); } while (0)

/* ntdll: the session's initial process ended (server_ios.c). */
void wine_launched_process_did_exit(int status) {
    if ((uint32_t)status >= 0xC0000000u)
        __atomic_store_n(&g_launch_exit, (UINT64_C(1) << 32) | (uint32_t)status, __ATOMIC_RELEASE);
}
void wine_steam_run_requested(unsigned int appid) { (void)appid; }

/* ======================================================================== */
/* JIT                                                                       */
/* ======================================================================== */

static cli_jit_info g_jit;
static pthread_mutex_t g_jit_lock = PTHREAD_MUTEX_INITIALIZER;

int cli_debugger_attached(void) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return 0;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

int cli_jit_available(void) {
#if TARGET_OS_SIMULATOR
    return 1;
#else
    return jit_check_debugged() ? 1 : 0;
#endif
}

void cli_jit_query(cli_jit_info *info) {
    /* Never wait for a running cli_jit_setup (it waits on the debugger): the UI
     * polls this from the main thread. */
    if (pthread_mutex_trylock(&g_jit_lock) != 0) {
        if (info) *info = g_jit;
        return;
    }
    uint32_t flags = 0;
    g_jit.cs_debugged = jit_cs_status(&flags) && (flags & 0x10000000u /* CS_DEBUGGED */) ? 1 : 0;
#if TARGET_OS_SIMULATOR
    g_jit.simulator = 1;
#endif
    g_jit.window_base = madeira_early_window_base;
    g_jit.window_size = madeira_early_window_size;
    unsigned long pb = 0, ps = 0;
    madeira_early_pool_placeholder(&pb, &ps);
    g_jit.placeholder_base = pb; g_jit.placeholder_size = ps;
    jit_task_map_range(&g_jit.map_min, &g_jit.map_max);
    if (info) *info = g_jit;
    pthread_mutex_unlock(&g_jit_lock);
}

static void export_pool(uint64_t rx, uint64_t rw, uint64_t size) {
    char v[32];
    snprintf(v, sizeof v, "%llx", (unsigned long long)rx);   setenv("WINE_IOS_JIT_RX", v, 1);
    snprintf(v, sizeof v, "%llx", (unsigned long long)rw);   setenv("WINE_IOS_JIT_RW", v, 1);
    snprintf(v, sizeof v, "%llx", (unsigned long long)size); setenv("WINE_IOS_JIT_SIZE", v, 1);
    /* Executable code comes from the pool only, so every image goes through
     * the copy + x18 rewrite path, exactly as on a device. */
    setenv("MADEIRA_NO_PLAIN_EXEC", "1", 1);
    if (madeira_early_window_base) {
        snprintf(v, sizeof v, "%lx:%lx", madeira_early_window_base, madeira_early_window_size);
        setenv("WINE_IOS_EXE_WINDOW", v, 1);
    }
    g_jit.pool_rx = rx; g_jit.pool_rw = rw; g_jit.pool_size = size; g_jit.pool_ready = 1;
}

/* RW alias of [rx, rx+size). */
static kern_return_t make_rw_alias(vm_address_t rx, vm_size_t size, vm_address_t *rw_out) {
    vm_prot_t cur = 0, max = 0;
    vm_address_t rw = 0x7000000000ul;   /* high hint, as Madeira (ml1037) */
    kern_return_t kr = vm_remap(mach_task_self(), &rw, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                rx, FALSE, &cur, &max, VM_INHERIT_NONE);
    if (kr == KERN_NO_SPACE) {   /* 63 GB map without extended-virtual-addressing */
        rw = rx + size;
        kr = vm_remap(mach_task_self(), &rw, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                      rx, FALSE, &cur, &max, VM_INHERIT_NONE);
        if (kr == KERN_NO_SPACE) {
            rw = 0;
            kr = vm_remap(mach_task_self(), &rw, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                          rx, FALSE, &cur, &max, VM_INHERIT_NONE);
        }
    }
    if (kr != KERN_SUCCESS) return kr;
    kr = vm_protect(mach_task_self(), rw, size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) { vm_deallocate(mach_task_self(), rw, size); return kr; }
    *rw_out = rw;
    return KERN_SUCCESS;
}

/* The pool must not land inside the 0x140000000 exe window and should stay
 * above 0x119000000, where Wine maps sub-floor images (Madeira ml977). */
/* Wine's own allocation window (TEBs, stacks, heaps): the pool must never be there,
 * or Wine maps over it (device log: pool at 0x7000000000, first exec faulted). */
#define GUEST_LO 0x7000000000ul
#define GUEST_HI 0x8000000000ul
static int pool_placement_ok(vm_address_t rx, vm_size_t size) {
    if (rx < 0x119000000ul) return 0;
    if (rx < GUEST_HI && rx + size > GUEST_LO) return 0;
    if (madeira_early_window_base &&
        rx < madeira_early_window_base + madeira_early_window_size &&
        rx + size > madeira_early_window_base) return 0;
    return 1;
}

static void jit_log_cb(const char *m) { dprintf(STDERR_FILENO, "[jit] %s\n", m); }

int cli_jit_setup(size_t pool_mb, cli_jit_info *info) {
    pthread_mutex_lock(&g_jit_lock);
    if (g_jit.pool_ready) {
        if (info) *info = g_jit;
        pthread_mutex_unlock(&g_jit_lock);
        return 0;
    }
    jit_set_log_callback(jit_log_cb);
    vm_size_t size = (vm_size_t)pool_mb << 20;
    g_jit.error[0] = 0;
    int rc = -1;

#if TARGET_OS_SIMULATOR
    /* Simulator: a macOS process without TXM and without the hardened
     * runtime. The same dual mapping as on a device, made directly. */
    snprintf(g_jit.method, sizeof g_jit.method, "simulator-dualmap");
    unsigned long pb = 0, ps = 0;
    madeira_early_pool_placeholder(&pb, &ps);
    if (pb && ps) vm_deallocate(mach_task_self(), pb, ps);
    vm_address_t rx = pb ? pb : 0x200000000ul;
    kern_return_t kr = vm_allocate(mach_task_self(), &rx, size, VM_FLAGS_ANYWHERE);
    if (kr == KERN_SUCCESS && !pool_placement_ok(rx, size)) {
        vm_deallocate(mach_task_self(), rx, size);
        rx = 0x300000000ul;
        kr = vm_allocate(mach_task_self(), &rx, size, VM_FLAGS_ANYWHERE);
    }
    if (kr == KERN_SUCCESS) {
        /* Max protection must allow EXEC; current RX. */
        kern_return_t k1 = vm_protect(mach_task_self(), rx, size, TRUE, VM_PROT_ALL);
        kern_return_t k2 = vm_protect(mach_task_self(), rx, size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
        vm_address_t rw = 0;
        kern_return_t k3 = (k2 == KERN_SUCCESS) ? make_rw_alias(rx, size, &rw) : k2;
        if (k3 == KERN_SUCCESS) {
            export_pool(rx, rw, size);
            rc = 0;
            LOG("JIT pool (simulator): RX=0x%lx RW=0x%lx size=0x%lx maxprot=%d", (unsigned long)rx,
                (unsigned long)rw, (unsigned long)size, k1);
        } else {
            snprintf(g_jit.error, sizeof g_jit.error, "simulator pool: protect=%d/%d remap=%d", k1, k2, k3);
            vm_deallocate(mach_task_self(), rx, size);
        }
    } else {
        snprintf(g_jit.error, sizeof g_jit.error, "simulator pool: vm_allocate %d", kr);
    }
#else
    snprintf(g_jit.method, sizeof g_jit.method, "debugger");
    if (!jit_check_debugged()) {
        snprintf(g_jit.error, sizeof g_jit.error, "JIT is not enabled (CS_DEBUGGED not set)");
    } else if (!cli_debugger_attached()) {
        snprintf(g_jit.error, sizeof g_jit.error,
                 "JIT is enabled but no debugger is attached; launch with JIT using the app's script");
    } else {
        /* An unanswered BRK must not kill the app. */
        jit_arm_trap_fallback();
        unsigned long pb = 0, ps = 0;
        madeira_early_pool_placeholder(&pb, &ps);
        if (pb && ps) vm_deallocate(mach_task_self(), pb, ps);
        /* Plug Wine's window (1 GB chunks, whatever is free) so the debugger's
         * allocation lands elsewhere; released right after (Madeira does the same). */
        vm_address_t plugs[64]; int nplugs = 0;
        for (vm_address_t a = GUEST_LO; a < GUEST_HI && nplugs < 64; a += (1ul << 30)) {
            vm_address_t t = a;
            if (vm_allocate(mach_task_self(), &t, 1ul << 30, VM_FLAGS_FIXED) == KERN_SUCCESS) plugs[nplugs++] = t;
        }
        void *rxp = NULL;
        void *bad[3]; int nbad = 0;
        for (int attempt = 0; attempt < 3 && !rxp; attempt++) {
            void *got = jit26_prepare_region(NULL, size);
            if (!got) break;
            if (!pool_placement_ok((vm_address_t)got, size)) {
                /* Keep the bad placement mapped so the next request lands elsewhere. */
                LOG("JIT pool: rejected placement %p", got);
                bad[nbad++] = got;
                continue;
            }
            rxp = got;
        }
        for (int i = 0; i < nbad; i++) vm_deallocate(mach_task_self(), (vm_address_t)bad[i], size);
        for (int i = 0; i < nplugs; i++) vm_deallocate(mach_task_self(), plugs[i], 1ul << 30);
        if (!rxp) {
            snprintf(g_jit.error, sizeof g_jit.error,
                     "the debugger did not prepare a JIT region (is the app's JIT script selected?)");
        } else {
            vm_address_t rw = 0;
            kern_return_t kr = make_rw_alias((vm_address_t)rxp, size, &rw);
            if (kr == KERN_SUCCESS) {
                jit_make_region_no_footprint((void *)rw, size, "jit-pool");
                export_pool((uint64_t)rxp, rw, size);
                rc = 0;
                LOG("JIT pool (debugger): RX=%p RW=0x%lx size=0x%lx", rxp, (unsigned long)rw, (unsigned long)size);
            } else {
                snprintf(g_jit.error, sizeof g_jit.error, "vm_remap of the JIT pool failed (%d)", kr);
            }
        }
        /* Detach as soon as the pool exists: Wine's signals would otherwise
         * all round-trip through the debugger (madeira-jit.js ml355). */
        jit26_detach();
        setenv("MADEIRA_DETACHED", "1", 1);
    }
#endif
    pthread_mutex_unlock(&g_jit_lock);
    cli_jit_query(info);
    return rc;
}

/* ======================================================================== */
/* Prefix                                                                    */
/* ======================================================================== */

void cli_seed_prefix_if_needed(const char *prefix_path) {
    @autoreleasepool {
        if (!prefix_path) return;
        NSString *prefix = [NSString stringWithUTF8String:prefix_path];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:prefix withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *stamp = [prefix stringByAppendingPathComponent:@".update-timestamp"];
        if (![fm fileExistsAtPath:stamp]) {
            NSString *tgz = [NSBundle.mainBundle pathForResource:@"prefix-template" ofType:@"tar.gz"];
            if (!tgz) LOG("prefix-template.tar.gz missing from bundle");
            else if (madeira_extract_prefix_tgz(tgz.UTF8String, prefix_path) != 0) LOG("prefix extraction failed");
            else LOG("prefix seeded");
        }
        NSString *dosdev = [prefix stringByAppendingPathComponent:@"dosdevices"];
        [fm createDirectoryAtPath:dosdev withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *cLink = [dosdev stringByAppendingPathComponent:@"c:"];
        [fm removeItemAtPath:cLink error:nil];
        [fm createSymbolicLinkAtPath:cLink withDestinationPath:@"../drive_c" error:nil];
    }
}

/* Called by WineServerBridge.m before the server thread starts (Madeira name). */
void madeira_seed_prefix_if_needed(const char *prefix_path) { cli_seed_prefix_if_needed(prefix_path); }

int cli_link_dll_farm(const char *prefix_path) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *src = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"aarch64-windows"];
        NSString *sys32 = [[NSString stringWithUTF8String:prefix_path]
                           stringByAppendingPathComponent:@"drive_c/windows/system32"];
        [fm createDirectoryAtPath:sys32 withIntermediateDirectories:YES attributes:nil error:nil];
        int linked = 0;
        for (NSString *name in [fm contentsOfDirectoryAtPath:src error:nil]) {
            NSString *s = [src stringByAppendingPathComponent:name];
            NSString *d = [sys32 stringByAppendingPathComponent:name];
            NSString *cur = [fm destinationOfSymbolicLinkAtPath:d error:nil];
            if (cur && [cur isEqualToString:s]) { linked++; continue; }
            [fm removeItemAtPath:d error:nil];   /* bundle path changes on reinstall */
            if ([fm createSymbolicLinkAtPath:d withDestinationPath:s error:nil]) linked++;
        }
        LOG("linked %d farm files into system32", linked);
        return linked;
    }
}

/* ======================================================================== */
/* Session                                                                   */
/* ======================================================================== */

typedef struct {
    char *prefix, *exe, *args, *workdir, *log_path;
    char **env;
    int stdin_pipe, stdout_pipe;
} session_copy;

static char *dupz(const char *s) { return s ? strdup(s) : NULL; }

/* CommandLineToArgvW-style split into argv (Madeira's madeira_split_launch_args
 * semantics, simplified: quotes group, backslashes before a quote escape it). */
static int split_args(const char *in, char *out, size_t outlen, char **argv, int max) {
    int argc = 0;
    if (!in) return 0;
    const char *p = in;
    char *d = out, *end = out + outlen - 1;
    while (*p) {
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;
        if (argc >= max || d >= end) return -1;
        argv[argc++] = d;
        int quoted = 0;
        while (*p && (quoted || (*p != ' ' && *p != '\t'))) {
            if (d >= end) return -1;
            if (*p == '\\') {
                int n = 0;
                while (p[n] == '\\') n++;
                if (p[n] == '"') {
                    for (int i = 0; i < n / 2; i++) { if (d >= end) return -1; *d++ = '\\'; }
                    if (n % 2) { *d++ = '"'; p += n + 1; } else p += n;
                } else {
                    for (int i = 0; i < n; i++) { if (d >= end) return -1; *d++ = '\\'; }
                    p += n;
                }
            } else if (*p == '"') {
                if (quoted && p[1] == '"') { *d++ = '"'; p += 2; }
                else { quoted = !quoted; p++; }
            } else *d++ = *p++;
        }
        *d++ = 0;
    }
    return argc;
}

static void *session_thread(void *arg) {
    session_copy *s = arg;
    @autoreleasepool {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);

        setenv("WINEPREFIX", s->prefix, 1);
        setenv("HOME", s->prefix, 1);
        setenv("WINELOADERNOEXEC", "1", 1);
        /* Fixed Windows user name: the profile is C:\users\user on every
         * device and in the simulator (ntdll's set_home_dir reads USER). */
        setenv("USER", "user", 1);
        setenv("WINEDLLPATH", NSBundle.mainBundle.bundlePath.UTF8String, 1);
        if (!getenv("WINEDEBUG")) setenv("WINEDEBUG", "err+all,err-virtual", 1);
        setenv("MADEIRA_WIN32U", "1", 1);
        setenv("MADEIRA_QUIET", "1", 1);
        for (char **e = s->env; e && *e; e++) {
            char *eq = strchr(*e, '=');
            if (!eq) continue;
            *eq = 0; setenv(*e, eq + 1, 1); *eq = '=';
        }
        if (s->log_path) wine_log_set_file(s->log_path);

        char exe_path[1024];
        if (strchr(s->exe, '\\') || (s->exe[0] && s->exe[1] == ':'))
            snprintf(exe_path, sizeof exe_path, "%s", s->exe);
        else
            snprintf(exe_path, sizeof exe_path, "C:\\windows\\system32\\%s", s->exe);

        static char args_buf[32768];
        static char *extra[256];
        int extra_argc = split_args(s->args, args_buf, sizeof args_buf, extra, 256);
        if (extra_argc < 0) {
            LOG("launch rejected: arguments too long");
            g_exit_code = -1;
            goto done;
        }
        char *argv[260];
        int argc = 0;
        argv[argc++] = "wine";
        argv[argc++] = exe_path;
        for (int i = 0; i < extra_argc; i++) argv[argc++] = extra[i];
        argv[argc] = NULL;
        LOG("launch %s (%d args)", exe_path, extra_argc);   /* arguments may hold secrets: not logged */

        /* Working folder: env_ios.c's get_initial_directory reads MADEIRA_INITIAL_CWD. */
        const char *wd = s->workdir;
        if (wd && (wd[0] == 'C' || wd[0] == 'c') && wd[1] == ':' && wd[2] == '\\') {
            char unix_dir[2048], rel[1024], wine_cwd[1100];
            snprintf(rel, sizeof rel, "%s", wd + 3);
            size_t n = strlen(rel);
            while (n && rel[n - 1] == '\\') rel[--n] = 0;
            for (char *q = rel; *q; q++) if (*q == '\\') *q = '/';
            snprintf(unix_dir, sizeof unix_dir, "%s/drive_c/%s", s->prefix, rel);
            mkdir(unix_dir, 0755);
            chdir(unix_dir);
            setenv("PWD", unix_dir, 1);
            snprintf(wine_cwd, sizeof wine_cwd, "C:\\%s%s", wd + 3, (n && wd[strlen(wd) - 1] != '\\') ? "\\" : "");
            if (!n) snprintf(wine_cwd, sizeof wine_cwd, "C:\\");
            setenv("MADEIRA_INITIAL_CWD", wine_cwd, 1);
        }

        wine_ios_main_thread = pthread_self();
        wine_ios_exit_initialized = 1;
        ios_main_image_i386 = 0;

        if (setjmp(wine_ios_exit_jmpbuf) == 0) {
            __wine_main(argc, argv);
            LOG("__wine_main returned");
        } else {
            LOG("program exited with code %d", wine_ios_exit_code);
        }
        g_exit_code = wine_ios_exit_code;
    }
done:
    /* Per-session variables must not leak into the next session. */
    for (char **e = s->env; e && *e; e++) {
        char *eq = strchr(*e, '=');
        if (!eq) continue;
        *eq = 0; unsetenv(*e); *eq = '=';
    }
    unsetenv("MADEIRA_INITIAL_CWD");
    /* Close our end of stdout so the reader sees EOF once everything drained. */
    if (s->stdout_pipe) { int nul = open("/dev/null", O_WRONLY); if (nul >= 0) { dup2(nul, STDOUT_FILENO); close(nul); } }
    __atomic_store_n(&g_running, 0, __ATOMIC_RELEASE);
    wineserver_stop();
    LOG("session finished");
    {
        /* TSD slot 275 holds this thread's TEB mirror (thread_ios.c); clear it
         * so pthread key destructors do not release a TEB (Madeira Steam S0). */
        uintptr_t tsd_base;
        __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(tsd_base));
        tsd_base &= ~7ULL;
        *(void **)(tsd_base + 275 * 8) = NULL;
    }
    return NULL;
}

int cli_session_start(const cli_session_params *p) {
    if (__atomic_load_n(&g_running, __ATOMIC_ACQUIRE)) { LOG("session already running"); return -1; }
    if (!p || !p->prefix || !p->exe) return -1;

    session_copy *s = calloc(1, sizeof *s);
    s->prefix = dupz(p->prefix); s->exe = dupz(p->exe); s->args = dupz(p->args);
    s->workdir = dupz(p->workdir); s->log_path = dupz(p->log_path);
    s->stdin_pipe = p->stdin_pipe; s->stdout_pipe = p->stdout_pipe;
    int n = 0;
    while (p->env && p->env[n]) n++;
    s->env = calloc(n + 1, sizeof(char *));
    for (int i = 0; i < n; i++) s->env[i] = strdup(p->env[i]);

    /* Logging: fd 2 is the Wine log (ERR channels, dprintf) and the
     * program's stderr. */
    if (p->log_path) setenv("CLI_WINE_LOG", p->log_path, 1);
    if (p->log_path) {
        int fd = open(p->log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) { dup2(fd, STDERR_FILENO); close(fd); }
    }
    /* fd 1: the program's stdout. All pseudo-processes share the fd table,
     * so this is set up before __wine_main and the app never writes fd 1. */
    if (g_stdout_r >= 0) { close(g_stdout_r); g_stdout_r = -1; }
    if (p->stdout_pipe) {
        int fds[2];
        if (pipe(fds) != 0) return -1;
        dup2(fds[1], STDOUT_FILENO); close(fds[1]);
        fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL, 0) | O_NONBLOCK);
        fcntl(fds[0], F_SETFD, FD_CLOEXEC);
        g_stdout_r = fds[0];
    } else if (p->log_path) {
        int fd = open(p->log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) { dup2(fd, STDOUT_FILENO); close(fd); }
    }
    if (g_stdin_w >= 0) { close(g_stdin_w); g_stdin_w = -1; }
    if (p->stdin_pipe) {
        int fds[2];
        if (pipe(fds) != 0) return -1;
        dup2(fds[0], STDIN_FILENO); close(fds[0]);
        fcntl(fds[1], F_SETFD, FD_CLOEXEC);
        g_stdin_w = fds[1];
    } else {
        int nul = open("/dev/null", O_RDONLY);
        if (nul >= 0) { dup2(nul, STDIN_FILENO); close(nul); }
    }

    cli_seed_prefix_if_needed(p->prefix);
    cli_link_dll_farm(p->prefix);

    __atomic_store_n(&g_launch_exit, 0, __ATOMIC_RELEASE);
    if (!wineserver_is_running()) {
        if (wineserver_start(p->prefix) != 0) { LOG("wineserver_start failed"); return -1; }
        for (int i = 0; i < 1000 && !wineserver_is_ready(); i++) usleep(10000);
        if (!wineserver_is_ready()) { LOG("wineserver not ready after 10 s"); return -1; }
    }

    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) { LOG("socketpair failed %d", errno); return -1; }
    char fd_str[16];
    snprintf(fd_str, sizeof fd_str, "%d", pair[1]);
    setenv("WINESERVERSOCKET", fd_str, 1);
    wineserver_inject_client_fd(pair[0]);

    __atomic_store_n(&g_running, 1, __ATOMIC_RELEASE);
    pthread_t t;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, 8 << 20);
    if (pthread_create(&t, &attr, session_thread, s) != 0) {
        __atomic_store_n(&g_running, 0, __ATOMIC_RELEASE);
        return -1;
    }
    pthread_attr_destroy(&attr);
    return 0;
}

int cli_session_running(void) { return __atomic_load_n(&g_running, __ATOMIC_ACQUIRE); }
int cli_session_exit_code(void) { return g_exit_code; }
uint32_t cli_session_crash_status(void) {
    uint64_t v = __atomic_load_n(&g_launch_exit, __ATOMIC_ACQUIRE);
    return (v >> 32) ? (uint32_t)v : 0;
}
int cli_stdout_fd(void) { return g_stdout_r; }
long cli_stdout_read(void *buf, unsigned long len) {
    if (g_stdout_r < 0) { errno = EBADF; return -1; }
    return read(g_stdout_r, buf, len);
}
long cli_stdin_write(const void *buf, unsigned long len) {
    if (g_stdin_w < 0) return -1;
    const char *b = buf;
    unsigned long done = 0;
    while (done < len) {
        ssize_t w = write(g_stdin_w, b + done, len - done);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        done += (unsigned long)w;
    }
    return (long)done;
}
void cli_stdin_close(void) { if (g_stdin_w >= 0) { close(g_stdin_w); g_stdin_w = -1; } }
void cli_session_shutdown(void) { wineserver_stop(); }

int cli_list_processes(char *buf, int len) { return cli_list_children(buf, len); }
