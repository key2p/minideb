#!/bin/bash
#
# ZPod OS Build Script
# This script builds the ZPod installation artifacts:
# - zpod.tar.gz: For online installation (dd.sh) and upgrades. Contains vmlinuz and initrd.
# - zpod.iso: A bootable ISO for fresh installations.

set -euo pipefail # Exit on error, undefined variable, or pipe failure

if [ -f "${PWD}/scripts/install/init" ]; then
    export SCRIPT_DIR="$PWD/scripts"
else
    export SCRIPT_DIR=$PWD
fi

# --- Configuration ---
KERNEL_URL="https://github.com/key2p/IPQ/releases/download/6.17_cloud/linux-image-6.17.7-x64v3-xanmod1_6.17.7-2_amd64.deb"
ABI="v3"

BUILD_TARGET="all"

# Check command line arguments
if [ $# -eq 0 ]; then
    echo "Usage: $0 [-k kernel_deb_url] [-a abi] [--all|--gz|--iso]"
    echo "  all: Build both gz and iso (default)"
    echo "  gz: Build only zpod.tar.gz"
    echo "  iso: Build only zpod.iso"
    exit 1
fi

while [[ $# -ge 1 ]]; do
    case $1 in
    -a|--abi)
        shift
        ABI="$1"
        shift
        ;;
    -k|--kernel)
        shift
        KERNEL_URL="$1"
        shift
        ;;
    --iso)
        BUILD_TARGET="iso"
        shift
        ;;
    --gz)
        BUILD_TARGET="gz"
        shift
        ;;
    --all)
        BUILD_TARGET="all"
        shift
        ;;
    *)
      echo "Unknown option: "
      exit 1;
        ;;
    esac
done

PODMAN_URL="https://github.com/mgoltzsche/podman-static/releases/latest/download/podman-linux-amd64.tar.gz"
ALPINE_ROOTFS_URL="https://github.com/key2p/minideb/releases/download/alpine-rootfs/alpine-part-rootfs.tar.gz"

# now not used. crun instead
#YOUKI_URL="https://github.com/youki-dev/youki/releases/latest/download/youki-0.5.7-x86_64-musl.tar.gz"

KERNEL_PATH="/dev/shm/kernel${ABI}.deb"
PODMAN_PATH="/dev/shm/podman-linux-amd64.tar.gz"

YOUKI_PATH="/dev/shm/youki-musl.tar.gz"
ALPINE_PATH="/dev/shm/alpine-part-rootfs.tar.gz"
DISKIMG_PATH="/dev/shm/disk.img.xz"

# Work directory for all build operations
WORKDIR="/dev/shm/cache/build_zpod"
# Final output directory
OUTPUT_DIR="/dev/shm/cache/dist"
PODMAN_CACHE="/dev/shm/podman_cache"

# --- Logging function ---
C_RESET='\033[0m'
C_GREEN='\033[0;32m'
C_BLUE='\033[0;34m'

log_info() {
    echo -e "${C_BLUE}==>${C_RESET} ${C_GREEN}$1${C_RESET}"
}

log_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; exit 1
}


# --- Cleanup function ---
cleanup() {
    log_info "Cleaning up..."

    local mount_dir="${WORKDIR}/img_mount"
    mountpoint -q "${mount_dir}/boot/efi" && (umount "${mount_dir}/boot/efi" &> /dev/null|| true)
    mountpoint -q "$mount_dir" && (umount "$mount_dir" &> /dev/null || true)

    # In case of script failure, unmount any mounted loop devices
    if losetup -a | grep -q "${WORKDIR}/disk.img"; then
        LOOP_DEV=$(losetup -a | grep "${WORKDIR}/disk.img" | cut -d: -f1)
        if [ -n "$LOOP_DEV" ]; then
            log_info "Detaching loop device ${LOOP_DEV}..."
            losetup -d "${LOOP_DEV}"
        fi
    fi

    # The script is designed to work within WORKDIR, so we don't delete it here
    # to allow inspection of build artifacts after a run.
    log_info "Cleanup finished."
}

