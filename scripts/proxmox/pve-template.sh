#!/usr/bin/env bash

# ==============================================================================
# Script: pve-template.sh
# Description: Creates Proxmox VE templates from cloud images
# Version: 1.0.0
# Author: Proless
# Repository: https://github.com/Proless/proxmox
# ==============================================================================

set -e

# ==============================================================================
# GLOBAL VARIABLES & CONFIGURATION
# ==============================================================================
IMAGE_FILE=""

# Script constants
declare -a SUPPORTED_DISTROS=("alpinelinux" "debian" "ubuntu" "fedora" "rocky")

# Storage configuration
declare -A DISK_STORAGE_CONFIG=()
declare -A SNIPPETS_STORAGE_CONFIG=()

# Template identification
ID=""                               # ID for the template
NAME=""                             # Name for the template
DISTRO=""                           # Distro of the image (auto-detected)
CLOUD_IMAGE_URL=""                  # Cloud Image URL

# VM hardware configuration
declare -A VM_CONFIG=(
    [memory]="2048"                 # Memory in MB (default: 2048)
    [cores]="4"                     # Number of CPU cores (default: 4)
    [bridge]="vmbr0"                # The Proxmox network bridge for the VM (default: vmbr0)
    [display]="std"                 # Display type (e.g., std, cirrus, vmware, qxl)
)

# Disk configuration
declare -A DISK_CONFIG=(
    [size]=""                       # Disk size for the VM (e.g., 32G)
    [format]="qcow2"                # Disk format: qcow2 (default), raw, or vmdk
    [flags]="discard=on"            # Default disk flags
    [storage]="local-lvm"           # The Proxmox storage where the VM disk will be allocated (default: local-lvm)
)

# Cloud-Init configuration
declare -A CI_CONFIG=(
    [user]=""                       # Cloud-Init user
    [password]=""                   # Cloud-Init password
    [ssh_keys]=""                   # Path to file with public SSH keys
)

# Localization configuration
declare -A LOCALE_CONFIG=(
    [timezone]=""                   # Timezone
    [keyboard]=""                   # Keyboard layout
    [keyboard_variant]=""           # Keyboard variant
    [locale]=""                     # Locale
)

# Network configuration
declare -A NETWORK_CONFIG=(
    [dns_servers]=""                # DNS servers (space-separated, e.g., 8.8.8.8 8.8.4.4)
    [domain_names]=""               # Domain names (space-separated, e.g., example.com internal.local)
)

# Advanced options
PACKAGES_TO_INSTALL=""              # Space-separated list of packages to install inside the VM template
PATCHES_TO_APPLY=""                 # Space-separated list of patches to apply
SNIPPETS_STORAGE=""                 # Storage where snippets are stored (default: same as DISK_CONFIG[storage])

# ==============================================================================
# UTILITY
# ==============================================================================

quiet_run() {
    "$@" >/dev/null 2>&1 || {
        echo "Command failed: $*" >&2
        exit 1
    }
}

