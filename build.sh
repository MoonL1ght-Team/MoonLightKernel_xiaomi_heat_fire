#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEVICE="${DEVICE:-fire}"
PREBUILT=0
CLEAN=0

usage() {
	printf 'Usage: %s [fire|heat] [--prebuilt] [clean]\n' "$0" >&2
}

while (($#)); do
	case "$1" in
		fire|heat)
			DEVICE="$1"
			;;
		--prebuilt)
			PREBUILT=1
			;;
		clean)
			CLEAN=1
			;;
		*)
			usage
			exit 2
			;;
	esac
	shift
done

if ((CLEAN)); then
	rm -rf "${OUT_DIR:-$ROOT_DIR/out/$DEVICE}" "${DIST_DIR:-$ROOT_DIR/dist}"
	exit 0
fi

DEFCONFIG="${DEFCONFIG:-${DEVICE}_defconfig}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/$DEVICE}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
PREBUILT_KERNEL_OUT="${PREBUILT_KERNEL_OUT:-$DIST_DIR/kernel}"
PREBUILT_DTBO_OUT="${PREBUILT_DTBO_OUT:-$DIST_DIR/dtbo.img}"
JOBS="${JOBS:-$(nproc --all)}"

CLANG_REVISION="${CLANG_REVISION:-clang-r383902b}"
CLANG_URL="${CLANG_URL:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android11-release/${CLANG_REVISION}.tar.gz}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/android-kernel-toolchains/$CLANG_REVISION}"

ANYKERNEL_REPO="${ANYKERNEL_REPO:-https://github.com/osm0sis/AnyKernel3.git}"
ANYKERNEL_COMMIT="${ANYKERNEL_COMMIT:-dca9dc370838d919d56c1f59ec78b27a14a72c68}"
ANYKERNEL_CACHE="${ANYKERNEL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/AnyKernel3}"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

fetch_clang() {
	local archive tmp_dir

	[[ -x "$TOOLCHAIN_DIR/bin/clang" ]] && return
	require_command curl
	require_command tar
	printf 'Downloading Android Clang %s...\n' "$CLANG_REVISION"
	archive="$(mktemp)"
	tmp_dir="$(mktemp -d)"
	trap 'rm -f "$archive"; rm -rf "$tmp_dir"' RETURN
	curl -fL --retry 2 "$CLANG_URL" -o "$archive"
	tar -xzf "$archive" -C "$tmp_dir"
	mkdir -p "$(dirname "$TOOLCHAIN_DIR")"
	rm -rf "$TOOLCHAIN_DIR"
	mv "$tmp_dir" "$TOOLCHAIN_DIR"
	rm -f "$archive"
	trap - RETURN
}

