# Faveo Helpdesk on Docker - Installation Guide   <!-- omit in toc -->

<img src="https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4e/Docker_%28container_engine%29_logo.svg/960px-Docker_%28container_engine%29_logo.svg.png?utm_source=commons.wikimedia.org&utm_campaign=index&utm_content=thumbnail" alt="Docker" width="220"/>

This guide explains how to install **Faveo Helpdesk** (paid editions) on Docker with the installer **`faveo-run.sh`**: every way to run it, every option, what is required, what the installer does, and what happens when something goes wrong.

> Using the free **Community Edition**? It has its own script - see [Community Edition](#18-community-edition).

---

## Contents   <!-- omit in toc -->

1. [What the installer does](#1-what-the-installer-does)
2. [Requirements](#2-requirements)
3. [Required information (fields)](#3-required-information-fields)
4. [Download the installer](#4-download-the-installer)
5. [Ways to install](#5-ways-to-install)
6. [All options in detail](#6-all-options-in-detail)
7. [What happens during the installation](#7-what-happens-during-the-installation)
8. [Automatic Faveo setup and license verification](#8-automatic-faveo-setup-and-license-verification)
9. [What is created on the server](#9-what-is-created-on-the-server)
10. [Wrong values - how the installer reacts](#10-wrong-values---how-the-installer-reacts)
11. [When the installation fails - rollback](#11-when-the-installation-fails---rollback)
12. [After the installation](#12-after-the-installation)
13. [Backup and restore](#13-backup-and-restore)
14. [Removing an installation](#14-removing-an-installation)
15. [Troubleshooting](#15-troubleshooting)
16. [Examples](#16-examples)
17. [FAQ](#17-faq)
18. [Community Edition](#18-community-edition)

---

## 1. What the installer does

One command takes a plain Linux server to a running Faveo Helpdesk:

- installs the tools it needs and **Docker** (if missing)
- creates the **SSL certificate** (Let's Encrypt, self-signed, or your paid certificate)
- downloads **Faveo Helpdesk** with your license
- builds and starts **5 containers**
- runs the **Faveo installation** (`php artisan install:faveo`) and **verifies your license**
- can later **back up** and **remove** the installation

Containers created for each installation (`<domain>` = your domain name):

| Container | Purpose |
|---|---|
| `<domain>-apache` | Web server with PHP - serves Faveo |
| `<domain>-mysql` | MySQL 8.4 database (not created when you use your own database server) |
| `<domain>-redis` | Cache and job queue |
| `<domain>-supervisor` | Background workers (queues, scheduled tasks, WebSocket) |
| `<domain>-meilisearch` | Search engine |

---

## 2. Requirements

| Requirement | Details |
|---|---|
| **Operating system** | 64-bit Linux - see the [supported operating systems](#21-supported-operating-systems) below. |
| **Processor** | x86_64 (Intel / AMD) or ARM64 (aarch64). 32-bit systems are not supported. |
| **Access** | Root, or a user with `sudo`. |
| **Internet** | Needed to download packages, Docker images and Faveo (or see [offline install](#e-offline-install-with-a-downloaded-faveo-archive)). |
| **Domain name** | A DNS A record pointing to the server's public IP. Required for Let's Encrypt; for self-signed / paid SSL any name works (test domains can use the hosts file). |
| **Ports** | 80 and 443 free (other ports possible with self-signed or paid SSL). Open them in the firewall / cloud security group. |
| **Docker** | Not required beforehand - the installer installs Docker Engine, Docker Compose and Docker Buildx for your OS. |
| **SELinux** | Can stay in *Enforcing* mode - handled automatically. |
| **Windows / macOS** | Not supported directly. On Windows use WSL2 with Ubuntu (for testing). |

### 2.1 Supported operating systems

⭐ **Recommended for production** - long-term support releases:

| Operating system | Versions | Docker installed from |
|---|---|---|
| ⭐ **AlmaLinux** | 8, 9, 10 | Docker official repository |
| ⭐ **Rocky Linux** | 8, 9, 10 | Docker official repository |
| ⭐ **Red Hat Enterprise Linux (RHEL)** | 8, 9, 10 *(10 needs an active Red Hat subscription)* | Docker official repository |
| ⭐ **Ubuntu LTS** | 22.04, 24.04, 26.04 | Docker official repository |
| ⭐ **Debian** | 12 (Bookworm), 13 (Trixie) | Docker official repository |

Also supported:

| Operating system | Versions | Docker installed from | Note |
|---|---|---|---|
| Ubuntu (other releases) | 20.04, 25.04 | Docker official repository | 25.04 is not LTS; 20.04 is out of standard support |
| Oracle Linux | 8, 9, 10 | Docker official repository | |
| CentOS Stream | 9, 10 | Docker official repository | Rolling preview of RHEL |
| Fedora | 41, 42, 43 | Docker official repository | Short support cycle |
| Amazon Linux | 2023, 2 | Amazon repository | Amazon Linux 2 reached end of life in June 2026 |
| Linux Mint | 21.3, 22 | Docker official repository | Desktop distribution |
| Kali Linux | Rolling | Docker official repository | Desktop / security distribution |
| openSUSE Leap | 15.6, 16.0 | openSUSE repository | |
| openSUSE Tumbleweed | Rolling | openSUSE repository | |
| SUSE Linux Enterprise Server | 15 SP7 | SUSE repository | Enable the Containers Module first: `SUSEConnect -p sle-module-containers/<version>/<arch>` |
| Arch Linux / Manjaro | Rolling | Distribution repository | |
| Alpine Linux | 3.19, 3.20, 3.21, 3.22 | Alpine repository | Install bash first: `apk add bash` |
| Void Linux | Rolling | Void repository | |

Not supported:

| System | Why |
|---|---|
| Windows, macOS | The installer is a Linux script. On Windows 10/11, WSL2 with Ubuntu can be used for testing only. |
| End-of-life releases (Debian 11, CentOS 7 / 8, Ubuntu 18.04 ...) | Their package mirrors are archived or broken. |
| Gentoo, NixOS, Slackware, Clear Linux | No automatic installation. They work only if Docker, Docker Compose, curl, unzip, openssl, cron and find are installed beforehand. |
| 32-bit systems (i386, armv7) and ppc64le, s390x, riscv64 | The MySQL 8.4 and Meilisearch images exist only for x86_64 and ARM64. |

Processors: **x86_64** (Intel / AMD) and **ARM64** (AWS Graviton, Oracle Ampere, Raspberry Pi 4/5 with a 64-bit OS) - all images and the ionCube loader exist for both.

---

## 3. Required information (fields)

These five values are always needed. Missing ones are asked for; give them all on the command line to install without any question.

| Field | Option | Rules | Example | Where to get it |
|---|---|---|---|---|
| **Domain name** | `-d`, `--domain` | Letters, digits, `-` and `.` - no `https://`, no `_` | `helpdesk.example.com` | Your DNS provider |
| **Email** | `-e`, `--email` | A valid email address | `admin@example.com` | Your email - also used by Let's Encrypt for expiry notices |
| **License code** | `-l`, `--license` | Letters, digits and `-` (16 characters for license verification) | `ABC1D23EFJH50000` | [billing.faveohelpdesk.com](https://billing.faveohelpdesk.com) |
| **Order number** | `-o`, `--order` | Letters, digits and `-`; a leading `#` is removed | `45894483` | [billing.faveohelpdesk.com](https://billing.faveohelpdesk.com) |
| **SSL type** | `-s`, `--ssl` | `certbot`, `self-signed` or `paid-ssl` (or `A`, `B`, `C`) | `certbot` | Your choice - see [SSL](#62-ssl-certificate) |

Required **only in some cases**:

| Case | Required fields |
|---|---|
| `--ssl paid-ssl` | `--certfile`, `--keyfile`, `--cacertfile` (asked for if missing; required with `-y`) |
| Your own database server (`--db remote` or `--db-host`) | `--db-host`, `--db-admin-password` (asked for if missing; required with `-y`) |
| Remote database over SSL (`--db-ssl yes`) | `--db-ssl-ca` |

---

## 4. Download the installer

```sh
git clone https://github.com/ladybirdweb/faveo-helpdesk-docker-v2.git
cd faveo-helpdesk-docker-v2/faveo-helpdesk-docker
chmod +x faveo-run.sh
```

The installer uses the Dockerfiles and templates in this folder and **copies** them into the installation folder. This folder is never changed, so you can install several domains from it.

---

## 5. Ways to install

### A. Interactive - answer questions

```sh
sudo ./faveo-run.sh
```

The installer asks, one by one:

| Question | Purpose | Default (Enter) |
|---|---|---|
| Domain name | Address of the helpdesk | - |
| Email address | Admin / Let's Encrypt email | - |
| License code, Order number | Download and license verification | - |
| Release | `official`, `rc` or `beta` version of Faveo | official |
| Application environment | `production`, `development` or `testing` | production |
| SSL certificate | Let's Encrypt, self-signed or paid | - |
| Certificate files *(paid SSL only)* | Path, pasted PEM text or base64 | - |
| Enable WebSocket | Live updates in the browser | No |
| Database location | Local MySQL container or your own server | Local |
| Customize database name / user / password | Change the defaults | No |
| Installation path | Where the installation is created | `/opt/faveo/<domain>` |
| Custom ports | Shows the ports and whether they are free | No (80 / 443 / 9001) |
| Custom subnet | Docker network range | No (first free from 172.24.0.0/16) |

A wrong answer is explained and asked again (up to 3 times). At the end a **summary** is shown and you confirm with **y**. Nothing is changed before that.

### B. One command, no questions

```sh
sudo ./faveo-run.sh -d helpdesk.example.com -e admin@example.com -l ABC1D23EFJH50000 -o 45894483 -s certbot --install-docker
```

When all [required fields](#3-required-information-fields) are given, the installer runs straight through - no questions and no confirmation. Any option you leave out uses its default. `--install-docker` lets it install Docker when the server does not have it.

### C. One command, but review the summary first

```sh
sudo ./faveo-run.sh -d helpdesk.example.com -e admin@example.com -l ABC1D23EFJH50000 -o 45894483 -s certbot --confirm
```

Same as B, but shows the summary and waits for **y**.

### D. Generate the files only, review, then start

```sh
sudo ./faveo-run.sh -d helpdesk.example.com -e admin@example.com -l XXXX -o 1234 -s self-signed -g -i /root/faveo-preview
```

Creates `docker-compose.yml`, `.env`, the Apache / Supervisor configuration and Dockerfiles - but requests no certificate, downloads nothing and starts no container. Useful to review or customise before a real installation.

### E. Offline install with a downloaded Faveo archive

```sh
sudo FAVEO_ZIP_FILE=/root/faveo.zip ./faveo-run.sh -d helpdesk.example.com -e admin@example.com -l XXXX -o 1234 -s self-signed
```

Uses the given Faveo archive instead of downloading it from billing.faveohelpdesk.com. (Docker images and OS packages still need internet, or a local mirror.)

### F. Old-style options

The options of the previous script still work:

```sh
sudo ./faveo-run.sh -domainname helpdesk.example.com -email admin@example.com -license XXXX -orderno 1234 -ssl A -websocket y
```

---

## 6. All options in detail

Options can be combined in any order. `--option value` and `--option=value` both work.

### 6.1 Required

| Option | Purpose | Values | If wrong |
|---|---|---|---|
| `-d`, `--domain` | Domain of the helpdesk; also names the containers (`<domain>-apache` ...) | e.g. `helpdesk.example.com` | Stops: *"not a valid domain name"* |
| `-e`, `--email` | Admin / Let's Encrypt email | valid email | Stops: *"not a valid email address"* |
| `-l`, `--license` | Download Faveo and verify the license | letters, digits, `-` | Stops before anything is changed. A code that is valid but not 16 characters installs, but license verification is skipped |
| `-o`, `--order` | Download Faveo | letters, digits, `-` | Stops. A wrong (but valid-looking) license/order makes the **download fail** → automatic rollback |
| `-s`, `--ssl` | SSL certificate type | `certbot`, `self-signed`, `paid-ssl` / `A`, `B`, `C` | Stops: *"use certbot, self-signed or paid-ssl"* |

### 6.2 SSL certificate

| Type | Use it when | What happens | Needs |
|---|---|---|---|
| `certbot` (A) | Real domain reachable from the internet | Let's Encrypt certificate is requested; renewed weekly by cron; Apache reloads after renewal | Domain points to the server, ports **80 and 443** free and open (custom ports not allowed) |
| `self-signed` (B) | Testing, internal servers, custom ports | A certificate is generated; browsers show a warning. Import `ssl_copy/faveorootCA.crt` into browsers to trust it | Nothing |
| `paid-ssl` (C) | You bought a certificate | Your files are checked and installed | The three files below |

Paid SSL files - each value can be a **file path**, the **PEM text** itself, or the PEM **base64-encoded** (handy for automation):

| Option | Purpose | Alias |
|---|---|---|
| `--certfile` | Your certificate (`certificate.crt`) | `--ssl-cert` |
| `--keyfile` | Its private key (`private.key`) | `--ssl-key` |
| `--cacertfile` | CA bundle / intermediate chain (`ca_bundle.crt`) | `--ssl-ca` |

Checks before installing:

| Check | Result if it fails |
|---|---|
| Each file is a valid PEM certificate / key | **Stops** - *"not a valid file path or PEM certificate"* |
| The key matches the certificate | **Stops** - *"The private key does not match the certificate"* |
| Certificate not expired | Warning only |
| Certificate issued for the domain | Warning only |

### 6.3 Release, environment and features

| Option | Purpose | Values | Default |
|---|---|---|---|
| `-r`, `--release` | Which Faveo version to download | `official` (stable), `rc` (release candidate), `beta` | `official` |
| `--faveo-env` | Faveo application environment (`--env` of `install:faveo`). Alias `--faveoenv` | `production`, `development`, `testing` | `production` |
| `-w`, `--websocket` | Live updates: enables the WebSocket proxy in Apache and the WebSocket workers | `yes` / `no` (`y` / `n`) | `no` |
| `--skip-faveo-setup` | Do **not** run `install:faveo` and the license check - finish in the browser yourself ([section 19](#19-finishing-the-setup-in-the-browser-manual)) | - | off |

If the chosen release is not available for your license, the download fails and the installation is rolled back.

### 6.4 Installation folder

| Option | Purpose | Default |
|---|---|---|
| `-i`, `--install-dir` | Folder that holds the whole installation | `/opt/faveo/<domain>` |
| `-f`, `--force` | Allow a folder that is not empty | off |

- Missing folders are created (including parent folders). Relative paths and `~` work.
- **Refused** (asked again / stops): system folders such as `/`, `/opt`, `/home`, `/etc`, `/var`, `/usr`, `/tmp`, `/root`, a user's home folder itself, and Windows drives under WSL (`/mnt/c/...`).
- A folder that is **not empty**: interactively you are asked; with `-y` it stops unless `--force` is given. With `--force` the old content is **moved** to `<folder>.old-<date>` (not deleted) and put back if the installation fails.

### 6.5 Database - local MySQL container (default)

| Option | Purpose | Default | Rules |
|---|---|---|---|
| `--db` | `local` = MySQL 8.4 container on this server; `remote` = your own server | `local` | `local` / `remote` |
| `--db-name` | Database name | `faveo` | letters, digits, `_`, max 32 |
| `--db-user` | Database user | `faveo` | letters, digits, `_`, max 32 |
| `--db-password` | Password of that user | generated (20 characters) | 8-64 characters: letters, digits and `@ # % ^ * _ + = . , : ! ? -` |
| `--db-root-password` | MySQL root password | generated (20 characters) | same as above |

The database files are stored in the `mysql/` folder of the installation.

### 6.6 Database - your own MySQL / MariaDB server

Selected with `--db remote` or simply by giving `--db-host`. No MySQL container is created.

| Option | Purpose | Default |
|---|---|---|
| `--db-host` | Server hostname or IPv4 address | *(required)* |
| `--db-port` | Server port | `3306` |
| `--db-admin-user` | Account that can create databases and users | `root` |
| `--db-admin-password` | Its password | *(required)* |
| `--db-name` / `--db-user` / `--db-password` | Database and user that are **created** on the server | `faveo` / `faveo` / generated |
| `--db-ssl` | Encrypted connection | `no` |
| `--db-ssl-ca` | CA certificate of the server (path, PEM or base64) | *(required with `--db-ssl yes`)* |
| `--db-ssl-cert` / `--db-ssl-key` | Client certificate and key (optional; key needed with cert) | - |
| `--db-ssl-verify` | Check the server's hostname against its certificate | `yes` |

What the installer does with your server:

1. Tests the connection with the admin account - **stops** if it cannot connect.
2. Checks the database is new or empty - **stops** if it contains tables.
3. If the user already exists:
   - it has access **only** to the Faveo database → it is reused and gets a new password (`ALTER USER ... IDENTIFIED BY ...`);
   - it also has access to other databases (probably used by another application) → interactively you are asked; with `-y` it **stops**, so the other application keeps working.
4. Creates the database and user, grants access, then **tests the login** as that user.

A server on the same machine (`localhost` / `127.0.0.1`) is reached by the containers as `host.docker.internal` - that MySQL must accept connections from Docker, not only from 127.0.0.1.
If the installation fails, the database / user **created** by this run is removed, and so is a Faveo-only user that was **reused** (its database was empty). `--uninstall` removes the database user (it asks for the admin password, or use `--db-admin-user` / `--db-admin-password` with `-y`) but **keeps the database** with your data.

Option names of the Faveo server installer also work: `--sqlreser yes|no`, `--sqlhost`, `--sqlport`, `--sqlusername`, `--sqlpassword`, `--sqlsecure`, `--sqlsslca`, `--sqlsslcert`, `--sqlsslkey`, `--sqlsslverify`.

### 6.7 Ports and Docker network

| Option | Purpose | Default |
|---|---|---|
| `--http-port` | HTTP port on the server (redirects to HTTPS) | `80` |
| `--https-port` | HTTPS port on the server | `443` |
| `--supervisor-port` | Supervisor port, reachable **from this server only** (127.0.0.1); `none` = not published | `9001` |
| `--auto-ports` | If a port is busy, take the next free one automatically | off |
| `--subnet` | Docker network range, form `x.y.0.0/16` | first free from `172.24.0.0/16` |

- With **certbot** the ports must be 80 and 443 - other values stop the installer.
- With custom ports the site address becomes `https://<domain>:<https-port>`.
- A port that is **already in use**: interactively you are asked for another (a free one is suggested); with `-y` it stops and names a free port; with `--auto-ports` a free port is taken.
- A subnet that **overlaps** an existing network (another Docker network, your LAN or VPN route) is refused.

### 6.8 Image versions and timezone

| Option | Purpose | Default | Alias |
|---|---|---|---|
| `--php` | PHP version in the images (8.x) | `8.4` | `--php-version` |
| `--node` | Node.js major version | `22` | `--node-version` |
| `--timezone` | Container timezone (`Area/City`) | `Asia/Kolkata` | - |

A PHP version without an ionCube loader makes the image build fail → rollback. Keep the default unless you need another version.

### 6.9 Behaviour

| Option | Purpose |
|---|---|
| `-y`, `--yes` | Never ask anything (also automatic when all required fields are given) |
| `--confirm` | Show the summary and ask for **y**, even when all fields are given |
| `--install-docker` | Install Docker Engine, Compose and Buildx if missing or too old. Without it, an interactive run asks; a run without questions stops |
| `-g`, `--generate-only` | Only create the files (see [5.D](#d-generate-the-files-only-review-then-start)) |
| `--keep-on-failure` | Do not roll back when the installation fails - keep the files to investigate |
| `--no-banner` | Do not print the Faveo banner |
| `-h`, `--help` | Show all options plus: your OS, Docker status, free ports, the Docker subnet that would be used, and the installations on this server |

### 6.10 Backup and removal

| Option | Purpose |
|---|---|
| `--backup` | Back up an installation ([section 13](#13-backup-and-restore)) |
| `--backup-dir <path>` | Where backups are stored (default `<installation parent>/Backup`, e.g. `/opt/faveo/Backup`) |
| `--uninstall` | Remove an installation ([section 14](#14-removing-an-installation)) - alias `--rollback` |
| `-i <path>` / `-d <domain>` | Choose the installation for `--backup` / `--uninstall` without the list |

---

## 7. What happens during the installation

| Step | What is done |
|---|---|
| 1. Check the values | All options are validated. Errors are listed together; **nothing is changed** yet. |
| 2. Questions and summary | Missing values are asked for; the summary is shown (confirmed with **y**, unless running without questions). |
| 3. Prerequisites | Missing tools are installed (curl, unzip, openssl, tar, find, cron for Let's Encrypt). Docker / Compose / Buildx are installed if needed. Docker is started and enabled at boot. |
| 4. Remote database | *(remote only)* connection, empty-database and user checks. |
| 5. Installation folder | Created; templates copied; `docker-compose.yml`, `.env`, Apache and Supervisor configuration, `credentials.txt` and `FAVEO-DOCKER-COMMANDS.txt` written. |
| 6. Database user | *(remote only)* database and user created, login tested. |
| 7. SSL certificate | Requested, generated or installed. |
| 8. Faveo download | Downloaded with license + order number, checked, extracted. |
| 9. Containers | Images built (retried up to 3 times on network errors), containers started. |
| 10. Site check | Waits until `https://<domain>` answers. |
| 11. Faveo setup | `install:faveo` and license verification ([section 8](#8-automatic-faveo-setup-and-license-verification)). |
| 12. Summary | Status, credentials and management commands are shown. |

If steps 5-9 fail, the installation is rolled back ([section 11](#11-when-the-installation-fails---rollback)).

---

## 8. Automatic Faveo setup and license verification

After the containers are up (unless `--skip-faveo-setup` is given):

1. The **supervisor container is stopped**.
2. The installer waits until MySQL accepts connections.
3. **`php artisan install:faveo`** runs in the Apache container with this installation's values:
   `--appurl` (site address), `--sqlhost`, `--sqlport`, `--dbname`, `--dbuser`, `--dbpass`, `--securecon` / `--sslca` / `--sslcert` / `--sslkey` / `--sslverify` (remote SSL database), `--migrate=1 --dummy=0 --env=<faveo-env>`.
   The full output is shown and saved in `logs/faveo-install.log`.
4. `REDIS_HOST=faveo-redis` is set in Faveo's `.env` and the configuration cache is cleared.
5. The **license is verified**: the 16-character license code is sent in four parts to `https://<domain>/licenseVerification` from inside the Apache container. The full response is shown; one retry after 10 seconds.
6. The **supervisor container is started** again and the status of all containers is shown.

Final result:

```
  Faveo installation (install:faveo):  SUCCESS
  License verification:                VERIFIED SUCCESSFULLY
  Supervisor container:                running

 ✔ Faveo GUI installation completed successfully. Open https://helpdesk.example.com
```

| Result | Meaning | What to do |
|---|---|---|
| Installation **SUCCESS**, license **VERIFIED SUCCESSFULLY** | Ready to use | Open the site |
| Installation **FAILED: \<reason\>** | `install:faveo` reported a problem (the reason is shown, e.g. *SSL certificate not found*) | See [troubleshooting](#15-troubleshooting); full output in `logs/faveo-install.log`; you can also finish in the browser |
| License **FAILED (HTTP xxx: \<message\>)** | The license server refused (e.g. *maximum number of installations reached*) | Check the message and the license code; verify again later (command in `FAVEO-DOCKER-COMMANDS.txt`) |
| License **not checked** | The installation failed, or the license code is not 16 characters | Fix the installation / code |

These two steps are **never rolled back**: if they fail, the containers and files stay, the full output is shown, and the script ends with exit code 1.

---

## 9. What is created on the server

Everything is inside the installation folder (default `/opt/faveo/<domain>`):

| File / folder | Content |
|---|---|
| `credentials.txt` | URL, license code, order number, database host / name / user / passwords, Meilisearch key (root only) |
| `FAVEO-DOCKER-COMMANDS.txt` | Ready-to-use commands for this installation and this OS - health checks, logs, artisan, workers, database, SSL, Docker service, Docker update, firewall, backup (no passwords inside) |
| `faveo-run.sh` | A copy of the installer - run `--backup`, `--uninstall` or `--help` from here, even if the repository folder is gone (new installations still start from the repository folder) |
| `.env` | Settings used by Docker Compose (root only) |
| `docker-compose.yml` | Container definitions |
| `Dockerfile/` | Image recipes (apache, supervisor, selfsign) |
| `apache/000-default.conf` | Apache virtual host for your domain |
| `supervisor/` | Worker definitions (Horizon, scheduler, WebSocket) |
| `ssl_copy/` or `certbot/` | Certificates |
| `faveo/` | The Faveo application |
| `storage/` | Faveo storage |
| `mysql/` | Database files (local database) |
| `db_ssl/` | Remote database certificates (remote + SSL) |
| `redis/`, `meilisearch/` | Queue / cache and search data |
| `logs/` | Apache, Supervisor and installation logs (`faveo-install.log`) |

Outside the folder: the Docker network `<domain>-faveo`, the images `faveo-apache` / `faveo-supervisor`, and (Let's Encrypt only) a weekly renewal entry in root's crontab.

---

## 10. Wrong values - how the installer reacts

All values are checked **before anything is changed**. With options, every error is listed at once; interactively each wrong answer is asked again (up to 3 times).

| Situation | Message (example) | Fix |
|---|---|---|
| Required field missing (no questions mode) | `--domain is required.` | Add the option |
| Invalid domain | `--domain: 'my_site' is not a valid domain name` | Letters, digits, `-`, `.` only |
| Invalid email | `--email: 'x@' is not a valid email address` | Use a full address |
| Invalid SSL type | `--ssl: use certbot, self-signed or paid-ssl` | |
| Let's Encrypt with other ports | `Let's Encrypt (certbot) needs HTTP port 80 and HTTPS port 443` | Use self-signed / paid-ssl, or ports 80/443 |
| Port in use | `Port 443 (HTTPS) is in use by apache2. Use --https-port 8443 (free) or add --auto-ports` | Free the port or choose another |
| Same port twice | `HTTP and HTTPS ports must be different` | |
| Bad subnet | `--subnet: use the form x.y.0.0/16` / `overlaps a network already used` | Choose another `/16` |
| Paid SSL key does not match | `The private key does not match the certificate` | Use the matching key |
| Bad certificate file | `--certfile: not a valid file path or PEM certificate` | Check the path / content |
| Bad DB name / password | `--db-password: 8-64 characters: letters, digits and ...` | Follow the rules in [6.5](#65-database---local-mysql-container-default) |
| Remote DB unreachable | `Could not connect to the database server db:3306: ...` | Host, port, firewall, admin password |
| Remote DB not empty | `Database 'faveo' on db is not empty` | Use another `--db-name` |
| System folder as install path | `Refusing to use '/opt' as the installation path` | Use a sub-folder |
| Folder not empty | `'/srv/faveo' is not empty. Use --force ...` | Another folder or `--force` |
| Docker missing (no questions) | `Docker / Docker Compose is missing ... Run again with --install-docker` | Add `--install-docker` |
| Unknown option | `Unknown option: --whatever` | See `--help` |
| Not root | `Please run as root: sudo ./faveo-run.sh ...` | Use `sudo` |

---

## 11. When the installation fails - rollback

If a step fails after the installation has started changing the server - or you press **Ctrl+C** - the installer **rolls back** what that run created:

| Created by the run | Rolled back |
|---|---|
| Containers and the Docker network | Stopped and removed |
| Faveo images built by the run | Removed (if no other installation uses them) |
| Let's Encrypt renewal cron entry | Removed |
| Remote database / user created by the run, or a Faveo-only user it reused | Dropped (a database that existed before, and a user shared with other databases, are never touched) |
| The installation folder | Deleted |
| A folder replaced with `--force` | Put back, and its containers started again |

How it is triggered:

| Mode | Behaviour |
|---|---|
| Interactive | Shows what will be undone and asks *"Roll back now? (Y/n)"* |
| No questions (`-y` / all fields given) | Rolls back automatically |
| `--keep-on-failure` | Never rolls back - shows how to resume (`docker compose up -d --build`) or remove later (`--uninstall`) |

Not rolled back:
- Docker and the OS packages that were installed (they are useful anyway).
- Downloaded base images (ubuntu, mysql, redis, meilisearch) - free the space with `docker image prune -a`.
- The **Faveo setup and license verification** step ([section 8](#8-automatic-faveo-setup-and-license-verification)).

**Exit codes:** `0` = installed, Faveo set up and license verified · `1` = error, cancelled, or Faveo setup / license verification failed.

---

## 12. After the installation

Run these in the installation folder (`cd /opt/faveo/<domain>`):

| Task | Command |
|---|---|
| Status of the containers | `docker compose ps` |
| Live logs | `docker compose logs -f` |
| Logs of one container | `docker compose logs -f faveo-apache` |
| Stop / start | `docker compose down` / `docker compose up -d` |
| Restart | `docker compose restart` |
| Shell in the app container | `docker exec -it <domain>-apache bash` |
| Clear Faveo caches | `docker exec -u www-data <domain>-apache php artisan optimize:clear` |

Many more ready-made commands are in **`FAVEO-DOCKER-COMMANDS.txt`**. Servers that only have the old standalone tool use `docker-compose` instead of `docker compose`.

Good to know:

- Containers **start automatically** after a reboot (Docker is enabled at boot).
- Let's Encrypt certificates **renew automatically** every week, and Apache reloads them.
- The Supervisor port is reachable only from the server itself.
- **Test domains** (not in public DNS): add `<server IP> <domain>` to the hosts file of the computer you browse from (`/etc/hosts`, or `C:\Windows\System32\drivers\etc\hosts`).
- **Self-signed**: import `ssl_copy/faveorootCA.crt` into your browser / OS to remove the warning.

---

## 13. Backup and restore

### Create a backup

```sh
sudo ./faveo-run.sh --backup                                           # choose from the list
sudo ./faveo-run.sh --backup -d helpdesk.example.com -y                # by domain, no questions
sudo ./faveo-run.sh --backup -i /opt/faveo/helpdesk.example.com --backup-dir /mnt/backups -y
```

The backup goes to `<backup-dir>/<domain>/<date_time>/` (default backup-dir: `/opt/faveo/Backup`, or next to your custom installation folder):

| File | Content |
|---|---|
| `database.sql.gz` | Database dump (local container or remote server). A stopped MySQL container is started for the dump and stopped again |
| `faveo-files.tar.gz` | `faveo/` and `storage/` |
| `config.tar.gz` | `.env`, `docker-compose.yml`, `credentials.txt`, `FAVEO-DOCKER-COMMANDS.txt`, Apache / Supervisor configuration, Dockerfiles, certificates |
| `SHA256SUMS` | Checksums - verify with `sha256sum -c SHA256SUMS` |
| `README.txt` | Contents and step-by-step restore |

- Free disk space is checked first. The backup folder must be outside the installation folder.
- The dump is verified. **A failed backup deletes its own folder and changes nothing else.**

### Restore

The `README.txt` in each backup has the exact commands. In short:

1. Create the folder and unpack: `tar xzf config.tar.gz && tar xzf faveo-files.tar.gz`
2. Local database: start MySQL (`docker compose up -d faveo-mysql`) and import `database.sql.gz` into it. Remote database: import it into your server.
3. Start everything: `docker compose up -d --build`

---

## 14. Removing an installation

```sh
sudo ./faveo-run.sh --uninstall                                        # choose from the list
sudo ./faveo-run.sh --uninstall --backup -i /opt/faveo/helpdesk.example.com -y   # back up, then remove
sudo ./faveo-run.sh --uninstall -i /opt/faveo/helpdesk.example.com -y           # remove without backup
```

How the installation is found: folders in `/opt/faveo/`, plus custom folders recorded by Docker on the containers. If the containers no longer exist, give the folder with `-i`.

The installer shows what will be deleted, asks **yes / no**, then offers a **backup** first.

| Removed | Kept |
|---|---|
| Containers and Docker network | A remote database (your data - drop it yourself if no longer needed) |
| The Faveo database **user** on a remote database server (needs the admin password) | |
| The installation folder (application, database files, certificates, logs, credentials) | Backups |
| Faveo images (if no other installation uses them) | Base images (`docker image prune -a` frees them) |
| Let's Encrypt renewal cron entry | Docker itself |

Safety: if the backup fails, **nothing is removed**; only folders created by this installer can be removed; system folders are never deleted.

---

## 15. Troubleshooting

| Problem | Cause | Solution |
|---|---|---|
| **Port 80 / 443 in use** | Another web server (Apache, nginx ...) is running | Stop it, or use `-s self-signed --http-port 8091 --https-port 8443`, or `--auto-ports` |
| **Let's Encrypt failed** | Domain does not point to the server, or port 80 is blocked | Check DNS (`ping <domain>`), open port 80/443 in the firewall and cloud security group |
| **Download failed** | Wrong license / order number, release not available for the license, or no internet | Check the values on billing.faveohelpdesk.com; try `-r official` |
| **"The downloaded file is not a valid archive"** | License / order number not accepted | Check them |
| **Image build failed** | Network problem (retried 3 times) or unsupported `--php` version | Check internet; keep the default PHP version |
| **Faveo installation FAILED: SSL certificate not found** | Faveo could not open its own `https://` address | Check `FAVEO-DOCKER-COMMANDS.txt` → *Site answers*; make sure the domain and certificate are correct |
| **License verification FAILED** | Message from the license server (e.g. *maximum number of installations reached*) | Free an installation slot on billing.faveohelpdesk.com or contact Faveo; verify again (command in `FAVEO-DOCKER-COMMANDS.txt`) |
| **Browser cannot open the site** | Domain not pointing to the server, firewall, or custom port missing in the URL | Check DNS / hosts file, firewall, and use `https://<domain>:<port>` for custom ports |
| **Browser warns about the certificate** | Self-signed certificate | Expected - import `ssl_copy/faveorootCA.crt`, or use certbot / paid SSL |
| **Containers stopped after a reboot** | Docker not starting at boot | `FAVEO-DOCKER-COMMANDS.txt` → *Start at boot* |
| **Subnet clashes with LAN / VPN** | Docker network range already used | Reinstall with `--subnet 172.30.0.0/16` (any free `x.y.0.0/16`) |
| **"is not an installation created by this script"** | `--uninstall` / `--backup` pointed to another folder | Use the folder of an installation made by `faveo-run.sh` |

Useful commands for diagnosis:

```sh
./faveo-run.sh --help                              # OS, Docker, free ports, installations
cd /opt/faveo/<domain> && docker compose ps        # container status
docker compose logs --tail 100 faveo-apache        # web server / PHP errors
cat logs/faveo-install.log                         # Faveo setup and license output
```

---

## 16. Examples

```sh
# 1. Fully interactive
sudo ./faveo-run.sh

# 2. Production: Let's Encrypt, no questions, install Docker if needed
sudo ./faveo-run.sh -d helpdesk.example.com -e admin@example.com -l ABC1D23EFJH50000 -o 45894483 -s certbot --install-docker

# 3. Same, but review the summary first
sudo ./faveo-run.sh -d helpdesk.example.com -e admin@example.com -l ABC1D23EFJH50000 -o 45894483 -s certbot --confirm

# 4. Paid certificate from files
sudo ./faveo-run.sh -d helpdesk.example.com -e admin@example.com -l XXXX -o 1234 -s paid-ssl \
     --certfile /root/ssl/certificate.crt --keyfile /root/ssl/private.key --cacertfile /root/ssl/ca_bundle.crt

# 5. Paid certificate passed as base64 (automation / CI)
sudo ./faveo-run.sh ... -s paid-ssl --certfile "$(base64 -w0 certificate.crt)" \
     --keyfile "$(base64 -w0 private.key)" --cacertfile "$(base64 -w0 ca_bundle.crt)"

# 6. Test server where 80/443 are used: self-signed on other ports
sudo ./faveo-run.sh -d helpdesk.local -e admin@example.com -l XXXX -o 1234 -s self-signed --http-port 8091 --https-port 8443

# 7. Release candidate, WebSocket, custom folder, own database name
sudo ./faveo-run.sh -d hd.example.com -e admin@example.com -l XXXX -o 1234 -s self-signed \
     -r rc -w yes -i /srv/faveo/helpdesk --db-name helpdesk --db-user hduser

# 8. Your own MySQL server
sudo ./faveo-run.sh ... --db-host db.example.com --db-admin-password 'Adm1n!Pass'

# 9. Your own MySQL server over SSL with custom names
sudo ./faveo-run.sh ... --db remote --db-host db.example.com --db-port 3306 \
     --db-admin-user dbadmin --db-admin-password 'Adm1n!Pass' --db-name helpdesk --db-user hduser \
     --db-password 'Str0ng.Pass' --db-ssl yes --db-ssl-ca /root/db/ca.pem --db-ssl-verify yes

# 10. Custom Docker subnet (172.24.x.x is used by your LAN / VPN)
sudo ./faveo-run.sh ... --subnet 172.30.0.0/16

# 11. Generate the files only, to review them
sudo ./faveo-run.sh -d hd.example.com -e a@b.com -l XXXX -o 1234 -s self-signed -g -i /root/faveo-preview

# 12. Offline: use a Faveo archive downloaded beforehand
sudo FAVEO_ZIP_FILE=/root/faveo.zip ./faveo-run.sh -d hd.example.com -e a@b.com -l XXXX -o 1234 -s self-signed

# 13. Keep the files if something fails (for investigation)
sudo ./faveo-run.sh ... --keep-on-failure

# 14. Backup, and backup + remove
sudo ./faveo-run.sh --backup -d helpdesk.example.com --backup-dir /mnt/backups -y
sudo ./faveo-run.sh --uninstall --backup -i /opt/faveo/helpdesk.example.com -y
```

---

## 17. FAQ

**Can I install several domains on one server?**
Yes. Each installation gets its own folder, containers and network. Only one can use ports 80/443 - give the others other ports (self-signed or paid SSL) or put a reverse proxy in front.

**Where is my installation?**
In `/opt/faveo/<domain>`, or the folder you gave with `-i`. `./faveo-run.sh --help` lists the installations on the server.

**Where are the passwords?**
In `credentials.txt` in the installation folder (readable by root only).

**Is the repository folder changed?**
No. The templates are copied into the installation folder.

**What happens on a server reboot?**
Docker starts at boot and the containers start again automatically.

**Can I run the installer again with the same domain?**
Yes, with `--force` (or answer *y* when asked): the old folder is moved aside to `<folder>.old-<date>`. Delete it when it is no longer needed. Use `--uninstall` first if you want a clean start.

**How do I change ports later?**
The simplest way is a backup, `--uninstall` and a new installation with the new ports. (Manually: `HTTP_PORT` / `HTTPS_PORT` in `.env` and the ports in `apache/000-default.conf`, then `docker compose up -d`.)

**Does it work behind a proxy / without internet?**
Faveo itself can come from a local archive (`FAVEO_ZIP_FILE`); Docker images and OS packages need internet or local mirrors.

---

## 18. Community Edition

The free Community Edition uses **`faveo-community-run.sh`**. It runs in this folder and keeps its files here.

```sh
chmod +x faveo-community-run.sh
sudo ./faveo-community-run.sh -domainname helpdesk.example.com -email admin@example.com -ssl A
```

| Option | Purpose | Required |
|---|---|---|
| `-domainname` | Domain pointing to the server | Yes |
| `-email` | Email for Let's Encrypt | Yes |
| `-ssl` | `A` = Let's Encrypt, `B` = self-signed, `C` = paid (you are asked for the certificate, key and CA bundle paths) | Yes |
| `-h`, `--help` | Help | - |

Passwords are shown at the end and saved in `credentials.txt` in this folder. Then [finish the setup in the browser](#19-finishing-the-setup-in-the-browser-manual).

---
