#! /usr/bin/env bash

# A script to create Proxmox VE templates for various Linux distributions.

set -e

# --- Configuration ---

# VM settings
STORAGE=""              # The Proxmox storage where the VM disk will be allocated
BRIDGE=""               # The Proxmox network bridge for the VM
VMID=""                 # VM ID for the template
VM_NAME=""              # Name for the template
DISK_SIZE=""            # Disk size for the VM (e.g., 32G)
MEMORY="2048"           # Memory in MB (default: 2048)
CORES="4"               # Number of CPU cores (default: 4)

# Cloud-Init settings
CI_USER=""
CI_PASSWORD=""

# Localization settings
TIMEZONE=""             # Timezone (e.g., America/New_York, Europe/London)
KEYBOARD=""             # Keyboard layout (e.g., us, uk, de)
LOCALE=""               # Locale (e.g., en_US.UTF-8, en_GB.UTF-8)

# Packages to install inside the VM template
PACKAGES_TO_INSTALL=""

# Snippets storage for cloud-init configs
SNIPPETS_STORAGE=""     # Storage where snippets are stored (default: same as STORAGE)
SNIPPETS_DIR=""         # Will be auto-detected from SNIPPETS_STORAGE

# --- Image URLs ---

# Debian 12 (Bookworm)
DEBIAN_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"

# Ubuntu 24.04 (Noble Numbat)
UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"


# --- Functions ---

