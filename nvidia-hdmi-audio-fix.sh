#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# NVIDIA HDMI/DisplayPort audio dropout workaround for Bazzite and other
# systemd-based Linux distributions.
#
# This is a workaround, not a driver fix. It sets a configurable minimum
# NVIDIA graphics clock while preserving an automatic maximum clock.

set -Eeuo pipefail

readonly VERSION='1.1.0'
readonly APP='nvidia-hdmi-audio-fix'
readonly SERVICE="${APP}.service"
readonly INSTALL_DIR="/etc/${APP}"
readonly INSTALLED_SCRIPT="${INSTALL_DIR}/${APP}.sh"
readonly CONFIG_FILE="${INSTALL_DIR}/config"
readonly UNIT_FILE="/etc/systemd/system/${SERVICE}"
readonly RESUME_HOOK="/etc/systemd/system-sleep/${APP}"
readonly BIN_DIR="/usr/local/bin"
readonly CLI_NAME='nvidia-hdmi-audio-fix'

# Defaults are intentionally conservative. The minimum is adjustable.
MIN_CLOCK=800
MAX_CLOCK=auto
GPU_SELECTOR=0

log()   { printf '[%s] %s\n' "$APP" "$*"; }
warn()  { printf '[%s] WARNING: %s\n' "$APP" "$*" >&2; }
die()   { printf '[%s] ERROR: %s\n' "$APP" "$*" >&2; exit 1; }

usage() {
    cat <<HELP
NVIDIA HDMI audio dropout workaround (Bazzite / systemd)

Usage:
  $CLI_NAME install [--min MHz] [--max MHz|auto] [--gpu INDEX|UUID]
  $CLI_NAME configure [--min MHz] [--max MHz|auto] [--gpu INDEX|UUID]
  $CLI_NAME apply [--min MHz] [--max MHz|auto] [--gpu INDEX|UUID]
  $CLI_NAME reset
  $CLI_NAME enable
  $CLI_NAME disable
  $CLI_NAME status
  $CLI_NAME monitor
  $CLI_NAME diagnose
  $CLI_NAME logs
  $CLI_NAME uninstall
  $CLI_NAME --help

Examples:
  sudo ./nvidia-hdmi-audio-fix.sh install --min 800
  sudo $CLI_NAME configure --min 750
  sudo $CLI_NAME configure --min 800 --max auto
  $CLI_NAME monitor
  $CLI_NAME status
  sudo $CLI_NAME disable

Details:
  install    Install files, enable boot-time service, and apply now.
  configure  Save clock settings; restart the service if it is active.
  apply      Apply clocks immediately (overrides are NOT saved).
  reset      Restore default GPU graphics clocks (does not disable startup).
  enable     Reenable the installed service and apply the workaround.
  disable    Disable startup and restore default GPU graphics clocks.
  status     Show installed configuration and current GPU clocks.
  monitor    Continuously monitor GPU P-state, clocks, PCIe and power.
  diagnose   Print diagnostic information for troubleshooting.
  logs       Show this boot's service logs.
  uninstall  Disable, reset clocks and remove installed files.

Notes:
  install also creates a CLI symlink in $BIN_DIR ($CLI_NAME).
  --max auto queries NVIDIA's maximum graphics clock at each application.
  --gpu defaults to 0. Use an NVIDIA GPU index or GPU-... UUID.
  Changing GPU clocks can increase idle power consumption.
  This tool does not change GPU power limits, overclock or lock VRAM clocks.
HELP
}

require_root() {
    (( EUID == 0 )) || die 'Root privileges required. Retry with sudo.'
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # The configuration is installed root-owned and not user-writable.
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
}

