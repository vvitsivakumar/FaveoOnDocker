#!/usr/bin/env bash

# Colour variables for the script.
red=`tput setaf 1 2>/dev/null`

green=`tput setaf 2 2>/dev/null`

yellow=`tput setaf 11 2>/dev/null`

skyblue=`tput setaf 14 2>/dev/null`

white=`tput setaf 15 2>/dev/null`

reset=`tput sgr0 2>/dev/null`

# Faveo Banner.

echo -e "$skyblue                                                                                                                    $reset"
sleep 0.05
echo -e "$skyblue                                   _______ _______ _     _ _______ _______                                          $reset"
sleep 0.05
echo -e "$skyblue                                  (_______|_______|_)   (_|_______|_______)                                         $reset"
sleep 0.05
echo -e "$skyblue                                   _____   _______ _     _ _____   _     _                                          $reset"
sleep 0.05
echo -e "$skyblue                                  |  ___) |  ___  | |   | |  ___) | |   | |                                         $reset"
sleep 0.05
echo -e "$skyblue                                  | |     | |   | |\ \ / /| |_____| |___| |                                         $reset"
sleep 0.05
echo -e "$skyblue                                  |_|     |_|   |_| \___/ |_______)\_____/                                          $reset"
sleep 0.05
echo -e "$skyblue                                                                                                                    $reset"
sleep 0.05
echo -e "$skyblue                         _     _ _______ _       ______ ______  _______  ______ _     _                            $reset"
sleep 0.05
echo -e "$skyblue                        (_)   (_|_______|_)     (_____ (______)(_______)/ _____|_)   | |                            $reset"
sleep 0.05
echo -e "$skyblue                         _______ _____   _       _____) )     _ _____  ( (____  _____| |                            $reset"
sleep 0.05
echo -e "$skyblue                        |  ___  |  ___) | |     |  ____/ |   | |  ___)  \____ \|  _   _)                            $reset"
sleep 0.05
echo -e "$skyblue                        | |   | | |_____| |_____| |    | |__/ /| |_____ _____) ) |  \ \                             $reset"
sleep 0.05
echo -e "$skyblue                        |_|   |_|_______)_______)_|    |_____/ |_______|______/|_|   \_)                            $reset"
sleep 0.05
echo -e "$skyblue                                                                                                                    $reset"
sleep 0.05
echo -e "$skyblue                                                                                                                    $reset"


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
    install_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)

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

usage() {
    echo "Usage:"
    echo "  ./faveo-community-run.sh -domainname <domain> -email <email> -ssl <A|B|C>"
    echo ""
    echo "Required arguments:"
    echo "  -domainname   Domain name pointing to this server's public IP"
    echo "  -email        Email address used for Let's Encrypt SSL registration"
    echo "  -ssl          SSL option:"
    echo "                  A - Let's Encrypt (Free SSL)"
    echo "                  B - Self-Signed SSL"
    echo "                  C - Paid SSL (you will be prompted for the certificate, key and CA bundle paths)"
    echo ""
    echo "Optional arguments:"
    echo "  -h, --help    Show this help message and exit"
    echo ""
    echo "Example:"
    echo "  ./faveo-community-run.sh -domainname helpdesk.example.com -email admin@example.com -ssl A"
    show_os_help
}

for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        usage
        exit 0
    fi
done

