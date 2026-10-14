#!/bin/bash
#
# Faveo Docker Installer (self-contained)
#
# Single script that installs Faveo on Docker:
#   helpdesk   - Faveo Helpdesk (licensed)
#   nd         - Faveo Network Discovery (licensed)
#
# Every Dockerfile, Apache vhost, supervisor program, docker-compose.yml and
# .env is embedded in this script and generated into the installation path, so
# nothing else needs to be downloaded or copied alongside it.
#
# Modelled on the Faveo server auto-installer (install.sh):
#   - runs interactively when options are missing, or fully from --options
#   - SSL types certbot | self-signed | paid-ssl
#   - paid SSL accepts a file path, pasted PEM content or base64 PEM, each
#     validated with openssl before the installation starts
#
# Run './faveo-install.sh --help' for usage.

set -o pipefail

SCRIPT_NAME=$(basename "$0")

# ----------------------------------------------------------------------------
# Colours / logging
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
    CYAN='\033[1;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    [[ "$install_started" == "y" ]] && on_failure
    exit 1
}

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
product=""
domainname=""
email=""
license=""
orderno=""
release=""             # official | rc | beta  (billing download channel)
ssl_option=""          # A = certbot, B = self-signed, C = paid-ssl
websocket_enable=""
certfile=""
keyfile=""
cacertfile=""
install_dir=""
db_name="faveo"
db_user="faveo"
db_location=""         # local (MySQL container, default) | remote (existing server)
db_password=""         # Faveo DB user password; empty = auto-generate
db_root_password=""    # local MySQL root password; empty = auto-generate
db_host=""             # remote only
db_port=""
db_admin_user=""
db_admin_password=""
db_admin_pw_given="n"
db_ssl=""              # remote: yes | no
db_ssl_ca=""; db_ssl_cert=""; db_ssl_key=""
db_ssl_verify=""
db_custom_from_cli="n"
timezone="Asia/Kolkata"
php_version="8.4"
node_version="22"
assume_yes="n"
force="n"
generate_only="n"
show_banner="y"
show_help="n"
http_port=""           # host ports; empty = default (80 / 443 / 9001)
https_port=""
supervisor_port=""
auto_ports="n"
ports_from_cli="n"
uninstall="n"
do_backup="n"          # --backup: back up an installation (also before --uninstall)
backup_dir=""          # --backup-dir: where backups go (default: <install parent>/Backup)
install_docker="n"     # --install-docker: install Docker Engine + Compose if missing
subnet=""              # Docker network subnet (x.y.0.0/16); empty = first free one
subnet_prefix="172.24"
keep_on_failure="n"
install_started="n"   # set once the installer starts changing the system
build_retries=3
# What this run created (undone by rollback).
RB_DIR=""; RB_NETWORK=""; RB_CRON=""; RB_IMAGES=()     # set when any port option was passed
host_root_dir="faveo"
max_retries=3

# Validated paid-SSL material is staged here until the installation path exists.
STAGE_DIR=$(mktemp -d) || die "Cannot create a temporary directory."
trap 'rm -rf "$STAGE_DIR"' EXIT
# Ctrl+C / kill while installing (e.g. a step is stuck) -> offer rollback.
trap 'echo ""; die "Installation interrupted."' INT TERM

# ----------------------------------------------------------------------------
# Help
# ----------------------------------------------------------------------------
usage() {
    local o="  ${GREEN}%-22s${NC} %-32s %s\n"
    echo -e "${CYAN}Faveo Docker Installer${NC} - installs Faveo Helpdesk or Faveo Network Discovery on Docker."
    echo ""
    echo -e "${CYAN}Usage:${NC} sudo ./$SCRIPT_NAME [OPTIONS]"
    echo ""
    echo -e "${YELLOW}Any required option that is not supplied is asked for interactively.${NC}"
    echo -e "${YELLOW}With --yes (or without a terminal) all required options must be given.${NC}"
    echo ""
    echo "Required:"
    printf "$o" "-p, --product"     "helpdesk|nd"                   "Product to install"
    printf "$o" "-d, --domain"      "<domain>"                      "Domain name for Faveo (without https://)"
    printf "$o" "-e, --email"       "<email>"                       "Admin email (also used for Let's Encrypt)"
    printf "$o" "-l, --license"     "<code>"                        "Faveo license code (billing.faveohelpdesk.com)"
    printf "$o" "-o, --order"       "<number>"                      "Faveo order number (without '#')"
    printf "$o" "-s, --ssl"         "certbot|self-signed|paid-ssl"  "SSL type (A|B|C also accepted)"
    printf "$o" "-r, --release"     "official|rc|beta"              "Release to download     (default: official)"
    echo ""
    echo "Paid SSL (--ssl paid-ssl) - each value may be a file path, raw PEM or base64 PEM:"
    printf "$o" "    --certfile"    "<path|pem|base64>"             "Certificate           (certificate.crt)"
    printf "$o" "    --keyfile"     "<path|pem|base64>"             "Private key           (private.key)"
    printf "$o" "    --cacertfile"  "<path|pem|base64>"             "CA bundle / chain     (ca_bundle.crt)"
    echo "  If omitted, you are asked for each file: enter its path or paste its content."
    echo ""
    echo "Database (all optional; asked interactively, defaults used with --yes):"
    printf "$o" "    --db"          "local|remote"                  "local = MySQL 8.4 container (default), remote = existing server"
    echo "  Local (MySQL container):"
    printf "$o" "    --db-name"     "<name>"                        "Database name       (optional, default: faveo)"
    printf "$o" "    --db-user"     "<name>"                        "Database user       (optional, default: faveo)"
    printf "$o" "    --db-password" "<password>"                    "Database password   (optional, default: auto-generated)"
    printf "$o" "    --db-root-password" "<password>"               "MySQL root password (optional, default: auto-generated)"
    echo "  Remote (--db remote, or just give --db-host):"
    printf "$o" "    --db-host"     "<host|IPv4>"                   "Remote MySQL/MariaDB server      (required)"
    printf "$o" "    --db-port"     "<port>"                        "Remote port         (optional, default: 3306)"
    printf "$o" "    --db-admin-user" "<user>"                      "Admin user that creates the DB  (optional, default: root)"
    printf "$o" "    --db-admin-password" "<password>"              "Admin password                  (required)"
    printf "$o" "    --db-name"     "<name>"                        "Database to create  (optional, default: faveo)"
    printf "$o" "    --db-user"     "<name>"                        "User to create      (optional, default: faveo)"
    printf "$o" "    --db-password" "<password>"                    "Password for it     (optional, default: auto-generated)"
    printf "$o" "    --db-ssl"      "yes|no"                        "SSL/TLS connection  (optional, default: no)"
    printf "$o" "    --db-ssl-ca"   "<path|pem|base64>"             "CA certificate      (required with --db-ssl yes)"
    printf "$o" "    --db-ssl-cert" "<path|pem|base64>"             "Client certificate  (optional)"
    printf "$o" "    --db-ssl-key"  "<path|pem|base64>"             "Client key          (optional, needed with --db-ssl-cert)"
    printf "$o" "    --db-ssl-verify" "yes|no"                      "Verify server certificate identity (optional, default: yes)"
    echo "  Passwords: $DB_PASS_RULE."
    echo "  install.sh names also work: --sqlreser --sqlhost --sqlport --sqlusername --sqlpassword"
    echo "  --sqlsecure --sqlsslca --sqlsslcert --sqlsslkey --sqlsslverify"
    echo ""
    echo "Ports (defaults 80 / 443 / 9001; Let's Encrypt always uses 80 and 443):"
    printf "$o" "    --http-port"   "<port>"                        "HTTP port on this server  (default: 80)"
    printf "$o" "    --https-port"  "<port>"                        "HTTPS port on this server (default: 443)"
    printf "$o" "    --supervisor-port" "<port|none>"               "Supervisor port (default: 9001; none = not published)"
    printf "$o" "    --auto-ports"  ""                              "If a port is in use, pick the next free one automatically"
    printf "$o" "    --subnet"      "<x.y.0.0/16>"                  "Docker network subnet, e.g. 172.30.0.0/16"
    printf "$o" ""                  ""                              "  (default: first free from 172.24.0.0/16 upward; asked interactively)"
    echo "  If a port is already in use you are asked for another one (a free port is suggested)."
    echo "  With certbot the HTTP/HTTPS ports cannot be changed: ports 80 and 443 must be free."
    echo ""
    echo "Optional:"
    printf "$o" "-w, --websocket"   "yes|no"                        "WebSocket services, helpdesk only (default: no)"
    printf "$o" "-i, --install-dir" "<path>"                        "Installation path (asked if omitted;"
    printf "$o" ""                  ""                              "  default /opt/faveo/<domain>)"
    printf "$o" "    --timezone"    "<tz>"                          "Container timezone    (default: $timezone)"
    printf "$o" "    --php"         "<version e.g. 8.4>"            "PHP version           (default: $php_version)"
    printf "$o" "    --node"        "<major e.g. 22>"               "Node.js version       (default: $node_version)"
    printf "$o" "-g, --generate-only" ""                            "Only create the files; no SSL request, download or Docker"
    printf "$o" "-y, --yes"         ""                              "Non-interactive: no prompts, no confirmation"
    printf "$o" "    --keep-on-failure" ""                          "Do not roll back when the installation fails"
    printf "$o" "    --install-docker" ""                           "Install Docker Engine + Compose plugin if missing"
    printf "$o" ""                  ""                              "  (asked interactively when Docker is not found)"
    printf "$o" "    --backup"      ""                              "Back up an installation: MySQL dump + Faveo files + config"
    printf "$o" ""                  ""                              "  (lists installs and asks which, or use -i / -d)"
    printf "$o" "    --backup-dir"  "<path>"                        "Where backups go (default: <install parent>/Backup,"
    printf "$o" ""                  ""                              "  e.g. /opt/faveo/Backup/<domain>/<date-time>)"
    printf "$o" "    --uninstall"   ""                              "Remove an installation (containers, network, cron,"
    printf "$o" ""                  ""                              "  images if unused, files). Lists the installs found"
    printf "$o" ""                  ""                              "  and asks which one (default: the first), or use -i / -d"
    printf "$o" "-f, --force"       ""                              "Overwrite a non-empty installation path"
    printf "$o" "    --no-banner"   ""                              "Do not print the banner"
    printf "$o" "-h, --help"        ""                              "Show this help and exit"
    echo ""
    echo "Failure / rollback:"
    echo "  If a step fails or you press Ctrl+C (e.g. a step is stuck), everything this run created is"
    echo "  rolled back: containers, Docker network, renewal cron entry, Faveo images (if unused by other"
    echo "  installs) and the installation path. Interactively you are asked first and may keep the files"
    echo "  to resume; with --yes it rolls back automatically unless --keep-on-failure is given."
    echo "  Downloaded base images (ubuntu, mysql, redis, meilisearch) stay in Docker's cache."
    echo ""
    echo "Supported systems (x86_64 and aarch64/ARM64):"
    echo "  Ubuntu, Debian, RHEL, Rocky, AlmaLinux, CentOS Stream, Fedora, Amazon Linux,"
    echo "  openSUSE / SLES, Arch Linux and Alpine. SELinux (enforcing) is handled automatically."
    echo ""
    echo "Aliases: --orderno, --ssl-cert, --ssl-key, --ssl-ca, --php-version, --node-version,"
    echo "         and the old -domainname, -email, -license, -orderno, -ssl, -websocket flags."
    echo ""
    echo "Created under the installation path:"
    echo "  docker-compose.yml .env credentials.txt  Dockerfile/{apache,supervisor}/  apache/  supervisor/"
    echo "  ssl_copy/ or certbot/  faveo/  storage/  mysql/  redis/  meilisearch/ (helpdesk)  logs/"
    echo ""
    echo "Examples:"
    echo "  # Fully interactive"
    echo "  sudo ./$SCRIPT_NAME"
    echo ""
    echo "  # Helpdesk with Let's Encrypt and WebSocket"
    echo "  sudo ./$SCRIPT_NAME --product helpdesk --domain hd.example.com --email admin@example.com \\"
    echo "       --license XXXXXXXXXXXXXXXX --order XXXXXXXX --ssl certbot --websocket yes"
    echo ""
    echo "  # Install the beta release"
    echo "  sudo ./$SCRIPT_NAME -p helpdesk -d hd.example.com -e admin@example.com -l XXXX -o XXXX \\"
    echo "       --ssl self-signed --release beta"
    echo ""
    echo "  # Network Discovery with a paid certificate, no prompts"
    echo "  sudo ./$SCRIPT_NAME -p nd -d nd.example.com -e admin@example.com -l XXXX -o XXXX \\"
    echo "       --ssl paid-ssl --certfile /root/ssl/certificate.crt --keyfile /root/ssl/private.key \\"
    echo "       --cacertfile /root/ssl/ca_bundle.crt -i /opt/faveo/nd -y"
    echo ""
    echo "  # Self-signed SSL on custom ports (e.g. another web server already uses 80/443)"
    echo "  sudo ./$SCRIPT_NAME -p helpdesk -d hd.example.com -e admin@example.com -l XXXX -o XXXX \\"
    echo "       --ssl self-signed --http-port 8080 --https-port 8443"
    echo ""
    echo "  # Remote database over SSL (no MySQL container is created)"
    echo "  sudo ./$SCRIPT_NAME -p helpdesk -d hd.example.com -e admin@example.com -l XXXX -o XXXX \\"
    echo "       --ssl certbot --db remote --db-host db.example.com --db-admin-user root \\"
    echo "       --db-admin-password 'Secret!' --db-ssl yes --db-ssl-ca /root/db/ca.pem"
    echo ""
    echo "  # Local database with your own name / user / password"
    echo "  sudo ./$SCRIPT_NAME ... --db-name helpdesk --db-user hduser --db-password 'Str0ng.Pass'"
    echo ""
    echo "  # Custom Docker subnet (if 172.24.x.x clashes with your LAN or VPN)"
    echo "  sudo ./$SCRIPT_NAME -p helpdesk -d hd.example.com -e admin@example.com -l XXXX -o XXXX \\"
    echo "       --ssl self-signed --subnet 172.30.0.0/16"
    echo ""
    echo "  # Back up an installation (choose from the list)"
    echo "  sudo ./$SCRIPT_NAME --backup"
    echo ""
    echo "  # Back up, then remove, without questions"
    echo "  sudo ./$SCRIPT_NAME --uninstall --backup -i /opt/faveo/hd.example.com -y"
    echo ""
    echo "  # Remove an installation completely"
    echo "  sudo ./$SCRIPT_NAME --uninstall -i /opt/faveo/hd.example.com"
    echo ""
    echo "  # Paid SSL passed as base64 (safe for automation)"
    echo "  sudo ./$SCRIPT_NAME ... --ssl paid-ssl --certfile \"\$(base64 -w0 cert.crt)\" \\"
    echo "       --keyfile \"\$(base64 -w0 private.key)\" --cacertfile \"\$(base64 -w0 ca_bundle.crt)\""
}