build_dtbo_image() {
	local boot_dir dtbo_image
	local -a overlays

	boot_dir="$OUT_DIR/arch/arm64/boot"
	dtbo_image="$boot_dir/dtbo.img"
	rm -f "$dtbo_image"
	mapfile -t overlays < <(find "$boot_dir/dts" -type f -name '*.dtbo' -print 2>/dev/null | sort)
	((${#overlays[@]})) || return

	require_command mkdtboimg
	mkdtboimg create "$dtbo_image" --page_size=2048 "${overlays[@]}"
	printf 'DTBO image: %s\n' "$dtbo_image"
}

prepare_prebuilt() {
	local dtbo_image image

	image="$OUT_DIR/arch/arm64/boot/Image.gz"
	[[ -f "$image" ]] || die "kernel image was not produced"
	dtbo_image="$OUT_DIR/arch/arm64/boot/dtbo.img"

	mkdir -p "$(dirname "$PREBUILT_KERNEL_OUT")"
	cp "$image" "$PREBUILT_KERNEL_OUT"
	printf 'Prebuilt kernel: %s\n' "$PREBUILT_KERNEL_OUT"

	rm -f "$PREBUILT_DTBO_OUT"
	if [[ -f "$dtbo_image" ]]; then
		mkdir -p "$(dirname "$PREBUILT_DTBO_OUT")"
		cp "$dtbo_image" "$PREBUILT_DTBO_OUT"
		printf 'Prebuilt DTBO image: %s\n' "$PREBUILT_DTBO_OUT"
	fi
}

prepare_anykernel() {
	local package_dir image zip_name version

	image="$OUT_DIR/arch/arm64/boot/Image.gz-dtb"
	[[ -f "$image" ]] || image="$OUT_DIR/arch/arm64/boot/Image.gz"
	[[ -f "$image" ]] || die "kernel image was not produced"

	if [[ ! -d "$ANYKERNEL_CACHE/.git" ]]; then
		mkdir -p "$(dirname "$ANYKERNEL_CACHE")"
		git clone --no-checkout "$ANYKERNEL_REPO" "$ANYKERNEL_CACHE"
	fi
	git -C "$ANYKERNEL_CACHE" fetch --depth=1 origin "$ANYKERNEL_COMMIT"

	package_dir="$OUT_DIR/AnyKernel3"
	rm -rf "$package_dir"
	mkdir -p "$package_dir"
	git -C "$ANYKERNEL_CACHE" archive "$ANYKERNEL_COMMIT" | tar -x -C "$package_dir"
	rm -rf "$package_dir/.github" "$package_dir/README.md"
	cp "$image" "$package_dir/$(basename "$image")"
	cp "$ROOT_DIR/AUTHORS" "$package_dir/AUTHORS"
	[[ -f "$OUT_DIR/arch/arm64/boot/dtbo.img" ]] &&
		cp "$OUT_DIR/arch/arm64/boot/dtbo.img" "$package_dir/dtbo.img"

	cat > "$package_dir/anykernel.sh" <<EOF
### AnyKernel3 Ramdisk Mod Script
## MoonLightKernel for Xiaomi Redmi 12 (fire/heat)
## Authors: 1VicTim1 and Flasix67

properties() { '
kernel.string=MoonLightKernel ${DEVICE} by 1VicTim1 and Flasix67
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=fire
device.name2=heat
supported.versions=
supported.patchlevels=
'; }

boot_attributes() {
set_perm_recursive 0 0 755 644 \$RAMDISK/*;
set_perm_recursive 0 0 750 750 \$RAMDISK/init* \$RAMDISK/sbin;
}

BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;
dump_boot;
write_boot;
EOF

	version="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf local)"
	mkdir -p "$DIST_DIR"
	zip_name="$DIST_DIR/MoonLightKernel-${DEVICE}-${version}-AnyKernel3.zip"
	rm -f "$zip_name"
	(cd "$package_dir" && zip -qr9 "$zip_name" . -x '.git*')
	printf 'AnyKernel3 package: %s\n' "$zip_name"
}

require_command make
require_command ccache
if ((!PREBUILT)); then
	require_command git
	require_command zip
fi
fetch_clang

export PATH="$TOOLCHAIN_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$TOOLCHAIN_DIR/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CCACHE_DIR="${CCACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ccache/inferno-kernel}"
export CCACHE_CPP2=yes
mkdir -p "$CCACHE_DIR" "$OUT_DIR"
ccache --max-size="${CCACHE_MAXSIZE:-10G}" >/dev/null

MAKE_ARGS=(
	O="$OUT_DIR"
	ARCH=arm64
	LLVM=1
	LLVM_IAS=1
	CC="ccache clang"
	HOSTCC="ccache clang"
	LD=ld.lld
	AS=llvm-as
	AR=llvm-ar
	NM=llvm-nm
	OBJCOPY=llvm-objcopy
	OBJDUMP=llvm-objdump
	READELF=llvm-readelf
	STRIP=llvm-strip
	CROSS_COMPILE=aarch64-linux-gnu-
)

printf 'Building %s with %s (%s jobs, ccache enabled)...\n' \
	"$DEFCONFIG" "$("$TOOLCHAIN_DIR/bin/clang" --version | head -1)" "$JOBS"
make "${MAKE_ARGS[@]}" "$DEFCONFIG"
make "${MAKE_ARGS[@]}" olddefconfig
make -j"$JOBS" "${MAKE_ARGS[@]}"
build_dtbo_image
if ((PREBUILT)); then
	prepare_prebuilt
else
	prepare_anykernel
fi
ccache --show-stats
