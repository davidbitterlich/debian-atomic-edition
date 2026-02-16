image_name := env("BUILD_IMAGE_NAME", "debian-atomic-edition")
installer_suffix := "-installer"
image_name_installer := image_name + installer_suffix
image_tag := env("BUILD_IMAGE_TAG", "latest")
remote_registry := "ghcr.io/davidbitterlich"
base_dir := env("BUILD_BASE_DIR", ".")
filesystem := env("BUILD_FILESYSTEM", "ext4")
iso_dir := env("BUILD_ISO_DIR", base_dir + "/iso")
selinux := path_exists('/sys/fs/selinux')
host_arch_raw := `uname -m`
host_arch := `echo {{ host_arch_raw }} | sed 's/x86_64/amd64/g; s/aarch64/arm64/g'`

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

    just _prepare-iso-env
    just generate-bootable-image
    just _container-to-disk $remote_registry/$target_image:$tag

    just _create-squashfs
    #just _create-iso

_prepare-iso-env:
    #!/usr/bin/env bash
    set -euo pipefail
    
    rm -rf {{iso_dir}} {{work_dir}}
    
    mkdir -p {{iso_dir}}/{live,isolinux,EFI/boot}
    mkdir -p {{work_dir}}/{disk,mount}

_container-to-disk image:
    #!/usr/bin/env bash
    set -euox pipefail
    
    CONTAINER_ARCHIVE="container.tar"
    ARCHIVE_PATH="{{work_dir}}/disk/$CONTAINER_ARCHIVE"

    container_id=$({{container_runtime}} create {{image}})
    {{container_runtime}} export $container_id -o $ARCHIVE_PATH
    podman rm $container_id

_create-squashfs:
    #!/usr/bin/env bash
    set -euox pipefail
    
    CONTAINER_ARCHIVE="container.tar"
    ARCHIVE_PATH="{{work_dir}}/disk/$CONTAINER_ARCHIVE"
    ROOTFS_PATH="{{work_dir}}/disk/rootfs"
    SQUASHFS="{{iso_dir}}/live/filesystem.squashfs"

    # extract the tar file
    if [ -d "$ROOTFS_PATH" ]
    then
        sudo rm -rf "$ROOTFS_PATH"
    fi
    mkdir "$ROOTFS_PATH"
    sudo tar --numeric-owner -xf $ARCHIVE_PATH -C "$ROOTFS_PATH"
    modules_dir="${ROOTFS_PATH}/usr/lib/modules"
    echo "modules_dir=$modules_dir"
    modules_actual_dir=$(sh -c "ls -d $modules_dir/*")
    echo "modules_actual_dir=$modules_actual_dir"
    sudo cp "$modules_actual_dir"/vmlinuz "{{iso_dir}}/live/vmlinuz"
    sudo cp "$modules_actual_dir"/initramfs.img "{{iso_dir}}/live/initramfs.img"
    sudo mksquashfs "$ROOTFS_PATH" "$SQUASHFS" -comp xz -b 131072

    echo "SquashFS created: ${SQUASHFS}"

# dummy
_create-iso:
    # 1. we need to install grub into the iso folder
    {{ container_runtime }} run --rm -it -v {{iso_dir}}:/isodir debian:latest \
    apt-get update && apt-get install -y grub-efi-{{host_arch}}-bin && \
    grub-mkstandalone -O {{host_arch}}-efi -o BOOTX64.EFI "boot/grub/grub.cfg/grub.cfg"
    xorriso -as mkisofs \
        -iso-level 3 \
        -o live.iso \
        -full-iso9660-filenames \
        -volid "LIVE_ISO" \
        -eltorito-boot isolinux/isolinux.bin \
        -eltorito-catalog isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e EFI/boot/bootx64.efi \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -output iso/