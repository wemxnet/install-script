# WemX v3 Installer

One-command installer for [WemX](https://v3.wemx.net/docs).

```bash
bash <(curl -s https://sh.wemx.net/install.sh)
```

Run it as root. The installer:

1. Checks the system (OS, architecture, memory, disk, internet, port conflicts) and lists which components are already installed.
2. Asks for your domain, install directory, web server (Nginx or Apache), database (MariaDB/MySQL, PostgreSQL, or none) and SSL.
3. Installs only what is missing: PHP 8.3+ with the required extensions, Composer, the web server, the database server and Certbot.
4. Downloads the latest WemX release from GitHub, creates `.env`, generates `APP_KEY` and sets permissions (including SELinux contexts on RHEL-based systems).
5. Writes the web server site config, the scheduler (`/etc/cron.d/wemx`) and the queue worker (`wemx.service`).
6. Opens ports 80/443 in UFW or firewalld if one is active, and requests a Let's Encrypt certificate.
7. Prints the database credentials and the link to the web installer (`/install`). They are also saved to `/root/wemx-install-info.txt`.

## Supported systems

| Family | Versions |
| --- | --- |
| Ubuntu | 22.04, 24.04 and newer |
| Debian | 11, 12, 13 |
| RHEL / Rocky / AlmaLinux / Oracle / CentOS Stream | 8, 9, 10 |
| Fedora | 40+ |

x86_64 and arm64. Other Debian or RHEL derivatives work with a warning.

## Unattended install

```bash
bash <(curl -s https://sh.wemx.net/install.sh) -y \
  --domain panel.example.com --webserver nginx --database mysql \
  --ssl --email you@example.com
```

| Option | Description |
| --- | --- |
| `-d, --domain` | Domain (or IP) WemX will be served on |
| `--dir` | Install directory (default `/var/www/wemx`) |
| `--webserver` | `nginx` or `apache` |
| `--database` | `mysql`, `pgsql` or `none` |
| `--ssl` / `--no-ssl` | Request a Let's Encrypt certificate or not |
| `--email` | Email for Let's Encrypt notices |
| `--php` | Force a PHP version, e.g. `8.4` |
| `--version` | Install a specific WemX release tag |
| `-y, --yes` | Non-interactive, accept defaults |
| `--force` | Continue on an unsupported OS or non-empty directory |
| `--no-color`, `--no-animation` | Plain output (useful for CI logs) |

`GITHUB_TOKEN` can be set to avoid GitHub API rate limits.

The installer log is written to `/var/log/wemx-install.log`.
