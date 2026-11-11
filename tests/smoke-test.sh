#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo bash tests/smoke-test.sh" >&2; exit 1; }
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/etc/systemd/system" "$ROOT/etc/systemd/system-sleep"
export MOCK_ROOT="$ROOT"
cat > "$ROOT/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
set -e
printf '%s\n' "$*" >> "$MOCK_ROOT/nvidia.log"
case " $* " in
  *'--query-gpu=clocks.max.graphics'*) printf '3000\n' ;;
  *'--query-gpu=name '*) printf 'NVIDIA GeForce RTX 5070\n' ;;
  *'--query-gpu=name,pstate'*) printf 'NVIDIA GeForce RTX 5070, P3, 800 MHz, 1000 MHz, 30 W\n' ;;
  *'--query-gpu=index,uuid'*) printf '0, GPU-a1b2c3, NVIDIA RTX 5070, 590, 3000 MHz\n' ;;
  *'-lgc '*) printf 'GPU clock lock applied\n' ;;
  *'-rgc '*) printf 'GPU clocks reset\n' ;;
  *) printf 'OK\n' ;;
esac
EOF
cat > "$ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -e
printf '%s\n' "$*" >> "$MOCK_ROOT/systemctl.log"
case " $* " in
  *'is-active'*) test -e "$MOCK_ROOT/active" ;;
  *'is-enabled'*) test -e "$MOCK_ROOT/enabled" ;;
  *'enable'*) touch "$MOCK_ROOT/enabled" ;;
  *'restart'*) touch "$MOCK_ROOT/active" ;;
  *'start '*) touch "$MOCK_ROOT/active" ;;
  *'disable'*) rm -f "$MOCK_ROOT/enabled" "$MOCK_ROOT/active" ;;
  *'stop '*) rm -f "$MOCK_ROOT/active" ;;
esac
EOF
chmod +x "$ROOT/bin/"*
export PATH="$ROOT/bin:$PATH"
SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/nvidia-hdmi-audio-fix.sh"
DEST="$ROOT/nvidia-hdmi-audio-fix.sh"
python - "$SRC" "$DEST" "$ROOT" <<'PY'
import sys
s=open(sys.argv[1]).read()
r=sys.argv[3]
s=s.replace('readonly INSTALL_DIR="/etc/${APP}"', f'readonly INSTALL_DIR="{r}/etc/${{APP}}"')
s=s.replace('readonly UNIT_FILE="/etc/systemd/system/${SERVICE}"', f'readonly UNIT_FILE="{r}/etc/systemd/system/${{SERVICE}}"')
s=s.replace('readonly RESUME_HOOK="/etc/systemd/system-sleep/${APP}"', f'readonly RESUME_HOOK="{r}/etc/systemd/system-sleep/${{APP}}"')
s=s.replace('readonly BIN_DIR="/usr/local/bin"', f'readonly BIN_DIR="{r}/usr/local/bin"')
s=s.replace('mkdir -p /etc/systemd/system-sleep', f'mkdir -p {r}/etc/systemd/system-sleep')
open(sys.argv[2], 'w').write(s)
PY
chmod +x "$DEST"
bash -n "$DEST"
"$DEST" install --min 800 --max auto
[[ -f "$ROOT/etc/systemd/system/nvidia-hdmi-audio-fix.service" ]]
[[ -f "$ROOT/etc/nvidia-hdmi-audio-fix/nvidia-hdmi-audio-fix.sh" ]]
[[ -L "$ROOT/usr/local/bin/nvidia-audio-fix" ]]
[[ -L "$ROOT/usr/local/bin/nvidia-hdmi-audio-fix" ]]
"$DEST" apply --min 740
rg='740,3000'
grep -q -- "$rg" "$ROOT/nvidia.log"
"$DEST" configure --min 750
[[ $(grep '^MIN_CLOCK' "$ROOT/etc/nvidia-hdmi-audio-fix/config") == MIN_CLOCK=750 ]]
"$DEST" status
"$DEST" disable
"$DEST" uninstall
[[ ! -f "$ROOT/etc/systemd/system/nvidia-hdmi-audio-fix.service" ]]
[[ ! -f "$ROOT/etc/nvidia-hdmi-audio-fix/config" ]]
[[ ! -e "$ROOT/usr/local/bin/nvidia-audio-fix" ]]
if "$DEST" install --min 740 --max 700 >/dev/null 2>&1; then
  echo 'FAILED: invalid min > max accepted' >&2
  exit 1
fi
printf '\nPASS: integration smoke test\n'
