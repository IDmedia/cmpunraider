# cmpunraider – Unlock the CMP 170HX's full 64 GB on Unraid

Builds an Nvidia driver package for Unraid with kernel modules patched by
[cmpunlocker](https://github.com/amoghmunikote/cmpunlocker) and puts it where the Nvidia-Driver
plugin loads its driver from. The card is unlocked on every boot. No VM, no User Scripts.

```bash
bash cmpunraider.sh build      # compile the patched driver (needs Docker + internet)
bash cmpunraider.sh install    # put it in place, then power off completely and boot
nvidia-smi --query-gpu=memory.total,pcie.link.gen.current --format=csv    # check it worked
```

## Prerequisites

- Unraid 7.x with the **Nvidia-Driver plugin** installed. It stays installed and loads the package at boot.
- Docker running (the build happens in a container) and internet access during `build`.
- ~1.5 GB free where you keep the script (build cache + output) and ~400 MB on the flash drive.
- The CMP 170HX installed (only `install` needs it; `build` works without).
- Leave the plugin's driver version dropdown alone before `install`. `install` sets `driver_version`
  for you, and changing it in the GUI first just triggers a pointless download.

## Commands

Run as root from the folder containing the script, e.g. `/mnt/user/system/cmpunraider/`.

### `bash cmpunraider.sh build`

Downloads the pre-compiled Unraid kernel tree, cmpunlocker and the stock
`nvidia-<driver>-<kernel>-1.txz` into `./cache/`, compiles the patched modules, swaps them into the
stock package and writes `./out/nvidia-<driver>-<kernel>-1.txz`. Nothing outside the script's folder is touched.

Optional environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `DRV` | `615.71.09` | Driver version; must be in cmpunlocker's `driver/VERSION` and available as an Unraid package for your kernel |
| `CMPUNLOCKER_REF` | `v0.5` | cmpunlocker tag or branch. The default keeps builds reproducible; `master` takes the latest changes (untested here, recheck the card after building) |
| `PROFILE` | auto | `8gb`, `10gb` or `mixed`; detected from `lspci`, `8gb` if no card is found |
| `FORCE` | unset | `FORCE=1` lets `install` run without a card present |

### `bash cmpunraider.sh install`

Refuses without a CMP 170HX present. Changes on the flash drive (`/boot`):

| Path | Change |
|---|---|
| `config/plugins/nvidia-driver/packages/<kernel>/` | Stock `.txz` + `.md5` replaced by the patched ones |
| `config/plugins/nvidia-driver/settings.cfg` | `driver_version` set, `update_check=false`. Original saved to `./out/settings.cfg.orig` |
| `config/modprobe.d/cmp-pcie-gen2.conf` | PCIe Gen2 module option from cmpunlocker |
| `config/cmp-gen2-hammer.sh` | Copy of cmpunlocker's `tools/hammer.sh`, which retrains the link to Gen2 |
| `config/go` | One line (marked `# cmp-unraid gen2`) before `emhttp`: reloads the nvidia modules, then runs `cmp-gen2-hammer.sh`. Adds a few seconds to boot; log in `/var/log/gen2.log` |

Then **power off completely** (not a warm reboot), wait for the power to drop, and power on.

### `bash cmpunraider.sh uninstall`

Reverts `install`, then reboot:

- Restores the stock package from `./cache/` and `settings.cfg` from `./out/settings.cfg.orig`.
- Deletes the modprobe file, `cmp-gen2-hammer.sh` and the marked line in `go`.
- Keeps `./cache/`, `./out/` (~1 GB), the Docker image and the script. Delete them by hand if you want the space back.

Without a cached stock package the plugin downloads the newest stock driver at next boot (needs internet).

## Verify it worked

```bash
nvidia-smi --query-gpu=name,memory.total,pcie.link.gen.current --format=csv
```

| Result | Meaning |
|---|---|
| `NVIDIA CMP 170HX`, `65536 MiB` (8 GB card) or ~`40960 MiB` (10 GB card), gen `2` | Fully working |
| `8192 MiB` / `10240 MiB` or name `NVIDIA Graphics Device` | Memory unlock not active, see below |
| Memory correct, gen `1` | Gen2 retrain didn't take, see below |

An idle card can report a lower link speed, so check gen while the GPU is busy. For more detail:

```bash
nvidia-smi -q -d ECC                                  # ECC Mode "Enabled" and error counters at 0 (cmpunlocker v0.5+)
lspci -vv -s <bdf> | grep LnkSta:                     # Speed 5GT/s = gen 2; width (x8, x16) comes from your slot
bash <script folder>/cache/cmpunlocker/verify.sh      # cmpunlocker's own check: memory, profile and PCIe gen
dmesg | grep "late PMA extension status=0x0"          # one line per unlocked card (full unlock log: grep SEC2_DEBUG, ~100 lines)
cat /var/log/gen2.log                                 # result of the boot-time Gen2 retrain
```

Watch the ECC counters over time: correctable errors (`DRAM Correctable`) are fixed by ECC, but a counter that
keeps rising, or any `Uncorrectable` error, means failing memory. That is the check for the binned HBM
mentioned in Notes.

**Memory still stock.** Make sure you did a full power-off, not a warm reboot. Check that the patched driver is
loaded (`modinfo -F version nvidia`, `dmesg | grep SEC2_DEBUG`). An Unraid update brings a new kernel and the
plugin then installs a stock driver, so rerun `build` and `install`.

**Gen 1 instead of Gen 2.**
- `grep "cmp-unraid gen2" /boot/config/go` must show the line; if not, rerun `install`.
- `setpci -s <bdf> CAP_EXP+2c.l` reads `00000006` when the card advertises Gen 2 and `00000002` when it doesn't.
  The retrain only works in the first case, and the driver reload in the hook is what produces it.
- `dmesg` always shows `CMP Gen2: PCIe retrain completed without Gen2 link`. That is the driver's own
  retrain at load, which misses; ignore it and judge by `nvidia-smi` and `lspci`.

## Notes

- **Unraid OS update** = new kernel, so the unlock is gone until you rerun `build` and `install`.
- Don't change the driver version or click update in the plugin GUI while installed; that replaces the patched package with stock.
- **Multiple cards:** the patches identify cards by PCI ID and the retrain handles every card it finds, so several
  cards should work, but this is only tested with one. A mixed 8 GB + 10 GB setup uses the `mixed` profile.
- Unlocked HBM is binned silicon. Test the memory before trusting all 64 GB.

## Dependency risk

`build` needs a pre-compiled Unraid kernel tree matching your exact `uname -r`, published at
[ich777/unraid_kernel](https://github.com/ich777/unraid_kernel/releases). As of September 2026 ich777 has
stepped back from maintaining Unraid plugins and drivers. Existing releases stay downloadable, but a new
Unraid kernel might not get a matching release right away, or ever. A generic `gcc` image doesn't help, because
the missing piece is Unraid's patched kernel config, not the compiler. If `build` fails with "no pre-compiled
kernel tree", wait for a matching release or stay on your current Unraid version.

## Credits

The unlock itself (the patched open-gpu-kernel-modules for the CMP 170HX) is the work of
[amoghmunikote/cmpunlocker](https://github.com/amoghmunikote/cmpunlocker) and its contributors.
cmpunraider only packages it for Unraid.
