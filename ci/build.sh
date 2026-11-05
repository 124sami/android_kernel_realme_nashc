#!/usr/bin/env bash
# Build the nashc kernel with module loading + APatch support fixed.
# Runs on a Linux x86_64 machine / GitHub Actions runner (see .github/workflows/build-kernel.yml).
#
# Environment knobs:
#   LTO=1|0              keep CONFIG_LTO_CLANG (default 1; needs ~8GB+ RAM)
#   FORCE_LOAD=0|1       enable CONFIG_MODULE_FORCE_LOAD
#   NO_MODVERSIONS=0|1   try to disable CONFIG_MODVERSIONS (MediaTek Kconfig selects it, so it may stay on)
#   CLANG_BIN=/path/bin  directory with clang, ld.lld, llvm-* (prepended to PATH)
#   STAGE=all|config     "config" stops after generating and checking .config
#   OUT=out  JOBS=N  DIST=dist
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="${OUT:-out}"
DIST="${DIST:-dist}"
JOBS="${JOBS:-$(nproc)}"
LTO="${LTO:-1}"
FORCE_LOAD="${FORCE_LOAD:-0}"
NO_MODVERSIONS="${NO_MODVERSIONS:-0}"
STAGE="${STAGE:-all}"
[ -n "${CLANG_BIN:-}" ] && export PATH="$CLANG_BIN:$PATH"

die() { echo "::error::$*" >&2; exit 1; }
warn() { echo "::warning::$*" >&2; }

MK=(make O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1
    CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu-)

echo "== toolchain"
clang --version | head -1
ld.lld --version | head -1

echo "== generate config from nashc_defconfig"
"${MK[@]}" nashc_defconfig

CFG="$OUT/.config"
C=(scripts/config --file "$CFG")
# 1. keep every exported symbol available to modules
"${C[@]}" -d TRIM_UNUSED_KSYMS --set-str UNUSED_KSYMS_WHITELIST ""
# 2. APatch / KernelPatch needs the full symbol table (KALLSYMS_ALL depends on DEBUG_KERNEL)
"${C[@]}" -e DEBUG_KERNEL -e KALLSYMS -e KALLSYMS_ALL
"${C[@]}" -e MODULES -e MODULE_UNLOAD
[ "$LTO" = 0 ] && "${C[@]}" -d LTO_CLANG
[ "$FORCE_LOAD" = 1 ] && "${C[@]}" -e MODULE_FORCE_LOAD
[ "$NO_MODVERSIONS" = 1 ] && "${C[@]}" -d MODVERSIONS
"${MK[@]}" olddefconfig

echo "== verify the config really took (Kconfig silently drops options whose dependencies are unmet)"
need() { grep -q "^CONFIG_$1=y" "$CFG" || die "CONFIG_$1 is not =y in the final config"; }
need MODULES; need MODULE_UNLOAD; need KALLSYMS; need KALLSYMS_ALL
grep -q "^CONFIG_TRIM_UNUSED_KSYMS=y" "$CFG" && die "CONFIG_TRIM_UNUSED_KSYMS is still on"
if [ "$LTO" = 0 ]; then grep -q "^CONFIG_LTO_CLANG=y" "$CFG" && warn "LTO requested off but LTO_CLANG is still on"; fi
[ "$FORCE_LOAD" = 1 ] && { need MODULE_FORCE_LOAD; }
if [ "$NO_MODVERSIONS" = 1 ] && grep -q "^CONFIG_MODVERSIONS=y" "$CFG"; then
  warn "CONFIG_MODVERSIONS stayed on (selected by a MediaTek Kconfig option); only a source change can remove it"
fi
grep -E "^(# )?CONFIG_(TRIM_UNUSED_KSYMS|UNUSED_KSYMS_WHITELIST|KALLSYMS|KALLSYMS_ALL|MODULES|MODULE_SIG|MODULE_FORCE_LOAD|MODVERSIONS|LTO_CLANG)[ =]" "$CFG"

[ "$STAGE" = config ] && { echo "config stage only: done"; exit 0; }

echo "== build (jobs=$JOBS)"
"${MK[@]}" -j"$JOBS" Image.gz dtbs modules

echo "== verify exports that were trimmed out of the stock kernel are back"
SV="$OUT/Module.symvers"
[ -s "$SV" ] || die "$SV missing"
missing=0
for s in memset strcmp strrchr get_random_u32 proc_create remove_proc_entry find_vpid \
         pid_task get_task_mm mmput d_path kobject_del si_meminfo ioremap_cache \
         __list_del_entry_valid printk __arch_copy_from_user __arch_copy_to_user; do
  if grep -qP "^0x[0-9a-f]+\t${s}\t" "$SV"; then :; else echo "NOT EXPORTED: $s"; missing=1; fi
done
exports=$(wc -l < "$SV"); echo "exported symbols in Module.symvers: $exports"
[ "$missing" = 0 ] || die "some expected symbols are not exported"

echo "== build module smoke test"
"${MK[@]}" M="$ROOT/ci/hello" modules

echo "== collect"
rm -rf "$DIST"; mkdir -p "$DIST"
cp "$OUT/arch/arm64/boot/Image.gz" "$DIST/"
[ -f "$OUT/arch/arm64/boot/Image" ] && cp "$OUT/arch/arm64/boot/Image" "$DIST/"
find "$OUT/arch/arm64/boot/dts" -name 'mt6785.dtb' -exec cp {} "$DIST/" \; || true
find "$OUT/arch/arm64/boot/dts" -name '*.dtbo' -exec cp {} "$DIST/" \; || true
cp "$CFG" "$DIST/nashc.config"
cp "$SV" "$DIST/Module.symvers"
cp ci/hello/hello_test.ko "$DIST/"
{
  echo "commit : $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "release: $(cat "$OUT/include/config/kernel.release" 2>/dev/null)"
  echo "clang  : $(clang --version | head -1)"
  echo "LTO=$LTO FORCE_LOAD=$FORCE_LOAD NO_MODVERSIONS=$NO_MODVERSIONS"
  echo "Image.gz: $(stat -c %s "$DIST/Image.gz") bytes   (boot partition is 33554432 bytes)"
} | tee "$DIST/build-info.txt"

echo "== check prebuilt modules in ci/check/ against this kernel"
shopt -s nullglob
for ko in ci/check/*.ko; do
  python3 ci/check_module.py "$ko" "$SV" | tee -a "$DIST/module-check.txt" || true
  echo >> "$DIST/module-check.txt"
done
echo "done"
