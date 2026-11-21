#!/bin/bash
set -e

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
WINE_BUILD="$WINE_SRC/build-macos"
. "$(cd "$(dirname "$0")/.." && pwd)/platform.sh"
OBJ_DIR="$BUILD_DIR/obj-$PLATFORM"
APP_LIB="$OUT_DIR/libntdll_unix.a"

mkdir -p "$OBJ_DIR"

# Optional Vulkan route; do not change the normal native build.
VULKAN_FLAGS=()
if [ "${MADEIRA_MOLTENVK:-0}" = 1 ]; then
    VULKAN_FLAGS=(-DMADEIRA_MOLTENVK=1)
fi

# Detect optional diagnostic fields in the SDK used for this target build.
# Keep SDK versions without this member buildable; it is not a runtime requirement.
RUSAGE_PAGE_WAIT_FLAGS=()
if printf '#include <sys/resource.h>\nvoid probe(struct rusage_info_v6 *r) { (void)r->ri_page_wait_time_mach; }\n' | \
    xcrun -sdk "$PLATFORM" clang -target "$TRIPLE" -isysroot "$SDK" \
         -x c -fsyntax-only - >/dev/null 2>&1; then
    RUSAGE_PAGE_WAIT_FLAGS=(-DMADEIRA_HAVE_RUSAGE_PAGE_WAIT_TIME_MACH=1)

fi

SUCCEEDED=0
FAILED=0
FAILED_FILES=""

compile_one() {
    local src=$1
    local name=$2
    shift 2   # anything after src and name: extra flags for this file only
    echo -n "  $name... "

    if xcrun -sdk "$PLATFORM" clang \
        -target "$TRIPLE" -isysroot "$SDK" \
        -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
        "${VULKAN_FLAGS[@]}" \
        -Wno-implicit-function-declaration -Wno-int-conversion \
        -include "$WINE_BUILD/include/config.h" \
        -include "$BUILD_DIR/shims/wine_ios_exit.h" \
        -I"$BUILD_DIR/shims" -I"$BUILD_DIR/../madsync" -DHAVE_LINUX_NTSYNC_H=1 \
        -I"$WINE_BUILD/dlls/ntdll" -I"$WINE_SRC/dlls/ntdll" -I"$WINE_SRC/dlls/ntdll/unix" \
        -I"$WINE_BUILD/include" -I"$WINE_SRC/include" \
        -D__WINESRC__ -DLTC_NO_PROTOTYPES -DLTC_SOURCE -D_NTSYSTEM_ \
        -D_ACRTIMP= -DWINBASEAPI= \
        -DBINDIR=\"/usr/local/bin\" -DLIBDIR=\"/usr/local/lib\" \
        -DDATADIR=\"/usr/local/share\" -DSYSTEMDLLPATH=\"\" \
        -DWINE_UNIX_LIB -DWINE_IOS=1 \
        "${RUSAGE_PAGE_WAIT_FLAGS[@]}" \
        -Dget_thread_context=ntdll_get_thread_context \
        -Dset_thread_context=ntdll_set_thread_context \
        "$@" \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"
        SUCCEEDED=$((SUCCEEDED + 1))
    else
        echo "FAILED"
        FAILED=$((FAILED + 1))
        FAILED_FILES="$FAILED_FILES $name"
    fi
}

