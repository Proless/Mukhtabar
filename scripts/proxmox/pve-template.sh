#!/usr/bin/env bash

# A script to create Proxmox VE templates for various Linux distributions.

set -e

declare -A DISK_STORAGE_CONFIG=()
declare -A SNIPPETS_STORAGE_CONFIG=()

# --- Configuration ---
SUPPORTED_DISTROS=("alpine" "debian" "ubuntu" "fedora" "rockylinux")

# ---  Template Settings ---
ID=""                               # ID for the template
NAME=""                             # Name for the template
DISTRO=""                           # Distro of the image (auto-detected)
CLOUD_IMAGE_URL=""                  # Cloud Image URL

# VM settings
DISK_SIZE=""                        # Disk size for the VM (e.g., 32G)
BRIDGE="vmbr0"                      # The Proxmox network bridge for the VM (default: vmbr0)
MEMORY="2048"                       # Memory in MB (default: 2048)
CORES="4"                           # Number of CPU cores (default: 4)
DISK_FORMAT="qcow2"                 # Disk format: qcow2 (default), raw, or vmdk
DISK_FLAGS="discard=on"             # Default disk flags
DISPLAY_TYPE="std"                  # Display type (e.g., std, cirrus, vmware, qxl)

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
PATCHES_TO_APPLY=""                 # Space-separated list of patches to apply

# Storage
STORAGE="local-lvm"                 # The Proxmox storage where the VM disk will be allocated (default: local-lvm)
SNIPPETS_STORAGE=""                 # Storage where snippets are stored (default: same as STORAGE)

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
    echo "  --patches <patches>            Space-separated list of patch names to apply"
    echo "  -h,  --help                    Display this help message"
    
    echo ""
    echo "Supported distros: ${SUPPORTED_DISTROS[*]}"

    echo ""
    echo "Supported patches (for --patches):"
    echo "  debian_locale                  Debian-specific: Set up locale"
    echo "  debian_keyboard                Debian-specific: Set up keyboard layout"
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
}

# Function to create cloud-init vendor-data file
generate_ci_vendor_data() {
    local vendor_data_file="$1"

    echo "Creating cloud-init vendor-data snippet..."

    # Create vendor-data file
    yq -y -n \
        " .package_update = true
        | .package_upgrade = true
        | .package_reboot_if_required = true
        | .packages = [\"qemu-guest-agent\"]
        " > "$vendor_data_file"

    # Append extra packages if specified
    if [[ -n "$PACKAGES_TO_INSTALL" ]]; then
        IFS=' ' read -ra pkg_array <<< "$PACKAGES_TO_INSTALL"
        for pkg in "${pkg_array[@]}"; do
            yq -i -y ".packages += [\"$pkg\"]" "$vendor_data_file"
        done
    fi

    [[ -n "$LOCALE" ]] && yq -i -y ".locale = \"$LOCALE\"" "$vendor_data_file"
    [[ -n "$TIMEZONE" ]] && yq -i -y ".timezone = \"$TIMEZONE\"" "$vendor_data_file"

    if [[ -n "$KEYBOARD" ]]; then
        yq -i -y ".keyboard.layout = \"$KEYBOARD\"" "$vendor_data_file"
        if [[ -n "$KEYBOARD_VARIANT" ]]; then
            yq -i -y ".keyboard.variant = \"$KEYBOARD_VARIANT\"" "$vendor_data_file"
        fi
    fi

    # Initialize runcmd array
    yq -i -y '.runcmd = []' "$vendor_data_file"

    # Add final runcmd commands based on distro
    case "$DISTRO" in
        debian|ubuntu|fedora|rockylinux)
            yq -i -y ".runcmd += [\"systemctl enable qemu-guest-agent\"]" "$vendor_data_file"
            yq -i -y ".runcmd += [\"systemctl start qemu-guest-agent\"]" "$vendor_data_file"
            ;;
        alpine)
            yq -i -y ".runcmd += [\"rc-update add qemu-guest-agent default\"]" "$vendor_data_file"
            yq -i -y ".runcmd += [\"service qemu-guest-agent start\"]" "$vendor_data_file"
            ;;
        *)
            # Default to systemctl for unknown distros
            yq -i -y '.runcmd += ["systemctl enable qemu-guest-agent"]' "$vendor_data_file"
            yq -i -y '.runcmd += ["systemctl start qemu-guest-agent"]' "$vendor_data_file"
            ;;
    esac
}

# patch functions params : vendor-data file ($1),  image file ($2) as arguments

patch_debian_locale() {
    # Remove the locale section from the YAML file
    yq -i -y "del(.locale)" "$1"
    # Add shell commands to runcmd for locale setup
    yq -i -y ".runcmd += [\"sed -i -E \\\"s/^# *\\\\(${LOCALE}\\\\)/\\\\1/\\\" /etc/locale.gen\"]" "$1"
    yq -i -y ".runcmd += [\"grep -q \\\"^${LOCALE}\\\" /etc/locale.gen || echo \\\"${LOCALE}\\\" >> /etc/locale.gen\"]" "$1"
    yq -i -y ".runcmd += [\"locale-gen\"]" "$1"
    yq -i -y ".runcmd += [\"update-locale LANG=\\\"${LOCALE}\\\"\"]" "$1"
    yq -i -y ".runcmd += [\"export LANG=\\\"${LOCALE}\\\"\"]" "$1"
}

