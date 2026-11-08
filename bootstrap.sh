#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Market Adviser Bot - Host Bootstrap
# Prepares a dedicated Debian/Ubuntu x86_64 host (Hatron Tiny / Intel J1900).
# Inspired by AmirShams-ir/Host-Server; application dependencies are installed
# separately by ./install.sh as an unprivileged application user.
# -----------------------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/market-adviser-bootstrap.log"
BACKUP_DIR="/var/backups/market-adviser-bootstrap/$(date +%Y%m%d-%H%M%S)"
APT_MAIN="/etc/apt/sources.list"
APT_DROPIN="/etc/apt/sources.list.d/market-adviser-fallback.list"
APT_PREF="/etc/apt/preferences.d/99-market-adviser-mirrors"
APT_RETRY="/etc/apt/apt.conf.d/80-market-adviser-retries"
SYSCTL_FILE="/etc/sysctl.d/90-market-adviser.conf"
JOURNAL_DIR="/etc/systemd/journald.conf.d"
ZRAM_CONF="/etc/default/zramswap"

info(){ printf '\033[34m[INFO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[32m[ OK ]\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
die(){ printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || {
  command -v sudo >/dev/null 2>&1 || die "Run as root or install sudo."
  exec sudo --preserve-env=PATH bash "$0" "$@"
}

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'rc=$?; if [[ $rc -ne 0 ]]; then warn "Failed (exit $rc). See $LOG_FILE"; fi' EXIT

[[ -r /etc/os-release ]] || die "Cannot detect operating system."
# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
  debian)
    case "${VERSION_ID:-}" in
      12) CODENAME=bookworm ;;
      13) CODENAME=trixie ;;
      *) die "Supported Debian versions: 12/13 (detected ${VERSION_ID:-unknown})." ;;
    esac
    OS_FAMILY=debian
    ;;
  ubuntu)
    case "${VERSION_ID:-}" in
      22.04) CODENAME=jammy ;;
      24.04) CODENAME=noble ;;
      *) die "Supported Ubuntu versions: 22.04/24.04 (detected ${VERSION_ID:-unknown})." ;;
    esac
    OS_FAMILY=ubuntu
    ;;
  *)
    die "Unsupported OS: ${PRETTY_NAME:-unknown}. Use Debian 12/13 or Ubuntu 22.04/24.04."
    ;;
esac

ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
[[ "$ARCH" == amd64 ]] || die "This bootstrap targets x86_64/amd64 Hatron hardware; detected architecture: ${ARCH:-unknown}."

if [[ -f /etc/armbian-release || "${ID:-}" == armbian ]]; then
  die "Armbian detected. This Intel x86_64 host bootstrap is not intended for Armbian."
fi

RAM_MB="$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
CPU_COUNT="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
ROOT_FS="$(findmnt -n -o FSTYPE / 2>/dev/null || echo unknown)"
ROOT_SOURCE="$(findmnt -n -o SOURCE / 2>/dev/null || echo unknown)"

info "Market Adviser host bootstrap"
info "OS: ${PRETTY_NAME:-unknown} | codename: $CODENAME | arch: $ARCH"
info "CPU threads: $CPU_COUNT | RAM: ${RAM_MB} MiB | root: $ROOT_SOURCE ($ROOT_FS)"
info "Target profile: low-power Intel J1900 / 4 GiB RAM"

mkdir -p "$BACKUP_DIR"
backup_file(){
  local file="$1"
  [[ -e "$file" || -L "$file" ]] || return 0
  mkdir -p "$BACKUP_DIR$(dirname "$file")"
  cp -a "$file" "$BACKUP_DIR$file"
}
backup_file "$APT_MAIN"
backup_file "$APT_DROPIN"
backup_file "$APT_PREF"
backup_file "$APT_RETRY"
backup_file "$SYSCTL_FILE"
backup_file "$ZRAM_CONF"
backup_file "$JOURNAL_DIR/market-adviser.conf"
ok "APT and tuning configuration backups: $BACKUP_DIR"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ---------------------------------------------------------------------------
# APT sources: official distro endpoints are preferred; official CDN and
# regional mirrors are optional lower-priority fallback. Never disable APT
# signature verification and never overwrite Armbian/vendor repositories.
# ---------------------------------------------------------------------------
if [[ "$OS_FAMILY" == debian ]]; then
  COMPONENTS="main contrib non-free non-free-firmware"
  cat > "$APT_MAIN" <<EOF
