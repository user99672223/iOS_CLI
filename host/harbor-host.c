/*
 * harbor-host.exe - the persistent main program of the app's Wine session.
 *
 * The iOS app runs exactly one Wine process for its whole lifetime (starting
 * a second wineserver in the same app process is not possible), and every
 * Windows program the app needs (claude.exe, cmd.exe, git, ...) is started
 * from here as a child process. Each child's standard input, output and error
 * are pipes owned by this program and relayed to the app over this program's
 * own stdin/stdout, as tab-separated lines (variable fields base64-encoded):
 *
 * app -> host
 *   RUN <id> <flags> <b64 cwd> <b64 command line> <b64 env>
 *        flags: "-" or letters: p = pseudo console (ConPTY), e = stderr into stdout
 *        env: NAME=VALUE entries separated by U+001F, added to this process's environment
 *   IN <id> <b64 data>          write to the child's stdin
 *   EOF <id>                    close the child's stdin
 *   KILL <id>                   terminate the child
 *   RESIZE <id> <cols> <rows>   resize a pseudo console
 *   QUIT                        terminate every child and exit
 *
 * host -> app
 *   READY <pid>
 *   STARTED <id> <pid>
 *   FAILED <id> <win32 error>
 *   OUT <id> <b64 data> / ERR <id> <b64 data>
 *   EXIT <id> <exit code>
 *
 * Build: aarch64-w64-mingw32-gcc -O2 -municode -o harbor-host.exe harbor-host.c
 */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#ifndef PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
#define PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE 0x00020016
#endif
typedef VOID *HPCON_;
typedef HRESULT (WINAPI *pCreatePseudoConsole)(COORD, HANDLE, HANDLE, DWORD, HPCON_ *);
typedef HRESULT (WINAPI *pResizePseudoConsole)(HPCON_, COORD);
typedef VOID (WINAPI *pClosePseudoConsole)(HPCON_);

static CRITICAL_SECTION out_lock;
static HANDLE out_handle;

/* ---------------- base64 ---------------- */

static const char b64chars[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static size_t b64_encode(const unsigned char *in, size_t len, char *out)
{
    size_t i, o = 0;
    for (i = 0; i + 2 < len; i += 3)
    {
        out[o++] = b64chars[in[i] >> 2];
        out[o++] = b64chars[((in[i] & 3) << 4) | (in[i + 1] >> 4)];
        out[o++] = b64chars[((in[i + 1] & 15) << 2) | (in[i + 2] >> 6)];
        out[o++] = b64chars[in[i + 2] & 63];
    }
    if (i < len)
    {
        out[o++] = b64chars[in[i] >> 2];
        if (i + 1 < len)
        {
            out[o++] = b64chars[((in[i] & 3) << 4) | (in[i + 1] >> 4)];
            out[o++] = b64chars[(in[i + 1] & 15) << 2];
        }
        else
        {
            out[o++] = b64chars[(in[i] & 3) << 4];
            out[o++] = '=';
        }
        out[o++] = '=';
    }
    out[o] = 0;
    return o;
}

static int b64_val(char c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+' || c == '-') return 62;
    if (c == '/' || c == '_') return 63;
    return -1;
}

/* Decodes in place-safe into out (out may equal in). Returns length. */
static size_t b64_decode(const char *in, unsigned char *out)
{
    size_t o = 0;
    unsigned int acc = 0;
    int bits = 0, v;
    for (; *in; in++)
    {
        if ((v = b64_val(*in)) < 0) continue;
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8)
        {
            bits -= 8;
            out[o++] = (unsigned char)(acc >> bits);
        }
    }
    return o;
}

/* ---------------- output to the app ---------------- */

static void emit(const char *line, size_t len)
{
    DWORD done;
    EnterCriticalSection(&out_lock);
    while (len)
    {
        if (!WriteFile(out_handle, line, (DWORD)len, &done, NULL) || !done) break;
        line += done;
        len -= done;
    }
    LeaveCriticalSection(&out_lock);
}

static void emitf(const char *fmt, ...)
{
    char buf[256];
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0) emit(buf, (size_t)n);
}

static void emit_data(const char *tag, unsigned int id, const unsigned char *data, size_t len)
{
    char *line = malloc(len * 4 / 3 + 64);
    int n;
    if (!line) return;
    n = sprintf(line, "%s %u ", tag, id);
    n += (int)b64_encode(data, len, line + n);
    line[n++] = '\n';
    emit(line, n);
    free(line);
}

/* ---------------- children ---------------- */

#define MAX_CHILDREN 64

struct child
{
    unsigned int id;
    int used;
    HANDLE process;
    HANDLE in_w;            /* our end of the child's stdin */
    HANDLE out_r, err_r;    /* our ends of stdout / stderr */
    HANDLE readers[2];
    HPCON_ pcon;
    LONG exited_reported;
};