check_dependencies() {
    log_info "Checking for required build tools..."

    local missing=0
    local tools=(
        curl tar gzip xz
        dpkg-deb parted fallocate losetup mkfs.vfat mkfs.ext4
        xorriso grub-mkrescue
    )

    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            echo "Error: Required tool '$tool' is not installed." >&2
            missing=1
        fi
    done

    if [ $missing -eq 1 ]; then
        echo "Please install the missing tools to proceed." >&2
        echo "On Debian/Ubuntu: sudo apt-get install curl tar gzip xz-utils dpkg parted fdisk util-linux dosfstools e2fsprogs xorriso grub-pc-bin grub-efi-amd64-bin" >&2
        exit 1
    fi
}

# Prepare the build environment
setup_environment() {
    log_info "Setting up build environment in ${WORKDIR}"
    rm -rf "${WORKDIR}" "${OUTPUT_DIR}"
    # Main structure for initrd
    mkdir -p "${WORKDIR}/initrd"/{bin,etc,lib,os/bin,installer,proc,sys,dev,tmp,rom}
    # Structure for the ISO
    mkdir -p "${WORKDIR}/iso/boot/grub"
    # Structure for the podman and ext4 disk img
    mkdir -p "${WORKDIR}/os"
    # Final output directory
    mkdir -p "${OUTPUT_DIR}"
}

# 1 & 2. Download and extract the Xanmod kernel
download_and_extract_kernel() {
    log_info "Downloading and extracting kernel..."
    local extract_dir="${WORKDIR}/kernel_extracted"
    
    [ ! -e "${KERNEL_PATH}" ] && curl -L -o "${KERNEL_PATH}" "$KERNEL_URL"
    dpkg-deb -R "$KERNEL_PATH" "$extract_dir"

    # Find the kernel image and modules
    local vmlinuz_path=$(find "$extract_dir/boot" -name "vmlinuz-*")
    # local modules_path=$(find "$extract_dir/lib/modules" -type d -name "*-xanmod*")
    local modules_path="$extract_dir/lib/modules"

    if [ -z "$vmlinuz_path" ] || [ -z "$modules_path" ]; then
        echo "Error: Could not find vmlinuz or modules in the downloaded deb package." >&2
        exit 1
    fi

    # Copy to their final destinations for the build
    cp "$vmlinuz_path" "${WORKDIR}/zpod-vmlinuz"
    cp -r "$modules_path" "${WORKDIR}/initrd/lib/modules/"

    log_info "Kernel extracted successfully."
}

