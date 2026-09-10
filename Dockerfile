# syntax=docker/dockerfile:1

FROM registry.gitlab.com/qemu-project/qemu/qemu/debian:latest AS builder

ARG VERSION_ARG="0.0.0"

ARG QEMU_VERSION="11.1.0"
ARG QEMU_REF="84f07211cc5b4fc6a371559bf8a5de4fb068e648"

ARG DEBIAN_FRONTEND="noninteractive"

RUN <<EOF_BUILD_DEPS
  set -eu

  apt-get update
  apt-get install --no-install-recommends -y \
    dpkg-dev \
    libvulkan-dev \
    python3-mako \
    python3-yaml

  rm -rf /var/lib/apt/lists/*
EOF_BUILD_DEPS

WORKDIR /src

ADD --keep-git-dir=true https://github.com/qemus/qemu-render.git#v1.2.0 /src/qemu-render

# Helios scanout code uses virglrenderer's extended resource metadata API.
# Build against the exact virglrenderer revision selected by the latest
# qemu-render master so the two projects stay on the same API automatically.
RUN <<EOF_VIRGL
  set -eu

  qemu_render_commit="$(git -C qemu-render rev-parse HEAD)"
  virgl_ref="$(sed -n 's/^ARG VIRGL_REF="\([0-9a-f]\{40\}\)"$/\1/p' qemu-render/Dockerfile)"
  if [ -z "$virgl_ref" ]; then
    echo "FAIL: could not resolve VIRGL_REF from qemu-render Dockerfile."
    exit 1
  fi

  echo "Using qemu-render commit $qemu_render_commit"
  echo "Using qemu-render virglrenderer commit $virgl_ref"

  git init virglrenderer
  git -C virglrenderer remote add origin https://gitlab.freedesktop.org/virgl/virglrenderer.git
  git -C virglrenderer fetch --depth=1 origin "$virgl_ref"
  git -C virglrenderer checkout --detach FETCH_HEAD

  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"

  meson setup /build-virgl /src/virglrenderer \
    --buildtype=release \
    --prefix=/usr/local \
    --libdir="lib/${multiarch}" \
    -Dplatforms=egl \
    -Dvenus=true \
    -Drender-server-worker=thread \
    -Dunstable-apis=true \
    -Dtests=false \
    -Dvideo=false

  meson compile -C /build-virgl
  meson install -C /build-virgl
  ldconfig
EOF_VIRGL

ADD --keep-git-dir=true https://github.com/qemus/qemu-vmvga.git#master /src/qemu-vmvga

RUN <<EOF_SOURCE
  set -eu

  git init qemu
  git -C qemu remote add origin https://gitlab.com/qemu-project/qemu.git
  git -C qemu fetch --depth=1 origin "refs/tags/v${QEMU_VERSION}"
  git -C qemu checkout --detach FETCH_HEAD

  actual="$(git -C qemu rev-parse HEAD)"
  if [ "$actual" != "${QEMU_REF}" ]; then
    echo "FAIL: QEMU v${QEMU_VERSION} resolved to $actual instead of ${QEMU_REF}."
    exit 1
  fi

  # Overlay the latest enhanced VMware SVGA II implementation onto the same
  # QEMU 11.1 source tree that contains the Helios integration. qemu-vmvga is
  # source-only: its vmware_vga.c and VMware headers are compiled by QEMU.
  actual="$(git -C qemu-vmvga rev-parse HEAD)"
  echo "Using qemu-vmvga commit $actual"

  qemu_display="qemu/hw/display"
  vmvga_source="qemu-vmvga/hw/display"

  cp -a "$vmvga_source/." "$qemu_display/"

  # A git tag checkout does not contain Meson wrap sources. Prefetch the
  # subprojects required by the system UI and TCG test configuration so the
  # later --disable-download configure step can remain offline.
  meson subprojects download --sourcedir qemu \
    keycodemapdb \
    berkeley-softfloat-3 \
    berkeley-testfloat-3

EOF_SOURCE

# General QEMU compatibility patches maintained by qemu-windows.
COPY patches /tmp/qemu-windows-patches

# Helios-specific files and patches remain maintained in qemu-helios. Fetch them
# at build time instead of carrying duplicate copies in this repository.
ADD https://github.com/qemus/qemu-helios.git#master /tmp/qemu-helios

RUN <<'EOF_PATCHES'
  set -eu

  install -Dm644 /tmp/qemu-helios/files/vulkan-readback.c /src/qemu/ui/vulkan-readback.c
  install -Dm644 /tmp/qemu-helios/files/vulkan-readback.h /src/qemu/ui/vulkan-readback.h

  for patch in /tmp/qemu-helios/patches/*.patch; do
    echo "Applying Helios ${patch##*/}..."
    git -C /src/qemu apply --recount --check "$patch"
    git -C /src/qemu apply --recount "$patch"
  done

  for patch in /tmp/qemu-windows-patches/*.patch; do
    echo "Applying qemu-windows ${patch##*/}..."
    git -C /src/qemu apply --recount --check "$patch"
    git -C /src/qemu apply --recount "$patch"
  done

  # Allow VMware user-mode display drivers to reach the VMware backdoor ports
  # on x64 Windows without requiring the host-wide KVM vmware_backdoor option.
  # The active Windows x64 TSS normally has no I/O bitmap (limit 0x67) while
  # IoMapBase is 0x68. Install a deny-by-default bitmap immediately after the
  # TSS, permit only the four ports consumed by a 32-bit access at 0x5658, and
  # extend the cached task-register limit so the processor consults that map.
  python3 - <<'EOF_VMPORT_TSS'
