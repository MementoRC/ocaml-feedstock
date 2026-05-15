"""W4II fault-offset symbolizer for hi.exe crash analysis.

Usage: python w4ii_symbolize.py [exe_path]
  exe_path defaults to hi.exe in the current directory.
All stages are wrapped in try/except; script never exits nonzero.
"""
import struct
import subprocess
import shutil
import os
import re
import sys


def _tag(msg):
    print("[W4II] " + msg)


def query_wer(exe_name):
    """Query WER Application log for the most recent EventID=1000 mentioning exe_name."""
    fault_offset = None
    exception_code = None
    try:
        result = subprocess.run(
            [
                "wevtutil", "qe", "Application",
                "/q:*[System[(EventID=1000)]]",
                "/c:5", "/rd:true", "/f:text",
            ],
            capture_output=True, text=True, timeout=30,
        )
        output = result.stdout
        exe_base = os.path.basename(exe_name).lower()
        # Split into event blocks (separated by blank lines or "Event[")
        blocks = re.split(r"(?=Event\[)", output)
        target_block = None
        for block in blocks:
            if exe_base in block.lower():
                target_block = block
                break
        if target_block is None:
            _tag("WER: no event block found mentioning " + exe_base)
        else:
            m = re.search(r"Fault offset:\s*(0x[0-9a-fA-F]+)", target_block, re.IGNORECASE)
            if m:
                fault_offset = m.group(1)
                _tag("WER fault offset: " + fault_offset)
            else:
                _tag("WER: Fault offset not found in matching block")
            m2 = re.search(r"Exception code:\s*(\S+)", target_block, re.IGNORECASE)
            if m2:
                exception_code = m2.group(1)
                _tag("WER exception code: " + exception_code)
    except Exception as exc:
        _tag("WER query failed: " + str(exc))
    return fault_offset, exception_code


def read_pe_imagebase(exe_path):
    """Read ImageBase from PE Optional Header (PE32+)."""
    base = 0x140000000
    try:
        with open(exe_path, "rb") as f:
            data = f.read(0x200)
        if len(data) < 0x40:
            _tag("PE: file too small to read e_lfanew")
            return base
        e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
        if e_lfanew + 0x38 > len(data):
            _tag("PE: e_lfanew=" + hex(e_lfanew) + " out of range")
            return base
        sig = data[e_lfanew:e_lfanew + 4]
        if sig != b"PE\x00\x00":
            _tag("PE: bad signature at e_lfanew=" + hex(e_lfanew))
            return base
        # Optional Header starts at e_lfanew + 24; ImageBase at +0x18 (+24) for PE32
        # For PE32+: magic=0x20b, ImageBase at Optional Header +0x18 (8 bytes)
        opt_magic = struct.unpack_from("<H", data, e_lfanew + 24)[0]
        if opt_magic == 0x20B:
            # PE32+: ImageBase at pehdr+24+24 = pehdr+48 = pehdr+0x30
            base = struct.unpack_from("<Q", data, e_lfanew + 0x30)[0]
            _tag("PE: PE32+ ImageBase=" + hex(base))
        elif opt_magic == 0x10B:
            # PE32: ImageBase at pehdr+24+28 = pehdr+52 = pehdr+0x34 (4 bytes)
            base = struct.unpack_from("<I", data, e_lfanew + 0x34)[0]
            _tag("PE: PE32 ImageBase=" + hex(base))
        else:
            _tag("PE: unknown opt magic=" + hex(opt_magic) + "; using default base=" + hex(base))
    except Exception as exc:
        _tag("PE read failed: " + str(exc) + "; using default base=" + hex(base))
    return base


def find_nm():
    """Locate nm: try nm, llvm-nm, x86_64-w64-mingw32-nm."""
    for candidate in ["nm", "llvm-nm", "x86_64-w64-mingw32-nm"]:
        found = shutil.which(candidate)
        if found:
            return found
    return None


def find_objdump(nm_path):
    """Locate objdump; also tries the directory of nm_path for llvm-objdump."""
    for candidate in ["llvm-objdump", "objdump", "x86_64-w64-mingw32-objdump"]:
        found = shutil.which(candidate)
        if found:
            return found
    if nm_path:
        nm_dir = os.path.dirname(os.path.abspath(nm_path))
        for name in ["llvm-objdump", "objdump"]:
            candidate = os.path.join(nm_dir, name)
            if os.path.isfile(candidate):
                return candidate
            candidate_exe = candidate + ".exe"
            if os.path.isfile(candidate_exe):
                return candidate_exe
    return None


