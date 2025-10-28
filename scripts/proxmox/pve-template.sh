#! /usr/bin/env bash

# A script to create Proxmox VE templates for various Linux distributions.

set -e

# --- Configuration ---

# VM settings
ID=""                               # ID for the template
NAME=""                             # Name for the template
DISK_SIZE=""                        # Disk size for the VM (e.g., 32G)
STORAGE="${STORAGE:-local-lvm}"     # The Proxmox storage where the VM disk will be allocated (default: local-lvm)
BRIDGE="${BRIDGE:-vmbr0}"           # The Proxmox network bridge for the VM (default: vmbr0)
MEMORY="2048"                       # Memory in MB (default: 2048)
CORES="4"                           # Number of CPU cores (default: 4)
DISK_FORMAT="qcow2"                 # Disk format: qcow2 (default), raw, or vmdk
DISK_FLAGS="discard=on"             # Default disk flags

# SSH settings
ENABLE_ROOT_LOGIN="false"           # If set to true, enable PermitRootLogin yes
ENABLE_PASSWORD_AUTH="false"        # If set to true, enable PasswordAuthentication yes

# Cloud-Init settings
USER=""
PASSWORD=""
SSH_KEYS=""

# Localization settings
TIMEZONE=""                         # Timezone (e.g., America/New_York, Europe/London)
KEYBOARD=""                         # Keyboard layout (e.g., us, uk, de)
LOCALE=""                           # Locale (e.g., en_US.UTF-8, en_GB.UTF-8)

# Other settings
PACKAGES_TO_INSTALL=""              # Packages to install inside the VM template

# Snippets storage for cloud-init configs
SNIPPETS_STORAGE=""                 # Storage where snippets are stored (default: same as STORAGE)
SNIPPETS_DIR=""                     # Will be auto-detected from SNIPPETS_STORAGE

# --- Cloud Image URL (required) ---
CLOUD_IMAGE_URL=""

# --- Functions ---

# Function to run a command quietly (suppress output)
quiet_run() {
    "$@" >/dev/null
}

# Function to display usage information
usage() {
    echo "Usage: $0 <cloud-image-url> <id> <name> [OPTIONS]"
    echo "Creates a Proxmox VE template for a given Linux cloud image URL."
    echo ""
    echo "Arguments:"
    echo "  cloud-image-url                URL to the cloud image to use for the template (required)"
    echo "  id                             ID for the template (required)"
    echo "  name                           Name for the template (required)"
    echo ""
    echo "Options:"
    echo "  --user <user>                  Set the cloud-init username"
    echo "  --password <password>          Set the cloud-init password"
    echo "  --storage <storage>            Proxmox storage for VM disk (default: local-lvm)"
    echo "  --snippets-storage <storage>   Proxmox storage for cloud-init snippets (default: same as --storage)"
    echo "  --bridge <bridge>              Network bridge for VM (default: vmbr0)"
    echo "  --memory <mb>                  Memory in MB (default: 2048)"
    echo "  --cores <num>                  Number of CPU cores (default: 4)"
    echo "  --timezone <timezone>          Timezone (e.g., America/New_York, Europe/London)"
    echo "  --keyboard <layout>            Keyboard layout (e.g., us, uk, de)"
    echo "  --locale <locale>              Locale (e.g., en_US.UTF-8, en_GB.UTF-8)"
    echo "  --ssh-keys <file>              Path to file with public SSH keys (one per line, OpenSSH format)"
    echo "  --disk-size <size>             Disk size (e.g., 32G, 50G)"
    echo "  --disk-format <format>         Disk format: qcow2 (default), raw, or vmdk"
    echo "  --disk-flags <flags>           Disk flags (default: discard=on)"
    echo "  --install <packages>           Space-separated list of packages to install in the template using cloud-init"
    echo "  --enable-root-login            Enable PermitRootLogin yes in SSH config (default: false)"
    echo "  --enable-password-auth         Enable PasswordAuthentication yes in SSH config (default: false)"
    echo "  -h,  --help                    Display this help message"
}

