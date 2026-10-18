#!/usr/bin/env bash
#
# Faveo Helpdesk - Docker installer
#
# Installs Faveo Helpdesk (licensed editions) on Docker. Runs interactively when
# options are missing, or completely from options (-y). Also backs up and
# removes installations, and rolls back automatically if an installation fails.
#
# The Dockerfiles and configuration templates in this folder are copied into the
# installation path (default /opt/faveo/<domain>); this folder is never changed,
# so the script can be run again for further installations.
#
# Run './faveo-run.sh --help' for all options.

set -o pipefail

SCRIPT_VERSION="2.0.0"
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MYSQL_IMAGE="mysql:8.4.11"
MEILI_IMAGE="getmeili/meilisearch:v1.31.0"
REDIS_IMAGE="redis:7.4"
DEFAULT_PARENT="/opt/faveo"

# ----------------------------------------------------------------------------
# Colours / messages
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
    CYAN='\033[1;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

info()      { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()        { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()      { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step_done() { echo -e "   ${GREEN}✔${NC} $*"; }
die() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    [[ "$install_started" == "y" ]] && on_failure
    exit 1
}

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
domainname=""; email=""; license=""; orderno=""
release=""                 # official | rc | beta
faveo_env=""               # production | development | testing (php artisan install:faveo --env)
skip_faveo_setup="n"       # y = do not run install:faveo / license check (finish in the browser)
FAVEO_SETUP_STATUS=""; LICENSE_STATUS=""; SUPERVISOR_STATUS=""
ssl_option=""              # A = certbot, B = self-signed, C = paid-ssl
ssl_raw=""; websocket_raw=""; websocket_enable=""
certfile=""; keyfile=""; cacertfile=""
install_dir=""
db_location=""             # local | remote
db_name="faveo"; db_user="faveo"
db_password=""; db_root_password=""
db_custom_from_cli="n"
db_host=""; db_port=""; db_admin_user=""; db_admin_password=""; db_admin_pw_given="n"
db_ssl=""; db_ssl_ca=""; db_ssl_cert=""; db_ssl_key=""; db_ssl_verify=""
http_port=""; https_port=""; supervisor_port=""
auto_ports="n"; ports_from_cli="n"
subnet=""; subnet_prefix="172.24"
php_version="8.4"; node_version="22"; timezone="Asia/Kolkata"
assume_yes="n"; confirm_flag="n"; force="n"; generate_only="n"; install_docker_flag="n"
keep_on_failure="n"; show_banner="y"; show_help="n"
uninstall="n"; do_backup="n"; backup_dir=""
max_retries=3; build_retries=3
host_root_dir="faveo"
SUDO=""                    # the script runs as root; kept for the shared OS helpers
DOCKER_COMPOSE=""

# What this run created - undone by the rollback.
install_started="n"
RB_DIR=""; RB_MOVED=""; RB_CRON=""; RB_STACK=""; RB_IMAGES=()
RB_REMOTE_DB_CREATED="n"; RB_REMOTE_USER_CREATED="n"
RB_REMOTE_DB_EXISTED="n"; RB_REMOTE_USER_EXISTED="n"; RB_REMOTE_USER_REUSED="n"

# Validated certificates are staged here until the installation path exists.
STAGE_DIR=$(mktemp -d) || { echo "Cannot create a temporary directory." >&2; exit 1; }
trap 'rm -rf "$STAGE_DIR"' EXIT
trap 'echo ""; die "Interrupted (Ctrl+C)."' INT TERM

interactive() { [[ "$assume_yes" != "y" && -t 0 ]]; }

# ----------------------------------------------------------------------------
# Help
# ----------------------------------------------------------------------------
usage() {
    local o="    ${GREEN}%-27s${NC} %s\n"
    local h="${CYAN}${BOLD}"
    echo ""
    echo -e "${h}FAVEO HELPDESK - DOCKER INSTALLER${NC}  ${DIM}(version $SCRIPT_VERSION)${NC}"
    echo ""
    echo "  Installs Faveo Helpdesk on Docker, and can back up or remove an installation."
    echo "  Every option you leave out is asked for, step by step. When all required"
    echo "  options are given on the command line, it runs without any question or"
    echo "  confirmation (add --confirm to review the summary first)."
    echo ""
    echo -e "${h}USAGE${NC}"
    echo "    sudo ./$SCRIPT_NAME                          install, answering questions"
    echo "    sudo ./$SCRIPT_NAME [options]                install with options"
    echo "    sudo ./$SCRIPT_NAME --backup    [-i <path>]  back up an installation"
    echo "    sudo ./$SCRIPT_NAME --uninstall [-i <path>]  remove an installation"
    echo ""
    echo -e "${h}QUICK START${NC}"
    echo "    sudo ./$SCRIPT_NAME -d helpdesk.example.com -e admin@example.com \\"
    echo "         -l <license code> -o <order number> -s certbot"
    echo ""
    echo -e "${h}1. REQUIRED${NC}  ${DIM}(asked for when missing)${NC}"
    printf "$o" "-d, --domain <name>"       "Domain name, without https://       e.g. helpdesk.example.com"
    printf "$o" "-e, --email <address>"     "Admin email (also for Let's Encrypt)"
    printf "$o" "-l, --license <code>"      "Faveo license code (billing.faveohelpdesk.com)"
    printf "$o" "-o, --order <number>"      "Faveo order number ('#' is removed)"
    printf "$o" "-s, --ssl <type>"          "certbot     = Let's Encrypt, free (ports 80/443 must be free)"
    printf "$o" ""                          "self-signed = generated certificate (browser warning)"
    printf "$o" ""                          "paid-ssl    = your purchased certificate (see 2)"
    printf "$o" ""                          "A | B | C are accepted too"
    echo ""
    echo -e "${h}2. PAID SSL${NC}  ${DIM}(--ssl paid-ssl; each value: file path, PEM text or base64)${NC}"
    printf "$o" "--certfile <value>"        "Certificate       (certificate.crt)    alias --ssl-cert"
    printf "$o" "--keyfile <value>"         "Private key       (private.key)        alias --ssl-key"
    printf "$o" "--cacertfile <value>"      "CA bundle / chain (ca_bundle.crt)      alias --ssl-ca"
    echo "    Checked before installing: valid PEM, key matches the certificate (else stop),"
    echo "    warning if expired or not issued for the domain."
    echo ""
    echo -e "${h}3. OPTIONAL${NC}  ${DIM}(defaults in brackets)${NC}"
    echo -e "    ${BOLD}Release and features${NC}"
    printf "$o" "-r, --release <type>"      "official | rc | beta                        [official]"
    printf "$o" "-w, --websocket <yes|no>"  "Enable WebSocket services                   [no]"
    printf "$o" "--faveo-env <env>"         "production | development | testing         [production]"
    printf "$o" "--skip-faveo-setup"        "Do not configure Faveo and verify the license; finish in the browser"
    echo -e "    ${BOLD}Installation path${NC}"
    printf "$o" "-i, --install-dir <path>"  "Where everything is created                 [/opt/faveo/<domain>]"
    printf "$o" "-f, --force"               "Use a path that is not empty (old content is moved aside)"
    echo -e "    ${BOLD}Database - local MySQL 8.4 container${NC}  ${DIM}(default)${NC}"
    printf "$o" "--db <local|remote>"       "Where the database lives                    [local]"
    printf "$o" "--db-name <name>"          "Database name                               [faveo]"
    printf "$o" "--db-user <name>"          "Database user                               [faveo]"
    printf "$o" "--db-password <pass>"      "Database user password                      [generated]"
    printf "$o" "--db-root-password <pass>" "MySQL root password                         [generated]"
    echo -e "    ${BOLD}Database - remote MySQL / MariaDB server${NC}  ${DIM}(--db remote, or just give --db-host)${NC}"
    printf "$o" "--db-host <host|IPv4>"     "Server address                              (required)"
    printf "$o" "--db-admin-password <pass>" "Password of the admin user                  (required)"
    printf "$o" "--db-admin-user <user>"    "Admin user that creates the DB and user     [root]"
    printf "$o" "--db-port <port>"          "Server port                                 [3306]"
    printf "$o" "--db-ssl <yes|no>"         "Encrypted connection                        [no]"
    printf "$o" "--db-ssl-ca <value>"       "CA certificate                              (required with --db-ssl yes)"
    printf "$o" "--db-ssl-cert <value>"     "Client certificate                          (optional)"
    printf "$o" "--db-ssl-key <value>"      "Client key                                  (with --db-ssl-cert)"
    printf "$o" "--db-ssl-verify <yes|no>"  "Check the server's identity                 [yes]"
    echo "    The database and user are created on the server and a login is tested. The"
    echo "    database must be new or empty. Rollback removes only what this run created;"
    echo "    --uninstall removes the database user (with the admin password) but keeps the database."
    echo -e "    ${BOLD}Ports and Docker network${NC}"
    printf "$o" "--http-port <port>"        "HTTP port on this server                    [80]"
    printf "$o" "--https-port <port>"       "HTTPS port on this server                   [443]"
    printf "$o" "--supervisor-port <port>"  "Supervisor port (this server only), or none [9001]"
    printf "$o" "--auto-ports"              "If a port is busy, take the next free one"
    printf "$o" "--subnet <x.y.0.0/16>"     "Docker network subnet                       [first free from 172.24.0.0/16]"
    echo "    Let's Encrypt (certbot) always needs ports 80 and 443."
    echo -e "    ${BOLD}Image versions${NC}"
    printf "$o" "--php <8.x>"               "PHP version                                 [8.4]"
    printf "$o" "--node <major>"            "Node.js version                             [22]"
    printf "$o" "--timezone <Area/City>"    "Container timezone                          [Asia/Kolkata]"
    echo -e "    ${BOLD}Behaviour${NC}"
    printf "$o" "-y, --yes"                 "No questions and no confirmation"
    printf "$o" "--confirm"                 "Show the summary and ask before installing, even with all options given"
    printf "$o" "--install-docker"          "Install Docker + Compose if missing (asked when interactive)"
    printf "$o" "-g, --generate-only"       "Only create the files to review them (no SSL, download, Docker)"
    printf "$o" "--keep-on-failure"         "Keep the files if the installation fails (no rollback)"
    printf "$o" "--no-banner"               "Do not show the banner"
    printf "$o" "-h, --help"                "Show this help and the detected system"
    echo ""
    echo -e "${h}4. BACKUP AND REMOVE${NC}"
    printf "$o" "--backup"                  "Back up an installation (database + files + configuration)"
    printf "$o" "--backup-dir <path>"       "Where backups go          [<install parent>/Backup]"
    printf "$o" "--uninstall"               "Remove an installation (alias --rollback); offers a backup first"
    printf "$o" "--uninstall --backup"      "Back up, then remove"
    echo "    Pick the installation from a list, or give -i <path> / -d <domain>."
    echo "    Backups: <backup-dir>/<domain>/<date_time>/ with database.sql.gz,"
    echo "    faveo-files.tar.gz, config.tar.gz, SHA256SUMS and README.txt (restore steps)."
    echo ""
    echo -e "${h}5. IF SOMETHING GOES WRONG${NC}"
    echo "    If a step fails or you press Ctrl+C, everything this run created is removed again:"
    echo "    containers, network, images built by this run, the renewal cron entry, a remote"
    echo "    database/user created by this run, and the installation folder (a folder replaced"
    echo "    with --force is put back). You are asked first; with -y it happens automatically"
    echo "    unless --keep-on-failure is given."
    echo ""
    echo -e "${h}6. VALUE RULES${NC}"
    echo "    Domain         letters, digits, '-' and '.'"
    echo "    License/Order  letters, digits and '-'"
    echo "    DB name/user   letters, digits and '_' (max 32)"
    echo "    DB passwords   $DB_PASS_RULE"
    echo "    Ports          1-65535, HTTP / HTTPS / Supervisor must differ"
    echo ""
    echo -e "${h}7. EXAMPLES${NC}"
    echo -e "    ${DIM}# Let's Encrypt, WebSocket on, no questions${NC}"
    echo "    sudo ./$SCRIPT_NAME -d hd.example.com -e admin@example.com -l XXXX -o 1234 \\"
    echo "         -s certbot -w yes -y"
    echo -e "    ${DIM}# Paid certificate from files${NC}"
    echo "    sudo ./$SCRIPT_NAME -d hd.example.com -e admin@example.com -l XXXX -o 1234 -s paid-ssl \\"
    echo "         --certfile /root/ssl/certificate.crt --keyfile /root/ssl/private.key \\"
    echo "         --cacertfile /root/ssl/ca_bundle.crt"
    echo -e "    ${DIM}# 80/443 already used by another web server: self-signed on other ports${NC}"
    echo "    sudo ./$SCRIPT_NAME -d hd.local -e admin@example.com -l XXXX -o 1234 -s self-signed \\"
    echo "         --http-port 8081 --https-port 8443"
    echo -e "    ${DIM}# Remote database over SSL${NC}"
    echo "    sudo ./$SCRIPT_NAME ... --db-host db.example.com --db-admin-password 'Adm1n!Pass' \\"
    echo "         --db-ssl yes --db-ssl-ca /root/db/ca.pem"
    echo -e "    ${DIM}# Fresh server: install Docker as well, beta release, own path${NC}"
    echo "    sudo ./$SCRIPT_NAME ... --install-docker -r beta -i /srv/faveo/helpdesk -y"
    echo -e "    ${DIM}# Back up, or back up and remove${NC}"
    echo "    sudo ./$SCRIPT_NAME --backup -d hd.example.com --backup-dir /mnt/backups -y"
    echo "    sudo ./$SCRIPT_NAME --uninstall --backup -i /opt/faveo/hd.example.com -y"
    echo ""
    echo -e "${h}8. CREATED IN THE INSTALLATION PATH${NC}"
    echo "    docker-compose.yml  .env  credentials.txt  FAVEO-DOCKER-COMMANDS.txt  faveo-run.sh (copy)"
    echo "    Dockerfile/  apache/  supervisor/"
    echo "    ssl_copy/ or certbot/  faveo/  storage/  mysql/ (local DB)  db_ssl/ (remote DB + SSL)"
    echo "    redis/  meilisearch/  logs/"
    echo ""
    echo "    Old options still work: -domainname -email -license -orderno -ssl -websocket"
}

# Detected system, port and subnet status (second part of --help).
print_system_info() {
    local o="  %-18s : %s\n" hp sp vp label port
    if [[ -n "$install_dir" ]]; then HELP_INSTALL_PATH=$(norm_path "$install_dir")
    elif [[ -n "$domainname" ]]; then HELP_INSTALL_PATH="$DEFAULT_PARENT/$domainname"
    else HELP_INSTALL_PATH="$DEFAULT_PARENT/<domain>"; fi
    show_os_help
    hp=${http_port:-80}; sp=${https_port:-443}; vp=${supervisor_port:-9001}
    echo ""
    echo -e "${CYAN}Port status on this server:${NC}"
    for label in "HTTP:$hp" "HTTPS:$sp" "Supervisor:$vp"; do
        port=${label#*:}
        [[ "$port" == "none" ]] && continue
        valid_port "$port" || continue
        if port_in_use "$port"; then
            printf "$o" "${label%%:*} ($port)" "IN USE by $(port_owner "$port")"
        else
            printf "$o" "${label%%:*} ($port)" "free"
        fi
    done
    if [[ -n "$subnet" ]]; then
        printf "$o" "Docker subnet" "$subnet (from --subnet)"
    elif command -v docker >/dev/null 2>&1; then
        printf "$o" "Docker subnet" "$(choose_subnet quiet >/dev/null 2>&1; echo "${subnet_prefix}.0.0/16") (first free; change with --subnet)"
    fi
    local found
    found=$(find_installs 2>/dev/null)
    if [[ -n "$found" ]]; then
        echo ""
        echo -e "${CYAN}Faveo installations on this server:${NC}"
        while read -r port; do echo "  $port   ($(install_info "$port"))"; done <<<"$found"
    fi
}

# ----------------------------------------------------------------------------
# Validators
# ----------------------------------------------------------------------------
EMAIL_RE="^[A-Za-z0-9!#\$%&'*+/=?^_\`{|}~-]+(\.[A-Za-z0-9!#\$%&'*+/=?^_\`{|}~-]+)*@([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$"
DOMAIN_RE='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
DB_HOST_RE='^([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9])(\.([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]))*$'
DB_IPV4_RE='^((25[0-5]|(2[0-4]|1[0-9]|[1-9])?[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9])?[0-9])$'
DB_PASS_RE='^[A-Za-z0-9@#%^*_+=.,:!?-]{8,64}$'
DB_PASS_RULE="8-64 characters: letters, digits and @ # % ^ * _ + = . , : ! ? -"

valid_domain()   { [[ "$1" =~ $DOMAIN_RE ]] && (( ${#1} <= 253 )); }
valid_email()    { [[ "$1" =~ $EMAIL_RE ]]; }
valid_code()     { [[ -n "$1" && "$1" =~ ^[A-Za-z0-9-]+$ ]]; }
valid_order()    { valid_code "${1#\#}"; }
valid_db_host()  { [[ "$1" =~ $DB_HOST_RE || "$1" =~ $DB_IPV4_RE ]]; }
valid_db_ident() { [[ "$1" =~ ^[A-Za-z0-9_]{1,32}$ ]]; }
valid_db_pass()  { [[ "$1" =~ $DB_PASS_RE ]]; }
valid_port()     { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_tz()       { [[ "$1" == "UTC" || "$1" =~ ^[A-Za-z]+(/[A-Za-z0-9_+-]+)+$ ]]; }
# parse_subnet <value> -> PARSED_PREFIX ("x.y") for a valid x.y.0.0/16
parse_subnet() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.0\.0/16$ ]] || return 1
    (( BASH_REMATCH[1] <= 255 && BASH_REMATCH[2] <= 255 )) || return 1
    PARSED_PREFIX="$((10#${BASH_REMATCH[1]})).$((10#${BASH_REMATCH[2]}))"
}

normalize_ssl() {
    case "${1,,}" in
        a|certbot|letsencrypt|lets-encrypt) echo "A" ;;
        b|self-signed|selfsigned|self)      echo "B" ;;
        c|paid-ssl|paid|paidssl)            echo "C" ;;
        *) return 1 ;;
    esac
}
normalize_yesno() {
    case "${1,,}" in
        y|yes) echo "yes" ;;
        n|no)  echo "no" ;;
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

