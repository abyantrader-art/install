#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# 9Hits Viewer v6 - legacy/non-systemd installer
#
# Derived from 9hitste/install v6 before commit a39c7977245e5a0372b0fdfacea6750974892bdf
# (parent: 95a496e8296dfac99a4c1122c4f630b21ffa3d63).
#
# Purpose:
#   Run 9Hits Viewer v6 on Linux hosts without systemd, including notebook/container
#   runtimes that permit the required packages and background processes.
#
# This script does NOT embed credentials. Pass all 9Hits settings as normal arguments.

set -Eeuo pipefail

DEFAULT_DOWNLOAD="https://dl.9hits.com/9hitsv6-linux64.tar.bz2"
INSTALL_DIR="${HOME}/9hits"
RESTART_DELAY=5
DO_INSTALL_DEPS=1
DO_INSTALL_VNC=0
VNC_PW=""
NO_VNC_PW=0
VNC_PORT=5901
XVFB_RESOLUTION=""
CREATE_SWAP=""
XVFB_DISPLAY=":99"
SCREEN_SESSION="9hits"
PERIODIC_RESTART=86400
APP_ARGS=()
ACTION="install"

X11VNC_PID_FILE=""
XVFB_PID_FILE=""
RUNNER_LOG=""

usage() {
  cat <<'USAGE'
Usage:
  bash install.sh --access-key=<32hex> [options forwarded to nhviewer]

Installer options:
  --install-dir=<path>       Install directory (default: $HOME/9hits)
  --install-deps             Install Linux dependencies (default)
  --skip-install-deps        Skip Linux dependency installation
  --install-vnc              Install and start x11vnc mirrored from Xvfb
  --vnc-pw=<password>        VNC password; only the first 8 characters are effective
  --no-vnc-pw                Start VNC without password (not recommended)
  --vnc-port=<port>          VNC port (default: 5901)
  --resolution=<WxHxD|auto>  Xvfb resolution (default: auto)
  --create-swap=<size>       Create temporary /tmp/9hits_swap (for example: 10G)
  --restart-delay=<seconds>  Delay before Viewer restart (default: 5)
  --reset-interval=<value>   Forward to Viewer (example: 6h, 24h)
  --screen-session=<name>    screen session name (default: 9hits)
  --default-dl=<url>         Override Viewer archive URL
  --status                   Print status and logs, then exit
  --stop                     Stop Viewer, Xvfb, VNC, then exit
  --help                     Show this help

All other options are forwarded once to nhviewer during initialization.
Examples include --access-key, --system-session, --ex-proxy-url,
--ex-proxy-sessions, --allow-crypto, --allow-adult, --hide-browser,
and --session-note.
USAGE
}

log()  { printf '[9hits] %s\n' "$*"; }
err()  { printf '[9hits] ERROR: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "$1 requires root. Run this installer as root."; }

parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --install-dir=*) INSTALL_DIR="${arg#*=}" ;;
      --install-deps) DO_INSTALL_DEPS=1 ;;
      --skip-install-deps) DO_INSTALL_DEPS=0 ;;
      --install-vnc) DO_INSTALL_VNC=1 ;;
      --vnc-pw=*) VNC_PW="${arg#*=}" ;;
      --no-vnc-pw) NO_VNC_PW=1 ;;
      --vnc-port=*) VNC_PORT="${arg#*=}" ;;
      --resolution=*) XVFB_RESOLUTION="${arg#*=}" ;;
      --create-swap=*) CREATE_SWAP="${arg#*=}" ;;
      --restart-delay=*) RESTART_DELAY="${arg#*=}" ;;
      --reset-interval=*) APP_ARGS+=("$arg") ;;
      --screen-session=*) SCREEN_SESSION="${arg#*=}" ;;
      --default-dl=*) DEFAULT_DOWNLOAD="${arg#*=}" ;;
      --status) ACTION="status" ;;
      --stop) ACTION="stop" ;;
      --help|-h) usage; exit 0 ;;
      # Managed by this installer. Do not forward duplicate lifecycle flags.
      --exit-on-init|--auto-start|--in-loop|--render-to-terminal) ;;
      *) APP_ARGS+=("$arg") ;;
    esac
  done

  X11VNC_PID_FILE="${INSTALL_DIR}/x11vnc.pid"
  XVFB_PID_FILE="${INSTALL_DIR}/xvfb.pid"
  RUNNER_LOG="${INSTALL_DIR}/viewer.log"
}

