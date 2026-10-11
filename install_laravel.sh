#!/usr/bin/env bash
#
#   WemX v3 Installer
#   ─────────────────
#   Installs WemX together with everything it needs: PHP, Composer, a web
#   server (Nginx or Apache), a database (MariaDB or PostgreSQL), a cron
#   scheduler, a queue worker and an optional free SSL certificate.
#
#   Usage:
#     bash <(curl -s https://sh.wemx.net/install.sh)
#     bash <(curl -s https://sh.wemx.net/install.sh) --help
#
#   Supported systems:
#     Ubuntu 22.04 / 24.04 (and newer)
#     Debian 11 / 12 / 13
#     RHEL, Rocky Linux, AlmaLinux, Oracle Linux, CentOS Stream 8 / 9 / 10
#     Fedora 40+
#
#   Docs: https://v3.wemx.net/docs
#

set -uo pipefail

# ════════════════════════════════════════════════════════════════════════════
#  Settings
# ════════════════════════════════════════════════════════════════════════════

readonly INSTALLER_VERSION="3.0.0"
readonly GITHUB_REPO="wemxnet/wemx"
readonly MIN_PHP="8.3"
readonly DEFAULT_PHP="8.4"
readonly DOCS_URL="https://v3.wemx.net/docs"
readonly LICENSE_URL="https://app.wemx.net"
readonly LOG_FILE="/var/log/wemx-install.log"
readonly INFO_FILE="/root/wemx-install-info.txt"

# Defaults (can be overridden with flags, see --help)
DOMAIN=""
INSTALL_DIR="/var/www/wemx"
WEBSERVER=""          # nginx | apache
DATABASE=""           # mysql | pgsql | none
SSL=""                # yes | no
SSL_EMAIL=""
PHP_WANTED=""
WEMX_VERSION=""       # release tag; empty = latest
ASSUME_YES=false
FORCE=false
USE_COLOR=true
ANIMATE=true

# ════════════════════════════════════════════════════════════════════════════
#  Terminal UI
# ════════════════════════════════════════════════════════════════════════════

setup_ui() {
    if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" && $USE_COLOR == true ]]; then
        RESET=$'\033[0m'  BOLD=$'\033[1m'  DIM=$'\033[2m'
        RED=$'\033[38;5;203m'    GREEN=$'\033[38;5;114m'  YELLOW=$'\033[38;5;221m'
        BLUE=$'\033[38;5;75m'    ACCENT=$'\033[38;5;141m' ACCENT2=$'\033[38;5;117m'
        GREY=$'\033[38;5;244m'   WHITE=$'\033[38;5;255m'
        GRADIENT=($'\033[38;5;93m' $'\033[38;5;99m' $'\033[38;5;105m' $'\033[38;5;111m' $'\033[38;5;117m' $'\033[38;5;123m')
    else
        RESET="" BOLD="" DIM="" RED="" GREEN="" YELLOW="" BLUE="" ACCENT="" ACCENT2="" GREY="" WHITE=""
        GRADIENT=("" "" "" "" "" "")
        ANIMATE=false
    fi
    [[ -t 1 ]] || ANIMATE=false
    SPINNER=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    BAR_WIDTH=46
}

INTERACTIVE=true
TTY=/dev/tty
setup_tty() {
    if $ASSUME_YES || ! { true </dev/tty; } 2>/dev/null; then
        INTERACTIVE=false
    fi
}

hide_cursor() { [[ -t 1 ]] && printf '\033[?25l'; return 0; }
show_cursor() { [[ -t 1 ]] && printf '\033[?25h'; return 0; }

log() { printf '[%(%F %T)T] %s\n' -1 "$*" >>"$LOG_FILE" 2>/dev/null; return 0; }

WARNINGS=()
ok()    { printf '  %s✔%s %s\n' "$GREEN" "$RESET" "$*"; log "OK    $*"; }
info()  { printf '  %s●%s %s\n' "$BLUE" "$RESET" "$*"; log "INFO  $*"; }
warn()  { printf '  %s▲%s %s\n' "$YELLOW" "$RESET" "$*"; log "WARN  $*"; WARNINGS+=("$*"); }
fail()  { printf '  %s✖%s %s\n' "$RED" "$RESET" "$*"; log "ERROR $*"; }
skip()  { printf '  %s○%s %s%s%s\n' "$GREY" "$RESET" "$GREY" "$*" "$RESET"; log "SKIP  $*"; }
note()  { printf '    %s%s%s\n' "$GREY" "$*" "$RESET"; }

die() {
    show_cursor
    echo
    fail "${BOLD}$*${RESET}"
    printf '\n    %sFull log:%s %s\n' "$GREY" "$RESET" "$LOG_FILE"
    printf '    %sNeed help?%s %s\n\n' "$GREY" "$RESET" "$DOCS_URL"
    exit 1
}

repeat() { local s="" i; for ((i = 0; i < $2; i++)); do s+="$1"; done; printf '%s' "$s"; }

fmt_duration() {
    local s=$1
    if ((s >= 60)); then printf '%dm %02ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi
}