# Market Adviser: official Debian repositories (preferred)
deb https://deb.debian.org/debian $CODENAME $COMPONENTS
deb https://deb.debian.org/debian $CODENAME-updates $COMPONENTS
deb https://security.debian.org/debian-security $CODENAME-security $COMPONENTS
EOF
  cat > "$APT_DROPIN" <<EOF
# Optional fallbacks. Official Debian endpoints above remain preferred.
deb https://cdn-aws.deb.debian.org/debian $CODENAME $COMPONENTS
deb https://cdn-aws.deb.debian.org/debian $CODENAME-updates $COMPONENTS
deb https://cdn-aws.deb.debian.org/debian-security $CODENAME-security $COMPONENTS
deb https://mirror.cdn.ir/repository/debian $CODENAME $COMPONENTS
deb https://mirror.cdn.ir/repository/debian $CODENAME-updates $COMPONENTS
deb https://mirror.cdn.ir/repository/debian-security $CODENAME-security $COMPONENTS
deb https://repo.iut.ac.ir/debian $CODENAME $COMPONENTS
deb https://repo.iut.ac.ir/debian $CODENAME-updates $COMPONENTS
deb https://mirror.arvancloud.ir/debian $CODENAME $COMPONENTS
deb https://mirror.arvancloud.ir/debian-security $CODENAME-security $COMPONENTS
EOF
  cat > "$APT_PREF" <<'EOF'
Package: *
Pin: origin "deb.debian.org"
Pin-Priority: 700

Package: *
Pin: origin "security.debian.org"
Pin-Priority: 700

Package: *
Pin: origin "cdn-aws.deb.debian.org"
Pin-Priority: 600

Package: *
Pin: origin "mirror.cdn.ir"
Pin-Priority: 400

Package: *
Pin: origin "repo.iut.ac.ir"
Pin-Priority: 350

Package: *
Pin: origin "mirror.arvancloud.ir"
Pin-Priority: 300
EOF
else
  COMPONENTS="main restricted universe multiverse"
  cat > "$APT_MAIN" <<EOF
# Market Adviser: official Ubuntu repositories (preferred)
deb https://archive.ubuntu.com/ubuntu $CODENAME $COMPONENTS
deb https://archive.ubuntu.com/ubuntu $CODENAME-updates $COMPONENTS
deb https://archive.ubuntu.com/ubuntu $CODENAME-backports $COMPONENTS
deb https://security.ubuntu.com/ubuntu $CODENAME-security $COMPONENTS
EOF
  cat > "$APT_DROPIN" <<EOF
# Optional fallbacks. Official Ubuntu endpoints above remain preferred.
deb https://ubuntu-archive.trafficmanager.net/ubuntu $CODENAME $COMPONENTS
deb https://ubuntu-archive.trafficmanager.net/ubuntu $CODENAME-updates $COMPONENTS
deb https://ubuntu-archive.trafficmanager.net/ubuntu $CODENAME-backports $COMPONENTS
deb https://mirror.cdn.ir/ubuntu $CODENAME $COMPONENTS
deb https://mirror.cdn.ir/ubuntu $CODENAME-updates $COMPONENTS
deb https://mirror.cdn.ir/ubuntu $CODENAME-security $COMPONENTS
deb https://repo.iut.ac.ir/ubuntu $CODENAME $COMPONENTS
deb https://repo.iut.ac.ir/ubuntu $CODENAME-updates $COMPONENTS
deb https://mirror.arvancloud.ir/ubuntu $CODENAME $COMPONENTS
EOF
  cat > "$APT_PREF" <<'EOF'
