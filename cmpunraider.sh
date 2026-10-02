#!/bin/bash
# cmpunraider.sh - build and install a CMP 170HX unlocked Nvidia driver package for Unraid
#
# Run on the Unraid host (terminal or SSH):
#   bash cmpunraider.sh build     # builds ./out/nvidia-<drv>-<kernel>-1.txz via docker
#   bash cmpunraider.sh install   # drops it into the Nvidia-Driver plugin's package dir
#   (power off fully, boot, verify with nvidia-smi)
#   bash cmpunraider.sh uninstall # restores stock package + removes modprobe option, then reboot
#
# Env overrides: DRV=615.71.09  PROFILE=8gb|10gb|mixed (auto from lspci, 8gb if no card)
#                CMPUNLOCKER_REF=v0.4|master|<tag>  (cmpunlocker version to build, default v0.4)
#                IMAGE=ghcr.io/ich777/unraid_kernel:gcc_14.2.0  FORCE=1 (install without card present)
#
# How it works: the plugin re-installs whatever .txz sits in
# /boot/config/plugins/nvidia-driver/packages/<kernel>/ on every boot without contacting
# GitHub or checking md5. We take the stock proprietary package for the same driver version
# (identical userspace libs + GSP firmware), swap its kernel modules for cmpunlocker-patched
# open-gpu-kernel-modules built against the exact Unraid kernel, and repack it.
set -euo pipefail
trap 'echo "ERROR line $LINENO: $BASH_COMMAND" >&2' ERR

DRV="${DRV:-615.71.09}"
IMAGE="${IMAGE:-ghcr.io/ich777/unraid_kernel:gcc_14.2.0}"
CMPUNLOCKER_REF="${CMPUNLOCKER_REF:-v0.4}"   # cmpunlocker git tag or branch (e.g. master)
KVER="$(uname -r)"          # e.g. 6.18.38-Unraid
KSHORT="${KVER%%-*}"        # e.g. 6.18.38
PKG="nvidia-${DRV}-${KVER}-1.txz"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="${1:-build}"

die() { echo "ERROR: $*" >&2; exit 1; }

detect_profile() {
  [ -n "${PROFILE:-}" ] && return
  local ids
  ids="$(lspci -nn | grep -oiE '10de:(20c2|2082)' | tr 'A-Z' 'a-z' | sort -u || true)"
  case "$(echo "$ids" | tr '\n' ' ')" in
    "10de:20c2 ") PROFILE=8gb ;;
    "10de:2082 ") PROFILE=10gb ;;
    *20c2*2082*|*2082*20c2*) PROFILE=mixed ;;
    *) PROFILE=8gb; CARD_FOUND=0; echo "no CMP 170HX found, defaulting to 8gb (10de:20c2) profile" ;;
  esac
  echo "GPU profile: ${PROFILE}"
}
CARD_FOUND=1

# ---------------------------------------------------------------- inside container
build_inside() {
  local WORK=/work CACHE=/work/cache OUT=/work/out
  mkdir -p "$CACHE" "$OUT"

  echo "==> kernel ${KVER}, driver ${DRV}, profile ${PROFILE}"

  # 0. the image's curl/git are broken (libnghttp3 drift). Shim curl with python; build.sh uses
  #    "curl -L --fail -o FILE URL", same as we do.
  mkdir -p /usr/local/bin
  cat > /usr/local/bin/curl <<'PY'
#!/usr/bin/python3
import sys, shutil, urllib.request
out = url = None; a = sys.argv[1:]; i = 0
while i < len(a):
    if a[i] == '-o': out = a[i+1]; i += 2; continue
    if not a[i].startswith('-'): url = a[i]
    i += 1
try:
    with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'curl'})) as r:
        if out:
            with open(out, 'wb') as f: shutil.copyfileobj(r, f)
        else:
            shutil.copyfileobj(r, sys.stdout.buffer)
except Exception as e:
    print(f"curl-shim: {url}: {e}", file=sys.stderr); sys.exit(22)