typewrite() { # color text [delay]
    local color=$1 text=$2 delay=${3:-0.012} i
    printf '%s' "$color"
    if $ANIMATE; then
        for ((i = 0; i < ${#text}; i++)); do printf '%s' "${text:i:1}"; sleep "$delay"; done
    else
        printf '%s' "$text"
    fi
    printf '%s\n' "$RESET"
}

banner() {
    local -a logo=(
        '██╗    ██╗███████╗███╗   ███╗██╗  ██╗'
        '██║    ██║██╔════╝████╗ ████║╚██╗██╔╝'
        '██║ █╗ ██║█████╗  ██╔████╔██║ ╚███╔╝ '
        '██║███╗██║██╔══╝  ██║╚██╔╝██║ ██╔██╗ '
        '╚███╔███╔╝███████╗██║ ╚═╝ ██║██╔╝ ██╗'
        ' ╚══╝╚══╝ ╚══════╝╚═╝     ╚═╝╚═╝  ╚═╝'
    )
    local i
    [[ -t 1 ]] && clear
    echo
    hide_cursor
    for i in "${!logo[@]}"; do
        printf '    %s%s%s\n' "${GRADIENT[i]}" "${logo[i]}" "$RESET"
        $ANIMATE && sleep 0.06
    done
    echo
    typewrite "$WHITE$BOLD" "    WemX v3 Installer" 0.02
    typewrite "$GREY" "    Installer ${INSTALLER_VERSION}  ·  ${DOCS_URL}" 0.006
    show_cursor
}

# Section header with an animated, gradient-filled overall progress bar.
STEP=0
STEP_TOTAL=11
LAST_PCT=0
draw_bar() {
    local pct=$1 filled i idx bar=""
    filled=$((pct * BAR_WIDTH / 100))
    for ((i = 0; i < filled; i++)); do
        idx=$((i * ${#GRADIENT[@]} / BAR_WIDTH))
        bar+="${GRADIENT[idx]}━"
    done
    printf '\r  %s%s%s%s %s%3d%%%s' "$bar" "$GREY" "$(repeat '─' $((BAR_WIDTH - filled)))" "$RESET" "$BOLD" "$pct" "$RESET"
}

progress_to() {
    local target=$1 p
    if $ANIMATE; then
        hide_cursor
        for ((p = LAST_PCT; p <= target; p += 2)); do draw_bar "$p"; sleep 0.012; done
        show_cursor
    fi
    draw_bar "$target"
    printf '\n'
    LAST_PCT=$target
}

step() {
    STEP=$((STEP + 1))
    echo
    printf '  %s%s%02d/%02d%s  %s%s%s\n' "$ACCENT" "$BOLD" "$STEP" "$STEP_TOTAL" "$RESET" "$BOLD$WHITE" "$1" "$RESET"
    progress_to $(((STEP - 1) * 100 / STEP_TOTAL))
    log "──── STEP $STEP/$STEP_TOTAL: $1"
}

# Run a command (or shell function) in the background with a spinner.
#   task  "message" cmd args...   → aborts the installer if the command fails
#   try   "message" cmd args...   → only warns if the command fails
SPIN_PID=""
_run_spinner() {
    local fatal=$1 msg=$2
    shift 2
    local start=$SECONDS i=0 rc elapsed log_start
    log "RUN   $msg :: $*"
    log_start=$(($(wc -l <"$LOG_FILE" 2>/dev/null || echo 0) + 1))

    ("$@") </dev/null >>"$LOG_FILE" 2>&1 &
    SPIN_PID=$!

    if $ANIMATE; then
        hide_cursor
        while kill -0 "$SPIN_PID" 2>/dev/null; do
            elapsed=$((SECONDS - start))
            printf '\r  %s%s%s %s %s%s%s\033[K' \
                "${GRADIENT[(i / 3) % ${#GRADIENT[@]}]}" "${SPINNER[i % ${#SPINNER[@]}]}" "$RESET" \
                "$msg" "$GREY" "$( ((elapsed > 0)) && fmt_duration "$elapsed")" "$RESET"
            i=$((i + 1))
            sleep 0.08
        done
        show_cursor
    else
        printf '  %s…%s %s\n' "$BLUE" "$RESET" "$msg"
    fi

    wait "$SPIN_PID"
    rc=$?
    SPIN_PID=""
    elapsed=$((SECONDS - start))
    $ANIMATE && printf '\r\033[K'

    if ((rc == 0)); then
        printf '  %s✔%s %s %s%s%s\n' "$GREEN" "$RESET" "$msg" "$GREY" "$( ((elapsed > 1)) && fmt_duration "$elapsed")" "$RESET"
        log "OK    $msg ($elapsed s)"
        return 0
    fi

    if [[ $fatal == true ]]; then
        printf '  %s✖%s %s\n\n' "$RED" "$RESET" "$msg"
        printf '    %s╭─ output ─────────────────────────────────────────%s\n' "$GREY" "$RESET"
        tail -n +"$log_start" "$LOG_FILE" | tail -n 15 | sed "s/^/    ${GREY}│${RESET} /"
        printf '    %s╰──────────────────────────────────────────────────%s\n' "$GREY" "$RESET"
        die "Step failed: $msg (exit code $rc)"
    fi
    printf '  %s▲%s %s %s(failed, continuing)%s\n' "$YELLOW" "$RESET" "$msg" "$GREY" "$RESET"
    WARNINGS+=("$msg failed — see $LOG_FILE")
    log "WARN  $msg failed with exit code $rc"
    return "$rc"
}
task() { _run_spinner true "$@"; }
try()  { _run_spinner false "$@"; }

# ── Prompts ────────────────────────────────────────────────────────────────

# ask VAR "Question" "default" [validator] [error message]
ask() {
    local __var=$1 q=$2 def=$3 validator=${4:-} err=${5:-That value is not valid.} ans had_err=false
    if [[ $INTERACTIVE != true ]]; then printf -v "$__var" '%s' "$def"; return 0; fi
    while true; do
        printf '  %s?%s %s%s%s' "$ACCENT" "$RESET" "$BOLD" "$q" "$RESET"
        [[ -n $def ]] && printf ' %s(%s)%s' "$GREY" "$def" "$RESET"
        printf ' %s›%s ' "$ACCENT" "$RESET"
        IFS= read -r ans <"$TTY"
        ans="${ans:-$def}"
        ans="${ans#"${ans%%[![:space:]]*}"}"; ans="${ans%"${ans##*[![:space:]]}"}"
        if [[ -n $validator ]] && ! "$validator" "$ans"; then
            $had_err && printf '\033[1A\r\033[K'
            printf '\033[1A\r\033[K    %s✖ %s%s\n' "$RED" "$err" "$RESET"
            had_err=true
            continue
        fi
        break
    done
    $had_err && printf '\033[1A\r\033[K'
    printf '\033[1A\r\033[K  %s✔%s %s %s·%s %s%s%s\n' "$GREEN" "$RESET" "$q" "$GREY" "$RESET" "$ACCENT2" "${ans:-—}" "$RESET"
    printf -v "$__var" '%s' "$ans"
}

# choose VAR "Question" default_index "value|Label|hint" ...
choose() {
    local __var=$1 q=$2 sel=$3
    shift 3
    local -a opts=("$@")
    local n=${#opts[@]} i key rest val label hint
    if [[ $INTERACTIVE != true ]]; then printf -v "$__var" '%s' "${opts[sel]%%|*}"; return 0; fi

    if [[ ! -t 1 ]]; then # plain numbered fallback
        printf '  ? %s\n' "$q"
        for i in "${!opts[@]}"; do IFS='|' read -r val label hint <<<"${opts[i]}"; printf '    %d) %s %s\n' $((i + 1)) "$label" "$hint"; done
        read -rp "    Choice [$((sel + 1))]: " key <"$TTY"
        [[ $key =~ ^[0-9]+$ ]] && ((key >= 1 && key <= n)) && sel=$((key - 1))
        printf -v "$__var" '%s' "${opts[sel]%%|*}"
        return 0
    fi

    printf '  %s?%s %s%s%s %s↑/↓ and Enter%s\n' "$ACCENT" "$RESET" "$BOLD" "$q" "$RESET" "$GREY" "$RESET"
    hide_cursor
    local first=true
    while true; do
        $first || printf '\033[%dA' "$n"
        first=false
        for i in "${!opts[@]}"; do
            IFS='|' read -r val label hint <<<"${opts[i]}"
            if ((i == sel)); then
                printf '\r\033[K    %s❯ %s%s%s' "$ACCENT" "$BOLD" "$label" "$RESET"
            else
                printf '\r\033[K      %s' "$label"
            fi
            [[ -n $hint ]] && printf '  %s%s%s' "$GREY" "$hint" "$RESET"
            printf '\n'
        done
        IFS= read -rsn1 key <"$TTY"
        if [[ $key == $'\033' ]]; then
            read -rsn2 -t 0.05 rest <"$TTY"
            key+="$rest"
        fi
        case "$key" in
            $'\033[A' | k) sel=$(((sel - 1 + n) % n)) ;;
            $'\033[B' | j) sel=$(((sel + 1) % n)) ;;
            [1-9]) ((key <= n)) && sel=$((key - 1)) ;;
            '') break ;;
        esac
    done
    printf '\033[%dA' $((n + 1))
    for ((i = 0; i <= n; i++)); do printf '\r\033[K\n'; done
    printf '\033[%dA' $((n + 1))
    IFS='|' read -r val label hint <<<"${opts[sel]}"
    printf '  %s✔%s %s %s·%s %s%s%s\n' "$GREEN" "$RESET" "$q" "$GREY" "$RESET" "$ACCENT2" "$label" "$RESET"
    show_cursor
    printf -v "$__var" '%s' "$val"
}

# confirm "Question" [Y|N]   → returns 0 for yes
confirm() {
    local q=$1 def=${2:-Y} ans hint
    if [[ $INTERACTIVE != true ]]; then [[ $def == Y ]]; return; fi
    [[ $def == Y ]] && hint="Y/n" || hint="y/N"
    printf '  %s?%s %s%s%s %s(%s)%s %s›%s ' "$ACCENT" "$RESET" "$BOLD" "$q" "$RESET" "$GREY" "$hint" "$RESET" "$ACCENT" "$RESET"
    IFS= read -r ans <"$TTY"
    ans=${ans:-$def}
    printf '\033[1A\r\033[K'
    if [[ $ans =~ ^[Yy] ]]; then
        printf '  %s✔%s %s %s·%s %sYes%s\n' "$GREEN" "$RESET" "$q" "$GREY" "$RESET" "$ACCENT2" "$RESET"
        return 0
    fi
    printf '  %s✔%s %s %s·%s %sNo%s\n' "$GREEN" "$RESET" "$q" "$GREY" "$RESET" "$ACCENT2" "$RESET"
    return 1
}

# ════════════════════════════════════════════════════════════════════════════
#  Helpers
# ════════════════════════════════════════════════════════════════════════════

have() { command -v "$1" >/dev/null 2>&1; }

version_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]; }

php_ver_of() { "$1" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null; }

random_string() { tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "${1:-24}"; }

is_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

valid_domain() {
    local d=$1
    is_ipv4 "$d" && return 0
    [[ $d == localhost ]] && return 0
    [[ $d =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

valid_dir() {
    local d=$1
    [[ $d == /* ]] || return 1
    case "${d%/}" in
        "" | /bin | /boot | /dev | /etc | /home | /lib | /lib64 | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var | /var/www) return 1 ;;
    esac
    return 0
}

valid_email() { [[ -z $1 || $1 =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }

normalize_domain() {
    local d=$1
    d=${d#http://}; d=${d#https://}; d=${d%%/*}; d=${d%%:*}
    printf '%s' "${d,,}"
}

svc_enable() { # start a service now and on boot
    if $HAS_SYSTEMD; then
        systemctl enable "$1" && systemctl restart "$1"
    elif have rc-service; then
        rc-update add "$1" default; rc-service "$1" restart
    else
        service "$1" restart
    fi
}

svc_reload() {
    if $HAS_SYSTEMD; then systemctl reload-or-restart "$1"; else service "$1" reload || service "$1" restart; fi
}

svc_active() {
    if $HAS_SYSTEMD; then systemctl is-active --quiet "$1"; else service "$1" status >/dev/null 2>&1; fi
}

# ── Package management ─────────────────────────────────────────────────────

apt_get() {
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -y -q \
        -o DPkg::Lock::Timeout=600 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

pkg_update() {
    case $PKG in
        apt) apt_get update ;;
        dnf) dnf -y makecache ;;
    esac
}

pkg_install() {
    case $PKG in
        apt) apt_get install "$@" ;;
        dnf) dnf -y install "$@" ;;
    esac
}

pkg_installed() {
    case $PKG in
        apt) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
        dnf) rpm -q "$1" >/dev/null 2>&1 ;;
    esac
}

# Print which of the given packages can be installed from the enabled repos.
pkg_available() {
    case $PKG in
        apt)
            apt-cache policy "$@" 2>/dev/null | awk '
                /^[^ ].*:$/          { name = substr($0, 1, length($0) - 1) }
                /^  Candidate:/ && $2 != "(none)" { print name }'
            ;;
        dnf)
            dnf -q repoquery --qf '%{name}\n' "$@" 2>/dev/null | sed '/^$/d' | sort -u
            ;;
    esac
}

# ensure_packages "Label" pkg... → installs only what is missing
ensure_packages() {
    local label=$1 p
    shift
    local -a missing=()
    for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
    if ((${#missing[@]} == 0)); then
        ok "$label ${GREY}already installed${RESET}"
        return 0
    fi
    task "Installing $label ${GREY}(${#missing[@]} package$( ((${#missing[@]} > 1)) && echo s))${RESET}" pkg_install "${missing[@]}"
}

# ════════════════════════════════════════════════════════════════════════════
#  Detection
# ════════════════════════════════════════════════════════════════════════════

detect_os() {
    [[ -r /etc/os-release ]] || die "Cannot detect your operating system (/etc/os-release is missing)."
    eval "$(
        . /etc/os-release
        printf 'OS_ID=%q OS_VERSION=%q OS_NAME=%q OS_CODENAME=%q OS_LIKE=%q OS_UBUNTU_CODENAME=%q\n' \
            "${ID:-unknown}" "${VERSION_ID:-}" "${PRETTY_NAME:-${ID:-unknown}}" "${VERSION_CODENAME:-}" "${ID_LIKE:-}" "${UBUNTU_CODENAME:-}"
    )"
    OS_MAJOR=${OS_VERSION%%.*}
    [[ $OS_MAJOR =~ ^[0-9]+$ ]] || OS_MAJOR=0
    OS_SUPPORTED=false

    case $OS_ID in
        ubuntu) FAMILY=debian; ((OS_MAJOR >= 22)) && OS_SUPPORTED=true ;;
        debian) FAMILY=debian; ((OS_MAJOR >= 11)) && OS_SUPPORTED=true ;;
        rhel | rocky | almalinux | centos | ol) FAMILY=rhel; ((OS_MAJOR >= 8)) && OS_SUPPORTED=true ;;
        fedora) FAMILY=fedora; ((OS_MAJOR >= 40)) && OS_SUPPORTED=true ;;
        *)
            case " $OS_LIKE " in
                *" ubuntu "* | *" debian "*) FAMILY=debian ;;
                *" rhel "* | *" centos "* | *" fedora "*) FAMILY=rhel ;;
                *) die "Unsupported operating system: $OS_NAME. Supported: Ubuntu, Debian, RHEL/Rocky/Alma/Oracle/CentOS Stream, Fedora." ;;
            esac
            ;;
    esac

    if [[ $FAMILY == debian ]]; then PKG=apt; else PKG=dnf; fi
    have "${PKG/apt/apt-get}" || die "Package manager '$PKG' was not found on this system."

    ARCH=$(uname -m)
    HAS_SYSTEMD=false
    [[ -d /run/systemd/system ]] && HAS_SYSTEMD=true

    SELINUX=false
    if have getenforce && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then SELINUX=true; fi
}

detect_resources() {
    MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    local probe=$INSTALL_DIR
    while [[ ! -d $probe && $probe != / ]]; do probe=$(dirname "$probe"); done
    DISK_MB=$(df -Pm "$probe" 2>/dev/null | awk 'NR==2 {print $4}')
    DISK_MB=${DISK_MB:-0}
    CPUS=$(nproc 2>/dev/null || echo 1)
}

detect_public_ip() {
    PUBLIC_IP=""
    if have curl; then
        PUBLIC_IP=$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null ||
            curl -fsS4 --max-time 5 https://ifconfig.me 2>/dev/null || true)
    fi
    is_ipv4 "$PUBLIC_IP" || PUBLIC_IP=""
    if [[ -z $PUBLIC_IP ]]; then
        PUBLIC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1)
    fi
}

# Find an installed PHP >= MIN_PHP (prefers the newest).
detect_php() {
    PHP_FOUND_VER=""
    PHP_FOUND_BIN=""
    local v bin cand
    for v in 8.5 8.4 8.3; do
        if [[ -x /usr/bin/php$v ]]; then PHP_FOUND_VER=$v; PHP_FOUND_BIN=/usr/bin/php$v; return; fi
    done
    if have php; then
        bin=$(command -v php)
        cand=$(php_ver_of "$bin")
        PHP_FOUND_VER=$cand
        PHP_FOUND_BIN=$bin
    fi
}

detect_components() {
    detect_php
    HAS_COMPOSER=false;  { have composer || [[ -x /usr/local/bin/composer ]]; } && HAS_COMPOSER=true
    HAS_NGINX=false;     have nginx && HAS_NGINX=true
    HAS_APACHE=false;    { have apache2 || have httpd || [[ -x /usr/sbin/apache2 || -x /usr/sbin/httpd ]]; } && HAS_APACHE=true
    HAS_MYSQL=false;     { have mariadbd || have mysqld || [[ -x /usr/sbin/mariadbd || -x /usr/sbin/mysqld ]]; } && HAS_MYSQL=true
    HAS_PGSQL=false;     { have postgres || compgen -G '/usr/lib/postgresql/*/bin/postgres' >/dev/null; } && HAS_PGSQL=true
    HAS_CERTBOT=false;   have certbot && HAS_CERTBOT=true
}

# Which programs listen on a TCP port (names only)
port_owners() {
    have ss || return 0
    ss -H -ltnp "sport = :$1" 2>/dev/null | grep -o '(("[^"]*"' | tr -d '("' | sort -u | tr '\n' ' '
}

component_row() { # name status detail
    local name=$1 state=$2 detail=$3 icon color
    case $state in
        ok)      icon="✔"; color=$GREEN ;;
        missing) icon="○"; color=$GREY ;;
        old)     icon="▲"; color=$YELLOW ;;
        *)       icon="✖"; color=$RED ;;
    esac
    printf '    %s%s%s  %-16s %s%s%s\n' "$color" "$icon" "$RESET" "$name" "$GREY" "$detail" "$RESET"
}

show_system_report() {
    local v
    echo
    printf '  %s%sSystem%s\n' "$BOLD" "$WHITE" "$RESET"
    printf '    %-19s %s\n' "OS" "$OS_NAME"
    printf '    %-19s %s\n' "Architecture" "$ARCH"
    printf '    %-19s %s\n' "CPU / Memory" "$CPUS cores · $MEM_MB MB RAM"
    printf '    %-19s %s\n' "Free disk" "$((DISK_MB / 1024)) GB"
    printf '    %-19s %s\n' "Public IP" "${PUBLIC_IP:-unknown}"
    $SELINUX && printf '    %-19s %s\n' "SELinux" "enforcing (will be configured)"
    echo
    printf '  %s%sInstalled components%s\n' "$BOLD" "$WHITE" "$RESET"

    if [[ -n $PHP_FOUND_VER ]] && version_ge "$PHP_FOUND_VER" "$MIN_PHP"; then
        component_row "PHP" ok "$PHP_FOUND_VER · will be reused"
    elif [[ -n $PHP_FOUND_VER ]]; then
        component_row "PHP" old "$PHP_FOUND_VER is too old · PHP $DEFAULT_PHP will be installed alongside"
    else
        component_row "PHP" missing "not installed · will be installed"
    fi

    if $HAS_COMPOSER; then
        v=$(COMPOSER_ALLOW_SUPERUSER=1 composer --version --no-ansi 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        component_row "Composer" ok "${v:-installed}"
    else component_row "Composer" missing "not installed · will be installed"; fi

    if $HAS_NGINX; then component_row "Nginx" ok "$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    else component_row "Nginx" missing "not installed"; fi

    if $HAS_APACHE; then component_row "Apache" ok "installed"
    else component_row "Apache" missing "not installed"; fi

    if $HAS_MYSQL; then component_row "MariaDB / MySQL" ok "$( (mariadb --version 2>/dev/null || mysql --version 2>/dev/null) | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    else component_row "MariaDB / MySQL" missing "not installed"; fi

    if $HAS_PGSQL; then component_row "PostgreSQL" ok "installed"
    else component_row "PostgreSQL" missing "not installed"; fi

    if $HAS_CERTBOT; then component_row "Certbot" ok "$(certbot --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
    else component_row "Certbot" missing "not installed"; fi
}

# ════════════════════════════════════════════════════════════════════════════
#  Preflight
# ════════════════════════════════════════════════════════════════════════════

preflight() {
    printf '\n  %s%sPreflight checks%s\n' "$BOLD" "$WHITE" "$RESET"

    [[ $EUID -eq 0 ]] || die "Please run the installer as root, e.g.  sudo bash <(curl -s https://sh.wemx.net/install.sh)"
    ok "Running as root"

    if $OS_SUPPORTED; then
        ok "Operating system supported ${GREY}($OS_NAME)${RESET}"
    else
        warn "$OS_NAME is not officially supported by this installer"
        if ! $FORCE; then
            confirm "Continue anyway?" N || die "Installation cancelled."
        fi
    fi

    case $ARCH in
        x86_64 | amd64 | aarch64 | arm64) ok "CPU architecture supported ${GREY}($ARCH)${RESET}" ;;
        *) warn "Untested CPU architecture: $ARCH" ;;
    esac

    if $HAS_SYSTEMD; then ok "systemd detected"; else warn "systemd not detected — the queue worker must be started manually"; fi

    if ((MEM_MB > 0 && MEM_MB < 900)); then
        warn "Only $MEM_MB MB RAM detected — 1 GB or more is recommended"
    else
        ok "Memory ${GREY}($MEM_MB MB)${RESET}"
    fi

    if ((DISK_MB > 0 && DISK_MB < 2048)); then
        warn "Only $DISK_MB MB free disk space — at least 2 GB is recommended"
    else
        ok "Disk space ${GREY}($((DISK_MB / 1024)) GB free)${RESET}"
    fi

    if have curl; then
        if curl -fsS --max-time 10 -o /dev/null https://github.com 2>/dev/null; then
            ok "Internet connection ${GREY}(github.com reachable)${RESET}"
        else
            die "Cannot reach github.com. Check this server's internet connection / DNS and try again."
        fi
    fi
}

# ════════════════════════════════════════════════════════════════════════════
#  Configuration (questions)
# ════════════════════════════════════════════════════════════════════════════

configure() {
    printf '\n  %s%sConfiguration%s\n' "$BOLD" "$WHITE" "$RESET"

    # Domain
    if [[ -n $DOMAIN ]]; then
        DOMAIN=$(normalize_domain "$DOMAIN")
        valid_domain "$DOMAIN" || die "Invalid domain: $DOMAIN"
        ok "Domain ${GREY}·${RESET} ${ACCENT2}$DOMAIN${RESET}"
    else
        if [[ $INTERACTIVE != true && -z $PUBLIC_IP ]]; then die "Use --domain when running non-interactively."; fi
        ask DOMAIN "Domain for WemX (e.g. panel.example.com)" "${PUBLIC_IP}" valid_domain "Enter a valid domain such as panel.example.com or an IPv4 address."
        DOMAIN=$(normalize_domain "$DOMAIN")
    fi

    # Install directory
    if [[ $INSTALL_DIR != /var/www/wemx || $INTERACTIVE != true ]]; then
        valid_dir "$INSTALL_DIR" || die "Invalid install directory: $INSTALL_DIR"
        ok "Install directory ${GREY}·${RESET} ${ACCENT2}$INSTALL_DIR${RESET}"
    else
        ask INSTALL_DIR "Install directory" "$INSTALL_DIR" valid_dir "Use an absolute path such as /var/www/wemx (system folders are not allowed)."
    fi
    INSTALL_DIR=${INSTALL_DIR%/}

    # Web server — default to whatever is already installed
    if [[ -z $WEBSERVER ]]; then
        local def=0
        $HAS_APACHE && ! $HAS_NGINX && def=1
        choose WEBSERVER "Web server" "$def" \
            "nginx|Nginx|$($HAS_NGINX && echo 'installed · ')recommended" \
            "apache|Apache|$($HAS_APACHE && echo 'installed')"
    else
        [[ $WEBSERVER == nginx || $WEBSERVER == apache ]] || die "--webserver must be 'nginx' or 'apache'"
        ok "Web server ${GREY}·${RESET} ${ACCENT2}$WEBSERVER${RESET}"
    fi

    # Port conflicts
    local owners
    owners=$(port_owners 80)
    if [[ -n $owners ]]; then
        case "$WEBSERVER:$owners" in
            nginx:*apache2* | nginx:*httpd*) die "Apache is already using port 80. Re-run and choose Apache, or stop Apache first." ;;
            apache:*nginx*) die "Nginx is already using port 80. Re-run and choose Nginx, or stop Nginx first." ;;
            *nginx* | *apache2* | *httpd*) ;;
            *) warn "Port 80 is in use by: $owners— the web server may fail to start" ;;
        esac
    fi

    # Database
    if [[ -z $DATABASE ]]; then
        local def=0
        $HAS_PGSQL && ! $HAS_MYSQL && def=1
        choose DATABASE "Database" "$def" \
            "mysql|MariaDB / MySQL|$($HAS_MYSQL && echo 'installed · ')recommended" \
            "pgsql|PostgreSQL|$($HAS_PGSQL && echo 'installed')" \
            "none|Skip|use SQLite or an external database in the web installer"
    else
        case $DATABASE in mariadb | mysql) DATABASE=mysql ;; postgres | postgresql | pgsql) DATABASE=pgsql ;; none | sqlite | skip) DATABASE=none ;;
            *) die "--database must be 'mysql', 'pgsql' or 'none'" ;; esac
        ok "Database ${GREY}·${RESET} ${ACCENT2}$DATABASE${RESET}"
    fi

    # SSL
    if is_ipv4 "$DOMAIN" || [[ $DOMAIN == localhost ]]; then
        SSL=no
        skip "SSL skipped — Let's Encrypt needs a domain name, not an IP address"
    elif [[ -z $SSL ]]; then
        if confirm "Set up a free SSL certificate (Let's Encrypt)?" Y; then SSL=yes; else SSL=no; fi
    fi
    if [[ $SSL == yes && -z $SSL_EMAIL ]]; then
        ask SSL_EMAIL "Email for SSL expiry notices (optional)" "" valid_email "Enter a valid email address or leave it empty."
    fi

    # Existing installation in the target directory
    EXISTING_ACTION=""
    if [[ -e $INSTALL_DIR && ! -d $INSTALL_DIR ]]; then
        die "$INSTALL_DIR exists and is not a directory."
    fi
    if [[ -d $INSTALL_DIR && -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
        BACKUP_DIR="${INSTALL_DIR}-backup-$(date +%Y%m%d-%H%M%S)"
        echo
        warn "$INSTALL_DIR is not empty$([[ -f $INSTALL_DIR/artisan ]] && echo ' (an existing WemX / Laravel install was found)')"
        note "To update an existing WemX v3 install use the built-in updater instead: $DOCS_URL/updating"
        if $FORCE || confirm "Move the existing files to $BACKUP_DIR and continue?" N; then
            EXISTING_ACTION=backup
        else
            die "Installation cancelled — $INSTALL_DIR must be empty."
        fi
    fi
}

resolve_release() {
    RELEASE_TAG=""
    RELEASE_URL=""
    local json url
    if [[ -n $WEMX_VERSION ]]; then
        RELEASE_TAG=$WEMX_VERSION
        json=$(curl -fsSL --max-time 15 "https://api.github.com/repos/$GITHUB_REPO/releases/tags/$WEMX_VERSION" 2>/dev/null || true)
    else
        json=$(curl -fsSL --max-time 15 -H "Accept: application/vnd.github+json" \
            ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
            "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null || true)
    fi

    if [[ -n $json ]]; then
        [[ -z $RELEASE_TAG ]] && RELEASE_TAG=$(grep -m1 '"tag_name"' <<<"$json" | sed -E 's/.*"tag_name"[^"]*"([^"]+)".*/\1/')
        RELEASE_URL=$(grep -oE '"browser_download_url"[^"]*"[^"]+\.zip"' <<<"$json" | sed -E 's/.*"(https[^"]+)"/\1/' | grep -i 'wemx' | head -n1)
        [[ -z $RELEASE_URL ]] && RELEASE_URL=$(grep -oE '"browser_download_url"[^"]*"[^"]+\.zip"' <<<"$json" | sed -E 's/.*"(https[^"]+)"/\1/' | head -n1)
    fi

    # Fallback when the GitHub API is rate limited: follow the "latest" redirect
    if [[ -z $RELEASE_TAG ]]; then
        url=$(curl -fsSIL --max-time 15 -o /dev/null -w '%{url_effective}' "https://github.com/$GITHUB_REPO/releases/latest" 2>/dev/null || true)
        [[ $url == */tag/* ]] && RELEASE_TAG=${url##*/tag/}
    fi
    [[ -n $RELEASE_TAG && -z $RELEASE_URL ]] && RELEASE_URL="https://github.com/$GITHUB_REPO/releases/download/$RELEASE_TAG/WemX-$RELEASE_TAG.zip"
    [[ -n $RELEASE_URL ]]
}

summary_and_confirm() {
    local db_label web_label
    case $DATABASE in mysql) db_label="MariaDB / MySQL (database + user created automatically)" ;; pgsql) db_label="PostgreSQL (database + user created automatically)" ;; *) db_label="configure in the web installer" ;; esac
    [[ $WEBSERVER == nginx ]] && web_label="Nginx" || web_label="Apache"

    echo
    printf '  %s╭─%s %s%sReady to install%s\n' "$ACCENT" "$RESET" "$BOLD" "$WHITE" "$RESET"
    printf '  %s│%s\n' "$ACCENT" "$RESET"
    printf '  %s│%s  %-14s %s\n' "$ACCENT" "$RESET" "WemX" "${RELEASE_TAG:-latest}"
    printf '  %s│%s  %-14s %s\n' "$ACCENT" "$RESET" "URL" "$([[ $SSL == yes ]] && echo https || echo http)://$DOMAIN"
    printf '  %s│%s  %-14s %s\n' "$ACCENT" "$RESET" "Directory" "$INSTALL_DIR"
    printf '  %s│%s  %-14s %s\n' "$ACCENT" "$RESET" "PHP" "$(php_plan_label)"
    printf '  %s│%s  %-14s %s\n' "$ACCENT" "$RESET" "Web server" "$web_label"
    printf '  %s│%s  %-14s %s\n' "$ACCENT" "$RESET" "Database" "$db_label"
    printf '  %s│%s  %-14s %s\n' "$ACCENT" "$RESET" "SSL" "$([[ $SSL == yes ]] && echo "Let's Encrypt${SSL_EMAIL:+ ($SSL_EMAIL)}" || echo "no")"
    [[ $EXISTING_ACTION == backup ]] && printf '  %s│%s  %-14s %s\n' "$ACCENT" "$RESET" "Backup" "$INSTALL_DIR → $BACKUP_DIR"
    printf '  %s│%s\n' "$ACCENT" "$RESET"
    printf '  %s╰─%s %sLog file: %s%s\n' "$ACCENT" "$RESET" "$GREY" "$LOG_FILE" "$RESET"
    echo
    confirm "Start the installation?" Y || die "Installation cancelled."
}