die() {
    echo "Error: $*" >&2
    exit 1
}

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
    echo "  --bridge <bridge>              Network bridge for VM (default: vmbr0)"
    echo "  --memory <mb>                  Memory in MB (default: 2048)"
    echo "  --cores <num>                  Number of CPU cores (default: 4)"
    echo "  --timezone <timezone>          Timezone (e.g., America/New_York, Europe/London)"
    echo "  --keyboard <layout>            Keyboard layout (e.g., us, uk, de)"
    echo "  --keyboard-variant <variant>   Keyboard variant (e.g., intl)"
    echo "  --locale <locale>              Locale (e.g., en_US.UTF-8, de_DE.UTF-8)"
    echo "  --ssh-keys <file>              Path to file with public SSH keys (one per line, OpenSSH format)"
    echo "  --disk-size <size>             Disk size (e.g., 32G, 50G, 6144M)"
    echo "  --disk-storage <storage>       Proxmox storage for VM disk (default: local-lvm)"
    echo "  --disk-format <format>         Disk format: ex. qcow2 (default)"
    echo "  --disk-flags <flags>           Space-separated Disk flags (default: discard=on)"
    echo "  --display <type>               Set the display/vga type (default: std)"
    echo "  --install <packages>           Space-separated list of packages to install in the template using cloud-init"
    echo "  --dns-servers <servers>        Space-separated DNS servers (e.g., '10.10.10.10 9.9.9.9')"
    echo "  --domain-names <domains>       Space-separated domain names (e.g., 'example.com internal.local')"
    echo "  --snippets-storage <storage>   Proxmox storage for cloud-init snippets (default: same as --disk-storage)"
    echo "  --patches <patches>            Space-separated list of patch names to apply"
    echo "  -h,  --help                    Display this help message"
    
    echo ""
    echo "Supported distros: ${SUPPORTED_DISTROS[*]}"

    echo ""
    echo "Supported patches (for --patches):"
    echo "  debian_locale                  Debian-specific: Set up locale"
    echo "  debian_keyboard                Debian-specific: Set up keyboard layout"
}

# ==============================================================================
# CLOUD-INIT
# ==============================================================================

ci_create_base_config() {
    local vendor_data_file="$1"

    # Create base vendor-data file with update settings
    yq -y -n \
        " .package_update = true
        | .package_upgrade = true
        | .package_reboot_if_required = true
        | .packages = []
        | .runcmd = []
        " > "$vendor_data_file"
}

ci_add_qemu_guest_agent() {
    local vendor_data_file="$1"

    # Add qemu-guest-agent package
    yq -i -y ".packages += [\"qemu-guest-agent\"]" "$vendor_data_file"

    # Add distro-specific commands to enable and start qemu-guest-agent
    case "$DISTRO" in
        debian|ubuntu|fedora|rocky)
            yq -i -y ".runcmd += [\"systemctl enable qemu-guest-agent\"]" "$vendor_data_file"
            yq -i -y ".runcmd += [\"systemctl start qemu-guest-agent\"]" "$vendor_data_file"
            ;;
        alpinelinux)
            yq -i -y ".runcmd += [\"rc-update add qemu-guest-agent default\"]" "$vendor_data_file"
            yq -i -y ".runcmd += [\"rc-service qemu-guest-agent start\"]" "$vendor_data_file"
            ;;
    esac
}

ci_add_extra_packages() {
    local vendor_data_file="$1"

    # Append extra packages if specified
    if [[ -n "$PACKAGES_TO_INSTALL" ]]; then
        IFS=' ' read -ra pkg_array <<< "$PACKAGES_TO_INSTALL"
        for pkg in "${pkg_array[@]}"; do
            yq -i -y ".packages += [\"$pkg\"]" "$vendor_data_file"
        done
    fi
}

ci_add_localization() {
    local vendor_data_file="$1"

    # Add locale configuration
    [[ -n "${LOCALE_CONFIG[locale]}" ]] && yq -i -y ".locale = \"${LOCALE_CONFIG[locale]}\"" "$vendor_data_file"
    
    # Add timezone configuration
    [[ -n "${LOCALE_CONFIG[timezone]}" ]] && yq -i -y ".timezone = \"${LOCALE_CONFIG[timezone]}\"" "$vendor_data_file"

    # Add keyboard configuration
    if [[ -n "${LOCALE_CONFIG[keyboard]}" ]]; then
        yq -i -y ".keyboard.layout = \"${LOCALE_CONFIG[keyboard]}\"" "$vendor_data_file"
        [[ -n "${LOCALE_CONFIG[keyboard_variant]}" ]] && yq -i -y ".keyboard.variant = \"${LOCALE_CONFIG[keyboard_variant]}\"" "$vendor_data_file"
    fi
}