PY
  chmod +x /usr/local/bin/curl
  export PATH=/usr/local/bin:$PATH

  # 1. pre-compiled Unraid kernel tree (ich777) -> /lib/modules/$KVER/build
  local KTAR="$CACHE/linux-${KVER}.tar.xz"
  [ -s "$KTAR" ] || curl -L --fail -o "$KTAR" \
    "https://github.com/ich777/unraid_kernel/releases/download/${KVER}/linux-${KVER}.tar.xz" \
    || die "no pre-compiled kernel tree for ${KVER} at github.com/ich777/unraid_kernel/releases yet." \
           " Wait for a matching release, or stay on your current Unraid kernel until one appears."
  rm -rf /kbuild && mkdir /kbuild
  tar -xJf "$KTAR" -C /kbuild
  local KSRC
  KSRC="$(dirname "$(find /kbuild -maxdepth 4 -name Module.symvers -print -quit)")"
  [ -f "$KSRC/Makefile" ] || die "kernel tree not found in tarball"
  mkdir -p "/lib/modules/${KVER}"
  ln -sfn "$KSRC" "/lib/modules/${KVER}/build"

  # 2. cmpunlocker sources + PyYAML (build.sh needs it)
  curl -L --fail -o "$CACHE/cmpunlocker.tar.gz" \
    "https://github.com/amoghmunikote/cmpunlocker/archive/${CMPUNLOCKER_REF}.tar.gz"
  rm -rf "$CACHE/cmpunlocker" && mkdir -p "$CACHE/cmpunlocker"
  tar -xzf "$CACHE/cmpunlocker.tar.gz" --strip-components=1 -C "$CACHE/cmpunlocker"
  if ! python3 -c 'import yaml' 2>/dev/null; then      # no pip in image: pure-python PyYAML via PYTHONPATH
    [ -f "$CACHE/pyyaml/lib/yaml/__init__.py" ] || {
      curl -L --fail -o "$CACHE/pyyaml.tar.gz" https://github.com/yaml/pyyaml/archive/refs/tags/6.0.2.tar.gz
      mkdir -p "$CACHE/pyyaml" && tar -xzf "$CACHE/pyyaml.tar.gz" --strip-components=1 -C "$CACHE/pyyaml"
    }
    export PYTHONPATH="$CACHE/pyyaml/lib${PYTHONPATH:+:$PYTHONPATH}"
    python3 -c 'import yaml' || die "PyYAML import failed"
  fi

  # 3. build patched modules. build.sh ends by trying to reload modules on a live system,
  #    which cannot work in a container; the .ko files are already installed by then.
  local MODDIR="/lib/modules/${KVER}/updates/cmpunlocker"
  CMPUNLOCKER_DRIVER_VERSION="$DRV" CMPUNLOCKER_CARD_PROFILE="$PROFILE" \
  CMPUNLOCKER_BUILD_DIR="$CACHE/build" \
    bash "$CACHE/cmpunlocker/driver/build.sh" || echo "(build.sh post-install step failed, expected in container)"
  [ -f "$MODDIR/nvidia.ko" ] || die "patched nvidia.ko not produced, see output above"

  # 4. stock Unraid package for same driver version
  local PKGURL="https://github.com/unraid/unraid-nvidia-driver/releases/download/${KVER}"
  [ -s "$CACHE/$PKG" ] || curl -L --fail -o "$CACHE/$PKG" "$PKGURL/$PKG" \
    || die "no ${DRV} package for ${KVER} at github.com/unraid/unraid-nvidia-driver/releases." \
           " Check the plugin's version dropdown for what's actually available, or try DRV=<other version>."
  curl -sL --fail -o "$CACHE/$PKG.md5" "$PKGURL/$PKG.md5"
  [ "$(md5sum "$CACHE/$PKG" | cut -d' ' -f1)" = "$(cut -d' ' -f1 < "$CACHE/$PKG.md5")" ] \
    || die "md5 mismatch on stock package"
  rm -rf /pkg && mkdir /pkg
  tar -xJf "$CACHE/$PKG" -C /pkg
  [ -f "/pkg/lib/firmware/nvidia/${DRV}/gsp_ga10x.bin" ] || die "GSP firmware missing in stock package"

  # 5. swap kernel modules, keep everything else
  local VID="/pkg/lib/modules/${KVER}/kernel/drivers/video" m
  mkdir -p "$VID" "/pkg${MODDIR}"
  for m in nvidia nvidia-modeset nvidia-uvm nvidia-drm nvidia-peermem; do
    [ -f "$MODDIR/$m.ko" ] || continue
    strip --strip-debug "$MODDIR/$m.ko"
    install -m 0644 "$MODDIR/$m.ko" "$VID/$m.ko"
  done
  cp "$MODDIR"/{driver_version,card_profile,unlock_geometry,gpu_inventory} "/pkg${MODDIR}/" 2>/dev/null || true
  echo "cmpunlocker ${CMPUNLOCKER_REF} $(date -u +%F) profile=${PROFILE}" > "/pkg${MODDIR}/unraid_build"

  # 6. repack as Slackware package with the stock filename
  rm -f "$OUT/$PKG" "$OUT/$PKG.md5"
  (cd /pkg && makepkg -l n -c n "$OUT/$PKG")
  md5sum "$OUT/$PKG" | cut -d' ' -f1 > "$OUT/$PKG.md5"
  echo "==> built $OUT/$PKG ($(du -h "$OUT/$PKG" | cut -f1))"
}