# 3. Download and place Podman static binary
download_podman_static() {
    log_info "Downloading Podman static binary..."
    [ ! -e "${PODMAN_PATH}" ] && curl -L -o "${PODMAN_PATH}" "$PODMAN_URL"

    if [ ! -d "${PODMAN_CACHE}" ]; then
        mkdir -p "${PODMAN_CACHE}" || true
        # Extract directly into the 'os' directory which will be copied to /boot/os
        tar -xzf "${PODMAN_PATH}" -C "${PODMAN_CACHE}" --strip-components=1

        # reduce size
        strip "${PODMAN_CACHE}/usr/local/bin/podman"
        strip "${PODMAN_CACHE}/usr/local/bin/crun"
        strip "${PODMAN_CACHE}/usr/local/lib/podman/netavark"

        time upx -q --best --lzma "${PODMAN_CACHE}/usr/local/bin/podman"
        time upx -q --best --lzma "${PODMAN_CACHE}/usr/local/lib/podman/netavark"
        time upx -q --best --lzma "${PODMAN_CACHE}/usr/local/lib/podman/aardvark-dns"
        time upx -q --best --lzma "${PODMAN_CACHE}/usr/local/lib/podman/rootlessport"
        time upx -q --best --lzma "${PODMAN_CACHE}/usr/local/lib/podman/conmon"

        
        # 默认使用 crun, 当youki 足够稳定再切换到 youki
        #[ ! -e "${YOUKI_PATH}" ] && curl -L -o "${YOUKI_PATH}" "$YOUKI_URL"
        #tar -xzf "${YOUKI_PATH}" -C "${PODMAN_CACHE}/usr/local/bin"
    fi

    cp -rf "${PODMAN_CACHE}"/* "${WORKDIR}/initrd/" || true
    
    chmod +x "${WORKDIR}/initrd/usr/local/bin/"*

    rm -f "${WORKDIR}/initrd/usr/local/libexec/podman/quadlet"
    rm -f "${WORKDIR}/initrd/usr/local/bin/runc"

    mkdir -p "${WORKDIR}/initrd/licenses" || true
    mv "${WORKDIR}/initrd/usr/local/bin/LICENSE" "${WORKDIR}/initrd/licenses"  || true

    rm -f "${WORKDIR}/initrd/usr/local/bin/README.md" || true
    rm -f "${WORKDIR}/initrd/README.md" || true

    log_info "Podman installed in /initrd/."
}


# 4. Prepare the Alpine-based initrd rootfs
prepare_initrd_rootfs() {
    log_info "Preparing initrd with Alpine minirootfs..."

    [ ! -e "${ALPINE_PATH}" ] && curl -L -o "${ALPINE_PATH}" "$ALPINE_ROOTFS_URL"
    tar -xzf "${ALPINE_PATH}" -C "${WORKDIR}/initrd"

    # Alpine's busybox provides all necessary tools
    # We just need to ensure our directory structure exists
    log_info "Copying installer scripts..."
    # This assumes you have an 'install' directory alongside build.sh
    # with an 'init' script inside it.
    if [ ! -f "${SCRIPT_DIR}/install/init" ]; then
        echo "Error: Installer script 'install/init' not found." >&2
        echo "Please create this file." >&2
        exit 1
    fi

    # podman runtime to youki
    if [ ! -f "${WORKDIR}/initrd/etc/containers/containers.conf" ]; then
        echo '[engine]' > "${WORKDIR}/initrd/etc/containers/containers.conf"
    fi
    
    # 在 initramfs 中, 无法使用默认的 pivot_root 切换到 容器的 rootfs
    # https://man.archlinux.org/man/containers.conf.5.en
    # https://forum.tinycorelinux.net/index.php/topic,21089.0.html
    # https://forums.docker.com/t/tinycore-8-0-x86-pivot-root-invalid-argument/32633
    echo 'no_pivot_root = true' >> "${WORKDIR}/initrd/etc/containers/containers.conf"

    # 足够稳定的时候再切换到 youki
    #echo 'runtime = "/usr/local/bin/youki"' >> "${WORKDIR}/initrd/etc/containers/containers.conf"
 
    # dropbear host key
    mkdir -p "${WORKDIR}/initrd/etc/dropbear/" || true
    echo "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMOLyz3cG2NHr6BpTzDoA56cObh+tTrRwdbv9aJaZdxoHF2hU9UaPcQKsJ6eAmDbfQFrwPoYsye2ddmxo54Edr0AAAAhAIWqQdlQyVLMIRn+ED9kk4unCDmYiw8sE7n4Cs/Ujm0E" | base64 -d - > "${WORKDIR}/initrd/etc/dropbear/dropbear_ecdsa_host_key"
    chmod 0600 "${WORKDIR}/initrd/etc/dropbear/dropbear_ecdsa_host_key"

    # copy mdev files
    mkdir -p "${WORKDIR}/initrd/lib/mdev"
    cp -f ${SCRIPT_DIR}/install/mdev/* "${WORKDIR}/initrd/lib/mdev"
    mv "${WORKDIR}/initrd/lib/mdev/mdev.conf" "${WORKDIR}/initrd/etc/mdev.conf"
    chmod +x "${WORKDIR}/initrd/lib/mdev/"*

    cp -f ${SCRIPT_DIR}/install/init_functions "${WORKDIR}/initrd/bin/"
    chmod +x "${WORKDIR}/initrd/bin/init_functions"

    cp -f ${SCRIPT_DIR}/install/init_install "${WORKDIR}/initrd/sbin/init_install"
    chmod +x "${WORKDIR}/initrd/sbin/init_install"

    cp -f ${SCRIPT_DIR}/install/init "${WORKDIR}/initrd/init"
    chmod +x "${WORKDIR}/initrd/init"
}

# 5. Build the empty disk image for the installer
build_disk_img() {
    log_info "Building disk.img template..."

    if [  -e "${DISKIMG_PATH}" ]; then
        cp -f "${DISKIMG_PATH}" "${WORKDIR}/disk.img.xz"
        return
    fi

    local img_file="/dev/shm/disk.img"
    local mount_dir="${WORKDIR}/img_mount"
    local img_size="356M" # 30M EFI + 400M BOOT + 64 ROOT + buffer

    # Create a sparse file
    fallocate -l "$img_size" "$img_file"

    # Create partitions using parted
    # 注意ESP分区太小如32M, 导致可能无法启动; BIOS 分区设置为1M 也可能无法启动
    parted -s "$img_file" \
        mklabel gpt \
        mkpart ESP fat32 1MiB 62MiB \
        set 1 esp on \
        mkpart primary 62MiB 64MiB \
        set 2 bios_grub  on \
        mkpart boot ext4 64MiB 320MiB \
        mkpart root ext4 320MiB 100%

    # Format the partitions using a loop device
    LOOP_DEV=$(losetup -f --show -P "$img_file")
    mkfs.vfat -F 32 -n ESP "${LOOP_DEV}p1"
    mkfs.ext4 -L ZPOD_BOOT "${LOOP_DEV}p3"
    mkfs.ext4 -L ZPOD_ROOT "${LOOP_DEV}p4"

    # p2 = BIOS Boot (不格式化), p1 = EFI, p3 = /boot, p4 = /
    mkdir -p "${mount_dir}" && mount "${LOOP_DEV}p3" "$mount_dir"           # 挂载 boot 分区 (p3)
    mkdir -p "${mount_dir}/boot/efi" && mount "${LOOP_DEV}p1" "${mount_dir}/boot/efi" # 挂载 EFI 分区 (p1)

    log_info "Installing GRUB for both EFI and BIOS..."
    # Install GRUB for EFI (64-bit)
    grub-install \
        --target=x86_64-efi \
        --efi-directory="${mount_dir}/boot/efi" \
        --boot-directory="${mount_dir}/boot" \
        --removable \
        --no-floppy || log_error "GRUB EFI install failed!"

    # Install GRUB for Legacy BIOS (MBR)
    grub-install \
        --target=i386-pc \
        --modules="ext2 iso9660 xzio" \
        --boot-directory="${mount_dir}/boot" \
        --no-floppy \
        "$LOOP_DEV" || log_error "GRUB BIOS install failed!"

    # 删除不必要的重复文件, 其在外层initrd中还会存在. 容易出现bios 和 mod 不匹配的情况, 特别是 硬盘安装的时候
    #rm -rf "${mount_dir}/boot/grub/x86_64-efi"
    #rm -rf "${mount_dir}/boot/grub/i386-pc"
    #rm -rf "${mount_dir}/boot/grub/fonts"
  
    # Unmount everything cleanly
    mountpoint -q "${mount_dir}/boot/efi" && umount "${mount_dir}/boot/efi"
    mountpoint -q "$mount_dir" && umount "$mount_dir"
    
    zerofree -v "${LOOP_DEV}p3"  # /boot 分区
    zerofree -v "${LOOP_DEV}p4"  # /root 分区

    losetup -d "$LOOP_DEV"
    LOOP_DEV="" # Clear variable after detaching
    rm -rf "$mount_dir"

    log_info "Compressing disk.img..."
    xz -9 -c "$img_file" > "${DISKIMG_PATH}"
    cp -f "${DISKIMG_PATH}" "${WORKDIR}/disk.img.xz"

    rm "$img_file"

    log_info "disk.img.xz created in ${WORKDIR} ."
}


# 7. Build the final artifacts (initrd, iso)
build_final_artifacts() {
    log_info "Building final artifacts..."

    rm "${WORKDIR}/initrd/sbin/reboot" || true
    cat > "${WORKDIR}/initrd/sbin/reboot" << EOF
#!/bin/sh
sync; echo '[*] Zpod will reboot after 6s'; sleep 2; sync; /bin/busybox reboot; sleep 4; echo 'b' > /proc/sysrq-trigger
EOF
    chmod +x "${WORKDIR}/initrd/sbin/reboot"

    chmod +x "${SCRIPT_DIR}/optmize.sh"
    . "${SCRIPT_DIR}/optmize.sh"

    # 优化 sysctl
    do_optimize "${WORKDIR}/initrd"
    date > "${WORKDIR}/initrd/zpod_build_info"

    # Create the main installer initrd
    pushd "${WORKDIR}/initrd" > /dev/null
    time find . | cpio -o -H newc | xz -9 --check=crc32 > "${WORKDIR}/zpod-initrd"
    popd > /dev/null

    # --- Build zpod.tar.gz ---
    pushd "${WORKDIR}" > /dev/null
    if [ "$BUILD_TARGET" = "gz" ] ||  [ "$BUILD_TARGET" = "all" ]; then
        log_info "Creating ${OUTPUT_DIR}/zpod${ABI}.tar.gz..."
        time tar -czf "${OUTPUT_DIR}/zpod${ABI}.tar.gz" zpod-vmlinuz zpod-initrd disk.img.xz
    fi

    popd > /dev/null

    # --- Build zpod.iso ---
    if [ "$BUILD_TARGET" = "iso" ] ||  [ "$BUILD_TARGET" = "all" ]; then
        log_info "Creating ${OUTPUT_DIR}/zpod${ABI}.iso..."

        # Prepare ISO contents
        cp "${WORKDIR}/zpod-vmlinuz" "${WORKDIR}/iso/boot/"
        cp "${WORKDIR}/zpod-initrd" "${WORKDIR}/iso/boot/"
        cp "${WORKDIR}/disk.img.xz" "${WORKDIR}/iso/boot/"

        # Create GRUB config for the ISO
        cat > "${WORKDIR}/iso/boot/grub/grub.cfg" << EOF
set timeout=3
set default=0

menuentry "Install ZPod OS" {
    echo "Loading kernel..."
    linux /boot/zpod-vmlinuz net.ifnames=0 biosdevname=0 quiet
    initrd /boot/zpod-initrd
}
EOF

        # Use grub-mkrescue which is a wrapper around xorriso for making bootable GRUB ISOs
        time grub-mkrescue --compress=xz -o "${OUTPUT_DIR}/zpod${ABI}.iso" "${WORKDIR}/iso" -- -volid "ZPOD_INSTALL"
    fi

    log_info "All artifacts built successfully in ${OUTPUT_DIR}."
}


# --- Main Execution Flow ---

# Register the cleanup function to run on script exit
trap cleanup EXIT

check_dependencies
setup_environment

# --- Build Steps ---
download_and_extract_kernel
download_podman_static
build_disk_img
prepare_initrd_rootfs

# Final artifact creation depends on the target
if [ "$BUILD_TARGET" = "all" ] || [ "$BUILD_TARGET" = "gz" ] || [ "$BUILD_TARGET" = "iso" ]; then
    build_final_artifacts
else
    echo "Error: Invalid build target '$BUILD_TARGET'." >&2
    exit 1
fi

log_info "Build finished."