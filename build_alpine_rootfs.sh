#!/bin/bash
#
# build-custom-alpine.sh
#
# This script automates the creation of a custom Alpine Linux minirootfs.
# It performs the following steps:
# 1. Dynamically finds the latest stable minirootfs URL from Alpine's servers.
# 2. Downloads the rootfs.
# 3. Sets up a chroot environment.
# 4. Updates all packages to their latest versions.
# 5. Installs 'cloud-utils-growpart' and 'e2fsprogs-extra'.
# 6. Cleans up and packages the new, custom rootfs into a tar.gz archive.

set -euo pipefail # Exit on error, undefined variable, or pipe failure

# --- Configuration ---
ALPINE_RELEASES_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64"
OUTPUT_FILE="/dev/shm/alpine-part-rootfs.tar.gz"
WORKDIR=/dev/shm/alpine-rootfs

# --- Colors for logging ---
C_RESET='\033[0m'
C_GREEN='\033[0;32m'
C_BLUE='\033[0;34m'
C_RED='\033[0;31m'

# --- Logging functions ---
log_info() {
    echo -e "${C_BLUE}==>${C_RESET} ${C_GREEN}$1${C_RESET}"
}
log_error() {
    echo -e "${C_RED}[ERROR]${C_RESET} $1" >&2
}


# --- Cleanup function ---
do_umount() {
    # Unmount chroot directories in reverse order, checking if they are mounted first
    #if mountpoint -q "${chroot_dir}/etc/ssl/certs"; then
    #    umount "${chroot_dir}/etc/ssl/certs"
    #fi

    if mountpoint -q "${chroot_dir}/dev"; then
        umount "${chroot_dir}/dev"
    fi
    if mountpoint -q "${chroot_dir}/sys"; then
        umount "${chroot_dir}/sys"
    fi
    if mountpoint -q "${chroot_dir}/proc"; then
        umount "${chroot_dir}/proc"
    fi
}

cleanup() {
    log_info "Cleaning up..."
    local chroot_dir="${WORKDIR}/rootfs"

   
    # Remove the entire temporary directory
    do_umount
    rm -rf "${WORKDIR}"

    log_info "Cleanup finished."
}


# Check for root privileges and required dependencies
check_prerequisites() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root to use chroot and mount."
        exit 1
    fi

    for cmd in curl grep sed tar; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command '$cmd' is not installed."
            exit 1
        fi
    done

    mkdir -p "${WORKDIR}" || true
}

# Main script logic
main() {
    check_prerequisites
    trap cleanup EXIT

    log_info "Step 1: Finding the latest Alpine minirootfs..."
    local yaml_url="${ALPINE_RELEASES_URL}/latest-releases.yaml"
    
    # Parse the YAML file to find the minirootfs filename
    local minirootfs_file=$(curl -s "$yaml_url" | grep 'file: alpine-minirootfs' | awk '{print $2}' | cut -d ' ' -f2 | head -n 1)

    if [ -z "$minirootfs_file" ]; then
        log_error "Could not parse the minirootfs filename from the releases YAML."
        exit 1
    fi
    
    local download_url="${ALPINE_RELEASES_URL}/${minirootfs_file}"
    log_info "Found: ${minirootfs_file}"
    echo "${minirootfs_file}" > "/dev/shm/alpine_version"

    log_info "Step 2: Downloading the base rootfs..."
    curl -L -o "${WORKDIR}/minirootfs.tar.gz" "$download_url" || (echo "Failed to download the minirootfs $download_url." && exit 1)

    log_info "Step 3: Setting up the chroot environment..."
    local chroot_dir="${WORKDIR}/rootfs"
    mkdir -p "$chroot_dir"
    tar -xzf "${WORKDIR}/minirootfs.tar.gz" -C "$chroot_dir"

    # Mount necessary pseudo-filesystems for chroot to function
    mount --bind /proc "${chroot_dir}/proc"
    mount --bind /sys "${chroot_dir}/sys"
    mount --bind /dev "${chroot_dir}/dev"
    
    # Provide DNS resolution inside the chroot for apk
    #cp /etc/resolv.conf "${chroot_dir}/etc/"
    echo "nameserver 1.1.1.1" >> "${chroot_dir}/etc/resolv.conf"

    #echo "https://mirrors.ustc.edu.cn/alpine/v3.22/main" > "${chroot_dir}/etc/apk/repositories"
    #echo "https://mirrors.ustc.edu.cn/alpine/v3.22/community" >> "${chroot_dir}/etc/apk/repositories"

    #mount --bind /etc/ssl/certs "${chroot_dir}/etc/ssl/certs"
    #mkdir -p "${chroot_dir}/usr/share/ca-certificates" || true
    #mount --bind /usr/share/ca-certificates "${chroot_dir}/usr/share/ca-certificates"
    

    log_info "Step 4: Updating packages and installing tools inside chroot..."
    # We run all commands in a single chroot shell session for efficiency
    # --no-cache is used to avoid filling the rootfs with unnecessary cache files
    # cloud-utils-growpart e2fsprogs-extra for install growpart and mkfs.ext4
    # iptables busybox-openrc busybox-mdev-openrc for podman
    # dropbear for ssh maybe
    chroot "$chroot_dir" /bin/sh -c "date; ln -s /etc/ssl /usr/lib/ssl; apk --no-check-certificate update && \
        apk --no-check-certificate upgrade && \
        apk add -v --no-check-certificate cloud-utils-growpart e2fsprogs-extra iptables busybox-openrc busybox-mdev-openrc dropbear dropbear-ssh && \
        rc-update add cgroups && \
        rm -rf /var/cache/apk/*" || {
        log_error "Failed to run commands inside chroot. Check network or package errors."
        exit 1
    }

    log_info "Step 5: Cleaning up the chroot environment..."
    # The apk cache is already clean due to --no-cache. Just remove resolv.conf.
    rm "${chroot_dir}/etc/resolv.conf"
    # Unmounts will be handled by the cleanup trap function to ensure they always run.

    log_info "Step 6: Packaging the new custom rootfs..."
    do_umount
    # The -C flag tells tar to change to that directory before archiving.
    # The '.' at the end means "archive everything in this directory".
    # This creates a clean tarball without any leading path components.
    tar -czf "${OUTPUT_FILE}" -C "$chroot_dir" .
    chmod 0666 "${OUTPUT_FILE}"

    echo
    log_success "Custom Alpine rootfs created successfully!"
    log_success "Output file: ${OUTPUT_FILE}"
}

# A small wrapper for success messages
log_success() {
    echo -e "${C_GREEN}[SUCCESS]${C_RESET} $1"
}

# Run the main function
main
