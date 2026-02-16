image_name := env("BUILD_IMAGE_NAME", "debian-atomic-edition")
installer_suffix := "-installer"
image_name_installer := image_name + installer_suffix
image_tag := env("BUILD_IMAGE_TAG", "latest")
remote_registry := "ghcr.io/davidbitterlich"
base_dir := env("BUILD_BASE_DIR", ".")
filesystem := env("BUILD_FILESYSTEM", "ext4")
iso_dir := env("BUILD_ISO_DIR", base_dir + "/iso")
selinux := path_exists('/sys/fs/selinux')

iso_file := "debian-bootc-installer.iso"
work_dir := "build/work"

container_runtime := env("CONTAINER_RUNTIME", `command -v podman >/dev/null 2>&1 && echo podman || echo docker`)

build-containerfile $image_name=image_name:
    {{container_runtime}} build -f Containerfile -t "${image_name}:latest" .

bootc *ARGS:
    {{container_runtime}} run \
        --rm --privileged --pid=host \
        -it \
        -v /etc/containers:/etc/containers{{ if selinux == 'true' { ':Z' } else { '' } }} \
        -v /var/lib/containers:/var/lib/containers{{ if selinux == 'true' { ':Z' } else { '' } }} \
        {{ if selinux == 'true' { '-v /sys/fs/selinux:/sys/fs/selinux' } else { '' } }} \
        {{ if selinux == 'true' { '--security-opt label=type:unconfined_t' } else { '' } }} \
        -v /dev:/dev \
        -e RUST_LOG=debug \
        -v "{{ base_dir }}:/data" \
        "{{ image_name }}:{{ image_tag }}" bootc {{ ARGS }}

generate-bootable-image $base_dir=base_dir $filesystem=filesystem:
    #!/usr/bin/env bash
    if [ ! -e "${base_dir}/bootable.img" ] ; then
        fallocate -l 20G "${base_dir}/bootable.img"
    fi
    just bootc install to-disk --composefs-backend --via-loopback /data/bootable.img --filesystem "${filesystem}" --wipe --bootloader systemd

build-installer-image $target_image=image_name $target_tag=image_tag:
    {{container_runtime}} build -f Containerfile-installer --build-arg IMAGE={{target_image}} --build-arg TAG={{target_tag}} -t "{{image_name_installer}}:{{image_tag}}" .

build-iso $remote_registry=remote_registry $target_image=image_name $tag=image_tag $image_name_installer=image_name_installer:
    #!/usr/bin/env bash
    #just build-installer-image $remote_registry/$target_image $tag

    #just _prepare-iso-env
    sudo just generate-bootable-image
    just _compose-to-disk

    sudo just _create-squashfs

_prepare-iso-env:
    #!/usr/bin/env bash
    set -euo pipefail
    
    # Cleanup alte Builds
    rm -rf {{iso_dir}} {{work_dir}}
    
    # Erstelle Verzeichnisstruktur
    mkdir -p {{iso_dir}}/{live,isolinux,EFI/boot}
    mkdir -p {{work_dir}}/{disk,mount}
    
    # Installiere benötigte Tools (falls nicht vorhanden)
    if ! command -v mksquashfs &> /dev/null; then
        echo "Installing squashfs-tools..."
        sudo apt-get install -y squashfs-tools
    fi
    
    if ! command -v xorriso &> /dev/null; then
        echo "Installing xorriso..."
        sudo apt-get install -y xorriso isolinux syslinux-efi
    fi

_container-to-disk image:
    #!/usr/bin/env bash
    set -euo pipefail
    
    DISK_IMAGE="{{work_dir}}/disk/bootable.img"
    
    if [ ! -e "${DISK_IMAGE}" ]; then
        fallocate -l 20G "${DISK_IMAGE}"
    fi
    
    # OHNE --composefs-backend!
    {{container_runtime}} run --rm --privileged \
        -v "${PWD}/${DISK_IMAGE}:/target-disk.img:rw" \
        -v /dev:/dev \
        {{image}} \
        bootc install to-disk \
            --via-loopback /target-disk.img \
            --filesystem ext4 \
            --wipe \
            --bootloader systemd \
            --generic-image
    
    echo "Disk image created: ${DISK_IMAGE}"

_create-squashfs:
    #!/usr/bin/env bash
    set -euo pipefail
    
    DISK_IMAGE="bootable.img"
    MOUNT_DIR="build/work/mount"
    SQUASHFS="{{iso_dir}}/live/filesystem.squashfs"
    
    echo "${MOUNT_DIR}"
    echo "Mounting disk image..."
    LOOP_DEVICE=$(sudo losetup -f --show -P "${DISK_IMAGE}")
    echo "${LOOP_DEVICE}"
    sudo mount --verbose "${LOOP_DEVICE}p2" "${MOUNT_DIR}"
    
    echo "Copying kernel and initrd..."
    # base dir is /usr/lib/modules/<version>
    modules_dir="${MOUNT_DIR}/usr/lib/modules"
    modules_actual_dir=$modules_dir/$(ls -d "$modules_dir" | head -n1)
    sudo cp "$modules_actual_dir"/vmlinuz-* "{{iso_dir}}/live/vmlinuz"
    sudo cp "$modules_actual_dir"/initrd.img-* "{{iso_dir}}/live/initrd"

    echo "Creating squashfs (this may take a while)..."
    sudo mksquashfs "${MOUNT_DIR}" "${SQUASHFS}" \
        -comp xz \
        -b 1M \
        -Xbcj x86 \
        -Xdict-size 100% \
        -noappend
    
    echo "SquashFS created: ${SQUASHFS}"
    trap "sudo umount ${MOUNT_DIR} 2>/dev/null || true; sudo losetup -d ${LOOP_DEVICE} 2>/dev/null" EXIT
  