php_plan_label() {
    if [[ -n $PHP_WANTED ]]; then echo "PHP $PHP_WANTED"
    elif [[ -n $PHP_FOUND_VER ]] && version_ge "$PHP_FOUND_VER" "$MIN_PHP"; then echo "PHP $PHP_FOUND_VER (already installed)"
    else echo "PHP $MIN_PHP+ (newest available)"; fi
}

# ════════════════════════════════════════════════════════════════════════════
#  Install steps
# ════════════════════════════════════════════════════════════════════════════

# ── 1. System packages ─────────────────────────────────────────────────────
step_system() {
    step "Preparing the system"
    task "Refreshing package lists" pkg_update

    if [[ $FAMILY == debian ]]; then
        ensure_packages "base tools" ca-certificates curl git unzip tar gnupg cron openssl iproute2
    else
        local -a base
        mapfile -t base < <(pkg_available ca-certificates curl git unzip tar cronie openssl iproute dnf-plugins-core findutils)
        ensure_packages "base tools" "${base[@]}"
        $SELINUX && ensure_packages "SELinux tools" policycoreutils-python-utils
    fi

    if [[ $FAMILY == rhel ]]; then
        if ! pkg_installed epel-release; then
            task "Enabling EPEL repository" enable_epel
        else
            ok "EPEL repository ${GREY}already enabled${RESET}"
        fi
    fi

    svc_active cron 2>/dev/null || svc_active crond 2>/dev/null ||
        try "Starting cron" svc_enable "$([[ $FAMILY == debian ]] && echo cron || echo crond)"
}