# ----------------------------------------------------------------------------
# Ports
# ----------------------------------------------------------------------------
apply_port_rules() {
    [[ "$supervisor_port" == "0" ]] && supervisor_port="none"

    if [[ "$ssl_option" == "A" ]]; then
        # Let's Encrypt validates over port 80 and the site is served on 443;
        # these are fixed for certbot installs.
        if [[ -n "$http_port" && $((10#$http_port)) -ne 80 ]] || [[ -n "$https_port" && $((10#$https_port)) -ne 443 ]]; then
            die "Let's Encrypt (certbot) requires HTTP port 80 and HTTPS port 443. Remove --http-port/--https-port, or use --ssl self-signed / paid-ssl for custom ports."
        fi
    fi

    http_port=$((10#${http_port:-80}))
    https_port=$((10#${https_port:-443}))
    [[ -z "$supervisor_port" ]] && supervisor_port=9001
    [[ "$supervisor_port" != "none" ]] && supervisor_port=$((10#$supervisor_port))

    [[ $http_port -eq $https_port ]] && die "HTTP and HTTPS ports must be different (both are $http_port)."
    if [[ "$supervisor_port" != "none" ]] && [[ $supervisor_port -eq $http_port || $supervisor_port -eq $https_port ]]; then
        die "The Supervisor port ($supervisor_port) must differ from the HTTP/HTTPS ports."
    fi
    set_site_url
}

set_site_url() {
    if [[ $https_port -eq 443 ]]; then
        site_url="https://$domainname"
    else
        site_url="https://$domainname:$https_port"
    fi
}

port_in_use() {
    local port=$1
    if command -v ss >/dev/null; then
        ss -ltnH "sport = :$port" 2>/dev/null | grep -q .
    else
        (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
    fi
}

# Name of what is listening on a port (process, or Docker container name).
port_owner() {
    local port=$1 proc names
    proc=$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -o 'users:(("[^"]*' | head -1 | cut -d'"' -f2)
    if [[ "$proc" == docker-proxy || -z "$proc" ]] && command -v docker >/dev/null; then
        names=$(docker ps --filter "publish=$port" --format '{{.Names}}' 2>/dev/null | paste -sd, -)
        [[ -n "$names" ]] && { echo "container $names"; return; }
    fi
    echo "${proc:-unknown process}"
}

# True when the port is held by the Faveo stack that is about to be replaced
# (an existing install in the chosen path, overwritten with --force / "y").
port_held_by_replaced_stack() {
    local port=$1 ids ours id
    [[ "$force" == "y" && -f "$install_dir/docker-compose.yml" ]] || return 1
    command -v docker >/dev/null || return 1
    ids=$(docker ps -q --no-trunc --filter "publish=$port" 2>/dev/null)
    [[ -n "$ids" ]] || return 1
    ours=$(cd "$install_dir" && docker compose ps -q --no-trunc 2>/dev/null)
    for id in $ids; do
        grep -q "$id" <<<"$ours" || return 1
    done
    return 0
}

port_busy() {
    local port=$1
    port_in_use "$port" && ! port_held_by_replaced_stack "$port"
}

# next_free_port <start> <exclude...>
next_free_port() {
    local p=$1; shift
    local skip
    while (( p <= 65535 )); do
        skip=""
        for x in "$@"; do [[ "$x" == "$p" ]] && skip=y; done
        [[ -z "$skip" ]] && ! port_busy "$p" && { echo "$p"; return 0; }
        p=$((p + 1))
    done
    return 1
}

# resolve_port <variable> <label> <suggest-from>
resolve_port() {
    local __var=$1 label=$2 from=$3
    local port=${!__var} owner suggest input tries=0 others=()

    port_busy "$port" || return 0
    owner=$(port_owner "$port")

    if [[ "$ssl_option" == "A" && ( "$__var" == http_port || "$__var" == https_port ) ]]; then
        die "Port $port ($label) is already in use by $owner. Let's Encrypt needs ports 80 and 443: stop that service, or use --ssl self-signed / paid-ssl with --http-port/--https-port."
    fi

    for v in http_port https_port supervisor_port; do
        [[ "$v" != "$__var" && "${!v}" != "none" ]] && others+=("${!v}")
    done
    suggest=$(next_free_port "$from" "${others[@]}") || die "No free port found for $label."

    if [[ "$auto_ports" == "y" ]]; then
        warn "Port $port ($label) is in use by $owner; using free port $suggest instead."
        printf -v "$__var" '%s' "$suggest"
        return 0
    fi

    if ! interactive; then
        die "Port $port ($label) is already in use by $owner. Choose another with --${__var//_/-} <port> (free: $suggest) or add --auto-ports."
    fi

    warn "Port $port ($label) is already in use by $owner."
    while true; do
        read -r -p "$(echo -e "${YELLOW} Enter another $label port [$suggest]: ${NC}")" input
        input=${input:-$suggest}
        if ! valid_port "$input"; then
            echo -e "${RED} '$input' is not a valid port (1-65535).${NC}"
        elif printf '%s
' "${others[@]}" | grep -qx "$((10#$input))"; then
            echo -e "${RED} Port $input is already assigned to another Faveo service.${NC}"
        elif port_busy "$((10#$input))"; then
            echo -e "${RED} Port $input is also in use by $(port_owner "$((10#$input))").${NC}"
        else
            printf -v "$__var" '%s' "$((10#$input))"
            ok "Using port $((10#$input)) for $label."
            return 0
        fi
        tries=$((tries + 1))
        [[ $tries -ge $max_retries ]] && die "Too many invalid attempts. Please rerun the script."
    done
}

# Status text for a port: "free" or "IN USE by <owner>".
port_status() {
    local port=$1
    [[ "$port" == "none" ]] && { echo "not published"; return; }
    [[ "$generate_only" == "y" ]] && { echo ""; return; }
    if port_busy "$port"; then
        echo "IN USE by $(port_owner "$port")"
    else
        echo "free"
    fi
}

# ask_port <variable> <label> ; asks for one port, current value as default.
ask_port() {
    local __var=$1 label=$2 cur=${!1} input tries=0 others=() v allow_none=""
    [[ "$__var" == supervisor_port ]] && allow_none=" (or 'none')"
    for v in http_port https_port supervisor_port; do
        [[ "$v" != "$__var" && "${!v}" != "none" ]] && others+=("${!v}")
    done
    while true; do
        read -r -p "$(echo -e "${YELLOW} $label port${allow_none} [$cur]: ${NC}")" input
        input=${input:-$cur}
        input=${input,,}
        if [[ -n "$allow_none" && ( "$input" == "none" || "$input" == "0" ) ]]; then
            printf -v "$__var" '%s' "none"
            return 0
        elif ! valid_port "$input"; then
            echo -e "${RED} '$input' is not a valid port (1-65535).${NC}"
        elif printf '%s\n' "${others[@]}" | grep -qx "$((10#$input))"; then
            echo -e "${RED} Port $input is already assigned to another Faveo service.${NC}"
        elif [[ "$generate_only" != "y" ]] && port_busy "$((10#$input))"; then
            echo -e "${RED} Port $input is in use by $(port_owner "$((10#$input))").${NC}"
        else
            printf -v "$__var" '%s' "$((10#$input))"
            return 0
        fi
        tries=$((tries + 1))
        [[ $tries -ge $max_retries ]] && die "Too many invalid attempts. Please rerun the script."
    done
}

# Interactive: show the ports that will be used and offer to change them.
ask_custom_ports() {
    interactive || return 0
    [[ "$ports_from_cli" == "y" ]] && return 0

    local row="  %-12s %-7s %s\n" answer
    echo ""
    echo -e "${CYAN} Faveo will use these ports on this server:${NC}"
    printf "$row" "HTTP"       "$http_port"       "$(port_status "$http_port")"
    printf "$row" "HTTPS"      "$https_port"      "$(port_status "$https_port")"
    printf "$row" "Supervisor" "$supervisor_port" "$(port_status "$supervisor_port")"

    if [[ "$ssl_option" == "A" ]]; then
        # Fixed ports for certbot: stop now if they are taken.
        [[ "$generate_only" != "y" ]] && { resolve_port http_port "HTTP" 8080; resolve_port https_port "HTTPS" 8443; }
        echo -e "${YELLOW} Let's Encrypt requires HTTP 80 and HTTPS 443; only the Supervisor port can be changed.${NC}"
    fi
    read -r -p "$(echo -e "${YELLOW} Do you want to use custom ports? (y/N): ${NC}")" answer
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || return 0

    if [[ "$ssl_option" != "A" ]]; then
        ask_port http_port  "HTTP"
        ask_port https_port "HTTPS"
    fi
    ask_port supervisor_port "Supervisor"
    set_site_url
    ok "Ports: HTTP $http_port, HTTPS $https_port, Supervisor $supervisor_port"
}

# First two octets of every network already used by Docker (other than this
# install's own network, which is recreated) and by the host routing table.
used_subnet_prefixes() {
    local n
    if command -v docker >/dev/null; then
        for n in $(docker network ls -q 2>/dev/null); do
            docker network inspect -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' "$n" 2>/dev/null
        done | awk -v own="${domainname}-faveo" '$1 != own { for (i = 2; i <= NF; i++) print $i }'
    fi
    ip route 2>/dev/null | awk '{print $1}'
} 2>/dev/null

choose_subnet() {
    local used cand
    used=$(used_subnet_prefixes | grep -oE '^[0-9]+\.[0-9]+' | sort -u)

    if [[ -n "$subnet" ]]; then
        grep -qx "$subnet_prefix" <<<"$used" \
            && die "Subnet $subnet overlaps a network already in use on this server. Choose another --subnet or omit it."
        return 0
    fi
    for cand in 172.{24..31} 172.{18..23} 10.{24..40}; do
        if ! grep -qx "$cand" <<<"$used"; then
            subnet_prefix=$cand
            [[ "$cand" != "172.24" && "$1" != "quiet" ]] && info "Subnet 172.24.0.0/16 is in use; using free subnet ${cand}.0.0/16 for Docker."
            return 0
        fi
    done
    die "No free /16 subnet found for the Docker network. Pass one with --subnet."
}

# Interactive: show the Docker subnet that will be used and offer to change it.
ask_custom_subnet() {
    interactive || return 0
    [[ -n "$subnet" ]] && return 0          # given with --subnet

    local answer input tries=0 used
    [[ "$generate_only" != "y" ]] && choose_subnet quiet

    echo ""
    echo -e "${CYAN} Docker network subnet for the Faveo containers: ${GREEN}${subnet_prefix}.0.0/16${NC}"
    echo -e "    (containers get ${subnet_prefix}.0.2 - ${subnet_prefix}.0.6; it must not overlap your LAN/VPN)"
    read -r -p "$(echo -e "${YELLOW} Do you want to use a custom subnet? (y/N): ${NC}")" answer
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || return 0

    used=$(used_subnet_prefixes | grep -oE '^[0-9]+\.[0-9]+' | sort -u)
    while true; do
        read -r -p "$(echo -e "${YELLOW} Subnet, e.g. 172.30.0.0/16 or 10.50.0.0/16 [${subnet_prefix}.0.0/16]: ${NC}")" input
        input=${input:-${subnet_prefix}.0.0/16}
        if ! parse_subnet "$input"; then
            echo -e "${RED} '$input' is not valid. Use the form x.y.0.0/16, e.g. 172.30.0.0/16.${NC}"
        elif [[ "$generate_only" != "y" ]] && grep -qx "$PARSED_PREFIX" <<<"$used"; then
            echo -e "${RED} $input overlaps a network already in use on this server.${NC}"
        else
            subnet=$input
            subnet_prefix=$PARSED_PREFIX
            ok "Using Docker subnet $subnet."
            return 0
        fi
        tries=$((tries + 1))
        [[ $tries -ge $max_retries ]] && die "Too many invalid attempts. Please rerun the script."
    done
}

# Check the chosen host ports before anything is installed.
resolve_ports() {
    [[ "$generate_only" == "y" ]] && return 0
    choose_subnet
    resolve_port http_port  "HTTP"  8080
    resolve_port https_port "HTTPS" 8443
    [[ "$supervisor_port" != "none" ]] && resolve_port supervisor_port "Supervisor" 9002
    set_site_url
}

# ----------------------------------------------------------------------------
# System detection (shown in --help)
# ----------------------------------------------------------------------------
detect_system() {
    local id="" id_like=""
    os_name="Unknown"
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        os_name=$(. /etc/os-release; echo "${PRETTY_NAME:-$NAME $VERSION_ID}")
        id=$(. /etc/os-release; echo "${ID,,}")
        id_like=$(. /etc/os-release; echo "${ID_LIKE,,}")
    fi
    arch=$(uname -m)

    if command -v apt-get >/dev/null; then pkg_mgr="apt"
    elif command -v dnf >/dev/null;   then pkg_mgr="dnf"
    elif command -v yum >/dev/null;   then pkg_mgr="yum"
    elif command -v zypper >/dev/null; then pkg_mgr="zypper"
    elif command -v pacman >/dev/null; then pkg_mgr="pacman"
    elif command -v apk >/dev/null;    then pkg_mgr="apk"
    else pkg_mgr="Unknown"; fi

    docker_ver=$(docker --version 2>/dev/null) || docker_ver="Not installed"
    compose_ver=$(docker compose version 2>/dev/null) || compose_ver="Not installed"

    if command -v getenforce >/dev/null; then
        selinux=$(getenforce 2>/dev/null || echo "Unknown")
    elif [[ -d /sys/fs/selinux ]]; then
        selinux="Present"
    else
        selinux="Not present"
    fi

    if command -v ufw >/dev/null; then firewall="ufw"
    elif command -v firewall-cmd >/dev/null; then firewall="firewalld"
    elif command -v nft >/dev/null; then firewall="nftables"
    elif command -v iptables >/dev/null; then firewall="iptables"
    else firewall="None detected"; fi

    run_as=$(id -un 2>/dev/null || echo "$USER")

    case " $id $id_like " in
        *" ubuntu "*|*" debian "*)                         os_family="debian" ;;
        *" amzn "*)                                        os_family="amazon" ;;
        *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*) os_family="rhel" ;;
        *" sles "*|*" suse "*|*" opensuse"*)               os_family="suse" ;;
        *" arch "*|*" manjaro "*|*" endeavouros "*)        os_family="arch" ;;
        *" alpine "*)                                      os_family="alpine" ;;
        *)                                                 os_family="other" ;;
    esac
    os_id=$id
}

print_system_info() {
    local o="  %-18s : %s\n" path dir_hint

    detect_system
    local hp=${http_port:-80} sp=${https_port:-443} vp=${supervisor_port:-9001}
    [[ "$vp" == "0" ]] && vp="none"

    if [[ -n "$install_dir" ]]; then
        path=$(realpath -m "$install_dir")
    elif [[ -n "$domainname" ]]; then
        path="/opt/faveo/$domainname"
    else
        path="/opt/faveo/<domain>"
        dir_hint=$'\n  (add --install-dir <path> or --domain <domain> to --help to show the exact path)'
    fi

    echo ""
    echo -e "${CYAN}Detected system:${NC}"
    printf "$o" "Operating System" "$os_name"
    printf "$o" "Architecture"     "$arch"
    printf "$o" "Package Manager"  "$pkg_mgr"
    printf "$o" "Docker"           "$docker_ver"
    printf "$o" "Docker Compose"   "$compose_ver"
    printf "$o" "SELinux"          "$selinux"
    printf "$o" "Firewall tool"    "$firewall"
    printf "$o" "Running as"       "$run_as"

    echo ""
    echo -e "${CYAN}Notes for this OS:${NC}"
    case "$os_family" in
        debian)
            local repo="ubuntu"; [[ "$os_id" == "debian" ]] && repo="debian"
            echo "  - Docker is installed from Docker's official apt repository (download.docker.com/linux/$repo)." ;;
        rhel)
            echo "  - Docker is installed from Docker's official repository: dnf config-manager --add-repo"
            echo "    https://download.docker.com/linux/$( [[ "$os_id" == "fedora" ]] && echo fedora || echo rhel )/docker-ce.repo && dnf install docker-ce docker-compose-plugin" ;;
        amazon)
            echo "  - Docker is installed from the Amazon Linux repository: $pkg_mgr install -y docker"
            echo "    (the Compose plugin is installed separately into /usr/local/lib/docker/cli-plugins)." ;;
        suse)
            echo "  - Docker is installed from the distribution repository: zypper install docker docker-compose" ;;
        arch)
            echo "  - Docker is installed from the distribution repository: pacman -S docker docker-compose" ;;
        alpine)
            echo "  - Docker is installed from the distribution repository: apk add docker docker-cli-compose" ;;
        *)
            echo "  - Install Docker Engine and the Compose plugin: https://docs.docker.com/engine/install/" ;;
    esac
    [[ "$docker_ver" == "Not installed" ]] && echo "  - Docker is NOT installed yet; add --install-docker (or answer yes when asked) to install it."
    [[ "$compose_ver" == "Not installed" ]] && echo "  - The Docker Compose plugin ('docker compose') is NOT installed yet."
    case "$firewall" in
        ufw)       echo "  - If ufw is active, allow web traffic: sudo ufw allow ${hp},${sp}/tcp" ;;
        firewalld) echo "  - If firewalld is running, allow web traffic:"
                   echo "    sudo firewall-cmd --permanent --add-port=${hp}/tcp --add-port=${sp}/tcp && sudo firewall-cmd --reload" ;;
        nftables|iptables)
                   echo "  - Make sure TCP ports $hp and $sp are allowed in your $firewall rules." ;;
    esac
    if [[ "$selinux" == "Enforcing" ]]; then
        echo "  - SELinux is enforcing: the installer adds the ':z' label to every bind mount automatically,"
        echo "    so the containers can read the installation path. Nothing to do manually."
    fi
    case "$arch" in
        x86_64|amd64|aarch64|arm64) ;;
        *) echo "  - Architecture $arch is NOT supported (ionCube loaders exist for x86_64 and aarch64 only)." ;;
    esac
    [[ "$run_as" != "root" ]] && echo "  - You are not root; run the installer with sudo."
    echo "  - Let's Encrypt (certbot) needs ports 80 and 443 free; with self-signed or paid SSL use"
    echo "    --http-port / --https-port if they are taken."

    echo ""
    echo -e "${CYAN}Port status on this server:${NC}"
    local label port
    for label in "HTTP:$hp" "HTTPS:$sp" "Supervisor:$vp"; do
        port=${label#*:}
        [[ "$port" == "none" ]] && continue
        if port_in_use "$port"; then
            printf "$o" "${label%%:*} ($port)" "IN USE by $(port_owner "$port")"
        else
            printf "$o" "${label%%:*} ($port)" "free"
        fi
    done

    if [[ -n "$subnet" ]]; then
        printf "$o" "Docker subnet" "$subnet (from --subnet)"
    elif command -v docker >/dev/null; then
        # Subshell so the lookup does not change this run's settings.
        printf "$o" "Docker subnet" "$(choose_subnet quiet >/dev/null 2>&1; echo "${subnet_prefix}.0.0/16") (first free; change with --subnet)"
    fi

    echo ""
    echo -e "${CYAN}Docker Compose commands for this system${NC} (run from $path)${dir_hint}:"
    echo "  cd $path"
    printf "$o" "Start containers"   "docker compose up -d"
    printf "$o" "Stop containers"    "docker compose down"
    printf "$o" "Restart containers" "docker compose down && docker compose up -d"
    printf "$o" "Container status"   "docker compose ps"
    printf "$o" "Follow logs"        "docker compose logs -f"
    printf "$o" "Rebuild images"     "docker compose up -d --build"

    echo ""
    echo -e "${CYAN}Docker service commands for this system:${NC}"
    if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
        printf "$o" "Start Docker"   "systemctl start docker"
        printf "$o" "Stop Docker"    "systemctl stop docker"
        printf "$o" "Enable on boot" "systemctl enable docker"
        printf "$o" "Docker status"  "systemctl status docker"
    else
        printf "$o" "Start Docker"   "service docker start"
        printf "$o" "Stop Docker"    "service docker stop"
        printf "$o" "Enable on boot" "update-rc.d docker defaults   (or chkconfig docker on)"
        printf "$o" "Docker status"  "service docker status"
    fi
}

# ----------------------------------------------------------------------------
# Validators
# ----------------------------------------------------------------------------
EMAIL_RE="^[A-Za-z0-9!#\$%&'*+/=?^_\`{|}~-]+(\.[A-Za-z0-9!#\$%&'*+/=?^_\`{|}~-]+)*@([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$"
DOMAIN_RE='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'

valid_product() { [[ "$1" =~ ^(helpdesk|nd)$ ]]; }
valid_domain()  { [[ "$1" =~ $DOMAIN_RE ]]; }
valid_email()   { [[ "$1" =~ $EMAIL_RE ]]; }
valid_code()    { [[ -n "$1" && "$1" =~ ^[A-Za-z0-9-]+$ ]]; }
# parse_subnet <value> -> sets PARSED_PREFIX ("x.y") for a valid x.y.0.0/16
parse_subnet() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.0\.0/16$ ]] || return 1
    (( BASH_REMATCH[1] <= 255 && BASH_REMATCH[2] <= 255 )) || return 1
    PARSED_PREFIX="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
}
DB_HOST_RE='^([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9])(\.([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]))*$'
DB_IPV4_RE='^((25[0-5]|(2[0-4]|1[0-9]|[1-9])?[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9])?[0-9])$'
valid_db_host() { [[ "$1" =~ $DB_HOST_RE || "$1" =~ $DB_IPV4_RE ]]; }
valid_db_ident(){ [[ "$1" =~ ^[A-Za-z0-9_]{1,32}$ ]]; }
# Passwords end up in SQL, .env and the web installer: keep them shell/SQL safe.
valid_db_pass() { [[ "$1" =~ ^[A-Za-z0-9@#%^*_+=.,:!?-]{8,64}$ ]]; }
DB_PASS_RULE="8-64 characters: letters, digits and @ # % ^ * _ + = . , : ! ? -"
valid_port()    { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_order()   { valid_code "${1#\#}"; }

# Map the install.sh SSL names (and the old A/B/C letters) to A/B/C.
normalize_ssl() {
    case "${1,,}" in
        a|certbot|letsencrypt|lets-encrypt)  echo "A" ;;
        b|self-signed|selfsigned|self)       echo "B" ;;
        c|paid-ssl|paid|paidssl)             echo "C" ;;
        *) return 1 ;;
    esac
}

normalize_yesno() {
    case "${1,,}" in
        y|yes) echo "y" ;;
        n|no)  echo "n" ;;
        *) return 1 ;;
    esac
}

ssl_name() {
    case "$1" in
        A) echo "certbot (Let's Encrypt)" ;;
        B) echo "self-signed" ;;
        C) echo "paid-ssl" ;;
    esac
}

# ----------------------------------------------------------------------------
# Paid SSL material (same rules as install.sh)
#
# A value may be:
#   1) a path to an existing PEM file on this server
#   2) base64-encoded PEM content, e.g. --certfile "$(base64 -w0 cert.crt)"
#   3) raw PEM content
# It is validated with openssl and written to <dest>. Returns non-zero if the
# value is not a valid certificate / private key.
# ----------------------------------------------------------------------------
pem_ok() {
    local file=$1 kind=$2
    if [[ "$kind" == "key" ]]; then
        openssl pkey -noout -in "$file" &>/dev/null
    else
        openssl x509 -noout -in "$file" &>/dev/null
    fi
}