# Function to get the snippets path for a given Proxmox storage
get_snippet_path() {
    local storage="$1"
    local cfg="/etc/pve/storage.cfg"

    if [[ ! -f "$cfg" ]]; then
        echo "Error: Storage configuration file not found at $cfg" >&2
        return 1
    fi

    # Parse storage.cfg to find the storage section and extract path
    local in_section=0
    local path=""
    local has_snippets=0
    local type=""

    while IFS= read -r line; do
        # Check if this is our storage header
        if [[ "$line" =~ ^(dir|nfs|cifs|cephfs):[[:space:]]+${storage}$ ]]; then
            in_section=1
            type="${BASH_REMATCH[1]}"
            continue
        fi

        # Check if we're entering a new storage section
        if [[ "$line" =~ ^[a-z]+: ]]; then
            if [[ $in_section -eq 1 ]]; then
                break
            fi
        fi

        # Extract path and check for snippets if in our section
        if [[ $in_section -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]+path[[:space:]]+(.+)$ ]]; then
                path="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ ^[[:space:]]+content[[:space:]]+ ]] && [[ "$line" == *"snippets"* ]]; then
                has_snippets=1
            fi
        fi
    done < "$cfg"

    # Validate results
    if [[ $in_section -eq 0 ]]; then
        echo "Error: Storage '$storage' not found or is not a supported storage type (dir, nfs, cifs, cephfs)." >&2
        return 1
    fi

    if [[ $has_snippets -eq 0 ]]; then
        echo "Error: Storage '$storage' does not have 'snippets' in its content types." >&2
        return 1
    fi

    if [[ -z "$path" ]]; then
        # Use default mount point for network storage
        if [[ "$type" == "nfs" || "$type" == "cifs" || "$type" == "cephfs" ]]; then
            path="/mnt/pve/$storage"
        else
            echo "Error: Could not determine path for storage '$storage'." >&2
            return 1
        fi
    fi

    echo "$path/snippets"
}

# Function to create cloud-init vendor-data file
generate_ci_vendor_data() {
    local vendor_data_file="${SNIPPETS_DIR}/ci-vendor-data-${ID}.yml"

    echo "Creating cloud-init vendor-data snippet..."

    # Write YAML header and qemu-guest-agent package
    cat > "$vendor_data_file" <<EOF
#cloud-config
package_update: true
package_upgrade: true
package_reboot_if_required: true
packages:
  - qemu-guest-agent
EOF
    # Append extra packages if specified
    if [[ -n "$PACKAGES_TO_INSTALL" ]]; then
        for pkg in $PACKAGES_TO_INSTALL; do
            echo "  - $pkg" >> "$vendor_data_file"
        done
    fi

    # Add runcmd to enable qemu-guest-agent and optionally SSH config changes
    echo "runcmd:" >> "$vendor_data_file"
    if [[ "$ENABLE_ROOT_LOGIN" == "true" ]]; then
        echo "  - sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config" >> "$vendor_data_file"
    fi
    if [[ "$ENABLE_PASSWORD_AUTH" == "true" ]]; then
        echo "  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config" >> "$vendor_data_file"
    fi

    {
        echo "  - systemctl restart sshd" 
        echo "  - systemctl enable qemu-guest-agent"
        echo "  - systemctl start qemu-guest-agent"
    } >> "$vendor_data_file"

    # Add locale if specified
    if [[ -n "$LOCALE" ]]; then
        echo "locale: ${LOCALE}" >> "$vendor_data_file"
    fi

    # Add timezone if specified
    if [[ -n "$TIMEZONE" ]]; then
        echo "timezone: ${TIMEZONE}" >> "$vendor_data_file"
    fi

    # Add keyboard if specified
    if [[ -n "$KEYBOARD" ]]; then
        cat >> "$vendor_data_file" <<EOF
keyboard:
  layout: ${KEYBOARD}
EOF
    fi
}

# Function to create cloud-init network-config file
generate_ci_network_data() {
    local network_config_file="${SNIPPETS_DIR}/ci-network-data-${ID}.yml"

    echo "Creating cloud-init network-data snippet..."

    cat > "$network_config_file" <<EOF
#cloud-config
network:
  version: 2
  ethernets:
    default:
      match:
        name: en*
      dhcp4: true
      dhcp4-overrides:
        use-dns: true
        use-ntp: true
        use-domains: true
EOF
}

# Function to create the VM template
create_template() {
    local url=$1
    local filename
    filename=$(basename "$url")

    echo "--- Creating template $NAME (ID: $ID) ---"

    # Ensure snippets directory exists
    if [ ! -d "$SNIPPETS_DIR" ]; then
        echo "Creating snippets directory at $SNIPPETS_DIR..."
        mkdir -p "$SNIPPETS_DIR"
    fi

    # Download the cloud image
    if [ ! -f "$filename" ]; then
        echo "Downloading image from $url..."
        wget -q --show-progress -O "$filename" "$url"
    else
        echo "Image $filename already exists. Skipping download"
    fi

    # Create a working copy of the image
    local ext="${filename##*.}"
    local working_image="${NAME}.${ext}"
    cp "$filename" "$working_image"

    # Resize disk if size specified
    if [[ -n "$DISK_SIZE" ]]; then
        echo "Resizing disk to $DISK_SIZE..."
        quiet_run qemu-img resize "$working_image" "$DISK_SIZE"
    fi

    # Create cloud-init snippets
    generate_ci_vendor_data
    generate_ci_network_data

    # Create a new VM with basic configuration
    echo "Creating VM $ID..."
    qm create "$ID" --name "$NAME" \
        --memory "$MEMORY" \
        --cpu host \
        --cores "$CORES" \
        --net0 virtio,bridge="$BRIDGE" \
        --agent enabled=1 \
        --ostype l26 \
        --serial0 socket

    # Import the downloaded disk to the VM's storage
    echo "Importing disk..."
    quiet_run qm importdisk "$ID" "$working_image" "$STORAGE" --format "$DISK_FORMAT"

    # Configure storage, boot, and cloud-init
    echo "Configuring storage and cloud-init..."
    quiet_run qm set "$ID" \
        --scsihw "virtio-scsi-single" \
        --scsi0 "$STORAGE:$ID/vm-$ID-disk-0.${DISK_FORMAT},${DISK_FLAGS}" \
        --boot "order=scsi0" \
        --scsi1 "$STORAGE:cloudinit" \
        --ciuser "$USER" \
        --cipassword "$PASSWORD" \
        --ciupgrade 1 \
        --ipconfig0 "ip6=auto,ip=dhcp" \
        --sshkeys "$SSH_KEYS" \
        --cicustom "vendor=${SNIPPETS_STORAGE}:snippets/ci-vendor-data-${ID}.yml,network=${SNIPPETS_STORAGE}:snippets/ci-network-data-${ID}.yml"

    # Convert the VM to a template
    echo "Converting VM $ID to a template..."
    quiet_run qm template "$ID"

    # Cleanup working image
    rm -f "$working_image"

    echo "--- Template $NAME created successfully! ---"
}