patch_debian_keyboard() {
    # Remove the keyboard section from the YAML file
    yq -i -y "del(.keyboard)" "$1"
    # Add required packages
    yq -i -y ".packages += [\"keyboard-configuration\"]" "$1"
    yq -i -y ".packages += [\"console-setup\"]" "$1"
    # Add shell commands to runcmd for keyboard setup
    yq -i -y ".runcmd += [\"sed -i -E \\\"s/^XKBMODEL.*/XKBMODEL=\\\"pc105\\\"/\\\" /etc/default/keyboard\"]" "$1"
    yq -i -y ".runcmd += [\"sed -i -E \\\"s/^XKBLAYOUT.*/XKBLAYOUT=\\\"${KEYBOARD}\\\"/\\\" /etc/default/keyboard\"]" "$1"
    yq -i -y ".runcmd += [\"sed -i -E \\\"s/^XKBVARIANT.*/XKBVARIANT=\\\"${KEYBOARD_VARIANT}\\\"/\\\" /etc/default/keyboard\"]" "$1"
    yq -i -y ".runcmd += [\"dpkg-reconfigure -f noninteractive keyboard-configuration\"]" "$1"
    yq -i -y ".runcmd += [\"setupcon\"]" "$1"
}

apply_patches() {
    local vendor_data_file="$1"
    local image_file="$2"
    
    IFS=' ' read -ra patches_array <<< "$PATCHES_TO_APPLY"
    for patch in "${patches_array[@]}"; do
        local func="patch_${patch}"
        if declare -f "$func" > /dev/null; then
            echo "Applying patch $patch..."
            "$func" "$vendor_data_file" "$image_file"
        else
            echo "Warning: Unknown patch '$patch' specified. Skipping."
        fi
    done
}

# Function to create the VM template
create_template() {
    local image_file="$1"
    local snippets_storage="${SNIPPETS_STORAGE_CONFIG[name]}"
    local disk_storage="${DISK_STORAGE_CONFIG[name]}"
    local snippets_dir="${SNIPPETS_STORAGE_CONFIG[snippets_dir]}"
    local vendor_data_file="${snippets_dir}/ci-vendor-data-${ID}.yml"

    echo "--- Creating template $NAME (ID: $ID) ---"

    # Create a working copy of the image
    local ext="${image_file##*.}"
    local working_image="${NAME}.${ext}"
    cp "$image_file" "$working_image"

    # Resize disk if size specified
    if [[ -n "$DISK_SIZE" ]]; then
        echo "Resizing disk to $DISK_SIZE..."
        quiet_run qemu-img resize "$working_image" "$DISK_SIZE"
    fi

    local tmp_yaml
    tmp_yaml=$(mktemp)

    # Create cloud-init snippets
    generate_ci_vendor_data "$tmp_yaml"

    # Apply patches if specified
    if [[ -n "$PATCHES_TO_APPLY" ]]; then
        apply_patches "$tmp_yaml" "$working_image"
    fi

    # Prepend header and create the final config file
    {
        echo "#cloud-config"
        cat "$tmp_yaml"
    } > "$vendor_data_file"

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
        --scsi1 "$disk_storage:cloudinit"
        --boot "order=scsi0"
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

    # Cleanup
    rm -f "$tmp_yaml"
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

# --- Distro detection ---
detect_distro() {
    local image_file="$1"

    # Try to detect the distro using virt-inspector
    local detected
    detected=$(virt-inspector --no-applications -a "$image_file" 2>/dev/null | grep '<distro>' | head -1 | sed -E 's/.*<distro>([^<]+)<\/distro>.*/\1/')
    if [[ -z "$detected" ]]; then
        die "Could not detect distro from image $image_file."
    fi
    DISTRO="$detected"
    echo "Detected distro: $DISTRO"
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

# Function to check for a dependency and install if missing
check_and_install_dependency() {
    local dep="$1"
    local package="$2"
    if ! command -v "$dep" &> /dev/null; then
        echo "$dep is not installed. Would you like to install it now? [Y/n]" >&2
        read -r yn
        case $yn in
            [Yy]*|"")
                echo "Installing $package..." >&2
                quiet_run apt update && quiet_run apt install -y "$package"
                if ! command -v "$dep" &> /dev/null; then
                    echo "$dep installation failed. Exiting." >&2
                    exit 1
                fi
                ;;
            [Nn]*)
                echo "$dep is required. Exiting." >&2
                exit 1
                ;;
            *)
                echo "Please answer yes or no." >&2
                exit 1
                ;;
        esac
    fi
}

# --- Main script logic ---

main() {
    

    check_and_install_dependency yq yq
    check_and_install_dependency wget wget
    check_and_install_dependency qemu-img qemu-utils
    check_and_install_dependency virt-inspector libguestfs-tools

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
            --patches)
                PATCHES_TO_APPLY="$2"
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

    # Validate arguments after parsing (DISTRO is now set)
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

    # Download the image if not present
    local image_file
    image_file=$(basename "$CLOUD_IMAGE_URL")
    if [[ ! -f "$image_file" ]]; then
        echo "Downloading image from $CLOUD_IMAGE_URL..."
        wget -q --show-progress -O "$image_file" "$CLOUD_IMAGE_URL"
    fi

    # Detect distro from image
    detect_distro "$image_file"

    # Check if distro is supported
    if [[ ! " ${SUPPORTED_DISTROS[*]} " == *" $DISTRO "* ]]; then
        die "Unsupported distro '$DISTRO'. Supported distros: ${SUPPORTED_DISTROS[*]}"
    fi

    create_template "$image_file"
}

# Run the main function with all script arguments
main "$@"
