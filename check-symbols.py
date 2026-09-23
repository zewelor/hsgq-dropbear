#!/usr/bin/env python3
"""
Automated Symbol Gate for HSGQ RTL8672 (Lexra LX4180).
Audits dynamic symbol dependencies of compiled binaries against
the native shared libraries supplied from the target firmware.

Strict Verification Principles:
1. Transitive DT_NEEDED Closure: Compares undefined symbols ONLY against
   the transitive closure of libraries explicitly declared in DT_NEEDED,
   NOT against the entire /lib directory.
2. Symbol Binding:
   - GLOBAL UND: MUST be resolved by the runtime closure.
   - WEAK UND (e.g. _Jv_RegisterClasses, __register_frame_info): Allowed
     to remain unresolved per standard ELF dynamic linking semantics.
3. Explicit syscall() Verification: Confirms that syscall() is required
   and exported by libc.so.0 in the closure.
"""

import sys
import os
import glob
import struct
import subprocess

def require_target_elf(data, filepath):
    """Reject inputs the ELF32 big-endian MIPS parser cannot inspect."""
    if (len(data) < 52 or data[:6] != b"\x7fELF\x01\x02"
            or struct.unpack(">H", data[18:20])[0] != 8):
        raise ValueError(f"Not an ELF32 big-endian MIPS file: {filepath}")

def parse_elf_dt_needed(filepath):
    """Extract DT_NEEDED library names directly from PT_DYNAMIC segment."""
    with open(filepath, "rb") as f:
        data = f.read()
    require_target_elf(data, filepath)

    e_phoff, = struct.unpack(">I", data[28:32])
    e_phentsize, e_phnum = struct.unpack(">HH", data[42:46])
    dyn_offset, dyn_size = None, None
    for i in range(e_phnum):
        ph = data[e_phoff + i * e_phentsize : e_phoff + (i + 1) * e_phentsize]
        p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags = struct.unpack(">IIIIIII", ph[:28])
        if p_type == 2:  # PT_DYNAMIC
            dyn_offset, dyn_size = p_offset, p_filesz
            break

    if not dyn_offset:
        return []

    strtab_vaddr = None
    needed_offsets = []
    for pos in range(dyn_offset, dyn_offset + dyn_size, 8):
        d_tag, d_val = struct.unpack(">iI", data[pos:pos+8])
        if d_tag == 0:
            break
        elif d_tag == 1:  # DT_NEEDED
            needed_offsets.append(d_val)
        elif d_tag == 5:  # DT_STRTAB
            strtab_vaddr = d_val

    if not strtab_vaddr:
        return []

    def vaddr_to_offset(vaddr):
        for i in range(e_phnum):
            ph = data[e_phoff + i * e_phentsize : e_phoff + (i + 1) * e_phentsize]
            p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags = struct.unpack(">IIIIIII", ph[:28])
            if p_type == 1 and p_vaddr <= vaddr < p_vaddr + p_memsz:
                return p_offset + (vaddr - p_vaddr)
        return None

    strtab_off = vaddr_to_offset(strtab_vaddr)
    if not strtab_off:
        return []

    needed_libs = []
    for off in needed_offsets:
        end = data.find(b"\x00", strtab_off + off)
        lib_name = data[strtab_off + off:end].decode("ascii", "replace")
        if lib_name:
            needed_libs.append(lib_name)
    return needed_libs