if [[ $# -lt 4 ]]; then
    echo "Please run the script by passing all the required arguments."
    echo "Run './faveo-community-run.sh --help' for usage."
    exit 1;
fi

echo "Checking Prerequisites....."

# ---------------------------------------------------------------------------
# Cross-distro prerequisites.
# Supported: Debian/Ubuntu (apt), RHEL/CentOS/Rocky/Alma/Oracle/Fedora/Amazon
# Linux (dnf/yum), openSUSE/SLES (zypper), Arch/Manjaro (pacman), Alpine (apk), Void (xbps).
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo "This script must be run as root or by a user with sudo privileges."
        exit 1
    fi
else
    SUDO=""
fi

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

# Only install what is missing (avoids e.g. curl vs curl-minimal conflicts on RHEL 9 / Amazon Linux 2023).
missing_pkgs=()
for cmd in unzip curl openssl git; do
    command -v "$cmd" >/dev/null 2>&1 || missing_pkgs+=("$cmd")
done
if ! command -v crontab >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        missing_pkgs+=("cron")
    else
        missing_pkgs+=("cronie")
    fi
fi
# find is used to set file permissions; minimal images (e.g. Rocky 8) lack it.
command -v find >/dev/null 2>&1 || missing_pkgs+=("findutils")
install_packages "${missing_pkgs[@]}"

for cmd in unzip curl openssl git find; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command '$cmd' is not available. Please install it and run the script again."
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Docker Engine + Docker Compose: install for the detected OS only if missing.
# ---------------------------------------------------------------------------
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

if command -v docker >/dev/null 2>&1; then
    echo "Docker is already installed."
else
    install_docker
    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker installation failed. Please install Docker manually (https://docs.docker.com/engine/install/) and run the script again."
        exit 1
    fi
    echo "Docker installed successfully."
fi

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
if command -v docker >/dev/null 2>&1; then
    start_docker_daemon
fi

# Install the Docker Compose plugin if neither "docker compose" nor "docker-compose" is available.
if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    install_compose_plugin
fi
if ! buildx_ok; then
    install_buildx_plugin
fi

# Wait for the Docker daemon to be ready before building or starting anything.
for i in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 1
done
if ! docker info >/dev/null 2>&1; then
    echo "Docker is installed but the Docker daemon is not running, or this user cannot access it."
    echo "Start Docker (for example: sudo systemctl start docker) and run this script again as root or with sudo."
    exit 1
fi

# Docker Compose v2 plugin ("docker compose") or legacy standalone ("docker-compose").
if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker-compose"
else
    DOCKER_COMPOSE="docker compose"
fi

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

# On SELinux-enforcing hosts (RHEL, Rocky, Alma, Fedora, ...) bind-mounted
# directories must be labelled so containers can read/write them.
selinux_label() {
    if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
        echo "SELinux detected, labelling $1 for container access..."
        $SUDO chcon -R -t container_file_t "$1" 2>/dev/null \
            || $SUDO chcon -R -t svirt_sandbox_file_t "$1" 2>/dev/null \
            || echo "Warning: could not set SELinux context on $1"
    fi
}

DockerVersion=$(docker --version)

if [[ $? != 0 ]]; then
echo -e "\n";
echo -e "Docker is not found in this server, Please install Docker and try again."
echo -e "\n";
exit 1;
else 
echo -e "\n";
echo $DockerVersion
echo -e "\n";
fi

DockerComposeVersion=$($DOCKER_COMPOSE version)

if [[ $? != 0 ]]; then
echo -e "\n";
echo -e "Docker Compose is not found in this server please install Docker Compose and try again."
echo -e "\n";
exit 1;
else 
echo -e "\n";
echo $DockerComposeVersion
echo -e "\n";
fi

if [[ $? -eq 0 ]]; then

    echo  -e "\n";
    echo "Prerequisites check completed."
    echo -e "\n";
else
    echo -e "\n";
    echo "Check failed please make sure to execute the script as sudo user and also check your Internet connectivity."
    echo  -e "\n";
    exit 1;
fi


lets() {
    echo "Calling lets() function..."
    if [ ! -d $CUR_DIR/certbot/html ]; then
        mkdir -p $CUR_DIR/certbot/html
    elif [ ! -e $CUR_DIR/certbot/html ]; then
        exit 0;
    fi;

echo "<h1>Obtain SSL Certs</h1>" > $CUR_DIR/certbot/html/index.html

selinux_label "$CUR_DIR/certbot"

echo -e "Initializing Temporary Apache container to obtain SSL Certificates..."

docker run -dti -p 80:80 -v $CUR_DIR/certbot/html:/usr/local/apache2/htdocs --name apache-cert httpd:2.4.33-alpine

if [[ $? -eq 0 ]]; then
    echo "Initializing Certbot Container to obtain SSL Certificates for $domainname"
    docker run -ti --rm -v $CUR_DIR/certbot/letsencrypt/etc/letsencrypt:/etc/letsencrypt -v $CUR_DIR/certbot/html:/data/letsencrypt --name certbot certbot/certbot certonly --webroot --email $email  --agree-tos --non-interactive  --no-eff-email --webroot-path=/data/letsencrypt -d $domainname
else
    echo "Temporary Container Failed to Initialise exiting..."
    exit 1;
fi;

docker rm -f apache-cert

enable_cron_service

crontab -l 2>/dev/null | { cat; echo "45 2 * * 6 docker run --rm -v $CUR_DIR/certbot/letsencrypt/etc/letsencrypt:/etc/letsencrypt -v $CUR_DIR/faveo/public:/data/letsencrypt --name certbot certbot/certbot certonly --webroot --email $email   --agree-tos --non-interactive  --no-eff-email --webroot-path=/data/letsencrypt -d $domainname >/dev/null 2>&1"; } | crontab -

chown -R "$(id -u):$(id -g)" "$CUR_DIR/certbot"

if [[ $? -eq 0 ]]; then
    echo "SSL Certificates for $domainname obtained Successfully."
else
    echo "Permission Issue."
    exit 1;
fi;
}

self() 
{
        echo "Calling self() function..."
        echo "<h1>Obtain SSL Certs</h1>" 

    if [[ $? -eq 0 ]]; then
        echo "Initializing SelfSigned SSL Certificates for $domainname"

        docker build --build-arg CN=$domainname -f dockerfile_selfsign_ssl -t selfsign_ssl .

        docker run -dti -p 8080:80 -p 8443:443 --name selfsign_ssl selfsign_ssl && docker cp selfsign_ssl:/etc/ssl/copy $CUR_DIR/ssl_copy
    else
        echo "Temporary Container Failed to Initialise exiting..."
        exit 1;
    fi;

    docker rm -f selfsign_ssl

    if [[ $? -eq 0 ]]; then
        echo "SSL Certificates for $domainname obtained Successfully."
    else
        echo "Permission Issue."
        exit 1;
    fi;
}

paid() 
{
DIR_NAME="ssl_copy"
if [ -d "$DIR_NAME" ]; then
    echo "Directory '$DIR_NAME' already exists."
else
    mkdir "$DIR_NAME"
    echo "Directory '$DIR_NAME' created successfully."
fi
touch "$DIR_NAME/faveolocal.crt"
touch "$DIR_NAME/private.key"
touch "$DIR_NAME/faveorootCA.crt"

echo "Empty files have been created in '$DIR_NAME':"
echo "$DIR_NAME/faveolocal.crt"
echo "$DIR_NAME/private.key"
echo "$DIR_NAME/faveorootCA.crt"
copy_file_content() {
    local file_desc="$1"
    local dest_file="$2"
    local source_path=""

    while true; do
        echo -n "Enter the path of the $file_desc file: "
        read source_path

        if [ -f "$source_path" ]; then
            cp "$source_path" "$dest_file"
            echo "Content of '$source_path' has been copied to '$dest_file'."
            break
        else
            echo -e "\e[31mError: '$source_path' does not exist. Please check the path and try again.\e[0m"
        fi
    done
}

copy_file_content "certificate.crt" "$DIR_NAME/faveolocal.crt"

copy_file_content "private.key" "$DIR_NAME/private.key"

copy_file_content "ca_bundle.crt" "$DIR_NAME/faveorootCA.crt"

echo "All files have been processed successfully."
}

setup_meilisearch() {
    echo "Setting up MeiliSearch..."

    if [ ! -d "$CUR_DIR/meilisearch/config" ]; then
        mkdir -p "$CUR_DIR/meilisearch/config"
        echo "Created directory: $CUR_DIR/meilisearch/config"
    fi

    MEILI_MASTER_KEY=$(openssl rand -base64 32 | tr -d '\n')

    curl -s https://raw.githubusercontent.com/meilisearch/meilisearch/latest/config.toml -o "$CUR_DIR/meilisearch/config/config.toml"

    sed -i "s|env = .*|env = \"production\"|" "$CUR_DIR/meilisearch/config/config.toml"
    sed -i "s|master_key = .*|master_key = \"$MEILI_MASTER_KEY\"|" "$CUR_DIR/meilisearch/config/config.toml"
    sed -i "s|db_path = .*|db_path = \"/meili_data/data\"|" "$CUR_DIR/meilisearch/config/config.toml"
    sed -i "s|dump_dir = .*|dump_dir = \"/meili_data/dumps\"|" "$CUR_DIR/meilisearch/config/config.toml"
    sed -i "s|snapshot_dir = .*|snapshot_dir = \"/meili_data/snapshots\"|" "$CUR_DIR/meilisearch/config/config.toml"
    
    echo "MeiliSearch setup complete."
}



CUR_DIR=$(pwd)
host_root_dir="faveo"
# Evaluate the arguments
while test $# -gt 0; do
        case "$1" in
                -domainname)
                    shift
                    domainname=$1
                    shift
                    ;;
                -email)
                    shift
                    email=$1
                    shift
                    ;;

                -ssl)
                    shift
                    ssl_option=$1  
                    if [[ "$ssl_option" == "A" || "$ssl_option" == "B" || "$ssl_option" == "C" ]]; then
                        echo -e "\n"
                    else
                        echo "$ssl_option is not a valid SSL option. Please choose A, B, or C."
                        exit 1
                    fi
                    shift
                    ;;
                *)
                echo "$1 is not a recognized flag!"
                exit 1;
                ;;
        esac