check_system() {
  local arch dist version_id major minor ok=0 min_ver=""
  arch="$(uname -m)"
  [ "$arch" = "x86_64" ] || die "Unsupported architecture '$arch'. Only x86_64 is supported."
  [ -f /etc/os-release ] || die "Cannot detect OS version: /etc/os-release is missing."

  dist="$(awk -F= '$1=="ID" {gsub("\"", "", $2); print tolower($2)}' /etc/os-release)"
  version_id="$(awk -F= '$1=="VERSION_ID" {gsub("\"", "", $2); print $2}' /etc/os-release)"
  major="${version_id%%.*}"
  minor="${version_id#*.}"
  [ "$minor" = "$version_id" ] && minor=0

  case "$dist" in
    ubuntu)
      if [ "$major" -gt 20 ] || { [ "$major" -eq 20 ] && [ "$minor" -ge 4 ]; }; then ok=1; fi
      min_ver="20.04"
      ;;
    debian)
      [ "$major" -ge 11 ] && ok=1
      min_ver="11 (Bullseye)"
      ;;
    centos|rhel|rocky|almalinux)
      [ "$major" -ge 9 ] && ok=1
      min_ver="9"
      ;;
    fedora)
      [ "$major" -ge 36 ] && ok=1
      min_ver="36"
      ;;
    *) die "Unsupported distribution '$dist'. Supported: Ubuntu 20.04+, Debian 11+, RHEL-compatible 9+, Fedora 36+." ;;
  esac

  [ "$ok" -eq 1 ] || die "$dist $version_id is too old. Minimum supported version: $min_ver."
  log "System check passed: $dist $version_id ($arch)"
}

detect_dist() {
  if [ -f /etc/os-release ]; then
    awk -F= '$1=="ID" {gsub("\"", "", $2); print tolower($2)}' /etc/os-release
  elif [ -f /etc/redhat-release ]; then
    awk '{print tolower($1)}' /etc/redhat-release
  else
    return 1
  fi
}

install_deps() {
  local dist
  need_root "Dependency installation"
  dist="$(detect_dist)" || die "Cannot detect Linux distribution."
  log "Installing dependencies for $dist..."

  case "$dist" in
    debian|ubuntu)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -q
      apt-get install -y --no-install-recommends \
        ca-certificates wget curl screen unzip acl xvfb bzip2 \
        libcanberra-gtk-module libxss1 libxtst6 libnss3 \
        psmisc procps bc libgtk-3-0 libgbm-dev libatspi2.0-0 \
        libatomic1 x11-utils iproute2 coreutils
      ;;
    centos|rhel|rocky|almalinux|fedora)
      if command -v dnf >/dev/null 2>&1; then
        dnf -y install \
          screen unzip acl libatomic alsa-lib gtk3 libgbm libxkbcommon-x11 \
          cups-libs atk xorg-x11-server-Xvfb xdpyinfo wget bzip2 \
          libXScrnSaver psmisc procps-ng coreutils iproute
      else
        yum -y install \
          screen unzip acl libatomic alsa-lib gtk3 libgbm libxkbcommon-x11 \
          cups-libs atk xorg-x11-server-Xvfb xdpyinfo wget bzip2 \
          libXScrnSaver psmisc procps-ng coreutils iproute
      fi
      ;;
    *) die "Unsupported distribution: $dist" ;;
  esac
}

setup_swap() {
  local size="$1" swap_file="/tmp/9hits_swap"
  need_root "Swap creation"
  log "Creating temporary swap: $size at $swap_file"
  swapoff "$swap_file" 2>/dev/null || true
  rm -f "$swap_file"
  fallocate -l "$size" "$swap_file" || die "Unable to allocate swap file."
  chmod 600 "$swap_file"
  mkswap "$swap_file" >/dev/null
  swapon "$swap_file" || die "Unable to enable swap."
  log "Swap enabled."
}

