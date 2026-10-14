# Faveo Docker Deployments

<img src="https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4e/Docker_%28container_engine%29_logo.svg/960px-Docker_%28container_engine%29_logo.svg.png?utm_source=commons.wikimedia.org&utm_campaign=index&utm_content=thumbnail" alt="Docker" width="260"/>

This repository contains ready-to-run Docker Compose setups for three Faveo products. Each product lives in its own folder with its own `faveo-run.sh` installer script. This page is a single starting point that tells you **which folder to use** and **how to run it** - full, product-specific details are in the `Readme.md` inside each folder.

| Folder | Product | License/Order Number Needed? |
|---|---|---|
| [`faveo-helpdesk-docker/`](faveo-helpdesk-docker/Readme.md) | Faveo Helpdesk (all paid editions) | ✅ Yes |
| [`faveo-invoicing-docker/`](faveo-invoicing-docker/Readme.md) | Faveo Invoicing (Community Edition) | ❌ No |
| [`faveo-nd-docker/`](faveo-nd-docker/Readme.md) | Faveo Network Discovery | ✅ Yes |

> 💡 **Not sure which one you need?** If you're setting up a support/helpdesk system, use `faveo-helpdesk-docker`. For billing/invoicing, use `faveo-invoicing-docker`. For network/asset discovery, use `faveo-nd-docker`.

---

## 1. Before You Start - Prerequisites (All Products)

Make sure your server has:

1. **Any major Linux distribution**: Ubuntu/Debian, RHEL/CentOS Stream/Rocky/AlmaLinux/Oracle Linux, Fedora, Amazon Linux, openSUSE/SLES, Arch Linux, Alpine (run `apk add bash` first) or Void Linux, on x86_64 or ARM64. SELinux-enforcing hosts are handled automatically. Full list of operating systems, processors and all parameters: [SUPPORTED_OS.txt](SUPPORTED_OS.txt)
2. **Docker** and **Docker Compose** - installed for your OS if missing (Faveo Helpdesk asks first, or use `--install-docker`; an existing install, Compose v2 `docker compose` or standalone `docker-compose`, is detected and reused)
3. **Sudo privileges**
4. A **domain name** fully pointed (DNS A record) to your server's public IP
5. **Ports 80 and 443 free** - needed for Let's Encrypt. Faveo Helpdesk can use other ports with self-signed or paid SSL (`--http-port` / `--https-port`)
6. For **Paid SSL**: your `.crt` / `.key` / CA bundle files ready on the server
7. For **Faveo Helpdesk** and **Faveo Network Discovery**: a valid **license code** and **order number** from [billing.faveohelpdesk.com](https://billing.faveohelpdesk.com) *(not needed for Faveo Invoicing - it's free/community)*

---

## 2. Get the Code

```sh
git clone https://github.com/ladybirdweb/faveo-helpdesk-docker-v2.git
cd faveo-helpdesk-docker-v2
```

Then move into **whichever product folder you need**:

```sh
cd faveo-helpdesk-docker     # OR
cd faveo-invoicing-docker    # OR
cd faveo-nd-docker
```

Give the installer script permission to run:

```sh
chmod +x faveo-run.sh
```

---

## 3. Run the Installer

Each script asks for a few arguments. You can always run `./faveo-run.sh --help` first to see the exact options for that product.

### 🟢 Faveo Helpdesk

```sh
sudo ./faveo-run.sh                     # asks for everything step by step
sudo ./faveo-run.sh -d helpdesk.example.com -e admin@example.com -l <license code> -o <order number> -s certbot
```

The Helpdesk installer has many more options - release (official / rc / beta), installation folder, local or remote database, custom ports and subnet, PHP / Node.js versions, backup, uninstall and automatic rollback if something fails. Run `./faveo-run.sh --help` or see the [Faveo Helpdesk guide](faveo-helpdesk-docker/Readme.md). It installs into `/opt/faveo/<domain>` and the old `-domainname -email -license -orderno -ssl -websocket` options still work.

### 🟢 Faveo Invoicing (Community - no license needed)

```sh
./faveo-run.sh -domainname invoicing.example.com -email admin@example.com -ssl A
```

### 🟢 Faveo Network Discovery

```sh
./faveo-run.sh -domainname nd.example.com -email admin@example.com -license <license code> -orderno <order number> -ssl A
```

**Argument quick reference** (Invoicing and Network Discovery; Faveo Helpdesk accepts these too):

| Flag | Meaning |
|---|---|
| `-domainname` | Your domain, fully pointed to this server |
| `-email` | Used for Let's Encrypt SSL registration/renewal |
| `-license` | Faveo license code (Helpdesk & ND only) |
| `-orderno` | Faveo order number, **without** the `#` symbol (Helpdesk & ND only) |
| `-ssl` | `A` = Let's Encrypt (free) · `B` = Self-Signed · `C` = Paid SSL (you'll be asked for cert/key/CA paths) |
| `-websocket` | `y` or `n` - enables live chat/notifications (Helpdesk only, optional, default `n`) |
| `-h`, `--help` | Show usage help and exit |

> ⚠️ If you choose SSL option **C (Paid SSL)**, have these ready before running the script:
> - Certificate: `/path/to/certificate.crt`
> - Private Key: `/path/to/private.key`
> - CA Bundle: `/path/to/ca_bundle.crt`

The script will show you a colour-coded summary of what you entered and ask **"Continue (y/n)?"** before it does anything - review it carefully before confirming.

---

## 4. What Happens Next

Once you confirm, the script automatically:

1. Checks/installs prerequisites (`curl`, `unzip`, `openssl`, cron, Docker Engine and Docker Compose) using your OS package manager
2. Obtains your SSL certificate (Let's Encrypt / Self-Signed / Paid)
3. Downloads the Faveo codebase (or clones it, for Invoicing)
4. Generates secure random database credentials
5. Creates the Docker network, volumes, and starts all containers
6. Prints your database credentials and saves them to **`credentials.txt`** - keep this file safe (Faveo Helpdesk: in `/opt/faveo/<domain>`; Invoicing / Network Discovery: in the product folder)

---

## 5. Finish the Setup in Your Browser

1. Visit `https://yourdomainname.com`, complete the installation wizard, and enter the database details from `credentials.txt` when prompted.
2. Once the wizard finishes, open the newly created `.env` file inside the `faveo/` directory (Faveo Helpdesk: `/opt/faveo/<domain>/faveo/.env`) and add:
   ```
   REDIS_HOST=faveo-redis
   ```
3. Restart the containers from the installation folder so the change takes effect:
   ```sh
   docker compose down && docker compose up -d
   ```

> **Faveo Helpdesk / Faveo Network Discovery only:** if the interface doesn't load right after this step, you may need to clear one leftover plugin entry from the database - see the **Troubleshooting** section in that folder's `Readme.md` for the exact commands.

---

## 6. Need More Detail?

This page only covers the common steps. For product-specific notes (MeiliSearch setup, WebSocket details, full troubleshooting, etc.), open the full guide for the product you installed:

- 📄 [Faveo Helpdesk - full guide](faveo-helpdesk-docker/Readme.md)
- 📄 [Faveo Invoicing - full guide](faveo-invoicing-docker/Readme.md)
- 📄 [Faveo Network Discovery - full guide](faveo-nd-docker/Readme.md)
