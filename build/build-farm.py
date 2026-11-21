#!/usr/bin/env python3
"""Build the aarch64-windows Wine DLL farm.

usage: build-farm.py <wine-build-dir> <dest-dir> [--strip <strip-tool>] [--jobs N] [--extra <exe/dll>...]

Reads build/farm-modules.txt, maps each name to its Wine module target
(dlls/<dir>/aarch64-windows/<module> or programs/...), builds it in the
configured Wine tree, then adds every module the built images (and any
--extra images, e.g. claude.exe) import until the set is closed. Imports Wine
does not provide (api-ms-* sets resolve through apisetschema; third-party
DLLs ship next to their programs) are ignored. Outputs are stripped
(--strip-debug, like Madeira) into dest-dir.
"""
import os, re, shutil, struct, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WINE = ROOT / 'wine'


def pe_imports(path):
    """Names of imported and delay-imported DLLs of a PE file (lower case)."""
    data = Path(path).read_bytes()
    if data[:2] != b'MZ':
        return set()
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        return set()
    nsect = struct.unpack_from('<H', data, pe + 6)[0]
    optsz = struct.unpack_from('<H', data, pe + 20)[0]
    opt = pe + 24
    magic = struct.unpack_from('<H', data, opt)[0]
    dd = opt + (112 if magic == 0x20b else 96)
    sects = []
    for i in range(nsect):
        s = opt + optsz + 40 * i
        vsize, va, rsize, rptr = struct.unpack_from('<IIII', data, s + 8)
        sects.append((va, max(vsize, rsize), rptr))

    def off(rva):
        for va, size, ptr in sects:
            if va <= rva < va + size:
                return rva - va + ptr
        return None

    def cstr(rva):
        o = off(rva)
        if o is None:
            return None
        e = data.index(b'\0', o)
        return data[o:e].decode('ascii', 'replace').lower()

    names = set()
    imp_rva = struct.unpack_from('<I', data, dd + 8)[0]
    if imp_rva and off(imp_rva) is not None:
        o = off(imp_rva)
        while True:
            name_rva = struct.unpack_from('<I', data, o + 12)[0]
            if not name_rva:
                break
            n = cstr(name_rva)
            if n:
                names.add(n)
            o += 20
    dly_rva = struct.unpack_from('<I', data, dd + 13 * 8)[0]
    if dly_rva and off(dly_rva) is not None:
        o = off(dly_rva)
        while True:
            attrs, name_rva = struct.unpack_from('<II', data, o)
            if not name_rva:
                break
            n = cstr(name_rva)
            if n:
                names.add(n)
            o += 32
    return names


def wine_modules():
    """module file name (lower) -> (category, directory, module file name)"""
    mods = {}
    for cat in ('dlls', 'programs'):
        for mk in (WINE / cat).glob('*/Makefile.in'):
            m = re.search(r'^MODULE\s*=\s*(\S+)', mk.read_text(errors='replace'), re.M)
            if m:
                mods[m[1].lower()] = (cat, mk.parent.name, m[1])
    return mods


def resolve(name, mods):
    n = name.lower()
    for cand in (n, n + '.dll', n + '.exe', n + '.com', n + '.sys', n + '.drv'):
        if cand in mods:
            return cand
    return None


def main():
    args = sys.argv[1:]
    build, dest = Path(args[0]).resolve(), Path(args[1]).resolve()
    strip = None
    jobs = os.cpu_count() or 4
    extra = []
    i = 2
    while i < len(args):
        if args[i] == '--strip':
            strip = args[i + 1]; i += 2
        elif args[i] == '--jobs':
            jobs = int(args[i + 1]); i += 2
        elif args[i] == '--extra':
            i += 1
            while i < len(args) and not args[i].startswith('--'):
                extra.append(args[i]); i += 1
        else:
            sys.exit(f'unknown argument {args[i]}')

    mods = wine_modules()
    wanted = []
    for line in (ROOT / 'build/farm-modules.txt').read_text().splitlines():
        line = line.split('#', 1)[0]
        for name in line.split():
            r = resolve(name, mods)
            if not r:
                sys.exit(f'farm-modules.txt: no Wine module named {name}')
            wanted.append(r)

    # Modules this tree does not build for aarch64 (on an x86_64 host, Wine's
    # helper programs such as conhost are host-arch only). On the arm64 macOS
    # build host only 16-bit modules are disabled.
    disabled = set()
    mk = (build / 'Makefile').read_text(errors='replace')
    m = re.search(r'^aarch64_DISABLED_SUBDIRS\s*=(.*)$', mk, re.M)
    if m:
        disabled = {d.split('/')[-1] for d in m[1].split()}
    skipped = [x for x in wanted if mods[x][1] in disabled]
    if skipped:
        print('WARNING: disabled in this tree, skipped:', ' '.join(skipped), flush=True)
        if os.environ.get('FARM_STRICT') == '1':
            sys.exit('FARM_STRICT: required modules are disabled')
    wanted = [x for x in wanted if mods[x][1] not in disabled]

    def target(m):
        cat, d, f = mods[m]
        return f'{cat}/{d}/aarch64-windows/{f}'

    done = set()
    pending = list(dict.fromkeys(wanted))
    ext_imports = set()
    for e in extra:
        ext_imports |= pe_imports(e)
    for n in sorted(ext_imports):
        r = resolve(n, mods)
        if r and r not in pending and mods[r][1] not in disabled:
            pending.append(r)
    rounds = 0
    while pending:
        rounds += 1
        if rounds > 20:
            sys.exit('import closure did not converge')
        batch = [m for m in pending if m not in done]
        pending = []
        print(f'round {rounds}: building {len(batch)} modules', flush=True)
        subprocess.run(['make', '-C', str(build), f'-j{jobs}', *[target(m) for m in batch]], check=True)
        done |= set(batch)
        for m in batch:
            for imp in pe_imports(build / target(m)):
                r = resolve(imp, mods)
                if r and r not in done and r not in pending and mods[r][1] not in disabled:
                    pending.append(r)

    dest.mkdir(parents=True, exist_ok=True)
    for m in sorted(done):
        src = build / target(m)
        out = dest / mods[m][2]
        shutil.copyfile(src, out)
        if strip:
            subprocess.run([strip, '--strip-debug', str(out)], check=True)
    print(f'farm: {len(done)} modules in {dest}')
    (dest / '.farm-manifest').write_text('\n'.join(sorted(mods[m][2] for m in done)) + '\n')


if __name__ == '__main__':
    main()
