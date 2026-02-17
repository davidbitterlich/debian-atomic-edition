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
    {{container_runtime}} build -f Containerfile-installer --build-arg IMAGE={{target_image}} --build-arg TAG={{target_tag}} -t "{{image_name_installer}}:{{target_tag}}" .

build-iso $remote_registry=remote_registry $target_image=image_name $tag=image_tag $image_name_installer=image_name_installer:
    #!/usr/bin/env bash

    #image="localhost/$image_name_installer:$tag"
    #just build-installer-image "$remote_registry/$target_image" "$tag"
    #just _prepare-iso-env
    #just _container-to-disk $remote_registry/$target_image:$tag
    #just _create-squashfs
    just _process-grub-template
    just _create-iso

_prepare-iso-env:
    #!/usr/bin/env bash
    set -euo pipefail
    
    rm -rf {{iso_dir}}
    sudo rm -rf {{work_dir}}
    
    mkdir -p {{iso_dir}}/live
    mkdir -p {{iso_dir}}/boot/grub
    mkdir -p {{work_dir}}/disk

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

_process-grub-template:
    #!/usr/bin/env bash
    set -euox pipefail
    OS_RELEASE="{{work_dir}}/disk/rootfs/usr/lib/os-release"
    TMPL="build_files/grub/grub.cfg.template"
    DEST="build/grub.cfg"
    PRETTY_NAME="$(source "$OS_RELEASE" > /dev/null && echo "$PRETTY_NAME")"
    sed -e "s|@PRETTY_NAME@|$PRETTY_NAME|g" "$TMPL" > "$DEST"

