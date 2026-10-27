#!/bin/bash

##---------- Author : Thirumoorthi Duraipandi------------------------------------------------##
##---------- Email : thirumoorthi.duraipandi@ladybirdweb.com,thirumoorthi3706@gmail.com------##
##---------- Github page : https://github.com/ladybirdweb/faveo-server-images/---------------##
##---------- Purpose : Auto Install Faveo Helpdesk in a linux system.------------------------##
##---------- Tested on : RHEL 10/9/8, Rocky 10/9/8, Ubuntu 24/22/20 -------------------------##
##---------- Alma Linux 8/9/10, Debian 11/12/13 ---------------------------------------------##
##---------- Updated version : v2.0 (Updated on 17th AUG 2026) ------------------------------##
##-----NOTE: This script requires root privileges, otherwise one could run the script -------##
##---------- as a sudo user who got root privileges. ----------------------------------------##
##-----------USAGE: "sudo /bin/bash faveo-autoscript.sh" ------------------------------------##


# Color variables (ANSI codes with escaped octal for portability)
red='\033[1;31m'
green='\033[1;32m'
yellow='\033[1;33m'
blue='\033[1;34m'
cyan='\033[1;36m'
reset='\033[0m'
bold='\033[1m'


# Get terminal width directly from the shell.
# COLUMNS is preferred when available; otherwise use tput.
if [[ -n "${COLUMNS:-}" && "$COLUMNS" =~ ^[0-9]+$ ]]; then
    TERM_WIDTH=$COLUMNS
else
    TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
fi

# Minimum sane terminal width
(( TERM_WIDTH > 0 )) || TERM_WIDTH=80

# Banner
BANNER=$(cat <<'EOF'
███████╗ █████╗ ██╗   ██╗███████╗ ██████╗
██╔════╝██╔══██╗██║   ██║██╔════╝██╔═══██╗
█████╗  ███████║██║   ██║█████╗  ██║   ██║
██╔══╝  ██╔══██║╚██╗ ██╔╝██╔══╝  ██║   ██║
██║     ██║  ██║ ╚████╔╝ ███████╗╚██████╔╝
╚═╝     ╚═╝  ╚═╝  ╚═══╝  ╚══════╝ ╚═════╝

██╗  ██╗███████╗██╗     ██████╗ ██████╗ ███████╗███████╗██╗  ██╗
██║  ██║██╔════╝██║     ██╔══██╗██╔══██╗██╔════╝██╔════╝██║ ██╔╝
███████║█████╗  ██║     ██████╔╝██║  ██║█████╗  ███████╗█████╔╝
██╔══██║██╔══╝  ██║     ██╔═══╝ ██║  ██║██╔══╝  ╚════██║██╔═██╗
██║  ██║███████╗███████╗██║     ██████╔╝███████╗███████║██║  ██╗
╚═╝  ╚═╝╚══════╝╚══════╝╚═╝     ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝
EOF
)

# Find the widest line using Bash only.
BANNER_WIDTH=0

