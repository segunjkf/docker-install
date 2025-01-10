# Docker Installation Script

A robust, automated script for installing Docker Engine and Docker Compose on Linux systems. Supports Debian, Ubuntu, Fedora, and RHEL/CentOS distributions.

## Features

- Automatic distribution detection
- Handles repository setup and GPG keys
- Removes conflicting packages
- Retries failed network operations
- Verifies installation success
- Comprehensive error handling
- Supports both Docker Engine and Docker Compose

## Supported Distributions

- Ubuntu 20.04 or later
- Debian 10 or later
- Fedora 35 or later
- RHEL/CentOS 7 or later

## Prerequisites

- Root access or sudo privileges
- Bash shell
- curl
- Basic system utilities (already present on supported distributions)

## Usage

1. Download the script:
```bash
curl -O https://raw.githubusercontent.com/segunjkf/docker-install/main/docker-install.sh
```

2. Make it executable:
```bash
chmod +x install-docker.sh
```

3. Run the script:
```bash
sudo ./install-docker.sh
```

## What the Script Does

1. Checks system requirements
2. Removes conflicting packages
3. Sets up Docker repositories
4. Installs Docker Engine and Docker Compose
5. Configures Docker service
6. Adds user to docker group (if not root)
7. Verifies installation

## Error Handling

- Automatically retries failed network operations
- Creates backups of modified system files
- Provides detailed error messages
- Cleans up on failure
