#!/usr/bin/env bash

# A script to create Proxmox VE templates for various Linux distributions.

set -e

declare -A DISK_STORAGE_CONFIG=()
declare -A SNIPPETS_STORAGE_CONFIG=()

# --- Configuration ---

# VM settings
ID=""                               # ID for the template
NAME=""                             # Name for the template
DISK_SIZE=""                        # Disk size for the VM (e.g., 32G)
BRIDGE="vmbr0"                      # The Proxmox network bridge for the VM (default: vmbr0)
MEMORY="2048"                       # Memory in MB (default: 2048)
CORES="4"                           # Number of CPU cores (default: 4)
DISK_FORMAT="qcow2"                 # Disk format: qcow2 (default), raw, or vmdk
DISK_FLAGS="discard=on"             # Default disk flags
DISPLAY_TYPE="std"                  # Display type (e.g., std, cirrus, vmware, qxl)

# SSH settings
ENABLE_ROOT_LOGIN="false"           # If set to true, enable PermitRootLogin yes
ENABLE_PASSWORD_AUTH="false"        # If set to true, enable PasswordAuthentication yes

# Cloud-Init settings
CI_USER=""
PASSWORD=""
SSH_KEYS=""

# Localization settings
TIMEZONE=""                         # Timezone
KEYBOARD=""                         # Keyboard layout
KEYBOARD_VARIANT=""                 # Keyboard variant
LOCALE=""                           # Locale

# Network settings
DNS_SERVERS=""                      # DNS servers (space-separated, e.g., 8.8.8.8 8.8.4.4)
DOMAIN_NAMES=""                     # Domain names (space-separated, e.g., example.com internal.local)

# Other settings
PACKAGES_TO_INSTALL=""              # Packages to install inside the VM template

# Storage
STORAGE="local-lvm"                 # The Proxmox storage where the VM disk will be allocated (default: local-lvm)
SNIPPETS_STORAGE=""                 # Storage where snippets are stored (default: same as STORAGE)

# --- Cloud Image URL (required) ---
CLOUD_IMAGE_URL=""

# --- Functions ---

# Function to run a command quietly (suppress output)
quiet_run() {
    "$@" >/dev/null 2>&1 || {
        echo "Command failed: $*" >&2
        exit 1
    }
}

# Function to display usage information
usage() {
    echo "Usage: $0 <cloud-image-url> <id> <name> [OPTIONS]"
    echo ""
    echo "Creates a Proxmox VE template for a given Linux cloud image URL."
    echo ""
    echo "Arguments:"
    echo "  cloud-image-url                URL to the cloud image to use for the template (required)"
    echo "  id                             ID for the template (required)"
    echo "  name                           Name for the template (required)"
    echo ""
    echo "Options:"
    echo "  --user <user>                  Set the cloud-init user"
    echo "  --password <password>          Set the cloud-init password"
    echo "  --storage <storage>            Proxmox storage for VM disk (default: local-lvm)"
    echo "  --snippets-storage <storage>   Proxmox storage for cloud-init snippets (default: same as --storage)"
    echo "  --bridge <bridge>              Network bridge for VM (default: vmbr0)"
    echo "  --memory <mb>                  Memory in MB (default: 2048)"
    echo "  --cores <num>                  Number of CPU cores (default: 4)"
    echo "  --timezone <timezone>          Timezone (e.g., America/New_York, Europe/London)"
    echo "  --keyboard <layout>            Keyboard layout (e.g., us, uk, de)"
    echo "  --keyboard-variant <variant>   Keyboard variant (e.g., intl)"
    echo "  --locale <locale>              Locale (e.g., en_US.UTF-8, de_DE.UTF-8)"
    echo "  --ssh-keys <file>              Path to file with public SSH keys (one per line, OpenSSH format)"
    echo "  --disk-size <size>             Disk size (e.g., 32G, 50G, 6144M)"
    echo "  --disk-format <format>         Disk format: ex. qcow2 (default)"
    echo "  --disk-flags <flags>           Space-separated Disk flags (default: discard=on)"
    echo "  --display <type>               Set the display/vga type (default: std)"
    echo "  --install <packages>           Space-separated list of packages to install in the template using cloud-init"
    echo "  --dns-servers <servers>        Space-separated DNS servers (e.g., '10.10.10.10 9.9.9.9')"
    echo "  --domain-names <domains>       Space-separated domain names (e.g., 'example.com internal.local')"
    echo "  --enable-root-login            Enable PermitRootLogin yes in SSH config (default: false)"
    echo "  --enable-password-auth         Enable PasswordAuthentication yes in SSH config (default: false)"
    echo "  -h,  --help                    Display this help message"
}

