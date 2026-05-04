#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="Laravel"
DEFAULT_DIR="/var/www/laravel"
REPO_URL="https://github.com/laravel/laravel.git"
MIN_PHP_VERSION="8.3"
TARGET_PHP_VERSION="8.5"

# ------------------------------------------------------------
# UI
# ------------------------------------------------------------

if [[ -t 1 ]]; then
    BOLD="\033[1m"
    DIM="\033[2m"
    RED="\033[31m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    BLUE="\033[34m"
    MAGENTA="\033[35m"
    CYAN="\033[36m"
    RESET="\033[0m"
else
    BOLD=""
    DIM=""
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    MAGENTA=""
    CYAN=""
    RESET=""
fi

logo() {
    clear || true
    echo -e "${MAGENTA}"
    cat <<'EOF'
╭──────────────────────────────────────────────╮
│                                              │
│        WemX (v3) Auto Install Script         │
│                                              │
│        PHP 8.3+ • Composer • Nginx • SSL     │
│                                              │
╰──────────────────────────────────────────────╯
EOF
    echo -e "${RESET}"
}

info() {
    echo -e "${BLUE}●${RESET} $1"
}

success() {
    echo -e "${GREEN}✔${RESET} $1"
}

warn() {
    echo -e "${YELLOW}⚠${RESET} $1"
}

error() {
    echo -e "${RED}✖${RESET} $1"
}

section() {
    echo
    echo -e "${BOLD}${CYAN}$1${RESET}"
    echo -e "${DIM}$(printf '─%.0s' {1..52})${RESET}"
}

die() {
    error "$1"
    exit 1
}

run() {
    local message="$1"
    shift

    echo -ne "${BLUE}●${RESET} ${message}..."
    if "$@" >/tmp/laravel-installer.log 2>&1; then
        echo -e "\r${GREEN}✔${RESET} ${message}"
    else
        echo -e "\r${RED}✖${RESET} ${message}"
        echo
        error "Command failed:"
        echo "  $*"
        echo
        echo "Last output:"
        tail -n 40 /tmp/laravel-installer.log || true
        exit 1
    fi
}

ask() {
    local prompt="$1"
    local default="$2"
    local value

    read -rp "$(echo -e "${BOLD}${prompt}${RESET} ${DIM}[${default}]${RESET}: ")" value
    echo "${value:-$default}"
}

# ------------------------------------------------------------
# Root / sudo
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    die "Please run this script as root, for example: sudo bash install-laravel.sh"
fi

logo

# ------------------------------------------------------------
# User input
# ------------------------------------------------------------

DOMAIN="$(ask "Enter your domain or hostname" "example.com")"
TARGET_DIR="$(ask "Enter target directory" "$DEFAULT_DIR")"

if [[ -z "$DOMAIN" ]]; then
    die "Domain cannot be empty."
fi

if [[ -z "$TARGET_DIR" ]]; then
    die "Target directory cannot be empty."
fi

if [[ -e "$TARGET_DIR" ]]; then
    if [[ ! -d "$TARGET_DIR" ]]; then
        die "Target path exists and is not a directory: ${TARGET_DIR}. Remove it or choose a different path."
    fi
    if [[ -n "$(ls -A "$TARGET_DIR" 2>/dev/null || true)" ]]; then
        die "A project is already installed in ${TARGET_DIR}. The target directory must be empty (or not exist) before running this installer. Remove or relocate the existing files, then try again."
    fi
fi

section "Install settings"
echo -e "Domain:           ${BOLD}${DOMAIN}${RESET}"
echo -e "Target directory: ${BOLD}${TARGET_DIR}${RESET}"
echo

read -rp "Continue? [Y/n]: " CONTINUE
CONTINUE="${CONTINUE:-Y}"

if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
    die "Installation cancelled."
fi

# ------------------------------------------------------------
# OS / package manager detection
# ------------------------------------------------------------

section "Detecting system"

PKG_MANAGER=""
INSTALL_CMD=""
UPDATE_CMD=""

if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    UPDATE_CMD="apt-get update -y"
    INSTALL_CMD="apt-get install -y"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    UPDATE_CMD="dnf makecache -y"
    INSTALL_CMD="dnf install -y"
elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    UPDATE_CMD="yum makecache -y"
    INSTALL_CMD="yum install -y"
elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
    UPDATE_CMD="pacman -Sy --noconfirm"
    INSTALL_CMD="pacman -S --noconfirm --needed"
elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
    UPDATE_CMD="zypper refresh"
    INSTALL_CMD="zypper install -y"
elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    UPDATE_CMD="apk update"
    INSTALL_CMD="apk add --no-cache"
else
    die "Unsupported Linux package manager. Supported: apt, dnf, yum, pacman, zypper, apk."
fi

success "Detected package manager: $PKG_MANAGER"

run "Updating package index" bash -c "$UPDATE_CMD"

# ------------------------------------------------------------
# Package helpers
# ------------------------------------------------------------

install_packages() {
    local packages=("$@")
    if [[ "${#packages[@]}" -eq 0 ]]; then
        return 0
    fi

    run "Installing packages: ${packages[*]}" bash -c "$INSTALL_CMD ${packages[*]}"
}

# ------------------------------------------------------------
# Base packages
# ------------------------------------------------------------

section "Installing base packages"

case "$PKG_MANAGER" in
    apt)
        install_packages \
            ca-certificates curl wget git unzip zip tar lsb-release gnupg2 software-properties-common \
            nginx certbot python3-certbot-nginx
        ;;
    dnf|yum)
        install_packages \
            ca-certificates curl wget git unzip zip tar nginx certbot python3-certbot-nginx
        ;;
    pacman)
        install_packages \
            ca-certificates curl wget git unzip zip tar nginx certbot certbot-nginx
        ;;
    zypper)
        install_packages \
            ca-certificates curl wget git unzip zip tar nginx certbot python3-certbot-nginx
        ;;
    apk)
        install_packages \
            ca-certificates curl wget git unzip zip tar nginx certbot certbot-nginx bash
        ;;