# iOS-Madeira 2026-07-05 (Steam S0): compile a DLL's unix side into
# libntdll_unix.a. Args: src, obj-name, funcs-prefix, extra flags...
# The __wine_unix_call_funcs tables are renamed per-lib (they'd collide
# in one archive) and registered by name in virtual_ios.c's
# load_builtin_unixlib. GnuTLS-backed libs add ios_gnutls_shim.h to
# route dlopen/dlsym at the static symtab (gnutls_symtab_ios.c).
CRYPTO_DIR="$REPO_ROOT/build/crypto-unix"
GNUTLS_PREFIX="${GNUTLS_PREFIX:-$REPO_ROOT/toolchains/gnutls-ios-$PLATFORM}"
compile_unixlib() {
    local src=$1 name=$2 prefix=$3
    shift 3
    echo -n "  $name... "
    if xcrun -sdk "$PLATFORM" clang \
        -target "$TRIPLE" -isysroot "$SDK" \
        -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
        "${VULKAN_FLAGS[@]}" \
        -Wno-implicit-function-declaration -Wno-int-conversion \
        -include "$WINE_BUILD/include/config.h" \
        -include "$BUILD_DIR/shims/wine_ios_exit.h" \
        -I"$BUILD_DIR/shims" -I"$BUILD_DIR/../madsync" -DHAVE_LINUX_NTSYNC_H=1 \
        -I"$WINE_BUILD/include" -I"$WINE_SRC/include" \
        -D__WINESRC__ -D_NTSYSTEM_ -D_ACRTIMP= -DWINBASEAPI= \
        -DWINE_UNIX_LIB -DWINE_IOS=1 \
        -D__wine_unix_call_funcs=${prefix}_unix_call_funcs \
        -D__wine_unix_call_wow64_funcs=${prefix}_unix_call_wow64_funcs \
        "$@" \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"
        SUCCEEDED=$((SUCCEEDED + 1))
    else
        echo "FAILED"
        FAILED=$((FAILED + 1))
        FAILED_FILES="$FAILED_FILES $name"
    fi
}

echo "=== Building ntdll unix (iOS) ==="

# iOS-Madeira 2026-05-13: silent audio driver — provides a null
# IAudioClock that advances at real time so FMOD's audio-gated rhythm
# logic in Thumper et al. advances past intro music.
compile_one "$BUILD_DIR/audio_null_ios.c" "audio_null_ios"
compile_one "$BUILD_DIR/../madsync/madsync.c" "madsync"   # ml1058: userspace ntsync

# iOS-Madeira 2026-07-05 (Steam S0): network + crypto unix sides.
echo "=== Building crypto/network unixlibs ==="
# CLI build: GnuTLS is optional (Bun and Git bring their own TLS). Without the
# archive, bcrypt/secur32/crypt32 compile to their no-GnuTLS variants.
if [ -f "$GNUTLS_PREFIX/lib/libgnutls.a" ]; then
    "$CRYPTO_DIR/gen_gnutls_symtab.sh" > /dev/null
    compile_one "$CRYPTO_DIR/gnutls_symtab_ios.c" "gnutls_symtab_ios"
fi
compile_unixlib "$WINE_SRC/dlls/ws2_32/unixlib.c" "ws2_32_unixlib" "ws2_32" \
    -I"$WINE_SRC/dlls/ws2_32"
# madeira-gnutls-unixlibs: the host configure cannot detect an iOS arm64 static
# archive, so config.h leaves HAVE_GNUTLS_CIPHER_INIT and SONAME_LIBGNUTLS
# undefined and all three sources below compile to empty objects. The iOS chain
# links GnuTLS statically regardless (see ios_gnutls_shim.h), so define them
# here -- on these three translation units only, because the host build really
# does not have GnuTLS and config.h should keep saying so.
#
# Warns rather than fails when the prefix is absent, so a tree that has never
# run build/gnutls-ios/build.sh still builds exactly as it does today -- it
# just keeps getting the empty objects, and now says so instead of leaving it
# to be discovered by a program whose HTTPS request goes nowhere.
GNUTLS_DEFS=()
if [ -f "$GNUTLS_PREFIX/lib/libgnutls.a" ]; then
    GNUTLS_DEFS=(-DHAVE_GNUTLS_CIPHER_INIT '-DSONAME_LIBGNUTLS="libgnutls.so.30"')
else
    echo "WARNING: $GNUTLS_PREFIX/lib/libgnutls.a is missing, so bcrypt," >&2
    echo "         secur32 and crypt32 compile to empty objects and guest-side" >&2
    echo "         TLS will not work. Run build/gnutls-ios/build.sh to fix." >&2
fi