# Function to parse Proxmox storage configuration and extract information
parse_storage_config() {
    local storage="$1"
    local -n storage_config="$2"

    local cfg="/etc/pve/storage.cfg"

    if [[ ! -f "$cfg" ]]; then
        echo "Error: Storage configuration file not found at $cfg" >&2
        return 1
    fi

    # Initialize variables
    local in_section=0
    local storage_type=""
    local path=""
    local content=""
    local content_dirs=""

    # Parse storage.cfg to find the storage section and extract information
    while IFS= read -r line; do
        # Check if this is our storage header
        if [[ "$line" =~ ^(dir|nfs|cifs|cephfs|lvmthin|zfspool):[[:space:]]+${storage}$ ]]; then
            in_section=1
            storage_type="${BASH_REMATCH[1]}"
            continue
        fi

        # Check if we're entering a new storage section
        if [[ "$line" =~ ^[a-z]+: ]]; then
            if [[ $in_section -eq 1 ]]; then
                break
            fi
        fi

        # Extract properties if in our section
        if [[ $in_section -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]+path[[:space:]]+(.+)$ ]]; then
                path="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]+content[[:space:]]+(.+)$ ]]; then
                content="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]+content-dirs[[:space:]]+(.+)$ ]]; then
                content_dirs="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$cfg"

    # Validate results
    if [[ $in_section -eq 0 ]]; then
        echo "Error: Storage '$storage' not found or is not supported." >&2
        return 1
    fi

    # For network storage types, default to /mnt/pve/<storage> if path is empty
    if [[ "$storage_type" =~ ^(nfs|cifs|cephfs)$ ]] && [[ -z "$path" ]]; then
        path="/mnt/pve/$storage"
    fi

    # Check if storage supports images
    local supports_images="false"
    local image_formats=""
    if [[ "$content" == *"images"* ]]; then
        supports_images="true"

        # Set supported image formats based on storage type
        case "$storage_type" in
            dir)
                image_formats="raw,qcow2,vmdk,subvol"
                ;;
            nfs|cifs)
                image_formats="raw,qcow2,vmdk"
                ;;
            lvmthin)
                image_formats="raw"
                ;;
            zfspool)
                image_formats="raw,subvol"
                ;;
        esac
    fi

    # Check if storage supports snippets
    local supports_snippets="false"
    local snippets_dir=""
    if [[ "$content" == *"snippets"* && -n "$path" ]]; then
        supports_snippets="true"

        # Determine snippets directory
        local relative_dir="snippets"

        # Check if content-dirs has a custom snippets path
        if [[ -n "$content_dirs" ]] && [[ "$content_dirs" =~ snippets=([^,]+) ]]; then
            relative_dir="${BASH_REMATCH[1]}"
        fi

        # Construct full path
        snippets_dir="${path}/${relative_dir}"

        mkdir -p "$snippets_dir"
    fi

    # Store configuration in associative array
    storage_config["name"]="$storage"
    storage_config["type"]="$storage_type"
    storage_config["path"]="$path"
    storage_config["content"]="$content"
    storage_config["content_dirs"]="$content_dirs"
    storage_config["supports_images"]="$supports_images"
    storage_config["image_formats"]="$image_formats"
    storage_config["supports_snippets"]="$supports_snippets"
    # shellcheck disable=SC2034
    storage_config["snippets_dir"]="$snippets_dir"

    return 0
}