esac

success "Base packages are ready"

# ------------------------------------------------------------
# PHP installation
# ------------------------------------------------------------

section "Checking PHP"

version_ge() {
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

current_php_version() {
    php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true
}

PHP_OK=false

if command -v php >/dev/null 2>&1; then
    PHP_VERSION="$(current_php_version)"
    if version_ge "$PHP_VERSION" "$MIN_PHP_VERSION"; then
        PHP_OK=true
        success "PHP $PHP_VERSION is already installed"
    else
        warn "PHP $PHP_VERSION is installed, but PHP $MIN_PHP_VERSION+ is required"
    fi
else
    warn "PHP is not installed"
fi

install_php() {
    local php_pkg_version="$TARGET_PHP_VERSION"

    case "$PKG_MANAGER" in
        apt)
            if ! apt-cache show "php${php_pkg_version}" >/dev/null 2>&1; then
                warn "PHP ${php_pkg_version} packages were not found in current apt repositories"

                if grep -qi ubuntu /etc/os-release 2>/dev/null; then
                    run "Adding Ondřej PHP PPA for Ubuntu" add-apt-repository -y ppa:ondrej/php
                    run "Updating package index" apt-get update -y
                elif grep -qi debian /etc/os-release 2>/dev/null; then
                    install_packages apt-transport-https
                    run "Adding Sury PHP repository for Debian" bash -c '
                        curl -fsSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/sury-php.gpg
                        echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury-php.list
                    '
                    run "Updating package index" apt-get update -y
                fi
            fi

            install_packages \
                "php${php_pkg_version}" "php${php_pkg_version}-cli" "php${php_pkg_version}-fpm" "php${php_pkg_version}-common" \
                "php${php_pkg_version}-curl" "php${php_pkg_version}-mbstring" "php${php_pkg_version}-xml" "php${php_pkg_version}-zip" \
                "php${php_pkg_version}-bcmath" "php${php_pkg_version}-intl" "php${php_pkg_version}-sqlite3" "php${php_pkg_version}-mysql"
            ;;

        dnf)
            if command -v dnf >/dev/null 2>&1; then
                dnf module reset php -y >/dev/null 2>&1 || true
                dnf module enable "php:${php_pkg_version}" -y >/dev/null 2>&1 || true
            fi

            install_packages \
                php php-cli php-fpm php-common php-curl php-mbstring \
                php-xml php-zip php-bcmath php-intl php-pdo php-mysqlnd php-sqlite3
            ;;

        yum)
            install_packages \
                php php-cli php-fpm php-common php-curl php-mbstring \
                php-xml php-zip php-bcmath php-intl php-pdo php-mysqlnd
            ;;

        pacman)
            install_packages \
                php php-fpm php-gd php-sqlite php-intl
            ;;

        zypper)
            install_packages \
                php8 php8-fpm php8-curl php8-mbstring php8-openssl \
                php8-xmlreader php8-xmlwriter php8-zip php8-bcmath php8-intl php8-pdo
            ;;

        apk)
            install_packages \
                php83 php83-cli php83-fpm php83-common php83-curl \
                php83-mbstring php83-xml php83-xmlreader php83-xmlwriter \
                php83-openssl php83-phar php83-tokenizer php83-dom \
                php83-fileinfo php83-pdo php83-pdo_sqlite php83-pdo_mysql \
                php83-session php83-ctype php83-simplexml php83-zip php83-bcmath php83-intl

            if ! command -v php >/dev/null 2>&1 && command -v php83 >/dev/null 2>&1; then
                ln -sf "$(command -v php83)" /usr/local/bin/php
            fi
            ;;
    esac
}

