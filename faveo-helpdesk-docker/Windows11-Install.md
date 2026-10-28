# Faveo Helpdesk on Docker: Windows 11 install notes

Faveo runs in Docker inside **WSL2 (Ubuntu)** on Windows 11. The Faveo installer runs inside Ubuntu, not in Windows.

---

## 1. Requirements

- Windows 11, with virtualization turned on in the BIOS
- At least 4 CPU cores, 8 GB RAM and 30 GB free disk space
- Faveo **license code** and **order number**
- Internet access

---

## 2. Install WSL2 and Ubuntu

Open **PowerShell as Administrator**:

```powershell
wsl --install -d Ubuntu-24.04
```

- Restart Windows when it asks.
- Open **Ubuntu** from the Start menu and create a Linux username and password.

Check it worked (in PowerShell):

```powershell
wsl -l -v
```

`Ubuntu-24.04` should show **VERSION 2**.

---

## 3. Turn on systemd in Ubuntu

In the Ubuntu window:

```bash
sudo nano /etc/wsl.conf
```

Add these lines, then save (Ctrl+O, Enter, Ctrl+X):

```ini
[boot]
systemd=true
```

Restart WSL from **PowerShell**:

```powershell
wsl --shutdown
```

Open Ubuntu again and check:

```bash
systemctl is-system-running
```

`running` or `degraded` are both fine.

---

## 4. Make sure ports 80 and 443 are free on Windows

In **PowerShell**:

```powershell
netstat -ano | findstr ":80 :443"
```

If IIS, Skype, XAMPP or something else is using them, stop it, or use other ports (see step 7).

---

## 5. Pick a domain name

For a local or test install, use a name such as `faveo.local`.

Open **Notepad as Administrator** and edit:

```
C:\Windows\System32\drivers\etc\hosts
```

Add this line:

```
127.0.0.1   faveo.local
```

Then run `wsl --shutdown` in PowerShell. Ubuntu copies the Windows hosts file the next time it starts.

> For a real domain, point its DNS to this PC's public IP instead.

---

## 6. Download the installer (in Ubuntu)

```bash
sudo apt update && sudo apt install -y wget tar
cd ~
wget -O faveo.tar.gz https://codeload.github.com/vvitsivakumar/FaveoOnDocker/tar.gz/refs/heads/main
tar -xzf faveo.tar.gz
cd FaveoOnDocker-main/faveo-helpdesk-docker
chmod +x faveo-run.sh
```

> Keep everything inside Linux (`~` or `/opt`). Don't use `/mnt/c/...`; the installer refuses Windows drives.

---

## 7. Install Faveo

**Option A: answer the questions step by step**

```bash
sudo ./faveo-run.sh --install-docker
```

**Option B: one command (self-signed SSL)**

```bash
sudo ./faveo-run.sh -d faveo.local -e admin@example.com \
     -l <LICENSE_CODE> -o <ORDER_NUMBER> -s self-signed --install-docker
```

**If ports 80/443 are busy on Windows:**

```bash
sudo ./faveo-run.sh -d faveo.local -e admin@example.com \
     -l <LICENSE_CODE> -o <ORDER_NUMBER> -s self-signed \
     --http-port 8081 --https-port 8443 --install-docker
```

What happens:

- Docker is installed inside Ubuntu (`--install-docker`).
- Faveo is installed in `/opt/faveo/<domain>`.
- The containers start: Apache, MySQL 8.4, Redis, Supervisor and Meilisearch.
- Faveo is configured and the license is verified.

> **SSL:** use `self-signed` on a PC. Let's Encrypt (`certbot`) only works with a public domain that points to this PC, with ports 80 and 443 open to the internet.

---

## 8. Open Faveo

In a Windows browser:

```
https://faveo.local
```

(or `https://faveo.local:8443` if you changed the ports)

- The browser warns about the self-signed certificate. Choose **Advanced → Proceed**.
- The admin login details are in:

```bash
sudo cat /opt/faveo/faveo.local/credentials.txt
```

---

## 9. Daily use

| Task | Command (in Ubuntu) |
|---|---|
| Go to the install folder | `cd /opt/faveo/faveo.local` |
| See the containers | `sudo docker compose ps` |
| Start Faveo | `sudo docker compose up -d` |
| Stop Faveo | `sudo docker compose down` |
| Logs | `sudo docker compose logs -f` |
| Backup | `sudo ./faveo-run.sh --backup -d faveo.local` |
| Remove | `sudo ./faveo-run.sh --uninstall -d faveo.local` |
| All commands | `cat /opt/faveo/faveo.local/FAVEO-DOCKER-COMMANDS.txt` |

> After a Windows restart, open **Ubuntu** once. Docker starts by itself because systemd is on.

---

## 10. Common problems

| Problem | Fix |
|---|---|
| `wsl --install` fails | Turn on virtualization in the BIOS, and turn on **Virtual Machine Platform** in Windows Features |
| Docker doesn't start | Check `/etc/wsl.conf` has `systemd=true`, then `wsl --shutdown` |
| Port 80/443 busy | Stop IIS/XAMPP, or use `--http-port 8081 --https-port 8443` |
| Browser can't find `faveo.local` | Check the Windows `hosts` file entry |
| Other PCs can't open it | WSL only listens on this PC. Ask IT to set up `netsh interface portproxy` and a firewall rule |

---

### Notes

- **Docker Desktop instead:** if Docker Desktop is already installed, turn on **Settings → Resources → WSL Integration → Ubuntu-24.04** and leave out `--install-docker`.
- **Script version:** the download uses the latest scripts on GitHub `main`, so local changes that aren't pushed are not included.