ci_generate_vendor_data() {
    local vendor_data_file="$1"

    echo "Creating cloud-init vendor-data snippet..."

    # Build the cloud-init configuration
    ci_create_base_config "$vendor_data_file"
    ci_add_qemu_guest_agent "$vendor_data_file"
    ci_add_extra_packages "$vendor_data_file"
    ci_add_localization "$vendor_data_file"
}

# ==============================================================================
# PATCH
# ==============================================================================

patch_debian_locale() {
    local vendor_data_file="$1"

    # Remove the locale section from the YAML file
    yq -i -y "del(.locale)" "$vendor_data_file"
    # Add shell commands to runcmd for locale setup
    yq -i -y ".runcmd += [\"sed -i -E \\\"s/^# *\\\\(${LOCALE_CONFIG[locale]}\\\\)/\\\\1/\\\" /etc/locale.gen\"]" "$vendor_data_file"
    yq -i -y ".runcmd += [\"grep -q \\\"^${LOCALE_CONFIG[locale]}\\\" /etc/locale.gen || echo \\\"${LOCALE_CONFIG[locale]}\\\" >> /etc/locale.gen\"]" "$vendor_data_file"
    yq -i -y ".runcmd += [\"locale-gen\"]" "$vendor_data_file"
    yq -i -y ".runcmd += [\"update-locale LANG=\\\"${LOCALE_CONFIG[locale]}\\\"\"]" "$vendor_data_file"
    yq -i -y ".runcmd += [\"export LANG=\\\"${LOCALE_CONFIG[locale]}\\\"\"]" "$vendor_data_file"
}

