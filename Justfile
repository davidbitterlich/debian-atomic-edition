image_name := env("BUILD_IMAGE_NAME", "debian-atomic-edition")
image_tag := env("BUILD_IMAGE_TAG", "latest")
base_dir := env("BUILD_BASE_DIR", ".")
filesystem := env("BUILD_FILESYSTEM", "ext4")
iso_dir := env("BUILD_ISO_DIR", base_dir + "/iso")
selinux := path_exists('/sys/fs/selinux')

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