def nm_symbolize(nm_exe, exe_path, fault_va):
    """Run nm --numeric-sort on exe_path and find nearest symbol to fault_va."""
    try:
        result = subprocess.run(
            [nm_exe, "--numeric-sort", exe_path],
            capture_output=True, text=True, timeout=60,
        )
        syms = []
        for line in result.stdout.splitlines():
            parts = line.split()
            if len(parts) < 3:
                continue
            sym_type = parts[1]
            if sym_type in ("U", "u"):
                continue
            try:
                addr = int(parts[0], 16)
            except ValueError:
                continue
            name = parts[2]
            syms.append((addr, name))
        if not syms:
            _tag("nm: no defined symbols found")
            return
        # Find insertion index: first sym with addr > fault_va
        idx = len(syms)
        for i in range(len(syms)):
            if syms[i][0] > fault_va:
                idx = i
                break
        # Print 5 neighbors on each side
        lo = max(0, idx - 5)
        hi = min(len(syms), idx + 6)
        _tag("nm: nearest symbols around fault VA=" + hex(fault_va) + ":")
        for addr, name in syms[lo:hi]:
            marker = " <-- fault VA" if addr == fault_va else (
                " <-- nearest below" if addr < fault_va and (idx == 0 or addr == syms[idx - 1][0]) else ""
            )
            _tag("  sym: " + hex(addr) + "  " + name + marker)
        _tag("nm: done")
    except Exception as exc:
        _tag("nm symbolize failed: " + str(exc))


def objdump_disassemble(objdump_exe, exe_path, fault_va):
    """Disassemble +/-0x80 bytes around fault_va."""
    try:
        lo = fault_va - 0x80
        hi = fault_va + 0x80
        result = subprocess.run(
            [
                objdump_exe, "--disassemble",
                "--start-address=" + hex(lo),
                "--stop-address=" + hex(hi),
                exe_path,
            ],
            capture_output=True, text=True, timeout=30,
        )
        lines = result.stdout.splitlines()[:60]
        _tag("objdump disassembly window around fault VA=" + hex(fault_va) + ":")
        for line in lines:
            _tag("  " + line)
        _tag("objdump: done")
    except Exception as exc:
        _tag("objdump disassemble failed: " + str(exc))


def main():
    exe_path = sys.argv[1] if len(sys.argv) > 1 else "hi.exe"
    _tag("=== W4II fault-offset symbolizer ===")
    _tag("target exe: " + exe_path)

    fault_offset_str, _exception_code = query_wer(exe_path)

    fault_va = None
    if fault_offset_str:
        try:
            base = read_pe_imagebase(exe_path) if os.path.isfile(exe_path) else 0x140000000
            offset = int(fault_offset_str, 16)
            fault_va = base + offset
            _tag("fault VA = " + hex(fault_va) + " (base=" + hex(base) + " + offset=" + fault_offset_str + ")")
        except Exception as exc:
            _tag("VA computation failed: " + str(exc))
    else:
        _tag("no fault offset available; skipping VA computation")

    nm_exe = find_nm()
    if nm_exe and fault_va is not None and os.path.isfile(exe_path):
        _tag("using nm: " + nm_exe)
        nm_symbolize(nm_exe, exe_path, fault_va)
    elif nm_exe is None:
        _tag("nm/llvm-nm not found in PATH - skipping symbolization")
    elif not os.path.isfile(exe_path):
        _tag("exe not found at " + exe_path + " - skipping nm")

    objdump_exe = find_objdump(nm_exe)
    if objdump_exe and fault_va is not None and os.path.isfile(exe_path):
        _tag("using objdump: " + objdump_exe)
        objdump_disassemble(objdump_exe, exe_path, fault_va)
    elif objdump_exe is None:
        _tag("llvm-objdump not found in PATH or nm dir - skipping disassembly")
    elif fault_va is None:
        _tag("no fault VA - skipping disassembly")

    _tag("=== W4II symbolizer done ===")


if __name__ == "__main__":
    main()