# Function to create cloud-init vendor-data file
generate_ci_vendor_data() {
    local snippets_dir="${SNIPPETS_STORAGE_CONFIG[snippets_dir]}"
    local vendor_data_file="${snippets_dir}/ci-vendor-data-${ID}.yml"

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
        IFS=' ' read -ra pkg_array <<< "$PACKAGES_TO_INSTALL"
        for pkg in "${pkg_array[@]}"; do
            echo "  - $pkg" >> "$vendor_data_file"
        done
    fi

    [[ -n "$LOCALE" ]] && echo "locale: ${LOCALE}" >> "$vendor_data_file"
    [[ -n "$TIMEZONE" ]] && echo "timezone: ${TIMEZONE}" >> "$vendor_data_file"
    if [[ -n "$KEYBOARD" ]]; then
    cat >> "$vendor_data_file" <<EOF
keyboard:
  layout: ${KEYBOARD}
EOF
        if [[ -n "$KEYBOARD_VARIANT" ]]; then
            echo "  variant: ${KEYBOARD_VARIANT}" >> "$vendor_data_file"
        fi
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
}

# Function to create the VM template
create_template() {
    local url=$1
    local filename
    local snippets_storage="${SNIPPETS_STORAGE_CONFIG[name]}"
    local disk_storage="${DISK_STORAGE_CONFIG[name]}"
    filename=$(basename "$url")

    echo "--- Creating template $NAME (ID: $ID) ---"

    # Download the cloud image
    if [[ ! -f "$filename" ]]; then
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

    # Create a new VM with basic configuration
    echo "Creating VM $ID..."
    quiet_run qm create "$ID" --name "$NAME" \
        --memory "$MEMORY" \
        --cpu host \
        --cores "$CORES" \
        --net0 virtio,bridge="$BRIDGE" \
        --agent enabled=1 \
        --ostype l26 \
        --vga "$DISPLAY_TYPE" \
        --serial0 socket

    # Import the downloaded disk to the VM's storage
    echo "Importing disk..."
    quiet_run qm importdisk "$ID" "$working_image" "$disk_storage" --format "$DISK_FORMAT"

    # Configure storage, boot, and cloud-init
    echo "Configuring storage and cloud-init..."

    # Build disk path based on storage type
    local disk_path
    local storage_type="${DISK_STORAGE_CONFIG[type]}"
    if [[ "$storage_type" =~ ^(lvmthin|zfspool)$ ]]; then
        # Block storage types use simple format: storage:vm-ID-disk-N
        disk_path="$disk_storage:vm-$ID-disk-0"
    else
        # Directory-based storage types use: storage:ID/vm-ID-disk-N.format
        disk_path="$disk_storage:$ID/vm-$ID-disk-0.${DISK_FORMAT}"
    fi

    # Build qm set command with conditional cloud-init parameters
    local qm_cmd=(qm set "$ID"
        --scsihw "virtio-scsi-single"
        --scsi0 "${disk_path},${DISK_FLAGS// /,}"
        --boot "order=scsi0"
        --scsi1 "$disk_storage:cloudinit"
        --ciupgrade 1
        --cicustom "vendor=${snippets_storage}:snippets/ci-vendor-data-${ID}.yml"
        --ipconfig0 "ip=dhcp"
    )

    # Add DNS servers if specified
    if [[ -n "$DNS_SERVERS" ]]; then
        qm_cmd+=(--nameserver "$DNS_SERVERS")
    fi

    # Add search domain if specified
    if [[ -n "$DOMAIN_NAMES" ]]; then
        qm_cmd+=(--searchdomain "$DOMAIN_NAMES")
    fi

    # Add cloud-init user settings if user is specified
    if [[ -n "$CI_USER" ]]; then
        qm_cmd+=(--ciuser "$CI_USER")

        if [[ -n "$PASSWORD" ]]; then
            qm_cmd+=(--cipassword "$PASSWORD")
        fi

        if [[ -n "$SSH_KEYS" ]]; then
            qm_cmd+=(--sshkeys "$SSH_KEYS")
        fi
    fi

    quiet_run "${qm_cmd[@]}"

    # Convert the VM to a template
    echo "Converting VM $ID to a template..."
    quiet_run qm template "$ID"

    # Cleanup working image
    rm -f "$working_image"

    echo "--- Template $NAME created successfully! ---"
}

