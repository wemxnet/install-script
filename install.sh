#!/usr/bin/env bash

set -euo pipefail

WEMX_TMP_ZIP="/tmp/wemx.zip"
DEFAULT_DIR="/var/www/wemx"
LOG="/tmp/wemx-installer.log"

if [[ -t 1 ]]; then
    BOLD='\033[1m' DIM='\033[2m' RESET='\033[0m' RED='\033[31m' GREEN='\033[32m' YELLOW='\033[33m' CYAN='\033[36m'
else
    BOLD='' DIM='' RESET='' RED='' GREEN='' YELLOW='' CYAN=''
fi

success() { printf '%b✔%b %s\n'  "${GREEN}"  "${RESET}" "$1"; }
warn()    { printf '%b⚠%b  %s\n' "${YELLOW}" "${RESET}" "$1"; }
error()   { printf '%b✖%b %s\n'  "${RED}"    "${RESET}" "$1" >&2; }
die()     { error "$1"; exit 1; }

run() {
    local msg="$1"; shift
    printf '%b●%b %s...' "${CYAN}" "${RESET}" "${msg}"
    if "$@" >>"${LOG}" 2>&1; then
        printf '\r%b✔%b %s\n' "${GREEN}" "${RESET}" "${msg}"
    else
        printf '\r%b✖%b %s\n' "${RED}" "${RESET}" "${msg}"
        printf '\nLast output:\n'
        tail -n 40 "${LOG}" || true
        exit 1
    fi
}

[[ "${EUID}" -ne 0 ]] && die "must be run as root (sudo)"

printf '%b%s%b\n\n' "${DIM}" "WemX • https://wemx.net" "${RESET}"

# Detect package manager
PM=""
if command -v apt >/dev/null 2>&1; then
    PM="apt"
elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
else
    die "unsupported system - requires apt (Debian/Ubuntu) or dnf (RHEL/Fedora)"
fi
success "Detected package manager: ${PM}"
printf '\n'

pm_install() { "${PM}" install -y "$@"; }

# User input
read -rp "Domain: " DOMAIN
read -rp "Install directory [${DEFAULT_DIR}]: " TARGET_DIR
TARGET_DIR="${TARGET_DIR:-${DEFAULT_DIR}}"