download_app() {
  local tmp_file="/tmp/nhviewer-linux64.tar.bz2"
  mkdir -p "$INSTALL_DIR"
  log "Downloading Viewer archive..."

  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 20 "$DEFAULT_DOWNLOAD" -o "$tmp_file" || die "Viewer download failed."
  else
    wget -q --show-progress -O "$tmp_file" "$DEFAULT_DOWNLOAD" || die "Viewer download failed."
  fi

  [ -s "$tmp_file" ] || die "Downloaded Viewer archive is empty."
  log "Extracting Viewer to $INSTALL_DIR..."
  tar -xjf "$tmp_file" -C "$INSTALL_DIR" --strip-components=1 || die "Viewer archive extraction failed."
  rm -f "$tmp_file"
  chmod +x "$INSTALL_DIR/nhviewer"
  [ -x "$INSTALL_DIR/nhviewer" ] || die "nhviewer binary was not found after extraction."
}

auto_resolution() {
  local cores mem_mb
  cores="$(nproc 2>/dev/null || echo 1)"
  mem_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
  if [ "$cores" -ge 4 ] && [ "$mem_mb" -ge 4000 ]; then
    printf '2560x1440x24'
  else
    printf '1920x1080x24'
  fi
}

display_number() {
  local d="${XVFB_DISPLAY#:}"
  printf '%s' "${d%%.*}"
}

stop_pid_file() {
  local file="$1" label="$2" pid
  [ -f "$file" ] || return 0
  pid="$(cat "$file" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "Stopping $label (PID $pid)..."
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$file"
}

kill_viewer() {
  # Exact process names only. Do not use `pkill -f may`: it can match the shell.
  pkill -TERM -x nhviewer 2>/dev/null || true
  pkill -TERM -x may 2>/dev/null || true
  sleep 2
  pkill -KILL -x nhviewer 2>/dev/null || true
  pkill -KILL -x may 2>/dev/null || true
}

start_xvfb() {
  local dnum tries=0
  dnum="$(display_number)"

  if xdpyinfo -display "$XVFB_DISPLAY" >/dev/null 2>&1; then
    log "Reusing existing Xvfb display $XVFB_DISPLAY."
    return 0
  fi

  rm -f "/tmp/.X${dnum}-lock" "/tmp/.X11-unix/X${dnum}" 2>/dev/null || true
  log "Starting Xvfb on $XVFB_DISPLAY ($XVFB_RESOLUTION)..."
  nohup Xvfb "$XVFB_DISPLAY" -screen 0 "$XVFB_RESOLUTION" -nolisten tcp \
    >"${INSTALL_DIR}/xvfb.log" 2>&1 &
  echo $! > "$XVFB_PID_FILE"

  until xdpyinfo -display "$XVFB_DISPLAY" >/dev/null 2>&1 || [ "$tries" -ge 20 ]; do
    sleep 0.5
    tries=$((tries + 1))
  done

  xdpyinfo -display "$XVFB_DISPLAY" >/dev/null 2>&1 || {
    tail -n 80 "${INSTALL_DIR}/xvfb.log" 2>/dev/null || true
    die "Xvfb failed to start."
  }
  log "Xvfb is ready on $XVFB_DISPLAY."
}

install_vnc() {
  local dist
  need_root "VNC installation"
  dist="$(detect_dist)" || die "Cannot detect Linux distribution."
  log "Installing x11vnc..."
  case "$dist" in
    debian|ubuntu)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -q
      apt-get install -y --no-install-recommends x11vnc
      ;;
    centos|rhel|rocky|almalinux|fedora)
      if command -v dnf >/dev/null 2>&1; then
        dnf -y install epel-release || true
        dnf -y install x11vnc
      else
        yum -y install epel-release || true
        yum -y install x11vnc
      fi
      ;;
    *) die "Cannot install x11vnc on '$dist'." ;;
  esac
}

gen_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8
}