patch_debian_keyboard() {
    local vendor_data_file="$1"
    
    # Remove the keyboard section from the YAML file
    yq -i -y "del(.keyboard)" "$vendor_data_file"
    # Add required packages
    yq -i -y ".packages += [\"keyboard-configuration\"]" "$vendor_data_file"
    yq -i -y ".packages += [\"console-setup\"]" "$vendor_data_file"
    # Add shell commands to runcmd for keyboard setup
    yq -i -y ".runcmd += [\"sed -i -E \\\"s/^XKBMODEL.*/XKBMODEL=\\\"pc105\\\"/\\\" /etc/default/keyboard\"]" "$vendor_data_file"
    yq -i -y ".runcmd += [\"sed -i -E \\\"s/^XKBLAYOUT.*/XKBLAYOUT=\\\"${LOCALE_CONFIG[keyboard]}\\\"/\\\" /etc/default/keyboard\"]" "$vendor_data_file"
    yq -i -y ".runcmd += [\"sed -i -E \\\"s/^XKBVARIANT.*/XKBVARIANT=\\\"${LOCALE_CONFIG[keyboard_variant]}\\\"/\\\" /etc/default/keyboard\"]" "$vendor_data_file"
    yq -i -y ".runcmd += [\"dpkg-reconfigure -f noninteractive keyboard-configuration\"]" "$vendor_data_file"
    yq -i -y ".runcmd += [\"setupcon\"]" "$vendor_data_file"
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

# ==============================================================================
# TEMPLATE
# ==============================================================================

prepare_disk() {
    local image_file="$1"

    # Resize disk if size specified
    if [[ -n "${DISK_CONFIG[size]}" ]]; then
        echo "Resizing disk to ${DISK_CONFIG[size]}..."
        quiet_run qemu-img resize "$image_file" "${DISK_CONFIG[size]}"
    fi
}

create_vm() {
    local image_file="$1"

    echo "Creating VM $ID..."
    quiet_run qm create "$ID" --name "$NAME" \
        --memory "${VM_CONFIG[memory]}" \
        --cpu host \
        --cores "${VM_CONFIG[cores]}" \
        --net0 "virtio,bridge=${VM_CONFIG[bridge]}" \
        --agent enabled=1 \
        --ostype l26 \
        --vga "${VM_CONFIG[display]}" \
        --serial0 socket

    echo "Importing disk..."
    quiet_run qm importdisk "$ID" "$image_file" "${DISK_STORAGE_CONFIG[name]}" --format "${DISK_CONFIG[format]}"
}

configure_vm() {
    echo "Configuring VM storage and cloud-init..."

    # Build disk path based on storage type
    local disk_path
    if [[ "${DISK_STORAGE_CONFIG[type]}" =~ ^(lvmthin|zfspool)$ ]]; then
        # Block storage types use simple format: storage:vm-ID-disk-N
        disk_path="${DISK_STORAGE_CONFIG[name]}:vm-$ID-disk-0"
    else
        # Directory-based storage types use: storage:ID/vm-ID-disk-N.format
        disk_path="${DISK_STORAGE_CONFIG[name]}:$ID/vm-$ID-disk-0.${DISK_CONFIG[format]}"
    fi

    # Build qm set command with conditional cloud-init parameters
    local qm_cmd=(qm set "$ID"
        --scsihw "virtio-scsi-single"
        --scsi0 "${disk_path},${DISK_CONFIG[flags]// /,}"
        --scsi1 "${DISK_STORAGE_CONFIG[name]}:cloudinit"
        --boot "order=scsi0"
        --ciupgrade 1
        --cicustom "vendor=${SNIPPETS_STORAGE_CONFIG[name]}:snippets/ci-vendor-data-${ID}.yml"
        --ipconfig0 "ip=dhcp"
    )

    # Add DNS servers if specified
    [[ -n "${NETWORK_CONFIG[dns_servers]}" ]] && qm_cmd+=(--nameserver "${NETWORK_CONFIG[dns_servers]}")

    # Add search domain if specified
    [[ -n "${NETWORK_CONFIG[domain_names]}" ]] && qm_cmd+=(--searchdomain "${NETWORK_CONFIG[domain_names]}")

    # Add cloud-init user settings if user is specified
    if [[ -n "${CI_CONFIG[user]}" ]]; then
        qm_cmd+=(--ciuser "${CI_CONFIG[user]}")
        [[ -n "${CI_CONFIG[password]}" ]] && qm_cmd+=(--cipassword "${CI_CONFIG[password]}")
        [[ -n "${CI_CONFIG[ssh_keys]}" ]] && qm_cmd+=(--sshkeys "${CI_CONFIG[ssh_keys]}")
    fi

    quiet_run "${qm_cmd[@]}"
}

# Function to create the VM template
create_template() {
    echo "Creating template $NAME (ID: $ID)..."

    local tmp_yaml
    local image_copy
    local vendor_data_file

    tmp_yaml=$(mktemp)
    image_copy="${NAME}.${IMAGE_FILE##*.}"
    vendor_data_file="${SNIPPETS_STORAGE_CONFIG[snippets_dir]}/ci-vendor-data-${ID}.yml"
    
    # Create a copy of the image
    cp "$IMAGE_FILE" "$image_copy"

    # Create cloud-init snippets
    ci_generate_vendor_data "$tmp_yaml"
    
    # Apply patches if specified
    if [[ -n "$PATCHES_TO_APPLY" ]]; then
        apply_patches "$tmp_yaml" "$image_copy"
    fi

    # Prepend header and create the final ci config file
    {
        echo "#cloud-config"
        cat "$tmp_yaml"
    } > "$vendor_data_file"

    # Prepare the disk
    prepare_disk "$image_copy"

    # Create VM
    create_vm "$image_copy"

    # Configure VM
    configure_vm

    # Convert to template
    echo "Converting VM $ID to a template..."
    quiet_run qm template "$ID"
    
    # Clean up temporary files
    rm -f "$tmp_yaml"
    rm -f "$image_copy"

    echo "Template $NAME created successfully"
}

# ==============================================================================
# ARGUMENT
# ==============================================================================

require_arg_file() {
    if [[ ! -f "$1" || ! -s "$1" ]]; then
        die "File not found or empty: $2 ($1)"
    fi
}

require_arg_string() {
    if [[ -z "$1" ]]; then
        die "Missing required argument: $2"
    fi
}

require_arg_number() {
    if ! [[ "$1" =~ ^[0-9]+$ && "$1" -gt 0 ]]; then
        die "Argument '$2' must be a positive number (got '$1')"
    fi
}

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

parse_arguments() {
    # Validate minimum arguments
    if [[ "$#" -lt 3 ]]; then
        usage
        exit 1
    fi

    # Ensure first three arguments are not options
    for argn in 1 2 3; do
        arg="${!argn}"
        if [[ "$arg" == --* ]]; then
            die "Argument $argn must be a value, not an option (got '$arg')"
        fi
    done

    # Set required positional arguments
    CLOUD_IMAGE_URL="$1"
    ID="$2"
    NAME="$3"
    shift 3

    # Parse optional arguments
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --user)             CI_CONFIG[user]="$2"; shift 2 ;;
            --password)         CI_CONFIG[password]="$2"; shift 2 ;;
            --memory)           VM_CONFIG[memory]="$2"; shift 2 ;;
            --cores)            VM_CONFIG[cores]="$2"; shift 2 ;;
            --bridge)           VM_CONFIG[bridge]="$2"; shift 2 ;;
            --disk-size)        DISK_CONFIG[size]="$2"; shift 2 ;;
            --disk-storage)     DISK_CONFIG[storage]="$2"; SNIPPETS_STORAGE="${SNIPPETS_STORAGE:-$2}"; shift 2 ;;
            --disk-format)      DISK_CONFIG[format]="$2"; shift 2 ;;
            --disk-flags)       DISK_CONFIG[flags]="$2"; shift 2 ;;
            --display)          VM_CONFIG[display]="$2"; shift 2 ;;
            --timezone)         LOCALE_CONFIG[timezone]="$2"; shift 2 ;;
            --keyboard)         LOCALE_CONFIG[keyboard]="$2"; shift 2 ;;
            --keyboard-variant) LOCALE_CONFIG[keyboard_variant]="$2"; shift 2 ;;
            --locale)           LOCALE_CONFIG[locale]="$2"; shift 2 ;;
            --ssh-keys)         CI_CONFIG[ssh_keys]="$2"; shift 2 ;;
            --dns-servers)      NETWORK_CONFIG[dns_servers]="$2"; shift 2 ;;
            --domain-names)     NETWORK_CONFIG[domain_names]="$2"; shift 2 ;;
            --snippets-storage) SNIPPETS_STORAGE="$2"; shift 2 ;;
            --install)          PACKAGES_TO_INSTALL="$2"; shift 2 ;;
            --patches)          PATCHES_TO_APPLY="$2"; shift 2 ;;
            -h|--help)          usage; exit 0 ;;
            *)                  break ;;
        esac
    done

    # Parse storage configuration
    parse_storage_config "${DISK_CONFIG[storage]}" DISK_STORAGE_CONFIG
    if [[ "$SNIPPETS_STORAGE" == "${DISK_CONFIG[storage]}" ]]; then
        # Copy storage config
        for key in "${!DISK_STORAGE_CONFIG[@]}"; do
            SNIPPETS_STORAGE_CONFIG["$key"]="${DISK_STORAGE_CONFIG[$key]}"
        done
    else
        parse_storage_config "$SNIPPETS_STORAGE" SNIPPETS_STORAGE_CONFIG
    fi
}