die() {
    echo "Error: $*" >&2
    exit 1
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

validate_args() {

    require_param "$CLOUD_IMAGE_URL" "cloud image url (argument 1)"
    require_param "$ID" "id (argument 2)"
    require_param "$NAME" "name (argument 3)"

    if [[ -n "$CI_USER" ]]; then
        if [[ -z "$PASSWORD" && -z "$SSH_KEYS" ]]; then
            die "You must provide at least one of --password or --ssh-keys when --user is specified"
        fi

        # If SSH keys provided, check file existence
        if [[ -n "$SSH_KEYS" ]]; then
            require_file "$SSH_KEYS" "SSH keys file"

            if [[ ! -s "$SSH_KEYS" ]]; then
                die "SSH keys file '$SSH_KEYS' is empty"
            fi
        fi

    else
        echo "Warning: No cloud-init user provided"
    fi

    if qm status "$ID" &>/dev/null; then
        die "ID $ID already exists. Please choose a different ID."
    fi
}

validate_storage() {
    # Validate disk storage supports images
    if [[ "${DISK_STORAGE_CONFIG[supports_images]}" != "true" ]]; then
        die "Storage '${DISK_STORAGE_CONFIG[name]}' does not support VM disk images. Supported content: ${DISK_STORAGE_CONFIG[content]}"
    fi

    # Validate disk format is supported by the storage type
    local supported_formats="${DISK_STORAGE_CONFIG[image_formats]}"
    if [[ ! ",$supported_formats," == *",$DISK_FORMAT,"* ]]; then
        die "Disk format '$DISK_FORMAT' is not supported by storage '${DISK_STORAGE_CONFIG[name]}' (type: ${DISK_STORAGE_CONFIG[type]}). Supported formats: $supported_formats"
    fi

    # Validate snippets storage supports snippets
    if [[ "${SNIPPETS_STORAGE_CONFIG[supports_snippets]}" != "true" ]]; then
        die "Storage '${SNIPPETS_STORAGE_CONFIG[name]}' does not support snippets. Supported content: ${SNIPPETS_STORAGE_CONFIG[content]}"
    fi
}

# --- Main script logic ---

main() {
    # Parse positional arguments
    if [[ "$#" -lt 3 ]]; then
        usage
        exit 1
    fi

    # Ensure first three arguments are not options
    for argn in 1 2 3; do
        arg="${!argn}"
        if [[ "$arg" == --* ]]; then
            echo "Error: Argument $argn must be a value, not an option (got '$arg')"
            echo ""
            usage
            exit 1
        fi
    done

    CLOUD_IMAGE_URL="$1"
    ID="$2"
    NAME="$3"
    shift 3

    # Parse command-line options
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --user)
                CI_USER="$2"
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
            --keyboard-variant)
                KEYBOARD_VARIANT="$2"
                shift 2
                ;;
            --locale)
                LOCALE="$2"
                shift 2
                ;;
            --dns-servers)
                DNS_SERVERS="$2"
                shift 2
                ;;
            --domain-names)
                DOMAIN_NAMES="$2"
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
            --display)
                DISPLAY_TYPE="$2"
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

    # Parse storage configuration
    parse_storage_config "$STORAGE" DISK_STORAGE_CONFIG
    if [[ "$SNIPPETS_STORAGE" == "$STORAGE" ]]; then
        # Copy storage config
        for key in "${!DISK_STORAGE_CONFIG[@]}"; do
            SNIPPETS_STORAGE_CONFIG["$key"]="${DISK_STORAGE_CONFIG[$key]}"
        done
    else
        parse_storage_config "$SNIPPETS_STORAGE" SNIPPETS_STORAGE_CONFIG
    fi

    # Validate storage capabilities
    validate_storage

    create_template "$CLOUD_IMAGE_URL"
}

# Run the main function with all script arguments
main "$@"