resolve_cert_arg() {
    local value=$1 dest=$2 kind=$3 decoded
    [[ -z "$value" ]] && return 1

    if [[ -f "$value" ]]; then
        pem_ok "$value" "$kind" || return 1
        cp "$value" "$dest" && chmod 600 "$dest"
        return 0
    fi

    decoded=$(printf '%s' "$value" | base64 -d 2>/dev/null)
    if [[ -n "$decoded" ]]; then
        printf '%s\n' "$decoded" > "$dest"
        chmod 600 "$dest"
        pem_ok "$dest" "$kind" && return 0
    fi

    printf '%s\n' "$value" > "$dest"
    chmod 600 "$dest"
    pem_ok "$dest" "$kind" && return 0

    rm -f "$dest"
    return 1
}

# Interactive: one prompt per file that accepts EITHER a file path on this
# server OR the pasted PEM content (or a base64 string). The type of input is
# detected automatically:
#   - starts with "-----BEGIN"  -> pasted PEM; lines are read until the last
#                                   "-----END ...-----" (bundles with several
#                                   certificates are supported)
#   - an existing file          -> used as the path
#   - anything else             -> tried as base64 PEM
collect_cert_material() {
    local desc=$1 dest=$2 kind=$3 optional=${4:-n}
    local tries=0 input line value

    while true; do
        echo -e "${CYAN} $desc${NC}"
        echo -e "${GREEN}   Enter the file path (e.g. /root/ssl/$desc)${NC}"
        echo -e "${GREEN}   or paste the content starting with -----BEGIN ...-----${NC}"
        read -r -p "$(echo -e "${YELLOW} Path or content of $desc: ${NC}")" input
        input=${input%$'\r'}

        if [[ "$input" == -----BEGIN* ]]; then
            # Pasted PEM: read the rest of the block(s).
            value="$input"
            while IFS= read -r line; do
                line=${line%$'\r'}
                value+=$'\n'"$line"
                if [[ "$line" == -----END*----- ]]; then
                    # More blocks (e.g. a CA bundle) arrive immediately when pasted.
                    IFS= read -r -t 1 line || break
                    line=${line%$'\r'}
                    value+=$'\n'"$line"
                fi
            done
            printf '%s\n' "$value" > "$dest"
            chmod 600 "$dest"
            if pem_ok "$dest" "$kind"; then
                ok "Pasted $desc saved and validated."
                return 0
            fi
            rm -f "$dest"
            echo -e "${RED} The pasted content is not a valid PEM $kind.${NC}"
        elif [[ -n "$input" ]]; then
            [[ "$input" == "~/"* ]] && input="$HOME${input:1}"
            if [[ -f "$input" ]]; then
                if pem_ok "$input" "$kind"; then
                    cp "$input" "$dest" && chmod 600 "$dest"
                    ok "Using '$input' for $desc."
                    return 0
                fi
                echo -e "${RED} '$input' is not a valid PEM $kind.${NC}"
            elif resolve_cert_arg "$input" "$dest" "$kind"; then
                ok "Base64 $desc decoded and validated."
                return 0
            elif [[ "$input" == /* || "$input" == ./* || "$input" == *.* ]]; then
                echo -e "${RED} File '$input' does not exist.${NC}"
            else
                echo -e "${RED} Not a valid file path or PEM $kind content.${NC}"
            fi
        elif [[ "$optional" == "y" ]]; then
            echo -e "${YELLOW} Skipped $desc.${NC}"
            return 2
        else
            echo -e "${RED} No input received.${NC}"
        fi

        tries=$((tries + 1))
        [[ $tries -ge $max_retries ]] && die "Too many invalid attempts for $desc. Please rerun the script."
        echo -e "${YELLOW} Please try again. ($tries/$max_retries)${NC}"
    done
}

# Extra checks once all three files are present.
check_paid_ssl_bundle() {
    local crt="$STAGE_DIR/faveolocal.crt" key="$STAGE_DIR/private.key" c k

    c=$(openssl x509 -noout -pubkey -in "$crt" 2>/dev/null | openssl sha256)
    k=$(openssl pkey -pubout -in "$key" 2>/dev/null | openssl sha256)
    [[ -n "$c" && "$c" == "$k" ]] || die "The private key does not match the certificate."

    openssl x509 -checkend 0 -noout -in "$crt" >/dev/null 2>&1 \
        || warn "The certificate has expired."
    if [[ -n "$domainname" ]] && ! openssl x509 -noout -checkhost "$domainname" -in "$crt" 2>/dev/null | grep -q "does match"; then
        warn "The certificate does not appear to cover '$domainname'."
    fi
    ok "Paid SSL certificate, key and CA bundle validated."
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
need_value() {
    # Values may legitimately start with dashes (raw PEM "-----BEGIN ..."), so only
    # reject a missing value or one that looks like the next --option.
    [[ -n "$2" && ! "$2" =~ ^--?[A-Za-z][A-Za-z-]*$ ]] || die "Option '$1' requires a value. Run '$SCRIPT_NAME --help' for usage."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help|-help)                    show_help="y"; shift ;;
        -p|--product)                       need_value "$1" "$2"; product=${2,,}; shift 2 ;;
        -d|--domain|-domainname|--domainname) need_value "$1" "$2"; domainname=$2; shift 2 ;;
        -e|--email|-email)                  need_value "$1" "$2"; email=$2; shift 2 ;;
        -l|--license|-license)              need_value "$1" "$2"; license=$2; shift 2 ;;
        -o|--order|--orderno|-orderno)      need_value "$1" "$2"; orderno=$2; shift 2 ;;
        -s|--ssl|-ssl)                      need_value "$1" "$2"; ssl_raw=$2; shift 2 ;;
        -r|--release)                       need_value "$1" "$2"; release=${2,,}; shift 2 ;;
        -w|--websocket|-websocket)          need_value "$1" "$2"; websocket_raw=$2; shift 2 ;;
        --certfile|--ssl-cert)              need_value "$1" "$2"; certfile=$2; shift 2 ;;
        --keyfile|--ssl-key)                need_value "$1" "$2"; keyfile=$2; shift 2 ;;
        --cacertfile|--ssl-ca)              need_value "$1" "$2"; cacertfile=$2; shift 2 ;;
        -i|--install-dir)                   need_value "$1" "$2"; install_dir=$2; shift 2 ;;
        --db-name)                          need_value "$1" "$2"; db_name=$2; db_custom_from_cli="y"; shift 2 ;;
        --db-user)                          need_value "$1" "$2"; db_user=$2; db_custom_from_cli="y"; shift 2 ;;
        --db-password)                      need_value "$1" "$2"; db_password=$2; db_custom_from_cli="y"; shift 2 ;;
        --db-root-password)                 need_value "$1" "$2"; db_root_password=$2; shift 2 ;;
        --db|--db-location)                 need_value "$1" "$2"; db_location=${2,,}; shift 2 ;;
        --sqlreser)                         need_value "$1" "$2"; [[ "${2,,}" == "yes" ]] && db_location="remote" || db_location="local"; shift 2 ;;
        --db-host|--sqlhost)                need_value "$1" "$2"; db_host=$2; shift 2 ;;
        --db-port|--sqlport)                need_value "$1" "$2"; db_port=$2; shift 2 ;;
        --db-admin-user|--sqlusername)      need_value "$1" "$2"; db_admin_user=$2; shift 2 ;;
        --db-admin-password|--sqlpassword)  [[ $# -ge 2 ]] || die "Option '$1' requires a value."; db_admin_password=$2; db_admin_pw_given="y"; shift 2 ;;
        --db-ssl|--sqlsecure)               need_value "$1" "$2"; db_ssl=${2,,}; shift 2 ;;
        --db-ssl-ca|--sqlsslca)             need_value "$1" "$2"; db_ssl_ca=$2; shift 2 ;;
        --db-ssl-cert|--sqlsslcert)         need_value "$1" "$2"; db_ssl_cert=$2; shift 2 ;;
        --db-ssl-key|--sqlsslkey)           need_value "$1" "$2"; db_ssl_key=$2; shift 2 ;;
        --db-ssl-verify|--sqlsslverify|--sslverify) need_value "$1" "$2"; db_ssl_verify=${2,,}; shift 2 ;;
        --timezone)                         need_value "$1" "$2"; timezone=$2; shift 2 ;;
        --php|--php-version)                need_value "$1" "$2"; php_version=$2; shift 2 ;;
        --node|--node-version)              need_value "$1" "$2"; node_version=$2; shift 2 ;;
        -g|--generate-only)                 generate_only="y"; shift ;;
        -y|--yes)                           assume_yes="y"; shift ;;
        -f|--force)                         force="y"; shift ;;
        --no-banner)                        show_banner="n"; shift ;;
        --http-port)                        need_value "$1" "$2"; http_port=$2; ports_from_cli="y"; shift 2 ;;
        --https-port)                       need_value "$1" "$2"; https_port=$2; ports_from_cli="y"; shift 2 ;;
        --supervisor-port)                  need_value "$1" "$2"; supervisor_port=${2,,}; ports_from_cli="y"; shift 2 ;;
        --auto-ports)                       auto_ports="y"; shift ;;
        --subnet)                           need_value "$1" "$2"; subnet=$2; shift 2 ;;
        --uninstall|--rollback)             uninstall="y"; shift ;;
        --backup)                           do_backup="y"; shift ;;
        --backup-dir)                       need_value "$1" "$2"; backup_dir=$2; shift 2 ;;
        --install-docker)                   install_docker="y"; shift ;;
        --keep-on-failure)                  keep_on_failure="y"; shift ;;
        *) die "Unknown option: $1. Run '$SCRIPT_NAME --help' for usage." ;;
    esac
done

# Help is printed after parsing so --install-dir / --domain can be reflected in it.
if [[ "$show_help" == "y" ]]; then
    usage
    print_system_info
    exit 0
fi

interactive() { [[ "$assume_yes" != "y" && -t 0 ]]; }

# openssl is needed to validate certificates and generate passwords. Minimal
# images (Debian, Alma/Rocky, Fedora, Alpine...) may not ship it: install it.
if ! command -v openssl >/dev/null; then
    if [[ $EUID -eq 0 ]]; then
        info "Installing openssl..."
        if   command -v apt-get >/dev/null; then apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssl >/dev/null 2>&1
        elif command -v dnf     >/dev/null; then dnf install -y -q openssl >/dev/null 2>&1
        elif command -v yum     >/dev/null; then yum install -y -q openssl >/dev/null 2>&1
        elif command -v zypper  >/dev/null; then zypper -n -q install openssl >/dev/null 2>&1
        elif command -v pacman  >/dev/null; then pacman -Sy --noconfirm --needed openssl >/dev/null 2>&1
        elif command -v apk     >/dev/null; then apk add --no-cache -q openssl >/dev/null 2>&1
        fi
    fi
    command -v openssl >/dev/null \
        || die "openssl is required. Install it with your package manager (apt-get / dnf / yum / zypper / pacman / apk install openssl) and rerun."
fi

# --uninstall is handled after the functions are defined (see below).

# ----------------------------------------------------------------------------
# Validate supplied values (before anything is changed on the system)
# ----------------------------------------------------------------------------
errors=()
orderno=${orderno#\#}

[[ -n "$product"    ]] && ! valid_product "$product"   && errors+=("--product: must be helpdesk or nd.")
[[ -n "$domainname" ]] && ! valid_domain "$domainname" && errors+=("--domain: '$domainname' is not a valid domain name.")
[[ -n "$email"      ]] && ! valid_email "$email"       && errors+=("--email: invalid format.")
[[ -n "$license"    ]] && ! valid_code "$license"      && errors+=("--license: only letters, digits and '-' are allowed.")
[[ -n "$orderno"    ]] && ! valid_code "$orderno"      && errors+=("--order: only letters, digits and '-' are allowed.")
[[ -n "$release"    && ! "$release" =~ ^(official|rc|beta)$ ]] && errors+=("--release: must be official, rc, or beta.")
if [[ -n "$ssl_raw" ]]; then
    ssl_option=$(normalize_ssl "$ssl_raw") || errors+=("--ssl: must be certbot, self-signed or paid-ssl.")
fi
if [[ -n "$websocket_raw" ]]; then
    websocket_enable=$(normalize_yesno "$websocket_raw") || errors+=("--websocket: must be yes or no.")
fi
[[ "$php_version" =~ ^([8-9]|[1-9][0-9])\.[0-9]+$ ]] || errors+=("--php: must be version 8.x or above (e.g. 8.4).")
[[ "$node_version" =~ ^[0-9]+$ ]]                    || errors+=("--node: must be a major version number (e.g. 22).")
valid_db_ident "$db_name"                            || errors+=("--db-name: letters, digits and underscore only (max 32).")
valid_db_ident "$db_user"                            || errors+=("--db-user: letters, digits and underscore only (max 32).")
[[ -n "$db_password"      ]] && ! valid_db_pass "$db_password"      && errors+=("--db-password: $DB_PASS_RULE.")
[[ -n "$db_root_password" ]] && ! valid_db_pass "$db_root_password" && errors+=("--db-root-password: $DB_PASS_RULE.")
[[ -z "$db_location" && -n "$db_host" ]] && db_location="remote"
[[ -n "$db_location" && ! "$db_location" =~ ^(local|remote)$ ]] && errors+=("--db: must be local or remote.")
[[ -n "$db_host" ]] && ! valid_db_host "$db_host" && errors+=("--db-host: must be a valid hostname or IPv4 address.")
[[ -n "$db_port" ]] && ! valid_port "$db_port"    && errors+=("--db-port: must be a number between 1 and 65535.")
[[ -n "$db_ssl" && ! "$db_ssl" =~ ^(yes|no)$ ]]               && errors+=("--db-ssl: must be yes or no.")
[[ -n "$db_ssl_verify" && ! "$db_ssl_verify" =~ ^(yes|no)$ ]] && errors+=("--db-ssl-verify: must be yes or no.")
if [[ "$db_location" == "remote" && "$db_ssl" == "yes" ]]; then
    [[ -n "$db_ssl_ca"   ]] && { resolve_cert_arg "$db_ssl_ca"   "$STAGE_DIR/db-ca.pem"   cert || errors+=("--db-ssl-ca: not a valid path or PEM certificate (plain or base64)."); }
    [[ -n "$db_ssl_cert" ]] && { resolve_cert_arg "$db_ssl_cert" "$STAGE_DIR/db-cert.pem" cert || errors+=("--db-ssl-cert: not a valid path or PEM certificate (plain or base64)."); }
    [[ -n "$db_ssl_key"  ]] && { resolve_cert_arg "$db_ssl_key"  "$STAGE_DIR/db-key.pem"  key  || errors+=("--db-ssl-key: not a valid path or PEM private key (plain or base64)."); }
    [[ -n "$db_ssl_cert" && -z "$db_ssl_key" ]] && errors+=("--db-ssl-key is required when --db-ssl-cert is given.")
fi
if [[ -n "$subnet" ]]; then
    if parse_subnet "$subnet"; then
        subnet_prefix=$PARSED_PREFIX
    else
        errors+=("--subnet: must look like 172.30.0.0/16 (a /16 network).")
    fi
fi
[[ -n "$http_port"  ]] && ! valid_port "$http_port"  && errors+=("--http-port: must be a number between 1 and 65535.")
[[ -n "$https_port" ]] && ! valid_port "$https_port" && errors+=("--https-port: must be a number between 1 and 65535.")
if [[ -n "$supervisor_port" && "$supervisor_port" != "none" && "$supervisor_port" != "0" ]]; then
    valid_port "$supervisor_port" || errors+=("--supervisor-port: must be a number between 1 and 65535, or none.")
fi

if [[ "$ssl_option" == "C" ]]; then
    [[ -n "$certfile"   ]] && { resolve_cert_arg "$certfile"   "$STAGE_DIR/faveolocal.crt"  cert || errors+=("--certfile: not a valid path or PEM certificate (plain or base64)."); }
    [[ -n "$keyfile"    ]] && { resolve_cert_arg "$keyfile"    "$STAGE_DIR/private.key"     key  || errors+=("--keyfile: not a valid path or PEM private key (plain or base64)."); }
    [[ -n "$cacertfile" ]] && { resolve_cert_arg "$cacertfile" "$STAGE_DIR/faveorootCA.crt" cert || errors+=("--cacertfile: not a valid path or PEM certificate (plain or base64)."); }
elif [[ -n "$certfile$keyfile$cacertfile" && -n "$ssl_option" ]]; then
    warn "--certfile/--keyfile/--cacertfile are only used with --ssl paid-ssl; ignoring them."
fi

# Without a terminal (or with --yes) nothing can be asked, so everything must be given.
if ! interactive && [[ "$uninstall" != "y" && "$do_backup" != "y" && "$db_location" == "remote" ]]; then
    [[ -z "$db_host" ]] && errors+=("--db-host is required for a remote database.")
    [[ "$db_admin_pw_given" != "y" ]] && errors+=("--db-admin-password is required for a remote database.")
    [[ "$db_ssl" == "yes" && -z "$db_ssl_ca" ]] && errors+=("--db-ssl-ca is required with --db-ssl yes.")
fi
if ! interactive && [[ "$uninstall" != "y" && "$do_backup" != "y" ]]; then
    [[ -z "$product"    ]] && errors+=("--product is required (helpdesk or nd).")
    [[ -z "$domainname" ]] && errors+=("--domain is required.")
    [[ -z "$email"      ]] && errors+=("--email is required.")
    [[ -z "$license"    ]] && errors+=("--license is required.")
    [[ -z "$orderno"    ]] && errors+=("--order is required.")
    [[ -z "$ssl_option" && -z "$ssl_raw" ]] && errors+=("--ssl is required (certbot, self-signed or paid-ssl).")
    if [[ "$ssl_option" == "C" ]]; then
        [[ -z "$certfile"   ]] && errors+=("--certfile is required for paid-ssl.")
        [[ -z "$keyfile"    ]] && errors+=("--keyfile is required for paid-ssl.")
        [[ -z "$cacertfile" ]] && errors+=("--cacertfile is required for paid-ssl.")
    fi
fi

if [[ ${#errors[@]} -gt 0 ]]; then
    for e in "${errors[@]}"; do echo -e "${RED}[ERROR]${NC} $e" >&2; done
    echo "" >&2
    echo "Run '$SCRIPT_NAME --help' for usage." >&2
    exit 1
fi

[[ "$generate_only" == "y" || $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."

# ----------------------------------------------------------------------------
# Remote database
# ----------------------------------------------------------------------------
# remote_mysql <user> <password> [mysql args...] ; runs the MySQL client in a
# throw-away container on the host network (works the same on every host OS).
remote_mysql() {
    local user=$1 pass=$2; shift 2
    local args=(-h "$db_host" -P "$db_port" -u "$user" --connect-timeout=10 -N -B)
    local vol=()
    if [[ "$db_ssl" == "yes" ]]; then
        vol=(-v "$STAGE_DIR:/dbssl:ro$(selinux_enforcing && echo ,z)")
        args+=(--ssl-ca=/dbssl/db-ca.pem)
        [[ -f "$STAGE_DIR/db-cert.pem" ]] && args+=(--ssl-cert=/dbssl/db-cert.pem)
        [[ -f "$STAGE_DIR/db-key.pem"  ]] && args+=(--ssl-key=/dbssl/db-key.pem)
        [[ "$db_ssl_verify" == "yes" ]] && args+=(--ssl-mode=VERIFY_IDENTITY) || args+=(--ssl-mode=VERIFY_CA)
    fi
    docker run --rm -i --network host -e MYSQL_PWD="$pass" "${vol[@]}" mysql:8.4.11 mysql "${args[@]}" "$@"
}

# Before installing: check the server is reachable with the admin account.
remote_db_check() {
    local out ver exists tables
    info "Testing the connection to the remote database $db_host:$db_port as '$db_admin_user'..."
    out=$(remote_mysql "$db_admin_user" "$db_admin_password" -e "SELECT VERSION();" 2>&1) \
        || die "Could not connect to the remote database at $db_host:$db_port: $(tail -1 <<<"$out")"
    ver=$(tail -1 <<<"$out")
    ok "Connected to the remote database (server version $ver)."

    exists=$(remote_mysql "$db_admin_user" "$db_admin_password" -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$db_name';" 2>/dev/null)
    if [[ "$exists" == "1" ]]; then
        tables=$(remote_mysql "$db_admin_user" "$db_admin_password" -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$db_name';" 2>/dev/null)
        if [[ "${tables:-0}" -gt 0 ]]; then
            warn "Database '$db_name' already exists on the server and has $tables table(s)."
            if interactive; then
                local a; ask_yes_no a "Use it anyway? (the Faveo installer needs an empty database)" n
                [[ "$a" == "yes" ]] || die "Choose another database name (--db-name) and run the installer again."
            else
                die "Database '$db_name' on $db_host is not empty. Use another --db-name."
            fi
        fi
        RB_REMOTE_DB_EXISTED="y"
    fi
    [[ "$(remote_mysql "$db_admin_user" "$db_admin_password" -e "SELECT COUNT(*) FROM mysql.user WHERE user='$db_user' AND host='%';" 2>/dev/null)" == "1" ]] \
        && RB_REMOTE_USER_EXISTED="y"
}

# Create the Faveo database and user, then log in as that user to prove it works.
remote_db_create() {
    local out
    info "Creating database '$db_name' and user '$db_user' on $db_host..."
    out=$(remote_mysql "$db_admin_user" "$db_admin_password" 2>&1 <<SQL
CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$db_user'@'%' IDENTIFIED BY '$db_user_pw';
ALTER USER '$db_user'@'%' IDENTIFIED BY '$db_user_pw';
GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'%';
FLUSH PRIVILEGES;
SQL
    ) || die "Could not create the database/user on $db_host (does '$db_admin_user' have CREATE USER and GRANT privileges?): $(tail -1 <<<"$out")"
    [[ "${RB_REMOTE_DB_EXISTED:-n}" != "y" ]] && RB_REMOTE_DB_CREATED="y"
    [[ "${RB_REMOTE_USER_EXISTED:-n}" != "y" ]] && RB_REMOTE_USER_CREATED="y"

    out=$(remote_mysql "$db_user" "$db_user_pw" -e "USE \`$db_name\`; SELECT 1;" 2>&1) \
        || die "Database user '$db_user' could not log in to $db_host: $(tail -1 <<<"$out")"
    ok "Remote database '$db_name' and user '$db_user' are ready."
}

# Rollback: remove only what this run created on the remote server.
remote_db_rollback() {
    [[ "$db_location" == "remote" ]] || return 0
    if [[ "${RB_REMOTE_DB_CREATED:-n}" == "y" ]]; then
        remote_mysql "$db_admin_user" "$db_admin_password" -e "DROP DATABASE IF EXISTS \`$db_name\`;" >/dev/null 2>&1 \
            && step_done "Dropped remote database $db_name on $db_host (created by this run)"
    fi
    if [[ "${RB_REMOTE_USER_CREATED:-n}" == "y" ]]; then
        remote_mysql "$db_admin_user" "$db_admin_password" -e "DROP USER IF EXISTS '$db_user'@'%';" >/dev/null 2>&1 \
            && step_done "Dropped remote database user $db_user (created by this run)"
    fi
}

# ----------------------------------------------------------------------------
# Rollback / uninstall
# ----------------------------------------------------------------------------
# Remove a Faveo image only when no other container (another install) uses it.
remove_image_if_unused() {
    local img=$1
    docker image inspect "$img" >/dev/null 2>&1 || return 0
    if [[ -n "$(docker ps -aq --filter "ancestor=$img" 2>/dev/null)" ]]; then
        warn "Image $img is still used by other containers; keeping it."
        return 0
    fi
    docker rmi "$img" >/dev/null 2>&1 && step_done "Removed image $img"
}

# rollback_install <dir> <domain> <remove_images:y|n> <remove_cron:y|n>
step_done() { echo -e "   ${GREEN}✔${NC} $*"; }

# rollback_install <dir> <domain> <remove_images:y|n> <remove_cron:y|n> [uninstall|rollback]
rollback_install() {
    local dir=$1 dom=$2 images=$3 cron=$4 mode=${5:-rollback} img n ids

    echo ""
    if [[ "$mode" == "uninstall" ]]; then
        echo -e "${CYAN} Uninstalling the Faveo Docker installation for ${dom:-this server}...${NC}"
    else
        echo -e "${YELLOW} Rolling back the incomplete Faveo installation for ${dom:-this server}...${NC}"
    fi

    # Temporary helper containers that may be left by an interrupted step.
    docker rm -f apache-cert selfsign_ssl >/dev/null 2>&1 || true
    docker rmi selfsign_ssl >/dev/null 2>&1 || true

    n=0
    [[ -n "$dom" ]] && n=$(docker ps -aq --filter "name=^${dom}-(apache|mysql|redis|supervisor|meilisearch)$" 2>/dev/null | wc -l)
    if [[ -n "$dir" && -f "$dir/docker-compose.yml" ]]; then
        (cd "$dir" && docker compose down --remove-orphans --timeout 20 >/dev/null 2>&1)
    fi
    # Containers named after the domain that compose did not catch (e.g. half-created).
    if [[ -n "$dom" ]]; then
        ids=$(docker ps -aq --filter "name=^${dom}-(apache|mysql|redis|supervisor|meilisearch)$" 2>/dev/null)
        [[ -n "$ids" ]] && docker rm -f $ids >/dev/null 2>&1
        [[ $n -gt 0 ]] && step_done "Stopped and removed $n container(s)"
        docker network rm "${dom}-faveo" >/dev/null 2>&1 && step_done "Removed Docker network ${dom}-faveo"
    fi

    if [[ "$images" == "y" ]]; then
        for img in "${RB_IMAGES[@]}"; do remove_image_if_unused "$img"; done
    fi

    if [[ "$cron" == "y" && -n "$dom" ]] && crontab -l 2>/dev/null | grep -qF -- "-d $dom "; then
        crontab -l 2>/dev/null | grep -vF -- "-d $dom " | crontab - \
            && step_done "Removed the Let's Encrypt renewal cron entry"
    fi

    if [[ -n "$dir" && -d "$dir" ]]; then
        case "$dir" in
            /|/opt|/home|/root|/var|/usr|/etc) warn "Refusing to delete '$dir'." ;;
            *) rm -rf "$dir" && step_done "Deleted the installation folder $dir" ;;
        esac
    fi

    echo ""
    if [[ "$mode" == "uninstall" ]]; then
        echo -e "${GREEN} ✔ The Faveo Docker installation for ${dom} has been removed.${NC}"
    else
        echo -e "${GREEN} ✔ Rollback completed - the changes made by this installation were undone.${NC}"
    fi
    echo "   Base images (ubuntu, mysql, redis, meilisearch) were kept to speed up future installs."
    echo "   To free that disk space as well, run: docker image prune -a"
}

# Called by die() once the installation has started changing the system.
on_failure() {
    install_started="n"          # prevent recursion if anything below fails
    trap - INT TERM
    local answer="y"

    echo ""
    if [[ "$keep_on_failure" == "y" ]]; then
        answer="n"
    elif interactive; then
        echo -e "${YELLOW} The installation did not complete. Rolling back will undo what was created:${NC}"
        [[ -n "$RB_DIR" ]]     && echo "   - installation path $RB_DIR (application, configs, database files)"
        [[ -n "$RB_NETWORK" ]] && echo "   - containers and Docker network $RB_NETWORK"
        [[ ${#RB_IMAGES[@]} -gt 0 ]] && echo "   - images built by this run: ${RB_IMAGES[*]} (if not used elsewhere)"
        [[ -n "$RB_CRON" ]]    && echo "   - the certificate renewal cron entry"
        [[ "${RB_REMOTE_DB_CREATED:-n}" == "y" ]]   && echo "   - remote database $db_name on $db_host (created by this run)"
        [[ "${RB_REMOTE_USER_CREATED:-n}" == "y" ]] && echo "   - remote database user $db_user (created by this run)"
        read -r -p "$(echo -e "${YELLOW} Undo the incomplete installation now? (Y/n): ${NC}")" answer
        answer=${answer:-y}
    fi

    if [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]; then
        remote_db_rollback
        rollback_install "$RB_DIR" "$domainname" "$([[ ${#RB_IMAGES[@]} -gt 0 ]] && echo y || echo n)" "$([[ -n "$RB_CRON" ]] && echo y || echo n)"
        echo -e "${YELLOW} Fix the problem above and run the installer again.${NC}"
    else
        warn "Files were kept in ${RB_DIR:-the installation path}."
        if [[ -n "$RB_DIR" && -d "$RB_DIR/$host_root_dir" && -f "$RB_DIR/docker-compose.yml" ]]; then
            echo "  To resume after fixing the problem (no new download needed):"
            echo "    cd $RB_DIR && docker compose up -d --build"
        fi
        echo "  To remove everything later:  sudo ./$SCRIPT_NAME --uninstall -i ${RB_DIR:-<path>}"
    fi
}

# A directory is a Faveo Docker install if it has the generated .env + compose file.
is_faveo_install() {
    [[ -f "$1/docker-compose.yml" && -f "$1/.env" ]] && grep -q '^DOMAINNAME=' "$1/.env" 2>/dev/null
}

# Installations found on this server: /opt/faveo/* and the working directories
# of existing Faveo containers (installs placed elsewhere with --install-dir).
find_installs() {
    {
        local d
        for d in /opt/faveo/*/; do [[ -d "$d" ]] && echo "${d%/}"; done
        if command -v docker >/dev/null; then
            docker ps -a --filter "label=com.docker.compose.service=faveo-apache" \
                --format '{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null
        fi
    } | while read -r d; do
        [[ -n "$d" ]] && is_faveo_install "$d" && realpath -m "$d"
    done | sort -u
}

# Short state of an install: domain and container status.
install_info() {
    local dir=$1 dom total running
    dom=$(grep -m1 '^DOMAINNAME=' "$dir/.env" 2>/dev/null | cut -d= -f2-)
    total=$(docker ps -a --filter "name=^${dom}-" --format '{{.Names}}' 2>/dev/null | wc -l)
    running=$(docker ps --filter "name=^${dom}-" --format '{{.Names}}' 2>/dev/null | wc -l)
    echo "domain: ${dom:-?} | containers: $total ($running running)"
}

# choose_existing_install <verb>  ("remove" / "back up") -> sets SELECTED_DIR
# Uses -i / -d when given, otherwise lists the installations found and asks.
choose_existing_install() {
    local verb=$1 dir="" input tries=0 default="" i
    local installs=()

    if [[ -n "$install_dir" ]]; then
        dir=$(realpath -m "$install_dir")
    elif [[ -n "$domainname" ]]; then
        dir="/opt/faveo/$domainname"
    elif interactive; then
        mapfile -t installs < <(find_installs)
        if [[ ${#installs[@]} -gt 0 ]]; then
            default=${installs[0]}
            echo -e "${CYAN} Faveo Docker installations found on this server:${NC}"
            for i in "${!installs[@]}"; do
                printf "${GREEN}  (%d) %s${NC}\n      %s\n" $((i + 1)) "${installs[$i]}" "$(install_info "${installs[$i]}")"
            done
        else
            default="/opt/faveo"
            echo -e "${YELLOW} No installation was found under /opt/faveo or in Docker; enter its path.${NC}"
        fi

        while true; do
            if [[ ${#installs[@]} -gt 0 ]]; then
                read -r -p "$(echo -e "${YELLOW} Which installation do you want to $verb? Enter a number or a path [1]: ${NC}")" input
            else
                read -r -p "$(echo -e "${YELLOW} Installation path to $verb: ${NC}")" input
            fi
            input=${input:-$default}
            if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#installs[@]} )); then
                dir=${installs[$((input - 1))]}
            else
                [[ "$input" == "~" || "$input" == "~/"* ]] && input="$HOME${input:1}"
                dir=$(realpath -m "$input")
            fi

            if [[ ! -d "$dir" ]]; then
                echo -e "${RED} '$dir' does not exist.${NC}"
            elif ! is_faveo_install "$dir"; then
                echo -e "${RED} '$dir' is not a Faveo Docker installation (no docker-compose.yml / .env with DOMAINNAME).${NC}"
            else
                break
            fi
            tries=$((tries + 1))
            [[ $tries -ge $max_retries ]] && die "Too many invalid attempts. Nothing was changed."
        done
    else
        die "This needs --install-dir <path> or --domain <domain> when run non-interactively."
    fi

    [[ -d "$dir" ]] || die "'$dir' does not exist. Nothing was changed."
    is_faveo_install "$dir" \
        || die "'$dir' is not a Faveo Docker installation (no docker-compose.yml / .env with DOMAINNAME). Nothing was changed."
    SELECTED_DIR=$dir
}

# ----------------------------------------------------------------------------
# Backup
# ----------------------------------------------------------------------------
env_get() { grep -m1 "^$2=" "$1/.env" 2>/dev/null | cut -d= -f2-; }
cred_get() { awk -F' : ' -v k="$2" 'index($0, k) == 1 { sub(/^[ ]+/, "", $2); print $2; exit }' "$1/credentials.txt" 2>/dev/null; }

# backup_database <install dir> <output .sql.gz>
backup_database() {
    local dir=$1 out=$2 dom loc started="" i
    dom=$(env_get "$dir" DOMAINNAME)
    loc=$(env_get "$dir" DB_LOCATION); loc=${loc:-local}

    if [[ "$loc" == "remote" ]]; then
        local host port name user pass ssl verify args=() vol=()
        host=$(env_get "$dir" DB_HOST); port=$(env_get "$dir" DB_PORT)
        name=$(env_get "$dir" DB_DATABASE); user=$(env_get "$dir" DB_USERNAME)
        ssl=$(env_get "$dir" DB_SSL); verify=$(env_get "$dir" DB_SSL_VERIFY)
        pass=$(cred_get "$dir" "Database password")
        [[ "$host" == "host.docker.internal" ]] && host="127.0.0.1"
        [[ -n "$pass" ]] || { warn "Remote database password not found in credentials.txt."; return 1; }
        args=(-h "$host" -P "${port:-3306}" -u "$user")
        if [[ "$ssl" == "yes" ]]; then
            vol=(-v "$dir/db_ssl:/dbssl:ro$(selinux_enforcing && echo ,z)")
            args+=(--ssl-ca=/dbssl/ca.pem)
            [[ -f "$dir/db_ssl/client-cert.pem" ]] && args+=(--ssl-cert=/dbssl/client-cert.pem --ssl-key=/dbssl/client-key.pem)
            [[ "$verify" == "no" ]] && args+=(--ssl-mode=VERIFY_CA) || args+=(--ssl-mode=VERIFY_IDENTITY)
        fi
        info "Dumping remote database '$name' from $host..."
        docker run --rm --network host -e MYSQL_PWD="$pass" "${vol[@]}" mysql:8.4.11 \
            mysqldump "${args[@]}" --single-transaction --no-tablespaces --routines --triggers --events \
            --databases "$name" 2>"$out.err" | gzip > "$out"
    else
        local name rootpw ctr="${dom}-mysql"
        name=$(env_get "$dir" MYSQL_DATABASE); rootpw=$(env_get "$dir" MYSQL_ROOT_PASSWORD)
        if [[ "$(docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null)" != "true" ]]; then
            info "Starting the MySQL container to take the dump..."
            (cd "$dir" && docker compose up -d faveo-mysql >/dev/null 2>&1) || { warn "Could not start $ctr."; return 1; }
            started="y"
        fi
        for i in $(seq 1 60); do
            docker exec -e MYSQL_PWD="$rootpw" "$ctr" mysqladmin -uroot ping >/dev/null 2>&1 && break
            sleep 2
        done
        info "Dumping database '$name' from container $ctr..."
        docker exec -e MYSQL_PWD="$rootpw" "$ctr" mysqldump -uroot --single-transaction --routines --triggers --events \
            --databases "$name" 2>"$out.err" | gzip > "$out"
        [[ -n "$started" ]] && (cd "$dir" && docker compose stop faveo-mysql >/dev/null 2>&1)
    fi

    # mysqldump ends a complete dump with "-- Dump completed".
    if zcat "$out" 2>/dev/null | tail -n 1 | grep -q "Dump completed"; then
        rm -f "$out.err"
        return 0
    fi
    warn "Database dump failed: $(grep -v 'Using a password' "$out.err" 2>/dev/null | tail -1)"
    rm -f "$out.err"
    return 1
}

human_size() { du -sh "$1" 2>/dev/null | cut -f1; }

# backup_install <install dir> -> sets LAST_BACKUP
backup_install() {
    local dir=$1 dom ts base dest need avail item cfg=()
    dom=$(env_get "$dir" DOMAINNAME)
    ts=$(date +%Y-%m-%d_%H%M%S)
    base=${backup_dir:-$(dirname "$dir")/Backup}
    base=$(realpath -m "$base")
    case "$base/" in "$dir"/*) die "The backup folder must be outside the installation folder ($dir)." ;; esac
    dest="$base/$dom/$ts"

    # Rough space check: application + storage (+ database files) vs free space.
    need=$(du -sk "$dir/$host_root_dir" "$dir/storage" "$dir/mysql" 2>/dev/null | awk '{s+=$1} END {print s+0}')
    mkdir -p "$base" || die "Cannot create the backup folder $base."
    avail=$(df -Pk "$base" | awk 'NR==2 {print $4}')
    if [[ -n "$avail" && "$need" -gt "$avail" ]]; then
        die "Not enough free space in $base (need about $((need / 1024)) MB, free $((avail / 1024)) MB). Use --backup-dir."
    fi

    mkdir -p "$dest"; chmod 700 "$base" "$base/$dom" "$dest"
    echo ""
    echo -e "${CYAN} Backing up the Faveo installation for $dom...${NC}"
    echo "   Destination: $dest"

    backup_database "$dir" "$dest/database.sql.gz" \
        || { rm -rf "$dest"; die "Backup failed: the database could not be dumped. Nothing was changed."; }
    step_done "Database dump        database.sql.gz      ($(human_size "$dest/database.sql.gz"))"

    tar -czf "$dest/faveo-files.tar.gz" -C "$dir" "$host_root_dir" storage 2>/dev/null \
        || { rm -rf "$dest"; die "Backup failed while archiving the Faveo files."; }
    step_done "Faveo directory      faveo-files.tar.gz   ($(human_size "$dest/faveo-files.tar.gz"))  [faveo/ + storage/]"

    for item in .env docker-compose.yml credentials.txt apache supervisor Dockerfile ssl_copy certbot db_ssl meilisearch/config; do
        [[ -e "$dir/$item" ]] && cfg+=("$item")
    done
    tar -czf "$dest/config.tar.gz" -C "$dir" "${cfg[@]}" 2>/dev/null \
        || { rm -rf "$dest"; die "Backup failed while archiving the configuration."; }
    step_done "Configuration        config.tar.gz        ($(human_size "$dest/config.tar.gz"))  [.env, compose, certificates, configs]"

    (cd "$dest" && sha256sum database.sql.gz faveo-files.tar.gz config.tar.gz > SHA256SUMS)
    cat > "$dest/README.txt" <<EOF
Faveo Docker backup
-------------------
Domain        : $dom
Installation  : $dir
Taken         : $(date '+%Y-%m-%d %H:%M:%S %Z')
Database      : $(env_get "$dir" DB_LOCATION | sed 's/^$/local/') ($(env_get "$dir" MYSQL_DATABASE)$(env_get "$dir" DB_DATABASE))

Files
  database.sql.gz      mysqldump of the Faveo database (includes CREATE DATABASE)
  faveo-files.tar.gz   faveo/ (application) and storage/
  config.tar.gz        .env, docker-compose.yml, credentials.txt, apache/, supervisor/,
                       Dockerfile/, certificates (ssl_copy/ or certbot/), db_ssl/
  SHA256SUMS           checksums - verify with: sha256sum -c SHA256SUMS

Restore (same or new server, Docker installed)
  1. mkdir -p $dir && cd $dir
  2. tar xzf <backup>/config.tar.gz && tar xzf <backup>/faveo-files.tar.gz
  3. Local database:  docker network create --subnet=\$(grep ^SUBNET_PREFIX= .env | cut -d= -f2).0.0/16 \$(grep ^DOMAINNAME= .env | cut -d= -f2)-faveo
                      mkdir -p mysql && docker compose up -d faveo-mysql   (wait ~30s for MySQL to start)
                      zcat <backup>/database.sql.gz | docker exec -i -e MYSQL_PWD=\$(grep ^MYSQL_ROOT_PASSWORD= .env | cut -d= -f2) \$(grep ^DOMAINNAME= .env | cut -d= -f2)-mysql mysql -uroot
     Remote database: zcat <backup>/database.sql.gz | mysql -h <host> -u <admin> -p
  4. docker compose up -d --build
EOF
    chmod 600 "$dest"/*
    LAST_BACKUP=$dest
    echo ""
    echo -e "${GREEN} ✔ Backup completed: $dest  ($(human_size "$dest") in total)${NC}"
    echo "   Copy this folder to another server or storage to keep it safe."
}

# --backup (without --uninstall)
run_backup() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
    command -v docker >/dev/null || die "Docker is not installed."
    choose_existing_install "back up"
    backup_install "$SELECTED_DIR"
    exit 0
}

# --uninstall: remove an existing installation.
run_uninstall() {
    local dir dom answer tries=0
    [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
    choose_existing_install "remove"
    dir=$SELECTED_DIR
    dom=$(grep -m1 '^DOMAINNAME=' "$dir/.env" 2>/dev/null | cut -d= -f2-)

    local names cnt
    names=$(docker ps -a --filter "name=^${dom}-" --format '{{.Names}}' 2>/dev/null | sort | paste -sd',' - | sed 's/,/, /g')
    cnt=$(docker ps -a --filter "name=^${dom}-" --format '{{.Names}}' 2>/dev/null | wc -l)

    echo ""
    echo -e "${YELLOW} The following will be permanently deleted:${NC}"
    echo "   Installation folder : $dir"
    echo "   Domain              : $dom"
    echo "   Containers          : ${names:-none}${names:+  ($cnt)}"
    echo "   Docker network      : ${dom}-faveo"
    echo "   Data in the folder  : application files, $(grep -q '^DB_LOCATION=remote' "$dir/.env" 2>/dev/null && echo "" || echo "database (mysql/), ")certificates, logs, credentials.txt"
    echo "   Docker images       : faveo-apache, faveo-supervisor (only if no other installation uses them)"
    echo "   Cron                : Let's Encrypt renewal entry (if one exists)"
    grep -q '^DB_LOCATION=remote' "$dir/.env" 2>/dev/null \
        && echo "   Remote database     : $(grep -m1 '^DB_DATABASE=' "$dir/.env" | cut -d= -f2-) on $(grep -m1 '^DB_HOST=' "$dir/.env" | cut -d= -f2-) - will NOT be touched"
    echo ""
    echo -e "${RED} ! This cannot be undone.${NC} You will be offered a backup before anything is deleted."
    echo ""
    if [[ "$assume_yes" != "y" ]]; then
        tries=0
        while true; do
            read -r -p "$(echo -e "${YELLOW} Do you want to permanently remove this Faveo installation? (yes/no) [no]: ${NC}")" answer
            case "${answer,,}" in
                y|yes|"${dom,,}") break ;;
                ""|n|no)          echo -e "${GREEN} Cancelled. Nothing was removed.${NC}"; exit 0 ;;
                *)
                    tries=$((tries + 1))
                    echo -e "${RED} Please type yes or no. ($tries/$max_retries)${NC}"
                    [[ $tries -ge $max_retries ]] && die "No valid answer; nothing was removed."
                    ;;
            esac
        done
    fi
    # Offer a backup before anything is deleted (a failed backup stops the uninstall).
    local want_backup="$do_backup"
    if [[ "$want_backup" != "y" ]] && interactive; then
        local bk; ask_yes_no bk "Do you want to take a backup (database dump + Faveo files) before removing?" y
        [[ "$bk" == "yes" ]] && want_backup="y"
    fi
    if [[ "$want_backup" == "y" ]]; then
        backup_install "$dir"
    else
        warn "No backup taken."
    fi

    local dbloc rhost rname
    dbloc=$(grep -m1 '^DB_LOCATION=' "$dir/.env" 2>/dev/null | cut -d= -f2-)
    rhost=$(grep -m1 '^DB_HOST=' "$dir/.env" 2>/dev/null | cut -d= -f2-)
    rname=$(grep -m1 '^DB_DATABASE=' "$dir/.env" 2>/dev/null | cut -d= -f2-)
    RB_IMAGES=("faveo-apache:latest" "faveo-supervisor:latest")
    rollback_install "$dir" "$dom" y y uninstall
    [[ -n "${LAST_BACKUP:-}" ]] && echo -e "   Backup kept at: ${GREEN}$LAST_BACKUP${NC}"
    if [[ "$dbloc" == "remote" ]]; then
        echo ""
        warn "The remote database '$rname' on $rhost was not removed. Drop it there if it is no longer needed."
    fi
    exit 0
}

# ----------------------------------------------------------------------------
# Banner
# ----------------------------------------------------------------------------
banner() {
    echo -e "${CYAN}"
    cat <<'EOF'
             ███████╗ █████╗ ██╗   ██╗███████╗ ██████╗
             ██╔════╝██╔══██╗██║   ██║██╔════╝██╔═══██╗
             █████╗  ███████║██║   ██║█████╗  ██║   ██║
             ██╔══╝  ██╔══██║╚██╗ ██╔╝██╔══╝  ██║   ██║
             ██║     ██║  ██║ ╚████╔╝ ███████╗╚██████╔╝
             ╚═╝     ╚═╝  ╚═╝  ╚═══╝  ╚══════╝ ╚═════╝
EOF
    echo -e "                        Docker Installer${NC}\n"
}

# ----------------------------------------------------------------------------
# Interactive prompts for anything not supplied (install.sh style)
# ----------------------------------------------------------------------------
# ask_value <var> <prompt> <validator> <error message>
ask_value() {
    local __var=$1 prompt=$2 validator=$3 errmsg=$4 tries=0 input
    while true; do
        read -r -p "$(echo -e "${YELLOW} $prompt: ${NC}")" input
        input=${input## }; input=${input%% }
        if "$validator" "$input"; then
            printf -v "$__var" '%s' "$input"
            return 0
        fi
        tries=$((tries + 1))
        echo -e "${RED} $errmsg ($tries/$max_retries)${NC}"
        [[ $tries -ge $max_retries ]] && die "Too many failed attempts. Exiting."
    done
}

# ask_choice <prompt> <option>... ; prints the chosen index (1-based)
ask_choice() {
    local prompt=$1; shift
    local tries=0 i choice n=$#
    while true; do
        echo -e "${CYAN} $prompt${NC}"
        i=1
        for opt in "$@"; do echo -e "${GREEN} ($i) - $opt${NC}"; i=$((i + 1)); done
        if [[ -n "${ASK_DEFAULT:-}" ]]; then
            read -r -p "$(echo -e "${YELLOW} Please select an option [1-$n, default: $ASK_DEFAULT]: ${NC}")" choice
            choice=${choice:-$ASK_DEFAULT}
        else
            read -r -p "$(echo -e "${YELLOW} Please select an option [1-$n]: ${NC}")" choice
        fi
        if [[ "$choice" =~ ^[0-9]+$ && $choice -ge 1 && $choice -le $n ]]; then
            CHOICE=$choice
            return 0
        fi
        tries=$((tries + 1))
        echo -e "${RED} Invalid option. ($tries/$max_retries)${NC}"
        [[ $tries -ge $max_retries ]] && die "Too many invalid attempts. Please rerun the script."
    done
}

# Release channel menu (same choices as install.sh; Enter = official).
ask_release() {
    local tries=0 choice
    while true; do
        echo -e "${CYAN} Select the release type for installation:${NC}"
        echo -e "${GREEN} (1) - Official (stable - recommended)${NC}"
        echo -e "${GREEN} (2) - RC (Release Candidate)${NC}"
        echo -e "${GREEN} (3) - Beta (testing)${NC}"
        read -r -p "$(echo -e "${YELLOW} Enter 1/2/3 [default: 1]: ${NC}")" choice
        case "$choice" in
            1|"") release="official" ;;
            2)    release="rc" ;;
            3)    release="beta" ;;
            *)
                tries=$((tries + 1))
                echo -e "${RED} Invalid input. Please enter 1, 2, or 3. ($tries/$max_retries)${NC}"
                [[ $tries -ge $max_retries ]] && die "Too many invalid attempts. Please rerun the script."
                continue ;;
        esac
        ok "You selected: $release"
        return 0
    done
}

# ask_secret <var> <prompt> ; hidden input (password)
ask_secret() {
    local __var=$1 prompt=$2 input
    read -r -s -p "$(echo -e "${YELLOW} $prompt: ${NC}")" input; echo ""
    printf -v "$__var" '%s' "$input"
}

# Ask for the Faveo DB password: Enter = auto-generate, otherwise typed twice.
ask_db_password() {
    local tries=0 p1 p2
    while true; do
        ask_secret p1 "Database password for '$db_user' [Enter = auto-generate]"
        [[ -z "$p1" ]] && { db_password=""; return 0; }
        if ! valid_db_pass "$p1"; then
            echo -e "${RED} Not allowed. Use $DB_PASS_RULE.${NC}"
        else
            ask_secret p2 "Confirm the password"
            [[ "$p1" == "$p2" ]] && { db_password=$p1; return 0; }
            echo -e "${RED} The passwords do not match.${NC}"
        fi
        tries=$((tries + 1))
        [[ $tries -ge $max_retries ]] && die "Too many failed attempts. Exiting."
    done
}

# Offer to change the Faveo database name / user / password.
ask_db_customize() {
    local where=$1 answer
    [[ "$db_custom_from_cli" == "y" ]] && return 0
    echo -e "${CYAN} Faveo database $where: name ${GREEN}$db_name${CYAN}, user ${GREEN}$db_user${CYAN}, password ${GREEN}auto-generated${NC}"
    read -r -p "$(echo -e "${YELLOW} Do you want to customize the database name, user or password? (y/N): ${NC}")" answer
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || return 0
    local v
    read -r -p "$(echo -e "${YELLOW} Database name [$db_name]: ${NC}")" v; v=${v:-$db_name}
    valid_db_ident "$v" || die "Invalid database name '$v' (letters, digits, underscore)."; db_name=$v
    read -r -p "$(echo -e "${YELLOW} Database user [$db_user]: ${NC}")" v; v=${v:-$db_user}
    valid_db_ident "$v" || die "Invalid database user '$v' (letters, digits, underscore)."; db_user=$v
    ask_db_password
}

ask_yes_no() {   # ask_yes_no <var> <prompt> <default y|n>
    local __var=$1 prompt=$2 def=$3 a tries=0
    while true; do
        read -r -p "$(echo -e "${YELLOW} $prompt ($([[ $def == y ]] && echo "Y/n" || echo "y/N")): ${NC}")" a
        case "${a,,}" in
            "")     printf -v "$__var" '%s' "$([[ $def == y ]] && echo yes || echo no)"; return 0 ;;
            y|yes)  printf -v "$__var" '%s' yes; return 0 ;;
            n|no)   printf -v "$__var" '%s' no;  return 0 ;;
        esac
        tries=$((tries + 1)); echo -e "${RED} Please answer y or n. ($tries/$max_retries)${NC}"
        [[ $tries -ge $max_retries ]] && die "Too many failed attempts. Exiting."
    done
}

ask_database() {
    if [[ -z "$db_location" ]]; then
        ASK_DEFAULT=1 ask_choice "Where should the Faveo database be?" \
            "Local MySQL 8.4 container on this server (default)" "Existing remote MySQL / MariaDB server"
        [[ $CHOICE -eq 2 ]] && db_location="remote" || db_location="local"
        ok "Database: $db_location"
    fi

    if [[ "$db_location" == "local" ]]; then
        ask_db_customize "(local container)"
        return 0
    fi

    # ---- remote server ----
    [[ -z "$db_host" ]] && ask_value db_host "Remote database server hostname or IPv4 address" valid_db_host "Invalid hostname/IP. Try again."
    if [[ -z "$db_port" ]]; then
        local v
        read -r -p "$(echo -e "${YELLOW} Remote database port [3306]: ${NC}")" v; v=${v:-3306}
        valid_port "$v" || die "Invalid port '$v'."; db_port=$v
    fi
    if [[ -z "$db_admin_user" ]]; then
        read -r -p "$(echo -e "${YELLOW} Admin user that can create databases and users [root]: ${NC}")" db_admin_user
        db_admin_user=${db_admin_user:-root}
    fi
    if [[ "$db_admin_pw_given" != "y" ]]; then
        ask_secret db_admin_password "Password for '$db_admin_user'"
        db_admin_pw_given="y"
    fi
    [[ -z "$db_ssl" ]] && ask_yes_no db_ssl "Use an SSL/TLS secured connection to the database server?" n
    if [[ "$db_ssl" == "yes" ]]; then
        [[ -f "$STAGE_DIR/db-ca.pem"   ]] || collect_cert_material "Database CA certificate (required)" "$STAGE_DIR/db-ca.pem" cert
        if [[ ! -f "$STAGE_DIR/db-cert.pem" && -z "$db_ssl_cert" ]]; then
            echo -e "${YELLOW} Client certificate and key are optional - press Enter to skip.${NC}"
            if collect_cert_material "Database client certificate (optional)" "$STAGE_DIR/db-cert.pem" cert y; then
                [[ -f "$STAGE_DIR/db-key.pem" ]] || collect_cert_material "Database client key" "$STAGE_DIR/db-key.pem" key
            fi
        fi
        [[ -z "$db_ssl_verify" ]] && ask_yes_no db_ssl_verify "Verify the server certificate identity (hostname)?" y
    fi
    ask_db_customize "to create on the remote server"
}

collect_attributes() {
    interactive || return 0
    if [[ -z "$product" || -z "$domainname" || -z "$email" || -z "$license" || -z "$orderno" || -z "$ssl_option" ]]; then
        echo -e "${CYAN} Enter the following details required by the Faveo Docker installation.${NC}"
    fi

    if [[ -z "$product" ]]; then
        ask_choice "Select the product to install." "Faveo Helpdesk" "Faveo Network Discovery"
        [[ $CHOICE -eq 1 ]] && product="helpdesk" || product="nd"
    fi

    [[ -z "$domainname" ]] && ask_value domainname "Domain Name [without https://]" valid_domain "Invalid domain. Try again."
    [[ -z "$email"      ]] && ask_value email "Email [valid email address]" valid_email "Invalid email format. Try again."
    [[ -z "$license"    ]] && ask_value license "License Code [from https://billing.faveohelpdesk.com]" valid_code "Invalid license code. Try again."
    if [[ -z "$orderno" ]]; then
        ask_value orderno "Order Number [from https://billing.faveohelpdesk.com]" valid_order "Invalid order number. Try again."
        orderno=${orderno#\#}
    fi

    if [[ -z "$release" ]]; then
        ask_release
    fi

    if [[ -z "$ssl_option" ]]; then
        ask_choice "Select your preferred SSL certificate for Faveo." \
            "FreeSSL from Let's Encrypt (certbot)" "Self-Signed SSL" "Paid SSL"
        case $CHOICE in 1) ssl_option="A" ;; 2) ssl_option="B" ;; 3) ssl_option="C" ;; esac
        case $ssl_option in
            A) ok "You have selected Let's Encrypt Free SSL." ;;
            B) ok "You have selected Self-Signed SSL." ;;
            C) ok "You have selected Paid SSL." ;;
        esac
    fi

    if [[ "$ssl_option" == "C" ]]; then
        [[ -f "$STAGE_DIR/faveolocal.crt"  ]] || collect_cert_material "certificate.crt" "$STAGE_DIR/faveolocal.crt"  cert
        [[ -f "$STAGE_DIR/private.key"     ]] || collect_cert_material "private.key"     "$STAGE_DIR/private.key"     key
        [[ -f "$STAGE_DIR/faveorootCA.crt" ]] || collect_cert_material "ca_bundle.crt"   "$STAGE_DIR/faveorootCA.crt" cert
    fi

    if [[ "$product" == "helpdesk" && -z "$websocket_enable" ]]; then
        ask_choice "Enable WebSocket services for Faveo Helpdesk?" "No (default)" "Yes"
        [[ $CHOICE -eq 2 ]] && websocket_enable="y" || websocket_enable="n"
    fi

    ask_database
}

finalize_attributes() {
    db_location=${db_location:-local}
    if [[ "$db_location" == "remote" ]]; then
        db_port=${db_port:-3306}
        db_admin_user=${db_admin_user:-root}
        db_ssl=${db_ssl:-no}
        [[ "$db_ssl" == "yes" ]] && db_ssl_verify=${db_ssl_verify:-yes}
        [[ "$db_ssl" == "yes" && ! -f "$STAGE_DIR/db-ca.pem" ]] && die "A CA certificate is required for an SSL database connection (--db-ssl-ca)."
        # A server on this machine is reached from the containers via the Docker host gateway.
        case "$db_host" in
            localhost|127.0.0.1|::1) db_container_host="host.docker.internal" ;;
            *)                       db_container_host=$db_host ;;
        esac
    fi
    db_password_auto="n"
    [[ -z "$db_password" ]] && { db_password=$(gen_password 20); db_password_auto="y"; }
    [[ -z "$db_root_password" ]] && db_root_password=$(gen_password 20)
    db_user_pw=$db_password
    db_root_pw=$db_root_password
    [[ -z "$release" ]] && release="official"
    [[ -z "$websocket_enable" ]] && websocket_enable="n"
    if [[ "$websocket_enable" == "y" && "$product" != "helpdesk" ]]; then
        warn "WebSocket is only supported for Faveo Helpdesk; ignoring it."
        websocket_enable="n"
    fi

    [[ "$ssl_option" == "C" ]] && check_paid_ssl_bundle

    case "$product" in
        helpdesk) product_label="Faveo Helpdesk" ;;
        nd)       product_label="Faveo Network Discovery" ;;
    esac

    # MeiliSearch and WebSocket ship with Helpdesk only.
    use_meilisearch="n"
    [[ "$product" == "helpdesk" ]] && use_meilisearch="y"

    default_install_dir="/opt/faveo/$domainname"

    apply_port_rules
}


# ----------------------------------------------------------------------------
# Installation path
# ----------------------------------------------------------------------------
# Normalise a path and refuse locations that must never be wiped or used as root.
resolve_install_dir() {
    local p=$1
    [[ "$p" == "~" || "$p" == "~/"* ]] && p="$HOME${p:1}"
    p=$(realpath -m "$p")
    case "$p" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/var/lib|/mnt|/media)
            echo "Refusing to use '$p' as the installation path; choose a dedicated sub-directory (e.g. /opt/faveo/$domainname)." >&2
            return 1 ;;
    esac
    echo "$p"
}

# Ask for the installation path when --install-dir was not given (interactive runs).
choose_install_dir() {
    local answer resolved

    if [[ -n "$install_dir" ]]; then
        resolved=$(resolve_install_dir "$install_dir") || exit 1
    elif ! interactive; then
        resolved=$(resolve_install_dir "$default_install_dir") || exit 1
    else
        while true; do
            read -r -p "$(echo -e "${YELLOW} Enter the installation path [$default_install_dir]: ${NC}")" answer
            resolved=$(resolve_install_dir "${answer:-$default_install_dir}") || continue

            if [[ -e "$resolved" && ! -d "$resolved" ]]; then
                echo -e "${RED} '$resolved' exists and is not a directory.${NC}"
                continue
            fi
            if [[ -d "$resolved" && -n "$(ls -A "$resolved" 2>/dev/null)" && "$force" != "y" ]]; then
                warn "'$resolved' is not empty. Its contents (including any existing database in mysql/) will be deleted."
                read -r -p "Remove its contents and install there (y/n)? " answer
                if [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]; then
                    force="y"
                else
                    continue
                fi
            fi
            break
        done
    fi

    install_dir=$resolved
    CUR_DIR="$install_dir"
}

# ----------------------------------------------------------------------------
# Summary + confirmation
# ----------------------------------------------------------------------------

confirm() {
    local row="${YELLOW}  %-22s${GREEN}%s${NC}\n"
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}       Faveo Docker Installation Summary${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    printf "$row" "Product:"       "$product_label"
    printf "$row" "Domain:"        "$domainname"
    printf "$row" "Email:"         "$email"
    printf "$row" "License Code:"  "$license"
    printf "$row" "Order Number:"  "$orderno"
    printf "$row" "Release:"       "$release"
    echo -e "${CYAN}  ──────────────────────────────────────────────────────${NC}"
    printf "$row" "SSL Type:"      "$(ssl_name "$ssl_option")"
    if [[ "$ssl_option" == "C" ]]; then
        printf "$row" "Certificate:" "$(openssl x509 -noout -subject -in "$STAGE_DIR/faveolocal.crt" 2>/dev/null | sed 's/^subject=//')"
        printf "$row" "Valid until:" "$(openssl x509 -noout -enddate -in "$STAGE_DIR/faveolocal.crt" 2>/dev/null | sed 's/^notAfter=//')"
    fi
    [[ "$product" == "helpdesk" ]] && printf "$row" "WebSocket:" "$([[ "$websocket_enable" == "y" ]] && echo yes || echo no)"
    printf "$row" "MeiliSearch:"   "$([[ "$use_meilisearch" == "y" ]] && echo yes || echo no)"
    printf "$row" "PHP / Node.js:" "$php_version / $node_version"
    if [[ "$db_location" == "remote" ]]; then
        printf "$row" "Database:"      "Remote server $db_host:$db_port (admin: $db_admin_user)"
        printf "$row" "Database SSL:"  "$([[ "$db_ssl" == "yes" ]] && echo "yes (verify identity: $db_ssl_verify)" || echo no)"
    else
        printf "$row" "Database:"      "Local MySQL 8.4 container"
    fi
    printf "$row" "DB name / user:" "$db_name / $db_user"
    printf "$row" "DB password:"   "$([[ "$db_password_auto" == "y" ]] && echo auto-generated || echo custom)"
    printf "$row" "Ports:"         "HTTP $http_port, HTTPS $https_port, Supervisor $supervisor_port"
    printf "$row" "Site URL:"      "$site_url"
    printf "$row" "Docker subnet:" "${subnet_prefix}.0.0/16"
    printf "$row" "Install Path:"  "$install_dir"
    [[ "$generate_only" == "y" ]] && printf "$row" "Mode:" "generate files only"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

    if [[ "$assume_yes" != "y" ]]; then
        read -r -p "$(echo -e "Continue (${GREEN}y${NC}/${RED}n${NC})? ")" REPLY
        [[ "$REPLY" =~ ^([yY]|[yY][eE][sS])$ ]] || { echo -e "${RED} Cancelled. Please rerun the script.${NC}"; exit 1; }
    fi
}

# ----------------------------------------------------------------------------
# Template rendering
#
# Templates are quoted heredocs (so $VARS meant for Docker/Apache/compose stay
# literal). Placeholders look like @@NAME@@ and are replaced from the TOK
# associative array. A line holding only a placeholder that renders empty is
# dropped, so optional blocks leave no blank lines behind.
# ----------------------------------------------------------------------------
declare -A TOK

render() {
    local dest=$1 line out k
    mkdir -p "$(dirname "$dest")"
    : > "$dest"
    while IFS= read -r line || [[ -n "$line" ]]; do
        out=$line
        if [[ "$out" == *@@*@@* ]]; then
            for k in "${!TOK[@]}"; do
                out=${out//"@@${k}@@"/"${TOK[$k]}"}
            done
            if [[ "$line" =~ ^[[:space:]]*@@[A-Z_]+@@[[:space:]]*$ && -z "${out//[[:space:]]/}" ]]; then
                continue
            fi
        fi
        printf '%s\n' "$out" >> "$dest"
    done
}

set_tokens() {
    TOK=()
    TOK[DOMAIN]=$domainname
    if [[ $https_port -eq 443 ]]; then TOK[HTTPS_PORT_SUFFIX]=""; else TOK[HTTPS_PORT_SUFFIX]=":$https_port"; fi
    if [[ "$supervisor_port" == "none" ]]; then
        TOK[SUPERVISOR_PORTS]=""
    else
        TOK[SUPERVISOR_PORTS]='      ports:
        - "${SUPERVISOR_PORT:-9001}:9001"'
    fi
    TOK[TIMEZONE]=$timezone
    TOK[PHP_VERSION]=$php_version
    TOK[NODE_VERSION]=$node_version

    if [[ "$product" == "nd" ]]; then
        # Network discovery tools + SNMP and passwordless sudo for scans.
        TOK[ND_NET_TOOLS]='    nmap \
    arp-scan \
    nbtscan \
    avahi-utils \
    net-tools \'
        TOK[ND_SNMP]=' \
    php${PHP_VERSION}-snmp'
        TOK[ND_SUDO]='# Configure passwordless sudo for www-data
RUN apt-get update && \
    apt-get install -y sudo && \
    echo "www-data ALL=(ALL) NOPASSWD: /usr/sbin/arp-scan, /usr/bin/nmap" > /etc/sudoers.d/www-data && \
    chmod 0440 /etc/sudoers.d/www-data && \
    visudo -cf /etc/sudoers.d/www-data && \
    rm -rf /var/lib/apt/lists/*
'
        TOK[HEADERS_UNSET]='    Header always unset X-Frame-Options
    Header always unset X-Content-Type-Options
'
    else
        TOK[ND_NET_TOOLS]=""
        TOK[ND_SNMP]=""
        TOK[ND_SUDO]=""
        TOK[HEADERS_UNSET]=""
    fi

    # WebSocket proxy lines are written commented unless enabled.
    if [[ "$websocket_enable" == "y" ]]; then
        TOK[WS]="   "
    else
        TOK[WS]="#   "
    fi

    if [[ "$ssl_option" == "A" ]]; then
        TOK[SSL_CERT]=/var/imported/ssl/cert.pem
        TOK[SSL_KEY]=/var/imported/ssl/privkey.pem
        TOK[SSL_CHAIN]=/var/imported/ssl/fullchain.pem
        TOK[HSTS]=""
        TOK[SSL_VOLUMES]='      - ${CUR_DIR}/certbot/letsencrypt/etc/letsencrypt/live/${DOMAINNAME}/cert.pem:/var/imported/ssl/cert.pem
      - ${CUR_DIR}/certbot/letsencrypt/etc/letsencrypt/live/${DOMAINNAME}/privkey.pem:/var/imported/ssl/privkey.pem
      - ${CUR_DIR}/certbot/letsencrypt/etc/letsencrypt/live/${DOMAINNAME}/fullchain.pem:/var/imported/ssl/fullchain.pem'
    else
        TOK[SSL_CERT]=/etc/ssl/certs/faveolocal.crt
        TOK[SSL_KEY]=/etc/ssl/private/private.key
        TOK[SSL_CHAIN]=/usr/local/share/ca-certificates/faveorootCA.crt
        TOK[HSTS]='    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"'
        TOK[SSL_VOLUMES]='      - ${CUR_DIR}/ssl_copy/faveolocal.crt:/etc/ssl/certs/faveolocal.crt
      - ${CUR_DIR}/ssl_copy/private.key:/etc/ssl/private/private.key
      - ${CUR_DIR}/ssl_copy/faveorootCA.crt:/usr/local/share/ca-certificates/faveorootCA.crt'
    fi

    if [[ "$db_location" == "remote" ]]; then
        TOK[MYSQL_SERVICE]=""
        TOK[SUPERVISOR_DEPENDS_MYSQL]=""
        if [[ "$db_container_host" == "host.docker.internal" ]]; then
            TOK[APACHE_EXTRA]='    extra_hosts:
      - "host.docker.internal:host-gateway"'
            TOK[SUPERVISOR_EXTRA]='      extra_hosts:
        - "host.docker.internal:host-gateway"'
        else
            TOK[APACHE_EXTRA]=""; TOK[SUPERVISOR_EXTRA]=""
        fi
        if [[ "$db_ssl" == "yes" ]]; then
            TOK[APACHE_DB_SSL]='      - ./db_ssl:/var/www/db-ssl'
            TOK[SUPERVISOR_DB_SSL]='        - ./db_ssl:/var/www/db-ssl'
        else
            TOK[APACHE_DB_SSL]=""; TOK[SUPERVISOR_DB_SSL]=""
        fi
    else
        TOK[MYSQL_SERVICE]='  faveo-mysql:
    image: mysql:8.4.11
    container_name: ${DOMAINNAME}-mysql
    volumes:
      - ./mysql:/var/lib/mysql
    networks:
      faveo-network:
         ipv4_address: ${SUBNET_PREFIX:-172.24}.0.3
    environment:
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    restart: on-failure
'
        TOK[SUPERVISOR_DEPENDS_MYSQL]='        - faveo-mysql'
        TOK[APACHE_EXTRA]=""; TOK[SUPERVISOR_EXTRA]=""
        TOK[APACHE_DB_SSL]=""; TOK[SUPERVISOR_DB_SSL]=""
    fi

    if [[ "$use_meilisearch" == "y" ]]; then
        TOK[MEILI_SERVICE]='  faveo-meilisearch:
    image: getmeili/meilisearch:v1.31.0
    container_name: ${DOMAINNAME}-meilisearch
    volumes:
      - ./meilisearch/data:/meili_data
      - ./meilisearch/config/config.toml:/config.toml
    environment:
      - MEILI_CONFIG_FILE_PATH=/config.toml
      - MEILI_MASTER_KEY=${MEILI_MASTER_KEY}
    networks:
      faveo-network:
        ipv4_address: ${SUBNET_PREFIX:-172.24}.0.6
    restart: always
'
    else
        TOK[MEILI_SERVICE]=""
    fi
}

# ----------------------------------------------------------------------------
# Embedded files
# ----------------------------------------------------------------------------
write_apache_dockerfile() {
    render "$CUR_DIR/Dockerfile/apache/Dockerfile" <<'EOF'
# Use the official Ubuntu base image
FROM ubuntu:24.04

# Set environment variables
ENV TZ=@@TIMEZONE@@ \
    DEBIAN_FRONTEND=noninteractive

# Define PHP and Node.js versions
ENV PHP_VERSION=@@PHP_VERSION@@ \
    NODE_VERSION=@@NODE_VERSION@@

# Retry package downloads on slow or unstable networks
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries

### IMPORTANT When you change the PHP VERSION, make sure the ionCube loader for that version exists.

# Update package lists and install initial packages
RUN apt-get update && \
    apt install -y mysql-client && \
    apt-get install -y \
    tzdata \
    software-properties-common \
    ca-certificates \
    git \
    wget \
    curl \
    unzip \
    nano \
@@ND_NET_TOOLS@@
    zip && \
    apt-get clean && \
    apt-get autoremove -y && \
    rm -rf \
        /var/lib/apt/lists/* \
        /var/cache/apt/* \
        /tmp/* \
        /var/tmp/*

# Add PPA repositories for Apache2 and PHP
RUN add-apt-repository ppa:ondrej/apache2 && \
    add-apt-repository ppa:ondrej/php && \
    apt-get update

# Install Apache2
RUN apt-get install -y apache2

# Install PHP and necessary extensions
RUN apt-get install -y \
    php${PHP_VERSION} \
    libapache2-mod-php${PHP_VERSION} \
    php${PHP_VERSION}-mysql \
    php${PHP_VERSION}-cli \
    php${PHP_VERSION}-common \
    php${PHP_VERSION}-fpm \
    php${PHP_VERSION}-soap \
    php${PHP_VERSION}-gd \
    php${PHP_VERSION}-opcache \
    php${PHP_VERSION}-mbstring \
    php${PHP_VERSION}-zip \
    php${PHP_VERSION}-bcmath \
    php${PHP_VERSION}-intl \
    php${PHP_VERSION}-xml \
    php${PHP_VERSION}-curl \
    php${PHP_VERSION}-imap \
    php${PHP_VERSION}-ldap \
    php${PHP_VERSION}-gmp \
    php${PHP_VERSION}-redis \
    php${PHP_VERSION}-memcached@@ND_SNMP@@

# Update PHP configuration for all configurations
RUN for config in fpm cli apache2; do \
        sed -i -e 's/^file_uploads = .*/file_uploads = On/' \
               -e 's/^allow_url_fopen = .*/allow_url_fopen = On/' \
               -e 's/^short_open_tag = .*/short_open_tag = On/' \
               -e 's/^memory_limit = .*/memory_limit = 256M/' \
               -e 's/^;cgi.fix_pathinfo=1.*/cgi.fix_pathinfo = 0/' \
               -e 's/^upload_max_filesize = .*/upload_max_filesize = 100M/' \
               -e 's/^post_max_size = .*/post_max_size = 100M/' \
               -e 's/^max_execution_time = .*/max_execution_time = 360/' \
            /etc/php/${PHP_VERSION}/$config/php.ini; \
    done

# Download and install ionCube Loader
RUN extension_dir=$(php -i | grep ^extension_dir | awk '{print $3}') && \
    case "$(uname -m)" in \
        x86_64)        ic_arch=x86-64 ;; \
        aarch64|arm64) ic_arch=aarch64 ;; \
        *) echo "Unsupported architecture for ionCube: $(uname -m)"; exit 1 ;; \
    esac && \
    curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 30 "https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_${ic_arch}.tar.gz" -o ioncube_loaders.tar.gz && \
    tar -xzf ioncube_loaders.tar.gz && \
    mv ioncube/ioncube_loader_lin_${PHP_VERSION}.so "$extension_dir" && \
    for config in apache2 cli fpm; do \
        sed -i "2 a zend_extension=${extension_dir}/ioncube_loader_lin_${PHP_VERSION}.so" /etc/php/${PHP_VERSION}/$config/php.ini; \
    done && \
    rm -rf ioncube_loaders.tar.gz ioncube

# Install wkhtmltopdf
RUN apt-get update && \
    apt-get install -y wkhtmltopdf

# Install Node.js
RUN curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 30 https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - && \
    apt-get install -y nodejs

# Install Puppeteer
# (Puppeteer's bundled Chrome is x86_64-only; on ARM the system chromium is used.)
RUN if [ "$(uname -m)" != "x86_64" ]; then export PUPPETEER_SKIP_DOWNLOAD=true; fi && \
    npm install --location=global --unsafe-perm puppeteer@^24.33.0

# Install additional dependencies for Puppeteer
RUN apt-get update && apt-get install -y --no-install-recommends chromium ca-certificates fonts-liberation libasound2t64 libatk-bridge2.0-0 libatk1.0-0 libc6 libcairo2 libcups2 libdbus-1-3 libexpat1 libfontconfig1 libgbm1 libgcc-s1 libgdk-pixbuf-2.0-0 libglib2.0-0 libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 libpangocairo-1.0-0 libstdc++6 libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxcursor1 libxdamage1 libxext6 libxfixes3 libxi6 libxrandr2 libxrender1 libxshmfence1 libxss1 libxtst6 xdg-utils wget && apt-get clean && rm -rf /var/lib/apt/lists/*

@@ND_SUDO@@
# Set the working directory and backup dir
RUN mkdir -p /var/www/storage
WORKDIR /var/www/html

# Add ServerName directive to Apache configuration
RUN echo "ServerName 127.0.0.1" >> /etc/apache2/apache2.conf

# Copy the start-services script into the container
COPY start-services.sh /usr/local/bin/start-services.sh

# Make the script executable
RUN chmod +x /usr/local/bin/start-services.sh

# Enable necessary Apache modules and configurations
RUN a2enmod \
    ssl \
    proxy \
    proxy_http \
    proxy_wstunnel \
    proxy_fcgi \
    setenvif \
    rewrite \
    headers && \
    a2enconf php${PHP_VERSION}-fpm

RUN service php${PHP_VERSION}-fpm restart && \
    service apache2 restart

# Expose ports 80 and 443
EXPOSE 80
EXPOSE 443

# Start both Apache2 and PHP-FPM using the shell script
CMD ["/usr/local/bin/start-services.sh"]
EOF

    render "$CUR_DIR/Dockerfile/apache/start-services.sh" <<'EOF'
#!/bin/bash

# Update CA certificates
update-ca-certificates

# Reload Apache configuration
service apache2 reload

# Start PHP-FPM service
service php@@PHP_VERSION@@-fpm start

# Start Apache in the foreground
apache2ctl -D FOREGROUND
EOF
    chmod +x "$CUR_DIR/Dockerfile/apache/start-services.sh"
}

write_supervisor_dockerfile() {
    render "$CUR_DIR/Dockerfile/supervisor/Dockerfile" <<'EOF'
# Use the official Ubuntu base image
FROM ubuntu:24.04

# Set environment variables
ENV TZ=@@TIMEZONE@@ \
    DEBIAN_FRONTEND=noninteractive

# Define PHP and Node.js versions
ENV PHP_VERSION=@@PHP_VERSION@@ \
    NODE_VERSION=@@NODE_VERSION@@

# Retry package downloads on slow or unstable networks
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries

### IMPORTANT When you change the PHP VERSION, make sure the ionCube loader for that version exists.

# Update package lists and install initial packages
RUN apt-get update && \
    apt install -y mysql-client && \
    apt-get install -y \
    tzdata \
    software-properties-common \
    ca-certificates \
    git \
    wget \
    curl \
    unzip \
    nano \
@@ND_NET_TOOLS@@
    zip && \
    apt-get clean && \
    apt-get autoremove -y && \
    rm -rf \
        /var/lib/apt/lists/* \
        /var/cache/apt/* \
        /tmp/* \
        /var/tmp/*

# Add PPA repositories for Apache2 and PHP
RUN add-apt-repository ppa:ondrej/apache2 && \
    add-apt-repository ppa:ondrej/php && \
    apt-get update

# Install Supervisor
RUN apt-get install -y supervisor

# Install PHP and necessary extensions
RUN apt-get install -y \
    php${PHP_VERSION} \
    libapache2-mod-php${PHP_VERSION} \
    php${PHP_VERSION}-mysql \
    php${PHP_VERSION}-cli \
    php${PHP_VERSION}-common \
    php${PHP_VERSION}-fpm \
    php${PHP_VERSION}-soap \
    php${PHP_VERSION}-gd \
    php${PHP_VERSION}-opcache \
    php${PHP_VERSION}-mbstring \
    php${PHP_VERSION}-zip \
    php${PHP_VERSION}-bcmath \
    php${PHP_VERSION}-intl \
    php${PHP_VERSION}-xml \
    php${PHP_VERSION}-curl \
    php${PHP_VERSION}-imap \
    php${PHP_VERSION}-ldap \
    php${PHP_VERSION}-gmp \
    php${PHP_VERSION}-redis \
    php${PHP_VERSION}-memcached@@ND_SNMP@@

# Download and install ionCube Loader
RUN extension_dir=$(php -i | grep ^extension_dir | awk '{print $3}') && \
    case "$(uname -m)" in \
        x86_64)        ic_arch=x86-64 ;; \
        aarch64|arm64) ic_arch=aarch64 ;; \
        *) echo "Unsupported architecture for ionCube: $(uname -m)"; exit 1 ;; \
    esac && \
    curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 30 "https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_${ic_arch}.tar.gz" -o ioncube_loaders.tar.gz && \
    tar -xzf ioncube_loaders.tar.gz && \
    mv ioncube/ioncube_loader_lin_${PHP_VERSION}.so "$extension_dir" && \
    sed -i "2 a zend_extension=${extension_dir}/ioncube_loader_lin_${PHP_VERSION}.so" /etc/php/${PHP_VERSION}/cli/php.ini && \
    rm -rf ioncube_loaders.tar.gz ioncube

# Install Node.js
RUN curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 30 https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - && \
    apt-get install -y nodejs

@@ND_SUDO@@
# Copy the entrypoint script into the container
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# Make the script executable
RUN chmod +x /usr/local/bin/entrypoint.sh

# Set the working directory
WORKDIR /var/www/html

# Set entrypoint to Supervisor service
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
EOF

    render "$CUR_DIR/Dockerfile/supervisor/entrypoint.sh" <<'EOF'
#!/bin/bash
set -e

# Start Supervisor in foreground
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
EOF
    chmod +x "$CUR_DIR/Dockerfile/supervisor/entrypoint.sh"
}

write_apache_conf() {
    render "$CUR_DIR/apache/000-default.conf" <<'EOF'
<IfModule !headers_module>
    LoadModule headers_module modules/mod_headers.so
</IfModule>

FileETag None
ServerTokens prod
ServerSignature off
TraceEnable off
Protocols http/1.1 h2

<VirtualHost *:80>
    ServerName @@DOMAIN@@
    DocumentRoot /var/www/html/public
    <Directory /var/www/html/public>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/faveo-error.log
    CustomLog ${APACHE_LOG_DIR}/faveo-access.log combined
    RewriteEngine on
    RewriteCond %{SERVER_NAME} =@@DOMAIN@@
    RewriteRule ^ https://%{SERVER_NAME}@@HTTPS_PORT_SUFFIX@@%{REQUEST_URI} [END,NE,R=permanent]
</VirtualHost>

<IfModule mod_ssl.c>
<VirtualHost *:443>
    ServerName @@DOMAIN@@
    DocumentRoot /var/www/html/public
    <Directory /var/www/html/public>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/faveo-error.log
    CustomLog ${APACHE_LOG_DIR}/faveo-access.log combined
    SSLEngine on
    SSLCertificateFile @@SSL_CERT@@
    SSLCertificateKeyFile @@SSL_KEY@@
    SSLCertificateChainFile @@SSL_CHAIN@@

#    ProxyPreserveHost On
#    ProxyPass "/natsws" "ws://faveo-nats:9235/"
#    ProxyPassReverse "/natsws" "ws://faveo-nats:9235/"
#    Header always set X-Forwarded-Proto https

#   ProxyPreserveHost On
@@WS@@SSLProxyEngine On

@@WS@@ProxyPass /fc/ http://faveo-supervisor:6001/fc/ retry=0
@@WS@@ProxyPassReverse /fc/ http://faveo-supervisor:6001/fc/

@@WS@@RewriteEngine On
@@WS@@RewriteCond %{HTTP:Upgrade} websocket [NC]
@@WS@@RewriteCond %{HTTP:Connection} upgrade [NC]
@@WS@@RewriteRule ^/fc/(.*) ws://faveo-supervisor:6001/fc/$1 [P,L]

</VirtualHost>
</IfModule>

<IfModule mod_headers.c>
@@HEADERS_UNSET@@
    Header set Content-Security-Policy "frame-ancestors 'self'"
    Header set Referrer-Policy "no-referrer-when-downgrade"
    Header set X-Content-Type-Options "nosniff"
    Header set X-Frame-Options "SAMEORIGIN"
    Header set X-XSS-Protection "1; mode=block"
    Header set Permissions-Policy "geolocation=(self), microphone=()"
    Header set Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"
    Header set Expect-CT "max-age=86400, enforce"
@@HSTS@@
</IfModule>
EOF
}

write_supervisor_confs() {
    render "$CUR_DIR/supervisor/faveo-horizon.conf" <<'EOF'
[program:faveo-horizon]
process_name=%(program_name)s
command=php /var/www/html/artisan horizon
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=/var/www/html/storage/logs/horizon-worker.log
EOF

    render "$CUR_DIR/supervisor/faveo-worker.conf" <<'EOF'
[program:faveo-cron]
process_name=%(program_name)s_%(process_num)02d
command=bash -c 'sleep 60 && php /var/www/html/artisan schedule:run'
autostart=true
autorestart=true
numprocs=1
user=www-data
redirect_stderr=true
stdout_logfile=/var/www/html/storage/logs/faveo-cron.log
EOF

    [[ "$product" == "helpdesk" ]] || return 0

    render "$CUR_DIR/supervisor/faveo-websocket.conf" <<'EOF'
[program:faveo-websockets-subscribe]
process_name=%(program_name)s
command=php /var/www/html/artisan socket:serve
autostart=true
autorestart=true
user=root
redirect_stderr=true
stdout_logfile=/var/www/html/storage/logs/socket-worker.log

[program:faveo-websockets-node]
process_name=%(program_name)s
command=node /var/www/html/resources/assets/js/socket
autostart=true
autorestart=true
user=root
redirect_stderr=true
stdout_logfile=/var/www/html/storage/logs/node-server.log
EOF
    # Keep the programs present but disabled unless WebSocket was requested.
    [[ "$websocket_enable" == "y" ]] || sed -i 's|^\(.\)|#\1|' "$CUR_DIR/supervisor/faveo-websocket.conf"
}

write_compose() {
    render "$CUR_DIR/docker-compose.yml" <<'EOF'
services:
  faveo-apache:
    build:
      context: ./Dockerfile/apache
      dockerfile: Dockerfile
    image: faveo-apache:latest
    container_name: ${DOMAINNAME}-apache
    networks:
      faveo-network:
         ipv4_address: ${SUBNET_PREFIX:-172.24}.0.2
    ports:
      - "${HTTP_PORT:-80}:80"
      - "${HTTPS_PORT:-443}:443"
    volumes:
      - ./${HOST_ROOT_DIR}:/var/www/html/
      - ./storage:/var/www/storage
      - ./apache/000-default.conf:/etc/apache2/sites-available/000-default.conf
      - ./logs/apache:/var/log/apache2
@@SSL_VOLUMES@@
@@APACHE_DB_SSL@@
    command: /bin/bash -c "apt-get update && update-ca-certificates && chown -R www-data:www-data /var/www/html/ && echo '127.0.0.1 ${DOMAINNAME}' >> /etc/hosts && service php@@PHP_VERSION@@-fpm start && apachectl -D FOREGROUND"
@@APACHE_EXTRA@@
    restart: always

@@MYSQL_SERVICE@@
  faveo-redis:
      image: redis
      container_name: ${DOMAINNAME}-redis
      volumes:
        - ./redis:/data
      restart: always
      networks:
        faveo-network:
          ipv4_address: ${SUBNET_PREFIX:-172.24}.0.4

  faveo-supervisor:
      build:
        context: ./Dockerfile/supervisor
        dockerfile: Dockerfile
      image: faveo-supervisor:latest
      container_name: ${DOMAINNAME}-supervisor
      volumes:
        - ./${HOST_ROOT_DIR}/:/var/www/html/
        - ./supervisor:/etc/supervisor/conf.d
        - ./logs/supervisor:/var/log/supervisor
@@SUPERVISOR_DB_SSL@@
@@SUPERVISOR_PORTS@@
@@SUPERVISOR_EXTRA@@
      depends_on:
        - faveo-redis
@@SUPERVISOR_DEPENDS_MYSQL@@
      networks:
        faveo-network:
          ipv4_address: ${SUBNET_PREFIX:-172.24}.0.5
      restart: on-failure

@@MEILI_SERVICE@@
networks:
  faveo-network:
    name: ${DOMAINNAME}-faveo
    external: true
EOF
}

# On SELinux-enforcing hosts append ":z" to every bind mount in docker-compose.yml
# so Docker relabels the files and the containers are allowed to read them.
apply_selinux_labels() {
    selinux_enforcing || [[ "${FORCE_SELINUX_LABELS:-}" == "1" ]] || return 0
    sed -i -E 's#^([[:space:]]*- (\./|\$\{CUR_DIR\})[^[:space:]:]*:[^[:space:]:]+)$#\1:z#' "$CUR_DIR/docker-compose.yml"
}

write_selfsign_dockerfile() {
    render "$CUR_DIR/Dockerfile/selfsign/Dockerfile" <<'EOF'
# Use an official Ubuntu image as the base
FROM ubuntu

# Set environment variables to avoid user prompts during installation
ENV DEBIAN_FRONTEND=noninteractive
ARG CN

# Install OpenSSL
RUN apt-get update && apt-get install -y openssl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/ssl/copy

WORKDIR /etc/ssl/copy

# Root CA: self-signed, and explicitly marked as a CA (basicConstraints/keyUsage)
# so that clients/openssl don't reject it with "invalid CA certificate" /
# "unsuitable certificate purpose".
RUN openssl ecparam -out faveoroot.key -name prime256v1 -genkey
RUN openssl req -new -x509 -sha256 -days 3650 -key faveoroot.key -out faveorootCA.crt \
    -subj "/CN=Faveo Root CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"

# Leaf/server cert: needs subjectAltName (CN alone is not enough for modern TLS
# clients) plus basicConstraints=CA:FALSE and serverAuth EKU.
RUN openssl ecparam -out private.key -name prime256v1 -genkey
RUN openssl req -new -sha256 -key private.key -out faveolocal.csr \
    -subj "/CN=${CN}" \
    -addext "subjectAltName=DNS:${CN}" \
    -addext "basicConstraints=CA:FALSE" \
    -addext "keyUsage=digitalSignature,keyAgreement" \
    -addext "extendedKeyUsage=serverAuth"
RUN openssl x509 -req -in faveolocal.csr -CA faveorootCA.crt -CAkey faveoroot.key -CAcreateserial \
    -out faveolocal.crt -days 3650 -sha256 -copy_extensions copy
EOF
}

gen_password() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-20}"; }

write_meilisearch_config() {
    [[ "$use_meilisearch" == "y" ]] || return 0
    MEILI_MASTER_KEY=$(gen_password 32)
    mkdir -p "$CUR_DIR/meilisearch/config" "$CUR_DIR/meilisearch/data"
    cat > "$CUR_DIR/meilisearch/config/config.toml" <<EOF
env = "production"
master_key = "$MEILI_MASTER_KEY"
http_addr = "0.0.0.0:7700"
db_path = "/meili_data/data"
dump_dir = "/meili_data/dumps"
snapshot_dir = "/meili_data/snapshots"
log_level = "INFO"
EOF
    chmod 600 "$CUR_DIR/meilisearch/config/config.toml"
}

write_env() {
    local dbblock
    if [[ "$db_location" == "remote" ]]; then
        dbblock="# Remote database (no MySQL container). Enter these in the Faveo web installer.
DB_LOCATION=remote
DB_HOST=$db_container_host
DB_PORT=$db_port
DB_DATABASE=$db_name
DB_USERNAME=$db_user
DB_SSL=$db_ssl
DB_SSL_VERIFY=${db_ssl_verify:-no}"
    else
        dbblock="DB_LOCATION=local
MYSQL_ROOT_PASSWORD=$db_root_pw
MYSQL_DATABASE=$db_name
MYSQL_USER=$db_user
MYSQL_PASSWORD=$db_user_pw"
    fi

    cat > "$CUR_DIR/.env" <<EOF
DOMAINNAME=$domainname
HOST_ROOT_DIR=$host_root_dir
CUR_DIR=$CUR_DIR
$dbblock
MEILI_MASTER_KEY=${MEILI_MASTER_KEY:-}
NATS_URL=
NATS_WS_URL=
# Host ports. If HTTPS_PORT is changed later, also update the redirect in
# apache/000-default.conf. Let's Encrypt installs must keep 80 / 443.
HTTP_PORT=$http_port
HTTPS_PORT=$https_port
# Docker network ${subnet_prefix}.0.0/16 (containers use fixed .0.2 - .0.6 addresses)
SUBNET_PREFIX=$subnet_prefix
EOF
    [[ "$supervisor_port" != "none" ]] && echo "SUPERVISOR_PORT=$supervisor_port" >> "$CUR_DIR/.env"
    if [[ "$websocket_enable" == "y" ]]; then
        echo "WEBSOCKET_PORT=6001" >> "$CUR_DIR/.env"
        echo "WEBSOCKET_URL=wss://${site_url#https://}/fc" >> "$CUR_DIR/.env"
    fi
    chmod 600 "$CUR_DIR/.env"
}

generate_files() {
    info "Generating Dockerfiles, configuration and docker-compose.yml in $CUR_DIR..."
    set_tokens
    write_apache_dockerfile
    write_supervisor_dockerfile
    write_apache_conf
    write_supervisor_confs
    write_compose
    apply_selinux_labels
    [[ "$ssl_option" == "B" ]] && write_selfsign_dockerfile
    write_meilisearch_config
    write_env
    # Every runtime directory lives inside the installation path.
    mkdir -p "$CUR_DIR/storage" "$CUR_DIR/$host_root_dir" "$CUR_DIR/redis" \
             "$CUR_DIR/logs/apache" "$CUR_DIR/logs/supervisor"
    if [[ "$db_location" == "local" ]]; then
        mkdir -p "$CUR_DIR/mysql"
    elif [[ "$db_ssl" == "yes" ]]; then
        # Database SSL files, readable by www-data (gid 33) inside the containers.
        mkdir -p "$CUR_DIR/db_ssl"
        cp "$STAGE_DIR/db-ca.pem" "$CUR_DIR/db_ssl/ca.pem"
        [[ -f "$STAGE_DIR/db-cert.pem" ]] && cp "$STAGE_DIR/db-cert.pem" "$CUR_DIR/db_ssl/client-cert.pem"
        [[ -f "$STAGE_DIR/db-key.pem"  ]] && cp "$STAGE_DIR/db-key.pem"  "$CUR_DIR/db_ssl/client-key.pem"
        chown -R 0:33 "$CUR_DIR/db_ssl" 2>/dev/null; chmod 750 "$CUR_DIR/db_ssl"; chmod 640 "$CUR_DIR/db_ssl"/*
    fi
    ok "Files generated."
}

# ----------------------------------------------------------------------------
# Prerequisites / install directory
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Host OS support
# ----------------------------------------------------------------------------
selinux_enforcing() {
    command -v getenforce >/dev/null && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]
}

# ":z" for docker -v options when SELinux is enforcing (shared relabel), else "".
selinux_opt() { selinux_enforcing && echo ":z" || echo ""; }

# pkg_install <pkg...> using whatever package manager the host has.
pkg_install() {
    case "$pkg_mgr" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null ;;
        dnf)    dnf install -y -q "$@" ;;
        yum)    yum install -y -q "$@" ;;
        zypper) zypper -n -q install --no-recommends "$@" ;;
        pacman) pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1 ;;
        apk)    apk add --no-cache -q "$@" ;;
        *)      return 1 ;;
    esac
}

# Start a service now and at boot (systemd or OpenRC).
enable_service() {
    local svc=$1
    if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
        systemctl enable --now "$svc" >/dev/null 2>&1
    elif command -v rc-update >/dev/null; then
        rc-update add "$svc" default >/dev/null 2>&1; rc-service "$svc" start >/dev/null 2>&1
    else
        service "$svc" start >/dev/null 2>&1
    fi
}

install_base_packages() {
    # Install only what is missing: RHEL/Rocky/Alma 9 ship curl-minimal, and
    # asking for the full "curl" package conflicts with it.
    local pkgs=() cmd pkg
    for cmd in unzip curl openssl ss realpath; do
        command -v "$cmd" >/dev/null && continue
        case "$cmd:$pkg_mgr" in
            ss:dnf|ss:yum)  pkg=iproute ;;
            ss:*)           pkg=iproute2 ;;
            realpath:*)     pkg=coreutils ;;
            *)              pkg=$cmd ;;
        esac
        pkgs+=("$pkg")
    done
    # Alpine's busybox realpath/base64 lack GNU options used here.
    if [[ "$pkg_mgr" == "apk" ]] && ! realpath -m / >/dev/null 2>&1; then pkgs+=(coreutils); fi
    [[ ${#pkgs[@]} -eq 0 ]] && { ok "Required tools are already installed."; return 0; }

    if [[ "$pkg_mgr" == "Unknown" ]]; then
        warn "No supported package manager found; install these manually: ${pkgs[*]}"
        return 0
    fi
    info "Installing required packages (${pkgs[*]}) with $pkg_mgr..."
    pkg_install "${pkgs[@]}" || die "Failed to install required packages (${pkgs[*]}) with $pkg_mgr."
}

# Let's Encrypt renewal needs a cron daemon; install and start one if missing.
ensure_cron() {
    command -v crontab >/dev/null && return 0
    info "Installing cron (needed for Let's Encrypt renewal)..."
    case "$pkg_mgr" in
        apt)            pkg_install cron   && enable_service cron ;;
        dnf|yum|zypper) pkg_install cronie && enable_service crond ;;
        pacman)         pkg_install cronie && enable_service cronie ;;
        apk)            pkg_install dcron  && enable_service dcron ;;   # busybox crond also works
        *)              false ;;
    esac
    command -v crontab >/dev/null || warn "Could not install cron; Let's Encrypt certificates will not renew automatically."
}

# Install Docker Engine + Compose plugin for the detected OS.
install_docker_engine() {
    local repo_os
    info "Installing Docker Engine and the Compose plugin for $os_name..."
    case "$os_family" in
        debian)
            repo_os=$os_id; [[ "$repo_os" != "debian" ]] && repo_os="ubuntu"
            pkg_install ca-certificates curl gnupg || return 1
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL --retry 5 "https://download.docker.com/linux/$repo_os/gpg" -o /etc/apt/keyrings/docker.asc || return 1
            chmod a+r /etc/apt/keyrings/docker.asc
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$repo_os $(. /etc/os-release; echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
                > /etc/apt/sources.list.d/docker.list
            pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
            ;;
        rhel)
            case "$os_id" in
                fedora) repo_os="fedora" ;;
                rhel)   repo_os="rhel" ;;
                *)      repo_os="centos" ;;   # Rocky, AlmaLinux, CentOS Stream
            esac
            if command -v dnf >/dev/null; then
                dnf -y -q install dnf-plugins-core >/dev/null 2>&1
                dnf config-manager --add-repo "https://download.docker.com/linux/$repo_os/docker-ce.repo" >/dev/null 2>&1 \
                    || dnf config-manager addrepo --from-repofile="https://download.docker.com/linux/$repo_os/docker-ce.repo" >/dev/null 2>&1 \
                    || return 1
            else
                yum -y -q install yum-utils && yum-config-manager --add-repo "https://download.docker.com/linux/$repo_os/docker-ce.repo" || return 1
            fi
            pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
            ;;
        amazon)
            pkg_install docker || return 1
            if ! docker compose version >/dev/null 2>&1; then
                local carch; carch=$(uname -m); [[ "$carch" == "arm64" ]] && carch="aarch64"
                mkdir -p /usr/local/lib/docker/cli-plugins
                curl -fsSL --retry 5 "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$carch" \
                    -o /usr/local/lib/docker/cli-plugins/docker-compose || return 1
                chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
            fi
            ;;
        suse)   pkg_install docker docker-compose || return 1 ;;
        arch)   pkg_install docker docker-compose docker-buildx || return 1 ;;
        alpine) pkg_install docker docker-cli-compose || return 1 ;;
        *)      return 1 ;;
    esac
    enable_service docker
    ok "Docker installed: $(docker --version 2>/dev/null)"
}

check_prerequisites() {
    local answer
    info "Checking prerequisites..."
    detect_system

    case "$arch" in
        x86_64|amd64|aarch64|arm64) ok "Architecture: $arch" ;;
        *) die "Architecture '$arch' is not supported (ionCube loaders exist for x86_64 and aarch64 only)." ;;
    esac
    ok "Operating system: $os_name (package manager: $pkg_mgr)"

    install_base_packages
    [[ "$ssl_option" == "A" ]] && ensure_cron

    if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
        if [[ "$install_docker" != "y" ]] && interactive; then
            warn "Docker Engine and/or the Docker Compose plugin are not installed."
            read -r -p "$(echo -e "${YELLOW} Install them now from the official repository? (Y/n): ${NC}")" answer
            [[ "${answer:-y}" =~ ^([yY]|[yY][eE][sS])$ ]] && install_docker="y"
        fi
        if [[ "$install_docker" == "y" ]]; then
            install_docker_engine || die "Docker installation failed on $os_name. Install Docker manually: https://docs.docker.com/engine/install/"
        fi
    fi

    command -v docker >/dev/null || die "Docker is not installed. Re-run with --install-docker, or install it: https://docs.docker.com/engine/install/"
    ok "$(docker --version)"

    docker compose version >/dev/null 2>&1 \
        || die "The Docker Compose plugin ('docker compose') is not installed. Re-run with --install-docker, or install docker-compose-plugin."
    ok "$(docker compose version)"

    if ! docker info >/dev/null 2>&1; then
        enable_service docker
        sleep 3
        docker info >/dev/null 2>&1 || die "Docker daemon is not running. Start it (systemctl start docker) and try again."
    fi

    if selinux_enforcing; then
        ok "SELinux is enforcing; bind mounts will be labelled with ':z'."
    fi
    ok "Prerequisites check completed."
}

prepare_install_dir() {
    if [[ -d "$install_dir" && -n "$(ls -A "$install_dir" 2>/dev/null)" ]]; then
        [[ "$force" == "y" ]] \
            || die "Install directory '$install_dir' is not empty. Use --force to overwrite it or choose another path."
        warn "Overwriting existing install directory '$install_dir'."
        if [[ "$generate_only" != "y" && -f "$install_dir/docker-compose.yml" ]]; then
            (cd "$install_dir" && docker compose down >/dev/null 2>&1) || true
        fi
        rm -rf "$install_dir"
    fi

    if [[ "$generate_only" != "y" ]]; then
        local ports=("$http_port" "$https_port")
        [[ "$supervisor_port" != "none" ]] && ports+=("$supervisor_port")
        for port in "${ports[@]}"; do
            port_in_use "$port" && die "Port $port is already in use by $(port_owner "$port"). Free it or choose another port."
        done
    fi

    install_started="y"
    RB_DIR="$install_dir"
    mkdir -p "$install_dir" || die "Cannot create '$install_dir'."
    cd "$CUR_DIR" || die "Cannot enter '$CUR_DIR'."
}

# ----------------------------------------------------------------------------
# SSL
# ----------------------------------------------------------------------------
ssl_letsencrypt() {
    info "Obtaining Let's Encrypt certificate for $domainname..."
    mkdir -p "$CUR_DIR/certbot/html"
    echo "<h1>Obtain SSL Certs</h1>" > "$CUR_DIR/certbot/html/index.html"

    docker rm -f apache-cert >/dev/null 2>&1 || true
    local z; z=$(selinux_opt)
    docker run -d -p 80:80 -v "$CUR_DIR/certbot/html:/usr/local/apache2/htdocs$z" \
        --name apache-cert httpd:2.4.33-alpine >/dev/null \
        || die "Temporary Apache container failed to start."

    docker run --rm \
        -v "$CUR_DIR/certbot/letsencrypt/etc/letsencrypt:/etc/letsencrypt$z" \
        -v "$CUR_DIR/certbot/html:/data/letsencrypt$z" \
        --name certbot certbot/certbot certonly --webroot --email "$email" \
        --agree-tos --non-interactive --no-eff-email \
        --webroot-path=/data/letsencrypt -d "$domainname"
    local rc=$?

    docker rm -f apache-cert >/dev/null 2>&1 || true

    if [[ $rc -ne 0 || ! -e "$CUR_DIR/certbot/letsencrypt/etc/letsencrypt/live/$domainname/fullchain.pem" ]]; then
        die "Let's Encrypt failed. Make sure $domainname resolves to this server and port 80 is reachable."
    fi

    # Weekly renewal through the running site; skip if this domain already has an entry.
    local cron_cmd="docker run --rm -v $CUR_DIR/certbot/letsencrypt/etc/letsencrypt:/etc/letsencrypt$z -v $CUR_DIR/$host_root_dir/public:/data/letsencrypt$z --name certbot certbot/certbot certonly --webroot --email $email --agree-tos --non-interactive --no-eff-email --webroot-path=/data/letsencrypt -d $domainname >/dev/null 2>&1 && docker restart $domainname-apache >/dev/null 2>&1"
    if ! crontab -l 2>/dev/null | grep -qF -- "-d $domainname "; then
        RB_CRON="y"
        (crontab -l 2>/dev/null; echo "45 2 * * 6 $cron_cmd") | crontab - \
            || warn "Could not add the certificate renewal cron job."
    fi
    ok "Let's Encrypt certificate obtained."
}

ssl_selfsigned() {
    info "Generating self-signed certificate for $domainname..."
    docker build -q --build-arg CN="$domainname" -t selfsign_ssl "$CUR_DIR/Dockerfile/selfsign" >/dev/null \
        || die "Self-signed certificate build failed."

    docker rm -f selfsign_ssl >/dev/null 2>&1 || true
    rm -rf "$CUR_DIR/ssl_copy"
    docker create --name selfsign_ssl selfsign_ssl >/dev/null \
        && docker cp selfsign_ssl:/etc/ssl/copy "$CUR_DIR/ssl_copy" >/dev/null
    local rc=$?
    docker rm -f selfsign_ssl >/dev/null 2>&1 || true
    docker rmi selfsign_ssl >/dev/null 2>&1 || true

    [[ $rc -eq 0 && -f "$CUR_DIR/ssl_copy/faveolocal.crt" ]] || die "Failed to extract self-signed certificates."
    ok "Self-signed certificate generated (CA: $CUR_DIR/ssl_copy/faveorootCA.crt)."
}

ssl_paid() {
    info "Installing paid SSL certificate..."
    mkdir -p "$CUR_DIR/ssl_copy"
    for f in faveolocal.crt private.key faveorootCA.crt; do
        [[ -f "$STAGE_DIR/$f" ]] || die "Paid SSL file '$f' is missing."
        cp "$STAGE_DIR/$f" "$CUR_DIR/ssl_copy/$f" || die "Failed to copy $f."
    done
    chmod 600 "$CUR_DIR/ssl_copy/private.key"
    chmod 644 "$CUR_DIR/ssl_copy/faveolocal.crt" "$CUR_DIR/ssl_copy/faveorootCA.crt"
    ok "Paid SSL files installed in $CUR_DIR/ssl_copy (CA bundle is added to the container trust store)."
}

# ----------------------------------------------------------------------------
# Application source
# ----------------------------------------------------------------------------
download_licensed() {
    info "Downloading $product_label ($release release) from billing.faveohelpdesk.com..."
    curl -fSL --retry 3 \
        "https://billing.faveohelpdesk.com/download/faveo?order_number=${orderno}&serial_key=${license}&release=${release}" \
        --output "$CUR_DIR/faveo.zip" \
        || die "Download failed. Check the order number, license code, that the '$release' release is available for your license, and your Internet connectivity."

    unzip -tq "$CUR_DIR/faveo.zip" >/dev/null 2>&1 \
        || die "Downloaded file is not a valid archive. Check the order number and license code."

    info "Extracting, please wait..."
    rm -rf "${CUR_DIR:?}/$host_root_dir"
    unzip -q "$CUR_DIR/faveo.zip" -d "$CUR_DIR/$host_root_dir" || die "Extraction failed."
    rm -f "$CUR_DIR/faveo.zip"
}

fix_permissions() {
    chown -R 33:33 "$CUR_DIR/$host_root_dir" "$CUR_DIR/storage"
    find "$CUR_DIR/$host_root_dir" -type d -exec chmod 755 {} +
    find "$CUR_DIR/$host_root_dir" -type f -exec chmod 644 {} +
    chmod -R 755 "$CUR_DIR/storage"
    ok "Application files ready."
}

# ----------------------------------------------------------------------------
# Docker
# ----------------------------------------------------------------------------
setup_docker_resources() {
    info "Creating Docker network..."
    RB_NETWORK="${domainname}-faveo"
    docker network rm "${domainname}-faveo" >/dev/null 2>&1 || true
    docker network create --subnet="${subnet_prefix}.0.0/16" --driver=bridge "${domainname}-faveo" >/dev/null \
        || die "Failed to create Docker network ${domainname}-faveo (is subnet ${subnet_prefix}.0.0/16 already in use? Try --subnet)."
    ok "Docker network ${domainname}-faveo created."
}

# Check that Apache answers over HTTPS and, for paid SSL, serves the supplied certificate.
verify_https() {
    local code="" i served expected
    info "Waiting for $site_url to respond..."
    for i in $(seq 1 30); do
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
            --resolve "$domainname:$https_port:127.0.0.1" "$site_url/" 2>/dev/null)
        [[ "$code" =~ ^[1-5][0-9][0-9]$ && "$code" != "000" ]] && break
        sleep 5
    done
    if [[ ! "$code" =~ ^[1-5][0-9][0-9]$ || "$code" == "000" ]]; then
        warn "$site_url did not respond yet. Check: docker compose -f $CUR_DIR/docker-compose.yml logs faveo-apache"
        return 0
    fi
    ok "$site_url is responding (HTTP $code)."

    if [[ "$ssl_option" == "C" ]]; then
        served=$(echo | openssl s_client -connect "127.0.0.1:$https_port" -servername "$domainname" 2>/dev/null \
            | openssl x509 -noout -fingerprint -sha256 2>/dev/null)
        expected=$(openssl x509 -noout -fingerprint -sha256 -in "$CUR_DIR/ssl_copy/faveolocal.crt" 2>/dev/null)
        if [[ -n "$served" && "$served" == "$expected" ]]; then
            ok "Paid SSL successfully configured for $domainname."
        else
            warn "Apache is not serving the supplied paid certificate. Check $CUR_DIR/ssl_copy."
        fi
    fi
}

start_stack() {
    local attempt img

    # Images that do not exist yet are created by this run (removed on rollback).
    for img in faveo-apache:latest faveo-supervisor:latest; do
        docker image inspect "$img" >/dev/null 2>&1 || RB_IMAGES+=("$img")
    done

    info "Building images (this can take several minutes)..."
    for attempt in $(seq 1 "$build_retries"); do
        docker compose build && break
        if [[ $attempt -lt $build_retries ]]; then
            warn "Image build failed (attempt $attempt/$build_retries), usually a network problem. Retrying in 15s; finished steps are cached..."
            sleep 15
        else
            die "Image build failed after $build_retries attempts. Check your network / the output above."
        fi
    done

    info "Starting containers..."
    docker compose up -d || die "docker compose up failed. Check the output above."
    ok "Containers started."
}

write_credentials() {
    local creds="$CUR_DIR/credentials.txt"
    {
        echo "$product_label Docker Setup Credentials"
        echo "----------------------------------------"
        echo "URL                         : $site_url"
        echo "Ports (HTTP/HTTPS/Supervisor): $http_port / $https_port / $supervisor_port"
        echo "Release                     : $release"
        echo "Install directory           : $CUR_DIR"
        if [[ "$db_location" == "remote" ]]; then
            echo "Database                    : remote server (no MySQL container)"
            echo "Database Hostname           : $db_container_host"
            [[ "$db_container_host" != "$db_host" ]] && echo "                              ($db_host on this server, reached from the containers)"
            echo "Database Port               : $db_port"
        else
            echo "Database Hostname           : faveo-mysql (container: ${domainname}-mysql)"
            echo "MySQL root password         : $db_root_pw"
        fi
        echo "Database name               : $db_name"
        echo "Database user               : $db_user"
        echo "Database password           : $db_user_pw"
        if [[ "$db_location" == "remote" && "$db_ssl" == "yes" ]]; then
            echo "Database SSL                : yes (verify server certificate: $db_ssl_verify)"
            echo "  CA file (in containers)   : /var/www/db-ssl/ca.pem"
            [[ -f "$CUR_DIR/db_ssl/client-cert.pem" ]] && echo "  Client cert (in containers): /var/www/db-ssl/client-cert.pem"
            [[ -f "$CUR_DIR/db_ssl/client-key.pem"  ]] && echo "  Client key (in containers): /var/www/db-ssl/client-key.pem"
        fi
        [[ "$db_location" == "local" ]] && echo "Database files              : $CUR_DIR/mysql"
        if [[ "$use_meilisearch" == "y" ]]; then
            echo "MeiliSearch Hostname        : http://${domainname}-meilisearch:7700"
            echo "MeiliSearch Master Key      : $MEILI_MASTER_KEY"
        fi
        if [[ "$ssl_option" == "B" ]]; then
            echo "Self-signed root CA         : $CUR_DIR/ssl_copy/faveorootCA.crt"
            echo "                              (import it into client browsers/OS to trust the site)"
        fi
    } > "$creds"
    chmod 600 "$creds"
}

print_summary() {
    echo ""
    echo "#########################################################################"
    echo ""
    if [[ "$generate_only" == "y" ]]; then
        echo -e "${GREEN}Files generated in $CUR_DIR (no containers started).${NC}"
        echo "Credentials that the generated .env uses:"
    else
        echo -e "${GREEN}$product_label installed successfully.${NC}"
        echo "Visit $site_url in your browser to finish the setup."
        echo "Please save the following credentials:"
    fi
    echo ""
    cat "$CUR_DIR/credentials.txt"
    echo ""
    echo "#########################################################################"
    echo "Credentials are saved in '$CUR_DIR/credentials.txt'."
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
[[ "$uninstall" == "y" ]] && run_uninstall
[[ "$do_backup" == "y" ]] && run_backup

[[ "$show_banner" == "y" ]] && banner
collect_attributes
finalize_attributes
choose_install_dir
ask_custom_ports
ask_custom_subnet
resolve_ports
confirm

if [[ "$generate_only" == "y" ]]; then
    command -v openssl >/dev/null || die "openssl is required to generate passwords."
else
    check_prerequisites
    [[ "$db_location" == "remote" ]] && remote_db_check
fi

prepare_install_dir
generate_files
write_credentials
[[ "$db_location" == "remote" && "$generate_only" != "y" ]] && remote_db_create

if [[ "$generate_only" == "y" ]]; then
    # Paid SSL files are local, so they are put in place even when only generating.
    [[ "$ssl_option" == "C" ]] && ssl_paid
    print_summary
    exit 0
fi

case "$ssl_option" in
    A) ssl_letsencrypt ;;
    B) ssl_selfsigned ;;
    C) ssl_paid ;;
esac

download_licensed
fix_permissions

setup_docker_resources
start_stack
verify_https
print_summary
