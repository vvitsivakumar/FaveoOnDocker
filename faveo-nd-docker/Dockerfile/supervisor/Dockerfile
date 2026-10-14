# Use the official Ubuntu base image
FROM ubuntu:24.04

# Set environment variables
ENV TZ=Asia/Kolkata \
    DEBIAN_FRONTEND=noninteractive 

# Define PHP and Node.js versions
ENV PHP_VERSION=8.4 \
    NODE_VERSION=22

### IMPORTANT When you chage the PHP VERSION, make sure to change the ioncube loader version in the RUN command below as well.

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
    nmap \
    arp-scan \
    nbtscan \
    avahi-utils \
    net-tools \
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
    php${PHP_VERSION}-memcached \
    php${PHP_VERSION}-snmp

# Download and install ionCube Loader (x86-64 or aarch64, matching the build host)
RUN extension_dir=$(php -i | grep ^extension_dir | awk '{print $3}') && \
    case "$(dpkg --print-architecture)" in arm64) ioncube_arch=aarch64 ;; *) ioncube_arch=x86-64 ;; esac && \
    curl -fsSL https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_${ioncube_arch}.tar.gz -o ioncube_loaders.tar.gz && \
    tar -xzf ioncube_loaders.tar.gz && \
    mv ioncube/ioncube_loader_lin_${PHP_VERSION}.so "$extension_dir" && \
    sed -i "2 a zend_extension=${extension_dir}/ioncube_loader_lin_${PHP_VERSION}.so" /etc/php/${PHP_VERSION}/cli/php.ini && \
    rm -rf ioncube_loaders.tar.gz ioncube

# Install Node.js
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - && \
    apt-get install -y nodejs

# Copy the entrypoint script into the container
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Configure passwordless sudo for www-data
RUN apt-get update && \
    apt-get install -y sudo && \
    echo "www-data ALL=(ALL) NOPASSWD: /usr/sbin/arp-scan, /usr/bin/nmap" > /etc/sudoers.d/www-data && \
    chmod 0440 /etc/sudoers.d/www-data && \
    visudo -cf /etc/sudoers.d/www-data && \
    rm -rf /var/lib/apt/lists/* 
    
# Make the script executable
RUN chmod +x /usr/local/bin/entrypoint.sh

# Set the working directory
WORKDIR /var/www/html

# Set entrypoint to Supervisor service
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
