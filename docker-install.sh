#!/bin/bash
set -eux

# Error handling
handle_error() {
    local exit_code=$1
    local line_number=$2
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Error occurred in script at line ${line_number}, exit code ${exit_code}"
    exit "${exit_code}"
}

trap 'handle_error $? $LINENO' ERR

# Basic logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Retry mechanism for commands
retry_command() {
    local -r cmd="${1}"
    local -r timeout="${2:-10m}"  # Default timeout 10 minutes
    local -r sleep_time="${3:-10}"  # Default sleep 10 seconds
    
    timeout "${timeout}" bash -c "until ${cmd}; do echo 'Command failed, retrying in ${sleep_time} seconds...'; sleep ${sleep_time}; done"
}

# Check if a package is installed (DNF systems)
is_package_installed_dnf() {
    if dnf list installed "$1" &>/dev/null; then
        return 0
    fi
    return 1
}

# Check if a package is installed (APT systems)
is_package_installed_apt() {
    if dpkg -l "$1" 2>/dev/null | grep -q '^ii'; then
        return 0
    fi
    return 1
}

# Check if Docker service is configured and running
check_docker_service() {
    if systemctl is-active docker &>/dev/null; then
        if systemctl is-enabled docker &>/dev/null; then
            log "Docker service is already configured and running"
            return 0
        fi
    fi
    return 1
}

# Check Docker installation
check_docker() {
    if ! command -v docker &> /dev/null || ! docker compose version &> /dev/null; then
        log "Docker or Docker Compose is not installed. Proceeding with installation..."
        return 1
    fi
    
    # Check Docker version
    DOCKER_VERSION=$(docker --version | awk '{ gsub(/,/, "", $3); print $3 }')
    DOCKER_MAJOR_VERSION=$(docker --version | awk '{ split($3, version, "."); print version[1]; }')
    
    if [ "${DOCKER_MAJOR_VERSION}" -lt 23 ]; then
        log "Docker ${DOCKER_VERSION} detected. This version is no longer supported. Will update."
        return 1
    fi
    
    log "Docker ${DOCKER_VERSION} is already installed and properly configured"
    return 0
}

# Check if user can use sudo
check_sudo() {
    if [ "${EUID}" -eq 0 ]; then
        return 0
    fi
    
    if groups | grep -q '\bsudo\b' || groups | grep -q '\badmin\b'; then
        return 0
    fi
    return 1
}

# Cleanup handler
cleanup() {
    log "Cleaning up temporary files..."
    # Add specific cleanup tasks here
}

# Set up cleanup trap
trap cleanup EXIT

