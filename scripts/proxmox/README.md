# Proxmox VE Scripts

This directory contains shell scripts for managing and automating Proxmox VE environments.

## Scripts Overview

### pve-init.sh

A post-installation script for configuring a fresh Proxmox VE installation inspired by [Proxmox VE Helper-Scripts](https://community-scripts.github.io/ProxmoxVE/).

**What it does:**

- Updates APT sources to use community repositories (removes enterprise repos)
- Disables firmware warnings for non-free packages
- Removes subscription warning messages from both Web UI and Mobile UI
- Performs a full system upgrade
- Automatically reboots the system

**Usage:**

```bash
# Run as root on a fresh Proxmox VE installation
./pve-init.sh
```

**Note:** The script will automatically reboot the system after completion.

---

### pve-template.sh

A comprehensive script for creating Proxmox VE VM templates from cloud images (Ubuntu, Debian, Fedora, etc.).

**What it does:**

- Downloads cloud images from specified URLs
- Creates and configures VMs with customizable hardware settings
- Sets up Cloud-Init for automated provisioning
- Configures localization (timezone, keyboard, locale)
- Installs packages and configures SSH access
- Converts the VM to a reusable template

**Syntax:**

```bash
./pve-template.sh <cloud-image-url> <id> <name> [OPTIONS]
```

**Required Arguments:**

- `cloud-image-url` - URL to the cloud image (e.g., Ubuntu cloud image)
- `id` - Unique VM ID number (e.g., 9000)
- `name` - Template name (e.g., ubuntu-2404-template)

**Common Options:**

| Option                         | Description                                   | Default                |
| ------------------------------ | --------------------------------------------- | ---------------------- |
| `--user <user>`                | Cloud-init username                           | (none)                 |
| `--password <password>`        | Cloud-init password                           | (none)                 |
| `--ssh-keys <file>`            | Path to SSH public keys file                  | (none)                 |
| `--disk-storage <storage>`     | Proxmox storage for VM disk                   | local-lvm              |
| `--snippets-storage <storage>` | Storage for cloud-init snippets               | same as --disk-storage |
| `--disk-size <size>`           | Disk size (e.g., 32G, 50G)                    | (image default)        |
| `--disk-format <format>`       | Disk format: qcow2, raw, vmdk                 | qcow2                  |
| `--disk-flags <flags>`         | Space-separated disk flags (e.g., discard=on) | discard=on             |
| `--memory <mb>`                | Memory in MB                                  | 2048                   |
| `--cores <num>`                | Number of CPU cores                           | 4                      |
| `--bridge <bridge>`            | Network bridge                                | vmbr0                  |
| `--timezone <timezone>`        | Timezone (e.g., America/New_York)             | (none)                 |
| `--keyboard <layout>`          | Keyboard layout (e.g., us, de, fr)            | (none)                 |
| `--keyboard-variant <variant>` | Keyboard variant (e.g., intl)                 | (none)                 |
| `--locale <locale>`            | Locale (e.g., en_US.UTF-8)                    | (none)                 |
| `--display <type>`             | Set the display/vga type                      | std                    |
| `--install <packages>`         | Space-separated packages to install           | (none)                 |
| `--dns-servers <servers>`      | Space-separated DNS servers                   | (none)                 |
| `--domain-names <domains>`     | Space-separated domain names for DNS search   | (none)                 |
| `--patches <patches>`          | Space-separated patch names to apply          | (none)                 |

**Patches:**

- Use the `--patches` option to apply one or more "fixes" to the template.
- Some patches are automatically applied based on the detected distro (e.g., `debian_locale`, `debian_keyboard`, `rocky_keyboard`).

**Supported User Patches:**

| Patch Name                 | Description                        |
| -------------------------- | ---------------------------------- |
| `enable_ssh_password_auth` | Enable SSH password authentication |
| `enable_ssh_root_login`    | Enable root login via SSH          |

**Usage Examples:**

```bash
ID=9999
IMAGE="https://cdimage.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMAGE_NAME="debian13"

# Tested Distros

# Ubuntu 24
# IMAGE="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
# IMAGE_NAME="ubuntu24"

# Debian 13
# IMAGE="https://cdimage.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
# IMAGE="https://cdimage.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
# IMAGE_NAME="debian13"

# Fedora 43
# IMAGE="https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2"
# IMAGE_NAME="fedora43"

# Rocky Linux 9
# IMAGE="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2"
# IMAGE_NAME="rocky9"

# Untested Distros

# Alpine Linux 3
# IMAGE="https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/cloud/nocloud_alpine-3.22.2-x86_64-bios-cloudinit-r0.qcow2"
# IMAGE_NAME="alpine3"

./pve-template.sh \
  "$IMAGE" \
  $ID \
  "$IMAGE_NAME-template" \
  --user myuser \
  --password mypass \
  --ssh-keys ~/.ssh/authorized_keys \
  --disk-storage local \
  --snippets-storage local \
  --disk-size 35G \
  --disk-format qcow2 \
  --disk-flags "discard=on ssd=1" \
  --display std \
  --memory 4096 \
  --cores 4 \
  --bridge vmbr2 \
  --timezone Europe/Berlin \
  --keyboard de \
  --keyboard-variant nodeadkeys \
  --locale de_DE.UTF-8 \
  --install "git nginx" \
  --dns-servers "1.1.1.1 8.8.8.8" \
  --domain-names home.arpa \
  --patches "enable_ssh_password_auth"
```

#### **Notes:**

- The script requires either `--password` or `--ssh-keys` when `--user` is specified
- Avoid using usernames that match built-in or existing group names (e.g., admin); cloud-init will fail if a group already exists. The root user is an exception.
- The script automatically installs and enables qemu-guest-agent
- Storage must support the chosen disk format