Package: *
Pin: origin "archive.ubuntu.com"
Pin-Priority: 700

Package: *
Pin: origin "security.ubuntu.com"
Pin-Priority: 700

Package: *
Pin: origin "ubuntu-archive.trafficmanager.net"
Pin-Priority: 600

Package: *
Pin: origin "mirror.cdn.ir"
Pin-Priority: 400

Package: *
Pin: origin "repo.iut.ac.ir"
Pin-Priority: 350

Package: *
Pin: origin "mirror.arvancloud.ir"
Pin-Priority: 300
EOF
fi

cat > "$APT_RETRY" <<'EOF'
Acquire::Retries "3";
Acquire::http::Timeout "20";
Acquire::https::Timeout "20";
Dpkg::Use-Pty "0";
EOF

ok "APT sources configured: official repositories preferred, fallback mirrors lower priority."

# ---------------------------------------------------------------------------
# DNS: configure only when systemd-resolved is already the active resolver.
# Do not replace /etc/resolv.conf, disable a network manager, or hard-code
# interface addresses. NetworkManager/ifupdown configurations stay untouched.
# ---------------------------------------------------------------------------
if command -v resolvectl >/dev/null 2>&1 &&
   systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  mkdir -p /etc/systemd/resolved.conf.d
  backup_file /etc/systemd/resolved.conf.d/market-adviser.conf
  cat > /etc/systemd/resolved.conf.d/market-adviser.conf <<'EOF'
[Resolve]
DNS=1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4
FallbackDNS=9.9.9.9 149.112.112.112
DNSSEC=allow-downgrade
Cache=yes
EOF
  systemctl restart systemd-resolved
  ok "DNS configured through existing systemd-resolved."
else
  warn "systemd-resolved is not the active resolver; preserving current DNS/network manager configuration."
  warn "No resolv.conf replacement or local DNS daemon will be installed."
fi

# Validate basic network connectivity before updating package indexes.
network_ok=false
for host in deb.debian.org archive.ubuntu.com github.com; do
  if getent ahosts "$host" >/dev/null 2>&1; then network_ok=true; break; fi
done
$network_ok || die "DNS/network connectivity check failed. Fix network access and rerun."

# ---------------------------------------------------------------------------
# Update base system and install tools required by the application's installer.
# ---------------------------------------------------------------------------
info "Refreshing APT indexes and upgrading installed packages..."
apt-get update
apt-get -y upgrade
apt-get install -y --no-install-recommends \
  ca-certificates curl wget git gnupg lsb-release \
  build-essential pkg-config \
  python3 python3-venv python3-pip python3-dev \
  libopenblas0-pthread libgfortran5 \
  sqlite3 libsqlite3-0 \
  chrony vnstat ethtool irqbalance \
  unattended-upgrades needrestart
ok "Base system updated and prerequisites installed."

# ---------------------------------------------------------------------------
# Time synchronization: keep local timezone; enable chrony only if available.
# ---------------------------------------------------------------------------
if systemctl list-unit-files chrony.service >/dev/null 2>&1; then
  systemctl enable --now chrony || warn "chrony could not be started; inspect timedatectl."
fi

# ---------------------------------------------------------------------------
# Memory profile for 4 GiB machine:
# - Add a modest 2 GiB swap only when the system has no active swap.
# - Do not add zram on top of an already configured zram/swap arrangement.
# - swappiness is moderate; no OOM killer daemon is installed.
# ---------------------------------------------------------------------------
if ! swapon --noheadings --show 2>/dev/null | grep -q .; then
  if [[ ! -e /swapfile ]]; then
    info "Creating a 2 GiB swapfile (no active swap was found)..."
    if fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none; then
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null
      swapon /swapfile
      grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab ||
        printf '/swapfile none swap sw,pri=10 0 0\n' >> /etc/fstab
      ok "2 GiB swapfile enabled."
    else
      rm -f /swapfile
      warn "Could not create swapfile; continuing without it."
    fi
  else
    warn "/swapfile already exists but is not active; leaving it untouched."
  fi