done
echo -e "\n";
echo -e "Confirm the Entered Helpdesk details:\n";
echo -e "-------------------------------------\n"

echo "Domain Name : $domainname";
echo "Email: $email";
if [ "$ssl_option" == "A" ]; then
    echo "SSL Option: A - Let's Encrypt SSL"
elif [ "$ssl_option" == "B" ]; then
    echo "SSL Option: B - Self-Sign SSL"
elif [ "$ssl_option" == "C" ]; then
    echo "SSL Option: C - Paid SSL"
else
    echo "Invalid SSL option selected."
fi

echo -e "\n"
echo -e "\n";
read -p "Continue (y/n)?" REPLY

if [[ ! $REPLY =~ ^(yes|y|Yes|YES|Y) ]]; then
        exit 1;
fi;

if [ ! -d $CUR_DIR/certbot/html ]; then
    mkdir -p $CUR_DIR/certbot/html
elif [ ! -e $CUR_DIR/certbot/html ]; then
    exit 0;
fi;

case "$ssl_option" in
    A)
        lets
        ;;
    B)
        self
        ;;
    C)
        paid
        ;;
esac

setup_meilisearch


echo -e "\n";
echo "Downloading Faveo Helpdesk"

git clone --depth 1 https://github.com/ladybirdweb/faveo-helpdesk.git
mv faveo-helpdesk faveo