# Absolute, normalised path (no dependency on GNU realpath).
norm_path() {
    local p=$1 part out=() parts=()
    [[ "$p" == "~" || "$p" == "~/"* ]] && p="$HOME${p:1}"
    [[ "$p" != /* ]] && p="$PWD/$p"
    IFS=/ read -ra parts <<<"$p"
    for part in "${parts[@]}"; do
        case "$part" in
            ""|.) ;;
            ..)   [[ ${#out[@]} -gt 0 ]] && unset 'out[${#out[@]}-1]' ;;
            *)    out+=("$part") ;;
        esac
    done
    local IFS=/
    echo "/${out[*]}"
}

gen_password() {
    local n=${1:-20} p=""
    while [[ ${#p} -lt $n ]]; do
        p+=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')
    done
    echo "${p:0:$n}"
}

selinux_enforcing() {
    command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]
}

# ----------------------------------------------------------------------------
# Certificates (paid SSL and database SSL)
# A value may be a file path, base64-encoded PEM or raw PEM text.
# ----------------------------------------------------------------------------
pem_ok() {
    if [[ "$2" == "key" ]]; then
        openssl pkey -noout -in "$1" >/dev/null 2>&1
    else
        openssl x509 -noout -in "$1" >/dev/null 2>&1
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
    if [[ "$value" != *"-----BEGIN"* ]]; then
        decoded=$(printf '%s' "$value" | base64 -d 2>/dev/null)
        if [[ -n "$decoded" ]]; then
            printf '%s\n' "$decoded" > "$dest"; chmod 600 "$dest"
            pem_ok "$dest" "$kind" && return 0
        fi
    fi
    printf '%s\n' "$value" > "$dest"; chmod 600 "$dest"
    pem_ok "$dest" "$kind" && return 0
    rm -f "$dest"
    return 1
}

# Interactive: one prompt per file that accepts a path, pasted PEM or base64.
collect_cert_material() {
    local desc=$1 dest=$2 kind=$3 optional=${4:-n} tries=0 input line value example kname="certificate"
    # Example path for this file, shown in the prompt.
    case "$desc" in
        certificate.crt)          example="/home/siva/ssl/certificate.crt" ;;
        private.key)              example="/home/siva/ssl/private.key" ;;
        ca_bundle.crt)            example="/home/siva/ssl/ca_bundle.crt" ;;
        *"CA certificate"*)       example="/home/siva/db-ssl/ca.pem" ;;
        *"client certificate"*)   example="/home/siva/db-ssl/client-cert.pem" ;;
        *"client key"*)           example="/home/siva/db-ssl/client-key.pem" ;;
        *)                        example="/home/siva/ssl/$desc" ;;
    esac
    [[ "$kind" == "key" ]] && kname="private key"
    while true; do
        echo -e "${CYAN} $desc${NC}"
        echo -e "${GREEN}   Enter the full path of the file on this server, e.g. ${example}${NC}"
        echo -e "${GREEN}   or paste the content starting with -----BEGIN ...-----${NC}"
        [[ "$optional" == "y" ]] && echo -e "${GREEN}   or press Enter to skip${NC}"
        read -r -p "$(echo -e "${YELLOW} Path or content: ${NC}")" input || die "No input."
        input=${input%$'\r'}
        if [[ "$input" == -----BEGIN* ]]; then
            value="$input"
            while IFS= read -r line; do
                line=${line%$'\r'}
                value+=$'\n'"$line"
                if [[ "$line" == -----END*----- ]]; then
                    IFS= read -r -t 1 line || break
                    value+=$'\n'"${line%$'\r'}"
                fi
            done
            printf '%s\n' "$value" > "$dest"; chmod 600 "$dest"
            pem_ok "$dest" "$kind" && { ok "Pasted $desc validated."; return 0; }
            rm -f "$dest"
            echo -e "${RED} The pasted content is not a valid PEM $kname.${NC}"
        elif [[ -n "$input" ]]; then
            [[ "$input" == "~/"* ]] && input="$HOME${input:1}"
            if [[ -d "$input" ]]; then
                echo -e "${RED} '$input' is a folder. Give the full path of the file itself, e.g. ${example}${NC}"
            elif [[ -f "$input" ]]; then
                pem_ok "$input" "$kind" && { cp "$input" "$dest"; chmod 600 "$dest"; ok "Using '$input'."; return 0; }
                echo -e "${RED} '$input' is not a valid PEM $kname.${NC}"
            elif resolve_cert_arg "$input" "$dest" "$kind"; then
                ok "Base64 $desc decoded and validated."; return 0
            elif [[ "$input" == */* ]]; then
                echo -e "${RED} File '$input' does not exist. Check the path, e.g. ${example}${NC}"
            else
                echo -e "${RED} '$input' is not a file path or valid PEM $kname content. Example path: ${example}${NC}"
            fi
        elif [[ "$optional" == "y" ]]; then
            echo -e "${YELLOW} Skipped.${NC}"; return 2
        else
            echo -e "${RED} No input received.${NC}"
        fi
        tries=$((tries + 1))
        [[ $tries -ge $max_retries ]] && die "Too many invalid attempts for $desc."
        echo -e "${YELLOW} Please try again ($tries of $max_retries).${NC}"
    done
}

check_paid_ssl_bundle() {
    local crt="$STAGE_DIR/faveolocal.crt" key="$STAGE_DIR/private.key" c k
    c=$(openssl x509 -noout -pubkey -in "$crt" 2>/dev/null | openssl sha256)
    k=$(openssl pkey -pubout -in "$key" 2>/dev/null | openssl sha256)
    [[ -n "$c" && "$c" == "$k" ]] || die "The private key does not match the certificate."
    openssl x509 -checkend 0 -noout -in "$crt" >/dev/null 2>&1 || warn "The certificate has expired."
    if ! openssl x509 -noout -checkhost "$domainname" -in "$crt" 2>/dev/null | grep -q "does match"; then
        warn "The certificate does not appear to be issued for '$domainname'."
    fi
    ok "Certificate, private key and CA bundle validated."
}

# ----------------------------------------------------------------------------
# Ports and Docker subnet
# ----------------------------------------------------------------------------
port_in_use() {
    local p=$1
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -Eq "[:.]${p}[[:space:]]"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | grep -Eq "[:.]${p}[[:space:]]"
    else
        (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null
    fi
}

# Busy = in use, except by the containers of the installation being replaced (--force).
port_busy() {
    local names
    port_in_use "$1" || return 1
    if [[ "$force" == "y" && -n "$domainname" ]] && command -v docker >/dev/null 2>&1; then
        names=$(docker ps --filter "publish=$1" --format '{{.Names}}' 2>/dev/null)
        [[ -n "$names" ]] && ! grep -qv "^${domainname}-" <<<"$names" && return 1
    fi
    return 0
}

port_owner() {
    local p=$1 names proc
    if command -v docker >/dev/null 2>&1; then
        names=$(docker ps --filter "publish=$p" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
        [[ -n "${names// /}" ]] && { echo "container ${names% }"; return; }
    fi
    proc=$(ss -ltnp 2>/dev/null | grep -E "[:.]${p}[[:space:]]" | grep -o 'users:(("[^"]*' | head -1 | cut -d'"' -f2)
    echo "${proc:-another program}"
}

# next_free_port <start> <exclude...>
next_free_port() {
    local p=$1 x skip; shift
    while (( p <= 65535 )); do
        skip=""
        for x in "$@"; do [[ "$x" == "$p" ]] && skip=y; done
        [[ -z "$skip" ]] && ! port_busy "$p" && { echo "$p"; return 0; }
        p=$((p + 1))
    done
    return 1
}

apply_port_rules() {
    [[ "$supervisor_port" == "0" ]] && supervisor_port="none"
    if [[ "$ssl_option" == "A" ]]; then
        if [[ -n "$http_port" && $((10#$http_port)) -ne 80 ]] || [[ -n "$https_port" && $((10#$https_port)) -ne 443 ]]; then
            die "Let's Encrypt (certbot) needs HTTP port 80 and HTTPS port 443. Remove --http-port/--https-port, or use self-signed / paid-ssl."
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
    if [[ $https_port -eq 443 ]]; then site_url="https://$domainname"; else site_url="https://$domainname:$https_port"; fi
}

# resolve_port <variable> <label> <suggest-from>
resolve_port() {
    local __var=$1 label=$2 from=$3 port=${!1} owner suggest input tries=0 others=() v
    port_busy "$port" || return 0
    owner=$(port_owner "$port")
    if [[ "$ssl_option" == "A" && ( "$__var" == http_port || "$__var" == https_port ) ]]; then
        die "Port $port ($label) is in use by $owner. Let's Encrypt needs ports 80 and 443: stop that service, or use self-signed / paid-ssl with other ports."
    fi
    for v in http_port https_port supervisor_port; do
        [[ "$v" != "$__var" && "${!v}" != "none" ]] && others+=("${!v}")
    done
    suggest=$(next_free_port "$from" "${others[@]}") || die "No free port found for $label."
    if [[ "$auto_ports" == "y" ]]; then
        warn "Port $port ($label) is in use by $owner; using free port $suggest."
        printf -v "$__var" '%s' "$suggest"; return 0
    fi
    interactive || die "Port $port ($label) is in use by $owner. Use --${__var//_/-} $suggest (free) or add --auto-ports."
    warn "Port $port ($label) is in use by $owner."
    while true; do
        read -r -p "$(echo -e "${YELLOW} Enter another $label port [$suggest]: ${NC}")" input || die "No input."
        input=${input:-$suggest}
        if ! valid_port "$input"; then
            echo -e "${RED} '$input' is not a valid port (1-65535).${NC}"
        elif printf '%s\n' "${others[@]}" | grep -qx "$((10#$input))"; then
            echo -e "${RED} Port $input is already used by another Faveo service.${NC}"
        elif port_busy "$((10#$input))"; then
            echo -e "${RED} Port $input is also in use by $(port_owner "$((10#$input))").${NC}"
        else
            printf -v "$__var" '%s' "$((10#$input))"; ok "Using port $((10#$input)) for $label."; return 0
        fi
        tries=$((tries + 1)); [[ $tries -ge $max_retries ]] && die "Too many invalid attempts."
    done
}

port_status() {
    local p=$1
    [[ "$p" == "none" ]] && { echo "not published"; return; }
    [[ "$generate_only" == "y" ]] && { echo ""; return; }
    port_busy "$p" && echo "IN USE by $(port_owner "$p")" || echo "free"
}

ask_port() {
    local __var=$1 label=$2 cur=${!1} input tries=0 others=() v allow_none=""
    [[ "$__var" == supervisor_port ]] && allow_none=" (or 'none')"
    for v in http_port https_port supervisor_port; do
        [[ "$v" != "$__var" && "${!v}" != "none" ]] && others+=("${!v}")
    done
    while true; do
        read -r -p "$(echo -e "${YELLOW} $label port${allow_none} [$cur]: ${NC}")" input || die "No input."
        input=${input:-$cur}; input=${input,,}
        if [[ -n "$allow_none" && ( "$input" == "none" || "$input" == "0" ) ]]; then
            printf -v "$__var" '%s' "none"; return 0
        elif ! valid_port "$input"; then
            echo -e "${RED} '$input' is not a valid port (1-65535).${NC}"
        elif printf '%s\n' "${others[@]}" | grep -qx "$((10#$input))"; then
            echo -e "${RED} Port $input is already used by another Faveo service.${NC}"
        elif [[ "$generate_only" != "y" ]] && port_busy "$((10#$input))"; then
            echo -e "${RED} Port $input is in use by $(port_owner "$((10#$input))").${NC}"
        else
            printf -v "$__var" '%s' "$((10#$input))"; return 0
        fi
        tries=$((tries + 1)); [[ $tries -ge $max_retries ]] && die "Too many invalid attempts."
    done
}

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
        [[ "$generate_only" != "y" ]] && { resolve_port http_port "HTTP" 8080; resolve_port https_port "HTTPS" 8443; }
        echo -e "${YELLOW} Let's Encrypt needs HTTP 80 and HTTPS 443; only the Supervisor port can be changed.${NC}"
    fi
    read -r -p "$(echo -e "${YELLOW} Do you want to use custom ports? (y/N): ${NC}")" answer || answer=""
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || return 0
    if [[ "$ssl_option" != "A" ]]; then
        ask_port http_port "HTTP"
        ask_port https_port "HTTPS"
    fi
    ask_port supervisor_port "Supervisor"
    set_site_url
    ok "Ports: HTTP $http_port, HTTPS $https_port, Supervisor $supervisor_port"
}

# Networks in use: Docker networks (except this install's own) and host routes.
used_networks() {
    local n name rest s
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        for n in $(docker network ls -q 2>/dev/null); do
            read -r name rest <<<"$(docker network inspect -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' "$n" 2>/dev/null)"
            [[ "$name" == "${domainname}-faveo" ]] && continue
            for s in $rest; do echo "$s"; done
        done
    fi
    if command -v ip >/dev/null 2>&1; then
        ip -4 route 2>/dev/null | while read -r s _; do [[ "$s" == */* ]] && echo "$s"; done
    fi
}

ip2int() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }

# subnet_free <x.y> : true when x.y.0.0/16 overlaps none of the used networks.
subnet_free() {
    local start end net ip bits nstart nend
    start=$(ip2int "$1.0.0"); end=$((start + 65535))
    while read -r net; do
        [[ "$net" =~ ^([0-9.]+)/([0-9]+)$ ]] || continue
        ip=${BASH_REMATCH[1]}; bits=${BASH_REMATCH[2]}
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        nstart=$(( $(ip2int "$ip") & ((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF) ))
        nend=$(( nstart + (1 << (32 - bits)) - 1 ))
        (( nstart <= end && start <= nend )) && return 1
    done <<<"$USED_NETWORKS"
    return 0
}

choose_subnet() {
    local cand
    USED_NETWORKS=$(used_networks 2>/dev/null)
    if [[ -n "$subnet" ]]; then
        subnet_free "$subnet_prefix" || die "Subnet $subnet overlaps a network already used on this server. Choose another --subnet."
        return 0
    fi
    for cand in 172.{24..31} 172.{18..23} 10.{24..40}; do
        if subnet_free "$cand"; then
            subnet_prefix=$cand
            [[ "$cand" != "172.24" && "$1" != "quiet" ]] && info "Subnet 172.24.0.0/16 is in use; using free subnet ${cand}.0.0/16."
            return 0
        fi
    done
    die "No free /16 subnet found for the Docker network. Give one with --subnet."
}

ask_custom_subnet() {
    interactive || return 0
    [[ -n "$subnet" ]] && return 0
    local answer input tries=0
    [[ "$generate_only" != "y" ]] && choose_subnet quiet
    echo ""
    echo -e "${CYAN} Docker network subnet for the Faveo containers: ${GREEN}${subnet_prefix}.0.0/16${NC}"
    echo "    (it must not overlap your LAN or VPN)"
    read -r -p "$(echo -e "${YELLOW} Do you want to use a custom subnet? (y/N): ${NC}")" answer || answer=""
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || return 0
    while true; do
        read -r -p "$(echo -e "${YELLOW} Subnet, e.g. 172.30.0.0/16 [${subnet_prefix}.0.0/16]: ${NC}")" input || die "No input."
        input=${input:-${subnet_prefix}.0.0/16}
        if ! parse_subnet "$input"; then
            echo -e "${RED} '$input' is not valid. Use the form x.y.0.0/16.${NC}"
        elif [[ "$generate_only" != "y" ]] && ! subnet_free "$PARSED_PREFIX"; then
            echo -e "${RED} $input overlaps a network already used on this server.${NC}"
        else
            subnet="$PARSED_PREFIX.0.0/16"; subnet_prefix=$PARSED_PREFIX; ok "Using Docker subnet $subnet."; return 0
        fi
        tries=$((tries + 1)); [[ $tries -ge $max_retries ]] && die "Too many invalid attempts."
    done
}

resolve_ports() {
    [[ "$generate_only" == "y" ]] && return 0
    choose_subnet
    resolve_port http_port "HTTP" 8080
    resolve_port https_port "HTTPS" 8443
    [[ "$supervisor_port" != "none" ]] && resolve_port supervisor_port "Supervisor" 9002
    set_site_url
}

# ----------------------------------------------------------------------------
# OS support: package, Docker, Compose, Buildx and service helpers.
# Shared with the other installers in this repository and tested on 39 Linux
# distribution versions (see SUPPORTED_OS.txt).
# ----------------------------------------------------------------------------
install_packages() {
    [[ $# -eq 0 ]] && return 0
    echo "Installing missing packages: $*"
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y "$@"
    elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y "$@"
    elif command -v zypper >/dev/null 2>&1; then
        $SUDO zypper --non-interactive install "$@"
    elif command -v pacman >/dev/null 2>&1; then
        $SUDO pacman -Sy --noconfirm --needed "$@"
    elif command -v apk >/dev/null 2>&1; then
        $SUDO apk add --no-cache "$@"
    elif command -v xbps-install >/dev/null 2>&1; then
        $SUDO xbps-install -Sy "$@"
    else
        echo "No supported package manager found. Please install manually: $*"
        return 1
    fi
}

os_release_value() {
    [[ -r /etc/os-release ]] && ( . /etc/os-release && eval "echo \"\${$1}\"" )
}

install_compose_plugin() {
    local arch
    case "$(uname -m)" in
        x86_64|amd64)  arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        armv7l)        arch="armv7" ;;
        armv6l)        arch="armv6" ;;
        ppc64le)       arch="ppc64le" ;;
        s390x)         arch="s390x" ;;
        *) echo "Unsupported architecture $(uname -m) for the Docker Compose plugin."; return 1 ;;
    esac
    echo "Installing Docker Compose plugin..."
    $SUDO mkdir -p /usr/local/lib/docker/cli-plugins
    $SUDO curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose \
        && $SUDO chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
}

# Compose builds the Faveo images with buildx, which must be v0.17.0 or newer
# (Amazon Linux and some distro packages ship without it or with an older one).
buildx_ok() {
    local v major rest minor
    v=$(docker buildx version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    v=${v#v}
    [[ -n "$v" ]] || return 1
    major=${v%%.*}; rest=${v#*.}; minor=${rest%%.*}
    (( major > 0 || minor >= 17 ))
}

install_buildx_plugin() {
    local arch tag
    case "$(uname -m)" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l)        arch="arm-v7" ;;
        armv6l)        arch="arm-v6" ;;
        ppc64le)       arch="ppc64le" ;;
        s390x)         arch="s390x" ;;
        riscv64)       arch="riscv64" ;;
        *) echo "Unsupported architecture $(uname -m) for the Docker Buildx plugin."; return 1 ;;
    esac
    tag=$(curl -fsSLo /dev/null -w '%{url_effective}' https://github.com/docker/buildx/releases/latest)
    tag=${tag##*/}
    if [[ "$tag" != v* ]]; then
        echo "Could not determine the latest Docker Buildx release."
        return 1
    fi
    echo "Installing Docker Buildx plugin ${tag}..."
    $SUDO mkdir -p /usr/local/lib/docker/cli-plugins
    $SUDO curl -fsSL "https://github.com/docker/buildx/releases/download/${tag}/buildx-${tag}.linux-${arch}" \
        -o /usr/local/lib/docker/cli-plugins/docker-buildx \
        && $SUDO chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
}

install_docker() {
    local os_id os_like codename repo
    os_id=$(os_release_value ID)
    os_like=" $(os_release_value ID_LIKE) "
    echo "Docker is not installed. Installing Docker for '${os_id:-unknown}'..."

    if [[ "$os_id" == "amzn" ]]; then
        # Amazon Linux ships its own Docker package; Compose plugin is added below.
        if command -v dnf >/dev/null 2>&1; then
            $SUDO dnf install -y docker
        elif command -v amazon-linux-extras >/dev/null 2>&1; then
            $SUDO amazon-linux-extras install -y docker   # Amazon Linux 2
        else
            $SUDO yum install -y docker
        fi

    elif command -v apt-get >/dev/null 2>&1; then
        if [[ "$os_id" == "ubuntu" || "$os_like" == *" ubuntu "* ]]; then
            repo="ubuntu"
            codename=$(os_release_value UBUNTU_CODENAME)
        else
            repo="debian"
            [[ "$os_id" == "raspbian" ]] && repo="raspbian"
            codename=$(os_release_value VERSION_CODENAME)
            [[ "$os_id" == "kali" ]] && codename="bookworm"
        fi
        [[ -z "$codename" ]] && codename=$(os_release_value VERSION_CODENAME)
        $SUDO apt-get update
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
        $SUDO install -m 0755 -d /etc/apt/keyrings
        $SUDO curl -fsSL "https://download.docker.com/linux/${repo}/gpg" -o /etc/apt/keyrings/docker.asc
        $SUDO chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${repo} ${codename} stable" \
            | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
        $SUDO apt-get update
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        case "$os_id" in
            fedora) repo="fedora" ;;
            rhel)   repo="rhel" ;;
            *)      repo="centos" ;;   # CentOS, Rocky, AlmaLinux, Oracle Linux and other EL clones
        esac
        $SUDO curl -fsSL "https://download.docker.com/linux/${repo}/docker-ce.repo" -o /etc/yum.repos.d/docker-ce.repo
        if command -v dnf >/dev/null 2>&1; then
            # --allowerasing replaces conflicting podman/runc packages on EL8/EL9.
            $SUDO dnf install -y --allowerasing \
                docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        else
            $SUDO yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        fi

    elif command -v zypper >/dev/null 2>&1; then
        $SUDO zypper --non-interactive install docker docker-compose \
            || $SUDO zypper --non-interactive install docker

    elif command -v pacman >/dev/null 2>&1; then
        $SUDO pacman -Sy --noconfirm --needed docker docker-compose

    elif command -v apk >/dev/null 2>&1; then
        $SUDO apk add --no-cache docker docker-cli-compose

    elif command -v xbps-install >/dev/null 2>&1; then
        $SUDO xbps-install -Sy docker docker-compose

    else
        # Last resort: Docker's convenience script.
        curl -fsSL https://get.docker.com | $SUDO sh
    fi
}

# Start the Docker daemon if it is installed but not running. Each init system is
# tried in turn, so hosts where systemctl exists but systemd is not running
# (WSL2 without systemd, containers) fall back to the SysV "service" script.
start_docker_daemon() {
    docker info >/dev/null 2>&1 && return 0
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        $SUDO systemctl enable --now docker >/dev/null 2>&1
        docker info >/dev/null 2>&1 && return 0
    fi
    if command -v rc-service >/dev/null 2>&1; then
        $SUDO rc-update add docker default >/dev/null 2>&1
        $SUDO rc-service docker start >/dev/null 2>&1
        docker info >/dev/null 2>&1 && return 0
    fi
    if command -v sv >/dev/null 2>&1 && [[ -d /etc/sv/docker ]]; then
        # runit (Void Linux)
        [[ -e /var/service/docker ]] || $SUDO ln -s /etc/sv/docker /var/service/
        $SUDO sv up docker >/dev/null 2>&1
        docker info >/dev/null 2>&1 && return 0
    fi
    if command -v service >/dev/null 2>&1; then
        $SUDO service docker start >/dev/null 2>&1
    fi
}

# Make sure cron is running so the Let's Encrypt renewal job fires.
enable_cron_service() {
    # openSUSE/SLES: cronie's spool dir is normally created by systemd-tmpfiles at boot.
    if command -v zypper >/dev/null 2>&1 && [[ ! -d /var/spool/cron/tabs ]]; then
        $SUDO mkdir -p -m 0700 /var/spool/cron/tabs
    fi
    if command -v systemctl >/dev/null 2>&1; then
        for svc in cron crond cronie; do
            $SUDO systemctl enable --now "$svc" >/dev/null 2>&1 && return 0
        done
    elif command -v rc-service >/dev/null 2>&1; then
        for svc in crond cronie; do
            $SUDO rc-update add "$svc" default >/dev/null 2>&1 && $SUDO rc-service "$svc" start >/dev/null 2>&1 && return 0
        done
    elif command -v sv >/dev/null 2>&1 && [[ -d /etc/sv/cronie ]]; then
        [[ -e /var/service/cronie ]] || $SUDO ln -s /etc/sv/cronie /var/service/
        $SUDO sv up cronie >/dev/null 2>&1
    elif command -v service >/dev/null 2>&1; then
        $SUDO service cron start >/dev/null 2>&1 || $SUDO service crond start >/dev/null 2>&1
    fi
    return 0
}

# Detect the host OS and print OS-specific guidance (used by --help). Read-only: changes nothing.
show_os_help() {
    local os_name="" os_id="" os_like="" pkg="none detected" family="other"
    local docker_status compose_status selinux_status="Not present" firewall="none detected" run_as
    local script_name
    script_name=$(basename "$0")

    if [[ -r /etc/os-release ]]; then
        os_name=$( . /etc/os-release && echo "${PRETTY_NAME:-$NAME}" )
        os_id=$( . /etc/os-release && echo "$ID" )
        os_like=" $( . /etc/os-release && echo "$ID_LIKE" ) "
    fi

    if   command -v apt-get >/dev/null 2>&1; then pkg="apt"
    elif command -v dnf     >/dev/null 2>&1; then pkg="dnf"
    elif command -v yum     >/dev/null 2>&1; then pkg="yum"
    elif command -v zypper  >/dev/null 2>&1; then pkg="zypper"
    elif command -v pacman  >/dev/null 2>&1; then pkg="pacman"
    elif command -v apk     >/dev/null 2>&1; then pkg="apk"
    elif command -v xbps-install >/dev/null 2>&1; then pkg="xbps"
    fi

    case "$os_id" in
        amzn)                                   family="amazon" ;;
        fedora)                                 family="fedora" ;;
        rhel|centos|rocky|almalinux|ol)         family="rhel" ;;
        ubuntu|debian|raspbian|linuxmint|pop|kali) family="debian" ;;
        opensuse*|sles|sled)                    family="suse" ;;
        arch|manjaro|endeavouros)               family="arch" ;;
        alpine)                                 family="alpine" ;;
        void)                                   family="void" ;;
        *)
            case "$os_like" in
                *" rhel "*|*" centos "*|*" fedora "*) family="rhel" ;;
                *" debian "*|*" ubuntu "*)           family="debian" ;;
                *" suse "*)                          family="suse" ;;
                *" arch "*)                          family="arch" ;;
            esac
            ;;
    esac

    if command -v docker >/dev/null 2>&1; then
        docker_status=$(docker --version 2>/dev/null)
    else
        docker_status="Not installed (will be installed automatically)"
    fi
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        compose_status=$(docker compose version 2>/dev/null)
    elif command -v docker-compose >/dev/null 2>&1; then
        compose_status="$(docker-compose version --short 2>/dev/null) (standalone docker-compose)"
    else
        compose_status="Not installed (will be installed automatically)"
    fi

    if command -v getenforce >/dev/null 2>&1; then
        selinux_status=$(getenforce 2>/dev/null)
        [[ "$selinux_status" == "Enforcing" ]] && selinux_status="Enforcing (install folder will be labelled automatically)"
    fi

    if command -v ufw >/dev/null 2>&1; then
        firewall="ufw"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall="firewalld"
    fi

    if [[ $EUID -eq 0 ]]; then run_as="root"; else run_as="$(id -un) (sudo will be used)"; fi

    echo ""
    echo "Detected system:"
    echo "  Operating System : ${os_name:-Unknown Linux}"
    echo "  Architecture     : $(uname -m)"
    echo "  Package Manager  : $pkg"
    echo "  Docker           : $docker_status"
    echo "  Docker Compose   : $compose_status"
    echo "  SELinux          : $selinux_status"
    echo "  Firewall tool    : $firewall"
    echo "  Running as       : $run_as"
    echo ""
    echo "Notes for this OS:"
    case "$family" in
        debian)
            echo "  - Docker is installed from Docker's official apt repository (download.docker.com)."
            ;;
        rhel)
            echo "  - Docker CE is installed from Docker's official repository."
            echo "  - Conflicting podman/runc packages are replaced automatically (dnf --allowerasing)."
            ;;
        fedora)
            echo "  - Docker CE is installed from Docker's official Fedora repository."
            echo "  - Conflicting podman/runc packages are replaced automatically (dnf --allowerasing)."
            ;;
        amazon)
            echo "  - Docker is installed from the Amazon Linux repository; the Compose plugin is downloaded from GitHub."
            echo "  - Allow inbound TCP 80 and 443 in the instance's AWS Security Group."
            ;;
        suse)
            echo "  - Docker is installed with zypper (on SLES enable the Containers Module first:"
            echo "    sudo SUSEConnect -p sle-module-containers/<version>/<arch>)."
            ;;
        arch)
            echo "  - Docker is installed with pacman (docker, docker-compose)."
            ;;
        alpine)
            echo "  - Docker is installed with apk (docker, docker-cli-compose) and enabled in OpenRC."
            echo "  - bash is required: apk add bash"
            ;;
        void)
            echo "  - Docker is installed with xbps (docker, docker-compose) and enabled as a runit service."
            ;;
        *)
            echo "  - OS not specifically recognised; Docker will be installed with https://get.docker.com."
            echo "  - If that fails, install Docker manually: https://docs.docker.com/engine/install/"
            ;;
    esac
    case "$firewall" in
        ufw)       echo "  - If ufw is active, allow web traffic: sudo ufw allow 80,443/tcp" ;;
        firewalld) echo "  - If firewalld is active, allow web traffic:"
                   echo "    sudo firewall-cmd --permanent --add-service=http --add-service=https && sudo firewall-cmd --reload" ;;
    esac
    if [[ $EUID -ne 0 ]]; then
        echo "  - Run the script as root or with sudo: sudo ./$script_name ..."
    fi

    # Docker Compose / service commands for this system.
    local compose_cmd="docker compose" prefix="" svc_prefix="" install_dir
    if ! (command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1) \
        && command -v docker-compose >/dev/null 2>&1; then
        compose_cmd="docker-compose"
    fi
    if [[ $EUID -ne 0 ]]; then
        svc_prefix="sudo "
        id -nG 2>/dev/null | grep -qw docker || prefix="sudo "
    fi
    install_dir=$HELP_INSTALL_PATH

    echo ""
    echo "Docker Compose commands for this system (run from ${install_dir:-the install folder}):"
    echo "  cd ${install_dir:-<install folder>}"
    echo "  Start containers   : ${prefix}${compose_cmd} up -d"
    echo "  Stop containers    : ${prefix}${compose_cmd} down"
    echo "  Restart containers : ${prefix}${compose_cmd} down && ${prefix}${compose_cmd} up -d"
    echo "  Container status   : ${prefix}${compose_cmd} ps"
    echo "  Follow logs        : ${prefix}${compose_cmd} logs -f"
    echo ""
    echo "Docker service commands for this system:"
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        echo "  Start Docker       : ${svc_prefix}systemctl start docker"
        echo "  Stop Docker        : ${svc_prefix}systemctl stop docker"
        echo "  Enable on boot     : ${svc_prefix}systemctl enable docker"
        echo "  Docker status      : ${svc_prefix}systemctl status docker"
    elif command -v sv >/dev/null 2>&1 || [[ "$family" == "void" ]]; then
        echo "  Start Docker       : ${svc_prefix}sv up docker"
        echo "  Stop Docker        : ${svc_prefix}sv down docker"
        echo "  Enable on boot     : ${svc_prefix}ln -s /etc/sv/docker /var/service/"
        echo "  Docker status      : ${svc_prefix}sv status docker"
    elif command -v rc-service >/dev/null 2>&1 || [[ "$family" == "alpine" ]]; then
        echo "  Start Docker       : ${svc_prefix}rc-service docker start"
        echo "  Stop Docker        : ${svc_prefix}rc-service docker stop"
        echo "  Enable on boot     : ${svc_prefix}rc-update add docker default"
        echo "  Docker status      : ${svc_prefix}rc-service docker status"
    else
        echo "  Start Docker       : ${svc_prefix}service docker start"
        echo "  Stop Docker        : ${svc_prefix}service docker stop"
        echo "  Docker status      : ${svc_prefix}service docker status"
    fi
}