# --- Parameter validation ---
require_param() {
    if [[ -z "$1" ]]; then
        die "Missing required argument: $2"
    fi
}

require_file() {
    if [[ ! -f "$1" ]]; then
        die "File not found: $2 ($1)"
    fi
}

die() {
    echo "Error: $*" >&2
    exit 1
}

validate_args() {
    # 1. Mutually exclusive/dependent options
    if [[ -n "$USER" ]]; then
        if [[ -z "$PASSWORD" && -z "$SSH_KEYS" ]]; then
            die "You must provide at least one of --password or --ssh-keys."
        fi
    fi
    # 2. Required parameters
    require_param "$CLOUD_IMAGE_URL" "cloud image url (argument 1)"
    require_param "$ID" "id (argument 2)"
    require_param "$NAME" "name (argument 3)"
    # 3. File existence
    if [[ -n "$SSH_KEYS" ]]; then
        require_file "$SSH_KEYS" "SSH keys file"
    fi
    # 4. Value validity
    case "$DISK_FORMAT" in
        qcow2|raw|vmdk) ;;
        *)
            die "Unsupported disk format '$DISK_FORMAT'. Supported: qcow2, raw, vmdk."
            ;;
    esac
    # 5. ID existence (after all other checks)
    if qm status "$ID" &>/dev/null; then
        die "ID $ID already exists. Please choose a different ID."
    fi  
}

# --- Main script logic ---

main() {
    # Parse positional arguments
    if [[ "$#" -lt 3 ]]; then
        usage
        exit 1
    fi
    CLOUD_IMAGE_URL="$1"
    ID="$2"
    NAME="$3"
    shift 3

    # Parse command-line options
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --user)
                USER="$2"
                shift 2
                ;;
            --password)
                PASSWORD="$2"
                shift 2
                ;;
            --install)
                PACKAGES_TO_INSTALL="$2"
                shift 2
                ;;
            --storage)
                STORAGE="$2"
                shift 2
                ;;
            --snippets-storage)
                SNIPPETS_STORAGE="$2"
                shift 2
                ;;
            --bridge)
                BRIDGE="$2"
                shift 2
                ;;
            --disk-size)
                DISK_SIZE="$2"
                shift 2
                ;;
            --memory)
                MEMORY="$2"
                shift 2
                ;;
            --cores)
                CORES="$2"
                shift 2
                ;;
            --timezone)
                TIMEZONE="$2"
                shift 2
                ;;
            --keyboard)
                KEYBOARD="$2"
                shift 2
                ;;
            --locale)
                LOCALE="$2"
                shift 2
                ;;
            --ssh-keys)
                SSH_KEYS="$2"
                shift 2
                ;;
            --disk-format)
                DISK_FORMAT="$2"
                shift 2
                ;;
            --disk-flags)
                DISK_FLAGS="$2"
                shift 2
                ;;
            --enable-root-login)
                ENABLE_ROOT_LOGIN=true
                shift
                ;;
            --enable-password-auth)
                ENABLE_PASSWORD_AUTH=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                break # Stop processing options
                ;;
        esac
    done

    # Validate arguments after parsing
    validate_args

    # Set SNIPPETS_STORAGE to STORAGE if not specified
    SNIPPETS_STORAGE="${SNIPPETS_STORAGE:-$STORAGE}"

    # Auto-detect snippets directory and install dependencies
    SNIPPETS_DIR=$(get_snippet_path "$SNIPPETS_STORAGE")

    create_template "$CLOUD_IMAGE_URL"
}

# Run the main function with all script arguments
main "$@"