if [[ $? -eq 0 ]]; then
    echo "Download Successfull";
else
    echo "Download Failed. Please check the order number, serial number of Helpdesk entered and your Internet connectivity."
    exit 1;
fi;

if [ $? -eq 0 ]; then
    chown -R 33:33 $host_root_dir
    find $host_root_dir -type d -exec chmod 755 {} \;
    find $host_root_dir -type f -exec chmod 644 {} \;
    echo "Extracted"
else
    echo "Extract failure."
fi

db_root_pw=$(openssl rand -base64 12)
db_name=faveo
db_user=faveo
db_user_pw=$(openssl rand -base64 12)

if [[ $? -eq 0 ]]; then
    rm -f .env
    cp example.env .env
    sed -i 's:MYSQL_ROOT_PASSWORD=:&'$db_root_pw':' .env
    sed -i 's/MYSQL_DATABASE=/&'$db_name'/' .env
    sed -i 's/MYSQL_USER=/&'$db_user'/' .env
    sed -i 's:MYSQL_PASSWORD=:&'$db_user_pw':' .env
    sed -i 's/DOMAINNAME=/&'$domainname'/' .env
    sed -i '/ServerName/c\    ServerName '$domainname'' ./letsapache/000-default.conf
    sed -i '/ServerName/c\    ServerName '$domainname'' ./apache/000-default.conf  
    
    sed -i 's:domainrewrite:'$domainname':g' ./letsapache/000-default.conf
    sed -i 's:domainrewrite:'$domainname':g' ./apache/000-default.conf
    
    sed -i 's/HOST_ROOT_DIR=/&'$host_root_dir'/' .env
    sed -i 's:CUR_DIR=:&'$PWD':' .env