# ----------------------------------------------------------------------------
# Prerequisites
# ----------------------------------------------------------------------------
# Start Docker at boot so the containers ("restart: unless-stopped") come back after a reboot.
enable_docker_on_boot() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemctl enable docker >/dev/null 2>&1 || warn "Could not enable Docker at boot (systemctl enable docker)."
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update add docker default >/dev/null 2>&1 || warn "Could not enable Docker at boot (rc-update add docker default)."
    elif command -v sv >/dev/null 2>&1 && [[ -d /etc/sv/docker ]]; then
        [[ -e /var/service/docker ]] || ln -s /etc/sv/docker /var/service/ 2>/dev/null \
            || warn "Could not enable Docker at boot (ln -s /etc/sv/docker /var/service/)."
    elif command -v update-rc.d >/dev/null 2>&1; then
        update-rc.d docker defaults >/dev/null 2>&1 || true
    elif command -v chkconfig >/dev/null 2>&1; then
        chkconfig docker on >/dev/null 2>&1 || true
    fi
}

prepare_system() {
    local answer cmd missing=() need_docker="n"
    info "Checking prerequisites..."
    case "$(uname -m)" in
        x86_64|amd64|aarch64|arm64) ok "Architecture: $(uname -m)" ;;
        *) die "Architecture '$(uname -m)' is not supported. Faveo needs x86_64 or aarch64 (ARM64)." ;;
    esac
    ok "Operating system: $(os_release_value PRETTY_NAME)"

    for cmd in unzip curl openssl tar gzip; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    command -v find >/dev/null 2>&1 || missing+=("findutils")
    if [[ "$ssl_option" == "A" ]] && ! command -v crontab >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then missing+=("cron"); else missing+=("cronie"); fi
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        install_packages "${missing[@]}"
    fi
    for cmd in unzip curl openssl tar gzip find; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command '$cmd' is not available. Install it and run the script again."
    done
    ok "Required tools are available."

    if ! command -v docker >/dev/null 2>&1; then
        need_docker="y"
    elif ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        need_docker="y"
    elif ! buildx_ok; then
        need_docker="y"
    fi
    if [[ "$need_docker" == "y" ]]; then
        if [[ "$install_docker_flag" != "y" ]]; then
            interactive || die "Docker / Docker Compose is missing or too old. Run again with --install-docker, or install it: https://docs.docker.com/engine/install/"
            warn "Docker Engine, Docker Compose or Docker Buildx is missing or too old."
            read -r -p "$(echo -e "${YELLOW} Install them now for this OS? (Y/n): ${NC}")" answer || answer="n"
            [[ "${answer:-y}" =~ ^([yY]|[yY][eE][sS])$ ]] || die "Docker is required. Install it and run the script again."
        fi
        command -v docker >/dev/null 2>&1 || install_docker
        command -v docker >/dev/null 2>&1 || die "Docker installation failed. Install it manually (https://docs.docker.com/engine/install/) and run again."
        start_docker_daemon
        if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
            install_compose_plugin
        fi
        buildx_ok || install_buildx_plugin
    fi

    start_docker_daemon
    local i
    for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
    docker info >/dev/null 2>&1 || die "The Docker daemon is not running. Start it (e.g. systemctl start docker) and run again."
    enable_docker_on_boot
    ok "$(docker --version) (starts at boot)"

    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE="docker-compose"
    else
        die "Docker Compose is not available. Run again with --install-docker."
    fi
    ok "$($DOCKER_COMPOSE version 2>/dev/null | head -1)"
    buildx_ok || die "Docker Buildx 0.17 or newer is required to build the images. Run again with --install-docker."
    selinux_enforcing && ok "SELinux is enforcing; bind mounts get the ':z' label automatically."
    ok "Prerequisites check completed."
}

detect_compose() {
    [[ -n "$DOCKER_COMPOSE" ]] && return 0
    if docker compose version >/dev/null 2>&1; then DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then DOCKER_COMPOSE="docker-compose"
    else DOCKER_COMPOSE="docker compose"; fi
}

# ----------------------------------------------------------------------------
# Remote database
# ----------------------------------------------------------------------------
# remote_mysql <user> <password> [mysql args...] - MySQL client in a throw-away
# container on the host network. The password is passed through the
# environment, never on the command line.
remote_mysql() {
    local user=$1 pass=$2 host=$db_host args=() vol=(); shift 2
    [[ "$host" == "localhost" || "$host" == "::1" ]] && host="127.0.0.1"   # no socket inside the container
    args=(-h "$host" -P "$db_port" -u "$user" --connect-timeout=10 -N -B)
    if [[ "$db_ssl" == "yes" ]]; then
        vol=(-v "$STAGE_DIR:/dbssl:ro$(selinux_enforcing && echo ,z)")
        args+=(--ssl-ca=/dbssl/db-ca.pem)
        [[ -f "$STAGE_DIR/db-cert.pem" ]] && args+=(--ssl-cert=/dbssl/db-cert.pem)
        [[ -f "$STAGE_DIR/db-key.pem"  ]] && args+=(--ssl-key=/dbssl/db-key.pem)
        [[ "$db_ssl_verify" == "yes" ]] && args+=(--ssl-mode=VERIFY_IDENTITY) || args+=(--ssl-mode=VERIFY_CA)
    fi
    MYSQL_PWD="$pass" docker run --rm -i --network host -e MYSQL_PWD "${vol[@]}" "$MYSQL_IMAGE" mysql "${args[@]}" "$@"
}