validate_args() {
    # Validate required parameters
    require_arg_string "$CLOUD_IMAGE_URL" "cloud image url (argument 1)"
    require_arg_number "$ID" "id (argument 2)"
    require_arg_string "$NAME" "name (argument 3)"

    require_arg_string "${DISK_CONFIG[storage]}" "disk storage (--disk-storage)"
    require_arg_string "${DISK_CONFIG[format]}" "disk format (--disk-format)"
    require_arg_string "${VM_CONFIG[bridge]}" "network bridge (--bridge)"

    require_arg_number "${VM_CONFIG[memory]}" "memory (--memory)"
    require_arg_number "${VM_CONFIG[cores]}" "cores (--cores)"

    if [[ -n "${CI_CONFIG[user]}" ]]; then
        if [[ -z "${CI_CONFIG[password]}" && -z "${CI_CONFIG[ssh_keys]}" ]]; then
            die "You must provide at least one of --password or --ssh-keys when --user is specified"
        fi

        # If SSH keys provided, check file existence
        if [[ -n "${CI_CONFIG[ssh_keys]}" ]]; then
            require_arg_file "${CI_CONFIG[ssh_keys]}" "SSH keys file"
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
    if [[ ! ",$supported_formats," == *",${DISK_CONFIG[format]},"* ]]; then
        die "Disk format '${DISK_CONFIG[format]}' is not supported by storage '${DISK_STORAGE_CONFIG[name]}' (type: ${DISK_STORAGE_CONFIG[type]}). Supported formats: $supported_formats"
    fi

    # Validate snippets storage supports snippets
    if [[ "${SNIPPETS_STORAGE_CONFIG[supports_snippets]}" != "true" ]]; then
        die "Storage '${SNIPPETS_STORAGE_CONFIG[name]}' does not support snippets. Supported content: ${SNIPPETS_STORAGE_CONFIG[content]}"
    fi

    # Verify actual directories are writable (Proxmox-specific)
    local snippets_dir="${SNIPPETS_STORAGE_CONFIG[snippets_dir]}"
    if [[ -n "$snippets_dir" ]] && [[ ! -w "$snippets_dir" ]]; then
        die "Snippets directory not writable: $snippets_dir"
    fi
}