else
  ok "Existing swap detected; no additional swap was created."
fi

SWAPPINESS=20
cat > "$SYSCTL_FILE" <<EOF
# Market Adviser - conservative settings for Intel J1900 / 4 GiB RAM
vm.swappiness=$SWAPPINESS
vm.vfs_cache_pressure=100
vm.dirty_background_ratio=5
vm.dirty_ratio=15
vm.overcommit_memory=0
fs.file-max=131072

# Moderate TCP defaults; avoid oversized hosting-server socket buffers.
net.core.default_qdisc=fq
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.ip_local_port_range=10240 65535
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
EOF

# Enable BBR only if the running kernel reports support.
modprobe tcp_bbr 2>/dev/null || true
if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
  cat >> "$SYSCTL_FILE" <<'EOF'
net.ipv4.tcp_congestion_control=bbr
EOF
  ok "TCP BBR is supported and enabled."
else
  warn "TCP BBR is not available on the running kernel; using kernel default congestion control."
fi

sysctl --system >/dev/null
ok "Conservative kernel/network tuning applied."

# ---------------------------------------------------------------------------
# CPU: let the kernel select the supported governor; do not force performance.
# irqbalance helps distribute device interrupts on multi-core systems.
# ---------------------------------------------------------------------------
if command -v cpupower >/dev/null 2>&1; then
  cpupower frequency-info >/dev/null 2>&1 || true
fi
if systemctl list-unit-files irqbalance.service >/dev/null 2>&1; then
  systemctl enable --now irqbalance || warn "irqbalance could not be enabled."
fi

# ---------------------------------------------------------------------------
# Journald size cap and unattended security updates.
# ---------------------------------------------------------------------------
if systemctl list-unit-files systemd-journald.service >/dev/null 2>&1; then
  mkdir -p "$JOURNAL_DIR"
  cat > "$JOURNAL_DIR/market-adviser.conf" <<'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=100M
MaxRetentionSec=1month
EOF
  systemctl restart systemd-journald || warn "Could not restart journald."
fi

if command -v dpkg-reconfigure >/dev/null 2>&1; then
  dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
fi

# Install zram-tools only if no zram device is present and RAM <= 4 GiB.
if [[ "$RAM_MB" -le 4096 ]] &&
   ! lsblk -o NAME 2>/dev/null | grep -q '^zram' &&
   ! grep -qE '^[[:space:]]*zram' /proc/swaps 2>/dev/null; then
  apt-get install -y --no-install-recommends zram-tools || warn "zram-tools installation skipped."
  if [[ -f "$ZRAM_CONF" ]]; then
    cat > "$ZRAM_CONF" <<'EOF'
# Market Adviser: modest compressed-memory reserve for 4 GiB hosts
ALGO=zstd
PERCENT=25
PRIORITY=100
EOF
    systemctl enable --now zramswap.service 2>/dev/null || warn "zramswap service unavailable; swapfile remains available."
  fi
fi

# ---------------------------------------------------------------------------
# CPU/memory/storage diagnostics; no partition changes or disk trimming.
# ---------------------------------------------------------------------------
info "Host diagnostics:"
lscpu 2>/dev/null | grep -E 'Model name|CPU\(s\)|Architecture' | head -n 5 || true
free -h
df -h /
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null || true

# APT cache cleanup only; preserve downloaded package configuration.
apt-get autoremove -y
apt-get autoclean -y

ok "Market Adviser host bootstrap completed."
info "Log: $LOG_FILE"
info "Backup: $BACKUP_DIR"
info "Next: clone the repository as the normal application user and run ./install.sh."
info "After installation, set up systemd timers with scripts/install-timers.sh (review APP_DIR/user first)."
info "A reboot is recommended if the kernel or core system libraries were upgraded."