static struct child children[MAX_CHILDREN];
static CRITICAL_SECTION child_lock;
static pCreatePseudoConsole p_create_pc;
static pResizePseudoConsole p_resize_pc;
static pClosePseudoConsole p_close_pc;

static struct child *find_child(unsigned int id)
{
    int i;
    for (i = 0; i < MAX_CHILDREN; i++)
        if (children[i].used && children[i].id == id) return &children[i];
    return NULL;
}

struct reader_args { struct child *c; HANDLE h; const char *tag; };

static DWORD WINAPI reader_thread(void *arg)
{
    struct reader_args *a = arg;
    unsigned char buf[16384];
    DWORD got;
    while (ReadFile(a->h, buf, sizeof(buf), &got, NULL) && got)
        emit_data(a->tag, a->c->id, buf, got);
    free(a);
    return 0;
}

static DWORD WINAPI waiter_thread(void *arg)
{
    struct child *c = arg;
    DWORD code = 0, i, n = 0;
    HANDLE r[2];

    WaitForSingleObject(c->process, INFINITE);
    GetExitCodeProcess(c->process, &code);
    /* A pseudo console keeps its output pipe open until it is closed. */
    if (c->pcon && p_close_pc) { p_close_pc(c->pcon); c->pcon = NULL; }
    for (i = 0; i < 2; i++) if (c->readers[i]) r[n++] = c->readers[i];
    /* Grandchildren may still hold the pipes: give the readers a moment. */
    if (n) WaitForMultipleObjects(n, r, TRUE, 3000);
    emitf("EXIT %u %lu\n", c->id, (unsigned long)code);

    EnterCriticalSection(&child_lock);
    if (c->in_w) CloseHandle(c->in_w);
    CloseHandle(c->process);
    for (i = 0; i < 2; i++) if (c->readers[i]) CloseHandle(c->readers[i]);
    if (c->out_r) CloseHandle(c->out_r);
    if (c->err_r) CloseHandle(c->err_r);
    memset(c, 0, sizeof(*c));
    LeaveCriticalSection(&child_lock);
    return 0;
}

static WCHAR *utf8_to_wide(const char *s, int len)
{
    int n = MultiByteToWideChar(CP_UTF8, 0, s, len, NULL, 0);
    WCHAR *w = malloc((n + 1) * sizeof(WCHAR));
    if (!w) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, s, len, w, n);
    w[n] = 0;
    return w;
}

static int env_name_eq(const WCHAR *a, const WCHAR *b)
{
    while (*a && *b && *a != '=' && *b != '=')
    {
        if (towupper(*a) != towupper(*b)) return 0;
        a++; b++;
    }
    return (*a == '=' || !*a) && (*b == '=' || !*b);
}

/* This process's environment plus overrides (NAME=VALUE entries separated by 0x1f). */
static WCHAR *build_env(const char *overrides, size_t olen)
{
    WCHAR *base = GetEnvironmentStringsW(), *p, *out, *o;
    WCHAR **over = NULL;
    size_t nover = 0, total = 0, i;
    const char *s = overrides, *end = overrides + olen;

    while (s < end)
    {
        const char *e = memchr(s, 0x1f, end - s);
        if (!e) e = end;
        if (e > s)
        {
            over = realloc(over, (nover + 1) * sizeof(*over));
            over[nover++] = utf8_to_wide(s, (int)(e - s));
        }
        s = e + 1;
    }
    for (p = base; *p; p += wcslen(p) + 1) total += wcslen(p) + 1;
    for (i = 0; i < nover; i++) total += wcslen(over[i]) + 1;
    out = o = malloc((total + 2) * sizeof(WCHAR));
    for (p = base; *p; p += wcslen(p) + 1)
    {
        int replaced = 0;
        for (i = 0; i < nover; i++) if (env_name_eq(p, over[i])) replaced = 1;
        if (replaced) continue;
        wcscpy(o, p); o += wcslen(p) + 1;
    }
    for (i = 0; i < nover; i++)
    {
        wcscpy(o, over[i]); o += wcslen(over[i]) + 1;
        free(over[i]);
    }
    *o = 0;
    free(over);
    FreeEnvironmentStringsW(base);
    return out;
}

static void start_reader(struct child *c, int slot, HANDLE h, const char *tag)
{
    struct reader_args *a = malloc(sizeof(*a));
    a->c = c; a->h = h; a->tag = tag;
    c->readers[slot] = CreateThread(NULL, 0, reader_thread, a, 0, NULL);
}