compile_unixlib "$WINE_SRC/dlls/bcrypt/gnutls.c" "bcrypt_unixlib" "bcrypt" \
    -I"$WINE_SRC/dlls/bcrypt" -I"$GNUTLS_PREFIX/include" \
    -include "$CRYPTO_DIR/ios_gnutls_shim.h" \
    "${GNUTLS_DEFS[@]}"
compile_unixlib "$WINE_SRC/dlls/secur32/schannel_gnutls.c" "secur32_unixlib" "secur32" \
    -I"$WINE_SRC/dlls/secur32" -I"$GNUTLS_PREFIX/include" \
    -include "$CRYPTO_DIR/ios_gnutls_shim.h" \
    "${GNUTLS_DEFS[@]}"
compile_unixlib "$CRYPTO_DIR/crypt32_unixlib_ios.c" "crypt32_unixlib" "crypt32" \
    -I"$WINE_SRC/dlls/crypt32" -I"$GNUTLS_PREFIX/include" \
    -include "$CRYPTO_DIR/ios_gnutls_shim.h" \
    "${GNUTLS_DEFS[@]}"
if [ ${#GNUTLS_DEFS[@]} -gt 0 ]; then
    for module in bcrypt secur32 crypt32; do
        for table in unix_call_funcs unix_call_wow64_funcs; do
            xcrun nm -gU "$OBJ_DIR/${module}_unixlib.o" | grep -Eq "[[:space:]]_${module}_${table}$" || {
                echo "ERROR: $module did not build its $table table" >&2
                exit 1
            }
        done
    done
fi
# iOS-Madeira 2026-08-03 (#79 transport): in-process NSI TCP connection
# tables (nsiproxy.sys is not shipped; PE nsi.dll falls back to this).
compile_one "$BUILD_DIR/nsi_unixlib_ios.c" "nsi_unixlib_ios"
# iOS-Madeira: the other NSI tables (network interfaces, IP addresses,
# routes) from Wine's own BSD providers, wine/dlls/nsiproxy.sys/ndis.c and
# ip.c, behind nsiproxy.sys's table dispatcher (nsi_network_ios.c).
# shims/net/route.h declares the routing-message ABI they read, which the
# iPhoneOS SDK does not ship.
compile_one "$BUILD_DIR/nsi_network_ios.c" "nsi_network_ios"
compile_one "$BUILD_DIR/nsi_ndis_ios.c" "nsi_ndis"
compile_one "$BUILD_DIR/nsi_ip_ios.c" "nsi_ip"
# dnsapi had no unix side (the generic stub table: every call STATUS_NOT_SUPPORTED,
# including the DNS server list GetAdaptersAddresses asks for). dnsapi_unixlib_ios.c
# is upstream dlls/dnsapi/libresolv.c with res_init/res_query/_res/h_errno rebound to
# /usr/lib/libresolv.9.dylib through dlopen, so nothing is added to the app's link.
compile_unixlib "$BUILD_DIR/dnsapi_unixlib_ios.c" "dnsapi_unixlib" "dnsapi" \
    -I"$WINE_SRC/dlls/dnsapi"
for src in $WINE_SRC/dlls/ntdll/unix/*.c; do
    name=$(basename "$src" .c)

    # Use patched versions for specific files
    case "$name" in
        loader)
            compile_one "$BUILD_DIR/loader_ios.c" "loader"
            ;;
        process)
            compile_one "$BUILD_DIR/process_ios.c" "process"
            ;;
        server)
            compile_one "$BUILD_DIR/server_ios.c" "server"
            ;;
        env)
            compile_one "$BUILD_DIR/env_ios.c" "env"
            ;;
        cdrom)
            compile_one "$BUILD_DIR/cdrom_stub.c" "cdrom"
            ;;
        virtual)
            compile_one "$BUILD_DIR/virtual_ios.c" "virtual"
            ;;
        signal_arm64)
            compile_one "$BUILD_DIR/signal_arm64_ios.c" "signal_arm64"
            ;;
        thread)
            compile_one "$BUILD_DIR/thread_ios.c" "thread"
            ;;
        sync)
            # madeira-bcd: a NULL keyed-event handle resolves per guest process
            # (ios_default_keyed_event, loader_ios.c), not to the first process's
            # global. The copy is compiled from obj/, so its one relative include
            # is made absolute; the build fails if the source no longer matches.
            perl -0pe 's/(NTSTATUS WINAPI NtWaitForKeyedEvent\()/HANDLE ios_default_keyed_event(void);\n$1/;
                       s/if \(!handle\) handle = keyed_event;/if (!handle) handle = ios_default_keyed_event();/g;
                       s{"\.\./\.\./\.\./\.\./build/madeira_cfg\.h"}{"'"$REPO_ROOT"'/build/madeira_cfg.h"}' \
                "$src" > "$OBJ_DIR/sync_ios.c"
            if [ "$(grep -c 'handle = ios_default_keyed_event()' "$OBJ_DIR/sync_ios.c")" != 2 ]; then
                echo "  sync: keyed-event patch did not apply"; exit 1
            fi
            # MADEIRA_THREAD_QOS (thread_ios.c): ios_eco_apply_self sets a guest
            # thread's QoS through madeira_guest_qos_self, which picks the class
            # given for the thread's name; with the variable unset it passes through.
            compile_one "$OBJ_DIR/sync_ios.c" "sync" -Dpthread_set_qos_class_self_np=madeira_guest_qos_self
            ;;
        *)
            compile_one "$src" "$name"
            ;;
    esac
done

echo ""
echo "Results: $SUCCEEDED succeeded, $FAILED failed"
if [ -n "$FAILED_FILES" ]; then
    echo "Failed:$FAILED_FILES"
    for f in $FAILED_FILES; do echo "=== $f ==="; head -40 "$OBJ_DIR/$f.err"; done
    exit 1
fi

echo ""
echo "=== Building libntdll_unix.a ==="
ar rcs "$OBJ_DIR/libntdll_unix.a" \
    "$OBJ_DIR/audio_null_ios.o" "$OBJ_DIR/madsync.o" "$OBJ_DIR/nsi_unixlib_ios.o" \
    "$OBJ_DIR/nsi_network_ios.o" "$OBJ_DIR/nsi_ndis.o" "$OBJ_DIR/nsi_ip.o" \
    $([ -f "$OBJ_DIR/gnutls_symtab_ios.o" ] && echo "$OBJ_DIR/gnutls_symtab_ios.o") "$OBJ_DIR/ws2_32_unixlib.o" \
    "$OBJ_DIR/bcrypt_unixlib.o" "$OBJ_DIR/secur32_unixlib.o" "$OBJ_DIR/crypt32_unixlib.o" \
    "$OBJ_DIR/dnsapi_unixlib.o" \
    "$OBJ_DIR/cdrom.o" "$OBJ_DIR/debug.o" "$OBJ_DIR/env.o" "$OBJ_DIR/file.o" \
    "$OBJ_DIR/loader.o" "$OBJ_DIR/loadorder.o" "$OBJ_DIR/process.o" "$OBJ_DIR/registry.o" \
    "$OBJ_DIR/security.o" "$OBJ_DIR/serial.o" "$OBJ_DIR/server.o" \
    "$OBJ_DIR/signal_arm.o" "$OBJ_DIR/signal_arm64.o" "$OBJ_DIR/signal_i386.o" "$OBJ_DIR/signal_x86_64.o" \
    "$OBJ_DIR/socket.o" "$OBJ_DIR/sync.o" "$OBJ_DIR/syscall.o" "$OBJ_DIR/system.o" \
    "$OBJ_DIR/tape.o" "$OBJ_DIR/thread.o" "$OBJ_DIR/virtual.o"

echo "Copying to app..."
cp "$OBJ_DIR/libntdll_unix.a" "$APP_LIB"
echo "libntdll_unix.a: $(wc -c < "$APP_LIB" | tr -d ' ') bytes"
echo "Done!"