enable_epel() {
    if [[ $OS_ID == rhel ]]; then
        dnf -y install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_MAJOR}.noarch.rpm"
        subscription-manager repos --enable "codeready-builder-for-rhel-${OS_MAJOR}-$(arch)-rpms" || true
    else
        dnf -y install epel-release
        if ((OS_MAJOR == 8)); then dnf config-manager --set-enabled powertools || true
        else dnf config-manager --set-enabled crb || true; fi
    fi
}

# ── 2. PHP ─────────────────────────────────────────────────────────────────
add_php_repo_debian() {
    if [[ $OS_ID == ubuntu || -n $OS_UBUNTU_CODENAME ]]; then
        apt_get install software-properties-common
        LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
    else
        curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
        dpkg -i /tmp/debsuryorg-archive-keyring.deb
        rm -f /tmp/debsuryorg-archive-keyring.deb
        echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ ${OS_CODENAME} main" \
            >/etc/apt/sources.list.d/php.list
    fi
    apt_get update
}

add_php_repo_rhel() {
    dnf -y install "https://rpms.remirepo.net/enterprise/remi-release-${OS_MAJOR}.rpm"
    dnf -y module reset php
    dnf -y module enable "php:remi-${PHP_VER}"
    # upgrade an older PHP that is already installed to the new stream
    if rpm -q php-cli >/dev/null 2>&1; then dnf -y distro-sync 'php*'; fi
}