while IFS= read -r LINE; do
    LINE_WIDTH=${#LINE}

    if (( LINE_WIDTH > BANNER_WIDTH )); then
        BANNER_WIDTH=$LINE_WIDTH
    fi
done <<< "$BANNER"

# Calculate ONE padding value for the entire banner.
if (( TERM_WIDTH > BANNER_WIDTH )); then
    PADDING=$(( (TERM_WIDTH - BANNER_WIDTH) / 2 ))
else
    PADDING=0
fi

# Create indentation using Bash printf.
INDENT=$(printf '%*s' "$PADDING" '')

# Print banner.
printf '%b\n' "${cyan}${bold}"

while IFS= read -r LINE; do
    printf '%s%s\n' "$INDENT" "$LINE"
done <<< "$BANNER"

printf '%b\n' "${reset}"


# Detect scripts invoked through a non-Bash shell.
# IMPORTANT: do not grep the executable path for "sh" because /bin/bash
# itself contains the string "sh" and would incorrectly trigger this check.
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo -e "${red}This installer needs to be run with 'bash' not 'sh', try again with bash.${reset}"
    exit 1
fi

# Checking for the Super User.
if [[ $EUID -ne 0 ]]; then
    echo -e "${red}This script must be run as root, try again with sudo or root user.${reset}"
    exit 1
fi

###################################################### End of Banner ####################################################################


######################################################## End of OS Validation ###########################################################
##################################################### BACKUP ############################################################
# sudo bash faveo.sh --backup [--backup-dir <path>]
# Backs up the Faveo files (/var/www/faveo) and the Faveo database into <path>
# (default /var/www/faveo-bkps):  fs-<date-time>.tar.gz  and  db-<date-time>.sql.gz
# The database details are read from credentials.txt written by the installation
# (values missing there are taken from /var/www/faveo/.env).
# Nothing is stopped or changed; the database is read with --single-transaction.
FAVEO_DIR="/var/www/faveo"
DEFAULT_BACKUP_DIR="/var/www/faveo-bkps"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# credentials.txt of the installation: next to Faveo, or where the installer ran.
find_credentials_file() {
    local f
    for f in "$FAVEO_DIR/credentials.txt" "$SCRIPT_DIR/credentials.txt" "$PWD/credentials.txt"; do
        [[ -f "$f" ]] && grep -q '^Database Password:' "$f" && { printf '%s' "$f"; return 0; }
    done
    return 1
}

# Value of "Key: value" in credentials.txt.
cred_value() {
    [[ -n "$CRED_FILE" ]] || return 0
    grep -m1 "^$1: " "$CRED_FILE" 2>/dev/null | sed "s/^$1: //" | tr -d '\r'
}

# Value of KEY in Faveo's .env, without surrounding quotes.
faveo_env_value() {
    local v
    v=$(grep -m1 "^$1=" "$FAVEO_DIR/.env" 2>/dev/null | cut -d= -f2-)
    v="${v%$'\r'}"; v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
    printf '%s' "$v"
}

# First existing file named by a .env key that ends in the given suffix (SSL_CA, SSL_CERT, SSL_KEY).
faveo_env_ssl_file() {
    local key val
    for key in $(grep -oE "^[A-Z0-9_]*$1=" "$FAVEO_DIR/.env" 2>/dev/null | tr -d '='); do
        val=$(faveo_env_value "$key")
        [[ -n "$val" && -f "$val" ]] && { printf '%s' "$val"; return 0; }
    done
    return 1
}

backup_standalone() {
    local backup_dir="" ts fs_file db_file dump host port name user pass ca cert key need=0 avail kb _
    local args=() root_ok="n"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backup)       shift ;;
            --backup-dir)   [[ -n "$2" ]] || { echo -e "${red}--backup-dir needs a path.${reset}"; return 1; }
                            backup_dir="$2"; shift 2 ;;
            --backup-dir=*) backup_dir="${1#*=}"; shift ;;
            *) echo -e "${red}Unknown option for --backup: $1 (only --backup-dir <path> can be given).${reset}"; return 1 ;;
        esac
    done

    [[ -f "$FAVEO_DIR/artisan" ]] \
        || { echo -e "${red}No Faveo installation found in $FAVEO_DIR.${reset}"; return 1; }
    CRED_FILE=$(find_credentials_file) || CRED_FILE=""

    if [[ -z "$backup_dir" ]]; then
        if [[ -t 0 ]]; then
            read -r -p "$(echo -e "${yellow} Backup folder [default: $DEFAULT_BACKUP_DIR]: ${reset}")" backup_dir
        fi
        backup_dir="${backup_dir:-$DEFAULT_BACKUP_DIR}"
    fi
    [[ "$backup_dir" == /* ]] || backup_dir="$PWD/$backup_dir"
    backup_dir="${backup_dir%/}"
    case "$backup_dir/" in
        "$FAVEO_DIR"/*) echo -e "${red}The backup folder must be outside $FAVEO_DIR.${reset}"; return 1 ;;
    esac
    mkdir -p "$backup_dir" && chmod 700 "$backup_dir" \
        || { echo -e "${red}Cannot create the backup folder $backup_dir.${reset}"; return 1; }

    # Free space: about the size of the Faveo folder (compressed archives are smaller).
    read -r kb _ < <(du -sk "$FAVEO_DIR" 2>/dev/null); need=${kb:-0}
    read -r _ _ _ avail _ < <(df -Pk "$backup_dir" 2>/dev/null | tail -1)
    if [[ "$avail" =~ ^[0-9]+$ ]] && (( need > avail )); then
        echo -e "${red}Not enough free space in $backup_dir (need about $((need / 1024)) MB, free $((avail / 1024)) MB). Use --backup-dir.${reset}"
        return 1
    fi

    ts=$(date +%Y-%m-%d_%H-%M-%S)
    fs_file="$backup_dir/fs-$ts.tar.gz"
    db_file="$backup_dir/db-$ts.sql.gz"

    host=$(cred_value "Database Host");     [[ -n "$host" ]] || host=$(faveo_env_value DB_HOST)
    port=$(cred_value "Database Port");     [[ -n "$port" ]] || port=$(faveo_env_value DB_PORT)
    name=$(cred_value "Database Name");     [[ -n "$name" ]] || name=$(faveo_env_value DB_DATABASE)
    user=$(cred_value "Database Username"); [[ -n "$user" ]] || user=$(faveo_env_value DB_USERNAME)
    pass=$(cred_value "Database Password"); [[ -n "$pass" ]] || pass=$(faveo_env_value DB_PASSWORD)
    [[ -n "$name" && -n "$user" ]] \
        || { echo -e "${red}The database name / user were not found in credentials.txt or $FAVEO_DIR/.env.${reset}"; return 1; }
    host=${host:-127.0.0.1}; port=${port:-3306}

    if command -v mysqldump >/dev/null 2>&1; then dump=mysqldump
    elif command -v mariadb-dump >/dev/null 2>&1; then dump=mariadb-dump
    else echo -e "${red}mysqldump / mariadb-dump is not installed.${reset}"; return 1
    fi

    echo -e "\n${cyan}${bold} Backing up Faveo ($FAVEO_DIR)${reset}"
    echo -e "${yellow} Backup folder: $backup_dir${reset}"
    if [[ -n "$CRED_FILE" ]]; then
        echo -e "${yellow} Database details from: $CRED_FILE${reset}"
    else
        echo -e "${yellow} credentials.txt not found - database details from $FAVEO_DIR/.env${reset}"
    fi

    # Database. On the local database server root (socket login) is used, so routines and
    # events are included; otherwise the Faveo database user from .env.
    if [[ "$host" =~ ^(localhost|127\.0\.0\.1|::1)$ ]] && mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
        root_ok="y"
        args=(-u root --single-transaction --quick --routines --triggers --events --databases "$name")
    else
        [[ "$host" == "localhost" || "$host" == "::1" ]] && host="127.0.0.1"
        args=(-h "$host" -P "$port" -u "$user" --single-transaction --quick --no-tablespaces --triggers)
        ca=$(cred_value "Database SSL CA"); cert=$(cred_value "Database SSL Cert"); key=$(cred_value "Database SSL Key")
        [[ -n "$ca" && -f "$ca" ]] || ca=$(faveo_env_ssl_file SSL_CA) || ca=""
        if [[ -n "$ca" ]]; then
            args+=(--ssl-ca="$ca")
            [[ -n "$cert" && -f "$cert" ]] || cert=$(faveo_env_ssl_file SSL_CERT) || cert=""
            [[ -n "$key"  && -f "$key"  ]] || key=$(faveo_env_ssl_file SSL_KEY)   || key=""
            [[ -n "$cert" && -n "$key" ]] && args+=(--ssl-cert="$cert" --ssl-key="$key")
        fi
        args+=(--databases "$name")
    fi
    echo -e "${yellow} Dumping database '$name' ($([[ "$root_ok" == "y" ]] && echo "local server, root" || echo "$host:$port, user $user"))...${reset}"
    if [[ "$root_ok" == "y" ]]; then
        "$dump" "${args[@]}" 2>"$db_file.err" | gzip > "$db_file"
    else
        MYSQL_PWD="$pass" "$dump" "${args[@]}" 2>"$db_file.err" | gzip > "$db_file"
    fi
    if ! gzip -dc "$db_file" 2>/dev/null | tail -n 1 | grep -q "Dump completed"; then
        echo -e "${red}Database backup failed: $(grep -v 'Using a password' "$db_file.err" 2>/dev/null | tail -1)${reset}"
        rm -f "$db_file" "$db_file.err"
        return 1
    fi
    rm -f "$db_file.err"; chmod 600 "$db_file"
    echo -e "${green} Database : $db_file ($(du -sh "$db_file" | cut -f1))${reset}"

    # Files
    echo -e "${yellow} Archiving the files in $FAVEO_DIR...${reset}"
    if ! tar -czf "$fs_file" -C "$(dirname "$FAVEO_DIR")" "$(basename "$FAVEO_DIR")"; then
        echo -e "${red}File backup failed. The database backup is kept: $db_file${reset}"
        rm -f "$fs_file"
        return 1
    fi
    chmod 600 "$fs_file"
    echo -e "${green} Files    : $fs_file ($(du -sh "$fs_file" | cut -f1))${reset}"

    echo -e "\n${green}${bold} Backup completed.${reset}"
    echo    "  Restore the files    : tar -xzf $fs_file -C $(dirname "$FAVEO_DIR")"
    echo    "  Restore the database : gunzip < $db_file | mysql -u root"
    return 0
}

for _arg in "$@"; do
    if [[ "$_arg" == "--backup" ]]; then
        backup_standalone "$@"
        exit $?
    fi
done
################################################## End of BACKUP ########################################################

os_check() {
    echo -e "\n$yellow Checking OS compatibility for Faveo Helpdesk... $reset"
    sleep 0.05

    # Detect OS
    if [[ -e /etc/os-release ]]; then
        source /etc/os-release
        os_name=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
        os_version_id=$(echo "$VERSION_ID" | tr -d '"')
        Os_Version="$PRETTY_NAME"
    elif [[ -e /etc/debian_version ]]; then
        os_name="debian"
        os_version_id=$(cat /etc/debian_version | cut -d'.' -f1)
        Os_Version="Debian $(cat /etc/debian_version)"
    else
        echo -e "${red}Unsupported Linux distribution. Supported: Ubuntu 20/22/24, Debian 11/12, RHEL 8/9.${reset}"
        exit 1
    fi

    echo -e "[Detected OS] : $green $Os_Version $reset"
    sleep 0.05

    # Supported versions (Update when needed)
    declare -A supported_versions
    supported_versions=(
        [ubuntu]="22.04 24.04 26.04"
        [debian]="11 12"
        [rhel]="8 9 10"
        [rocky]="8 9 10"
        [almalinux]="8 9 10"
    )

    # Check if OS is supported
    if [[ -z "${supported_versions[$os_name]}" ]]; then
        echo -e "${red}Unsupported Linux distribution: $os_name.${reset}"
        exit 1
    fi

    # Check if OS version is supported
    supported=false
    for ver in ${supported_versions[$os_name]}; do
        if [[ "$os_version_id" == "$ver"* ]]; then
            supported=true
            break
        fi
    done

    if ! $supported; then
        echo -e "${red}This $os_name version ($Os_Version) is unsupported. Supported versions: ${supported_versions[$os_name]}.${reset}"
        exit 1
    fi

    echo -e "Faveo Helpdesk Compatibility Check: $green [OK] $reset"
    sleep 0.05

    # Call OS-specific installer scripts from the same folder
    case "$os_name" in
        ubuntu|debian)
            if [[ -f "./debian_block.sh" ]]; then
                bash ./debian_block.sh "$@"
            else
                echo -e "${red}Debian installer script not found!${reset}"
                exit 1
            fi
            ;;
        rhel|rocky|almalinux|centos)
            if [[ -f "./rhel_block.sh" ]]; then
                bash ./rhel_block.sh "$@"
            else
                echo -e "${red}RHEL installer script not found!${reset}"
                exit 1
            fi
            ;;
    esac
}

os_check "$@"

##################################################### OS CHECK ########################################################