static void do_run(unsigned int id, const char *flags, char *cwd64, char *cmd64, char *env64)
{
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
    STARTUPINFOEXW si;
    PROCESS_INFORMATION pi;
    HANDLE in_r = NULL, in_w = NULL, out_r = NULL, out_w = NULL, err_r = NULL, err_w = NULL;
    int pty = strchr(flags, 'p') != NULL, merge = strchr(flags, 'e') != NULL;
    size_t n;
    WCHAR *cwd = NULL, *cmd, *env;
    struct child *c = NULL;
    DWORD create_flags = CREATE_UNICODE_ENVIRONMENT;
    SIZE_T attr_size = 0;
    int i;

    n = b64_decode(cwd64, (unsigned char *)cwd64); cwd64[n] = 0;
    if (n && strcmp(cwd64, "-")) cwd = utf8_to_wide(cwd64, (int)n);
    n = b64_decode(cmd64, (unsigned char *)cmd64); cmd64[n] = 0;
    cmd = utf8_to_wide(cmd64, (int)n);
    n = b64_decode(env64, (unsigned char *)env64);
    env = build_env(env64, n);

    EnterCriticalSection(&child_lock);
    for (i = 0; i < MAX_CHILDREN; i++) if (!children[i].used) { c = &children[i]; break; }
    if (c) { memset(c, 0, sizeof(*c)); c->used = 1; c->id = id; }
    LeaveCriticalSection(&child_lock);
    if (!c) { emitf("FAILED %u %lu\n", id, (unsigned long)ERROR_TOO_MANY_OPEN_FILES); goto done; }

    memset(&si, 0, sizeof(si));
    si.StartupInfo.cb = sizeof(si);

    if (pty && p_create_pc)
    {
        COORD size = { 120, 40 };
        CreatePipe(&in_r, &in_w, NULL, 0);
        CreatePipe(&out_r, &out_w, NULL, 0);
        if (FAILED(p_create_pc(size, in_r, out_w, 0, &c->pcon)))
        {
            emitf("FAILED %u %lu\n", id, (unsigned long)GetLastError());
            CloseHandle(in_r); CloseHandle(in_w); CloseHandle(out_r); CloseHandle(out_w);
            c->used = 0;
            goto done;
        }
        InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
        si.lpAttributeList = malloc(attr_size);
        InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_size);
        UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                  c->pcon, sizeof(c->pcon), NULL, NULL);
        si.StartupInfo.cb = sizeof(STARTUPINFOEXW);
        create_flags |= EXTENDED_STARTUPINFO_PRESENT;
        if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, create_flags, env, cwd, &si.StartupInfo, &pi))
        {
            emitf("FAILED %u %lu\n", id, (unsigned long)GetLastError());
            p_close_pc(c->pcon);
            CloseHandle(in_r); CloseHandle(in_w); CloseHandle(out_r); CloseHandle(out_w);
            c->used = 0;
            goto done;
        }
        CloseHandle(in_r);
        CloseHandle(out_w);
        c->in_w = in_w;
        c->out_r = out_r;
    }
    else
    {
        CreatePipe(&in_r, &in_w, &sa, 0);
        CreatePipe(&out_r, &out_w, &sa, 0);
        if (!merge) CreatePipe(&err_r, &err_w, &sa, 0);
        SetHandleInformation(in_w, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);
        if (err_r) SetHandleInformation(err_r, HANDLE_FLAG_INHERIT, 0);
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        si.StartupInfo.hStdInput = in_r;
        si.StartupInfo.hStdOutput = out_w;
        si.StartupInfo.hStdError = merge ? out_w : err_w;
        if (!CreateProcessW(NULL, cmd, NULL, NULL, TRUE, create_flags | CREATE_NO_WINDOW, env, cwd, &si.StartupInfo, &pi))
        {
            emitf("FAILED %u %lu\n", id, (unsigned long)GetLastError());
            CloseHandle(in_r); CloseHandle(in_w); CloseHandle(out_r); CloseHandle(out_w);
            if (err_r) { CloseHandle(err_r); CloseHandle(err_w); }
            c->used = 0;
            goto done;
        }
        CloseHandle(in_r);
        CloseHandle(out_w);
        if (err_w) CloseHandle(err_w);
        c->in_w = in_w;
        c->out_r = out_r;
        c->err_r = err_r;
    }
    CloseHandle(pi.hThread);
    c->process = pi.hProcess;
    emitf("STARTED %u %lu\n", id, (unsigned long)pi.dwProcessId);
    start_reader(c, 0, c->out_r, "OUT");
    if (c->err_r) start_reader(c, 1, c->err_r, "ERR");
    CloseHandle(CreateThread(NULL, 0, waiter_thread, c, 0, NULL));