remote_db_check() {
    local out exists tables answer
    info "Testing the connection to $db_host:$db_port as '$db_admin_user'..."
    out=$(remote_mysql "$db_admin_user" "$db_admin_password" -e "SELECT VERSION();" 2>&1) \
        || die "Could not connect to the database server $db_host:$db_port: $(grep -v 'Using a password' <<<"$out" | tail -1)"
    ok "Connected to the database server (version $(tail -1 <<<"$out"))."

    exists=$(remote_mysql "$db_admin_user" "$db_admin_password" -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$db_name';" 2>/dev/null)
    if [[ "$exists" == "1" ]]; then
        tables=$(remote_mysql "$db_admin_user" "$db_admin_password" -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$db_name';" 2>/dev/null)
        [[ "${tables:-0}" -gt 0 ]] && die "Database '$db_name' on $db_host is not empty ($tables tables). Choose another --db-name."
        RB_REMOTE_DB_EXISTED="y"
        info "Database '$db_name' already exists and is empty; it will be used."
    fi
    if [[ "$(remote_mysql "$db_admin_user" "$db_admin_password" -e "SELECT COUNT(*) FROM mysql.user WHERE user='$db_user' AND host='%';" 2>/dev/null)" == "1" ]]; then
        RB_REMOTE_USER_EXISTED="y"
        # Reusing the user (with a new password) is safe only when it belongs to Faveo: its grants
        # may cover just the login right (USAGE ON *.*) and the Faveo database. A user with access
        # to other databases is probably used by another application - changing its password would
        # break that application.
        local grants other
        grants=$(remote_mysql "$db_admin_user" "$db_admin_password" -e "SHOW GRANTS FOR '$db_user'@'%';" 2>/dev/null)
        other=$(grep -vE "^GRANT USAGE ON \*\.\* TO " <<<"$grants" | grep -vE " ON [\`']?${db_name}[\`']?\.\* TO " | grep -v '^[[:space:]]*$')
        if [[ -n "$grants" && -z "$other" ]]; then
            warn "Database user '$db_user' already exists on $db_host and has access only to '$db_name' - reusing it with a new password."
            RB_REMOTE_USER_REUSED="y"
        else
            warn "Database user '$db_user' already exists on $db_host and has access to other databases too:"
            [[ -n "$other" ]] && sed 's/^/          /' <<<"$other"
            if interactive; then
                read -r -p "$(echo -e "${YELLOW} Change its password anyway? Other applications using it will stop working. (y/N): ${NC}")" answer || answer=""
                [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || die "Choose another database user (--db-user) and run again."
            else
                die "Database user '$db_user' on $db_host is also used for other databases. Choose another --db-user, so its password is not changed."
            fi
        fi
    fi
}

remote_db_create() {
    local out req=""
    [[ "$db_ssl" == "yes" ]] && req=" REQUIRE SSL"
    info "Creating database '$db_name' and user '$db_user' on $db_host..."
    out=$(remote_mysql "$db_admin_user" "$db_admin_password" 2>&1 <<SQL
CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$db_user'@'%' IDENTIFIED BY '$db_password';
ALTER USER '$db_user'@'%' IDENTIFIED BY '$db_password'$req;
GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'%';
FLUSH PRIVILEGES;
SQL
    ) || die "Could not create the database/user on $db_host (does '$db_admin_user' have CREATE USER and GRANT rights?): $(grep -v 'Using a password' <<<"$out" | tail -1)"
    [[ "$RB_REMOTE_DB_EXISTED" != "y" ]] && RB_REMOTE_DB_CREATED="y"
    [[ "$RB_REMOTE_USER_EXISTED" != "y" ]] && RB_REMOTE_USER_CREATED="y"
    out=$(remote_mysql "$db_user" "$db_password" -e "USE \`$db_name\`; SELECT 1;" 2>&1) \
        || die "User '$db_user' could not log in to $db_host: $(grep -v 'Using a password' <<<"$out" | tail -1)"
    ok "Remote database '$db_name' and user '$db_user' are ready (login tested)."
}

remote_db_rollback() {
    [[ "$db_location" == "remote" ]] || return 0
    if [[ "$RB_REMOTE_DB_CREATED" == "y" ]]; then
        remote_mysql "$db_admin_user" "$db_admin_password" -e "DROP DATABASE IF EXISTS \`$db_name\`;" >/dev/null 2>&1 \
            && step_done "Dropped database $db_name on $db_host (created by this run)"
    fi
    if [[ "$RB_REMOTE_USER_CREATED" == "y" || "$RB_REMOTE_USER_REUSED" == "y" ]]; then
        remote_mysql "$db_admin_user" "$db_admin_password" -e "DROP USER IF EXISTS '$db_user'@'%';" >/dev/null 2>&1 \
            && step_done "Dropped database user $db_user on $db_host ($([[ "$RB_REMOTE_USER_REUSED" == "y" ]] && echo "reused" || echo "created") by this run)"
    fi
}

# --uninstall of a remote-database installation: remove the Faveo database user from the
# database server (the database itself is kept). Needs the admin account, which is not stored:
# asked for interactively, or --db-admin-user / --db-admin-password.
uninstall_remote_db_user() {
    local dir=$1 answer err
    db_host=$(env_get "$dir" DB_HOST_FROM_SERVER); db_port=$(env_get "$dir" DB_PORT); db_port=${db_port:-3306}
    db_user=$(env_get "$dir" DB_USERNAME); db_ssl=$(env_get "$dir" DB_SSL); db_ssl_verify=$(env_get "$dir" DB_SSL_VERIFY)
    [[ -n "$db_host" && -n "$db_user" ]] || { warn "Database server details not found in .env - the database user was not removed."; return 0; }
    if [[ "$db_ssl" == "yes" ]]; then
        cp "$dir/db_ssl/ca.pem" "$STAGE_DIR/db-ca.pem" 2>/dev/null
        [[ -f "$dir/db_ssl/client-cert.pem" ]] && cp "$dir/db_ssl/client-cert.pem" "$STAGE_DIR/db-cert.pem"
        [[ -f "$dir/db_ssl/client-key.pem"  ]] && cp "$dir/db_ssl/client-key.pem"  "$STAGE_DIR/db-key.pem"
    fi
    if [[ "$db_admin_pw_given" != "y" ]]; then
        if ! interactive; then
            warn "Database user '$db_user' on $db_host was not removed - add --db-admin-user and --db-admin-password to remove it."
            return 0
        fi
        read -r -p "$(echo -e "${YELLOW} Remove the database user '$db_user' from $db_host? (the database itself is kept) (Y/n): ${NC}")" answer || answer="n"
        if [[ ! "${answer:-y}" =~ ^([yY]|[yY][eE][sS])$ ]]; then
            warn "Database user '$db_user' on $db_host was kept."
            return 0
        fi
        if [[ -z "$db_admin_user" ]]; then
            read -r -p "$(echo -e "${YELLOW} Admin user of $db_host [root]: ${NC}")" db_admin_user || db_admin_user=""
        fi
        ask_secret db_admin_password "Password of '${db_admin_user:-root}'"
    fi
    db_admin_user=${db_admin_user:-root}
    command -v docker >/dev/null 2>&1 || { warn "Docker is not available - the database user was not removed."; return 0; }
    if err=$(remote_mysql "$db_admin_user" "$db_admin_password" -e "DROP USER IF EXISTS '$db_user'@'%';" 2>&1); then
        step_done "Removed database user $db_user from $db_host"
    else
        warn "Could not remove database user '$db_user' from $db_host: $(grep -v 'Using a password' <<<"$err" | tail -1)"
        warn "Remove it on the database server with: DROP USER '$db_user'@'%';"
    fi
}

# ----------------------------------------------------------------------------
# Existing installations (backup / uninstall)
# ----------------------------------------------------------------------------
env_get() { grep -m1 "^$2=" "$1/.env" 2>/dev/null | cut -d= -f2-; }

# Created by this installer (the old in-place layout is never deleted by it).
is_faveo_install() {
    [[ -f "$1/docker-compose.yml" && -f "$1/.env" ]] && grep -q '^INSTALLED_BY=faveo-run.sh' "$1/.env" 2>/dev/null
}

find_installs() {
    {
        local d
        for d in "$DEFAULT_PARENT"/*/; do [[ -d "$d" ]] && echo "${d%/}"; done
        if command -v docker >/dev/null 2>&1; then
            docker ps -a --filter "label=com.docker.compose.service=faveo-apache" \
                --format '{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null
        fi
    } | while read -r d; do
        [[ -n "$d" ]] && is_faveo_install "$d" && norm_path "$d"
    done | sort -u
}

install_info() {
    local dir=$1 dom total running
    dom=$(env_get "$dir" DOMAINNAME)
    total=$(docker ps -a --filter "name=^${dom}-" --format '{{.Names}}' 2>/dev/null | wc -l)
    running=$(docker ps --filter "name=^${dom}-" --format '{{.Names}}' 2>/dev/null | wc -l)
    echo "domain ${dom:-?}, containers $((total)) ($((running)) running)"
}

# choose_existing_install <verb> -> SELECTED_DIR
choose_existing_install() {
    local verb=$1 dir="" input tries=0 i installs=() d
    if [[ -n "$install_dir" ]]; then
        dir=$(norm_path "$install_dir")
    elif [[ -n "$domainname" ]]; then
        while read -r d; do
            [[ -n "$d" && "$(env_get "$d" DOMAINNAME)" == "$domainname" ]] && { dir=$d; break; }
        done < <(find_installs)
        [[ -n "$dir" ]] || dir="$DEFAULT_PARENT/$domainname"
    elif interactive; then
        mapfile -t installs < <(find_installs)
        if [[ ${#installs[@]} -eq 0 ]]; then
            echo -e "${YELLOW} No installation was found under $DEFAULT_PARENT or in Docker.${NC}"
        else
            echo -e "${CYAN} Faveo installations on this server:${NC}"
            for i in "${!installs[@]}"; do
                printf "${GREEN}  (%d) %s${NC}\n      %s\n" $((i + 1)) "${installs[$i]}" "$(install_info "${installs[$i]}")"
            done
        fi
        while true; do
            if [[ ${#installs[@]} -gt 0 ]]; then
                read -r -p "$(echo -e "${YELLOW} Which installation do you want to $verb? Number or path [1]: ${NC}")" input || die "No input."
                input=${input:-1}
            else
                read -r -p "$(echo -e "${YELLOW} Installation path to $verb: ${NC}")" input || die "No input."
            fi
            if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#installs[@]} )); then
                dir=${installs[$((input - 1))]}
            else
                dir=$(norm_path "$input")
            fi
            is_faveo_install "$dir" && break
            echo -e "${RED} '$dir' is not an installation created by this script.${NC}"
            tries=$((tries + 1)); [[ $tries -ge $max_retries ]] && die "Too many invalid attempts. Nothing was changed."
        done
    else
        die "With -y (or without a terminal), give the installation with -i <path> or -d <domain>."
    fi
    [[ -d "$dir" ]] || die "'$dir' does not exist. Nothing was changed."
    is_faveo_install "$dir" || die "'$dir' is not an installation created by this script (no INSTALLED_BY in .env). Nothing was changed."
    SELECTED_DIR=$dir
}

# ----------------------------------------------------------------------------
# Backup
# ----------------------------------------------------------------------------
backup_database() {
    local dir=$1 out=$2 dom loc started="" i
    dom=$(env_get "$dir" DOMAINNAME)
    loc=$(env_get "$dir" DB_LOCATION)
    detect_compose
    if [[ "$loc" == "remote" ]]; then
        local host port name user pass ssl verify args=() vol=()
        host=$(env_get "$dir" DB_HOST_FROM_SERVER); port=$(env_get "$dir" DB_PORT)
        name=$(env_get "$dir" DB_DATABASE); user=$(env_get "$dir" DB_USERNAME)
        pass=$(env_get "$dir" DB_PASSWORD)
        ssl=$(env_get "$dir" DB_SSL); verify=$(env_get "$dir" DB_SSL_VERIFY)
        [[ "$host" == "localhost" || "$host" == "::1" ]] && host="127.0.0.1"
        args=(-h "$host" -P "${port:-3306}" -u "$user")
        if [[ "$ssl" == "yes" ]]; then
            vol=(-v "$dir/db_ssl:/dbssl:ro$(selinux_enforcing && echo ,z)")
            args+=(--ssl-ca=/dbssl/ca.pem)
            [[ -f "$dir/db_ssl/client-cert.pem" ]] && args+=(--ssl-cert=/dbssl/client-cert.pem --ssl-key=/dbssl/client-key.pem)
            [[ "$verify" == "no" ]] && args+=(--ssl-mode=VERIFY_CA) || args+=(--ssl-mode=VERIFY_IDENTITY)
        fi
        info "Dumping remote database '$name' from $host..."
        MYSQL_PWD="$pass" docker run --rm --network host -e MYSQL_PWD "${vol[@]}" "$MYSQL_IMAGE" \
            mysqldump "${args[@]}" --single-transaction --quick --no-tablespaces --triggers \
            --databases "$name" 2>"$out.err" | gzip > "$out"
    else
        local name rootpw ctr="${dom}-mysql"
        name=$(env_get "$dir" MYSQL_DATABASE); rootpw=$(env_get "$dir" MYSQL_ROOT_PASSWORD)
        if [[ "$(docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null)" != "true" ]]; then
            info "Starting the MySQL container for the dump..."
            (cd "$dir" && $DOCKER_COMPOSE up -d faveo-mysql >/dev/null 2>&1) || { warn "Could not start $ctr."; return 1; }
            started="y"
        fi
        for i in $(seq 1 60); do
            MYSQL_PWD="$rootpw" docker exec -e MYSQL_PWD "$ctr" mysqladmin -uroot -h127.0.0.1 ping >/dev/null 2>&1 && break
            sleep 2
        done
        info "Dumping database '$name' from container $ctr..."
        MYSQL_PWD="$rootpw" docker exec -e MYSQL_PWD "$ctr" mysqldump -uroot -h127.0.0.1 --single-transaction --quick \
            --routines --triggers --events --databases "$name" 2>"$out.err" | gzip > "$out"
        [[ -n "$started" ]] && (cd "$dir" && $DOCKER_COMPOSE stop faveo-mysql >/dev/null 2>&1)
    fi
    if gzip -dc "$out" 2>/dev/null | tail -n 1 | grep -q "Dump completed"; then
        rm -f "$out.err"; return 0
    fi
    warn "Database dump failed: $(grep -v 'Using a password' "$out.err" 2>/dev/null | tail -1)"
    rm -f "$out.err"
    return 1
}

human_size() { du -sh "$1" 2>/dev/null | cut -f1; }

# backup_install <dir> -> LAST_BACKUP. A failed backup removes its own folder.
backup_install() {
    local dir=$1 dom ts base dest need=0 avail kb item cfg=() _
    dom=$(env_get "$dir" DOMAINNAME)
    ts=$(date +%Y-%m-%d_%H%M%S)
    base=$(norm_path "${backup_dir:-$(dirname "$dir")/Backup}")
    case "$base/" in "$dir"/*) die "The backup folder must be outside the installation folder ($dir)." ;; esac
    dest="$base/$dom/$ts"
    mkdir -p "$base" || die "Cannot create the backup folder $base."
    while read -r kb _; do need=$((need + kb)); done < <(du -sk "$dir/$host_root_dir" "$dir/storage" "$dir/mysql" 2>/dev/null)
    read -r _ _ _ avail _ < <(df -Pk "$base" 2>/dev/null | tail -1)
    if [[ "$avail" =~ ^[0-9]+$ ]] && (( need > avail )); then
        die "Not enough free space in $base (need about $((need / 1024)) MB, free $((avail / 1024)) MB). Use --backup-dir."
    fi
    mkdir -p "$dest" && chmod 700 "$base/$dom" "$dest"
    echo ""
    echo -e "${CYAN} Backing up the Faveo installation for $dom...${NC}"
    echo "   Destination: $dest"
    backup_database "$dir" "$dest/database.sql.gz" \
        || { rm -rf "$dest"; die "Backup failed: the database could not be dumped. Nothing was changed."; }
    step_done "Database       database.sql.gz      ($(human_size "$dest/database.sql.gz"))"
    tar -czf "$dest/faveo-files.tar.gz" -C "$dir" "$host_root_dir" storage 2>/dev/null \
        || { rm -rf "$dest"; die "Backup failed while archiving the Faveo files. Nothing was changed."; }
    step_done "Faveo files    faveo-files.tar.gz   ($(human_size "$dest/faveo-files.tar.gz"))"
    for item in .env docker-compose.yml credentials.txt FAVEO-DOCKER-COMMANDS.txt faveo-run.sh apache supervisor Dockerfile ssl_copy certbot db_ssl meilisearch/config; do
        [[ -e "$dir/$item" ]] && cfg+=("$item")
    done
    tar -czf "$dest/config.tar.gz" -C "$dir" "${cfg[@]}" 2>/dev/null \
        || { rm -rf "$dest"; die "Backup failed while archiving the configuration. Nothing was changed."; }
    step_done "Configuration  config.tar.gz        ($(human_size "$dest/config.tar.gz"))"
    (cd "$dest" && sha256sum database.sql.gz faveo-files.tar.gz config.tar.gz > SHA256SUMS)
    cat > "$dest/README.txt" <<EOF
Faveo Helpdesk Docker backup
----------------------------
Domain        : $dom
Installation  : $dir
Taken         : $(date '+%Y-%m-%d %H:%M:%S %Z')
Database      : $(env_get "$dir" DB_LOCATION) ($(env_get "$dir" DB_DATABASE))

Files
  database.sql.gz      mysqldump of the Faveo database (includes CREATE DATABASE)
  faveo-files.tar.gz   faveo/ (application) and storage/
  config.tar.gz        .env, docker-compose.yml, credentials.txt, apache/, supervisor/,
                       Dockerfile/, certificates (ssl_copy/ or certbot/), db_ssl/
  SHA256SUMS           checksums - check with: sha256sum -c SHA256SUMS

Restore (same or a new server with Docker)
  1. mkdir -p $dir && cd $dir
  2. tar xzf <backup>/config.tar.gz && tar xzf <backup>/faveo-files.tar.gz
  3. Local database:
       mkdir -p mysql && docker compose up -d faveo-mysql      (wait about 30 seconds)
       gzip -dc <backup>/database.sql.gz | docker exec -i -e MYSQL_PWD=\$(grep ^MYSQL_ROOT_PASSWORD= .env | cut -d= -f2-) \$(grep ^DOMAINNAME= .env | cut -d= -f2-)-mysql mysql -uroot -h127.0.0.1
     Remote database:
       gzip -dc <backup>/database.sql.gz | mysql -h <host> -u <admin user> -p
  4. docker compose up -d --build
EOF
    chmod 600 "$dest"/*
    LAST_BACKUP=$dest
    echo ""
    echo -e "${GREEN} ✔ Backup completed: $dest  ($(human_size "$dest") in total)${NC}"
    echo "   Copy this folder to another server or storage to keep it safe."
}

run_backup() {
    command -v docker >/dev/null 2>&1 || die "Docker is not installed."
    choose_existing_install "back up"
    backup_install "$SELECTED_DIR"
    exit 0
}

# ----------------------------------------------------------------------------
# Rollback / uninstall
# ----------------------------------------------------------------------------
remove_image_if_unused() {
    local img=$1
    docker image inspect "$img" >/dev/null 2>&1 || return 0
    if [[ -n "$(docker ps -aq --filter "ancestor=$img" 2>/dev/null)" ]]; then
        warn "Image $img is used by another installation; keeping it."
        return 0
    fi
    docker rmi "$img" >/dev/null 2>&1 && step_done "Removed image $img"
}

remove_cron_entry() {
    local dir=$1
    command -v crontab >/dev/null 2>&1 || return 0
    crontab -l 2>/dev/null | grep -qF "# faveo-docker:$dir" || return 0
    crontab -l 2>/dev/null | grep -vF "# faveo-docker:$dir" | crontab - \
        && step_done "Removed the Let's Encrypt renewal cron entry"
}

# safe_to_delete <dir> : never remove system folders.
safe_to_delete() {
    case "$1" in
        ""|/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/var/lib|/mnt|/media|"$DEFAULT_PARENT")
            return 1 ;;
    esac
    [[ "$1" =~ ^/home/[^/]+$ ]] && return 1
    return 0
}

# remove_install <dir> <domain> <images...>
remove_install() {
    local dir=$1 dom=$2 img ids n=0; shift 2
    detect_compose
    docker rm -f "${dom}-apache-cert" "${dom}-selfsign" >/dev/null 2>&1 || true
    if [[ -n "$dom" ]]; then
        n=$(docker ps -aq --filter "name=^${dom}-(apache|mysql|redis|supervisor|meilisearch)$" 2>/dev/null | wc -l)
    fi
    if [[ -f "$dir/docker-compose.yml" ]]; then
        (cd "$dir" && $DOCKER_COMPOSE down --remove-orphans --timeout 20 >/dev/null 2>&1)
    fi
    if [[ -n "$dom" ]]; then
        ids=$(docker ps -aq --filter "name=^${dom}-(apache|mysql|redis|supervisor|meilisearch)$" 2>/dev/null)
        [[ -n "$ids" ]] && docker rm -f $ids >/dev/null 2>&1
        (( n > 0 )) && step_done "Stopped and removed $n container(s)"
        docker network rm "${dom}-faveo" >/dev/null 2>&1 && step_done "Removed Docker network ${dom}-faveo"
    fi
    for img in "$@"; do remove_image_if_unused "$img"; done
    remove_cron_entry "$dir"
    if [[ -d "$dir" ]]; then
        if safe_to_delete "$dir"; then
            rm -rf "$dir" && step_done "Deleted the installation folder $dir"
        else
            warn "Refusing to delete '$dir'."
        fi
    fi
}

on_failure() {
    install_started="n"           # no recursion if something below fails
    trap - INT TERM
    local answer="y"
    echo ""
    if [[ "$keep_on_failure" == "y" ]]; then
        answer="n"
    elif interactive; then
        echo -e "${YELLOW} The installation did not complete. A rollback removes what this run created:${NC}"
        [[ -n "$RB_DIR" ]]   && echo "   - the installation folder $RB_DIR"
        [[ -n "$RB_MOVED" ]] && echo "   - and puts the previous content back from $RB_MOVED"
        [[ -n "$RB_STACK" ]] && echo "   - containers and the Docker network ${domainname}-faveo"
        [[ ${#RB_IMAGES[@]} -gt 0 ]] && echo "   - images built by this run: ${RB_IMAGES[*]}"
        [[ -n "$RB_CRON" ]]  && echo "   - the certificate renewal cron entry"
        [[ "$RB_REMOTE_DB_CREATED" == "y" ]]   && echo "   - database $db_name on $db_host"
        [[ "$RB_REMOTE_USER_CREATED" == "y" || "$RB_REMOTE_USER_REUSED" == "y" ]] && echo "   - database user $db_user on $db_host"
        read -r -p "$(echo -e "${YELLOW} Roll back now? (Y/n): ${NC}")" answer || answer="y"
        answer=${answer:-y}
    fi
    if [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]; then
        echo ""
        echo -e "${YELLOW} Rolling back the incomplete installation...${NC}"
        remote_db_rollback
        [[ -n "$RB_DIR" ]] && remove_install "$RB_DIR" "$domainname" "${RB_IMAGES[@]}"
        if [[ -n "$RB_MOVED" && -d "$RB_MOVED" ]]; then
            mv "$RB_MOVED" "$RB_DIR" && step_done "Restored the previous content of $RB_DIR"
            if [[ -f "$RB_DIR/docker-compose.yml" ]]; then
                (cd "$RB_DIR" && $DOCKER_COMPOSE up -d >/dev/null 2>&1) \
                    && step_done "Started the previous installation again" \
                    || warn "Start the previous installation with: cd $RB_DIR && $DOCKER_COMPOSE up -d"
            fi
        fi
        echo -e "${GREEN} ✔ Rollback completed.${NC} Fix the problem above and run the script again."
    else
        warn "Files were kept in ${RB_DIR:-the installation path}."
        if [[ -n "$RB_DIR" && -f "$RB_DIR/docker-compose.yml" ]]; then
            echo "   Resume after fixing the problem:  cd $RB_DIR && ${DOCKER_COMPOSE:-docker compose} up -d --build"
        fi
        echo "   Remove everything later:          sudo ./$SCRIPT_NAME --uninstall -i ${RB_DIR:-<path>}"
        [[ -n "$RB_MOVED" ]] && echo "   The previous content of the folder is in $RB_MOVED"
    fi
}

run_uninstall() {
    local dir dom answer tries=0 names dbloc rhost rname want_backup php node
    command -v docker >/dev/null 2>&1 || die "Docker is not installed."
    choose_existing_install "remove"
    dir=$SELECTED_DIR
    dom=$(env_get "$dir" DOMAINNAME)
    dbloc=$(env_get "$dir" DB_LOCATION); rhost=$(env_get "$dir" DB_HOST_FROM_SERVER); rname=$(env_get "$dir" DB_DATABASE)
    php=$(env_get "$dir" PHP_VERSION); node=$(env_get "$dir" NODE_VERSION)
    names=$(docker ps -a --filter "name=^${dom}-" --format '{{.Names}}' 2>/dev/null | sort | tr '\n' ' ')

    echo ""
    echo -e "${YELLOW} This will permanently delete:${NC}"
    echo "   Installation folder : $dir"
    echo "   Domain              : $dom"
    echo "   Containers          : ${names:-none}"
    echo "   Docker network      : ${dom}-faveo"
    echo "   Data in the folder  : application, $([[ "$dbloc" == "local" ]] && echo "database (mysql/), ")certificates, logs, credentials.txt"
    echo "   Docker images       : faveo-apache / faveo-supervisor (php$php-node$node), if no other installation uses them"
    echo "   Cron                : the Let's Encrypt renewal entry (if any)"
    [[ "$dbloc" == "remote" ]] && echo "   Database user       : $(env_get "$dir" DB_USERNAME) on $rhost (admin password needed; the database $rname itself is KEPT)"
    echo ""
    if [[ "$assume_yes" != "y" ]]; then
        while true; do
            read -r -p "$(echo -e "${YELLOW} Remove this Faveo installation? (yes/no) [no]: ${NC}")" answer || answer="no"
            case "${answer,,}" in
                y|yes) break ;;
                ""|n|no) echo -e "${GREEN} Cancelled. Nothing was removed.${NC}"; exit 0 ;;
                *) tries=$((tries + 1)); echo -e "${RED} Please type yes or no.${NC}"
                   [[ $tries -ge $max_retries ]] && die "No valid answer; nothing was removed." ;;
            esac
        done
    fi
    want_backup=$do_backup
    if [[ "$want_backup" != "y" ]] && interactive; then
        read -r -p "$(echo -e "${YELLOW} Take a backup before removing? (Y/n): ${NC}")" answer || answer="y"
        [[ "${answer:-y}" =~ ^([yY]|[yY][eE][sS])$ ]] && want_backup="y"
    fi
    if [[ "$want_backup" == "y" ]]; then
        backup_install "$dir"       # stops (and removes nothing) if the backup fails
    else
        warn "No backup taken."
    fi
    echo ""
    echo -e "${CYAN} Removing the Faveo installation for $dom...${NC}"
    [[ "$dbloc" == "remote" ]] && uninstall_remote_db_user "$dir"
    remove_install "$dir" "$dom" "faveo-apache:php$php-node$node" "faveo-supervisor:php$php-node$node"
    echo ""
    echo -e "${GREEN} ✔ The Faveo installation for $dom has been removed.${NC}"
    [[ -n "${LAST_BACKUP:-}" ]] && echo -e "   Backup: ${GREEN}$LAST_BACKUP${NC}"
    [[ "$dbloc" == "remote" ]] && warn "The remote database '$rname' on $rhost was kept (it holds the helpdesk data); drop it there if it is no longer needed."
    echo "   Base images (ubuntu, mysql, redis, meilisearch) were kept. Free that space with: docker image prune -a"
    exit 0
}

# ----------------------------------------------------------------------------
# Interactive questions
# ----------------------------------------------------------------------------
banner() {
    local skyblue reset
    skyblue=$(tput setaf 14 2>/dev/null)
    reset=$(tput sgr0 2>/dev/null)
    echo -e "$skyblue"
    echo "                                                                                                                    "
    sleep 0.08

    echo "             ███████╗ █████╗ ██╗   ██╗███████╗ ██████╗                                                             "
    sleep 0.08

    echo "             ██╔════╝██╔══██╗██║   ██║██╔════╝██╔═══██╗                                                            "
    sleep 0.08

    echo "             █████╗  ███████║██║   ██║█████╗  ██║   ██║                                                            "
    sleep 0.08

    echo "             ██╔══╝  ██╔══██║╚██╗ ██╔╝██╔══╝  ██║   ██║                                                            "
    sleep 0.08

    echo "             ██║     ██║  ██║ ╚████╔╝ ███████╗╚██████╔╝                                                            "
    sleep 0.08

    echo "             ╚═╝     ╚═╝  ╚═╝  ╚═══╝  ╚══════╝ ╚═════╝                                                             "
    sleep 0.08

    echo "                                                                                                                    "
    sleep 0.08

    echo "             ██╗  ██╗███████╗██╗     ██████╗ ██████╗ ███████╗███████╗██╗  ██╗                                    "
    sleep 0.08

    echo "             ██║  ██║██╔════╝██║     ██╔══██╗██╔══██╗██╔════╝██╔════╝██║ ██╔╝                                    "
    sleep 0.08

    echo "             ███████║█████╗  ██║     ██████╔╝██║  ██║█████╗  ███████╗█████╔╝                                     "
    sleep 0.08

    echo "             ██╔══██║██╔══╝  ██║     ██╔═══╝ ██║  ██║██╔══╝  ╚════██║██╔═██╗                                     "
    sleep 0.08

    echo "             ██║  ██║███████╗███████╗██║     ██████╔╝███████╗███████║██║  ██╗                                    "
    sleep 0.08

    echo "             ╚═╝  ╚═╝╚══════╝╚══════╝╚═╝     ╚═════╝ ╚══════╝╚══════╝╚═╝  ╚═╝                                    "
    sleep 0.08

    echo "                                                                                                                    "
    sleep 0.08

    echo -e "$reset"

    sleep 0.5
}

ask_value() {   # ask_value <var> <prompt> <validator> <error>
    local __var=$1 prompt=$2 validator=$3 errmsg=$4 tries=0 input
    while true; do
        read -r -p "$(echo -e "${YELLOW} $prompt: ${NC}")" input || die "No input."
        input=${input## }; input=${input%% }
        if "$validator" "$input"; then printf -v "$__var" '%s' "$input"; return 0; fi
        tries=$((tries + 1)); echo -e "${RED} $errmsg ($tries/$max_retries)${NC}"
        [[ $tries -ge $max_retries ]] && die "Too many failed attempts."
    done
}

ask_choice() {  # ask_choice <prompt> <option>... -> CHOICE ; ASK_DEFAULT = Enter value
    local prompt=$1 tries=0 i choice n opt; shift; n=$#
    while true; do
        echo -e "${CYAN} $prompt${NC}"
        i=1; for opt in "$@"; do echo -e "${GREEN}   ($i) $opt${NC}"; i=$((i + 1)); done
        if [[ -n "${ASK_DEFAULT:-}" ]]; then
            read -r -p "$(echo -e "${YELLOW} Select 1-$n [$ASK_DEFAULT]: ${NC}")" choice || die "No input."
            choice=${choice:-$ASK_DEFAULT}
        else
            read -r -p "$(echo -e "${YELLOW} Select 1-$n: ${NC}")" choice || die "No input."
        fi
        [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )) && { CHOICE=$choice; return 0; }
        tries=$((tries + 1)); echo -e "${RED} Invalid option. ($tries/$max_retries)${NC}"
        [[ $tries -ge $max_retries ]] && die "Too many invalid attempts."
    done
}

ask_yes_no() {  # ask_yes_no <var> <prompt> <default y|n> -> yes|no
    local __var=$1 prompt=$2 def=$3 a tries=0
    while true; do
        read -r -p "$(echo -e "${YELLOW} $prompt ($([[ $def == y ]] && echo "Y/n" || echo "y/N")): ${NC}")" a || a=""
        case "${a,,}" in
            "")    printf -v "$__var" '%s' "$([[ $def == y ]] && echo yes || echo no)"; return 0 ;;
            y|yes) printf -v "$__var" '%s' yes; return 0 ;;
            n|no)  printf -v "$__var" '%s' no;  return 0 ;;
        esac
        tries=$((tries + 1)); echo -e "${RED} Please answer y or n.${NC}"
        [[ $tries -ge $max_retries ]] && die "Too many failed attempts."
    done
}

ask_secret() {  # ask_secret <var> <prompt>
    local __var=$1 prompt=$2 input
    read -r -s -p "$(echo -e "${YELLOW} $prompt: ${NC}")" input || input=""
    echo ""
    printf -v "$__var" '%s' "$input"
}

ask_db_password() {
    local tries=0 p1 p2
    while true; do
        ask_secret p1 "Password for '$db_user' [Enter = generate one]"
        [[ -z "$p1" ]] && { db_password=""; return 0; }
        if ! valid_db_pass "$p1"; then
            echo -e "${RED} Not allowed. Use $DB_PASS_RULE.${NC}"
        else
            ask_secret p2 "Repeat the password"
            [[ "$p1" == "$p2" ]] && { db_password=$p1; return 0; }
            echo -e "${RED} The passwords do not match.${NC}"
        fi
        tries=$((tries + 1)); [[ $tries -ge $max_retries ]] && die "Too many failed attempts."
    done
}

ask_db_customize() {
    local where=$1 answer v
    [[ "$db_custom_from_cli" == "y" ]] && return 0
    echo -e "${CYAN} Faveo database $where: name ${GREEN}$db_name${CYAN}, user ${GREEN}$db_user${CYAN}, password ${GREEN}generated${NC}"
    read -r -p "$(echo -e "${YELLOW} Customize the database name, user or password? (y/N): ${NC}")" answer || answer=""
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || return 0
    read -r -p "$(echo -e "${YELLOW} Database name [$db_name]: ${NC}")" v || v=""; v=${v:-$db_name}
    valid_db_ident "$v" || die "Invalid database name '$v' (letters, digits, underscore, max 32)."; db_name=$v
    read -r -p "$(echo -e "${YELLOW} Database user [$db_user]: ${NC}")" v || v=""; v=${v:-$db_user}
    valid_db_ident "$v" || die "Invalid database user '$v' (letters, digits, underscore, max 32)."; db_user=$v
    ask_db_password
}

ask_database() {
    if [[ -z "$db_location" ]]; then
        ASK_DEFAULT=1 ask_choice "Where should the Faveo database be?" \
            "Local MySQL 8.4 container on this server (recommended)" "Existing MySQL / MariaDB server"
        [[ $CHOICE -eq 2 ]] && db_location="remote" || db_location="local"
    fi
    if [[ "$db_location" == "local" ]]; then
        ask_db_customize "(local container)"
        return 0
    fi
    local v
    [[ -z "$db_host" ]] && ask_value db_host "Database server hostname or IPv4 address" valid_db_host "Invalid hostname or IP address."
    if [[ -z "$db_port" ]]; then
        read -r -p "$(echo -e "${YELLOW} Database server port [3306]: ${NC}")" v || v=""; v=${v:-3306}
        valid_port "$v" || die "Invalid port '$v'."; db_port=$v
    fi
    if [[ -z "$db_admin_user" ]]; then
        read -r -p "$(echo -e "${YELLOW} Admin user that can create databases and users [root]: ${NC}")" db_admin_user || db_admin_user=""
        db_admin_user=${db_admin_user:-root}
    fi
    if [[ "$db_admin_pw_given" != "y" ]]; then
        ask_secret db_admin_password "Password of '$db_admin_user'"
        db_admin_pw_given="y"
    fi
    [[ -z "$db_ssl" ]] && ask_yes_no db_ssl "Use an encrypted (SSL/TLS) connection to the database server?" n
    if [[ "$db_ssl" == "yes" ]]; then
        [[ -f "$STAGE_DIR/db-ca.pem" ]] || collect_cert_material "Database CA certificate (required)" "$STAGE_DIR/db-ca.pem" cert
        if [[ ! -f "$STAGE_DIR/db-cert.pem" && -z "$db_ssl_cert" ]]; then
            echo -e "${YELLOW} The client certificate and key are optional - press Enter to skip.${NC}"
            if collect_cert_material "Database client certificate (optional)" "$STAGE_DIR/db-cert.pem" cert y; then
                [[ -f "$STAGE_DIR/db-key.pem" ]] || collect_cert_material "Database client key" "$STAGE_DIR/db-key.pem" key
            fi
        fi
        [[ -z "$db_ssl_verify" ]] && ask_yes_no db_ssl_verify "Verify the server certificate (hostname)?" y
    fi
    ask_db_customize "to create on $db_host"
}

collect_attributes() {
    interactive || return 0
    if [[ -z "$domainname" || -z "$email" || -z "$license" || -z "$orderno" || -z "$ssl_option" ]]; then
        echo -e "${CYAN} Enter the details for the Faveo Helpdesk installation.${NC}"
    fi
    [[ -z "$domainname" ]] && ask_value domainname "Domain name [without https://]" valid_domain "Invalid domain name."
    [[ -z "$email" ]]      && ask_value email "Email address" valid_email "Invalid email address."
    [[ -z "$license" ]]    && ask_value license "License code [from billing.faveohelpdesk.com]" valid_code "Invalid license code (letters, digits and '-')."
    if [[ -z "$orderno" ]]; then
        ask_value orderno "Order number [from billing.faveohelpdesk.com]" valid_order "Invalid order number."
        orderno=${orderno#\#}
    fi
    if [[ -z "$release" ]]; then
        ASK_DEFAULT=1 ask_choice "Which release do you want to install?" \
            "Official (stable, recommended)" "RC (release candidate)" "Beta (testing)"
        case $CHOICE in 1) release="official" ;; 2) release="rc" ;; 3) release="beta" ;; esac
    fi
    if [[ -z "$faveo_env" && "$skip_faveo_setup" != "y" ]]; then
        ASK_DEFAULT=1 ask_choice "Select the Faveo application environment:" "Production (default)" "Development" "Testing"
        case $CHOICE in 1) faveo_env="production" ;; 2) faveo_env="development" ;; 3) faveo_env="testing" ;; esac
    fi
    if [[ -z "$ssl_option" ]]; then
        ask_choice "Which SSL certificate do you want to use?" \
            "Let's Encrypt - free (certbot; ports 80/443 must be reachable)" "Self-signed" "Paid SSL (your certificate files)"
        case $CHOICE in 1) ssl_option="A" ;; 2) ssl_option="B" ;; 3) ssl_option="C" ;; esac
    fi
    if [[ "$ssl_option" == "C" ]]; then
        [[ -f "$STAGE_DIR/faveolocal.crt"  ]] || collect_cert_material "certificate.crt" "$STAGE_DIR/faveolocal.crt"  cert
        [[ -f "$STAGE_DIR/private.key"     ]] || collect_cert_material "private.key"     "$STAGE_DIR/private.key"     key
        [[ -f "$STAGE_DIR/faveorootCA.crt" ]] || collect_cert_material "ca_bundle.crt"   "$STAGE_DIR/faveorootCA.crt" cert
    fi
    if [[ -z "$websocket_enable" ]]; then
        ASK_DEFAULT=1 ask_choice "Enable WebSocket services?" "No" "Yes"
        [[ $CHOICE -eq 2 ]] && websocket_enable="yes" || websocket_enable="no"
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
        case "$db_host" in
            localhost|127.0.0.1|::1) db_container_host="host.docker.internal" ;;
            *)                       db_container_host=$db_host ;;
        esac
    fi
    db_password_auto="n"
    [[ -z "$db_password" ]] && { db_password=$(gen_password 20); db_password_auto="y"; }
    [[ -z "$db_root_password" ]] && db_root_password=$(gen_password 20)
    release=${release:-official}
    faveo_env=${faveo_env:-production}
    websocket_enable=${websocket_enable:-no}
    [[ "$ssl_option" == "C" ]] && check_paid_ssl_bundle
    apply_port_rules
}

# ----------------------------------------------------------------------------
# Installation path
# ----------------------------------------------------------------------------
resolve_install_dir() {
    local p
    p=$(norm_path "$1")
    if ! safe_to_delete "$p"; then
        echo "Refusing to use '$p' as the installation path; choose a sub-folder such as $DEFAULT_PARENT/$domainname." >&2
        return 1
    fi
    if [[ "$p" == /mnt/[a-z]/* ]] && grep -qi microsoft /proc/version 2>/dev/null; then
        echo "'$p' is on a Windows drive (WSL). Use a Linux path such as $DEFAULT_PARENT/$domainname." >&2
        return 1
    fi
    echo "$p"
}

choose_install_dir() {
    local answer resolved def="$DEFAULT_PARENT/$domainname"
    if [[ -n "$install_dir" ]]; then
        resolved=$(resolve_install_dir "$install_dir") || exit 1
    elif ! interactive; then
        resolved=$(resolve_install_dir "$def") || exit 1
    else
        while true; do
            read -r -p "$(echo -e "${YELLOW} Installation path [$def]: ${NC}")" answer || answer=""
            resolved=$(resolve_install_dir "${answer:-$def}") || continue
            break
        done
    fi
    if [[ -e "$resolved" && ! -d "$resolved" ]]; then
        die "'$resolved' exists and is not a folder."
    fi
    if [[ -d "$resolved" && -n "$(ls -A "$resolved" 2>/dev/null)" && "$force" != "y" ]]; then
        if interactive; then
            warn "'$resolved' is not empty."
            read -r -p "$(echo -e "${YELLOW} Move its content aside (to $resolved.old-<date>) and install there? (y/N): ${NC}")" answer || answer=""
            [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || die "Choose another path with -i, or use --force."
            force="y"
        else
            die "'$resolved' is not empty. Use --force (the old content is moved aside) or choose another path."
        fi
    fi
    install_dir=$resolved
    CUR_DIR=$install_dir
    COMPOSE_PROJECT="faveo-$(echo "${domainname,,}" | tr -c 'a-z0-9\n' '-')"
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
confirm() {
    local row="${YELLOW}  %-18s${GREEN}%s${NC}\n" reply
    echo ""
    echo -e "${CYAN}${BOLD}  ═══════════════  Faveo Helpdesk - Installation Summary  ═══════════════${NC}"
    printf "$row" "Domain"         "$domainname"
    printf "$row" "Email"          "$email"
    printf "$row" "License"        "$license"
    printf "$row" "Order number"   "$orderno"
    printf "$row" "Release"        "$release"
    printf "$row" "Faveo setup"    "$([[ "$skip_faveo_setup" == "y" ]] && echo "in the browser (--skip-faveo-setup)" || echo "automatic - environment $faveo_env, license verification")"
    printf "$row" "SSL"            "$(ssl_name "$ssl_option")"
    if [[ "$ssl_option" == "C" ]]; then
        printf "$row" "Certificate"  "$(openssl x509 -noout -subject -in "$STAGE_DIR/faveolocal.crt" 2>/dev/null | sed 's/^subject= *//')"
        printf "$row" "Valid until"  "$(openssl x509 -noout -enddate -in "$STAGE_DIR/faveolocal.crt" 2>/dev/null | sed 's/^notAfter=//')"
    fi
    printf "$row" "WebSocket"      "$websocket_enable"
    printf "$row" "PHP / Node.js"  "$php_version / $node_version   (timezone $timezone)"
    if [[ "$db_location" == "remote" ]]; then
        printf "$row" "Database"     "remote server $db_host:$db_port (admin $db_admin_user)"
        printf "$row" "Database SSL" "$([[ "$db_ssl" == "yes" ]] && echo "yes (verify identity: $db_ssl_verify)" || echo no)"
    else
        printf "$row" "Database"     "local MySQL 8.4 container"
    fi
    printf "$row" "DB name / user" "$db_name / $db_user   (password: $([[ "$db_password_auto" == "y" ]] && echo generated || echo yours))"
    printf "$row" "Ports"          "HTTP $http_port, HTTPS $https_port, Supervisor $supervisor_port"
    printf "$row" "Docker subnet"  "${subnet_prefix}.0.0/16"
    printf "$row" "Install path"   "$install_dir$([[ "$force" == "y" && -n "$(ls -A "$install_dir" 2>/dev/null)" ]] && echo "   (existing content moved aside)")"
    printf "$row" "Site URL"       "$site_url"
    [[ "$generate_only" == "y" ]] && printf "$row" "Mode" "generate files only"
    echo -e "${CYAN}${BOLD}  ═══════════════════════════════════════════════════════════════════════${NC}"
    if [[ "$assume_yes" != "y" ]]; then
        read -r -p "$(echo -e " Continue (${GREEN}y${NC}/${RED}n${NC})? ")" reply || reply=""
        [[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]] || { echo -e "${RED} Cancelled. Nothing was changed.${NC}"; exit 1; }
    fi
}

# ----------------------------------------------------------------------------
# Generate the installation folder from the templates in this folder
# ----------------------------------------------------------------------------
prepare_install_dir() {
    install_started="y"
    if [[ -d "$install_dir" && -n "$(ls -A "$install_dir" 2>/dev/null)" ]]; then
        if [[ "$generate_only" != "y" && -f "$install_dir/docker-compose.yml" ]]; then
            detect_compose
            (cd "$install_dir" && $DOCKER_COMPOSE down --timeout 20 >/dev/null 2>&1) || true
        fi
        RB_MOVED="$install_dir.old-$(date +%Y%m%d%H%M%S)"
        mv "$install_dir" "$RB_MOVED" || die "Could not move the existing content of $install_dir aside."
        warn "The previous content of $install_dir was moved to $RB_MOVED."
    fi
    RB_DIR="$install_dir"
    mkdir -p "$install_dir" || die "Cannot create '$install_dir'."
    cd "$install_dir" || die "Cannot enter '$install_dir'."
}

copy_templates() {
    local t=$SCRIPT_DIR f
    for f in Dockerfile/apache/Dockerfile Dockerfile/apache/start-services.sh \
             Dockerfile/supervisor/Dockerfile Dockerfile/supervisor/entrypoint.sh \
             apache/000-default.conf letsapache/000-default.conf \
             supervisor/faveo-horizon.conf supervisor/faveo-worker.conf supervisor/faveo-websocket.conf \
             dockerfile_selfsign_ssl; do
        [[ -f "$t/$f" ]] || die "Template '$f' is missing next to $SCRIPT_NAME. New installations must be started from the faveo-helpdesk-docker folder of the repository (the copy in an installation folder is for --backup, --uninstall and --help)."
    done
    mkdir -p Dockerfile/apache Dockerfile/supervisor apache supervisor
    cp "$t"/Dockerfile/apache/{Dockerfile,start-services.sh} Dockerfile/apache/
    cp "$t"/Dockerfile/supervisor/{Dockerfile,entrypoint.sh} Dockerfile/supervisor/
    cp "$t"/supervisor/faveo-{horizon,worker,websocket}.conf supervisor/
    # A copy of this installer for --backup / --uninstall / --help from the installation folder.
    local self="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
    if [[ ! "$self" -ef "$install_dir/faveo-run.sh" ]]; then
        cp "$self" faveo-run.sh && chmod 700 faveo-run.sh
    fi
    if [[ "$ssl_option" == "B" ]]; then
        mkdir -p Dockerfile/selfsign
        # Only openssl is needed to create the certificates.
        sed -e 's/apt-get install -y apache2 openssl/apt-get install -y openssl/' \
            -e '/^EXPOSE/d' -e '/^CMD/d' -e '/^# Expose/d' -e '/^# Start Apache/d' \
            "$t/dockerfile_selfsign_ssl" > Dockerfile/selfsign/Dockerfile
    fi
}

write_apache_conf() {
    local src="$SCRIPT_DIR/apache/000-default.conf" le="/etc/letsencrypt/live/$domainname"
    [[ "$ssl_option" == "A" ]] && src="$SCRIPT_DIR/letsapache/000-default.conf"
    sed -e "s|^ServerName .*|    ServerName $domainname|" \
        -e "s|domainrewrite|$domainname|g" \
        -e "s|/var/imported/ssl/cert.pem|$le/cert.pem|" \
        -e "s|/var/imported/ssl/privkey.pem|$le/privkey.pem|" \
        -e "s|/var/imported/ssl/fullchain.pem|$le/chain.pem|" \
        "$src" > apache/000-default.conf
    if [[ $https_port -ne 443 ]]; then
        sed -i "s|https://%{SERVER_NAME}%{REQUEST_URI}|https://%{SERVER_NAME}:$https_port%{REQUEST_URI}|" apache/000-default.conf
    fi
    # Custom ports: Apache inside the container listens on them as well, so the site's own URL
    # (https://<domain>:<port>, used by Faveo's installer and license check) works inside the container.
    local listen=""
    if [[ $http_port -ne 80 && $http_port -ne 443 ]]; then
        sed -i "s|^<VirtualHost \*:80>|<VirtualHost *:80 *:$http_port>|" apache/000-default.conf
        listen+="Listen $http_port"$'\n'
    fi
    if [[ $https_port -ne 443 && $https_port -ne 80 ]]; then
        sed -i "s|^<VirtualHost \*:443>|<VirtualHost *:443 *:$https_port>|" apache/000-default.conf
        listen+="<IfModule mod_ssl.c>"$'\n'"    Listen $https_port"$'\n'"</IfModule>"$'\n'
    fi
    if [[ -n "$listen" ]]; then
        { printf '# Host ports %s / %s, also served inside the container\n%s\n' "$http_port" "$https_port" "$listen"; cat apache/000-default.conf; } > apache/000-default.conf.new
        mv apache/000-default.conf.new apache/000-default.conf
    fi
    if [[ "$websocket_enable" == "yes" ]]; then
        sed -i -e 's|^[[:space:]]*#\([[:space:]]*SSLProxyEngine On\)|\1|' \
               -e 's|^[[:space:]]*#\([[:space:]]*ProxyPass /fc/ .*\)|\1|' \
               -e 's|^[[:space:]]*#\([[:space:]]*ProxyPassReverse /fc/ .*\)|\1|' \
               -e 's|^[[:space:]]*#\([[:space:]]*RewriteEngine On\)|\1|' \
               -e 's|^[[:space:]]*#\([[:space:]]*RewriteCond %{HTTP:Upgrade} websocket \[NC\]\)|\1|' \
               -e 's|^[[:space:]]*#\([[:space:]]*RewriteCond %{HTTP:Connection} upgrade \[NC\]\)|\1|' \
               -e 's|^[[:space:]]*#\([[:space:]]*RewriteRule \^/fc/.*\)|\1|' apache/000-default.conf
        sed -i 's|^#||' supervisor/faveo-websocket.conf
    fi
}

write_meilisearch_config() {
    MEILI_MASTER_KEY=$(gen_password 32)
    mkdir -p meilisearch/config meilisearch/data
    cat > meilisearch/config/config.toml <<EOF
env = "production"
master_key = "$MEILI_MASTER_KEY"
http_addr = "0.0.0.0:7700"
db_path = "/meili_data/data"
dump_dir = "/meili_data/dumps"
snapshot_dir = "/meili_data/snapshots"
log_level = "INFO"
EOF
    chmod 600 meilisearch/config/config.toml
}

write_compose() {
    {
        echo "# Generated by $SCRIPT_NAME $SCRIPT_VERSION on $(date '+%Y-%m-%d %H:%M'). Settings are in .env."
        cat <<'EOF'
services:
  faveo-apache:
    build:
      context: ./Dockerfile/apache
      args:
        PHP_VERSION: ${PHP_VERSION}
        NODE_VERSION: ${NODE_VERSION}
    image: faveo-apache:php${PHP_VERSION}-node${NODE_VERSION}
    container_name: ${DOMAINNAME}-apache
    environment:
      TZ: ${TIMEZONE}
    ports:
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    volumes:
      - ./faveo:/var/www/html
      - ./storage:/var/www/storage
      - ./apache/000-default.conf:/etc/apache2/sites-available/000-default.conf
      - ./logs/apache:/var/log/apache2
EOF
        if [[ "$ssl_option" == "A" ]]; then
            echo "      - ./certbot/letsencrypt/etc/letsencrypt:/etc/letsencrypt"
        else
            echo "      - ./ssl_copy/faveolocal.crt:/etc/ssl/certs/faveolocal.crt"
            echo "      - ./ssl_copy/private.key:/etc/ssl/private/private.key"
            echo "      - ./ssl_copy/faveorootCA.crt:/usr/local/share/ca-certificates/faveorootCA.crt"
        fi
        [[ "$db_location" == "remote" && "$db_ssl" == "yes" ]] && echo "      - ./db_ssl:/var/www/db-ssl"
        cat <<'EOF'
    command: /bin/bash -c "update-ca-certificates && chown -R www-data:www-data /var/www/html/ && echo '127.0.0.1 ${DOMAINNAME}' >> /etc/hosts && service php${PHP_VERSION}-fpm start && apachectl -D FOREGROUND"
EOF
        if [[ "$db_container_host" == "host.docker.internal" ]]; then
            printf '    extra_hosts:\n      - "host.docker.internal:host-gateway"\n'
        fi
        echo "    depends_on:"
        echo "      - faveo-redis"
        [[ "$db_location" == "local" ]] && echo "      - faveo-mysql"
        cat <<'EOF'
    networks:
      - faveo-network
    restart: unless-stopped

EOF
        if [[ "$db_location" == "local" ]]; then
            cat <<EOF
  faveo-mysql:
    image: $MYSQL_IMAGE
EOF
            cat <<'EOF'
    container_name: ${DOMAINNAME}-mysql
    environment:
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      TZ: ${TIMEZONE}
    volumes:
      - ./mysql:/var/lib/mysql
    networks:
      - faveo-network
    restart: unless-stopped

EOF
        fi
        cat <<'EOF'
  faveo-redis:
    image: @@REDIS_IMAGE@@
    container_name: ${DOMAINNAME}-redis
    volumes:
      - ./redis:/data
    networks:
      - faveo-network
    restart: unless-stopped

  faveo-supervisor:
    build:
      context: ./Dockerfile/supervisor
      args:
        PHP_VERSION: ${PHP_VERSION}
        NODE_VERSION: ${NODE_VERSION}
    image: faveo-supervisor:php${PHP_VERSION}-node${NODE_VERSION}
    container_name: ${DOMAINNAME}-supervisor
    environment:
      TZ: ${TIMEZONE}
    volumes:
      - ./faveo:/var/www/html
      - ./supervisor:/etc/supervisor/conf.d
      - ./logs/supervisor:/var/log/supervisor
EOF
        [[ "$db_location" == "remote" && "$db_ssl" == "yes" ]] && echo "      - ./db_ssl:/var/www/db-ssl"
        if [[ "$supervisor_port" != "none" ]]; then
            printf '    ports:\n      - "127.0.0.1:${SUPERVISOR_PORT}:9001"\n'
        fi
        if [[ "$db_container_host" == "host.docker.internal" ]]; then
            printf '    extra_hosts:\n      - "host.docker.internal:host-gateway"\n'
        fi
        echo "    depends_on:"
        echo "      - faveo-redis"
        [[ "$db_location" == "local" ]] && echo "      - faveo-mysql"
        cat <<EOF
    networks:
      - faveo-network
    restart: unless-stopped

  faveo-meilisearch:
    image: $MEILI_IMAGE
EOF
        cat <<'EOF'
    container_name: ${DOMAINNAME}-meilisearch
    environment:
      - MEILI_CONFIG_FILE_PATH=/config.toml
      - MEILI_MASTER_KEY=${MEILI_MASTER_KEY}
      - TZ=${TIMEZONE}
    volumes:
      - ./meilisearch/data:/meili_data
      - ./meilisearch/config/config.toml:/config.toml
    networks:
      - faveo-network
    restart: unless-stopped

networks:
  faveo-network:
    name: ${DOMAINNAME}-faveo
    ipam:
      config:
        - subnet: ${SUBNET}
EOF
    } > docker-compose.yml
    sed -i "s|@@REDIS_IMAGE@@|$REDIS_IMAGE|" docker-compose.yml
    # SELinux (enforcing): let Docker relabel every bind mount for the containers.
    if selinux_enforcing; then
        sed -i -E 's#^([[:space:]]*- \./[^[:space:]:]*:[^[:space:]:]+)$#\1:z#' docker-compose.yml
    fi
}

write_env() {
    {
        echo "# Faveo Helpdesk Docker settings - generated by $SCRIPT_NAME on $(date '+%Y-%m-%d %H:%M')."
        echo "# Used by docker-compose.yml. Keep this file private (it contains passwords)."
        echo "INSTALLED_BY=faveo-run.sh $SCRIPT_VERSION"
        echo "COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT"
        echo "DOMAINNAME=$domainname"
        echo "INSTALL_DIR=$install_dir"
        echo "RELEASE=$release"
        echo "FAVEO_ENV=$faveo_env"
        echo "SSL_TYPE=$(ssl_name "$ssl_option" | cut -d' ' -f1)"
        echo "WEBSOCKET=$websocket_enable"
        echo "PHP_VERSION=$php_version"
        echo "NODE_VERSION=$node_version"
        echo "TIMEZONE=$timezone"
        echo "HTTP_PORT=$http_port"
        echo "HTTPS_PORT=$https_port"
        echo "SUPERVISOR_PORT=$([[ "$supervisor_port" == "none" ]] && echo "" || echo "$supervisor_port")"
        echo "SUBNET=${subnet_prefix}.0.0/16"
        echo "DB_LOCATION=$db_location"
        if [[ "$db_location" == "local" ]]; then
            echo "MYSQL_ROOT_PASSWORD=$db_root_password"
            echo "MYSQL_DATABASE=$db_name"
            echo "MYSQL_USER=$db_user"
            echo "MYSQL_PASSWORD=$db_password"
            echo "DB_HOST=faveo-mysql"
            echo "DB_PORT=3306"
        else
            echo "DB_HOST=$db_container_host"
            echo "DB_HOST_FROM_SERVER=$db_host"
            echo "DB_PORT=$db_port"
            echo "DB_SSL=$db_ssl"
            echo "DB_SSL_VERIFY=${db_ssl_verify:-no}"
        fi
        echo "DB_DATABASE=$db_name"
        echo "DB_USERNAME=$db_user"
        echo "DB_PASSWORD=$db_password"
        echo "MEILI_MASTER_KEY=$MEILI_MASTER_KEY"
        if [[ "$websocket_enable" == "yes" ]]; then
            echo "WEBSOCKET_PORT=6001"
            echo "WEBSOCKET_URL=wss://${site_url#https://}/fc"
        fi
    } > .env
    chmod 600 .env
}

generate_files() {
    info "Creating the installation files in $install_dir..."
    copy_templates
    write_apache_conf
    write_meilisearch_config
    write_compose
    write_env
    mkdir -p storage "$host_root_dir" redis logs/apache logs/supervisor
    if [[ "$db_location" == "local" ]]; then
        mkdir -p mysql
    elif [[ "$db_ssl" == "yes" ]]; then
        mkdir -p db_ssl
        cp "$STAGE_DIR/db-ca.pem" db_ssl/ca.pem
        [[ -f "$STAGE_DIR/db-cert.pem" ]] && cp "$STAGE_DIR/db-cert.pem" db_ssl/client-cert.pem
        [[ -f "$STAGE_DIR/db-key.pem"  ]] && cp "$STAGE_DIR/db-key.pem"  db_ssl/client-key.pem
        chown -R 0:33 db_ssl 2>/dev/null; chmod 750 db_ssl; chmod 640 db_ssl/*
    fi
    write_helper_file
    ok "Files created."
}

# ----------------------------------------------------------------------------
# SSL
# ----------------------------------------------------------------------------
ssl_letsencrypt() {
    local z="" rc cron_cmd
    selinux_enforcing && z=":z"
    info "Requesting a Let's Encrypt certificate for $domainname..."
    mkdir -p certbot/html certbot/letsencrypt/etc/letsencrypt
    echo "<h1>Obtain SSL Certs</h1>" > certbot/html/index.html
    docker rm -f "${domainname}-apache-cert" >/dev/null 2>&1 || true
    docker run -d -p 80:80 -v "$install_dir/certbot/html:/usr/local/apache2/htdocs$z" \
        --name "${domainname}-apache-cert" httpd:2.4.33-alpine >/dev/null \
        || die "The temporary web server for the certificate request could not start (is port 80 free?)."
    docker run --rm \
        -v "$install_dir/certbot/letsencrypt/etc/letsencrypt:/etc/letsencrypt$z" \
        -v "$install_dir/certbot/html:/data/letsencrypt$z" \
        certbot/certbot certonly --webroot --email "$email" --agree-tos --non-interactive \
        --no-eff-email --webroot-path=/data/letsencrypt -d "$domainname"
    rc=$?
    docker rm -f "${domainname}-apache-cert" >/dev/null 2>&1 || true
    if [[ $rc -ne 0 || ! -e "certbot/letsencrypt/etc/letsencrypt/live/$domainname/fullchain.pem" ]]; then
        die "Let's Encrypt failed. Check that $domainname points to this server and port 80 is reachable from the internet."
    fi
    ok "Let's Encrypt certificate obtained."

    # Weekly renewal through the running site, then reload Apache to use the new certificate.
    enable_cron_service
    cron_cmd="docker run --rm -v $install_dir/certbot/letsencrypt/etc/letsencrypt:/etc/letsencrypt$z -v $install_dir/$host_root_dir/public:/data/letsencrypt$z certbot/certbot renew --webroot --webroot-path=/data/letsencrypt --quiet && docker exec ${domainname}-apache apachectl -k graceful >/dev/null 2>&1"
    if (crontab -l 2>/dev/null | grep -vF "# faveo-docker:$install_dir"; echo "45 2 * * 6 $cron_cmd # faveo-docker:$install_dir") | crontab - 2>/dev/null; then
        RB_CRON="y"
        ok "Weekly certificate renewal added to cron."
    else
        warn "Could not add the certificate renewal to cron; renew manually before the certificate expires."
    fi
}

ssl_selfsigned() {
    local img="faveo-selfsign:$COMPOSE_PROJECT" ctr="${domainname}-selfsign" rc
    info "Creating a self-signed certificate for $domainname..."
    docker build -q --build-arg CN="$domainname" -t "$img" Dockerfile/selfsign >/dev/null \
        || die "Creating the self-signed certificate failed."
    docker rm -f "$ctr" >/dev/null 2>&1 || true
    rm -rf ssl_copy
    docker create --name "$ctr" "$img" >/dev/null && docker cp "$ctr:/etc/ssl/copy" ssl_copy >/dev/null
    rc=$?
    docker rm -f "$ctr" >/dev/null 2>&1 || true
    docker rmi "$img" >/dev/null 2>&1 || true
    [[ $rc -eq 0 && -f ssl_copy/faveolocal.crt ]] || die "Could not extract the self-signed certificate."
    rm -f ssl_copy/faveoroot.key ssl_copy/faveolocal.csr ssl_copy/*.srl
    chmod 600 ssl_copy/private.key
    ok "Self-signed certificate created (import ssl_copy/faveorootCA.crt into browsers to trust it)."
}

ssl_paid() {
    local f
    info "Installing the paid SSL certificate..."
    mkdir -p ssl_copy
    for f in faveolocal.crt private.key faveorootCA.crt; do
        [[ -f "$STAGE_DIR/$f" ]] || die "Paid SSL file '$f' is missing."
        cp "$STAGE_DIR/$f" "ssl_copy/$f" || die "Could not copy $f."
    done
    chmod 600 ssl_copy/private.key
    chmod 644 ssl_copy/faveolocal.crt ssl_copy/faveorootCA.crt
    ok "Paid SSL certificate installed."
}

# ----------------------------------------------------------------------------
# Application, containers, verification
# ----------------------------------------------------------------------------
download_faveo() {
    local url="https://billing.faveohelpdesk.com/download/faveo?order_number=${orderno}&serial_key=${license}"
    [[ "$release" != "official" ]] && url+="&release=${release}"
    if [[ -n "${FAVEO_ZIP_FILE:-}" ]]; then
        # Offline / pre-downloaded archive: FAVEO_ZIP_FILE=/path/faveo.zip ./faveo-run.sh ...
        [[ -f "$FAVEO_ZIP_FILE" ]] || die "FAVEO_ZIP_FILE '$FAVEO_ZIP_FILE' does not exist."
        info "Using the Faveo archive $FAVEO_ZIP_FILE (FAVEO_ZIP_FILE)."
        cp "$FAVEO_ZIP_FILE" faveo.zip || die "Could not copy $FAVEO_ZIP_FILE."
    else
        info "Downloading Faveo Helpdesk ($release release)..."
        curl -fSL --retry 3 "$url" --output faveo.zip \
            || die "Download failed. Check the order number and license code$([[ "$release" != "official" ]] && echo ", that the '$release' release is available for your license"), and the internet connection."
    fi
    unzip -tq faveo.zip >/dev/null 2>&1 \
        || die "The downloaded file is not a valid archive. Check the order number and license code."
    info "Extracting..."
    rm -rf "${install_dir:?}/$host_root_dir"
    unzip -q faveo.zip -d "$host_root_dir" || die "Extracting Faveo failed."
    rm -f faveo.zip
    chown -R 33:33 "$host_root_dir" storage
    find "$host_root_dir" -type d -exec chmod 755 {} +
    find "$host_root_dir" -type f -exec chmod 644 {} +
    chmod -R 755 storage
    ok "Faveo Helpdesk downloaded and extracted."
}

start_stack() {
    local attempt img
    for img in "faveo-apache:php$php_version-node$node_version" "faveo-supervisor:php$php_version-node$node_version"; do
        docker image inspect "$img" >/dev/null 2>&1 || RB_IMAGES+=("$img")
    done
    RB_STACK="y"
    info "Building the images (this can take several minutes)..."
    for attempt in $(seq 1 "$build_retries"); do
        $DOCKER_COMPOSE build && break
        if [[ $attempt -lt $build_retries ]]; then
            warn "Image build failed (attempt $attempt of $build_retries), usually a network problem. Retrying in 15 seconds..."
            sleep 15
        else
            die "Building the images failed $build_retries times. Check the network and the output above."
        fi
    done
    info "Starting the containers..."
    $DOCKER_COMPOSE up -d || die "Starting the containers failed. Check the output above."
    ok "Containers started."
}

verify_https() {
    local code="" i served expected
    info "Waiting for $site_url to respond..."
    for i in $(seq 1 30); do
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
            --resolve "$domainname:$https_port:127.0.0.1" "$site_url/" 2>/dev/null)
        [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && break
        sleep 5
    done
    if [[ ! "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
        warn "$site_url does not answer yet. Check: cd $install_dir && $DOCKER_COMPOSE logs faveo-apache"
        return 0
    fi
    ok "$site_url answers (HTTP $code)."
    if [[ "$ssl_option" == "C" ]]; then
        served=$(echo | openssl s_client -connect "127.0.0.1:$https_port" -servername "$domainname" 2>/dev/null \
            | openssl x509 -noout -fingerprint -sha256 2>/dev/null)
        expected=$(openssl x509 -noout -fingerprint -sha256 -in ssl_copy/faveolocal.crt 2>/dev/null)
        [[ -n "$served" && "$served" == "$expected" ]] && ok "The paid certificate is being served." \
            || warn "Apache is not serving the supplied certificate. Check $install_dir/ssl_copy."
    fi
}

# ----------------------------------------------------------------------------
# FAVEO-DOCKER-COMMANDS.txt - check / verify / manage commands for this installation,
# written for this server's OS. Contains no passwords (they are read from .env
# or credentials.txt when a command runs).
# ----------------------------------------------------------------------------
write_helper_file() {
    local f="FAVEO-DOCKER-COMMANDS.txt" C d=$domainname a="${domainname}-apache" m="${domainname}-mysql"
    local svc_start svc_stop svc_restart svc_status svc_boot fw upd os_name sel="" i
    detect_compose
    C=$DOCKER_COMPOSE
    os_name=$(os_release_value PRETTY_NAME); os_name=${os_name:-Linux}

    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        svc_start="systemctl start docker"; svc_stop="systemctl stop docker"; svc_restart="systemctl restart docker"
        svc_status="systemctl status docker"; svc_boot="systemctl enable docker"
    elif command -v rc-service >/dev/null 2>&1; then
        svc_start="rc-service docker start"; svc_stop="rc-service docker stop"; svc_restart="rc-service docker restart"
        svc_status="rc-service docker status"; svc_boot="rc-update add docker default"
    elif command -v sv >/dev/null 2>&1 && [[ -d /etc/sv/docker ]]; then
        svc_start="sv up docker"; svc_stop="sv down docker"; svc_restart="sv restart docker"
        svc_status="sv status docker"; svc_boot="ln -s /etc/sv/docker /var/service/"
    else
        svc_start="service docker start"; svc_stop="service docker stop"; svc_restart="service docker restart"
        svc_status="service docker status"; svc_boot="update-rc.d docker defaults   (or: chkconfig docker on)"
    fi

    if command -v ufw >/dev/null 2>&1; then
        fw="  Status            ufw status verbose
  Allow web ports   ufw allow $http_port/tcp && ufw allow $https_port/tcp"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        fw="  Status            firewall-cmd --state && firewall-cmd --list-all
  Allow web ports   firewall-cmd --permanent --add-port=$http_port/tcp --add-port=$https_port/tcp && firewall-cmd --reload"
    else
        fw="  No ufw / firewalld found. Allow TCP $http_port and $https_port in your firewall or cloud security group."
    fi
    fw+="
  Note: ports published by Docker can bypass ufw/firewalld; the Supervisor port is bound to 127.0.0.1."

    if command -v apt-get >/dev/null 2>&1; then
        upd="apt-get update && apt-get install --only-upgrade -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    elif [[ "$(os_release_value ID)" == "amzn" ]]; then
        upd="$(command -v dnf >/dev/null 2>&1 && echo dnf || echo yum) upgrade -y docker"
    elif command -v dnf >/dev/null 2>&1; then
        upd="dnf upgrade -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    elif command -v yum >/dev/null 2>&1; then
        upd="yum update -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    elif command -v zypper >/dev/null 2>&1; then
        upd="zypper --non-interactive update docker docker-compose"
    elif command -v pacman >/dev/null 2>&1; then
        upd="pacman -Syu --noconfirm docker docker-compose"
    elif command -v apk >/dev/null 2>&1; then
        upd="apk upgrade docker docker-cli-compose"
    elif command -v xbps-install >/dev/null 2>&1; then
        upd="xbps-install -Su docker docker-compose"
    else
        upd="see https://docs.docker.com/engine/install/"
    fi

    if command -v getenforce >/dev/null 2>&1; then
        sel="
SELINUX
  Mode              getenforce
  File labels       ls -Z $install_dir
  Relabel folder    chcon -R -t container_file_t $install_dir
"
    fi

    cat > "$f" <<EOF
=====================================================================================
 FAVEO HELPDESK - DOCKER COMMANDS
=====================================================================================
 Domain        : $d
 URL           : $site_url
 Install path  : $install_dir
 Server OS     : $os_name
 Created       : $(date '+%Y-%m-%d %H:%M') by $SCRIPT_NAME $SCRIPT_VERSION

 Run the commands as root (or put "sudo" in front), from the install path:
     cd $install_dir
 Passwords are in credentials.txt and .env (root only).
-------------------------------------------------------------------------------------

QUICK HEALTH CHECK
  All containers    $C ps
  Site answers      curl -sk -o /dev/null -w '%{http_code}\n' --resolve $d:$https_port:127.0.0.1 $site_url/
  Resource usage    docker stats --no-stream \$(docker ps --format '{{.Names}}' --filter name=^$d-)
  Disk usage        du -sh $install_dir/* && docker system df

CONTAINERS
  Start all         $C up -d
  Stop all          $C down
  Restart all       $C restart
  Restart one       $C restart faveo-apache      (faveo-mysql, faveo-redis, faveo-supervisor, faveo-meilisearch)
  Rebuild images    $C build --no-cache && $C up -d
  Shell (app)       docker exec -it $a bash
  Shell (worker)    docker exec -it ${d}-supervisor bash

LOGS
  All, live         $C logs -f --tail 100
  One service       $C logs -f --tail 100 faveo-apache
  Apache logs       tail -f $install_dir/logs/apache/faveo-error.log
  Faveo app log     tail -f $install_dir/faveo/storage/logs/laravel.log
  Worker logs       ls $install_dir/faveo/storage/logs/   (horizon-worker.log, faveo-cron.log)
  Install log       less $install_dir/logs/faveo-install.log

VERIFY THE APPLICATION
  PHP + ionCube     docker exec $a php -v
  PHP modules       docker exec $a php -m
  Apache config     docker exec $a apachectl -t
  Laravel info      docker exec -u www-data $a php artisan about
  Migrations        docker exec -u www-data $a php artisan migrate:status
  Scheduled tasks   docker exec -u www-data $a php artisan schedule:list
  Clear caches      docker exec -u www-data $a php artisan optimize:clear
  Worker processes  docker exec ${d}-supervisor supervisorctl status
  Horizon status    docker exec -u www-data ${d}-supervisor php artisan horizon:status
  Restart workers   docker exec ${d}-supervisor supervisorctl restart all
  Redis             docker exec ${d}-redis redis-cli ping
  Meilisearch       docker exec $a curl -s http://${d}-meilisearch:7700/health

LICENSE
  Verify again      L=\$(grep '^License code' credentials.txt | cut -d: -f2 | tr -d ' ')
                    docker exec $a curl -k -X POST https://$d/licenseVerification -H 'Content-Type: application/json' \\
                      -d "{\"first\":\"\${L:0:4}\", \"second\":\"\${L:4:4}\", \"third\":\"\${L:8:4}\", \"forth\":\"\${L:12:4}\"}"
EOF

    if [[ "$db_location" == "local" ]]; then
        cat >> "$f" <<EOF

DATABASE (local MySQL container $m)
  Is it up          docker exec -e MYSQL_PWD="\$(grep ^MYSQL_ROOT_PASSWORD= .env | cut -d= -f2-)" $m mysqladmin -uroot -h127.0.0.1 ping
  MySQL shell       docker exec -it -e MYSQL_PWD="\$(grep ^MYSQL_ROOT_PASSWORD= .env | cut -d= -f2-)" $m mysql -uroot -h127.0.0.1 $db_name
  Table count       docker exec -e MYSQL_PWD="\$(grep ^MYSQL_ROOT_PASSWORD= .env | cut -d= -f2-)" $m mysql -uroot -h127.0.0.1 -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db_name'"
  Quick dump        docker exec -e MYSQL_PWD="\$(grep ^MYSQL_ROOT_PASSWORD= .env | cut -d= -f2-)" $m mysqldump -uroot -h127.0.0.1 --single-transaction $db_name | gzip > $db_name-\$(date +%F).sql.gz
  Database files    du -sh $install_dir/mysql
EOF
    else
        cat >> "$f" <<EOF

DATABASE (remote server $db_host:$db_port)
  Login test        docker exec -e MYSQL_PWD="\$(grep ^DB_PASSWORD= .env | cut -d= -f2-)" $a mysql -h $db_container_host -P $db_port -u $db_user -e 'SELECT 1' $db_name
  MySQL shell       docker exec -it -e MYSQL_PWD="\$(grep ^DB_PASSWORD= .env | cut -d= -f2-)" $a mysql -h $db_container_host -P $db_port -u $db_user $db_name
EOF
    fi

    cat >> "$f" <<EOF

SSL CERTIFICATE
EOF
    if [[ "$ssl_option" == "A" ]]; then
        cat >> "$f" <<EOF
  Expiry date       openssl x509 -noout -enddate -in certbot/letsencrypt/etc/letsencrypt/live/$d/cert.pem
  Renewal cron      crontab -l | grep faveo-docker
  Renew now         docker run --rm -v $install_dir/certbot/letsencrypt/etc/letsencrypt:/etc/letsencrypt -v $install_dir/faveo/public:/data/letsencrypt certbot/certbot renew --webroot --webroot-path=/data/letsencrypt && docker exec $a apachectl -k graceful
EOF
    else
        cat >> "$f" <<EOF
  Expiry date       openssl x509 -noout -enddate -in ssl_copy/faveolocal.crt
  Certificate       openssl x509 -noout -subject -issuer -in ssl_copy/faveolocal.crt
  Replace it        copy the new files over ssl_copy/faveolocal.crt, private.key, faveorootCA.crt, then: $C restart faveo-apache
EOF
    fi
    cat >> "$f" <<EOF
  Served cert       echo | openssl s_client -connect 127.0.0.1:$https_port -servername $d 2>/dev/null | openssl x509 -noout -subject -enddate

DOCKER SERVICE ($os_name)
  Start             $svc_start
  Stop              $svc_stop
  Restart           $svc_restart
  Status            $svc_status
  Start at boot     $svc_boot
  Docker versions   docker --version && $C version
  Update Docker     $upd

FIREWALL
$fw
$sel
NETWORK
  Docker network    docker network inspect ${d}-faveo
  Ports in use      ss -ltnp | grep -E ':($http_port|$https_port|$supervisor_port) '

BACKUP AND REMOVE
  Back up           $install_dir/faveo-run.sh --backup -i $install_dir
  List backups      ls -l $(dirname "$install_dir")/Backup/$d/
  Remove            $install_dir/faveo-run.sh --uninstall -i $install_dir

CLEAN UP DOCKER (frees disk space; only removes unused items)
  Unused images     docker image prune -a
  Build cache       docker builder prune
=====================================================================================
EOF
    chmod 644 "$f"
}

write_credentials() {
    {
        echo "Faveo Helpdesk Docker - Credentials"
        echo "-----------------------------------"
        echo "URL                     : $site_url"
        echo "Install path            : $install_dir"
        echo "License code            : $license"
        echo "Order number            : $orderno"
        echo "Release                 : $release"
        echo "Ports (HTTP/HTTPS/Sup.) : $http_port / $https_port / $supervisor_port$([[ "$supervisor_port" != "none" ]] && echo "   (Supervisor: 127.0.0.1 only)")"
        if [[ "$db_location" == "remote" ]]; then
            echo "Database                : remote server (no MySQL container)"
            echo "Database host           : $db_container_host"
            [[ "$db_container_host" != "$db_host" ]] && echo "                          ($db_host on this server, as seen from the containers)"
            echo "Database port           : $db_port"
        else
            echo "Database host           : faveo-mysql   (container ${domainname}-mysql)"
            echo "MySQL root password     : $db_root_password"
            echo "Database files          : $install_dir/mysql"
        fi
        echo "Database name           : $db_name"
        echo "Database user           : $db_user"
        echo "Database password       : $db_password"
        if [[ "$db_location" == "remote" && "$db_ssl" == "yes" ]]; then
            echo "Database SSL            : yes (verify server certificate: $db_ssl_verify)"
            echo "  CA file (containers)  : /var/www/db-ssl/ca.pem"
            [[ -f db_ssl/client-cert.pem ]] && echo "  Client certificate    : /var/www/db-ssl/client-cert.pem"
            [[ -f db_ssl/client-key.pem  ]] && echo "  Client key            : /var/www/db-ssl/client-key.pem"
        fi
        echo "Redis host              : faveo-redis"
        echo "MeiliSearch host        : http://${domainname}-meilisearch:7700"
        echo "MeiliSearch master key  : $MEILI_MASTER_KEY"
        [[ "$ssl_option" == "B" ]] && echo "Self-signed root CA     : $install_dir/ssl_copy/faveorootCA.crt (import into browsers)"
    } > credentials.txt
    chmod 600 credentials.txt
}

# ----------------------------------------------------------------------------
# Configure Faveo (php artisan install:faveo) and verify the license.
# Problems here never roll back the installation; the full output is shown.
# ----------------------------------------------------------------------------
setup_faveo_app() {
    local ctr="${domainname}-apache" host port sec sslkey="" sslcert="" sslca="" verify="" i rc
    local log="$install_dir/logs/faveo-install.log" body code lic="$license"

    echo ""
    echo -e "${CYAN}${BOLD} Configuring Faveo Helpdesk${NC}"
    info "Stopping the supervisor container while Faveo is configured..."
    $DOCKER_COMPOSE stop faveo-supervisor 2>&1 | sed 's/^/   /'

    if [[ "$db_location" == "local" ]]; then
        host="faveo-mysql"; port=3306; sec="no"
        info "Waiting for MySQL to accept connections..."
        for i in $(seq 1 90); do
            MYSQL_PWD="$db_root_password" docker exec -e MYSQL_PWD "${domainname}-mysql" \
                mysqladmin -uroot -h127.0.0.1 ping >/dev/null 2>&1 && break
            sleep 2
        done
    else
        host=$db_container_host; port=$db_port; sec=$db_ssl
        if [[ "$db_ssl" == "yes" ]]; then
            sslca="/var/www/db-ssl/ca.pem"
            [[ -f db_ssl/client-cert.pem ]] && sslcert="/var/www/db-ssl/client-cert.pem"
            [[ -f db_ssl/client-key.pem  ]] && sslkey="/var/www/db-ssl/client-key.pem"
            verify=$db_ssl_verify
        fi
    fi

    info "Running php artisan install:faveo in $ctr (output below, also saved in $log)..."
    echo -e "${CYAN} ------------------------- install:faveo output -------------------------${NC}"
    docker exec -w /var/www/html "$ctr" php artisan install:faveo \
        --appurl="$site_url" --sqlengine=mysql --sqlhost="$host" \
        --dbname="$db_name" --dbuser="$db_user" --dbpass="$db_password" --sqlport="$port" \
        --securecon="$sec" --sslkey="$sslkey" --sslcert="$sslcert" --sslca="$sslca" --sslverify="$verify" \
        --migrate=1 --dummy=0 --env="$faveo_env" --no-interaction 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    echo -e "${CYAN} ------------------------------------------------------------------------${NC}"
    docker exec "$ctr" chown -R www-data:www-data /var/www/html >/dev/null 2>&1

    local failmsg
    failmsg=$(grep -iE 'cannot be installed|installation (has )?failed|SQLSTATE\[|uncaught|fatal error|^[[:space:]>]*Aborted\.' "$log" | head -1 | sed 's/^[[:space:]>]*//')
    if [[ $rc -eq 0 && -z "$failmsg" ]]; then
        FAVEO_SETUP_STATUS="success"
        # The application must reach Redis by its container name.
        if grep -q '^REDIS_HOST=' "$host_root_dir/.env" 2>/dev/null; then
            sed -i 's|^REDIS_HOST=.*|REDIS_HOST=faveo-redis|' "$host_root_dir/.env"
        elif [[ -f "$host_root_dir/.env" ]]; then
            echo "REDIS_HOST=faveo-redis" >> "$host_root_dir/.env"
        fi
        docker exec -u www-data -w /var/www/html "$ctr" php artisan config:clear 2>&1 | sed 's/^/   /'
        ok "Faveo installation completed (install:faveo exit code 0)."
    else
        if [[ -n "$failmsg" ]]; then
            FAVEO_SETUP_STATUS="failed: $failmsg"
        else
            FAVEO_SETUP_STATUS="failed (exit code $rc)"
        fi
        warn "php artisan install:faveo did not complete: ${failmsg:-exit code $rc}. The installation is kept (no rollback)."
    fi

    # License verification: the 16-character license code in four parts.
    if [[ "$FAVEO_SETUP_STATUS" != "success" ]]; then
        LICENSE_STATUS="not checked (Faveo installation failed)"
    elif [[ ${#lic} -ne 16 ]]; then
        LICENSE_STATUS="not checked (the license code is ${#lic} characters, 16 are needed)"
        warn "License verification skipped: the license code must have 16 characters."
    else
        # Sent from inside the Apache container, where the domain resolves to the
        # container itself (127.0.0.1 in its /etc/hosts) - the same as running curl
        # on the Faveo server. Apache listens on 443 inside the container.
        local attempt data msg
        data="{\"first\":\"${lic:0:4}\", \"second\":\"${lic:4:4}\", \"third\":\"${lic:8:4}\", \"forth\":\"${lic:12:4}\"}"
        for attempt in 1 2; do
            info "Verifying the license (attempt $attempt of 2): POST https://$domainname/licenseVerification"
            echo -e "${CYAN} ------------------------- licenseVerification response -----------------${NC}"
            body=$(docker exec "$ctr" curl -k -sS -X POST "https://$domainname/licenseVerification" \
                -H "Content-Type: application/json" -d "$data" \
                -w $'\nHTTP_STATUS:%{http_code}' 2>&1)
            code=$(grep -o 'HTTP_STATUS:[0-9]*' <<<"$body" | tail -1 | cut -d: -f2)
            sed '/^HTTP_STATUS:/d' <<<"$body"
            echo ""
            echo "HTTP status: ${code:-none}"
            echo -e "${CYAN} ------------------------------------------------------------------------${NC}"
            printf 'licenseVerification attempt %s:\n%s\n' "$attempt" "$body" >> "$log"
            if grep -qE '"success"[[:space:]]*:[[:space:]]*true' <<<"$body"; then
                LICENSE_STATUS="verified"
                break
            fi
            msg=$(grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$body" | head -1 | sed 's/^"message"[[:space:]]*:[[:space:]]*"//; s/"$//')
            LICENSE_STATUS="failed (HTTP ${code:-none}${msg:+: $msg})"
            if [[ $attempt -eq 1 ]]; then
                warn "License verification did not succeed; trying again in 10 seconds..."
                sleep 10
            fi
        done
        if [[ "$LICENSE_STATUS" == "verified" ]]; then
            ok "License verified successfully."
        else
            warn "License verification failed. See the response above. The installation is kept (no rollback)."
        fi
    fi

    info "Starting the supervisor container..."
    $DOCKER_COMPOSE start faveo-supervisor 2>&1 | sed 's/^/   /'
    sleep 3
    if [[ "$(docker inspect -f '{{.State.Running}}' "${domainname}-supervisor" 2>/dev/null)" == "true" ]]; then
        SUPERVISOR_STATUS="running"
    else
        SUPERVISOR_STATUS="NOT running - check: cd $install_dir && $DOCKER_COMPOSE logs faveo-supervisor"
    fi
    echo ""
    $DOCKER_COMPOSE ps 2>&1 | sed 's/^/   /'
}

print_summary() {
    echo ""
    echo "#########################################################################"
    echo ""
    if [[ "$generate_only" == "y" ]]; then
        echo -e "${GREEN} Files created in $install_dir (nothing was started).${NC}"
        echo "  Review them, then start with:  cd $install_dir && docker compose up -d --build"
        echo "  (SSL certificate and the Faveo download are not done in this mode.)"
    else
        if [[ "$skip_faveo_setup" == "y" ]]; then
            echo -e "${GREEN} Faveo Helpdesk is installed.${NC} Open ${GREEN}$site_url${NC} to finish the setup."
            echo "  Use the database details below in the Faveo web installer."
        else
            local row="  %-36s %s\n"
            printf "$row" "Faveo installation (install:faveo):" "$( [[ "$FAVEO_SETUP_STATUS" == "success" ]] && echo -e "${GREEN}SUCCESS${NC}" || echo -e "${RED}${FAVEO_SETUP_STATUS^^}${NC}")"
            printf "$row" "License verification:" "$( [[ "$LICENSE_STATUS" == "verified" ]] && echo -e "${GREEN}VERIFIED SUCCESSFULLY${NC}" || echo -e "${RED}${LICENSE_STATUS^^}${NC}")"
            printf "$row" "Supervisor container:" "$SUPERVISOR_STATUS"
            echo ""
            if [[ "$FAVEO_SETUP_STATUS" == "success" ]]; then
                echo -e "${GREEN} ✔ Faveo GUI installation completed successfully.${NC} Open ${GREEN}$site_url${NC}"
            else
                echo -e "${RED} ✘ Faveo GUI installation did not complete.${NC} The containers and files are kept (no rollback)."
                echo "   Full output: $install_dir/logs/faveo-install.log"
                echo "   You can finish in the browser at $site_url with the database details below,"
                echo "   or run the command again:  docker exec -it ${domainname}-apache php artisan install:faveo ..."
            fi
            [[ "$LICENSE_STATUS" != "verified" && "$FAVEO_SETUP_STATUS" == "success" ]] \
                && echo "   License: check the message above and the license code."
        fi
    fi
    echo ""
    cat credentials.txt
    echo ""
    echo "#########################################################################"
    echo " Saved in $install_dir/credentials.txt (readable by root only)."
    if [[ "$generate_only" != "y" ]]; then
        echo ""
        echo " Manage this installation:"
        echo "   Start / stop      cd $install_dir && $DOCKER_COMPOSE up -d   |   $DOCKER_COMPOSE down"
        echo "   Back up           sudo $install_dir/faveo-run.sh --backup -i $install_dir"
        echo "   Remove            sudo $install_dir/faveo-run.sh --uninstall -i $install_dir"
        echo "   All commands      $install_dir/FAVEO-DOCKER-COMMANDS.txt  (check, logs, database, SSL, Docker service for this OS)"
        if [[ -n "$RB_MOVED" ]]; then echo "   Previous content  $RB_MOVED  (delete it when no longer needed)"; fi
    fi
}

# ----------------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------------
need_value() {
    # Values may start with dashes (PEM text "-----BEGIN"), so only reject a
    # missing value or one that looks like the next option.
    [[ -n "$2" && ! "$2" =~ ^--?[A-Za-z][A-Za-z-]*$ ]] || die "Option '$1' needs a value. Run '$SCRIPT_NAME --help'."
}

while [[ $# -gt 0 ]]; do
    if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
    case "$1" in
        -h|--help|-help)                    show_help="y"; shift ;;
        -p|--product)                       need_value "$1" "$2"
                                            [[ "${2,,}" == "helpdesk" ]] || die "This script installs Faveo Helpdesk. For Network Discovery use ../faveo-nd-docker/faveo-run.sh."
                                            shift 2 ;;
        -d|--domain|-domainname|--domainname) need_value "$1" "$2"; domainname=$2; shift 2 ;;
        -e|--email|-email)                  need_value "$1" "$2"; email=$2; shift 2 ;;
        -l|--license|-license)              need_value "$1" "$2"; license=$2; shift 2 ;;
        -o|--order|--orderno|-orderno)      need_value "$1" "$2"; orderno=$2; shift 2 ;;
        -s|--ssl|-ssl)                      need_value "$1" "$2"; ssl_raw=$2; shift 2 ;;
        -r|--release)                       need_value "$1" "$2"; release=${2,,}; shift 2 ;;
        --faveo-env|--faveoenv)             need_value "$1" "$2"; faveo_env=${2,,}; shift 2 ;;
        --skip-faveo-setup)                 skip_faveo_setup="y"; shift ;;
        -w|--websocket|-websocket)          need_value "$1" "$2"; websocket_raw=$2; shift 2 ;;
        --certfile|--ssl-cert)              need_value "$1" "$2"; certfile=$2; shift 2 ;;
        --keyfile|--ssl-key)                need_value "$1" "$2"; keyfile=$2; shift 2 ;;
        --cacertfile|--ssl-ca)              need_value "$1" "$2"; cacertfile=$2; shift 2 ;;
        -i|--install-dir)                   need_value "$1" "$2"; install_dir=$2; shift 2 ;;
        -f|--force)                         force="y"; shift ;;
        --db|--db-location)                 need_value "$1" "$2"; db_location=${2,,}; shift 2 ;;
        --sqlreser)                         need_value "$1" "$2"; [[ "${2,,}" == "yes" ]] && db_location="remote" || db_location="local"; shift 2 ;;
        --db-name)                          need_value "$1" "$2"; db_name=$2; db_custom_from_cli="y"; shift 2 ;;
        --db-user)                          need_value "$1" "$2"; db_user=$2; db_custom_from_cli="y"; shift 2 ;;
        --db-password)                      need_value "$1" "$2"; db_password=$2; db_custom_from_cli="y"; shift 2 ;;
        --db-root-password)                 need_value "$1" "$2"; db_root_password=$2; shift 2 ;;
        --db-host|--sqlhost)                need_value "$1" "$2"; db_host=$2; shift 2 ;;
        --db-port|--sqlport)                need_value "$1" "$2"; db_port=$2; shift 2 ;;
        --db-admin-user|--sqlusername)      need_value "$1" "$2"; db_admin_user=$2; shift 2 ;;
        --db-admin-password|--sqlpassword)  [[ $# -ge 2 ]] || die "Option '$1' needs a value."; db_admin_password=$2; db_admin_pw_given="y"; shift 2 ;;
        --db-ssl|--sqlsecure)               need_value "$1" "$2"; db_ssl=${2,,}; shift 2 ;;
        --db-ssl-ca|--sqlsslca)             need_value "$1" "$2"; db_ssl_ca=$2; shift 2 ;;
        --db-ssl-cert|--sqlsslcert)         need_value "$1" "$2"; db_ssl_cert=$2; shift 2 ;;
        --db-ssl-key|--sqlsslkey)           need_value "$1" "$2"; db_ssl_key=$2; shift 2 ;;
        --db-ssl-verify|--sqlsslverify)     need_value "$1" "$2"; db_ssl_verify=${2,,}; shift 2 ;;
        --http-port)                        need_value "$1" "$2"; http_port=$2; ports_from_cli="y"; shift 2 ;;
        --https-port)                       need_value "$1" "$2"; https_port=$2; ports_from_cli="y"; shift 2 ;;
        --supervisor-port)                  need_value "$1" "$2"; supervisor_port=${2,,}; ports_from_cli="y"; shift 2 ;;
        --auto-ports)                       auto_ports="y"; shift ;;
        --subnet)                           need_value "$1" "$2"; subnet=$2; shift 2 ;;
        --php|--php-version)                need_value "$1" "$2"; php_version=$2; shift 2 ;;
        --node|--node-version)              need_value "$1" "$2"; node_version=$2; shift 2 ;;
        --timezone)                         need_value "$1" "$2"; timezone=$2; shift 2 ;;
        -y|--yes)                           assume_yes="y"; shift ;;
        --confirm)                          confirm_flag="y"; shift ;;
        -g|--generate-only)                 generate_only="y"; shift ;;
        --install-docker)                   install_docker_flag="y"; shift ;;
        --keep-on-failure)                  keep_on_failure="y"; shift ;;
        --no-banner)                        show_banner="n"; shift ;;
        --backup)                           do_backup="y"; shift ;;
        --backup-dir)                       need_value "$1" "$2"; backup_dir=$2; shift 2 ;;
        --uninstall|--rollback)             uninstall="y"; shift ;;
        *) die "Unknown option: $1. Run '$SCRIPT_NAME --help' to see all options." ;;
    esac
