# NVIDIA HDMI Audio Dropout Workaround (Bazzite / Linux)

A small, reversible workaround for recurring **HDMI/DisplayPort audio dropouts** on Linux systems with an NVIDIA GPU. It installs a root-owned **systemd system service** to request a minimum NVIDIA graphics clock while leaving the maximum at the GPU's reported maximum.

> **Community workaround, not a driver patch or an official NVIDIA/Bazzite solution.** The clock floor may increase idle power use. The observed stable minimum depends on the GPU, firmware, driver, display, and workload.

## Why it exists

On one **NVIDIA RTX 5070 running Bazzite KDE**, HDMI audio cut out with unrestricted GPU clocks. The following minimum graphics clock limits were observed:

| Requested minimum | HDMI audio (local test) |
| --- | --- |
| No restriction | Dropouts |
| 700 MHz | Dropouts |
| 740 MHz | Dropouts |
| 750 MHz | No dropouts observed |
| 1000 MHz | No dropouts observed |

**750 MHz was the local observed threshold, not a universal GPU specification.** This tool defaults to **800 MHz** to provide a small margin. Other GPUs may need different settings. No change to VRAM clocks or PCIe configuration is made.

## Requirements

- Linux with `systemd` (tested design for Bazzite KDE)
- NVIDIA driver exposing `nvidia-smi` and supporting `-lgc`/`-rgc`
- Root access (`sudo`) for installation and GPU clock changes
- `bash`, `systemctl`, and common coreutils

On Bazzite, `/etc` is writable despite the image-based `/usr` filesystem. This project places its files under `/etc/`.

## Quick start

```bash
chmod +x nvidia-hdmi-audio-fix.sh
sudo ./nvidia-hdmi-audio-fix.sh install --min 800 --max auto
nvidia-hdmi-audio-fix status
```

The installer:

1. Copies the script to `/etc/nvidia-hdmi-audio-fix/nvidia-hdmi-audio-fix.sh`.
2. Creates `/etc/nvidia-hdmi-audio-fix/config`.
3. Creates and enables `/etc/systemd/system/nvidia-hdmi-audio-fix.service` so the fix is applied automatically at boot.
4. Adds a lightweight resume hook under `/etc/systemd/system-sleep/`.
5. Installs a CLI command in `/usr/local/bin` (`nvidia-hdmi-audio-fix`, plus `nvidia-audio-fix`).
6. Applies the requested clock range immediately.

At each start, `--max auto` queries the selected GPU's reported max graphics clock. The tool **does not** hardcode a maximum clock value or disable GPU Boost.

## Commands

After installation, use the `nvidia-hdmi-audio-fix` command:

```bash
# Inspect device and unit state
nvidia-hdmi-audio-fix status
nvidia-hdmi-audio-fix monitor
nvidia-hdmi-audio-fix diagnose
nvidia-hdmi-audio-fix logs

# Change the configured floor and reapply if the service is running
sudo nvidia-hdmi-audio-fix configure --min 750

# Change GPU if multiple NVIDIA GPUs are present
sudo nvidia-hdmi-audio-fix configure --gpu 0 --min 800

# Temporarily test another floor WITHOUT saving it to the boot configuration
sudo nvidia-hdmi-audio-fix apply --min 900

# Disable/enable automatic application at boot
sudo nvidia-hdmi-audio-fix disable
sudo nvidia-hdmi-audio-fix enable

# Remove everything installed by the script
sudo nvidia-hdmi-audio-fix uninstall
```

The script can also be run directly from the repository or from its installed path:

```bash
sudo ./nvidia-hdmi-audio-fix.sh install --min 800 --max auto
sudo /etc/nvidia-hdmi-audio-fix/nvidia-hdmi-audio-fix.sh configure --min 800
```

### Recovery / rollback

If changing frequencies causes trouble:

```bash
sudo systemctl disable --now nvidia-hdmi-audio-fix.service
sudo nvidia-smi -i 0 -rgc
```

To remove the service and associated files:

```bash
sudo ./nvidia-hdmi-audio-fix.sh uninstall
```

If the NVIDIA driver is unavailable at boot, the script retries driver detection before failing; inspect `journalctl -b -u nvidia-hdmi-audio-fix.service` for errors. A failed startup does **not** prevent normal Linux boot.

## How it works

The key operation is equivalent to:

```bash
MAX=$(nvidia-smi --query-gpu=clocks.max.graphics --format=csv,noheader,nounits | head -n1 | tr -d ' ')
sudo nvidia-smi -i 0 -lgc "800,$MAX"
```

This requests a lower and upper graphics-clock boundary, **not a guarantee of an exact operating frequency**. NVIDIA can still adjust or throttle clocks under various conditions. The service runs as `root` because NVIDIA requires elevated privileges for clock locking.

`Type=oneshot` with `RemainAfterExit=yes` keeps the service active so `ExecStop` can request `nvidia-smi -rgc` on stop. A non-blocking systemd sleep hook asks the service to reapply its setting after resume.

The script deliberately does **not**:

- Set GPU power limits, overclock, force a specific P-state or disable NVIDIA power management globally.
- Set memory-clock constraints (`-lmc`).
- Edit the kernel command line, PipeWire configuration, or Bazzite image.
- Download and execute remote code.

## Troubleshooting

```bash
nvidia-smi -L
nvidia-smi -q -d CLOCK
systemctl status nvidia-hdmi-audio-fix.service
journalctl -b -u nvidia-hdmi-audio-fix.service --no-pager
```

- **`nvidia-smi` not found:** Use a compatible Bazzite NVIDIA image; check that NVIDIA drivers have loaded.
- **Clock lock returns `Not Supported`:** The particular GPU/driver does not expose this feature.
- **Settings lost after driver reset or resume:** Try `sudo systemctl restart nvidia-hdmi-audio-fix.service` and inspect logs; driver restarts during a session may require a manual reapply.
- **No audio improvement:** Disable the workaround; unrelated HDMI, AVR, WirePlumber or PipeWire issues can have the same symptoms.
- **Multiple NVIDIA GPUs:** Select a GPU index or `GPU-...` UUID using `--gpu`.

## Related discussions / references

- [Bazzite #5115 - GPU audio issues](https://github.com/ublue-os/bazzite/issues/5115)
- [NVIDIA Developer Forums - audio via HDMI often interrupted](https://forums.developer.nvidia.com/t/audio-pass-through-via-hdmi-often-interrupted/270808)
- [NVIDIA `nvidia-smi` official documentation](https://docs.nvidia.com/deploy/nvidia-smi/)

## License

MIT. See [`LICENSE`](LICENSE).

## Offline smoke test

The included smoke test uses fake `nvidia-smi` and `systemctl` executables in a temporary directory. It does **not** change real system services or GPU clocks, but uses `sudo` to exercise the installer's root checks:

```bash
sudo bash tests/smoke-test.sh
```