if [[ "$PHP_OK" != true ]]; then
    install_php
fi

if ! command -v php >/dev/null 2>&1; then
    die "PHP installation failed or PHP is not in PATH."
fi

PHP_VERSION="$(current_php_version)"

if ! version_ge "$PHP_VERSION" "$MIN_PHP_VERSION"; then
    die "PHP $PHP_VERSION is installed, but PHP $MIN_PHP_VERSION+ is required. Enable a PHP 8.3 repository for your distro and run again."
fi

success "PHP $PHP_VERSION is ready"

# ------------------------------------------------------------
# PHP extensions
# ------------------------------------------------------------

section "Checking Laravel PHP extensions"

REQUIRED_EXTENSIONS=(
    ctype
    curl
    dom
    fileinfo
    filter
    hash
    mbstring
    openssl
    pcre
    pdo
    session
    tokenizer
    xml
)

MISSING_EXTENSIONS=()

for ext in "${REQUIRED_EXTENSIONS[@]}"; do
    if php -m | grep -qi "^${ext}$"; then
        success "PHP extension already installed: $ext"
    else
        warn "PHP extension missing: $ext"
        MISSING_EXTENSIONS+=("$ext")
    fi
done

if [[ "${#MISSING_EXTENSIONS[@]}" -gt 0 ]]; then
    warn "Some extensions are still missing after package installation: ${MISSING_EXTENSIONS[*]}"
    warn "On some distros these are built into PHP or use different package names."
    die "Please install the missing extensions and run this script again."
fi

# ------------------------------------------------------------
# PHP-FPM service detection
# ------------------------------------------------------------

section "Configuring PHP-FPM"

PHP_FPM_SERVICE=""

for svc in "php${TARGET_PHP_VERSION}-fpm" php85-php-fpm php-fpm85 php85-fpm php8-fpm php8.3-fpm php83-php-fpm php-fpm83 php83-fpm php-fpm; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
        PHP_FPM_SERVICE="$svc"
        break
    fi
done

if [[ -z "$PHP_FPM_SERVICE" ]]; then
    if command -v rc-service >/dev/null 2>&1; then
        PHP_FPM_SERVICE="php-fpm83"
    else
        warn "Could not detect PHP-FPM service automatically"
    fi
else
    run "Enabling PHP-FPM service" systemctl enable --now "$PHP_FPM_SERVICE"
    success "PHP-FPM service is running: $PHP_FPM_SERVICE"
fi

# ------------------------------------------------------------
# Composer
# ------------------------------------------------------------

section "Checking Composer"

export COMPOSER_NO_INTERACTION=1
export COMPOSER_ALLOW_SUPERUSER=1

if command -v composer >/dev/null 2>&1; then
    success "Composer is already installed: $(composer --version --no-ansi | head -n 1)"
else
    info "Composer is not installed"

    EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"

    ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"

    if [[ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]]; then
        rm -f /tmp/composer-setup.php
        die "Invalid Composer installer signature."
    fi

    run "Installing Composer" php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php

    success "Composer installed: $(composer --version --no-ansi | head -n 1)"
fi

# ------------------------------------------------------------
# Clone Laravel
# ------------------------------------------------------------

section "Installing Laravel"

mkdir -p "$(dirname "$TARGET_DIR")"
run "Cloning laravel/laravel" git clone "$REPO_URL" "$TARGET_DIR"