start_vnc() {
  local auth_opts tries=0
  command -v x11vnc >/dev/null 2>&1 || die "x11vnc is missing. Use --install-vnc."
  stop_pid_file "$X11VNC_PID_FILE" "x11vnc"

  if [ -z "$VNC_PW" ] && [ "$NO_VNC_PW" -eq 0 ]; then
    VNC_PW="$(gen_password)"
    log "Generated VNC password: $VNC_PW"
  fi

  if [ -n "$VNC_PW" ]; then
    if [ "${#VNC_PW}" -gt 8 ]; then
      log "VNC accepts only 8 characters; using the first 8 characters."
      VNC_PW="${VNC_PW:0:8}"
    fi
    mkdir -p "$HOME/.x11vnc"
    x11vnc -storepasswd "$VNC_PW" "$HOME/.x11vnc/passwd" >/dev/null 2>&1
    chmod 600 "$HOME/.x11vnc/passwd"
    auth_opts="-rfbauth $HOME/.x11vnc/passwd"
  else
    auth_opts="-nopw"
    err "VNC starts without a password."
  fi

  log "Starting x11vnc on port $VNC_PORT..."
  # shellcheck disable=SC2086
  nohup x11vnc -display "$XVFB_DISPLAY" -rfbport "$VNC_PORT" \
    -forever -shared -noxdamage -quiet $auth_opts \
    >"${INSTALL_DIR}/x11vnc.log" 2>&1 &
  echo $! > "$X11VNC_PID_FILE"

  until ss -tln 2>/dev/null | grep -q ":${VNC_PORT}" || [ "$tries" -ge 20 ]; do
    sleep 0.5
    tries=$((tries + 1))
  done

  ss -tln 2>/dev/null | grep -q ":${VNC_PORT}" || {
    tail -n 80 "${INSTALL_DIR}/x11vnc.log" 2>/dev/null || true
    die "x11vnc failed to listen on port $VNC_PORT."
  }
  log "x11vnc is ready on port $VNC_PORT."
}

run_init() {
  log "Initializing Viewer settings..."
  kill_viewer
  export DISPLAY="$XVFB_DISPLAY"
  timeout 300 "$INSTALL_DIR/nhviewer" "${APP_ARGS[@]}" --exit-on-init || {
    local rc=$?
    [ "$rc" -eq 124 ] && die "Viewer initialization timed out after 300 seconds."
    die "Viewer initialization failed (exit code $rc)."
  }
  log "Initialization complete."
}

write_runner() {
  cat > "$INSTALL_DIR/runner.sh" <<EOF_RUNNER
#!/usr/bin/env bash
# Generated by the legacy/non-systemd 9Hits installer.
export DISPLAY='$XVFB_DISPLAY'
RESTART_DELAY='$RESTART_DELAY'
PERIODIC_RESTART='$PERIODIC_RESTART'
VIEWER='$INSTALL_DIR/nhviewer'

kill_viewer() {
  pkill -TERM -x nhviewer 2>/dev/null || true
  pkill -TERM -x may 2>/dev/null || true
  sleep 2
  pkill -KILL -x nhviewer 2>/dev/null || true
  pkill -KILL -x may 2>/dev/null || true
}

while true; do
  kill_viewer
  timeout "\$PERIODIC_RESTART" "\$VIEWER" --auto-start --in-loop --render-to-terminal
  rc=\$?
  printf '[%s] nhviewer exited (code %s); restarting in %ss...\\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$rc" "\$RESTART_DELAY"
  sleep "\$RESTART_DELAY"
done
EOF_RUNNER
  chmod +x "$INSTALL_DIR/runner.sh"
}

start_runner() {
  command -v screen >/dev/null 2>&1 || die "screen is missing. Re-run without --skip-install-deps."
  screen -S "$SCREEN_SESSION" -X quit >/dev/null 2>&1 || true
  sleep 1

  log "Starting Viewer in screen session '$SCREEN_SESSION'..."
  screen -L -Logfile "$RUNNER_LOG" -dmS "$SCREEN_SESSION" bash "$INSTALL_DIR/runner.sh"
  sleep 3

  screen -list 2>/dev/null | grep -q "[.]${SCREEN_SESSION}[[:space:]]" || {
    tail -n 100 "$RUNNER_LOG" 2>/dev/null || true
    die "screen session did not stay running."
  }
  log "Viewer runner is active."
}