php_native_rhel_ok() {
    # Fedora and EL10 ship a recent enough PHP in their own repositories
    local v
    v=$(dnf -q repoquery --qf '%{version}\n' php-cli 2>/dev/null | sed '/^$/d' | sort -V | tail -n1)
    [[ -n $v ]] && version_ge "${v%.*}" "$MIN_PHP"
}

step_php() {
    if [[ -n $PHP_WANTED ]]; then
        PHP_VER=$PHP_WANTED
    elif [[ -n $PHP_FOUND_VER ]] && version_ge "$PHP_FOUND_VER" "$MIN_PHP"; then
        PHP_VER=$PHP_FOUND_VER
    else
        PHP_VER=""
    fi

    step "Installing PHP${PHP_VER:+ $PHP_VER}"

    if [[ $FAMILY == debian ]]; then
        if [[ -z $PHP_VER ]]; then
            # Prefer what the distro ships, otherwise add the Ondřej Surý repository
            local v avail
            avail=$(pkg_available php8.5-fpm php8.4-fpm php8.3-fpm)
            for v in 8.4 8.3 8.5; do
                if grep -qx "php$v-fpm" <<<"$avail"; then PHP_VER=$v; break; fi
            done
            if [[ -z $PHP_VER ]]; then
                PHP_VER=$DEFAULT_PHP
                task "Adding PHP repository ${GREY}($([[ $OS_ID == ubuntu ]] && echo ppa:ondrej/php || echo packages.sury.org))${RESET}" add_php_repo_debian
            else
                ok "PHP $PHP_VER is available from the system repositories"
            fi
        elif [[ -z "$(pkg_available "php$PHP_VER-fpm")" ]]; then
            task "Adding PHP repository" add_php_repo_debian
        fi

        local -a want=() ext
        for ext in cli fpm common curl mbstring xml zip bcmath intl gd mysql pgsql sqlite3 soap opcache readline; do
            want+=("php$PHP_VER-$ext")
        done
        local -a pkgs
        mapfile -t pkgs < <(pkg_available "${want[@]}")
        ((${#pkgs[@]} > 0)) || die "PHP $PHP_VER packages are not available for $OS_NAME."
        ensure_packages "PHP $PHP_VER + extensions" "${pkgs[@]}"

        PHP_BIN=/usr/bin/php$PHP_VER
        FPM_SERVICE=php$PHP_VER-fpm
        FPM_SOCK=/run/php/php$PHP_VER-fpm.sock
        FPM_POOL=/etc/php/$PHP_VER/fpm/pool.d/www.conf
        PHP_INI_DIRS=("/etc/php/$PHP_VER/fpm/conf.d" "/etc/php/$PHP_VER/cli/conf.d")
        have update-alternatives && update-alternatives --set php "$PHP_BIN" >/dev/null 2>&1
    else
        if ! pkg_installed php-cli || ! version_ge "$(php_ver_of /usr/bin/php)" "$MIN_PHP"; then
            if [[ -z $PHP_VER ]] && php_native_rhel_ok; then
                ok "A recent PHP is available from the system repositories"
            else
                PHP_VER=${PHP_VER:-$DEFAULT_PHP}
                if [[ $FAMILY == fedora ]]; then
                    task "Adding Remi repository" bash -c "dnf -y install https://rpms.remirepo.net/fedora/remi-release-${OS_MAJOR}.rpm && dnf -y module reset php; dnf -y module enable php:remi-${PHP_VER} || dnf config-manager setopt remi-modular.enabled=1"
                else
                    task "Adding Remi PHP repository ${GREY}(PHP $PHP_VER)${RESET}" add_php_repo_rhel
                fi
            fi
        fi
        local -a pkgs
        mapfile -t pkgs < <(pkg_available php-cli php-fpm php-common php-mbstring php-xml php-pecl-zip php-zip php-bcmath \
            php-intl php-gd php-mysqlnd php-pgsql php-pdo php-soap php-opcache php-process php-sodium)
        ((${#pkgs[@]} > 0)) || die "PHP packages are not available for $OS_NAME."
        ensure_packages "PHP + extensions" "${pkgs[@]}"

        PHP_BIN=/usr/bin/php
        FPM_SERVICE=php-fpm
        FPM_SOCK=/run/php-fpm/www.sock
        FPM_POOL=/etc/php-fpm.d/www.conf
        PHP_INI_DIRS=("/etc/php.d")
    fi

    [[ -x $PHP_BIN ]] || die "PHP was not installed correctly ($PHP_BIN is missing)."
    PHP_VER=$(php_ver_of "$PHP_BIN")
    version_ge "$PHP_VER" "$MIN_PHP" || die "PHP $PHP_VER is installed but WemX needs PHP $MIN_PHP or newer."
    ok "PHP $PHP_VER ready ${GREY}($PHP_BIN)${RESET}"

    # Verify extensions
    # hard requirements of the WemX release (composer.lock) + Laravel
    local -a required=(ctype curl dom fileinfo filter hash iconv json mbstring openssl pcre pdo session soap tokenizer xml zip)
    local -a recommended=(bcmath intl gd)
    local modules missing=() e
    modules=$("$PHP_BIN" -m 2>/dev/null | tr '[:upper:]' '[:lower:]')
    for e in "${required[@]}"; do grep -qx "$e" <<<"$modules" || missing+=("$e"); done
    case $DATABASE in
        mysql) grep -qx pdo_mysql <<<"$modules" || missing+=(pdo_mysql) ;;
        pgsql) grep -qx pdo_pgsql <<<"$modules" || missing+=(pdo_pgsql) ;;
    esac
    ((${#missing[@]} == 0)) || die "Required PHP extensions are missing: ${missing[*]}"
    ok "Required PHP extensions present ${GREY}(${#required[@]} checked)${RESET}"
    missing=()
    for e in "${recommended[@]}"; do grep -qx "$e" <<<"$modules" || missing+=("$e"); done
    ((${#missing[@]} == 0)) || warn "Recommended PHP extensions missing: ${missing[*]}"

    # PHP settings for WemX
    local d
    for d in "${PHP_INI_DIRS[@]}"; do
        [[ -d $d ]] || continue
        cat >"$d/99-wemx.ini" <<'EOF'
; Managed by the WemX installer
memory_limit = 512M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 120
expose_php = Off
EOF
    done
    ok "PHP settings tuned for WemX ${GREY}(99-wemx.ini)${RESET}"

    # PHP-FPM runs as the web server user
    if [[ -f $FPM_POOL && $FAMILY != debian ]]; then
        sed -i -E "s/^user = .*/user = $WEB_USER/; s/^group = .*/group = $WEB_USER/" "$FPM_POOL"
    fi
    task "Starting PHP-FPM ${GREY}($FPM_SERVICE)${RESET}" svc_enable "$FPM_SERVICE"
}

# ── 3. Composer ────────────────────────────────────────────────────────────
install_composer() {
    local tmp expected actual
    tmp=$(mktemp -d)
    expected=$(curl -fsSL https://composer.github.io/installer.sig) || return 1
    curl -fsSL https://getcomposer.org/installer -o "$tmp/composer-setup.php" || return 1
    actual=$("$PHP_BIN" -r "echo hash_file('sha384', '$tmp/composer-setup.php');")
    if [[ $expected != "$actual" ]]; then
        echo "Composer installer checksum mismatch"
        rm -rf "$tmp"
        return 1
    fi
    "$PHP_BIN" "$tmp/composer-setup.php" --quiet --install-dir=/usr/local/bin --filename=composer
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

step_composer() {
    step "Installing Composer"
    export COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1
    if $HAS_COMPOSER; then
        ok "Composer ${GREY}already installed$(composer --version --no-ansi 2>/dev/null | grep -oE ' [0-9]+\.[0-9]+\.[0-9]+' | head -n1)${RESET}"
    else
        task "Downloading and verifying Composer" install_composer
    fi
    COMPOSER_BIN=$(command -v composer || echo /usr/local/bin/composer)
}

# ── 4. Web server ──────────────────────────────────────────────────────────
step_webserver() {
    if [[ $WEBSERVER == nginx ]]; then
        step "Installing Nginx"
        WEB_FRESH=false; $HAS_NGINX || WEB_FRESH=true
        ensure_packages "Nginx" nginx
        WEB_SERVICE=nginx
    else
        step "Installing Apache"
        WEB_FRESH=false; $HAS_APACHE || WEB_FRESH=true
        if [[ $FAMILY == debian ]]; then
            ensure_packages "Apache" apache2
            WEB_SERVICE=apache2
            task "Enabling Apache modules ${GREY}(rewrite, proxy_fcgi, headers)${RESET}" a2enmod -q rewrite proxy proxy_fcgi setenvif headers
            # mod_php conflicts with PHP-FPM
            local m
            for m in /etc/apache2/mods-enabled/php*.load; do [[ -e $m ]] && a2dismod -q "$(basename "$m" .load)" >/dev/null 2>&1; done
        else
            ensure_packages "Apache" httpd mod_ssl
            WEB_SERVICE=httpd
        fi
    fi
    task "Starting $WEB_SERVICE" svc_enable "$WEB_SERVICE"
}

# ── 5. Database ────────────────────────────────────────────────────────────
start_mysql() { svc_enable mariadb || svc_enable mysql || svc_enable mysqld; }

mysql_root() { # run SQL as the database root user
    if [[ -n ${MYSQL_ROOT_PASS:-} ]]; then
        MYSQL_PWD=$MYSQL_ROOT_PASS mysql -u root "$@"
    else
        mysql -u root "$@"
    fi
}

pg_super() { (cd / && runuser -u postgres -- psql -v ON_ERROR_STOP=1 -qtA "$@"); }

setup_pgsql_rhel() {
    if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
        postgresql-setup --initdb || return 1
    fi
    # allow password logins from localhost
    sed -i -E 's/^(host\s+all\s+all\s+(127\.0\.0\.1\/32|::1\/128)\s+)ident/\1scram-sha-256/' /var/lib/pgsql/data/pg_hba.conf
    svc_enable postgresql
}

step_database() {
    DB_NAME="" DB_USER="" DB_PASS="" DB_PORT=""
    case $DATABASE in
        none)
            step "Database"
            skip "Skipped — choose SQLite or enter your own database in the web installer"
            return
            ;;
        mysql)
            step "Setting up MariaDB / MySQL"
            if $HAS_MYSQL; then
                ok "MariaDB / MySQL ${GREY}already installed${RESET}"
            else
                ensure_packages "MariaDB server" mariadb-server
            fi
            local svc
            for svc in mariadb mysql mysqld; do
                if svc_active "$svc"; then DB_SERVICE=$svc; break; fi
            done
            [[ -n ${DB_SERVICE:-} ]] || task "Starting database server" start_mysql

            # Root access (unix socket auth on fresh installs)
            if ! mysql_root -e 'SELECT 1' >/dev/null 2>&1; then
                if [[ $INTERACTIVE == true ]]; then
                    warn "Could not log in to MySQL as root without a password"
                    printf '  %s?%s %sMySQL root password%s %s›%s ' "$ACCENT" "$RESET" "$BOLD" "$RESET" "$ACCENT" "$RESET"
                    IFS= read -rs MYSQL_ROOT_PASS <"$TTY"
                    printf '\n'
                fi
                if ! mysql_root -e 'SELECT 1' >/dev/null 2>&1; then
                    warn "Could not access MySQL as root — create the database manually (see $DOCS_URL)"
                    DATABASE=none
                    return
                fi
            fi

            DB_NAME=wemx DB_USER=wemx DB_PORT=3306
            local suffix
            suffix=$(random_string 4 | tr '[:upper:]' '[:lower:]')
            if [[ -n "$(mysql_root -N -e "SHOW DATABASES LIKE 'wemx'" 2>/dev/null)" ]]; then
                DB_NAME="wemx_$suffix"
                note "A database called 'wemx' already exists — using '$DB_NAME' instead"
            fi
            if [[ "$(mysql_root -N -e "SELECT COUNT(*) FROM mysql.user WHERE user='wemx'" 2>/dev/null)" != "0" ]]; then
                DB_USER="wemx_$suffix"
            fi
            DB_PASS=$(random_string 28)
            task "Creating database ${GREY}($DB_NAME)${RESET} and user ${GREY}($DB_USER)${RESET}" mysql_root -e "
                CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
                CREATE USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
                CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
                GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1';
                GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
                FLUSH PRIVILEGES;"
            ;;
        pgsql)
            step "Setting up PostgreSQL"
            if $HAS_PGSQL; then
                ok "PostgreSQL ${GREY}already installed${RESET}"
            elif [[ $FAMILY == debian ]]; then
                ensure_packages "PostgreSQL" postgresql postgresql-contrib
            else
                ensure_packages "PostgreSQL" postgresql-server postgresql-contrib
            fi
            if [[ $FAMILY == debian ]]; then
                svc_active postgresql || task "Starting PostgreSQL" svc_enable postgresql
            else
                task "Initialising PostgreSQL" setup_pgsql_rhel
            fi

            DB_NAME=wemx DB_USER=wemx DB_PORT=5432
            local suffix
            suffix=$(random_string 4 | tr '[:upper:]' '[:lower:]')
            [[ "$(pg_super -c "SELECT 1 FROM pg_database WHERE datname='wemx'" 2>/dev/null)" == 1 ]] && DB_NAME="wemx_$suffix"
            [[ "$(pg_super -c "SELECT 1 FROM pg_roles WHERE rolname='wemx'" 2>/dev/null)" == 1 ]] && DB_USER="wemx_$suffix"
            DB_PASS=$(random_string 28)
            task "Creating database ${GREY}($DB_NAME)${RESET} and user ${GREY}($DB_USER)${RESET}" bash -c "
                cd / &&
                runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -c \"CREATE USER $DB_USER WITH ENCRYPTED PASSWORD '$DB_PASS';\" &&
                runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -c \"CREATE DATABASE $DB_NAME OWNER $DB_USER ENCODING 'UTF8' TEMPLATE template0;\""
            ;;
    esac
}

# ── 6. Download ────────────────────────────────────────────────────────────
download_with_progress() { # url dest label
    local url=$1 dest=$2 label=$3 total size pct filled pid i=0 mb
    total=$(curl -fsSIL --max-time 20 "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:" {v=$2} END {print v+0}')
    log "RUN   download $url"
    curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url" 2>>"$LOG_FILE" &
    pid=$!
    SPIN_PID=$pid
    if $ANIMATE; then
        hide_cursor
        while kill -0 "$pid" 2>/dev/null; do
            size=$(stat -c %s "$dest" 2>/dev/null || echo 0)
            mb=$(awk -v s="$size" 'BEGIN {printf "%.1f", s/1048576}')
            if ((total > 0)); then
                pct=$((size * 100 / total)); ((pct > 100)) && pct=100
                filled=$((pct * 24 / 100))
                printf '\r  %s%s%s %s %s%s%s%s %3d%% %s%s / %s MB%s\033[K' \
                    "$ACCENT" "${SPINNER[i % ${#SPINNER[@]}]}" "$RESET" "$label" \
                    "$ACCENT2" "$(repeat '█' "$filled")" "$GREY" "$(repeat '░' $((24 - filled)))" "$pct" \
                    "$GREY" "$mb" "$(awk -v s="$total" 'BEGIN {printf "%.1f", s/1048576}')" "$RESET"
            else
                printf '\r  %s%s%s %s %s%s MB%s\033[K' "$ACCENT" "${SPINNER[i % ${#SPINNER[@]}]}" "$RESET" "$label" "$GREY" "$mb" "$RESET"
            fi
            i=$((i + 1))
            sleep 0.1
        done
        show_cursor
        printf '\r\033[K'
    fi
    wait "$pid"
    local rc=$?
    SPIN_PID=""
    return $rc
}

step_download() {
    step "Downloading WemX"
    if [[ -z ${RELEASE_URL:-} ]]; then
        resolve_release || die "Could not find the latest WemX release on GitHub (github.com/$GITHUB_REPO/releases)."
    fi
    ok "Release ${ACCENT2}$RELEASE_TAG${RESET} ${GREY}($(basename "$RELEASE_URL"))${RESET}"

    TMP_DIR=$(mktemp -d /tmp/wemx-install.XXXXXX)
    download_with_progress "$RELEASE_URL" "$TMP_DIR/wemx.zip" "Downloading $(basename "$RELEASE_URL")" ||
        die "Download failed: $RELEASE_URL"
    ok "Downloaded ${GREY}($(du -h "$TMP_DIR/wemx.zip" | cut -f1))${RESET}"

    task "Extracting archive" unzip -q -o "$TMP_DIR/wemx.zip" -d "$TMP_DIR/extract"

    local artisan
    artisan=$(find "$TMP_DIR/extract" -maxdepth 3 -type f -name artisan | head -n1)
    [[ -n $artisan && -d "$(dirname "$artisan")/public" ]] || die "The downloaded archive does not look like a WemX release."
    SRC_DIR=$(dirname "$artisan")

    if [[ $EXISTING_ACTION == backup ]]; then
        task "Moving existing files to ${GREY}$BACKUP_DIR${RESET}" mv "$INSTALL_DIR" "$BACKUP_DIR"
    fi
    mkdir -p "$INSTALL_DIR"
    task "Copying files to $INSTALL_DIR" cp -a "$SRC_DIR/." "$INSTALL_DIR/"
}

# ── 7. Configure application ───────────────────────────────────────────────
set_env() { # key value
    local file="$INSTALL_DIR/.env" esc
    esc=$(printf '%s' "$2" | sed -e 's/[\/&|]/\\&/g')
    if grep -qE "^$1=" "$file"; then
        sed -i -E "s|^$1=.*|$1=$esc|" "$file"
    else
        printf '%s=%s\n' "$1" "$2" >>"$file"
    fi
}

apply_selinux() {
    semanage fcontext -a -t httpd_sys_content_t "$INSTALL_DIR(/.*)?" 2>/dev/null ||
        semanage fcontext -m -t httpd_sys_content_t "$INSTALL_DIR(/.*)?"
    semanage fcontext -a -t httpd_sys_rw_content_t "$INSTALL_DIR/storage(/.*)?" 2>/dev/null ||
        semanage fcontext -m -t httpd_sys_rw_content_t "$INSTALL_DIR/storage(/.*)?"
    semanage fcontext -a -t httpd_sys_rw_content_t "$INSTALL_DIR/bootstrap/cache(/.*)?" 2>/dev/null ||
        semanage fcontext -m -t httpd_sys_rw_content_t "$INSTALL_DIR/bootstrap/cache(/.*)?"
    # .env and database/ are written by the web installer
    semanage fcontext -a -t httpd_sys_rw_content_t "$INSTALL_DIR/\.env" 2>/dev/null ||
        semanage fcontext -m -t httpd_sys_rw_content_t "$INSTALL_DIR/\.env"
    semanage fcontext -a -t httpd_sys_rw_content_t "$INSTALL_DIR/database(/.*)?" 2>/dev/null ||
        semanage fcontext -m -t httpd_sys_rw_content_t "$INSTALL_DIR/database(/.*)?"
    restorecon -R "$INSTALL_DIR"
    setsebool -P httpd_can_network_connect 1
    setsebool -P httpd_can_network_connect_db 1
    setsebool -P httpd_can_sendmail 1
}

step_configure() {
    step "Configuring WemX"
    cd "$INSTALL_DIR" || die "Cannot enter $INSTALL_DIR"

    if [[ ! -f vendor/autoload.php && -f composer.json ]]; then
        task "Installing PHP dependencies ${GREY}(composer install)${RESET}" \
            "$PHP_BIN" "$COMPOSER_BIN" install --no-dev --optimize-autoloader --no-interaction --no-progress
    else
        ok "PHP dependencies ${GREY}bundled with the release${RESET}"
    fi

    if [[ ! -f .env ]]; then
        [[ -f .env.example ]] || die ".env.example is missing from the release."
        cp .env.example .env
        ok "Created .env"
        task "Generating application key" "$PHP_BIN" artisan key:generate --force
    else
        ok ".env ${GREY}already exists — keeping it${RESET}"
    fi
    set_env APP_URL "http://$DOMAIN"

    try "Clearing caches" "$PHP_BIN" artisan optimize:clear

    task "Setting file ownership ${GREY}($WEB_USER)${RESET}" bash -c "
        chown -R '$WEB_USER:$WEB_USER' '$INSTALL_DIR' &&
        chmod -R ug+rwX '$INSTALL_DIR/storage' '$INSTALL_DIR/bootstrap/cache' &&
        chmod 640 '$INSTALL_DIR/.env'"

    if $SELINUX; then
        task "Applying SELinux policy" apply_selinux
    fi
}

# ── 8. Web server site ─────────────────────────────────────────────────────
write_nginx_site() {
    local conf link=""
    if [[ -d /etc/nginx/sites-available ]]; then
        conf=/etc/nginx/sites-available/wemx.conf
        link=/etc/nginx/sites-enabled/wemx.conf
    else
        mkdir -p /etc/nginx/conf.d
        conf=/etc/nginx/conf.d/wemx.conf
    fi
    [[ -f $conf ]] && cp "$conf" "$conf.bak-$(date +%s)" && note "Backed up the previous $conf"

    cat >"$conf" <<EOF
# WemX — generated by the WemX installer on $(date -u '+%F %T UTC')
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${INSTALL_DIR}/public;
    index index.php;
    charset utf-8;

    client_max_body_size 64m;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ ^/index\.php(/|\$) {
        fastcgi_pass unix:${FPM_SOCK};
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
        fastcgi_read_timeout 120;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
    if [[ -n $link ]]; then
        ln -sf "$conf" "$link"
        # links left behind by the previous installer for the same domain
        rm -f "/etc/nginx/sites-enabled/wemx-${DOMAIN}"
        $WEB_FRESH && rm -f /etc/nginx/sites-enabled/default
    fi
    SITE_CONF=$conf
}

write_apache_site() {
    local conf logdir
    if [[ $FAMILY == debian ]]; then
        conf=/etc/apache2/sites-available/wemx.conf
        logdir='${APACHE_LOG_DIR}'
    else
        conf=/etc/httpd/conf.d/wemx.conf
        logdir=logs
    fi
    [[ -f $conf ]] && cp "$conf" "$conf.bak-$(date +%s)" && note "Backed up the previous $conf"

    cat >"$conf" <<EOF
# WemX — generated by the WemX installer on $(date -u '+%F %T UTC')
<VirtualHost *:80>
    ServerName ${DOMAIN}
    DocumentRoot ${INSTALL_DIR}/public

    <Directory ${INSTALL_DIR}/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch \.php$>
        SetHandler "proxy:unix:${FPM_SOCK}|fcgi://localhost"
    </FilesMatch>

    LimitRequestBody 67108864
    ErrorLog ${logdir}/wemx-error.log
    CustomLog ${logdir}/wemx-access.log combined
</VirtualHost>
EOF
    if [[ $FAMILY == debian ]]; then
        a2ensite -q wemx >/dev/null
        $WEB_FRESH && a2dissite -q 000-default >/dev/null 2>&1
    fi
    SITE_CONF=$conf
}

step_site() {
    step "Configuring $([[ $WEBSERVER == nginx ]] && echo Nginx || echo Apache)"
    if [[ $WEBSERVER == nginx ]]; then
        write_nginx_site
        ok "Site config written ${GREY}($SITE_CONF)${RESET}"
        task "Testing Nginx configuration" nginx -t
    else
        write_apache_site
        ok "Site config written ${GREY}($SITE_CONF)${RESET}"
        task "Testing Apache configuration" apachectl configtest
    fi
    task "Reloading $WEB_SERVICE" svc_reload "$WEB_SERVICE"

    # Quick smoke test
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: $DOMAIN" http://127.0.0.1/ 2>/dev/null || echo 000)
    case $code in
        2?? | 3??) ok "WemX responds locally ${GREY}(HTTP $code)${RESET}" ;;
        *) warn "WemX returned HTTP $code on a local test request — check $LOG_FILE and $INSTALL_DIR/storage/logs" ;;
    esac
}

# ── 9. Scheduler & queue worker ────────────────────────────────────────────
step_services() {
    step "Scheduler & queue worker"

    # Cron — runs as the web user so cache files keep the right owner
    cat >/etc/cron.d/wemx <<EOF
# WemX scheduler — managed by the WemX installer
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * ${WEB_USER} ${PHP_BIN} ${INSTALL_DIR}/artisan schedule:run >> /dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/wemx
    # Remove the root crontab entry the previous installer created
    if crontab -l 2>/dev/null | grep -qF "${INSTALL_DIR}/artisan schedule:run"; then
        crontab -l 2>/dev/null | grep -vF "${INSTALL_DIR}/artisan schedule:run" | crontab -
        note "Removed the old root crontab entry"
    fi
    ok "Scheduler cron job ${GREY}(/etc/cron.d/wemx, every minute)${RESET}"

    if ! $HAS_SYSTEMD; then
        warn "systemd not available — run the queue worker yourself: $PHP_BIN $INSTALL_DIR/artisan queue:work"
        return
    fi

    # Retire the service name used by the previous installer
    if [[ -f /etc/systemd/system/wemx-queue-worker.service ]]; then
        systemctl disable --now wemx-queue-worker >/dev/null 2>&1
        mv /etc/systemd/system/wemx-queue-worker.service "/etc/systemd/system/wemx-queue-worker.service.bak"
        note "Replaced the old wemx-queue-worker service"
    fi
    [[ -f /etc/systemd/system/wemx.service ]] && cp /etc/systemd/system/wemx.service "/etc/systemd/system/wemx.service.bak-$(date +%s)"

    cat >/etc/systemd/system/wemx.service <<EOF
[Unit]
Description=WemX Queue Worker
After=network.target
# keep retrying until the web installer has configured the database
StartLimitIntervalSec=0

[Service]
User=${WEB_USER}
Group=${WEB_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${PHP_BIN} ${INSTALL_DIR}/artisan queue:work --sleep=3 --tries=3
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
    task "Starting queue worker ${GREY}(wemx.service)${RESET}" bash -c "systemctl daemon-reload && systemctl enable --now wemx"
}

# ── 10. Firewall ───────────────────────────────────────────────────────────
step_firewall() {
    step "Firewall"
    local done=false
    if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        task "Opening ports 80 and 443 in UFW" bash -c "ufw allow 80/tcp && ufw allow 443/tcp"
        done=true
    fi
    if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        task "Opening HTTP and HTTPS in firewalld" bash -c "firewall-cmd --permanent --add-service=http --add-service=https && firewall-cmd --reload"
        done=true
    fi
    $done || skip "No active firewall (UFW / firewalld) found — nothing to change"
    note "Using a cloud provider? Make sure ports 80 and 443 are open in its security group too."
}

# ── 11. SSL ────────────────────────────────────────────────────────────────
step_ssl() {
    step "SSL certificate"
    SSL_OK=false
    if [[ $SSL != yes ]]; then
        skip "Skipped"
        return
    fi

    local resolved
    resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1 {print $1}')
    if [[ -z $resolved ]]; then
        warn "$DOMAIN does not resolve yet — point an A record at ${PUBLIC_IP:-this server} first"
        confirm "Try to get a certificate anyway?" N || { skip "SSL skipped — run: certbot --$WEBSERVER -d $DOMAIN"; return; }
    elif [[ -n $PUBLIC_IP && $resolved != "$PUBLIC_IP" ]]; then
        warn "$DOMAIN points to $resolved, but this server's IP is $PUBLIC_IP"
        note "If you use the Cloudflare proxy (orange cloud), disable it until the certificate is issued."
        confirm "Try to get a certificate anyway?" Y || { skip "SSL skipped — run: certbot --$WEBSERVER -d $DOMAIN"; return; }
    else
        ok "DNS for $DOMAIN points to this server ${GREY}($resolved)${RESET}"
    fi

    if [[ $WEBSERVER == nginx ]]; then
        ensure_packages "Certbot" certbot python3-certbot-nginx
    else
        ensure_packages "Certbot" certbot python3-certbot-apache
    fi

    local -a args=(--"$WEBSERVER" -d "$DOMAIN" --non-interactive --agree-tos --redirect)
    if [[ -n $SSL_EMAIL ]]; then args+=(--email "$SSL_EMAIL"); else args+=(--register-unsafely-without-email); fi

    if try "Requesting certificate from Let's Encrypt" certbot "${args[@]}"; then
        SSL_OK=true
        set_env APP_URL "https://$DOMAIN"
        if $HAS_SYSTEMD; then
            systemctl enable --now certbot.timer >/dev/null 2>&1 || systemctl enable --now certbot-renew.timer >/dev/null 2>&1
        fi
        ok "HTTPS enabled ${GREY}(auto-renews)${RESET}"
    else
        note "Common causes: DNS not pointing here yet, ports 80/443 blocked, or Cloudflare proxy enabled."
        note "Retry later with: certbot --$WEBSERVER -d $DOMAIN"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
#  Finish
# ════════════════════════════════════════════════════════════════════════════

write_info_file() {
    umask 077
    {
        echo "WemX installation — $(date)"
        echo
        echo "URL:            ${APP_URL_FINAL}"
        echo "Web installer:  ${APP_URL_FINAL}/install"
        echo "Directory:      ${INSTALL_DIR}"
        echo "Release:        ${RELEASE_TAG}"
        echo "PHP:            ${PHP_VER} (${PHP_BIN})"
        echo "Web server:     ${WEBSERVER} (${SITE_CONF})"
        if [[ -n $DB_NAME ]]; then
            echo
            echo "Database type:  $([[ $DATABASE == mysql ]] && echo MySQL/MariaDB || echo PostgreSQL)"
            echo "Host:           127.0.0.1"
            echo "Port:           ${DB_PORT}"
            echo "Database:       ${DB_NAME}"
            echo "Username:       ${DB_USER}"
            echo "Password:       ${DB_PASS}"
        fi
        echo
        echo "Get your free license key at ${LICENSE_URL}"
    } >"$INFO_FILE"
}

finish() {
    progress_to 100
    APP_URL_FINAL="$([[ ${SSL_OK:-false} == true ]] && echo https || echo http)://$DOMAIN"
    write_info_file
    local total=$((SECONDS - START_TIME))

    echo
    typewrite "$GREEN$BOLD" "  ✔ WemX is installed!  ($(fmt_duration $total))" 0.02
    echo
    printf '  %s╭─%s %s%sFinish the setup in your browser%s\n' "$ACCENT" "$RESET" "$BOLD" "$WHITE" "$RESET"
    printf '  %s│%s\n' "$ACCENT" "$RESET"
    printf '  %s│%s  %s1%s  Open  %s%s%s/install%s\n' "$ACCENT" "$RESET" "$ACCENT2" "$RESET" "$BOLD" "$ACCENT2" "$APP_URL_FINAL" "$RESET"
    printf '  %s│%s  %s2%s  Get your free license key at %s%s%s\n' "$ACCENT" "$RESET" "$ACCENT2" "$RESET" "$ACCENT2" "$LICENSE_URL" "$RESET"
    if [[ -n $DB_NAME ]]; then
        printf '  %s│%s  %s3%s  Use these database details:\n' "$ACCENT" "$RESET" "$ACCENT2" "$RESET"
        printf '  %s│%s\n' "$ACCENT" "$RESET"
        printf '  %s│%s       %-11s %s\n' "$ACCENT" "$RESET" "Driver" "$([[ $DATABASE == mysql ]] && echo MySQL || echo PostgreSQL)"
        printf '  %s│%s       %-11s %s\n' "$ACCENT" "$RESET" "Host" "127.0.0.1"
        printf '  %s│%s       %-11s %s\n' "$ACCENT" "$RESET" "Port" "$DB_PORT"
        printf '  %s│%s       %-11s %s\n' "$ACCENT" "$RESET" "Database" "$DB_NAME"
        printf '  %s│%s       %-11s %s\n' "$ACCENT" "$RESET" "Username" "$DB_USER"
        printf '  %s│%s       %-11s %s%s%s\n' "$ACCENT" "$RESET" "Password" "$BOLD" "$DB_PASS" "$RESET"
    else
        printf '  %s│%s  %s3%s  Pick SQLite or enter your database in the installer\n' "$ACCENT" "$RESET" "$ACCENT2" "$RESET"
    fi
    printf '  %s│%s\n' "$ACCENT" "$RESET"
    printf '  %s╰─%s %sThese details are saved in %s (root only)%s\n' "$ACCENT" "$RESET" "$GREY" "$INFO_FILE" "$RESET"

    echo
    printf '  %sUseful commands%s\n' "$BOLD" "$RESET"
    note "systemctl status wemx              queue worker status"
    note "tail -f $INSTALL_DIR/storage/logs/laravel.log"
    note "less $LOG_FILE        installer log"

    if ((${#WARNINGS[@]} > 0)); then
        echo
        printf '  %s%d warning(s) during install:%s\n' "$YELLOW" "${#WARNINGS[@]}" "$RESET"
        local w
        for w in "${WARNINGS[@]}"; do note "• $w"; done
    fi
    echo
    note "Back up the APP_KEY in $INSTALL_DIR/.env — it encrypts data in your database."
    echo
}

# ════════════════════════════════════════════════════════════════════════════
#  CLI
# ════════════════════════════════════════════════════════════════════════════

usage() {
    cat <<EOF
WemX v3 installer ${INSTALLER_VERSION}

Usage: bash <(curl -s https://sh.wemx.net/install.sh) [options]

Options:
  -d, --domain <host>        Domain (or IP) WemX will be served on
      --dir <path>           Install directory (default: /var/www/wemx)
      --webserver <name>     nginx | apache
      --database <name>      mysql | pgsql | none
      --ssl / --no-ssl       Request a Let's Encrypt certificate (or not)
      --email <address>      Email for Let's Encrypt notices
      --php <version>        Force a PHP version, e.g. 8.4
      --version <tag>        Install a specific WemX release tag
  -y, --yes                  Non-interactive: accept defaults, no questions
      --force                Continue on unsupported OS / non-empty directory
      --no-color             Disable colours and animations
      --no-animation         Disable animations only
  -h, --help                 Show this help

Example (unattended):
  bash <(curl -s https://sh.wemx.net/install.sh) -y --domain panel.example.com \\
      --webserver nginx --database mysql --ssl --email you@example.com
EOF
}

parse_args() {
    while (($#)); do
        case $1 in
            -d | --domain) DOMAIN=${2:-}; shift ;;
            --dir) INSTALL_DIR=${2:-}; shift ;;
            --webserver) WEBSERVER=${2:-}; shift ;;
            --database | --db) DATABASE=${2:-}; shift ;;
            --ssl) SSL=yes ;;
            --no-ssl) SSL=no ;;
            --email) SSL_EMAIL=${2:-}; shift ;;
            --php) PHP_WANTED=${2:-}; shift ;;
            --version) WEMX_VERSION=${2:-}; shift ;;
            -y | --yes) ASSUME_YES=true ;;
            --force) FORCE=true ;;
            --no-color | --no-colour) USE_COLOR=false ;;
            --no-animation) ANIMATE=false ;;
            -h | --help) usage; exit 0 ;;
            *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
        esac
        shift
    done
}

on_exit() {
    show_cursor
    [[ -n ${TMP_DIR:-} && -d ${TMP_DIR:-} ]] && rm -rf "$TMP_DIR"
}

on_interrupt() {
    [[ -n $SPIN_PID ]] && kill "$SPIN_PID" 2>/dev/null
    show_cursor
    printf '\r\033[K\n'
    fail "Installation interrupted."
    note "Re-run the installer to try again. Log: $LOG_FILE"
    echo
    exit 130
}

main() {
    parse_args "$@"
    setup_ui
    setup_tty
    trap on_exit EXIT
    trap on_interrupt INT TERM

    START_TIME=$SECONDS
    if [[ $EUID -eq 0 ]]; then
        : >>"$LOG_FILE" && chmod 600 "$LOG_FILE"
        log "════ WemX installer $INSTALLER_VERSION started ════"
    fi

    banner
    detect_os
    detect_resources
    detect_public_ip
    detect_components
    preflight
    show_system_report
    configure

    case $WEBSERVER:$FAMILY in
        nginx:debian | apache:debian) WEB_USER=www-data ;;
        nginx:*) WEB_USER=nginx ;;
        apache:*) WEB_USER=apache ;;
    esac

    resolve_release || warn "Could not look up the latest WemX release yet — will retry during download"
    summary_and_confirm
    log "Config: domain=$DOMAIN dir=$INSTALL_DIR web=$WEBSERVER db=$DATABASE ssl=$SSL os=$OS_NAME"

    step_system
    step_webserver
    step_php
    step_composer
    step_database
    step_download
    step_configure
    step_site
    step_services
    step_firewall
    step_ssl
    finish
}

main "$@"