from pathlib import Path

path = Path("/src/qemu/target/i386/kvm/kvm.c")
text = path.read_text()

helper_anchor = '''static void kvm_rate_limit_on_bus_lock(void)
{
'''
helper = '''#define KVM_VMPORT_TSS_ORIGINAL_LIMIT 0x0067
#define KVM_VMPORT_TSS_IOMAP_BASE     0x0068
#define KVM_VMPORT_TSS_IOMAP_LIMIT    0x0b34
#define KVM_VMPORT_TSS_IOMAP_BYTES    (KVM_VMPORT_TSS_IOMAP_LIMIT - KVM_VMPORT_TSS_IOMAP_BASE + 1)
#define KVM_VMPORT_TSS_VMWARE_BYTE    (0x5658 >> 3)

static void kvm_vmport_tss_enable_user_io(X86CPU *cpu)
{
    CPUState *cs = CPU(cpu);
    CPUX86State *env = &cpu->env;
    struct kvm_sregs sregs;
    uint8_t io_map_base[2];
    uint8_t io_map[KVM_VMPORT_TSS_IOMAP_BYTES];
    static uint32_t reject_seen[256];
    static uint64_t last_tr_base[256];
    static uint32_t last_tr_limit[256];
    static uint8_t last_tr_type[256];
    static uint8_t last_tr_present[256];
    static uint8_t last_lma[256];
    static uint8_t state_valid[256];
    static uint16_t last_iomap[256];
    static uint8_t iomap_valid[256];
    uint32_t *seen = NULL;
    unsigned int index = cs->cpu_index;
    uint8_t lma;
    uint16_t iomap;
    int ret;

    if (index < ARRAY_SIZE(reject_seen)) {
        seen = &reject_seen[index];
        if (!(*seen & (1U << 0))) {
            *seen |= 1U << 0;
            fprintf(stderr, "vmport-tss: vcpu=%d probe entered\\n",
                    cs->cpu_index);
        }
    }

    /* Fast path after this vCPU has already received the extended limit. */
    if (env->tr.limit == KVM_VMPORT_TSS_IOMAP_LIMIT) {
        return;
    }

    ret = kvm_vcpu_ioctl(cs, KVM_GET_SREGS, &sregs);
    if (ret < 0) {
        if (!seen || !(*seen & (1U << 1))) {
            if (seen) {
                *seen |= 1U << 1;
            }
            fprintf(stderr,
                    "vmport-tss: vcpu=%d reject=KVM_GET_SREGS ret=%d\\n",
                    cs->cpu_index, ret);
        }
        return;
    }

    lma = !!(sregs.efer & MSR_EFER_LMA);
    if (index < ARRAY_SIZE(state_valid) &&
        (!state_valid[index] || last_lma[index] != lma ||
         last_tr_present[index] != sregs.tr.present ||
         last_tr_type[index] != sregs.tr.type ||
         last_tr_base[index] != sregs.tr.base ||
         last_tr_limit[index] != sregs.tr.limit)) {
        state_valid[index] = 1;
        last_lma[index] = lma;
        last_tr_present[index] = sregs.tr.present;
        last_tr_type[index] = sregs.tr.type;
        last_tr_base[index] = sregs.tr.base;
        last_tr_limit[index] = sregs.tr.limit;
        fprintf(stderr,
                "vmport-tss: vcpu=%d state lma=%u present=%u type=%u "
                "base=0x%" PRIx64 " limit=0x%x env-base=0x%" PRIx64
                " env-limit=0x%x\\n",
                cs->cpu_index, lma, sregs.tr.present, sregs.tr.type,
                (uint64_t)sregs.tr.base, sregs.tr.limit,
                (uint64_t)env->tr.base, env->tr.limit);
    }

    /* Match the normal active 64-bit Windows TSS before changing anything. */
    if (!lma) {
        if (!seen || !(*seen & (1U << 2))) {
            if (seen) {
                *seen |= 1U << 2;
            }
            fprintf(stderr, "vmport-tss: vcpu=%d reject=NOT_LONG_MODE\\n",
                    cs->cpu_index);
        }
        return;
    }
    if (!sregs.tr.present) {
        if (!seen || !(*seen & (1U << 3))) {
            if (seen) {
                *seen |= 1U << 3;
            }
            fprintf(stderr, "vmport-tss: vcpu=%d reject=TR_NOT_PRESENT\\n",
                    cs->cpu_index);
        }
        return;
    }
    if (sregs.tr.type != 11) {
        if (!seen || !(*seen & (1U << 4))) {
            if (seen) {
                *seen |= 1U << 4;
            }
            fprintf(stderr,
                    "vmport-tss: vcpu=%d reject=TR_TYPE type=%u\\n",
                    cs->cpu_index, sregs.tr.type);
        }
        return;
    }
    if (!sregs.tr.base) {
        if (!seen || !(*seen & (1U << 5))) {
            if (seen) {
                *seen |= 1U << 5;
            }
            fprintf(stderr, "vmport-tss: vcpu=%d reject=TR_BASE_ZERO\\n",
                    cs->cpu_index);
        }
        return;
    }
    if (sregs.tr.limit != KVM_VMPORT_TSS_ORIGINAL_LIMIT) {
        if (!seen || !(*seen & (1U << 6))) {
            if (seen) {
                *seen |= 1U << 6;
            }
            fprintf(stderr,
                    "vmport-tss: vcpu=%d reject=TR_LIMIT limit=0x%x "
                    "expected=0x%x\\n",
                    cs->cpu_index, sregs.tr.limit,
                    KVM_VMPORT_TSS_ORIGINAL_LIMIT);
        }
        return;
    }

    /* Synchronize CR3 and the segment state used by cpu_memory_rw_debug(). */
    kvm_cpu_synchronize_state(cs);
    if (env->tr.base != sregs.tr.base) {
        if (!seen || !(*seen & (1U << 7))) {
            if (seen) {
                *seen |= 1U << 7;
            }
            fprintf(stderr,
                    "vmport-tss: vcpu=%d reject=SYNC_BASE kvm=0x%" PRIx64
                    " env=0x%" PRIx64 "\\n",
                    cs->cpu_index, (uint64_t)sregs.tr.base,
                    (uint64_t)env->tr.base);
        }
        return;
    }
    if (env->tr.limit != KVM_VMPORT_TSS_ORIGINAL_LIMIT) {
        if (!seen || !(*seen & (1U << 8))) {
            if (seen) {
                *seen |= 1U << 8;
            }
            fprintf(stderr,
                    "vmport-tss: vcpu=%d reject=SYNC_LIMIT kvm=0x%x "
                    "env=0x%x\\n",
                    cs->cpu_index, sregs.tr.limit, env->tr.limit);
        }
        return;
    }

    ret = cpu_memory_rw_debug(cs, env->tr.base + 0x66, io_map_base,
                              sizeof(io_map_base), false);
    if (ret != 0) {
        if (!seen || !(*seen & (1U << 9))) {
            if (seen) {
                *seen |= 1U << 9;
            }
            fprintf(stderr,
                    "vmport-tss: vcpu=%d reject=IOMAP_READ ret=%d "
                    "address=0x%" PRIx64 "\\n",
                    cs->cpu_index, ret, (uint64_t)env->tr.base + 0x66);
        }
        return;
    }

    iomap = io_map_base[0] | ((uint16_t)io_map_base[1] << 8);
    if (index < ARRAY_SIZE(iomap_valid) &&
        (!iomap_valid[index] || last_iomap[index] != iomap)) {
        iomap_valid[index] = 1;
        last_iomap[index] = iomap;
        fprintf(stderr,
                "vmport-tss: vcpu=%d iomap-base=0x%04x at 0x%" PRIx64
                "\\n",
                cs->cpu_index, iomap, (uint64_t)env->tr.base + 0x66);
    }
    if (iomap != KVM_VMPORT_TSS_IOMAP_BASE) {
        if (!seen || !(*seen & (1U << 10))) {
            if (seen) {
                *seen |= 1U << 10;
            }
            fprintf(stderr,
                    "vmport-tss: vcpu=%d reject=IOMAP_BASE value=0x%04x "
                    "expected=0x%04x\\n",
                    cs->cpu_index, iomap, KVM_VMPORT_TSS_IOMAP_BASE);
        }
        return;
    }

    memset(io_map, 0xff, sizeof(io_map));

    /*
     * A 32-bit IN/OUT at 0x5658 checks ports 0x5658 through 0x565b.
     * 0x5659, used by VMware's high-bandwidth transport, is included too.
     */
    io_map[KVM_VMPORT_TSS_VMWARE_BYTE] = 0xf0;

    ret = cpu_memory_rw_debug(cs,
                              env->tr.base + KVM_VMPORT_TSS_IOMAP_BASE,
                              io_map, sizeof(io_map), true);
    if (ret != 0) {
        if (!seen || !(*seen & (1U << 11))) {
            if (seen) {
                *seen |= 1U << 11;
            }
            fprintf(stderr,
                    "vmport-tss: vcpu=%d reject=IOMAP_WRITE ret=%d "
                    "address=0x%" PRIx64 " size=0x%zx\\n",
                    cs->cpu_index, ret,
                    (uint64_t)env->tr.base + KVM_VMPORT_TSS_IOMAP_BASE,
                    sizeof(io_map));
        }
        return;
    }

    env->tr.limit = KVM_VMPORT_TSS_IOMAP_LIMIT;

    fprintf(stderr,
            "vmport-tss: vcpu=%d enabled user I/O 0x5658-0x565b "
            "at TSS 0x%" PRIx64 "\\n",
            cs->cpu_index, (uint64_t)env->tr.base);
}

'''