stop_stack() {
  local dnum
  dnum="$(display_number)"
  screen -S "$SCREEN_SESSION" -X quit >/dev/null 2>&1 || true
  kill_viewer
  stop_pid_file "$X11VNC_PID_FILE" "x11vnc"
  stop_pid_file "$XVFB_PID_FILE" "Xvfb"
  pkill -TERM -f "^Xvfb ${XVFB_DISPLAY}( |$)" 2>/dev/null || true
  rm -f "/tmp/.X${dnum}-lock" "/tmp/.X11-unix/X${dnum}" 2>/dev/null || true
  log "Stopped."
}

print_status() {
  local found=0
  echo "=== 9Hits legacy/non-systemd status ==="
  if screen -list 2>/dev/null | grep -q "[.]${SCREEN_SESSION}[[:space:]]"; then
    echo "screen session : RUNNING ($SCREEN_SESSION)"
    found=1
  else
    echo "screen session : STOPPED ($SCREEN_SESSION)"
  fi
  if xdpyinfo -display "$XVFB_DISPLAY" >/dev/null 2>&1; then
    echo "Xvfb           : RUNNING ($XVFB_DISPLAY)"
    found=1
  else
    echo "Xvfb           : STOPPED ($XVFB_DISPLAY)"
  fi
  if ss -tln 2>/dev/null | grep -q ":${VNC_PORT}"; then
    echo "VNC            : LISTENING (port $VNC_PORT)"
    found=1
  fi
  echo
  echo "=== processes ==="
  ps -eo pid,ppid,stat,etime,cmd | grep -E '[n]hviewer|[X]vfb|[x]11vnc|[s]creen' || true
  echo
  echo "=== latest Viewer log ==="
  tail -n 80 "$RUNNER_LOG" 2>/dev/null || true
  [ "$found" -eq 1 ] || return 1
}

main() {
  parse_args "$@"

  case "$ACTION" in
    status) print_status; exit 0 ;;
    stop) stop_stack; exit 0 ;;
  esac

  check_system

  local has_access_key=0 arg
  for arg in "${APP_ARGS[@]}"; do
    case "$arg" in
      --access-key=????????????????????????????????) has_access_key=1 ;;
    esac
  done
  [ "$has_access_key" -eq 1 ] || die "Missing or invalid --access-key=<32hex>."

  if [ "$DO_INSTALL_DEPS" -eq 1 ]; then
    install_deps
  fi
  if [ -n "$CREATE_SWAP" ]; then
    setup_swap "$CREATE_SWAP"
  fi
  if [ "$DO_INSTALL_VNC" -eq 1 ]; then
    install_vnc
  fi

  download_app
  if [ -z "$XVFB_RESOLUTION" ] || [ "$XVFB_RESOLUTION" = "auto" ]; then
    XVFB_RESOLUTION="$(auto_resolution)"
  fi
  log "Using Xvfb resolution: $XVFB_RESOLUTION"

  stop_stack
  start_xvfb
  if [ "$DO_INSTALL_VNC" -eq 1 ]; then
    start_vnc
  fi
  run_init
  write_runner
  start_runner

  echo
  echo "=== INSTALL COMPLETE ==="
  echo "Screen session : $SCREEN_SESSION"
  echo "Viewer log     : $RUNNER_LOG"
  echo "Status         : bash $0 --install-dir=$INSTALL_DIR --screen-session=$SCREEN_SESSION --status"
  echo "Stop           : bash $0 --install-dir=$INSTALL_DIR --screen-session=$SCREEN_SESSION --stop"
  echo "Attach         : screen -r $SCREEN_SESSION"
  if [ "$DO_INSTALL_VNC" -eq 1 ]; then
    echo "VNC port       : $VNC_PORT"
    [ -n "$VNC_PW" ] && echo "VNC password   : $VNC_PW"
  fi
}

main "$@"