# Function to display usage information
usage() {
    echo "Usage: $0 [OPTIONS] <distro>"
    echo "Creates a Proxmox VE template for a given Linux distribution using cloud images"
    echo ""
    echo "Supported distributions:"
    echo "  debian"
    echo "  ubuntu"
    echo ""
    echo "Options:"
    echo "  -u,  --user <user>          Set the cloud-init username"
    echo "  -p,  --password <password>  Set the cloud-init password"
    echo "  -i,  --install <packages>   Space-separated list of packages to install in the template"
    echo "  -s,  --storage <storage>    Proxmox storage for VM disk"
    echo "  -ss, --snippets-storage <storage>  Proxmox storage for cloud-init snippets (default: same as --storage)"
    echo "  -b,  --bridge <bridge>      Network bridge for VM"
    echo "  -d,  --disk-size <size>     Disk size (e.g., 32G, 50G)"
    echo "  -m,  --memory <mb>          Memory in MB (default: 2048)"
    echo "  -c,  --cores <num>          Number of CPU cores (default: 4)"
    echo "  -t,  --timezone <timezone>  Timezone (e.g., America/New_York, Europe/London)"
    echo "  -k,  --keyboard <layout>    Keyboard layout (e.g., us, uk, de)"
    echo "  -l,  --locale <locale>      Locale (e.g., en_US.UTF-8, en_GB.UTF-8)"
    echo "  -v,  --vmid <id>            VM ID for the template"
    echo "  -n,  --name <name>          Name for the template"
    echo "  -h,  --help                 Display this help message"
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

# Function to create cloud-init user-data file
generate_ci_user_data() {
    local user_data_file="${SNIPPETS_DIR}/ci-user-data-${VMID}.yml"
    
    echo "Creating cloud-init user-data snippet..."
    
    cat > "$user_data_file" <<EOF
#cloud-config
manage_etc_hosts: true
preserve_hostname: true
user: ${CI_USER}
password: ${CI_PASSWORD}
chpasswd:
  expire: false
users:
  - default
EOF

    # Add locale if specified
    if [[ -n "$LOCALE" ]]; then
        echo "locale: ${LOCALE}" >> "$user_data_file"
    fi

    # Add timezone if specified
    if [[ -n "$TIMEZONE" ]]; then
        echo "timezone: ${TIMEZONE}" >> "$user_data_file"
    fi

    # Add keyboard if specified
    if [[ -n "$KEYBOARD" ]]; then
        cat >> "$user_data_file" <<EOF
keyboard:
  layout: ${KEYBOARD}
EOF
    fi

    echo "Cloud-init user-data created at: $user_data_file"
}

# Function to create cloud-init vendor-data file
generate_ci_vendor_data() {
    local vendor_data_file="${SNIPPETS_DIR}/ci-vendor-data-${VMID}.yml"
    
    echo "Creating cloud-init vendor-data snippet..."
    
    # Add packages if specified
    if [[ -n "$PACKAGES_TO_INSTALL" ]]; then
        cat > "$vendor_data_file" <<EOF
#cloud-config
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
EOF
        for pkg in $PACKAGES_TO_INSTALL; do
            echo "  - $pkg" >> "$vendor_data_file"
        done
    else
        cat > "$vendor_data_file" <<EOF
#cloud-config
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
EOF
    fi

    # Add runcmd to enable qemu-guest-agent
    cat >> "$vendor_data_file" <<EOF
runcmd:
  - sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart sshd
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
EOF

    echo "Cloud-init vendor-data created at: $vendor_data_file"
}

# Function to create cloud-init network-config file
generate_ci_network_data() {
    local network_config_file="${SNIPPETS_DIR}/ci-network-data-${VMID}.yml"
    
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
        use-domains: true
EOF

    echo "Cloud-init network-config created at: $network_config_file"
}

# Function to create the VM template
create_template() {
    local url=$1
    local filename
    filename=$(basename "$url")

    echo "--- Creating template $VM_NAME (VMID: $VMID) ---"

    # Ensure snippets directory exists
    if [ ! -d "$SNIPPETS_DIR" ]; then
        echo "Creating snippets directory at $SNIPPETS_DIR..."
        mkdir -p "$SNIPPETS_DIR"
    fi

    # Download the cloud image
    if [ ! -f "$filename" ]; then
        echo "Downloading image from $url..."
        wget -O "$filename" "$url"
    else
        echo "Image $filename already exists. Skipping download"
    fi

    # Create a working copy of the image
    local working_image="${VM_NAME}.qcow2"
    echo "Creating working copy of image..."
    cp "$filename" "$working_image"

    # Resize disk if size specified
    if [[ -n "$DISK_SIZE" ]]; then
        echo "Resizing disk to $DISK_SIZE..."
        qemu-img resize "$working_image" "$DISK_SIZE"
    fi

    # Create cloud-init snippets
    generate_ci_user_data
    generate_ci_vendor_data
    generate_ci_network_data

    # Create a new VM with basic configuration
    echo "Creating VM $VMID..."
    qm create "$VMID" --name "$VM_NAME" \
        --memory "$MEMORY" \
        --cpu host \
        --cores "$CORES" \
        --net0 virtio,bridge="$BRIDGE" \
        --agent enabled=1 \
        --ostype l26 \
        --serial0 socket

    # Import the downloaded disk to the VM's storage
    echo "Importing disk..."
    qm importdisk "$VMID" "$working_image" "$STORAGE" --format qcow2

    # Configure storage, boot, and cloud-init
    echo "Configuring storage and cloud-init..."
    qm set "$VMID" \
        --scsihw virtio-scsi-single \
        --scsi0 "$STORAGE:$VMID/vm-$VMID-disk-0.qcow2,discard=on,ssd=1" \
        --boot order=scsi0 \
        --ide0 "$STORAGE:cloudinit" \
        --ipconfig0 ip=dhcp \
        --ciuser "${CI_USER}" \
        --cipassword "${CI_PASSWORD}" \
        --ciupgrade 1 \
        --cicustom "user=${SNIPPETS_STORAGE}:snippets/ci-user-data-${VMID}.yml,vendor=${SNIPPETS_STORAGE}:snippets/ci-vendor-data-${VMID}.yml,network=${SNIPPETS_STORAGE}:snippets/ci-network-data-${VMID}.yml"
    
    # Convert the VM to a template
    echo "Converting VM $VMID to a template..."
    qm template "$VMID"

    echo "--- Template $VM_NAME created successfully! ---"
}

# --- Main script logic ---
main() {
    
    # Parse command-line options
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -u|--user)
                CI_USER="$2"
                shift 2
                ;;
            -p|--password)
                CI_PASSWORD="$2"
                shift 2
                ;;
            -i|--install)
                PACKAGES_TO_INSTALL="$2"
                shift 2
                ;;
            -s|--storage)
                STORAGE="$2"
                shift 2
                ;;
            -ss|--snippets-storage)
                SNIPPETS_STORAGE="$2"
                shift 2
                ;;
            -b|--bridge)
                BRIDGE="$2"
                shift 2
                ;;
            -d|--disk-size)
                DISK_SIZE="$2"
                shift 2
                ;;
            -m|--memory)
                MEMORY="$2"
                shift 2
                ;;
            -c|--cores)
                CORES="$2"
                shift 2
                ;;
            -t|--timezone)
                TIMEZONE="$2"
                shift 2
                ;;
            -k|--keyboard)
                KEYBOARD="$2"
                shift 2
                ;;
            -l|--locale)
                LOCALE="$2"
                shift 2
                ;;
            -v|--vmid)
                VMID="$2"
                shift 2
                ;;
            -n|--name)
                VM_NAME="$2"
                shift 2
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
    
    if [ "$#" -ne 1 ]; then
        echo "Error: Distribution argument is required"
        usage
        exit 1
    fi

    if qm status "$VMID" &>/dev/null; then
        echo "Error: VMID $VMID already exists. Please choose a different VMID."
        exit 1
    fi

    # Check required parameters individually
    local missing_params=()
    
    [[ -z "$CI_USER" ]] && missing_params+=("user (-u/--user)")
    [[ -z "$CI_PASSWORD" ]] && missing_params+=("password (-p/--password)")
    [[ -z "$STORAGE" ]] && missing_params+=("storage (-s/--storage)")
    [[ -z "$BRIDGE" ]] && missing_params+=("bridge (-b/--bridge)")
    [[ -z "$VMID" ]] && missing_params+=("vmid (-v/--vmid)")
    [[ -z "$VM_NAME" ]] && missing_params+=("name (-n/--name)")
    
    if [ ${#missing_params[@]} -ne 0 ]; then
        echo "Error: Missing required parameter(s):"
        for param in "${missing_params[@]}"; do
            echo "  - $param"
        done
        echo ""
        usage
        exit 1
    fi

    # Set SNIPPETS_STORAGE to STORAGE if not specified
    SNIPPETS_STORAGE="${SNIPPETS_STORAGE:-$STORAGE}"

    # Auto-detect snippets directory and install dependencies
    SNIPPETS_DIR=$(get_snippet_path "$SNIPPETS_STORAGE")

    case "$1" in
        debian)
            create_template "$DEBIAN_IMAGE_URL"
            ;;
        ubuntu)
            create_template "$UBUNTU_IMAGE_URL"
            ;;
        *)
            echo "Error: Unsupported distribution '$1'"
            usage
            exit 1
            ;;
    esac
}

# Run the main function with all script arguments
main "$@"
