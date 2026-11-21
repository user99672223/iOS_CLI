/*
 * CLI app: live output capture for child processes.
 *
 * Claude Code's stream-json delivers a command's output only when the command
 * finishes. To show it while it runs, every write a Windows process makes to
 * its own standard output or error handle is also appended to
 * $CLI_CAPTURE_DIR/<pid>.log. The first line of each file is
 *   #pid <pid> <start-time> <command line>
 * The app tails these files and attributes them to the running Bash tool.
 *
 * file.c is compiled with -DNtWriteFile=cli_NtWriteFile_impl, so this file
 * provides the syscall entry point. Processes named in CLI_CAPTURE_SKIP
 * (default claude.exe, conhost.exe) are never captured: claude.exe's stdout
 * is the protocol itself.
 */
#if 0
#pragma makedep unix
#endif

#include "config.h"
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>

#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "windef.h"
#include "winternl.h"
#include "unix_private.h"

NTSTATUS WINAPI cli_NtWriteFile_impl( HANDLE handle, HANDLE event, PIO_APC_ROUTINE apc, void *apc_user,
                                      IO_STATUS_BLOCK *io, const void *buffer, ULONG length,
                                      LARGE_INTEGER *offset, ULONG *key );

#define CAP_SLOTS 64
static pthread_mutex_t cap_lock = PTHREAD_MUTEX_INITIALIZER;
static struct { ULONG_PTR pid; int fd; int skip; } cap_slots[CAP_SLOTS];
static int cap_next;
static int cap_enabled = -1;
static char cap_dir[1024];

static void cap_init(void)
{
    const char *d = getenv( "CLI_CAPTURE_DIR" );
    if (d && *d && strlen( d ) < sizeof(cap_dir) - 32)
    {
        strcpy( cap_dir, d );
        cap_enabled = 1;
    }
    else cap_enabled = 0;
}

static void wstr_to_utf8( const WCHAR *w, USHORT bytes, char *out, size_t outlen )
{
    size_t o = 0;
    USHORT n = bytes / sizeof(WCHAR), i;
    for (i = 0; i < n && o + 4 < outlen; i++)
    {
        unsigned int c = w[i];
        if (c >= 0xd800 && c < 0xdc00 && i + 1 < n && w[i + 1] >= 0xdc00 && w[i + 1] < 0xe000)
        {
            c = 0x10000 + ((c - 0xd800) << 10) + (w[i + 1] - 0xdc00);
            i++;
        }
        if (c == '\n' || c == '\r') c = ' ';
        if (c < 0x80) out[o++] = (char)c;
        else if (c < 0x800) { out[o++] = 0xc0 | (c >> 6); out[o++] = 0x80 | (c & 0x3f); }
        else if (c < 0x10000) { out[o++] = 0xe0 | (c >> 12); out[o++] = 0x80 | ((c >> 6) & 0x3f); out[o++] = 0x80 | (c & 0x3f); }
        else { out[o++] = 0xf0 | (c >> 18); out[o++] = 0x80 | ((c >> 12) & 0x3f); out[o++] = 0x80 | ((c >> 6) & 0x3f); out[o++] = 0x80 | (c & 0x3f); }
    }
    out[o] = 0;
}

static int image_is_skipped( const char *image )
{
    const char *skip = getenv( "CLI_CAPTURE_SKIP" );
    const char *base = strrchr( image, '\\' );
    char list[512], *tok, *save = NULL;
    base = base ? base + 1 : image;
    snprintf( list, sizeof(list), "%s", skip && *skip ? skip : "claude.exe,conhost.exe" );
    for (tok = strtok_r( list, ",", &save ); tok; tok = strtok_r( NULL, ",", &save ))
        if (!strcasecmp( base, tok )) return 1;
    return 0;
}

/* fd for the current process's capture file, or -1. Called with cap_lock held. */
static int cap_fd_for_current( void )
{
    TEB *teb = NtCurrentTeb();
    ULONG_PTR pid = (ULONG_PTR)teb->ClientId.UniqueProcess;
    RTL_USER_PROCESS_PARAMETERS *pp;
    char image[520], cmdline[2048], path[1100], header[2400];
    int i, fd, skip;

    for (i = 0; i < CAP_SLOTS; i++)
        if (cap_slots[i].pid == pid && pid) return cap_slots[i].skip ? -1 : cap_slots[i].fd;

    pp = teb->Peb ? teb->Peb->ProcessParameters : NULL;
    image[0] = cmdline[0] = 0;
    if (pp)
    {
        wstr_to_utf8( pp->ImagePathName.Buffer, pp->ImagePathName.Length, image, sizeof(image) );
        wstr_to_utf8( pp->CommandLine.Buffer, pp->CommandLine.Length, cmdline, sizeof(cmdline) );
    }
    skip = image_is_skipped( image );
    fd = -1;
    if (!skip)
    {
        snprintf( path, sizeof(path), "%s/%lu.log", cap_dir, (unsigned long)pid );
        fd = open( path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644 );
        if (fd >= 0)
        {
            int n = snprintf( header, sizeof(header), "#pid %lu %ld %s\n", (unsigned long)pid,
                              (long)time( NULL ), cmdline[0] ? cmdline : image );
            write( fd, header, n );
        }
    }
    /* Round-robin slots: a long session can start more than CAP_SLOTS processes. */
    i = cap_next++ % CAP_SLOTS;
    if (cap_slots[i].fd > 0 && !cap_slots[i].skip) close( cap_slots[i].fd );
    cap_slots[i].pid = pid;
    cap_slots[i].fd = fd;
    cap_slots[i].skip = skip || fd < 0;
    return fd;
}

static void cap_write( HANDLE handle, const void *buffer, ULONG length )
{
    TEB *teb = NtCurrentTeb();
    RTL_USER_PROCESS_PARAMETERS *pp;
    int fd;

    if (!teb || !teb->Peb || !(pp = teb->Peb->ProcessParameters)) return;
    if (handle != pp->hStdOutput && handle != pp->hStdError) return;
    pthread_mutex_lock( &cap_lock );
    fd = cap_fd_for_current();
    if (fd >= 0) write( fd, buffer, length );
    pthread_mutex_unlock( &cap_lock );
}

NTSTATUS WINAPI NtWriteFile( HANDLE handle, HANDLE event, PIO_APC_ROUTINE apc, void *apc_user,
                             IO_STATUS_BLOCK *io, const void *buffer, ULONG length,
                             LARGE_INTEGER *offset, ULONG *key )
{
    NTSTATUS status = cli_NtWriteFile_impl( handle, event, apc, apc_user, io, buffer, length, offset, key );
    if (cap_enabled < 0) cap_init();
    if (cap_enabled > 0 && buffer && length && (status == STATUS_SUCCESS || status == STATUS_PENDING))
        cap_write( handle, buffer, length );
    return status;
}
