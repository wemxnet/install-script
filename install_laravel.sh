#!/usr/bin/env bash
set -euo pipefail

APP_REPO="https://github.com/laravel/laravel.git"
DEFAULT_TARGET_DIR="/var/www/laravel"
DEFAULT_DOMAIN="laravel.local"
PHP_MIN_VERSION="8.3.0"
SSL_DIR="/etc/ssl/laravel"

PKG_MANAGER=""
SUDO=""
TARGET_DIR=""
DOMAIN=""
APT_UPDATED="false"

PHP_REQUIRED_EXTENSIONS=(
  "bcmath"
  "ctype"
  "fileinfo"
  "json"
  "mbstring"
  "openssl"
  "pdo"
  "tokenizer"
  "xml"
  "curl"
  "zip"
)

COLOR_RESET="\033[0m"
COLOR_BOLD="\033[1m"
COLOR_DIM="\033[2m"
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_CYAN="\033[36m"

print_banner() {
  printf "\n${COLOR_BOLD}${COLOR_CYAN}==============================================${COLOR_RESET}\n"
  printf "${COLOR_BOLD}${COLOR_CYAN}      Laravel Universal Linux Installer      ${COLOR_RESET}\n"
  printf "${COLOR_BOLD}${COLOR_CYAN}==============================================${COLOR_RESET}\n\n"
}

step() {
  printf "${COLOR_BOLD}${COLOR_BLUE}[STEP]${COLOR_RESET} %s\n" "$1"
}

ok() {
  printf "${COLOR_GREEN}[ OK ]${COLOR_RESET} %s\n" "$1"
}

warn() {
  printf "${COLOR_YELLOW}[WARN]${COLOR_RESET} %s\n" "$1"
}

error() {
  printf "${COLOR_RED}[FAIL]${COLOR_RESET} %s\n" "$1" >&2
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "Missing required command: $1"
    exit 1
  fi
}

run() {
  printf "${COLOR_DIM} -> %s${COLOR_RESET}\n" "$*"
  "$@"
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  else
    error "No supported package manager found (apt, dnf, yum, pacman, zypper, apk)."
    exit 1
  fi
}

ensure_sudo() {
  if [[ "${EUID}" -ne 0 ]]; then
    SUDO="sudo"
    require_cmd sudo
  fi
}

prompt_user_inputs() {
  read -r -p "Domain/hostname [${DEFAULT_DOMAIN}]: " DOMAIN
  DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"

  read -r -p "Target directory [${DEFAULT_TARGET_DIR}]: " TARGET_DIR
  TARGET_DIR="${TARGET_DIR:-$DEFAULT_TARGET_DIR}"

  ok "Using domain: ${DOMAIN}"
  ok "Using target directory: ${TARGET_DIR}"
}

version_gte() {
  local current="$1"
  local minimum="$2"
  [[ "$(printf '%s\n%s\n' "$minimum" "$current" | sort -V | head -n1)" == "$minimum" ]]
}

php_version() {
  php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION.".".PHP_RELEASE_VERSION;'
}

is_extension_loaded() {
  local extension="$1"
  php -m | awk '{print tolower($0)}' | grep -qx "${extension,,}"
}

install_packages() {
  case "$PKG_MANAGER" in
    apt)
      if [[ "$APT_UPDATED" != "true" ]]; then
        run $SUDO apt-get update
        APT_UPDATED="true"
      fi
      run $SUDO apt-get install -y "$@"
      ;;
    dnf)
      run $SUDO dnf install -y "$@"
      ;;
    yum)
      run $SUDO yum install -y "$@"
      ;;
    pacman)
      run $SUDO pacman -Sy --noconfirm "$@"
      ;;
    zypper)
      run $SUDO zypper --non-interactive install "$@"
      ;;
    apk)
      run $SUDO apk add --no-cache "$@"
      ;;
    *)
      error "Unsupported package manager: $PKG_MANAGER"
      exit 1
      ;;
  esac
}