_create-iso:
    #!/usr/bin/env bash
    set -xeuo pipefail
    cp -f build/grub.cfg {{iso_dir}}/boot/grub
    if [ -f "build/build-iso-internal.sh" ]
    then
      rm -f "build/build-iso-internal.sh"
    fi
    cat > build/build-iso-internal.sh << 'INNERSCRIPT'
    #!/bin/bash
    set -xeuo pipefail
    export DEBIAN_FRONTEND=noninteractive
    export arch="$(uname -m | sed 's/x86_64/amd64/g; s/aarch64/arm64/g')"
    apt-get update
    apt-get install -y grub-efi-$arch-bin grub2-common grub-efi-$arch systemd-boot-efi grub-efi-$arch-signed grub-efi-$arch-unsigned shim-signed shim-unsigned xorriso mtools p7zip-full dosfstools
    ISOROOT="$(realpath /app/{{ iso_dir }})"
    WORKDIR="$(realpath /app/{{ work_dir }})"
    mkdir -p $ISOROOT/EFI/BOOT
    ARCH_SHORT="$(echo $arch | sed 's/x86_64/x64/g' | sed 's/aarch64/aa64/g')"
    ARCH_32="$(echo $arch | sed 's/x86_64/ia32/g' | sed 's/aarch64/arm/g')"
    if [ "$arch" = "amd64" ]
    then
      cp -av /usr/lib/shim/shimx64.efi.signed "$ISOROOT/EFI/BOOT/BOOT${ARCH_SHORT^^}.EFI"
      cp -av /usr/lib/shim/shimx64.efi.signed "$ISOROOT/EFI/BOOT/shimx64.efi"
      cp -av /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed "$ISOROOT/EFI/BOOT/grubx64.efi"
      if [ -f /usr/lib/shim/shimia32.efi.signed ]; then
        cp -av /usr/lib/shim/shimia32.efi.signed "$ISOROOT/EFI/BOOT/BOOTIA32.EFI"
      fi
    elif [ "$arch" = "arm64" ]; then
      cp -av /usr/lib/shim/shimaa64.efi.signed "$ISOROOT/EFI/BOOT/BOOT${ARCH_SHORT^^}.EFI"
      cp -av /usr/lib/shim/shimaa64.efi.signed "$ISOROOT/EFI/BOOT/shimaa64.efi"
      cp -av /usr/lib/grub/arm64-efi-signed/grubaa64.efi.signed "$ISOROOT/EFI/BOOT/grubaa64.efi"
    fi
    cp -avf $ISOROOT/boot/grub/grub.cfg $ISOROOT/EFI/BOOT/BOOT.conf
    cp -avf $ISOROOT/boot/grub/grub.cfg $ISOROOT/EFI/BOOT/grub.cfg
    if [ -f /usr/share/grub/unicode.pf2 ]
    then
      cp -avf /usr/share/grub/unicode.pf2 $ISOROOT/EFI/BOOT/fonts
    fi

    ARCH_GRUB="$(uname -m | sed 's/x86_64/i386-pc/g' | sed 's/aarch64/arm64-efi/g')"
    ARCH_OUT="$(uname -m | sed 's/x86_64/i386-pc-eltorito/g' | sed 's/aarch64/arm64-efi/g')"
    ARCH_MODULES="$(uname -m | sed 's/x86_64/biosdisk/g' | sed 's/aarch64/efi_gop/g')"

    grub-mkimage -O $ARCH_OUT -d /usr/lib/grub/$ARCH_GRUB -o $ISOROOT/boot/eltorito.img -p /boot/grub iso9660 $ARCH_MODULES
    ls /app
    ls /app/iso
    grub-mkrescue -o $ISOROOT/../efiboot.img

    # approach 1
    #EFI_BOOT_MOUNT=$(mktemp -d)
    #mount $ISOROOT/../efiboot.img $EFI_BOOT_MOUNT
    #cp -r $EFI_BOOT_MOUNT/boot/grub $ISOROOT/boot/
    #umount $EFI_BOOT_MOUNT
    #rm -rf $EFI_BOOT_MOUNT
    
    # approach 2
    #mkdir -p $ISOROOT/boot/grub
    #mcopy -s -i $ISOROOT/../efiboot.img ::/boot/grub/* $ISOROOT/boot/grub/

    # approach 3
    7z x $ISOROOT/../efiboot.img -o/tmp/efi_extract boot/grub
    cp -r /tmp/efi_extract/boot/grub $ISOROOT/boot/

    #EFI_BOOT_PART=$(mktemp -d)
    #fallocate $WORKDIR/efiboot.img -l 25M
    #mkfs.msdos -v -n EFI $WORKDIR/efiboot.img
    #mount $WORKDIR/efiboot.img $EFI_BOOT_PART
    #mkdir -p $EFI_BOOT_PART/EFI/BOOT
    #cp -dRvf $ISOROOT/EFI/BOOT/. $EFI_BOOT_PART/EFI/BOOT
    #umount $EFI_BOOT_PART


    fallocate $WORKDIR/efiboot.img -l 25M
    mkfs.msdos -v -n EFI $WORKDIR/efiboot.img
    mcopy -s -i $WORKDIR/efiboot.img $ISOROOT/EFI ::/ 

    ARCH_SPECIFIC=()
    if [ "$arch" == "x86_64" ] ; then
        ARCH_SPECIFIC=("--grub2-mbr" "/usr/lib/grub/i386-pc/boot_hybrid.img")
    fi

    chown -R root:root $ISOROOT || true
    chmod -R u+rw,go+r $ISOROOT
    find $ISOROOT -type d -exec chmod u+rwx,go+rx {} \;
    xorrisofs \
        -R \
        -V debian-atomic-boot \
        -partition_offset 16 \
        -appended_part_as_gpt \
        -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B \
        $ISOROOT/../efiboot.img \
        -iso_mbr_part_type EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
        -c boot.cat --boot-catalog-hide \
        -b boot/eltorito.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        -eltorito-alt-boot \
        -e \
        --interval:appended_partition_2:all:: \
        -no-emul-boot \
        -vvvvv \
        -iso-level 3 \
        -o /app/{{ iso_file }} \
        "${ARCH_SPECIFIC[@]}" \
        $ISOROOT

    INNERSCRIPT
    chmod +x build/build-iso-internal.sh

    sudo {{ container_runtime }} run --privileged --rm \
        -v ".:/app:z" \
        --cap-add SYSADMIN \
        --security-opt label=disable \
        debian:latest \
        /app/build/build-iso-internal.sh