[[ -z "${DOMAIN}" ]]        && die "domain cannot be empty"
[[ "${TARGET_DIR}" != /* ]] && die "directory must be an absolute path"

if [[ -e "${TARGET_DIR}" ]]; then
    [[ ! -d "${TARGET_DIR}" ]] && die "${TARGET_DIR} exists but is not a directory"
    shopt -s nullglob dotglob
    _entries=("${TARGET_DIR}"/*)
    shopt -u nullglob dotglob
    [[ "${#_entries[@]}" -gt 0 ]] && die "${TARGET_DIR} is not empty"
fi

read -rp "Configure SSL with certbot? [Y/n]: " ssl_yn
ssl_yn="${ssl_yn:-Y}"
SSL=false
SSL_EMAIL=""
if [[ "${ssl_yn}" =~ ^[Yy]$ ]]; then
    SSL=true
    read -rp "Email for Let's Encrypt (leave empty to skip): " SSL_EMAIL || true
fi

printf '\n'

# Update package index
case "${PM}" in
    apt) run "Updating package index" apt update -y ;;
    dnf) run "Updating package index" dnf makecache -y ;;
esac

command -v unzip >/dev/null 2>&1 || run "Installing unzip" pm_install unzip

# PHP
PHP_OK=false
if command -v php >/dev/null 2>&1; then
    PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
    if printf '%s\n%s\n' "8.3" "${PHP_VER}" | sort -V -C; then
        PHP_OK=true
        success "PHP ${PHP_VER} already installed"
    fi
fi

if [[ "${PHP_OK}" != true ]]; then
    case "${PM}" in
        apt)
            if ! apt-cache show php8.3 >/dev/null 2>&1; then
                if grep -qi ubuntu /etc/os-release 2>/dev/null; then
                    run "Installing software-properties-common" pm_install software-properties-common
                    run "Adding Ondřej PHP PPA" add-apt-repository -y ppa:ondrej/php
                    run "Updating package index" apt update -y
                elif grep -qi debian /etc/os-release 2>/dev/null; then
                    run "Installing dependencies" pm_install apt-transport-https lsb-release ca-certificates curl
                    run "Downloading Sury GPG key" \
                        curl -fsSL https://packages.sury.org/php/apt.gpg \
                        -o /usr/share/keyrings/sury-php.gpg
                    CODENAME="$(lsb_release -sc)"
                    printf 'deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ %s main\n' \
                        "${CODENAME}" > /etc/apt/sources.list.d/sury-php.list
                    run "Updating package index" apt update -y
                fi
            fi
            run "Installing PHP 8.3" pm_install \
                php8.3 php8.3-cli php8.3-fpm php8.3-common \
                php8.3-curl php8.3-mbstring php8.3-xml php8.3-zip \
                php8.3-bcmath php8.3-intl php8.3-mysql php8.3-sqlite3
            ;;
        dnf)
            dnf module reset php -y >>"${LOG}" 2>&1 || true
            dnf module enable php:8.3 -y >>"${LOG}" 2>&1 || true
            run "Installing PHP 8.3" pm_install \
                php php-cli php-fpm php-common php-curl php-mbstring \
                php-xml php-zip php-bcmath php-intl php-pdo php-mysqlnd php-sqlite3
            ;;
    esac
fi

command -v php >/dev/null 2>&1 || die "PHP installation failed or not in PATH"
PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
printf '%s\n%s\n' "8.3" "${PHP_VER}" | sort -V -C \
    || die "PHP ${PHP_VER} installed but 8.3+ required"
success "PHP ${PHP_VER} ready"

# PHP extensions
REQUIRED_EXTS=(ctype curl dom fileinfo filter hash mbstring openssl pcre pdo session soap tokenizer xml zip)
MISSING_EXTS=()
for ext in "${REQUIRED_EXTS[@]}"; do
    php -m 2>/dev/null | grep -qi "^${ext}$" || MISSING_EXTS+=("${ext}")
done
if [[ "${#MISSING_EXTS[@]}" -gt 0 ]]; then
    die "missing PHP extensions: ${MISSING_EXTS[*]}"
fi

# PHP-FPM
FPM_SVC=""
if command -v systemctl >/dev/null 2>&1; then
    for svc in php8.3-fpm php83-php-fpm php-fpm83 php83-fpm php8-fpm php-fpm; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
            FPM_SVC="${svc}"; break
        fi
    done
fi
[[ -n "${FPM_SVC}" ]] && run "Enabling PHP-FPM (${FPM_SVC})" systemctl enable --now "${FPM_SVC}"

FPM_SOCK=""
for sock in \
    /run/php/php8.3-fpm.sock \
    /var/run/php/php8.3-fpm.sock \
    /run/php-fpm/www.sock \
    /run/php/php-fpm.sock \
    /run/php83-fpm.sock \
    /var/run/php-fpm/php-fpm.sock
do
    [[ -S "${sock}" ]] && { FPM_SOCK="${sock}"; break; }
done
[[ -z "${FPM_SOCK}" ]] && die "PHP-FPM socket not found - check that php-fpm is running"

# Composer
export COMPOSER_NO_INTERACTION=1
export COMPOSER_ALLOW_SUPERUSER=1
if ! command -v composer >/dev/null 2>&1; then
    run "Downloading Composer installer" \
        curl -fsSL -o /tmp/composer-setup.php https://getcomposer.org/installer
    run "Installing Composer" \
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
fi

# Nginx
command -v nginx >/dev/null 2>&1 || run "Installing Nginx" pm_install nginx

# WemX
mkdir -p "${TARGET_DIR}"
run "Downloading WemX" curl -fsSL -o "${WEMX_TMP_ZIP}" https://github.com/wemxnet/wemx/releases/latest/download/wemx.zip
run "Extracting WemX"  unzip -o "${WEMX_TMP_ZIP}" -d "${TARGET_DIR}"
rm -f "${WEMX_TMP_ZIP}"

if [[ ! -f "${TARGET_DIR}/artisan" ]]; then
    shopt -s nullglob
    entries=("${TARGET_DIR}"/*)
    shopt -u nullglob
    if [[ "${#entries[@]}" -eq 1 && -d "${entries[0]}" ]]; then
        sub="${entries[0]}"
        shopt -s dotglob nullglob
        sub_entries=("${sub}"/*)
        [[ "${#sub_entries[@]}" -gt 0 ]] && mv "${sub_entries[@]}" "${TARGET_DIR}/"
        shopt -u dotglob nullglob
        rmdir "${sub}"
    fi
fi
[[ -f "${TARGET_DIR}/artisan" ]] || die "artisan not found in ${TARGET_DIR} - extraction failed"

[[ -d "${TARGET_DIR}/vendor" ]] || \
    run "Running composer install" \
        composer install --no-dev --optimize-autoloader --working-dir="${TARGET_DIR}"

[[ -f "${TARGET_DIR}/.env" ]] || run "Creating .env" cp "${TARGET_DIR}/.env.example" "${TARGET_DIR}/.env"
sed -i "s|^APP_URL=.*|APP_URL=http://${DOMAIN}|" "${TARGET_DIR}/.env"
run "Generating app key" php "${TARGET_DIR}/artisan" key:generate --force
run "Linking storage"    php "${TARGET_DIR}/artisan" storage:link  --force

# Permissions
WEB_USER="www-data"
WEB_GROUP="www-data"
for u in www-data nginx apache; do
    if id "${u}" >/dev/null 2>&1; then
        WEB_USER="${u}"; WEB_GROUP="${u}"; break
    fi
done
run "Setting permissions" chmod -R 755 "${TARGET_DIR}/storage" "${TARGET_DIR}/bootstrap/cache"
run "Setting ownership"   chown -R "${WEB_USER}:${WEB_GROUP}" "${TARGET_DIR}"

# Nginx config
NGINX_CONF_NAME="wemx-${DOMAIN}"
if [[ -d /etc/nginx/sites-available ]]; then
    NGINX_CONF="/etc/nginx/sites-available/${NGINX_CONF_NAME}"
else
    mkdir -p /etc/nginx/conf.d
    NGINX_CONF="/etc/nginx/conf.d/${NGINX_CONF_NAME}.conf"
fi

cat > "${NGINX_CONF}" <<NGINX
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
        fastcgi_pass unix:${FPM_SOCK};
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
NGINX

if [[ -d /etc/nginx/sites-enabled ]]; then
    ln -sf "${NGINX_CONF}" "/etc/nginx/sites-enabled/${NGINX_CONF_NAME}"
    rm -f /etc/nginx/sites-enabled/default
fi
run "Testing Nginx config" nginx -t
if command -v systemctl >/dev/null 2>&1; then
    run "Enabling Nginx"  systemctl enable --now nginx
    run "Reloading Nginx" systemctl reload nginx
else
    run "Reloading Nginx" nginx -s reload
fi

# SSL
SSL_OK=false
if [[ "${SSL}" == true ]]; then
    if ! command -v certbot >/dev/null 2>&1; then
        run "Installing certbot" pm_install certbot python3-certbot-nginx
    fi
    CERTBOT_ARGS=(--nginx -d "${DOMAIN}" --non-interactive --agree-tos --redirect)
    if [[ -n "${SSL_EMAIL}" ]]; then
        CERTBOT_ARGS+=(--email "${SSL_EMAIL}")
    else
        CERTBOT_ARGS+=(--register-unsafely-without-email)
    fi
    if certbot "${CERTBOT_ARGS[@]}" >>"${LOG}" 2>&1; then
        SSL_OK=true
        success "SSL certificate obtained"
        sed -i "s|^APP_URL=.*|APP_URL=https://${DOMAIN}|" "${TARGET_DIR}/.env"
    else
        warn "SSL certificate failed - WemX is installed but running HTTP only"
        warn "Run manually: certbot --nginx -d ${DOMAIN}"
    fi
fi

# Cron
CRON_LINE="* * * * * php ${TARGET_DIR}/artisan schedule:run >> /dev/null 2>&1"
if ! crontab -l 2>/dev/null | grep -qF "${CRON_LINE}"; then
    _cron_add() { { crontab -l 2>/dev/null || true; printf '%s\n' "${CRON_LINE}"; } | crontab -; }
    run "Adding scheduler cron entry" _cron_add
fi

# Queue worker
if command -v systemctl >/dev/null 2>&1 && \
   ! systemctl list-unit-files 2>/dev/null | grep -q "^wemx\.service"; then
    PHP_BIN="$(command -v php)"
    cat > /etc/systemd/system/wemx.service <<SYSTEMD
[Unit]
Description=WemX Queue Worker

[Service]
User=${WEB_USER}
Group=${WEB_GROUP}
Restart=always
ExecStart=${PHP_BIN} ${TARGET_DIR}/artisan queue:work
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
SYSTEMD
    run "Reloading systemd"     systemctl daemon-reload
    run "Enabling queue worker" systemctl enable --now wemx
fi

printf '\n'
success "WemX has been installed successfully"
printf '\n'
printf '%bOpen your browser to complete setup:%b\n' "${BOLD}" "${RESET}"
printf '  http://%s\n' "${DOMAIN}"
[[ "${SSL_OK}" == true ]] && printf '  https://%s\n' "${DOMAIN}"