cd "$TARGET_DIR"

run "Installing Composer dependencies" composer install --no-interaction --prefer-dist --optimize-autoloader

if [[ ! -f ".env" ]]; then
    run "Creating .env file" cp .env.example .env
else
    success ".env already exists"
fi

run "Generating Laravel APP_KEY" php artisan key:generate --force

# Laravel storage / project tree ownership for nginx + php-fpm (TARGET_DIR):
# - Debian/Ubuntu (nginx or Apache), not RHEL: www-data:www-data
# - RHEL/CentOS-style (dnf/yum) with nginx: nginx:nginx
WEB_USER="www-data"

case "$PKG_MANAGER" in
    dnf|yum)
        WEB_USER="nginx"
        ;;
    pacman)
        WEB_USER="http"
        ;;
    zypper)
        WEB_USER="nginx"
        ;;
    apk)
        WEB_USER="nginx"
        ;;
esac

if id "$WEB_USER" >/dev/null 2>&1; then
    run "Setting Laravel permissions" bash -c "
        chown -R ${WEB_USER}:${WEB_USER} '$TARGET_DIR'
        chmod -R ug+rwX '$TARGET_DIR/storage' '$TARGET_DIR/bootstrap/cache'
    "
else
    warn "Web user $WEB_USER not found; skipping ownership change"
    chmod -R ug+rwX "$TARGET_DIR/storage" "$TARGET_DIR/bootstrap/cache"
fi

run "Optimizing Laravel config" php artisan config:clear
run "Caching Laravel routes/config/views" bash -c "php artisan config:cache && php artisan route:cache || true && php artisan view:cache || true"

# Run migrations after install. If DB is not configured yet, continue and show guidance.
section "Running database migrations"
if php artisan migrate --force >/tmp/laravel-migrate.log 2>&1; then
    success "Database migrations completed"
else
    warn "Database migration failed"
    warn "Laravel is installed, but database credentials may not be configured in .env yet."
    echo
    echo "Migration output:"
    tail -n 30 /tmp/laravel-migrate.log || true
fi

# ------------------------------------------------------------
# Nginx configuration
# ------------------------------------------------------------

section "Configuring Nginx"

PHP_FPM_SOCKET=""

for sock in \
    /run/php/php8.5-fpm.sock \
    /var/run/php/php8.5-fpm.sock \
    /run/php-fpm/php-fpm85.sock \
    /run/php85-fpm.sock \
    /run/php/php8.3-fpm.sock \
    /var/run/php/php8.3-fpm.sock \
    /run/php-fpm/www.sock \
    /run/php/php-fpm.sock \
    /run/php83-fpm.sock \
    /var/run/php-fpm/php-fpm.sock
do
    if [[ -S "$sock" ]]; then
        PHP_FPM_SOCKET="$sock"
        break
    fi
done

if [[ -z "$PHP_FPM_SOCKET" ]]; then
    PHP_FPM_SOCKET="127.0.0.1:9000"
    warn "PHP-FPM socket not found; using $PHP_FPM_SOCKET"
else
    success "Using PHP-FPM socket: $PHP_FPM_SOCKET"
fi

NGINX_CONF_NAME="laravel-${DOMAIN}"
NGINX_CONF=""

if [[ -d /etc/nginx/sites-available ]]; then
    NGINX_CONF="/etc/nginx/sites-available/${NGINX_CONF_NAME}"
else
    mkdir -p /etc/nginx/conf.d
    NGINX_CONF="/etc/nginx/conf.d/${NGINX_CONF_NAME}.conf"
fi

cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${DOMAIN};
    root ${TARGET_DIR}/public;

    index index.php index.html;

    charset utf-8;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ ^/index\.php(/|$) {
        fastcgi_pass unix:${PHP_FPM_SOCKET};
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

if [[ -d /etc/nginx/sites-enabled ]]; then
    ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/${NGINX_CONF_NAME}"

    if [[ -f /etc/nginx/sites-enabled/default ]]; then
        rm -f /etc/nginx/sites-enabled/default
    fi
fi

run "Testing Nginx configuration" nginx -t

if command -v systemctl >/dev/null 2>&1; then
    run "Enabling Nginx" systemctl enable --now nginx
    run "Reloading Nginx" systemctl reload nginx
elif command -v rc-service >/dev/null 2>&1; then
    rc-update add nginx default >/dev/null 2>&1 || true
    run "Starting Nginx" rc-service nginx restart
else
    run "Reloading Nginx" nginx -s reload
fi

# ------------------------------------------------------------
# SSL
# ------------------------------------------------------------

section "Generating SSL certificate"

SSL_OK=false

echo
read -rp "Enter email for Let's Encrypt notifications, or leave empty to skip email: " SSL_EMAIL

CERTBOT_ARGS=(
    --nginx
    -d "$DOMAIN"
    --non-interactive
    --agree-tos
    --redirect
)

if [[ -n "$SSL_EMAIL" ]]; then
    CERTBOT_ARGS+=(--email "$SSL_EMAIL")
else
    CERTBOT_ARGS+=(--register-unsafely-without-email)
fi

if certbot "${CERTBOT_ARGS[@]}" >/tmp/laravel-certbot.log 2>&1; then
    SSL_OK=true
    success "SSL certificate generated successfully"
else
    warn "SSL certificate generation failed"
    warn "Laravel is installed and available over HTTP."
    echo
    echo "Certbot output:"
    tail -n 30 /tmp/laravel-certbot.log || true
    echo
    warn "Common causes:"
    echo "  - DNS for ${DOMAIN} does not point to this server"
    echo "  - Ports 80/443 are blocked by firewall/security group"
    echo "  - Cloudflare proxy is interfering with validation"
fi

# ------------------------------------------------------------
# Cron scheduler
# ------------------------------------------------------------

section "Configuring cron scheduler"

SCHEDULE_CRON_LINE="* * * * * php ${TARGET_DIR}/artisan schedule:run >> /dev/null 2>&1"

if crontab -l 2>/dev/null | rg -Fq "$SCHEDULE_CRON_LINE"; then
    success "Cron schedule already exists"
else
    run "Adding Laravel scheduler cron entry" bash -c "(crontab -l 2>/dev/null || true; echo \"$SCHEDULE_CRON_LINE\") | crontab -"
fi

# ------------------------------------------------------------
# Queue worker (systemd)
# ------------------------------------------------------------

section "Configuring queue worker"

QUEUE_SERVICE_NAME="wemx-queue-worker"
QUEUE_SERVICE_FILE="/etc/systemd/system/${QUEUE_SERVICE_NAME}.service"

if command -v systemctl >/dev/null 2>&1; then
    if [[ -f "$QUEUE_SERVICE_FILE" ]] || systemctl list-unit-files 2>/dev/null | rg -q "^${QUEUE_SERVICE_NAME}\.service"; then
        success "Queue worker service already exists: ${QUEUE_SERVICE_NAME}.service"
    else
        PHP_BIN="$(command -v php || echo /usr/bin/php)"

        cat > "$QUEUE_SERVICE_FILE" <<EOF
[Unit]
Description=WemX Queue Worker

[Service]
# On some systems the user and group might be different.
# Some systems use apache or nginx as the user and group.
User=${WEB_USER}
Group=${WEB_USER}
Restart=always
ExecStart=${PHP_BIN} ${TARGET_DIR}/artisan queue:work
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

        run "Reloading systemd daemon" systemctl daemon-reload
        run "Enabling queue worker service" systemctl enable --now "$QUEUE_SERVICE_NAME"
    fi
else
    warn "systemd not detected; skipping queue worker service setup"
fi

# ------------------------------------------------------------
# Final output
# ------------------------------------------------------------

section "Installation complete"

echo -e "${GREEN}${BOLD}Laravel has been installed successfully.${RESET}"
echo
echo -e "Project directory: ${BOLD}${TARGET_DIR}${RESET}"
echo -e "Nginx config:      ${BOLD}${NGINX_CONF}${RESET}"
echo

echo -e "${BOLD}Open your application:${RESET}"
echo -e "  ${CYAN}http://${DOMAIN}${RESET}"

if [[ "$SSL_OK" == true ]]; then
    echo -e "  ${CYAN}https://${DOMAIN}${RESET}"
fi

echo
echo -e "${DIM}Useful commands:${RESET}"
echo "  cd ${TARGET_DIR}"
echo "  php artisan about"
echo "  php artisan migrate"
echo "  nginx -t"
echo "  certbot certificates"
echo
success "Done"