def parse_elf_exported_symbols(filepath):
    """Extract exported (defined dynamic) symbols from an ELF shared library via PT_DYNAMIC."""
    with open(filepath, "rb") as f:
        data = f.read()
    require_target_elf(data, filepath)

    e_phoff, = struct.unpack(">I", data[28:32])
    e_phentsize, e_phnum = struct.unpack(">HH", data[42:46])
    dyn_offset, dyn_size = None, None
    for i in range(e_phnum):
        ph = data[e_phoff + i * e_phentsize : e_phoff + (i + 1) * e_phentsize]
        p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags = struct.unpack(">IIIIIII", ph[:28])
        if p_type == 2:  # PT_DYNAMIC
            dyn_offset, dyn_size = p_offset, p_filesz
            break

    if not dyn_offset:
        return set()

    strtab_vaddr, symtab_vaddr, hash_vaddr = None, None, None
    for pos in range(dyn_offset, dyn_offset + dyn_size, 8):
        d_tag, d_val = struct.unpack(">iI", data[pos:pos+8])
        if d_tag == 0:
            break
        elif d_tag == 4:
            hash_vaddr = d_val
        elif d_tag == 5:
            strtab_vaddr = d_val
        elif d_tag == 6:
            symtab_vaddr = d_val

    if not (strtab_vaddr and symtab_vaddr and hash_vaddr):
        return set()

    def vaddr_to_offset(vaddr):
        if vaddr is None:
            return None
        for i in range(e_phnum):
            ph = data[e_phoff + i * e_phentsize : e_phoff + (i + 1) * e_phentsize]
            p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags = struct.unpack(">IIIIIII", ph[:28])
            if p_type == 1 and p_vaddr <= vaddr < p_vaddr + p_memsz:
                return p_offset + (vaddr - p_vaddr)
        return None

    strtab_off = vaddr_to_offset(strtab_vaddr)
    symtab_off = vaddr_to_offset(symtab_vaddr)
    hash_off = vaddr_to_offset(hash_vaddr)
    if not (strtab_off and symtab_off and hash_off):
        return set()

    nbucket, nchain = struct.unpack(">II", data[hash_off:hash_off+8])
    syms = set()
    for i in range(nchain):
        pos = symtab_off + i * 16
        st_name, st_value, st_size, st_info, st_other, st_shndx = struct.unpack(">IIIBBH", data[pos:pos+16])
        name_end = data.find(b"\x00", strtab_off + st_name)
        sym_name = data[strtab_off + st_name:name_end].decode("ascii", "replace")
        binding = st_info >> 4
        visibility = st_other & 0x03
        if (sym_name and st_shndx != 0 and
                binding in (1, 2) and visibility in (0, 3)):
            syms.add(sym_name)
    return syms

def get_binary_symbols(bin_path):
    """
    Extract undefined dynamic symbols from a compiled binary using readelf.
    Separates GLOBAL UND (mandatory for runtime) from WEAK UND (optional).
    """
    cmd = ["readelf", "-Ws", bin_path]
    res = subprocess.run(cmd, capture_output=True, text=True, check=True)
    global_und = set()
    weak_und = set()
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 8 and parts[6] == "UND":
            bind = parts[4]
            name = parts[7].split("@")[0]
            if not name or name == "__gnu_local_gp":
                continue
            if bind == "GLOBAL":
                global_und.add(name)
            elif bind == "WEAK":
                weak_und.add(name)
    return global_und, weak_und

def compute_transitive_closure(bin_path, fw_dir):
    """
    Compute transitive closure of DT_NEEDED dependencies starting from a binary.
    Returns:
      closure_files: set of absolute canonical file paths of resolved libraries
      closure_sonames: set of sonames / filenames encountered
      unresolved_needed: list of DT_NEEDED sonames that could not be located in fw_dir
    """
    direct_needed = parse_elf_dt_needed(bin_path)
    queue = list(direct_needed)
    visited_sonames = set(queue)
    closure_files = set()
    closure_sonames = set()
    unresolved_needed = []

    while queue:
        soname = queue.pop(0)
        closure_sonames.add(soname)
        candidate = os.path.join(fw_dir, soname)
        if not os.path.exists(candidate):
            unresolved_needed.append(soname)
            continue
        real_path = os.path.realpath(candidate)
        closure_files.add(real_path)
        closure_sonames.add(os.path.basename(real_path))

        deps = parse_elf_dt_needed(real_path)
        for dep in deps:
            if dep not in visited_sonames:
                visited_sonames.add(dep)
                queue.append(dep)

    return direct_needed, closure_files, closure_sonames, unresolved_needed