validate_distro() {
    # Detect the distro using virt-inspector
    DISTRO=$(virt-inspector --no-applications -a "$IMAGE_FILE" 2>/dev/null | grep '<distro>' | head -1 | sed -E 's/.*<distro>([^<]+)<\/distro>.*/\1/')
    
    if [[ -z "$DISTRO" ]]; then
        die "Failed to detect distro from image"
    fi

    # Check if distro is supported
    if [[ ! " ${SUPPORTED_DISTROS[*]} " == *" $DISTRO "* ]]; then
        die "Unsupported distro '$DISTRO'. Supported distros: ${SUPPORTED_DISTROS[*]}"
    fi
    
    echo "Detected distro: $DISTRO"
}

# ==============================================================================
# MAIN
# ==============================================================================

download_image() {
    local image_file

    # Extract filename from URL
    image_file=$(basename "$CLOUD_IMAGE_URL")

    # Download if not already present
    if [[ ! -f "$image_file" ]]; then
        echo "Downloading image from $CLOUD_IMAGE_URL..."
        wget -q --show-progress -O "$image_file" "$CLOUD_IMAGE_URL"
    fi

    # Set the full path to the image file
    IMAGE_FILE=$(realpath "$image_file")
}

install_dependencies() {
    echo "Checking required dependencies..."
    local packages=()
    if ! command -v yq &> /dev/null; then
        packages+=("yq")
    fi
    if ! command -v wget &> /dev/null; then
        packages+=("wget")
    fi
    if ! command -v qemu-img &> /dev/null; then
        packages+=("qemu-utils")
    fi
    if ! command -v virt-inspector &> /dev/null; then
        packages+=("libguestfs-tools")
    fi

    if [[ "${#packages[@]}" -gt 0 ]]; then
        echo "Installing missing dependencies: ${packages[*]}..."
        quiet_run apt update
        quiet_run apt install -y "${packages[@]}" || die "Failed to install dependencies: ${packages[*]}"
    fi
}

main() {
    echo "--- Proxmox VE Template Creation Script ---"
    
    # Install dependencies
    install_dependencies

    # Parse and populate variables from command-line arguments
    parse_arguments "$@"

    # Validate arguments
    validate_args

    # Validate storage
    validate_storage

    # Download the image
    download_image

    # Detect distro from image
    validate_distro

    # Create the template
    create_template

    echo "--- Proxmox VE Template Creation Script ---"
}

# Run the main function with all script arguments
main "$@"