post_run_anchor = '''MemTxAttrs kvm_arch_post_run(CPUState *cpu, struct kvm_run *run)
{
    X86CPU *x86_cpu = X86_CPU(cpu);
    CPUX86State *env = &x86_cpu->env;
'''
post_run_replacement = '''MemTxAttrs kvm_arch_post_run(CPUState *cpu, struct kvm_run *run)
{
    X86CPU *x86_cpu = X86_CPU(cpu);
    CPUX86State *env = &x86_cpu->env;

    bql_lock();
    kvm_vmport_tss_enable_user_io(x86_cpu);
    bql_unlock();
'''

if text.count(helper_anchor) != 1:
    raise SystemExit("FAIL: unexpected kvm_rate_limit_on_bus_lock anchor count")
if text.count(post_run_anchor) != 1:
    raise SystemExit("FAIL: unexpected kvm_arch_post_run anchor count")

text = text.replace(helper_anchor, helper + helper_anchor, 1)
text = text.replace(post_run_anchor, post_run_replacement, 1)
path.write_text(text)
EOF_VMPORT_TSS

  git -C /src/qemu diff --check
EOF_PATCHES

RUN <<'EOF_BUILD'
  set -eu

  mkdir /build /out
  cd /build

  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
  export PKG_CONFIG_PATH="/usr/local/lib/${multiarch}/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export LD_LIBRARY_PATH="/usr/local/lib/${multiarch}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export DEB_CFLAGS_MAINT_APPEND="-ffile-prefix-map=/src/qemu=."

  extra_cflags="$(dpkg-buildflags --get CFLAGS) $(dpkg-buildflags --get CPPFLAGS)"
  extra_ldflags="$(dpkg-buildflags --get LDFLAGS)"

  printf 'Debian CFLAGS/CPPFLAGS: %s\n' "$extra_cflags"
  printf 'Debian LDFLAGS: %s\n' "$extra_ldflags"

  /src/qemu/configure \
    --with-pkgversion="qemu-windows ${VERSION_ARG}" \
    --target-list=x86_64-softmmu \
    --prefix=/usr \
    --libdir="/usr/lib/${multiarch}" \
    --libexecdir=/usr/lib/qemu \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --mandir=/usr/share/man \
    --firmwarepath=/usr/share/qemu:/usr/share/seabios \
    --extra-cflags="$extra_cflags" \
    --extra-ldflags="$extra_ldflags" \
    --audio-drv-list=alsa,oss \
    --disable-af-xdp \
    --disable-blkio \
    --disable-brlapi \
    --disable-bzip2 \
    --disable-cocoa \
    --disable-containers \
    --disable-curl \
    --disable-docs \
    --disable-download \
    --disable-gtk \
    --disable-hvf \
    --disable-install-blobs \
    --disable-jack \
    --disable-libcbor \
    --disable-libiscsi \
    --disable-libnfs \
    --disable-libssh \
    --disable-linux-user \
    --disable-lzo \
    --disable-modules \
    --disable-pa \
    --disable-pipewire \
    --disable-rbd \
    --disable-rdma \
    --disable-relocatable \
    --disable-sdl \
    --disable-snappy \
    --disable-sndio \
    --disable-strip \
    --disable-tools \
    --disable-user \
    --disable-vde \
    --disable-vte \
    --disable-xen \
    --disable-xkbcommon \
    --enable-attr \
    --enable-bpf \
    --enable-cap-ng \
    --enable-capstone \
    --enable-curses \
    --enable-fdt \
    --enable-fuse \
    --enable-gnutls \
    --enable-kvm \
    --enable-libpmem \
    --enable-libusb \
    --enable-libudev \
    --enable-linux-aio \
    --enable-linux-io-uring \
    --enable-nettle \
    --enable-numa \
    --enable-opengl \
    --enable-pixman \
    --enable-png \
    --enable-seccomp \
    --enable-slirp \
    --enable-smartcard \
    --enable-spice \
    --enable-system \
    --enable-tcg \
    --enable-usb-redir \
    --enable-vhost-net \
    --enable-vhost-user \
    --enable-vhost-vdpa \
    --enable-virglrenderer \
    --enable-virtfs \
    --enable-vnc \
    --enable-vnc-jpeg \
    --enable-vnc-sasl \
    --enable-zstd

  # Print the resolved Meson configuration in the CI log. Every enabled
  # feature above is also a hard configure-time requirement, so dependencies
  # cannot disappear silently when the Debian snapshot changes.
  meson configure /build

  ninja qemu-system-x86_64

  install -Dm755 /build/qemu-system-x86_64 /out/qemu-system-x86_64
  strip --strip-unneeded /out/qemu-system-x86_64

  # This symbol is referenced only when the extended virglrenderer metadata API
  # was visible at compile time; without it native Helios scanout is incomplete.
  readelf -Ws /out/qemu-system-x86_64 \
    | grep -Fq 'virgl_renderer_resource_get_info_ext' || {
      echo "FAIL: virglrenderer extended resource metadata support was not compiled in."
      exit 1
    }

  for marker in \
    helios_scanout_bind \
    helios_scanout_read \
    helios_vulkan_capture \
    helios_vulkan_publish; do
    strings /out/qemu-system-x86_64 | grep -Fq "$marker" || {
      echo "FAIL: required Helios marker is missing from the binary: $marker"
      exit 1
    }
  done

  strings /out/qemu-system-x86_64 | grep -Fq 'vmport-tss: vcpu=' || {
    echo "FAIL: x64 vmport TSS compatibility code was not compiled in."
    exit 1
  }