done:
    if (si.lpAttributeList) { DeleteProcThreadAttributeList(si.lpAttributeList); free(si.lpAttributeList); }
    free(cwd); free(cmd); free(env);
}

static void do_in(unsigned int id, char *data64)
{
    struct child *c;
    size_t n = b64_decode(data64, (unsigned char *)data64);
    DWORD done;
    HANDLE h = NULL;
    EnterCriticalSection(&child_lock);
    if ((c = find_child(id)) && c->in_w) h = c->in_w;
    LeaveCriticalSection(&child_lock);
    if (h) WriteFile(h, data64, (DWORD)n, &done, NULL);
}

static void do_eof(unsigned int id)
{
    struct child *c;
    EnterCriticalSection(&child_lock);
    if ((c = find_child(id)) && c->in_w) { CloseHandle(c->in_w); c->in_w = NULL; }
    LeaveCriticalSection(&child_lock);
}

static void do_kill(unsigned int id)
{
    struct child *c;
    EnterCriticalSection(&child_lock);
    if ((c = find_child(id)) && c->process) TerminateProcess(c->process, 1);
    LeaveCriticalSection(&child_lock);
}

static void do_resize(unsigned int id, int cols, int rows)
{
    struct child *c;
    COORD size;
    size.X = (SHORT)cols; size.Y = (SHORT)rows;
    EnterCriticalSection(&child_lock);
    if ((c = find_child(id)) && c->pcon && p_resize_pc) p_resize_pc(c->pcon, size);
    LeaveCriticalSection(&child_lock);
}

/* ---------------- main loop ---------------- */

static char *next_field(char **p)
{
    char *s = *p, *e;
    if (!s) return (char *)"";
    e = strchr(s, '\t');
    if (e) { *e = 0; *p = e + 1; } else *p = NULL;
    return s;
}

static void handle_line(char *line)
{
    char *p = line, *cmd = next_field(&p);
    if (!strcmp(cmd, "RUN"))
    {
        unsigned int id = strtoul(next_field(&p), NULL, 10);
        char *flags = next_field(&p), *cwd = next_field(&p), *cmdline = next_field(&p), *env = next_field(&p);
        do_run(id, flags, cwd, cmdline, env);
    }
    else if (!strcmp(cmd, "IN"))
    {
        unsigned int id = strtoul(next_field(&p), NULL, 10);
        do_in(id, next_field(&p));
    }
    else if (!strcmp(cmd, "EOF")) do_eof(strtoul(next_field(&p), NULL, 10));
    else if (!strcmp(cmd, "KILL")) do_kill(strtoul(next_field(&p), NULL, 10));
    else if (!strcmp(cmd, "RESIZE"))
    {
        unsigned int id = strtoul(next_field(&p), NULL, 10);
        int cols = atoi(next_field(&p));
        do_resize(id, cols, atoi(next_field(&p)));
    }
    else if (!strcmp(cmd, "QUIT"))
    {
        int i;
        for (i = 0; i < MAX_CHILDREN; i++) if (children[i].used && children[i].process) TerminateProcess(children[i].process, 1);
        ExitProcess(0);
    }
}

int wmain(void)
{
    HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
    HMODULE k32 = GetModuleHandleW(L"kernel32.dll");
    char *buf, *line;
    size_t cap = 1 << 20, len = 0;
    DWORD got;

    InitializeCriticalSection(&out_lock);
    InitializeCriticalSection(&child_lock);
    out_handle = GetStdHandle(STD_OUTPUT_HANDLE);
    p_create_pc = (pCreatePseudoConsole)GetProcAddress(k32, "CreatePseudoConsole");
    p_resize_pc = (pResizePseudoConsole)GetProcAddress(k32, "ResizePseudoConsole");
    p_close_pc = (pClosePseudoConsole)GetProcAddress(k32, "ClosePseudoConsole");
    emitf("READY %lu\n", (unsigned long)GetCurrentProcessId());

    buf = malloc(cap);
    for (;;)
    {
        char *nl;
        if (len + 65536 > cap) { cap *= 2; buf = realloc(buf, cap); }
        if (!ReadFile(in, buf + len, (DWORD)(cap - len - 1), &got, NULL) || !got) break;
        len += got;
        buf[len] = 0;
        line = buf;
        while ((nl = memchr(line, '\n', buf + len - line)))
        {
            *nl = 0;
            if (nl > line && nl[-1] == '\r') nl[-1] = 0;
            handle_line(line);
            line = nl + 1;
        }
        len -= line - buf;
        memmove(buf, line, len);
    }
    /* The app closed our stdin: end every child. */
    {
        int i;
        for (i = 0; i < MAX_CHILDREN; i++) if (children[i].used && children[i].process) TerminateProcess(children[i].process, 1);
    }
    return 0;
}