parse_options() {
    while (( $# > 0 )); do
        case "$1" in
            --min|--max|--gpu)
                (( $# >= 2 )) || die "Missing value for $1"
                case "$1" in
                    --min) MIN_CLOCK=$2 ;;
                    --max) MAX_CLOCK=$2 ;;
                    --gpu) GPU_SELECTOR=$2 ;;
                esac
                shift 2
                ;;
            --min=*) MIN_CLOCK=${1#*=}; shift ;;
            --max=*) MAX_CLOCK=${1#*=}; shift ;;
            --gpu=*) GPU_SELECTOR=${1#*=}; shift ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

validate_settings() {
    [[ "$MIN_CLOCK" =~ ^[0-9]{1,5}$ ]] || die 'Minimum clock must be a positive integer in MHz.'
    MIN_CLOCK=$((10#$MIN_CLOCK))
    (( MIN_CLOCK >= 100 && MIN_CLOCK <= 6000 )) || die 'Minimum must be between 100 and 6000 MHz.'

    if [[ "$MAX_CLOCK" != auto ]]; then
        [[ "$MAX_CLOCK" =~ ^[0-9]{1,5}$ ]] || die 'Maximum must be auto or a positive integer in MHz.'
        MAX_CLOCK=$((10#$MAX_CLOCK))
        (( MAX_CLOCK >= MIN_CLOCK && MAX_CLOCK <= 6000 )) || die 'Maximum must be >= minimum and <= 6000 MHz.'
    fi

    [[ "$GPU_SELECTOR" =~ ^([0-9]+|GPU-[A-Za-z0-9-]+)$ ]] || die 'GPU must be an index or NVIDIA GPU-... UUID.'
}

write_config() {
    require_root
    require_command mktemp
    mkdir -p "$INSTALL_DIR"
    chmod 0755 "$INSTALL_DIR"
    local temp_file
    temp_file=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")
    {
        printf '# Managed by %s. Edit using the configure command.\n' "$APP"
        printf 'MIN_CLOCK=%q\n' "$MIN_CLOCK"
        printf 'MAX_CLOCK=%q\n' "$MAX_CLOCK"
        printf 'GPU_SELECTOR=%q\n' "$GPU_SELECTOR"
    } > "$temp_file"
    chmod 0644 "$temp_file"
    mv -f -- "$temp_file" "$CONFIG_FILE"
}

nvidia_bin() {
    command -v nvidia-smi || die 'nvidia-smi not found. Install/use a Bazzite NVIDIA image.'
}

# When max=auto, the maximum is read from the selected GPU during each start.
# The retry allows systemd to invoke the service while the driver is loading.
resolve_clock_range() {
    local nvidia=$1
    local detected_max='' info='' attempt

    for ((attempt=1; attempt<=30; attempt++)); do
        if info=$("$nvidia" -i "$GPU_SELECTOR" --query-gpu=name --format=csv,noheader 2>/dev/null) && [[ -n "$info" ]]; then
            break
        fi
        sleep 1
    done
    [[ -n "$info" ]] || die "GPU $GPU_SELECTOR not available after 30 attempts."

    if [[ "$MAX_CLOCK" == auto ]]; then
        if ! detected_max=$("$nvidia" -i "$GPU_SELECTOR" \
                --query-gpu=clocks.max.graphics --format=csv,noheader,nounits 2>/dev/null); then
            die 'Cannot query maximum graphics clock. Try --max with a supported MHz value.'
        fi
        detected_max=$(printf '%s' "$detected_max" | tr -d '[:space:]')
        [[ "$detected_max" =~ ^[0-9]+$ ]] || die "Unexpected GPU max clock: $detected_max"
    else
        detected_max=$MAX_CLOCK
    fi

    (( detected_max >= MIN_CLOCK )) || die "Minimum $MIN_CLOCK MHz exceeds GPU maximum $detected_max MHz."
    printf '%s' "$detected_max"
}

cmd_apply() {
    require_root
    load_config
    parse_options "$@"
    validate_settings
    local nvidia max_clock
    nvidia=$(nvidia_bin)
    max_clock=$(resolve_clock_range "$nvidia")
    log "Applying GPU $GPU_SELECTOR graphics clock range: $MIN_CLOCK-$max_clock MHz"
    "$nvidia" -i "$GPU_SELECTOR" -lgc "${MIN_CLOCK},${max_clock}" || \
        die 'NVIDIA rejected the clock range. Check driver support and supported clocks.'
    log 'Clock range applied. HDMI audio behavior must be verified by listening.'
}

cmd_reset() {
    require_root
    load_config
    validate_settings
    local nvidia
    nvidia=$(nvidia_bin)
    log "Restoring default graphics clocks on GPU $GPU_SELECTOR"
    "$nvidia" -i "$GPU_SELECTOR" -rgc
}

write_service() {
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=NVIDIA HDMI audio dropout workaround (graphics clock floor)
Documentation=https://docs.nvidia.com/deploy/nvidia-smi/
After=display-manager.service
ConditionPathExists=$CONFIG_FILE

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=50
ExecStart=/usr/bin/bash $INSTALLED_SCRIPT apply
ExecStop=/usr/bin/bash $INSTALLED_SCRIPT reset

[Install]
WantedBy=graphical.target
EOF
    chmod 0644 "$UNIT_FILE"
}

write_resume_hook() {
    mkdir -p /etc/systemd/system-sleep
    cat > "$RESUME_HOOK" <<EOF
#!/usr/bin/env bash
# Reapply after suspend/resume if the systemd service was already active.
if [[ "\${1:-}" == post ]]; then
    /usr/bin/systemctl --no-block try-restart $SERVICE || true
fi
EOF
    chmod 0755 "$RESUME_HOOK"
}

install_cli() {
    mkdir -p "$BIN_DIR"
    ln -sfn "$INSTALLED_SCRIPT" "$BIN_DIR/$CLI_NAME"
    ln -sfn "$INSTALLED_SCRIPT" "$BIN_DIR/nvidia-audio-fix"
}

remove_cli() {
    rm -f -- "$BIN_DIR/$CLI_NAME" "$BIN_DIR/nvidia-audio-fix"
}

cmd_install() {
    require_root
    require_command systemctl
    require_command nvidia-smi
    load_config
    parse_options "$@"
    validate_settings

    local source_path
    source_path=$(readlink -f -- "${BASH_SOURCE[0]}")
    # Stop any old instance while it still has its old GPU selection.
    # Its ExecStop resets the original GPU before the configuration changes.
    if [[ -f "$UNIT_FILE" ]] && systemctl is-active --quiet "$SERVICE"; then
        systemctl stop "$SERVICE"
    fi
    mkdir -p "$INSTALL_DIR"
    if [[ "$source_path" != "$INSTALLED_SCRIPT" ]]; then
        command install -m 0755 -- "$source_path" "$INSTALLED_SCRIPT"
    fi
    write_config
    write_service
    write_resume_hook
    install_cli
    systemctl daemon-reload
    systemctl enable "$SERVICE"
    systemctl restart "$SERVICE" || die "Service start failed. Check: journalctl -b -u $SERVICE"
    log "Installed; service enabled at boot (minimum: $MIN_CLOCK MHz, maximum: $MAX_CLOCK)."
    log "CLI available: $CLI_NAME (status, monitor, configure, ...)"
    log "After reboot: systemctl status $SERVICE"
}

ensure_installed() {
    [[ -f "$UNIT_FILE" && -f "$INSTALLED_SCRIPT" && -f "$CONFIG_FILE" ]] || \
        die 'Not installed. Use the install command first.'
}

cmd_configure() {
    require_root
    require_command systemctl
    ensure_installed
    load_config
    parse_options "$@"
    validate_settings
    local was_active=0
    if systemctl is-active --quiet "$SERVICE"; then
        was_active=1
        # Stop with the old configuration to reset the previously selected GPU.
        systemctl stop "$SERVICE"
    fi
    write_config
    log "Saved settings: GPU=$GPU_SELECTOR MIN=$MIN_CLOCK MHz MAX=$MAX_CLOCK"
    if (( was_active )); then
        systemctl start "$SERVICE" || die "Could not start service. See: journalctl -b -u $SERVICE"
    else
        log "Service is not active. Run: sudo $INSTALLED_SCRIPT enable"
    fi
}

cmd_enable() {
    require_root
    ensure_installed
    systemctl enable "$SERVICE"
    systemctl restart "$SERVICE"
    log 'Startup enabled and workaround applied.'
}

cmd_disable() {
    require_root
    if [[ -f "$UNIT_FILE" ]]; then
        systemctl disable --now "$SERVICE" || warn 'Could not fully disable/stop service.'
    fi
    # Fallback reset even when the unit was already stopped or failed.
    cmd_reset || warn 'GPU reset failed (perhaps the driver is not loaded).'
    log 'Startup disabled; default clocks requested.'
}

cmd_status() {
    load_config
    printf 'NVIDIA HDMI audio workaround v%s\n' "$VERSION"
    if [[ -f "$CONFIG_FILE" ]]; then
        validate_settings
        printf 'Config: GPU=%s, min=%s MHz, max=%s\n' "$GPU_SELECTOR" "$MIN_CLOCK" "$MAX_CLOCK"
    else
        printf 'Config: not installed (showing defaults)\n'
    fi
    if command -v systemctl >/dev/null 2>&1; then
        printf 'Service enabled: %s\n' "$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"
        printf 'Service active:  %s\n' "$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
    fi
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi -i "$GPU_SELECTOR" \
            --query-gpu=name,pstate,clocks.gr,clocks.mem,power.draw \
            --format=csv 2>/dev/null || warn 'NVIDIA GPU query failed.'
    else
        warn 'nvidia-smi is not installed or not on PATH.'
    fi
}

cmd_monitor() {
    load_config
    validate_settings
    local nvidia
    nvidia=$(nvidia_bin)
    log 'Monitoring GPU status every second; press Ctrl+C to stop.'
    exec "$nvidia" -i "$GPU_SELECTOR" \
        --query-gpu=timestamp,pstate,clocks.gr,clocks.mem,pcie.link.gen.current,power.draw \
        --format=csv -l 1
}

cmd_diagnose() {
    log 'Diagnostics (review output before sharing publicly)'
    if command -v rpm-ostree >/dev/null 2>&1; then
        rpm-ostree status || true
    fi
    printf '\nKernel: '; uname -r
    printf '\n'
    cmd_status
    printf '\nDriver / GPU list:\n'
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=index,uuid,name,driver_version,clocks.max.graphics \
            --format=csv || true
    fi
    printf '\nService logs from current boot:\n'
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -b -u "$SERVICE" --no-pager -n 80 || true
    fi
}

cmd_logs() {
    require_command journalctl
    journalctl -b -u "$SERVICE" --no-pager -n 100
}

cmd_uninstall() {
    require_root
    if [[ -f "$UNIT_FILE" ]]; then
        systemctl disable --now "$SERVICE" || warn 'Failed to stop or disable service.'
    fi
    if [[ -f "$CONFIG_FILE" ]]; then
        cmd_reset || warn 'Could not reset clocks (GPU may be unavailable).'
    fi
    rm -f -- "$UNIT_FILE" "$RESUME_HOOK" "$INSTALLED_SCRIPT" "$CONFIG_FILE"
    remove_cli
    rmdir "$INSTALL_DIR" 2>/dev/null || true
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE" 2>/dev/null || true
    log 'Uninstalled. NVIDIA default graphics clocks requested.'
}

main() {
    local command_name=${1:---help}
    shift || true
    case "$command_name" in
        install)    cmd_install "$@" ;;
        configure)  cmd_configure "$@" ;;
        apply)      cmd_apply "$@" ;;
        reset)      (( $# == 0 )) || die 'reset does not accept options'; cmd_reset ;;
        enable)     (( $# == 0 )) || die 'enable does not accept options'; cmd_enable ;;
        disable)    (( $# == 0 )) || die 'disable does not accept options'; cmd_disable ;;
        status)     (( $# == 0 )) || die 'status does not accept options'; cmd_status ;;
        monitor)    (( $# == 0 )) || die 'monitor does not accept options'; cmd_monitor ;;
        diagnose)   (( $# == 0 )) || die 'diagnose does not accept options'; cmd_diagnose ;;
        logs)       (( $# == 0 )) || die 'logs does not accept options'; cmd_logs ;;
        uninstall)  (( $# == 0 )) || die 'uninstall does not accept options'; cmd_uninstall ;;
        --help|-h|help) usage ;;
        --version|-V) printf '%s\n' "$VERSION" ;;
        *) usage >&2; die "Unknown command: $command_name" ;;
    esac
}

main "$@"