EOF_BUILD

# Test the produced executable inside the actual qemux/qemu runtime image.
# LD_BIND_NOW catches missing or incompatible shared-library symbols before the
# artifact is published.
FROM qemux/qemu:latest AS verify

COPY --from=builder /out/qemu-system-x86_64 /tmp/qemu-system-x86_64

RUN <<'EOF_VERIFY'
  set -eu

  binary=/tmp/qemu-system-x86_64

  deps="$(ldd "$binary" 2>&1)"
  printf '%s\n' "$deps"
  if printf '%s\n' "$deps" | grep -q 'not found'; then
    echo "FAIL: one or more QEMU runtime dependencies could not be resolved."
    exit 1
  fi

  LD_BIND_NOW=1 "$binary" --version \
    | grep -F "QEMU emulator version 11.1.0"

  QEMU_MODULE_DIR=/nonexistent LD_BIND_NOW=1 \
    "$binary" -device virtio-vga-gl,help \
    >/tmp/virtio-vga-gl-help 2>&1
  grep -F "host3d_blob_limit" /tmp/virtio-vga-gl-help

  QEMU_MODULE_DIR=/nonexistent LD_BIND_NOW=1 \
    "$binary" -display help >/tmp/display-help 2>&1
  grep -F "egl-headless" /tmp/display-help

  QEMU_MODULE_DIR=/nonexistent LD_BIND_NOW=1 \
    "$binary" -device qxl-vga,help >/tmp/qxl-help 2>&1

  install -Dm755 "$binary" /out/qemu-system-x86_64

  size="$(stat -c %s /out/qemu-system-x86_64)"
  echo "Verified qemu-system-x86_64 (${size} bytes)"
EOF_VERIFY

FROM scratch AS artifact

ARG VERSION_ARG="0.0.0"

LABEL org.opencontainers.image.title="QEMU Windows" \
      org.opencontainers.image.description="QEMU build for running Windows guests with hardware-accelerated graphics." \
      org.opencontainers.image.version="${VERSION_ARG}"

COPY --from=verify /out/qemu-system-x86_64 /usr/bin/qemu-system-x86_64