else
    echo "Database Password Generation Failed"
fi


if [[ $? -eq 0 ]]; then
    docker volume create --name ${domainname}-faveoDB
fi

docker network rm ${domainname}-faveo >/dev/null 2>&1 || true

docker network create ${domainname}-faveo --driver=bridge --subnet=172.24.0.0/16

if [[ $? -eq 0 ]]; then
    echo " Faveo Docker Network ${domainname}-faveo Created"
else
    echo " Faveo Docker Network Creation failed"
    exit 1;
fi


case "$ssl_option" in
    "A")
        echo "You selected Option A: Let's Encrypt SSL"

        sed -i 's|^\( *-\ \).*apache/000-default.conf.*|\1./letsapache/000-default.conf:/etc/apache2/sites-available/000-default.conf|' docker-compose.yml
        sed -i 's|^\( *-\ \).*faveolocal.crt.*|\1${CUR_DIR}/certbot/letsencrypt/etc/letsencrypt/live/${DOMAINNAME}/cert.pem:/var/imported/ssl/cert.pem|' docker-compose.yml
        sed -i 's|^\( *-\ \).*private.key.*|\1${CUR_DIR}/certbot/letsencrypt/etc/letsencrypt/live/${DOMAINNAME}/privkey.pem:/var/imported/ssl/privkey.pem|' docker-compose.yml
        sed -i 's|^\( *-\ \).*faveorootCA.crt.*|\1${CUR_DIR}/certbot/letsencrypt/etc/letsencrypt/live/${DOMAINNAME}/fullchain.pem:/var/imported/ssl/fullchain.pem|' docker-compose.yml
        ;;
    *)
        ;;
esac

echo "Starting Docker Compose..."
selinux_label "$CUR_DIR"

$DOCKER_COMPOSE up -d

if [[ $? -eq 0 ]]; then
    echo -e "\n"
    echo "#########################################################################"
    echo -e "\n"
    echo "Faveo Docker installed successfully. Visit https://$domainname from your browser."
    echo "Please save the following credentials."
    echo "Database Hostname: faveo-mysql"
    echo "Mysql Database root password: $db_root_pw"
    echo "Faveo Helpdesk DB name: $db_name"
    echo "Faveo Helpdesk DB User: $db_user"
    echo "Faveo Helpdesk DB Password: $db_user_pw"
    echo "MeiliSearch Master Key: $MEILI_MASTER_KEY"
    echo -e "\n"
    echo "#########################################################################"


    ###################Credentials File Creation####################
    echo "Faveo Helpdesk Docker Setup Credentials" > credentials.txt
    echo "----------------------------------------" >> credentials.txt
    echo "Faveo Docker installed successfully. Visit https://$domainname from your browser." >> credentials.txt
    echo "Database Hostname: faveo-mysql" >> credentials.txt
    echo "Mysql Database root password: $db_root_pw" >> credentials.txt
    echo "Faveo Helpdesk DB name: $db_name" >> credentials.txt
    echo "Faveo Helpdesk DB User: $db_user" >> credentials.txt
    echo "Faveo Helpdesk DB Password: $db_user_pw" >> credentials.txt
    echo "MeiliSearch Master Key: $MEILI_MASTER_KEY" >> credentials.txt
    echo -e "\n"
    echo "Credentials are saved in the file 'credentials.txt'."
else
    echo "Script Failed unknown error."
    exit 1;
fi