fix_repository_issues() {
    local temp_error=$(mktemp)
    local sources_dir="/etc/apt/sources.list.d"
    local main_list="/etc/apt/sources.list"
    local backup_dir="/etc/apt/sources.backup-$(date +%Y%m%d-%H%M%S)"
    
    log "Checking and fixing repository issues..."
    
    # Create backup
    mkdir -p "$backup_dir"
    cp $main_list "$backup_dir/"
    cp -r $sources_dir/* "$backup_dir/" 2>/dev/null || true
    
    # Attempt update and capture errors
    apt-get update &> "$temp_error"
    
    # If there are Release file issues
    if grep -q "does not have a Release file" "$temp_error"; then
        log "Found repositories with missing Release files"
        
        # Process each problem repository
        find "$sources_dir" -name "*.list" | while read -r list_file; do
            if [ -f "${list_file}" ] && grep -q "$(grep -o 'https\?://[^ ]*' "$temp_error")" "${list_file}" 2>/dev/null; then
                log "Disabling problematic repository: ${list_file}"
                mv "${list_file}" "${list_file}.disabled"
            fi
        done
        
        # Update base repositories based on distribution
        if [ -f /etc/debian_version ]; then
            log "Configuring Debian repositories"
            tee $main_list > /dev/null << EOF
deb http://deb.debian.org/debian $(lsb_release -cs) main contrib non-free
deb http://deb.debian.org/debian-security/ $(lsb_release -cs)-security main contrib non-free
deb http://deb.debian.org/debian $(lsb_release -cs)-updates main contrib non-free
EOF
        else
            log "Configuring Ubuntu repositories"
            local ubuntu_codename=$(lsb_release -cs)
            tee $main_list > /dev/null << EOF
deb http://archive.ubuntu.com/ubuntu/ ${ubuntu_codename} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${ubuntu_codename}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${ubuntu_codename}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${ubuntu_codename}-security main restricted universe multiverse
EOF
        fi
        
        # Clean and update
        rm -rf /var/lib/apt/lists/*
        apt-get clean
        retry_command "apt-get update"
    fi
    
    rm -f "$temp_error"
}

# Check Docker repository for Debian/Ubuntu
check_docker_repo_debian() {
    if [ -f "/etc/apt/keyrings/docker.gpg" ] && [ -f "/etc/apt/sources.list.d/docker.list" ]; then
        log "Docker repository files exist, checking configuration..."
        
        # Verify repository content
        if grep -q "download.docker.com/linux/$(. /etc/os-release && echo "$ID")" "/etc/apt/sources.list.d/docker.list"; then
            if [ -s "/etc/apt/keyrings/docker.gpg" ]; then
                log "Docker repository is properly configured"
                return 0
            else
                log "Docker GPG key appears to be empty or corrupted"
            fi
        else
            log "Docker repository configuration appears incorrect"
        fi
    fi
    log "Docker repository needs to be configured"
    return 1
}

# Check Docker repository for Fedora
check_docker_repo_fedora() {
    if [ -f "/etc/yum.repos.d/docker-ce.repo" ]; then
        log "Docker repository file exists, checking configuration..."
        
        # Verify repository content
        if grep -q "download.docker.com/linux/fedora" "/etc/yum.repos.d/docker-ce.repo"; then
            if grep -q "enabled=1" "/etc/yum.repos.d/docker-ce.repo"; then
                log "Docker repository is properly configured"
                return 0
            else
                log "Docker repository is disabled"
            fi
        else
            log "Docker repository configuration appears incorrect"
        fi
    fi
    log "Docker repository needs to be configured"
    return 1
}

# Check Docker repository for RHEL/CentOS
check_docker_repo_rhel() {
    if [ -f "/etc/yum.repos.d/docker-ce.repo" ]; then
        log "Docker repository file exists, checking configuration..."
        
        # Verify repository content
        if grep -q "download.docker.com/linux/centos" "/etc/yum.repos.d/docker-ce.repo"; then
            if grep -q "enabled=1" "/etc/yum.repos.d/docker-ce.repo"; then
                log "Docker repository is properly configured"
                return 0
            else
                log "Docker repository is disabled"
            fi
        else
            log "Docker repository configuration appears incorrect"
        fi
    fi
    log "Docker repository needs to be configured"
    return 1
}

# Configure Docker repository for Fedora
configure_docker_repo_fedora() {
    log "Configuring Docker repository for Fedora..."
    tee /etc/yum.repos.d/docker-ce.repo <<EOF
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=https://download.docker.com/linux/fedora/\$releasever/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/fedora/gpg
EOF
    
    # Verify configuration
    if ! check_docker_repo_fedora; then
        log "Error: Failed to configure Docker repository"
        return 1
    fi
    return 0
}

# Configure Docker repository for RHEL/CentOS
configure_docker_repo_rhel() {
    log "Configuring Docker repository for RHEL/CentOS..."
    retry_command "dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo"
    
    # Verify configuration
    if ! check_docker_repo_rhel; then
        log "Error: Failed to configure Docker repository"
        return 1
    fi
    return 0
}

# Configure Docker repository for Debian/Ubuntu
configure_docker_repo_debian() {
    log "Configuring Docker repository for $(. /etc/os-release && echo "$ID")..."
    
    # Set up directory for GPG key
    install -m 0755 -d /etc/apt/keyrings
    
    # Download and install GPG key with retry
    retry_command "curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Add repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Update package list with retry
    retry_command "apt-get update"
    
    # Verify configuration
    if ! check_docker_repo_debian; then
        log "Error: Failed to configure Docker repository"
        return 1
    fi
    return 0
}

install_docker_ubuntu_debian() {
    log "Installing Docker on Ubuntu/Debian"
    
    # First fix any repository issues
    fix_repository_issues
    
    # Remove conflicting packages only if they exist
    local packages_to_remove=(
        docker.io
        docker-engine
        docker
        docker-doc
        docker-compose
        docker-compose-v2
        podman-docker
        containerd
        runc
    )
    
    local found_conflicting=false
    for pkg in "${packages_to_remove[@]}"; do
        if is_package_installed_apt "$pkg"; then
            found_conflicting=true
            log "Found conflicting package: $pkg"
        fi
    done
    
    if [ "$found_conflicting" = true ]; then
        log "Removing conflicting packages..."
        retry_command "apt-get remove -y ${packages_to_remove[*]}"
    fi
    
    # Install prerequisites
    local prerequisites=(
        ca-certificates
        curl
        gnupg
        apt-transport-https
        software-properties-common
    )
    
    log "Updating package lists..."
    retry_command "apt-get update"
    
    local need_prereq=false
    for pkg in "${prerequisites[@]}"; do
        if ! is_package_installed_apt "$pkg"; then
            need_prereq=true
            break
        fi
    done
    
    if [ "$need_prereq" = true ]; then
        log "Installing prerequisites..."
        retry_command "apt-get install -y ${prerequisites[*]}"
    fi
    
    # Configure Docker repository if needed
    if ! check_docker_repo_debian; then
        configure_docker_repo_debian
    fi
    
    # Install Docker packages
    local docker_packages=(
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
    )
    
    local need_install=false
    for pkg in "${docker_packages[@]}"; do
        if ! is_package_installed_apt "$pkg"; then
            need_install=true
            log "Need to install: $pkg"
        fi
    done
    
    if [ "$need_install" = true ]; then
        log "Installing Docker packages..."
        retry_command "apt-get install -y ${docker_packages[*]}"
    fi
    
    # Verify and configure Docker service
    if ! check_docker_service; then
        log "Configuring Docker service..."
        systemctl enable docker
        systemctl start docker
    fi
    
    # Verify installation
    if ! command -v docker >/dev/null 2>&1; then
        log "Error: Docker installation failed"
        return 1
    fi
    
    log "Docker installation successful"
    return 0
}

# Install Docker and Docker Compose on Fedora
install_docker_fedora() {
    log "Installing Docker on Fedora"
    
    # Remove conflicting packages only if they exist
    local packages_to_remove=(
        docker
        docker-client
        docker-client-latest
        docker-common
        docker-latest
        docker-latest-logrotate
        docker-logrotate
        docker-selinux
        docker-engine-selinux
        docker-engine
        podman
    )
    
    local found_conflicting=false
    for pkg in "${packages_to_remove[@]}"; do
        if is_package_installed_dnf "$pkg"; then
            found_conflicting=true
            log "Found conflicting package: $pkg"
        fi
    done
    
    if [ "$found_conflicting" = true ]; then
        log "Removing conflicting packages..."
        retry_command "dnf -y remove ${packages_to_remove[*]}"
    fi
    
    # Install dnf-plugins-core if needed
    if ! is_package_installed_dnf "dnf-plugins-core"; then
        log "Installing dnf-plugins-core..."
        retry_command "dnf -y install dnf-plugins-core"
    fi
    
    # Configure Docker repository if needed
    if ! check_docker_repo_fedora; then
        configure_docker_repo_fedora
    fi
    
    # Install Docker packages
    local docker_packages=(
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
    )
    
    local need_install=false
    for pkg in "${docker_packages[@]}"; do
        if ! is_package_installed_dnf "$pkg"; then
            need_install=true
            log "Need to install: $pkg"
        fi
    done
    
    if [ "$need_install" = true ]; then
        log "Installing Docker packages..."
        retry_command "dnf -y install ${docker_packages[*]}"
    fi
    
    # Configure Docker service if needed
    if ! check_docker_service; then
        log "Configuring Docker service..."
        systemctl enable docker
        systemctl start docker
    fi
    
    # Verify installation
    if ! command -v docker >/dev/null 2>&1; then
        log "Error: Docker installation failed"
        return 1
    fi
    
    log "Docker installation successful"
    return 0
}

# Install Docker and Docker Compose on RHEL/CentOS
install_docker_rhel() {
    log "Installing Docker on RHEL/CentOS"
    
    # Remove conflicting packages only if they exist
    local packages_to_remove=(
        docker
        docker-client
        docker-client-latest
        docker-common
        docker-latest
        docker-latest-logrotate
        docker-logrotate
        docker-engine
        podman
        runc
    )
    
    local found_conflicting=false
    for pkg in "${packages_to_remove[@]}"; do
        if is_package_installed_dnf "$pkg"; then
            found_conflicting=true
            log "Found conflicting package: $pkg"
        fi
    done
    
    if [ "$found_conflicting" = true ]; then
        log "Removing conflicting packages..."
        retry_command "dnf -y remove ${packages_to_remove[*]}"
    fi
    
    # Install dnf-plugins-core if needed
    if ! is_package_installed_dnf "dnf-plugins-core"; then
        log "Installing dnf-plugins-core..."
        retry_command "dnf -y install dnf-plugins-core"
    fi
    
    # Configure Docker repository if needed
    if ! check_docker_repo_rhel; then
        configure_docker_repo_rhel
    fi
    
    # Install Docker packages
    local docker_packages=(
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
    )
    
    local need_install=false
    for pkg in "${docker_packages[@]}"; do
        if ! is_package_installed_dnf "$pkg"; then
            need_install=true
            log "Need to install: $pkg"
        fi
    done
    
    if [ "$need_install" = true ]; then
        log "Installing Docker packages..."
        retry_command "dnf -y install ${docker_packages[*]}"
    fi
    
    # Configure Docker service if needed
    if ! check_docker_service; then
        log "Configuring Docker service..."
        systemctl enable docker
        systemctl start docker
    fi
    
    # Verify installation
    if ! command -v docker >/dev/null 2>&1; then
        log "Error: Docker installation failed"
        return 1
    fi
    
    log "Docker installation successful"
    return 0
}

get_distribution() {
    local distro=""
    if [ -f /etc/os-release ]; then
        # Source the os-release file
        . /etc/os-release
        distro=$ID
    elif [ -f /etc/debian_version ]; then
        distro="debian"
    elif [ -f /etc/fedora-release ]; then
        distro="fedora"
    elif [ -f /etc/redhat-release ]; then
        if grep -q "CentOS" /etc/redhat-release; then
            distro="centos"
        else
            distro="rhel"
        fi
    fi
    echo "$distro"
}

# Get OS version
get_version() {
    local version=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        version=$VERSION_ID
    elif [ -f /etc/debian_version ]; then
        version=$(cat /etc/debian_version)
    elif [ -f /etc/fedora-release ]; then
        version=$(grep -oE '[0-9]+' /etc/fedora-release)
    elif [ -f /etc/redhat-release ]; then
        version=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | cut -d. -f1)
    fi
    echo "$version"
}

# Verify minimum version requirements
check_version_requirements() {
    local distro=$1
    local version=$2
    
    case "$distro" in
        ubuntu)
            if [ "${version%.*}" -lt 20 ]; then
                log "Error: Ubuntu version $version is not supported. Minimum required version is 20.04"
                return 1
            fi
            ;;
        debian)
            if [ "${version%.*}" -lt 10 ]; then
                log "Error: Debian version $version is not supported. Minimum required version is 10"
                return 1
            fi
            ;;
        fedora)
            if [ "$version" -lt 35 ]; then
                log "Error: Fedora version $version is not supported. Minimum required version is 35"
                return 1
            fi
            ;;
        centos|rhel)
            if [ "$version" -lt 7 ]; then
                log "Error: RHEL/CentOS version $version is not supported. Minimum required version is 7"
                return 1
            fi
            ;;
    esac
    return 0
}

# Main installation logic
main() {
    local distro
    local version
    
    # Check if script is run as root
    if [ "$EUID" -ne 0 ]; then
        if ! check_sudo; then
            log "Error: This script must be run as root or with sudo privileges"
            exit 1
        fi
    fi
    
    # Detect OS distribution and version
    distro=$(get_distribution)
    version=$(get_version)
    
    if [ -z "$distro" ]; then
        log "Error: Unable to detect Linux distribution"
        exit 1
    fi
    
    log "Detected distribution: $distro version $version"
    
    # Check version requirements
    if ! check_version_requirements "$distro" "$version"; then
        exit 1
    fi
    
    # Check if Docker is already installed properly
    if check_docker; then
        log "Docker is already installed and properly configured"
        docker --version
        docker compose version
        exit 0
    fi
    
    # Perform installation based on distribution
    case "$distro" in
        ubuntu|debian)
            if ! install_docker_ubuntu_debian; then
                log "Error: Docker installation failed on $distro"
                exit 1
            fi
            ;;
        fedora)
            if ! install_docker_fedora; then
                log "Error: Docker installation failed on Fedora"
                exit 1
            fi
            ;;
        centos|rhel)
            if ! install_docker_rhel; then
                log "Error: Docker installation failed on RHEL/CentOS"
                exit 1
            fi
            ;;
        *)
            log "Error: Unsupported distribution: $distro"
            exit 1
            ;;
    esac
    
    # Final verification
    if command -v docker >/dev/null 2>&1; then
        log "Docker installation completed successfully"
        log "Docker version: $(docker --version)"
        log "Docker Compose version: $(docker compose version)"
        
        # Add current user to docker group if not root
        if [ "$EUID" -ne 0 ]; then
            local current_user=${SUDO_USER:-$USER}
            if ! groups "$current_user" | grep -q docker; then
                log "Adding user $current_user to docker group..."
                usermod -aG docker "$current_user"
                log "Please log out and back in for the group changes to take effect"
            fi
        fi
        
        log "Installation completed successfully"
        exit 0
    else
        log "Error: Docker installation verification failed"
        exit 1
    fi
}

# Set strict error handling
set -euo pipefail

# Execute main function with error handling
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    trap 'handle_error $? $LINENO' ERR
    trap cleanup EXIT
    main "$@"
fi