# ---------------------------------------------------------------- host: build
build_host() {
  command -v docker >/dev/null || die "docker not running (start the array / docker service)"
  detect_profile
  mkdir -p "$SCRIPT_DIR/out" "$SCRIPT_DIR/cache"
  docker run --rm -it --entrypoint bash \
    -e IN_CONTAINER=1 -e DRV="$DRV" -e PROFILE="$PROFILE" -e CMPUNLOCKER_REF="$CMPUNLOCKER_REF" \
    -v "$SCRIPT_DIR":/work \
    "$IMAGE" /work/cmpunraider.sh build
  echo
  echo "Next: bash $SCRIPT_DIR/cmpunraider.sh install"
}

# ---------------------------------------------------------------- host: install
install_host() {
  local PLG=/boot/config/plugins/nvidia-driver PKGDIR SRC="$SCRIPT_DIR/out/$PKG"
  PKGDIR="$PLG/packages/$KSHORT"
  [ -f "$SRC" ] || die "$SRC not found, run: bash cmpunraider.sh build"
  [ -d "$PLG" ] || die "Nvidia-Driver plugin not installed"
  detect_profile
  [ "$CARD_FOUND" = 1 ] || [ -n "${FORCE:-}" ] || die "no CMP 170HX in this system; install the card first (or FORCE=1)"
  local need free
  need=$(du -m "$SRC" | cut -f1); free=$(df -m /boot | awk 'NR==2{print $4}')
  [ "$free" -gt "$((need + 50))" ] || die "only ${free}MB free on /boot, need ~${need}MB"

  mkdir -p "$PKGDIR"
  rm -f "$PKGDIR"/*                 # plugin installs the newest-sorted file here; leave only ours
  cp "$SRC" "$SRC.md5" "$PKGDIR/"

  cp -n "$PLG/settings.cfg" "$SCRIPT_DIR/out/settings.cfg.orig"   # for uninstall; -n keeps first backup
  sed -i "/^driver_version=/c\driver_version=${DRV}" "$PLG/settings.cfg"
  grep -q '^update_check=' "$PLG/settings.cfg" \
    && sed -i '/^update_check=/c\update_check=false' "$PLG/settings.cfg" \
    || echo "update_check=false" >> "$PLG/settings.cfg"

  # same modprobe option cmpunlocker's install.sh writes; Unraid copies this dir to /etc/modprobe.d at boot
  mkdir -p /boot/config/modprobe.d
  echo 'options nvidia NVreg_RegistryDwords="RmForceEnableGen2=1;RMPcieLinkSpeed=0x1"' \
    > /boot/config/modprobe.d/cmp-pcie-gen2.conf

  # The plugin has already loaded the driver by the time go runs, but by then the card advertises only
  # Gen1 (LnkCap2=00000002), so no retrain can work. Loading the driver sets LnkCap2=00000006 (the driver's
  # own retrain at probe misses), so go unloads it (nothing else uses it yet: no docker, no persistence
  # mode), reloads it, then retrains: that succeeds at iteration 1. Attempts capped: 600 blocked boot ~41s.
  local HAMMER="$SCRIPT_DIR/cache/cmpunlocker/tools/hammer.sh"
  [ -f "$HAMMER" ] || die "$HAMMER not found, run: bash cmpunraider.sh build"
  cp "$HAMMER" /boot/config/cmp-gen2-hammer.sh
  sed -i '/# cmp-unraid gen2/d' /boot/config/go
  sed -i '\|/usr/local/sbin/emhttp|i ( rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia; modprobe nvidia; modprobe nvidia_uvm; CMP170HX_GEN2_MAX_ITERATIONS=100 bash /boot/config/cmp-gen2-hammer.sh ) 2>/dev/null  # cmp-unraid gen2' /boot/config/go
  grep -q '# cmp-unraid gen2' /boot/config/go || die "no emhttp line in /boot/config/go; add manually before it: bash /boot/config/cmp-gen2-hammer.sh"

  cat <<EOF

Installed $PKG to $PKGDIR
Now do a COLD boot: shut down, wait for power to fully drop, power on.
Verify after boot:
  nvidia-smi --query-gpu=name,memory.total,pcie.link.gen.current --format=csv
  dmesg | grep SEC2_DEBUG
  bash $SCRIPT_DIR/cache/cmpunlocker/verify.sh
Revert: bash $SCRIPT_DIR/cmpunraider.sh uninstall ; reboot
EOF
}

# ---------------------------------------------------------------- host: uninstall
uninstall_host() {
  local PLG=/boot/config/plugins/nvidia-driver PKGDIR="$PLG/packages/$KSHORT"
  [ -d "$PLG" ] || die "Nvidia-Driver plugin not installed"

  local STOCK="$SCRIPT_DIR/cache/$PKG" ORIG="$SCRIPT_DIR/out/settings.cfg.orig"
  rm -f "$PKGDIR"/*
  rm -f /boot/config/modprobe.d/cmp-pcie-gen2.conf /boot/config/cmp-gen2-hammer.sh
  sed -i '/# cmp-unraid gen2/d' /boot/config/go
  [ -s "$ORIG" ] && mv "$ORIG" "$PLG/settings.cfg" && echo "Restored original settings.cfg"

  if [ -s "$STOCK" ] && [ -s "$STOCK.md5" ] \
     && [ "$(md5sum "$STOCK" | cut -d' ' -f1)" = "$(cut -d' ' -f1 < "$STOCK.md5")" ]; then
    mkdir -p "$PKGDIR"
    cp "$STOCK" "$STOCK.md5" "$PKGDIR/"     # stock package from build cache, same version, no download
    echo "Restored stock $PKG"
  else
    # empty dir => plugin downloads the NEWEST driver at boot and sets driver_version=latest
    sed -i '/^driver_version=/c\driver_version=latest' "$PLG/settings.cfg"
    echo "No cached stock package; plugin will download the newest driver on next boot (needs internet)."
  fi

  cat <<EOF

Patched modules and modprobe option removed. Reboot.
Verify: nvidia-smi --query-gpu=memory.total,pcie.link.gen.current --format=csv   (expect stock 8192/10240 MiB, gen 1)
Optional: rm -rf $SCRIPT_DIR/out $SCRIPT_DIR/cache   (build cache, ~1GB)
EOF
}

case "$CMD" in
  build)     if [ -n "${IN_CONTAINER:-}" ]; then build_inside; else build_host; fi ;;
  install)   install_host ;;
  uninstall) uninstall_host ;;
  *) die "usage: $0 build|install|uninstall" ;;
esac
