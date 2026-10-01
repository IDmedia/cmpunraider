# cmpunraider – Unlock the CMP 170HX's full 64 GB on Unraid

Builds an Nvidia driver package for Unraid whose kernel modules are patched with
[cmpunlocker](https://github.com/amoghmunikote/cmpunlocker), and drops it in place of the
stock package used by the Nvidia-Driver plugin. The plugin then loads it on every boot,
so the card is unlocked automatically. No VM, no User Scripts.

## Prerequisites

- Unraid 7.x with the **Nvidia-Driver plugin** (Community Apps) installed. The plugin stays
  installed; it is what loads the package at boot and wires up Docker.
- Don't touch the driver version dropdown in *Settings → Nvidia Driver* before running
  `install` — it writes `driver_version=615.71.09` (the regular `nvidia-*` build, not the
  "Open Source" `nvos-*` one) into `settings.cfg` for you. Changing it in the GUI first just
  triggers a pointless live download of the stock driver that `install` immediately overwrites.
- Docker service running (the build runs inside a container).
- Internet access during `build`.
- ~1.5 GB free on the share where you put the script (build cache + output), ~400 MB free on the flash drive.
- CMP 170HX installed (only needed for `install`; `build` works without the card).

## Commands

Run as root in the Unraid terminal, from the folder containing the script
(e.g. `/mnt/user/appdata/cmpunraider/`).

### `bash cmpunraider.sh build`

Builds the package. Writes nothing outside the script's own folder.

- Pulls Docker image `ghcr.io/ich777/unraid_kernel:gcc_14.2.0`.
- Downloads the pre-compiled Unraid kernel tree, cmpunlocker, PyYAML and the stock
  `nvidia-<driver>-<kernel>-1.txz` into `./cache/`.
- Compiles the patched open kernel modules, swaps them into the stock package, repacks.
- Output: `./out/nvidia-615.71.09-6.18.38-Unraid-1.txz` and `.md5`.

Env overrides:
- `DRV=610.43.03` – other driver version (must be in cmpunlocker's supported list).
- `PROFILE=8gb|10gb` – auto-detected from the card, defaults to 8gb without card.
- `CMPUNLOCKER_REF=v0.4` – cmpunlocker tag or branch to build. Defaults to the tested release `v0.4`
  so builds stay reproducible. Use `CMPUNLOCKER_REF=master` for the latest upstream changes (untested
  here, so recheck memory size and gen 2 after the build), or another tag like `v0.5` when one exists.
  The chosen ref is cached in `./cache/cmpunlocker`; it is re-downloaded on every `build`.

### `bash cmpunraider.sh install`

Puts the package where the plugin loads it. Refuses without a CMP 170HX present
(`FORCE=1` overrides). Changes on the flash drive (`/boot`):

| Path | Change |
|---|---|
| `/boot/config/plugins/nvidia-driver/packages/6.18.38/` | Stock `.txz` + `.md5` deleted, patched ones copied in |
| `/boot/config/plugins/nvidia-driver/settings.cfg` | `driver_version=615.71.09`, `update_check=false`. Original saved to `./out/settings.cfg.orig` |
| `/boot/config/modprobe.d/cmp-pcie-gen2.conf` | Created (PCIe Gen2 module option from cmpunlocker) |
| `/boot/config/cmp-gen2-hammer.sh` | Copy of cmpunlocker's `tools/hammer.sh`. Retrains the link to Gen2; this only works while the nvidia driver is not loaded |
| `/boot/config/go` | One line inserted before `emhttp` (marked `# cmp-unraid gen2`) that unloads the nvidia modules (the plugin has already loaded them), runs the script above (capped at 100 attempts), and reloads them. Adds ~7 s to boot; log in `/var/log/gen2.log`. The log usually says "no Gen2 window caught" even when the link comes up at Gen2 after the reload, so trust `nvidia-smi`, not the log |

Then **power off completely** (not a warm reboot), power on, verify:

```bash
nvidia-smi --query-gpu=name,memory.total,pcie.link.gen.current --format=csv
```

Expect ~65536 MiB and PCIe gen 2 for the 8 GB card (~40960 MiB for the 10 GB card). The card
boots at gen 1; the `go` hook above retrains it to gen 2. Check `pcie.link.gen.current` while the
GPU is busy, since an idle card can report a lower speed. The link width (e.g. x8) is set by your
motherboard slot, not by this tool.

**Expect a harmless "Gen2 failed" message.** On every boot the console and `/var/log/gen2.log` show
`no Gen2 window caught after 100 attempts` (rc=1), and `dmesg` shows
`CMP Gen2: PCIe retrain completed without Gen2 link`. Both are snapshots taken before the link finishes
retraining. The link still comes up at gen 2 after the driver reloads, so judge by `nvidia-smi` and
`lspci -vv -s <bdf> | grep LnkSta:` (`Speed 5GT/s`), not by those messages.

If it stays at gen 1, check `setpci -s <bdf> CAP_EXP+2c.l`: `00000006` means the card advertises
gen 2, `00000002` means it doesn't. In the second case the retrain can't help.

### `bash cmpunraider.sh uninstall`

Reverts everything `build` and `install` did, then reboot:

- Restores the stock `.txz` + `.md5` from `./cache/` into the packages dir.
- Restores `settings.cfg` from `./out/settings.cfg.orig`.
- Deletes `/boot/config/modprobe.d/cmp-pcie-gen2.conf` (and the dir, if it's now empty), `/boot/config/cmp-gen2-hammer.sh`, and the marked line in `/boot/config/go`.
- Keeps `./cache/` and `./out/` (build cache, ~1 GB) and the `ghcr.io/ich777/unraid_kernel` Docker
  image. Delete them by hand (`rm -rf cache out`, `docker rmi ...`) if you want the space back.
- Keeps `cmpunraider.sh` and this README — delete those by hand if you want them gone too.

If `./cache/` was already gone, the packages dir is left empty and the plugin downloads the
newest stock driver on next boot instead (needs internet).

Nothing else is touched. Unraid's root filesystem lives in RAM and is rebuilt from `/boot`
at every boot, so no live-system change survives a reboot on its own.

## Notes

- **Unraid OS update** = new kernel. The plugin downloads a stock driver for the new kernel
  and the unlock is gone until you rerun `build` then `install`.
- Do not change the driver version or click update in the plugin GUI while installed; that
  overwrites the patched package with stock.
- Plugin (.plg) updates are fine; they do not touch the packages dir.
- Unlocked HBM is binned silicon. Test the memory before trusting all 64 GB.

## Dependency risk

`build` needs a pre-compiled Unraid kernel source tree matching your exact `uname -r`,
published at [ich777/unraid_kernel](https://github.com/ich777/unraid_kernel/releases). As of
September 2026 ich777 has stepped back from actively maintaining Unraid plugins/drivers;
existing releases stay downloadable indefinitely (GitHub doesn't remove them), but a brand
new Unraid kernel version might not get a matching release right away, or ever.

A generic `gcc` Docker image would not fix this — the missing piece isn't the compiler, it's
Unraid's patched kernel source/config for your exact kernel build, which only exists in that
repo's releases. If `build` fails with "no pre-compiled kernel tree", either wait for a
matching release to appear, or stay on your current Unraid version until one does.

## Credits

The actual unlock (the patched open-gpu-kernel-modules for the CMP 170HX) is the work of
[amoghmunikote/cmpunlocker](https://github.com/amoghmunikote/cmpunlocker) and its contributors.
cmpunraider only packages it for Unraid: it builds cmpunlocker's patched modules against the
Unraid kernel and swaps them into the stock Nvidia-Driver plugin package. All credit for the
unlock itself goes to them.