done

if [[ "$show_help" == "y" ]]; then
    usage
    print_system_info
    exit 0
fi

# ----------------------------------------------------------------------------
# Validate everything that was given, before anything is changed
# ----------------------------------------------------------------------------
if [[ "$generate_only" != "y" && $EUID -ne 0 ]]; then
    die "Please run as root: sudo ./$SCRIPT_NAME $([[ "$uninstall" == "y" ]] && echo "--uninstall " )..."
fi
if ! command -v openssl >/dev/null 2>&1; then
    [[ $EUID -eq 0 ]] && install_packages openssl >/dev/null 2>&1
    command -v openssl >/dev/null 2>&1 || die "openssl is required. Install it with your package manager and run again."
fi

[[ "$uninstall" == "y" ]] && run_uninstall
[[ "$do_backup" == "y" ]] && run_backup

errors=()
orderno=${orderno#\#}
[[ -n "$domainname" ]] && ! valid_domain "$domainname" && errors+=("--domain: '$domainname' is not a valid domain name (letters, digits, '-' and '.').")
[[ -n "$email"      ]] && ! valid_email "$email"       && errors+=("--email: '$email' is not a valid email address.")
[[ -n "$license"    ]] && ! valid_code "$license"      && errors+=("--license: only letters, digits and '-' are allowed.")
[[ -n "$orderno"    ]] && ! valid_code "$orderno"      && errors+=("--order: only letters, digits and '-' are allowed.")
[[ -n "$release" && ! "$release" =~ ^(official|rc|beta)$ ]] && errors+=("--release: use official, rc or beta.")
[[ -n "$faveo_env" && ! "$faveo_env" =~ ^(production|development|testing)$ ]] && errors+=("--faveo-env: use production, development or testing.")
if [[ -n "$ssl_raw" ]]; then
    ssl_option=$(normalize_ssl "$ssl_raw") || errors+=("--ssl: use certbot, self-signed or paid-ssl (or A, B, C).")
fi
if [[ -n "$websocket_raw" ]]; then
    websocket_enable=$(normalize_yesno "$websocket_raw") || errors+=("--websocket: use yes or no.")
fi
[[ "$php_version" =~ ^([8-9]|[1-9][0-9])\.[0-9]+$ ]] || errors+=("--php: use version 8.x or newer, e.g. 8.4.")
[[ "$node_version" =~ ^[0-9]+$ ]]                    || errors+=("--node: use a major version number, e.g. 22.")
valid_tz "$timezone"                                 || errors+=("--timezone: use Area/City, e.g. Asia/Kolkata or Europe/London.")
valid_db_ident "$db_name"                            || errors+=("--db-name: letters, digits and '_' only (max 32).")
valid_db_ident "$db_user"                            || errors+=("--db-user: letters, digits and '_' only (max 32).")
[[ -n "$db_password"      ]] && ! valid_db_pass "$db_password"      && errors+=("--db-password: $DB_PASS_RULE.")
[[ -n "$db_root_password" ]] && ! valid_db_pass "$db_root_password" && errors+=("--db-root-password: $DB_PASS_RULE.")
[[ -z "$db_location" && -n "$db_host" ]] && db_location="remote"
[[ -n "$db_location" && ! "$db_location" =~ ^(local|remote)$ ]] && errors+=("--db: use local or remote.")
[[ -n "$db_host" ]] && ! valid_db_host "$db_host" && errors+=("--db-host: use a hostname or IPv4 address.")
[[ -n "$db_port" ]] && ! valid_port "$db_port"    && errors+=("--db-port: use a number from 1 to 65535.")
if [[ -n "$db_ssl" ]]; then db_ssl=$(normalize_yesno "$db_ssl") || errors+=("--db-ssl: use yes or no."); fi
if [[ -n "$db_ssl_verify" ]]; then db_ssl_verify=$(normalize_yesno "$db_ssl_verify") || errors+=("--db-ssl-verify: use yes or no."); fi
if [[ "$db_location" == "remote" && "$db_ssl" == "yes" ]]; then
    [[ -n "$db_ssl_ca"   ]] && { resolve_cert_arg "$db_ssl_ca"   "$STAGE_DIR/db-ca.pem"   cert || errors+=("--db-ssl-ca: not a valid file path or PEM certificate (text or base64)."); }
    [[ -n "$db_ssl_cert" ]] && { resolve_cert_arg "$db_ssl_cert" "$STAGE_DIR/db-cert.pem" cert || errors+=("--db-ssl-cert: not a valid file path or PEM certificate (text or base64)."); }
    [[ -n "$db_ssl_key"  ]] && { resolve_cert_arg "$db_ssl_key"  "$STAGE_DIR/db-key.pem"  key  || errors+=("--db-ssl-key: not a valid file path or PEM private key (text or base64)."); }
    [[ -n "$db_ssl_cert" && -z "$db_ssl_key" ]] && errors+=("--db-ssl-key is needed with --db-ssl-cert.")
fi
if [[ -n "$subnet" ]]; then
    if parse_subnet "$subnet"; then subnet_prefix=$PARSED_PREFIX; subnet="$PARSED_PREFIX.0.0/16"
    else errors+=("--subnet: use the form x.y.0.0/16, e.g. 172.30.0.0/16."); fi
fi
[[ -n "$http_port"  ]] && ! valid_port "$http_port"  && errors+=("--http-port: use a number from 1 to 65535.")
[[ -n "$https_port" ]] && ! valid_port "$https_port" && errors+=("--https-port: use a number from 1 to 65535.")
if [[ -n "$supervisor_port" && "$supervisor_port" != "none" && "$supervisor_port" != "0" ]]; then
    valid_port "$supervisor_port" || errors+=("--supervisor-port: use a number from 1 to 65535, or none.")
fi
if [[ "$ssl_option" == "C" ]]; then
    [[ -n "$certfile"   ]] && { resolve_cert_arg "$certfile"   "$STAGE_DIR/faveolocal.crt"  cert || errors+=("--certfile: not a valid file path or PEM certificate (text or base64)."); }
    [[ -n "$keyfile"    ]] && { resolve_cert_arg "$keyfile"    "$STAGE_DIR/private.key"     key  || errors+=("--keyfile: not a valid file path or PEM private key (text or base64)."); }
    [[ -n "$cacertfile" ]] && { resolve_cert_arg "$cacertfile" "$STAGE_DIR/faveorootCA.crt" cert || errors+=("--cacertfile: not a valid file path or PEM certificate (text or base64)."); }
elif [[ -n "$certfile$keyfile$cacertfile" && -n "$ssl_option" ]]; then
    warn "--certfile / --keyfile / --cacertfile are only used with --ssl paid-ssl; ignoring them."
fi
if ! interactive; then
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
    if [[ "$db_location" == "remote" ]]; then
        [[ -z "$db_host" ]] && errors+=("--db-host is required for a remote database.")
        [[ "$db_admin_pw_given" != "y" ]] && errors+=("--db-admin-password is required for a remote database.")
        [[ "$db_ssl" == "yes" && -z "$db_ssl_ca" ]] && errors+=("--db-ssl-ca is required with --db-ssl yes.")
    fi
fi
if [[ ${#errors[@]} -gt 0 ]]; then
    for e in "${errors[@]}"; do echo -e "${RED}[ERROR]${NC} $e" >&2; done
    echo "" >&2
    echo "Run '$SCRIPT_NAME --help' to see all options." >&2
    exit 1
fi

# All required options on the command line = a complete one-line command:
# run without questions or confirmation, like -y (unless --confirm is given).
if [[ "$assume_yes" != "y" && "$confirm_flag" != "y" && -n "$domainname" && -n "$email" \
      && -n "$license" && -n "$orderno" && -n "$ssl_option" ]] \
   && [[ "$ssl_option" != "C" || ( -n "$certfile" && -n "$keyfile" && -n "$cacertfile" ) ]]; then
    assume_yes="y"
    ONE_LINE_MODE="y"
fi

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
[[ "$show_banner" == "y" ]] && banner
[[ "${ONE_LINE_MODE:-}" == "y" ]] && info "All required options were given - installing without questions (add --confirm to review the summary first)."
collect_attributes
finalize_attributes
choose_install_dir
ask_custom_ports
ask_custom_subnet
resolve_ports
confirm

if [[ "$generate_only" != "y" ]]; then
    prepare_system
    [[ "$db_location" == "remote" ]] && remote_db_check
fi

prepare_install_dir
generate_files
write_credentials

if [[ "$generate_only" == "y" ]]; then
    [[ "$ssl_option" == "C" ]] && ssl_paid
    install_started="n"
    print_summary
    exit 0
fi

[[ "$db_location" == "remote" ]] && remote_db_create
case "$ssl_option" in
    A) ssl_letsencrypt ;;
    B) ssl_selfsigned ;;
    C) ssl_paid ;;
esac
download_faveo
start_stack
install_started="n"          # from here a problem no longer removes the installation
verify_https
[[ "$skip_faveo_setup" != "y" ]] && setup_faveo_app
print_summary
if [[ "$skip_faveo_setup" != "y" && ( "$FAVEO_SETUP_STATUS" != "success" || "$LICENSE_STATUS" != "verified" ) ]]; then
    exit 1
fi
exit 0