ensure_base_packages() {
  step "Installing base system tools if missing"
  local packages=()

  if ! command -v git >/dev/null 2>&1; then
    packages+=("git")
  else
    ok "git is already installed"
  fi

  if ! command -v curl >/dev/null 2>&1; then
    packages+=("curl")
  else
    ok "curl is already installed"
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    packages+=("openssl")
  else
    ok "openssl is already installed"
  fi

  case "$PKG_MANAGER" in
    apt)
      packages+=("ca-certificates" "unzip")
      ;;
    dnf|yum|pacman|zypper|apk)
      packages+=("unzip")
      ;;
  esac

  if [[ ${#packages[@]} -gt 0 ]]; then
    install_packages "${packages[@]}"
  fi

  require_cmd git
  require_cmd curl
  require_cmd openssl
}

install_php_and_extensions() {
  step "Checking PHP and required extensions"

  local php_ok="false"
  if command -v php >/dev/null 2>&1; then
    local current_version
    current_version="$(php_version)"
    if version_gte "$current_version" "$PHP_MIN_VERSION"; then
      ok "PHP ${current_version} is already installed (>= ${PHP_MIN_VERSION})"
      php_ok="true"
    else
      warn "PHP ${current_version} detected but ${PHP_MIN_VERSION}+ is required"
    fi
  else
    warn "PHP not found"
  fi

  if [[ "$php_ok" != "true" ]]; then
    step "Installing PHP ${PHP_MIN_VERSION}+ and common Laravel extensions"
    case "$PKG_MANAGER" in
      apt)
        install_packages software-properties-common ca-certificates lsb-release apt-transport-https gnupg
        if ! apt-cache policy php8.3 | grep -q "Candidate:"; then
          warn "php8.3 package not present in current apt sources; trying default php packages"
          install_packages php php-cli php-fpm php-mbstring php-xml php-bcmath php-curl php-zip php-mysql unzip
        else
          install_packages php8.3 php8.3-cli php8.3-fpm php8.3-mbstring php8.3-xml php8.3-bcmath php8.3-curl php8.3-zip php8.3-mysql unzip
        fi
        ;;
      dnf|yum)
        install_packages php php-cli php-fpm php-mbstring php-xml php-bcmath php-curl php-zip php-mysqlnd unzip
        ;;
      pacman)
        install_packages php php-fpm unzip
        ;;
      zypper)
        install_packages php8 php8-fpm php8-mbstring php8-xml php8-bcmath php8-curl php8-zip unzip
        ;;
      apk)
        install_packages php83 php83-fpm php83-mbstring php83-xml php83-bcmath php83-curl php83-zip unzip
        ;;
    esac
  fi

  if ! command -v php >/dev/null 2>&1; then
    error "PHP installation failed"
    exit 1
  fi

  local post_install_version
  post_install_version="$(php_version)"
  if ! version_gte "$post_install_version" "$PHP_MIN_VERSION"; then
    error "Installed PHP version (${post_install_version}) is still below ${PHP_MIN_VERSION}"
    error "Use a distro repository that provides PHP ${PHP_MIN_VERSION}+ and re-run."
    exit 1
  fi
  ok "PHP version check passed: ${post_install_version}"

  local missing=()
  local ext
  for ext in "${PHP_REQUIRED_EXTENSIONS[@]}"; do
    if is_extension_loaded "$ext"; then
      ok "PHP extension loaded: ${ext}"
    else
      warn "PHP extension missing: ${ext}"
      missing+=("$ext")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    step "Installing missing PHP extensions"
    case "$PKG_MANAGER" in
      apt)
        local apt_ext_pkgs=()
        for ext in "${missing[@]}"; do
          apt_ext_pkgs+=("php8.3-${ext}")
        done
        if ! install_packages "${apt_ext_pkgs[@]}"; then
          warn "Some php8.3-* extension packages failed; trying generic php-* fallback"
          apt_ext_pkgs=()
          for ext in "${missing[@]}"; do
            apt_ext_pkgs+=("php-${ext}")
          done
          install_packages "${apt_ext_pkgs[@]}"
        fi
        ;;
      dnf|yum)
        local rpm_ext_pkgs=()
        for ext in "${missing[@]}"; do
          case "$ext" in
            pdo|json|ctype|fileinfo|tokenizer|openssl)
              ;;
            *)
              rpm_ext_pkgs+=("php-${ext}")
              ;;
          esac
        done
        if [[ ${#rpm_ext_pkgs[@]} -gt 0 ]]; then
          install_packages "${rpm_ext_pkgs[@]}"
        fi
        ;;
      pacman|zypper|apk)
        warn "Extension packaging differs on this distro. Installed base PHP packages; re-checking module availability."
        ;;
    esac
  fi

  local final_missing=()
  for ext in "${PHP_REQUIRED_EXTENSIONS[@]}"; do
    if ! is_extension_loaded "$ext"; then
      final_missing+=("$ext")
    fi
  done

  if [[ ${#final_missing[@]} -gt 0 ]]; then
    error "Some required PHP extensions are still missing: ${final_missing[*]}"
    exit 1
  fi
  ok "All required PHP extensions are available"
}

install_composer() {
  step "Checking Composer"
  if command -v composer >/dev/null 2>&1; then
    ok "Composer is already installed: $(composer --version | head -n1)"
    return
  fi

  step "Installing Composer"
  require_cmd php
  require_cmd curl

  local installer
  installer="$(mktemp)"
  run curl -fsSL https://getcomposer.org/installer -o "$installer"
  run php "$installer" --quiet
  rm -f "$installer"
  run $SUDO mv composer.phar /usr/local/bin/composer
  run $SUDO chmod +x /usr/local/bin/composer
  ok "Composer installed successfully: $(composer --version | head -n1)"
}

prepare_target_dir() {
  step "Preparing target directory"
  local created_dir="false"
  if [[ -d "$TARGET_DIR" ]] && [[ -n "$(ls -A "$TARGET_DIR" 2>/dev/null || true)" ]]; then
    warn "Target directory is not empty: $TARGET_DIR"
    read -r -p "Continue and reuse this directory? [y/N]: " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      error "Installation aborted by user"
      exit 1
    fi
  else
    run $SUDO mkdir -p "$TARGET_DIR"
    created_dir="true"
  fi

  local active_user="${SUDO_USER:-$USER}"
  if [[ "$created_dir" == "true" ]]; then
    run $SUDO chown "$active_user":"$active_user" "$TARGET_DIR"
  else
    ok "Leaving ownership unchanged for existing directory"
  fi
  ok "Target directory ready"
}

is_existing_laravel_project() {
  [[ -f "$TARGET_DIR/artisan" && -f "$TARGET_DIR/composer.json" ]]
}

clone_and_install_laravel() {
  step "Cloning Laravel application"
  if is_existing_laravel_project; then
    ok "Existing Laravel project detected, reusing it"
    if [[ -d "$TARGET_DIR/.git" ]]; then
      local repo_origin
      repo_origin="$(git -C "$TARGET_DIR" remote get-url origin 2>/dev/null || true)"
      if [[ "$repo_origin" == "$APP_REPO" ]]; then
        read -r -p "Pull latest changes from laravel/laravel? [y/N]: " pull_answer
        if [[ "$pull_answer" =~ ^[Yy]$ ]]; then
          run git -C "$TARGET_DIR" pull --ff-only
        fi
      fi
    fi
  elif [[ -n "$(ls -A "$TARGET_DIR" 2>/dev/null || true)" ]]; then
    error "Target directory is not empty and does not look like a Laravel project."
    error "Use an empty directory or point to an existing Laravel project."
    exit 1
  else
    run git clone "$APP_REPO" "$TARGET_DIR"
  fi

  if [[ ! -f "$TARGET_DIR/composer.json" || ! -f "$TARGET_DIR/artisan" ]]; then
    error "No Laravel project found in $TARGET_DIR after clone/reuse step."
    exit 1
  fi

  step "Installing Laravel dependencies with Composer"
  (
    cd "$TARGET_DIR"
    run composer install --no-interaction --prefer-dist --optimize-autoloader
    if [[ ! -f .env && -f .env.example ]]; then
      run cp .env.example .env
    fi
    if [[ -f .env ]]; then
      if ! grep -Eq '^APP_KEY=base64:' .env; then
        run php artisan key:generate --force
      else
        ok "APP_KEY already set in .env, skipping key generation"
      fi
    else
      warn ".env not found (and no .env.example to copy); skipping APP_KEY generation"
    fi
    run mkdir -p storage/logs bootstrap/cache
    run chmod -R ug+rwx storage bootstrap/cache || true
  )
  ok "Laravel project is ready"
}

install_nginx_if_missing() {
  if command -v nginx >/dev/null 2>&1; then
    ok "Nginx is already installed"
    return
  fi

  step "Installing Nginx for HTTPS serving"
  case "$PKG_MANAGER" in
    apt|dnf|yum|pacman|zypper|apk)
      install_packages nginx
      ;;
    *)
      error "Cannot install nginx on unsupported package manager: $PKG_MANAGER"
      exit 1
      ;;
  esac
}

enable_and_restart_service() {
  local service_name="$1"
  if command -v systemctl >/dev/null 2>&1; then
    run $SUDO systemctl enable "$service_name"
    run $SUDO systemctl restart "$service_name"
  elif command -v service >/dev/null 2>&1; then
    run $SUDO service "$service_name" restart
  else
    warn "No recognized service manager found; restart ${service_name} manually if needed."
  fi
}

detect_php_fpm_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    printf "php-fpm"
    return
  fi

  local candidates=(
    "php8.4-fpm"
    "php8.3-fpm"
    "php8.2-fpm"
    "php8.1-fpm"
    "php-fpm"
    "php83-php-fpm"
    "php84-php-fpm"
  )
  local service_name
  for service_name in "${candidates[@]}"; do
    if $SUDO systemctl list-unit-files | awk '{print $1}' | grep -qx "${service_name}.service"; then
      printf "%s" "$service_name"
      return
    fi
  done
  printf ""
}

detect_php_fpm_socket() {
  local candidates=(
    "/run/php/php8.4-fpm.sock"
    "/run/php/php8.3-fpm.sock"
    "/run/php/php8.2-fpm.sock"
    "/run/php/php8.1-fpm.sock"
    "/run/php-fpm/www.sock"
    "/run/php-fpm/php-fpm.sock"
    "/run/php-fpm83/php-fpm.sock"
    "/var/run/php-fpm/www.sock"
  )
  local socket_path
  for socket_path in "${candidates[@]}"; do
    if [[ -S "$socket_path" ]]; then
      printf "%s" "$socket_path"
      return
    fi
  done
  printf ""
}

generate_ssl_and_nginx_config() {
  step "Generating SSL certificate"
  require_cmd openssl

  run $SUDO mkdir -p "$SSL_DIR"
  local cert_path="${SSL_DIR}/${DOMAIN}.crt"
  local key_path="${SSL_DIR}/${DOMAIN}.key"

  run $SUDO openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout "$key_path" \
    -out "$cert_path" \
    -subj "/CN=${DOMAIN}"
  ok "SSL certificate created at ${cert_path}"

  install_nginx_if_missing

  local nginx_conf="/etc/nginx/conf.d/laravel-${DOMAIN}.conf"
  local php_fpm_service
  php_fpm_service="$(detect_php_fpm_service)"
  if [[ -n "$php_fpm_service" ]]; then
    enable_and_restart_service "$php_fpm_service"
  else
    warn "Could not auto-detect PHP-FPM service name; continuing"
  fi

  local php_socket
  php_socket="$(detect_php_fpm_socket)"
  if [[ -z "$php_socket" ]]; then
    warn "Could not auto-detect PHP-FPM socket. Falling back to 127.0.0.1:9000."
    php_socket="127.0.0.1:9000"
  fi
  local php_fastcgi_pass="$php_socket"
  if [[ "$php_socket" == /* ]]; then
    php_fastcgi_pass="unix:${php_socket}"
  fi

  step "Writing Nginx HTTPS site configuration"
  run $SUDO tee "$nginx_conf" >/dev/null <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    root ${TARGET_DIR}/public;
    index index.php index.html;

    ssl_certificate     ${cert_path};
    ssl_certificate_key ${key_path};

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;
        fastcgi_pass ${php_fastcgi_pass};
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

  step "Testing and reloading Nginx"
  run $SUDO nginx -t

  enable_and_restart_service "nginx"
  ok "Nginx is serving Laravel over HTTPS"
}

final_output() {
  printf "\n${COLOR_BOLD}${COLOR_GREEN}Laravel installation completed successfully.${COLOR_RESET}\n"
  printf "${COLOR_BOLD}Project path:${COLOR_RESET} %s\n" "$TARGET_DIR"
  printf "${COLOR_BOLD}HTTPS URL:${COLOR_RESET} https://%s\n" "$DOMAIN"
  printf "${COLOR_BOLD}HTTP URL:${COLOR_RESET}  http://%s (redirects to HTTPS)\n" "$DOMAIN"
  printf "\n${COLOR_DIM}If your DNS does not point to this machine yet, add an /etc/hosts entry for %s.${COLOR_RESET}\n" "$DOMAIN"
}

main() {
  print_banner
  ensure_sudo
  detect_pkg_manager
  ensure_base_packages

  prompt_user_inputs
  install_php_and_extensions
  install_composer
  prepare_target_dir
  clone_and_install_laravel
  generate_ssl_and_nginx_config
  final_output
}

main "$@"