def main():
    fw_dir = sys.argv[1] if len(sys.argv) > 1 else "firmware-libs"
    out_dir = sys.argv[2] if len(sys.argv) > 2 else "out"

    print("=" * 80)
    print(" AUTOMATED SYMBOL GATE: TRANSITIVE DT_NEEDED CLOSURE AUDIT")
    print("=" * 80)
    print(f" Target firmware library source: '{fw_dir}'")
    print(f" Binaries output directory:      '{out_dir}'")
    print("=" * 80)

    binaries = ["dropbear", "dropbearkey", "dropbear-inetd"]
    missing_by_binary = {}
    total_missing = set()
    fatal_errors = []

    for b in binaries:
        bpath = os.path.join(out_dir, b)
        if not os.path.isfile(bpath):
            fatal_errors.append(f"Expected binary is missing: {bpath}")
            continue

        print(f"\n[*] Auditing binary: {b}")

        # 1. Compute transitive DT_NEEDED closure
        direct_needed, closure_files, closure_sonames, unresolved_needed = compute_transitive_closure(bpath, fw_dir)
        print(f"    - Direct DT_NEEDED:          {direct_needed}")
        print(f"    - Transitive Closure files:  {sorted([os.path.basename(f) for f in closure_files])}")

        if unresolved_needed:
            err = f"Binary '{b}' has unresolvable DT_NEEDED library: {unresolved_needed}"
            print(f"    [FAIL] {err}")
            fatal_errors.append(err)

        # 2. Collect exported symbols ONLY from libraries in the transitive closure
        closure_exports = set()
        lib_exports_breakdown = {}
        for lib_file in sorted(closure_files):
            lib_name = os.path.basename(lib_file)
            exports = parse_elf_exported_symbols(lib_file)
            lib_exports_breakdown[lib_name] = exports
            closure_exports.update(exports)

        print(f"    - Closure exported symbols:  {len(closure_exports)} defined symbols across closure")

        # 3. Extract undefined symbols from the binary
        global_und, weak_und = get_binary_symbols(bpath)
        print(f"    - Required GLOBAL UND:       {len(global_und)} symbols")
        print(f"    - Ignored WEAK UND:          {len(weak_und)} symbols {sorted(weak_und)}")

        # 4. Specific verification for syscall() in Dropbear binaries
        if "dropbear" in b:
            if "syscall" not in global_und:
                err = f"Binary '{b}' does not reference syscall() in GLOBAL UND"
                print(f"    [WARN] {err}")
            else:
                libc_has_sc = any("syscall" in exp for name, exp in lib_exports_breakdown.items() if "libc" in name)
                if libc_has_sc:
                    print(f"    [PASS] syscall() verified in DT_NEEDED closure (exported by target libc.so.0)")
                else:
                    err = f"Binary '{b}' requires syscall() but target libc in closure does not export it!"
                    print(f"    [FAIL] {err}")
                    fatal_errors.append(err)

        # 5. Check missing symbols (GLOBAL UND not in closure_exports)
        missing = sorted(global_und - closure_exports)
        missing_by_binary[b] = missing
        total_missing.update(missing)

        if missing:
            print(f"    [FAIL] {len(missing)} missing GLOBAL symbols: {missing}")
        else:
            print(f"    [PASS] 100% of GLOBAL UND symbols resolved by transitive DT_NEEDED closure.")

    # 6. Write missing-runtime-symbols.txt
    missing_file = os.path.join(out_dir, "missing-runtime-symbols.txt")
    with open(missing_file, "w") as f:
        for sym in sorted(total_missing):
            f.write(f"{sym}\n")

    print("\n" + "=" * 80)
    print(f" AUDIT SUMMARY:")
    print(f" Missing runtime symbols recorded in '{missing_file}': {len(total_missing)}")

    if fatal_errors or total_missing:
        print("\n [FATAL] Symbol Gate FAILED:")
        for err in fatal_errors:
            print(f"   - {err}")
        for sym in sorted(total_missing):
            print(f"   - Missing symbol: {sym}")
        print("=" * 80)
        sys.exit(1)
    else:
        print("\n [SUCCESS] Symbol Gate PASSED: missing-runtime-symbols.txt is EMPTY (0 missing).")
        print(" Every binary's GLOBAL UND symbols are 100% satisfied by its transitive DT_NEEDED closure.")
        print("=" * 80)
        sys.exit(0)

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, struct.error, subprocess.CalledProcessError) as exc:
        print(f"[FATAL] Symbol Gate cannot inspect input: {exc}", file=sys.stderr)
        sys.exit(1)
