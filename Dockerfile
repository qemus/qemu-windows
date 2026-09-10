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

  # Experimental VMware x64 UMD loader-triggered breakpoint compatibility.
  # Uses only stock KVM guest-debug ioctls.  Bootstrap ntdll once by placing a
  # temporary execution breakpoint on MSR_LSTAR (the x64 SYSCALL entry), then
  # Keep a loader breakpoint on LdrLoadDll.  When a VMware UMD starts loading,
  # place a temporary write watchpoint directly on LdrLoadDll's DllHandle output
  # variable.  The write gives us the exact ASLR image base without scanning or
  # tracing unrelated NtMapViewOfSection calls.
  # No recurring executable-page scan and no host-kernel/guest modifications.
  mkdir -p /tmp/vmport-bp
  cat > /tmp/vmport-bp/vmport-bp-core.h <<'EOF_VMBP_CORE'
/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef QEMU_VMPORT_BP_CORE_H
#define QEMU_VMPORT_BP_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define VMBP_PAGE_SIZE UINT64_C(4096)
#define VMBP_PHYS_MASK UINT64_C(0x000ffffffffff000)
#define VMBP_USER_END (UINT64_C(1) << 47)
#define VMBP_NX (UINT64_C(1) << 63)
#define VMBP_IN_OFFSET 31
#define VMBP_PROFILE_COUNT 3
#define VMBP_TRACKED_SITES 16
#define VMBP_MAX_PENDING 8

/* Entire 62-byte assembly thunk, including its sole IN EAX,DX instruction. */
static const uint8_t vmbp_thunk[] = {
    0x48,0x53,0x56,0x57,0x48,0x8b,0xc1,0x50,
    0x48,0x8b,0x78,0x28,0x48,0x8b,0x70,0x20,
    0x48,0x8b,0x50,0x18,0x48,0x8b,0x48,0x10,
    0x48,0x8b,0x58,0x08,0x48,0x8b,0x00,0xed,
    0x48,0x87,0x04,0x24,0x48,0x89,0x78,0x28,
    0x48,0x89,0x70,0x20,0x48,0x89,0x50,0x18,
    0x48,0x89,0x48,0x10,0x48,0x89,0x58,0x08,
    0x8f,0x00,0x5f,0x5e,0x5b,0xc3
};

typedef struct VmbpProfile {
    const char *name;
    uint32_t in_rva;
    uint32_t timestamp;
    uint32_t image_size;
    uint32_t checksum;
} VmbpProfile;

static const VmbpProfile vmbp_profiles[VMBP_PROFILE_COUNT] = {
    { "vm3dum64.dll",        0x2be4f, 0x60fe0aa9, 0x76000, 0x7f410 },
    { "vm3dum64_10.dll",     0x2928f, 0x60fe0aaa, 0x6d000, 0x6be49 },
    { "vm3dum64_loader.dll", 0x174cf, 0x60fe0aac, 0x2e000, 0x2f479 },
};

typedef bool (*VmbpRead)(void *, uint64_t, void *, size_t);

typedef struct VmbpWalk {
    VmbpRead read;
    void *opaque;
    uint64_t cr3;
    bool nxe;
} VmbpWalk;

static uint16_t vmbp_le16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t vmbp_le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t vmbp_le64(const uint8_t *p)
{
    return vmbp_le32(p) | ((uint64_t)vmbp_le32(p + 4) << 32);
}

static bool vmbp_translate(VmbpWalk *w, uint64_t va,
                           uint64_t *pa, bool *executable)
{
    uint64_t table = w->cr3 & VMBP_PHYS_MASK;
    bool nx = false;
    int level;

    if (va >= VMBP_USER_END) {
        return false;
    }
    for (level = 4; level >= 1; level--) {
        unsigned shift = 12 + 9 * (level - 1);
        uint8_t bytes[8];
        uint64_t entry, mask;

        if (!w->read(w->opaque, table + ((va >> shift) & 511) * 8,
                     bytes, sizeof(bytes))) {
            return false;
        }
        entry = vmbp_le64(bytes);
        if ((entry & 5) != 5 || (!w->nxe && (entry & VMBP_NX))) {
            return false;
        }
        nx |= !!(entry & VMBP_NX);
        if (level == 4 && (entry & 0x80)) {
            return false;
        }
        if (level == 1 || (entry & 0x80)) {
            mask = (UINT64_C(1) << shift) - 1;
            *pa = (entry & VMBP_PHYS_MASK & ~mask) | (va & mask);
            *executable = !nx;
            return true;
        }
        table = entry & VMBP_PHYS_MASK;
    }
    return false;
}

static bool vmbp_read_va(VmbpWalk *w, uint64_t va, void *dst, size_t size)
{
    uint8_t *out = dst;

    if (!size || va >= VMBP_USER_END || size > VMBP_USER_END - va) {
        return false;
    }
    while (size) {
        uint64_t pa;
        bool executable;
        size_t take = (size_t)(VMBP_PAGE_SIZE - (va & 4095));

        if (take > size) {
            take = size;
        }
        if (!vmbp_translate(w, va, &pa, &executable) ||
            !w->read(w->opaque, pa, out, take)) {
            return false;
        }
        va += take;
        out += take;
        size -= take;
    }
    return true;
}

static bool vmbp_read_u64(VmbpWalk *w, uint64_t va, uint64_t *value)
{
    uint8_t b[8];

    if (!vmbp_read_va(w, va, b, sizeof(b))) {
        return false;
    }
    *value = vmbp_le64(b);
    return true;
}

static bool vmbp_match_image(VmbpWalk *w, unsigned profile, uint64_t base)
{
    const VmbpProfile *p = &vmbp_profiles[profile];
    uint8_t dos[64], pe[160];
    uint32_t pe_offset;

    if (!base || (base & 0xffff) || base >= VMBP_USER_END ||
        p->image_size > VMBP_USER_END - base ||
        !vmbp_read_va(w, base, dos, sizeof(dos)) ||
        vmbp_le16(dos) != 0x5a4d) {
        return false;
    }
    pe_offset = vmbp_le32(dos + 0x3c);
    if (pe_offset < sizeof(dos) || pe_offset > 4096 ||
        !vmbp_read_va(w, base + pe_offset, pe, sizeof(pe))) {
        return false;
    }
    return vmbp_le32(pe) == 0x00004550 &&
           vmbp_le16(pe + 4) == 0x8664 &&
           vmbp_le16(pe + 6) > 0 && vmbp_le16(pe + 6) <= 96 &&
           vmbp_le32(pe + 8) == p->timestamp &&
           vmbp_le16(pe + 20) >= 112 &&
           (vmbp_le16(pe + 22) & 0x2000) &&
           vmbp_le16(pe + 24) == 0x20b &&
           vmbp_le32(pe + 24 + 56) == p->image_size &&
           vmbp_le32(pe + 24 + 64) == p->checksum;
}

static bool vmbp_match_site(VmbpWalk *w, unsigned profile, uint64_t ip)
{
    const VmbpProfile *p = &vmbp_profiles[profile];
    uint8_t code[sizeof(vmbp_thunk)];
    uint64_t pa;
    bool executable;

    return ip >= p->in_rva &&
           vmbp_translate(w, ip, &pa, &executable) && executable &&
           vmbp_match_image(w, profile, ip - p->in_rva) &&
           vmbp_read_va(w, ip - VMBP_IN_OFFSET, code, sizeof(code)) &&
           memcmp(code, vmbp_thunk, sizeof(code)) == 0;
}

#endif
EOF_VMBP_CORE

  cat > /tmp/vmport-bp/vmport-bp.inc <<'EOF_VMBP_GLUE'
/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Experimental VMware x64 UMD loader-triggered breakpoint compatibility.
 * Included by target/i386/kvm/kvm.c.  The guest disk and host kernel remain
 * untouched.  MSR_LSTAR supplies a deterministic one-shot x64 user bootstrap;
 * ntdll is then resolved from the PEB and no recurring page scan is needed.
 */
#include "system/cpus.h"
#include "system/reset.h"
#include "system/memory.h"
#include "vmport-bp-core.h"

typedef enum VmbpSlotKind {
    VMBP_SLOT_NONE,
    VMBP_SLOT_BOOTSTRAP_LSTAR,
    VMBP_SLOT_LDR_LOAD_DLL,
    VMBP_SLOT_DLL_HANDLE_WRITE,
    VMBP_SLOT_VMPORT,
} VmbpSlotKind;

typedef struct VmbpSite {
    bool valid;
    uint64_t ip;
    uint64_t base;
    uint64_t stamp;
    unsigned profile;
} VmbpSite;

typedef struct VmbpPending {
    bool active;
    uint64_t cr3;
    uint64_t dll_handle_ptr;
    uint64_t stamp;
    int64_t expires_us;
    unsigned profile;
} VmbpPending;

static VmbpSite vmbp_sites[VMBP_TRACKED_SITES];
static VmbpPending vmbp_pending[VMBP_MAX_PENDING];
static uint64_t vmbp_lstar;
static uint64_t vmbp_ldr_load_dll;
static uint64_t vmbp_stamp;
static unsigned vmbp_generation = 1;
static bool vmbp_initialized;
static bool vmbp_enabled;
static bool vmbp_debugger_warning;
static unsigned vmbp_bootstrap_logs;
static unsigned vmbp_handle_miss_logs;

static bool vmbp_ram_read(void *opaque, uint64_t pa, void *dst, size_t size)
{
    MemoryRegionSection section;
    bool ok = false;

    (void)opaque;
    if (!size || size > UINT64_MAX - pa) {
        return false;
    }
    section = memory_region_find(get_system_memory(), pa, size);
    if (!section.mr) {
        return false;
    }
    if (section.offset_within_address_space == pa &&
        int128_ge(section.size, int128_make64(size)) &&
        memory_region_is_ram(section.mr) &&
        !memory_region_is_ram_device(section.mr)) {
        memcpy(dst, (uint8_t *)memory_region_get_ram_ptr(section.mr) +
                    section.offset_within_region, size);
        ok = true;
    }
    memory_region_unref(section.mr);
    return ok;
}

static int vmbp_ascii_tolower(int c)
{
    return (c >= 'A' && c <= 'Z') ? c + ('a' - 'A') : c;
}

static bool vmbp_read_unicode_string(VmbpWalk *w, uint64_t us,
                                     char *out, size_t out_size)
{
    uint8_t hdr[16];
    uint8_t raw[256];
    uint16_t len;
    uint64_t ptr;
    size_t i, chars;

    if (out_size < 2 || !vmbp_read_va(w, us, hdr, sizeof(hdr))) {
        return false;
    }
    len = vmbp_le16(hdr);
    ptr = vmbp_le64(hdr + 8);
    if (!len || (len & 1) || len > sizeof(raw) || !ptr ||
        !vmbp_read_va(w, ptr, raw, len)) {
        return false;
    }
    chars = len / 2;
    if (chars >= out_size) {
        chars = out_size - 1;
    }
    for (i = 0; i < chars; i++) {
        uint16_t ch = vmbp_le16(raw + i * 2);
        out[i] = ch <= 0x7f ? vmbp_ascii_tolower(ch) : '?';
    }
    out[chars] = 0;
    return true;
}

static const char *vmbp_basename(const char *name)
{
    const char *base = name;

    for (; *name; name++) {
        if (*name == '\\' || *name == '/') {
            base = name + 1;
        }
    }
    return base;
}

static int vmbp_profile_for_name(const char *name)
{
    const char *base = vmbp_basename(name);
    unsigned i;

    for (i = 0; i < VMBP_PROFILE_COUNT; i++) {
        if (!strcmp(base, vmbp_profiles[i].name)) {
            return i;
        }
    }
    return -1;
}

static bool vmbp_read_cstr(VmbpWalk *w, uint64_t va,
                           char *out, size_t out_size)
{
    size_t i;

    if (out_size < 2) {
        return false;
    }
    for (i = 0; i + 1 < out_size; i++) {
        uint8_t c;
        if (!vmbp_read_va(w, va + i, &c, 1)) {
            return false;
        }
        out[i] = c;
        if (!c) {
            return true;
        }
    }
    out[out_size - 1] = 0;
    return false;
}

static bool vmbp_resolve_export(VmbpWalk *w, uint64_t base,
                                const char *wanted, uint64_t *address)
{
    uint8_t dos[64], pe[160], exp[40], b4[4], b2[2];
    uint32_t pe_off, exp_rva, exp_size, names, funcs, ords;
    uint32_t count, func_count, i;

    if (!vmbp_read_va(w, base, dos, sizeof(dos)) ||
        vmbp_le16(dos) != 0x5a4d) {
        return false;
    }
    pe_off = vmbp_le32(dos + 0x3c);
    if (pe_off < 64 || pe_off > 4096 ||
        !vmbp_read_va(w, base + pe_off, pe, sizeof(pe)) ||
        vmbp_le32(pe) != 0x00004550 || vmbp_le16(pe + 4) != 0x8664 ||
        vmbp_le16(pe + 24) != 0x20b) {
        return false;
    }
    exp_rva = vmbp_le32(pe + 24 + 112);
    exp_size = vmbp_le32(pe + 24 + 116);
    if (!exp_rva || exp_size < sizeof(exp) ||
        !vmbp_read_va(w, base + exp_rva, exp, sizeof(exp))) {
        return false;
    }
    func_count = vmbp_le32(exp + 20);
    count = vmbp_le32(exp + 24);
    funcs = vmbp_le32(exp + 28);
    names = vmbp_le32(exp + 32);
    ords = vmbp_le32(exp + 36);
    if (!count || count > 16384 || !funcs || !names || !ords) {
        return false;
    }
    for (i = 0; i < count; i++) {
        char name[80];
        uint32_t name_rva, fn_rva;
        uint16_t ordinal;
        uint64_t pa;
        bool executable;

        if (!vmbp_read_va(w, base + names + (uint64_t)i * 4, b4, 4)) {
            return false;
        }
        name_rva = vmbp_le32(b4);
        if (!name_rva || !vmbp_read_cstr(w, base + name_rva,
                                         name, sizeof(name))) {
            continue;
        }
        if (strcmp(name, wanted)) {
            continue;
        }
        if (!vmbp_read_va(w, base + ords + (uint64_t)i * 2, b2, 2)) {
            return false;
        }
        ordinal = vmbp_le16(b2);
        if (ordinal >= func_count ||
            !vmbp_read_va(w, base + funcs + (uint64_t)ordinal * 4, b4, 4)) {
            return false;
        }
        fn_rva = vmbp_le32(b4);
        if (!fn_rva || (fn_rva >= exp_rva && fn_rva < exp_rva + exp_size) ||
            !vmbp_translate(w, base + fn_rva, &pa, &executable) ||
            !executable) {
            return false;
        }
        *address = base + fn_rva;
        return true;
    }
    return false;
}

static bool vmbp_find_ntdll(VmbpWalk *w, uint64_t gs_base, uint64_t *base)
{
    uint64_t peb, ldr, head, entry;
    unsigned i;

    if (!gs_base || !vmbp_read_u64(w, gs_base + 0x60, &peb) || !peb ||
        !vmbp_read_u64(w, peb + 0x18, &ldr) || !ldr) {
        return false;
    }
    head = ldr + 0x10; /* PEB_LDR_DATA.InLoadOrderModuleList */
    if (!vmbp_read_u64(w, head, &entry)) {
        return false;
    }
    for (i = 0; i < 64 && entry && entry != head; i++) {
        char name[96];
        uint64_t dll_base, next;

        if (vmbp_read_u64(w, entry + 0x30, &dll_base) && dll_base &&
            vmbp_read_unicode_string(w, entry + 0x58, name, sizeof(name)) &&
            !strcmp(vmbp_basename(name), "ntdll.dll")) {
            *base = dll_base;
            return true;
        }
        if (!vmbp_read_u64(w, entry, &next) || next == entry) {
            return false;
        }
        entry = next;
    }
    return false;
}

static void vmbp_publish_debug_change(void)
{
    CPUState *cs;

    qatomic_set(&vmbp_generation, qatomic_read(&vmbp_generation) + 1);
    CPU_FOREACH(cs) {
        qemu_cpu_kick(cs);
    }
}

static void vmbp_reset(void *opaque)
{
    CPUState *cs;

    (void)opaque;
    memset(vmbp_sites, 0, sizeof(vmbp_sites));
    memset(vmbp_pending, 0, sizeof(vmbp_pending));
    vmbp_lstar = 0;
    qatomic_set(&vmbp_ldr_load_dll, 0);
    vmbp_stamp = 0;
    vmbp_bootstrap_logs = 0;
    vmbp_handle_miss_logs = 0;
    CPU_FOREACH(cs) {
        memset(&X86_CPU(cs)->vmport_bp, 0, sizeof(X86_CPU(cs)->vmport_bp));
    }
    vmbp_publish_debug_change();
}

static void vmbp_initialize(void)
{
    const char *setting = getenv("QEMU_VMPORT_BP");

    if (qatomic_read(&vmbp_initialized)) {
        return;
    }
    if ((setting && strcmp(setting, "1")) ||
        !object_resolve_path_type("", "vmport", NULL)) {
        qatomic_set(&vmbp_initialized, true);
        return;
    }
    if (kvm_state->guest_state_protected ||
        kvm_check_extension(kvm_state, KVM_CAP_SET_GUEST_DEBUG) <= 0) {
        fprintf(stderr, "vmport-bp: disabled: guest debugging unavailable\n");
        qatomic_set(&vmbp_initialized, true);
        return;
    }
    qemu_register_reset(vmbp_reset, NULL);
    qatomic_set(&vmbp_enabled, true);
    qatomic_set(&vmbp_initialized, true);
    fprintf(stderr, "vmport-bp: LSTAR/handle-watch x64 UMD breakpoints enabled; "
                    "no recurring executable-page scan\n");
}

static int vmbp_find_pending(uint64_t cr3, uint64_t dll_handle_ptr)
{
    unsigned i;

    for (i = 0; i < VMBP_MAX_PENDING; i++) {
        if (vmbp_pending[i].active && vmbp_pending[i].cr3 == cr3 &&
            vmbp_pending[i].dll_handle_ptr == dll_handle_ptr) {
            return i;
        }
    }
    return -1;
}

static bool vmbp_expire_pending(void)
{
    unsigned i;
    int64_t now = g_get_monotonic_time();
    bool changed = false;

    for (i = 0; i < VMBP_MAX_PENDING; i++) {
        if (vmbp_pending[i].active && vmbp_pending[i].expires_us <= now) {
            fprintf(stderr, "vmport-bp: load timeout cr3=0x%" PRIx64
                            " target=%s handle-out=0x%" PRIx64 "\n",
                    vmbp_pending[i].cr3,
                    vmbp_profiles[vmbp_pending[i].profile].name,
                    vmbp_pending[i].dll_handle_ptr);
            vmbp_pending[i].active = false;
            changed = true;
        }
    }
    return changed;
}

static int vmbp_add_pending(uint64_t cr3, unsigned profile,
                            uint64_t dll_handle_ptr)
{
    int existing = vmbp_find_pending(cr3, dll_handle_ptr);
    unsigned i, victim = 0;
    uint64_t oldest = UINT64_MAX;

    if (existing >= 0) {
        vmbp_pending[existing].profile = profile;
        vmbp_pending[existing].stamp = ++vmbp_stamp;
        vmbp_pending[existing].expires_us = g_get_monotonic_time() + 2000000;
        return existing;
    }
    for (i = 0; i < VMBP_MAX_PENDING; i++) {
        if (!vmbp_pending[i].active) {
            victim = i;
            oldest = 0;
            break;
        }
        if (vmbp_pending[i].stamp < oldest) {
            oldest = vmbp_pending[i].stamp;
            victim = i;
        }
    }
    vmbp_pending[victim] = (VmbpPending) {
        .active = true,
        .cr3 = cr3,
        .dll_handle_ptr = dll_handle_ptr,
        .stamp = ++vmbp_stamp,
        .expires_us = g_get_monotonic_time() + 2000000,
        .profile = profile,
    };
    return victim;
}

static int vmbp_newest_pending_not_in(uint32_t used)
{
    int best = -1;
    uint64_t stamp = 0;
    unsigned i;

    for (i = 0; i < VMBP_MAX_PENDING; i++) {
        if (!(used & (1U << i)) && vmbp_pending[i].active &&
            vmbp_pending[i].stamp >= stamp) {
            best = i;
            stamp = vmbp_pending[i].stamp;
        }
    }
    return best;
}

static int vmbp_find_site_by_ip(uint64_t ip)
{
    unsigned i;

    for (i = 0; i < VMBP_TRACKED_SITES; i++) {
        if (vmbp_sites[i].valid && vmbp_sites[i].ip == ip) {
            return i;
        }
    }
    return -1;
}

static int vmbp_add_site(unsigned profile, uint64_t base)
{
    uint64_t ip = base + vmbp_profiles[profile].in_rva;
    int existing = vmbp_find_site_by_ip(ip);
    unsigned i, victim = 0;
    uint64_t oldest = UINT64_MAX;

    if (existing >= 0) {
        vmbp_sites[existing].stamp = ++vmbp_stamp;
        return existing;
    }
    for (i = 0; i < VMBP_TRACKED_SITES; i++) {
        if (!vmbp_sites[i].valid) {
            victim = i;
            oldest = 0;
            break;
        }
        if (vmbp_sites[i].stamp < oldest) {
            oldest = vmbp_sites[i].stamp;
            victim = i;
        }
    }
    vmbp_sites[victim] = (VmbpSite) {
        .valid = true,
        .ip = ip,
        .base = base,
        .stamp = ++vmbp_stamp,
        .profile = profile,
    };
    return victim;
}

/* Called at the end of post_run.  Bootstrap is a small PEB/export walk and
 * stops permanently as soon as ntdll's LdrLoadDll address is known.
 */
static void vmbp_poll(CPUState *cs)
{
    X86CPU *cpu = X86_CPU(cs);
    uint64_t lstar = 0;
    int64_t now;

    if (!qatomic_read(&vmbp_initialized)) {
        bql_lock();
        vmbp_initialize();
        bql_unlock();
    }
    if (!qatomic_read(&vmbp_enabled)) {
        return;
    }

    now = g_get_monotonic_time();
    if (now < cpu->vmport_bp.next_probe_us) {
        return;
    }
    cpu->vmport_bp.next_probe_us = now + 100000;

    if (qatomic_read(&vmbp_ldr_load_dll)) {
        bql_lock();
        if (vmbp_expire_pending()) {
            vmbp_publish_debug_change();
        }
        bql_unlock();
        return;
    }
    if (vmbp_lstar) {
        return;
    }

    /* No user-mode timing dependency: discover Windows' x64 syscall entry
     * from KVM, then let an execution breakpoint on LSTAR give us the first
     * user CR3 + pre-SWAPGS user GS base deterministically.
     */
    if (kvm_get_one_msr(cpu, MSR_LSTAR, &lstar) < 0 || !lstar) {
        if (vmbp_bootstrap_logs++ < 2) {
            fprintf(stderr, "vmport-bp: waiting for MSR_LSTAR vcpu=%d\n",
                    cs->cpu_index);
        }
        return;
    }

    bql_lock();
    if (!vmbp_lstar && !qatomic_read(&vmbp_ldr_load_dll)) {
        vmbp_lstar = lstar;
        fprintf(stderr, "vmport-bp: bootstrap armed on LSTAR=0x%" PRIx64 "\n",
                lstar);
        vmbp_publish_debug_change();
    }
    bql_unlock();
}

static int vmbp_newest_site_not_in(uint32_t used)
{
    unsigned i;
    int best = -1;
    uint64_t stamp = 0;

    for (i = 0; i < VMBP_TRACKED_SITES; i++) {
        if (!(used & (1U << i)) && vmbp_sites[i].valid &&
            vmbp_sites[i].stamp >= stamp) {
            best = i;
            stamp = vmbp_sites[i].stamp;
        }
    }
    return best;
}

/* Called from kvm_arch_update_guest_debug(), under its existing BQL. */
static void vmbp_populate_debug(CPUState *cs, struct kvm_guest_debug *dbg,
                                unsigned debugger_slots)
{
    X86CPU *cpu = X86_CPU(cs);
    unsigned slot = 0;
    uint32_t used_pending = 0;
    uint32_t used_sites = 0;

    dbg->pad = 0;
    cpu->vmport_bp.slot_mask = 0;
    memset(cpu->vmport_bp.slot_kind, 0, sizeof(cpu->vmport_bp.slot_kind));
    memset(cpu->vmport_bp.slot_index, 0xff, sizeof(cpu->vmport_bp.slot_index));
    memset(cpu->vmport_bp.slot_ip, 0, sizeof(cpu->vmport_bp.slot_ip));

    if (!qatomic_read(&vmbp_enabled)) {
        return;
    }
    if (debugger_slots || kvm_sw_breakpoints_active(cs) ||
        cpu_single_stepping(cs)) {
        if (!vmbp_debugger_warning) {
            vmbp_debugger_warning = true;
            fprintf(stderr, "vmport-bp: suspended while external guest "
                            "debugging is active\n");
        }
        return;
    }
    if (!qatomic_read(&vmbp_ldr_load_dll) && !vmbp_lstar) {
        return;
    }

    memset(&dbg->arch, 0, sizeof(dbg->arch));
    dbg->control |= KVM_GUESTDBG_ENABLE | KVM_GUESTDBG_USE_HW_BP;
    dbg->arch.debugreg[7] = 0x0600;

#define VMBP_ARM_EXEC(_kind, _ip, _index) do { \
        dbg->arch.debugreg[slot] = (_ip); \
        dbg->arch.debugreg[7] |= UINT64_C(2) << (slot * 2); \
        cpu->vmport_bp.slot_mask |= 1U << slot; \
        cpu->vmport_bp.slot_kind[slot] = (_kind); \
        cpu->vmport_bp.slot_index[slot] = (_index); \
        cpu->vmport_bp.slot_ip[slot] = (_ip); \
        slot++; \
    } while (0)

#define VMBP_ARM_WRITE8(_ip, _index) do { \
        dbg->arch.debugreg[slot] = (_ip); \
        dbg->arch.debugreg[7] |= (UINT64_C(2) << (slot * 2)) | \
            (UINT64_C(1) << (16 + slot * 4)) | \
            (UINT64_C(2) << (18 + slot * 4)); \
        cpu->vmport_bp.slot_mask |= 1U << slot; \
        cpu->vmport_bp.slot_kind[slot] = VMBP_SLOT_DLL_HANDLE_WRITE; \
        cpu->vmport_bp.slot_index[slot] = (_index); \
        cpu->vmport_bp.slot_ip[slot] = (_ip); \
        slot++; \
    } while (0)

    if (!qatomic_read(&vmbp_ldr_load_dll)) {
        VMBP_ARM_EXEC(VMBP_SLOT_BOOTSTRAP_LSTAR, vmbp_lstar, UINT32_MAX);
        return;
    }

    /* DR0 remains the cheap loader trigger.  The remaining three slots are
     * first used for target-specific DllHandle writes, then for the newest
     * resolved vmport instruction addresses.
     */
    VMBP_ARM_EXEC(VMBP_SLOT_LDR_LOAD_DLL, qatomic_read(&vmbp_ldr_load_dll),
                  UINT32_MAX);

    while (slot < 4) {
        int pending = vmbp_newest_pending_not_in(used_pending);
        if (pending < 0) {
            break;
        }
        used_pending |= 1U << pending;
        VMBP_ARM_WRITE8(vmbp_pending[pending].dll_handle_ptr, pending);
    }
    while (slot < 4) {
        int site = vmbp_newest_site_not_in(used_sites);
        if (site < 0) {
            break;
        }
        used_sites |= 1U << site;
        VMBP_ARM_EXEC(VMBP_SLOT_VMPORT, vmbp_sites[site].ip, site);
    }
#undef VMBP_ARM_WRITE8
#undef VMBP_ARM_EXEC
}

static void vmbp_pre_run(CPUState *cs)
{
    X86CPU *cpu = X86_CPU(cs);
    unsigned generation = qatomic_read(&vmbp_generation);
    int ret;

    if (!qatomic_read(&vmbp_enabled) ||
        cpu->vmport_bp.generation == generation) {
        return;
    }
    bql_lock();
    generation = qatomic_read(&vmbp_generation);
    ret = kvm_update_guest_debug(cs, 0);
    if (ret < 0) {
        error_report("vmport-bp: KVM_SET_GUEST_DEBUG failed on vCPU %d: %s",
                     cs->cpu_index, strerror(-ret));
        exit(EXIT_FAILURE);
    }
    cpu->vmport_bp.generation = generation;
    fprintf(stderr, "vmport-bp: %s vcpu=%d slots=0x%x generation=%u\n",
            cpu->vmport_bp.slot_mask ? "armed" : "idle",
            cs->cpu_index, cpu->vmport_bp.slot_mask, generation);
    bql_unlock();
}

static bool vmbp_handle_bootstrap_lstar(X86CPU *cpu,
                                         struct kvm_sregs *sregs)
{
    CPUState *cs = CPU(cpu);
    CPUX86State *env = &cpu->env;
    VmbpWalk walk;
    uint64_t ntdll = 0, ldr = 0;

    walk = (VmbpWalk) {
        .read = vmbp_ram_read,
        .opaque = cs,
        .cr3 = sregs->cr3,
        .nxe = !!(sregs->efer & MSR_EFER_NXE),
    };

    /* SYSCALL has already switched CS/RIP to ring 0, but the first kernel
     * instruction at LSTAR has not executed yet.  Windows' SWAPGS therefore
     * has not run, so GUEST_GS_BASE is still the caller's x64 TEB base.
     */
    if (!(sregs->efer & MSR_EFER_LMA) || !sregs->cs.l ||
        (sregs->cs.selector & 3) != 0 || !sregs->gs.base ||
        sregs->gs.base >= VMBP_USER_END ||
        !vmbp_find_ntdll(&walk, sregs->gs.base, &ntdll) ||
        !vmbp_resolve_export(&walk, ntdll, "LdrLoadDll", &ldr)) {
        if (vmbp_bootstrap_logs++ < 8) {
            fprintf(stderr, "vmport-bp: LSTAR bootstrap retry vcpu=%d "
                            "cr3=0x%" PRIx64 " cs=0x%x gs=0x%" PRIx64 "\n",
                    cs->cpu_index, (uint64_t)sregs->cr3,
                    sregs->cs.selector, (uint64_t)sregs->gs.base);
        }
        env->eflags |= RF_MASK;
        return true;
    }

    qatomic_set(&vmbp_ldr_load_dll, ldr);
    vmbp_lstar = 0;
    fprintf(stderr, "vmport-bp: bootstrap ntdll=0x%" PRIx64
                    " LdrLoadDll=0x%" PRIx64 "\n",
            ntdll, ldr);
    vmbp_publish_debug_change();
    env->eflags |= RF_MASK;
    return true;
}

static bool vmbp_handle_ldr_load(X86CPU *cpu, struct kvm_sregs *sregs,
                                 VmbpWalk *walk)
{
    CPUState *cs = CPU(cpu);
    CPUX86State *env = &cpu->env;
    char name[160];
    int profile;
    uint64_t cr3 = sregs->cr3 & VMBP_PHYS_MASK;

    if (!vmbp_read_unicode_string(walk, env->regs[R_R8],
                                  name, sizeof(name))) {
        env->eflags |= RF_MASK;
        return true;
    }
    profile = vmbp_profile_for_name(name);
    if (profile >= 0 && env->regs[R_R9] && !(env->regs[R_R9] & 7)) {
        int pending = vmbp_add_pending(cr3, profile, env->regs[R_R9]);
        fprintf(stderr, "vmport-bp: load %s vcpu=%d cr3=0x%" PRIx64
                        " handle-out=0x%" PRIx64 " pending=%d\n",
                vmbp_profiles[profile].name, cs->cpu_index, cr3,
                (uint64_t)env->regs[R_R9], pending);
        vmbp_publish_debug_change();
    }
    env->eflags |= RF_MASK;
    return true;
}

static bool vmbp_handle_handle_write(X86CPU *cpu, struct kvm_sregs *sregs,
                                     VmbpWalk *walk, unsigned pending_index)
{
    CPUX86State *env = &cpu->env;
    VmbpPending *pending;
    uint64_t cr3 = sregs->cr3 & VMBP_PHYS_MASK;
    uint64_t base = 0;
    int site;

    if (pending_index >= VMBP_MAX_PENDING ||
        !vmbp_pending[pending_index].active) {
        env->eflags |= RF_MASK;
        return true;
    }
    pending = &vmbp_pending[pending_index];

    /* DR watchpoints are linear-address based and can theoretically collide
     * with the same user VA in another process.  Only consume the write in
     * the address space that issued the matching LdrLoadDll call.
     */
    if (pending->cr3 != cr3) {
        env->eflags |= RF_MASK;
        return true;
    }

    if (vmbp_read_u64(walk, pending->dll_handle_ptr, &base) && base &&
        vmbp_match_image(walk, pending->profile, base) &&
        vmbp_match_site(walk, pending->profile,
                        base + vmbp_profiles[pending->profile].in_rva)) {
        site = vmbp_add_site(pending->profile, base);
        fprintf(stderr, "vmport-bp: handle-write mapped %s base=0x%" PRIx64
                        " in=0x%" PRIx64 " site=%d cr3=0x%" PRIx64 "\n",
                vmbp_profiles[pending->profile].name, base,
                base + vmbp_profiles[pending->profile].in_rva, site, cr3);
        pending->active = false;
        vmbp_publish_debug_change();
    } else {
        pending->expires_us = g_get_monotonic_time() + 2000000;
        if (vmbp_handle_miss_logs++ < 12) {
            fprintf(stderr, "vmport-bp: handle-write target=%s cr3=0x%" PRIx64
                            " handle-out=0x%" PRIx64 " value=0x%" PRIx64
                            " (waiting for final module base)\n",
                    vmbp_profiles[pending->profile].name, cr3,
                    pending->dll_handle_ptr, base);
        }
    }

    env->eflags |= RF_MASK;
    return true;
}

static bool vmbp_handle_vmport(X86CPU *cpu, struct kvm_sregs *sregs,
                               VmbpWalk *walk, unsigned site_index,
                               struct kvm_debug_exit_arch *info)
{
    CPUState *cs = CPU(cpu);
    CPUX86State *env = &cpu->env;
    VmbpSite *site;
    uint8_t data[4];
    uint32_t command;

    if (site_index >= VMBP_TRACKED_SITES ||
        !vmbp_sites[site_index].valid) {
        return false;
    }
    site = &vmbp_sites[site_index];
    if (!(sregs->efer & MSR_EFER_LMA) || !sregs->cs.l ||
        (sregs->cs.selector & 3) != 3 ||
        env->eip != info->pc || (uint16_t)env->regs[R_EDX] != 0x5658 ||
        (uint32_t)env->regs[R_EAX] != 0x564d5868 ||
        !vmbp_match_site(walk, site->profile, info->pc)) {
        env->eflags |= RF_MASK;
        if (cpu->vmport_bp.rejects++ < 4) {
            fprintf(stderr, "vmport-bp: pass-through vcpu=%d ip=0x%" PRIx64
                            " (runtime identity/operation mismatch)\n",
                    cs->cpu_index, (uint64_t)info->pc);
        }
        return true;
    }
    command = env->regs[R_ECX];
    if (address_space_read(&address_space_io, 0x5658,
                           cpu_get_mem_attrs(env), data, sizeof(data)) !=
        MEMTX_OK) {
        error_report("vmport-bp: vmport dispatch failed");
        exit(EXIT_FAILURE);
    }
    env->regs[R_EAX] = vmbp_le32(data);
    env->eip++;
    env->eflags &= ~RF_MASK;
    site->stamp = ++vmbp_stamp;
    cpu->vmport_bp.hits++;
    if (cpu->vmport_bp.hits <= 8 ||
        (cpu->vmport_bp.hits & (cpu->vmport_bp.hits - 1)) == 0) {
        fprintf(stderr, "vmport-bp: emulated vcpu=%d ip=0x%" PRIx64
                        " cmd=0x%08x eax=0x%08x hits=%" PRIu64 "\n",
                cs->cpu_index, (uint64_t)info->pc, command,
                (uint32_t)env->regs[R_EAX], cpu->vmport_bp.hits);
    }
    return true;
}

/* A true return means this host-owned debug event was handled. */
static bool vmbp_handle_debug(X86CPU *cpu, struct kvm_debug_exit_arch *info)
{
    CPUState *cs = CPU(cpu);
    CPUX86State *env = &cpu->env;
    unsigned fired = info->dr6 & 15;
    struct kvm_sregs sregs;
    VmbpWalk walk;
    unsigned n;

    if (!qatomic_read(&vmbp_enabled) || info->exception != EXCP01_DB ||
        (info->dr6 & (DR6_BS | DR6_BD | DR6_BT)) || !fired ||
        (fired & ~cpu->vmport_bp.slot_mask)) {
        return false;
    }
    for (n = 0; n < 4; n++) {
        unsigned rwlen;

        if (!(fired & (1U << n)) ||
            cpu->vmport_bp.slot_kind[n] == VMBP_SLOT_NONE) {
            continue;
        }
        rwlen = (info->dr7 >> (16 + n * 4)) & 15;
        if (cpu->vmport_bp.slot_kind[n] == VMBP_SLOT_DLL_HANDLE_WRITE) {
            if (rwlen == 0x9) { /* write, 8 bytes */
                break;
            }
        } else if (rwlen == 0 && cpu->vmport_bp.slot_ip[n] == info->pc) {
            break;
        }
    }
    if (n == 4) {
        return false;
    }

    kvm_cpu_synchronize_state(cs);
    if (kvm_vcpu_ioctl(cs, KVM_GET_SREGS, &sregs) < 0) {
        error_report("vmport-bp: failed to read breakpoint CPU state");
        exit(EXIT_FAILURE);
    }

    if (cpu->vmport_bp.slot_kind[n] == VMBP_SLOT_BOOTSTRAP_LSTAR) {
        return vmbp_handle_bootstrap_lstar(cpu, &sregs);
    }

    walk = (VmbpWalk) {
        .read = vmbp_ram_read,
        .opaque = cs,
        .cr3 = sregs.cr3,
        .nxe = !!(sregs.efer & MSR_EFER_NXE),
    };
    if (!(sregs.efer & MSR_EFER_LMA) || !sregs.cs.l ||
        (sregs.cs.selector & 3) != 3 || (sregs.cr4 & CR4_LA57_MASK) ||
        env->eip != info->pc) {
        env->eflags |= RF_MASK;
        return true;
    }

    switch (cpu->vmport_bp.slot_kind[n]) {
    case VMBP_SLOT_LDR_LOAD_DLL:
        return vmbp_handle_ldr_load(cpu, &sregs, &walk);
    case VMBP_SLOT_DLL_HANDLE_WRITE:
        return vmbp_handle_handle_write(cpu, &sregs, &walk,
                                        cpu->vmport_bp.slot_index[n]);
    case VMBP_SLOT_VMPORT:
        return vmbp_handle_vmport(cpu, &sregs, &walk,
                                  cpu->vmport_bp.slot_index[n], info);
    default:
        return false;
    }
}
EOF_VMBP_GLUE

  cat > /tmp/vmport-bp/apply_vmport_bp.py <<'EOF_VMBP_INSTALL'
#!/usr/bin/env python3
"""Install loader-triggered VMware vmport breakpoints into pinned QEMU."""
from pathlib import Path
import sys


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise ValueError(f"{label}: expected one anchor, found {count}")
    return text.replace(old, new, 1)


def function_range(text: str, signature: str) -> tuple[int, int]:
    if text.count(signature) != 1:
        raise ValueError(f"Ambiguous/missing function: {signature}")
    start = text.index(signature)
    end = text.index("\n}\n", start) + len("\n}\n")
    return start, end


def edit_function(text: str, signature: str, old: str, new: str) -> str:
    start, end = function_range(text, signature)
    return text[:start] + replace_once(text[start:end], old, new, signature) + text[end:]


CPU_FIELDS = """
    /* Experimental host debugger state; intentionally not guest CPU state. */
    struct {
        int64_t next_probe_us;
        unsigned generation;
        unsigned slot_mask;
        uint8_t slot_kind[4];
        uint32_t slot_index[4];
        uint64_t slot_ip[4];
        uint64_t hits;
        uint64_t rejects;
    } vmport_bp;
"""


def patch_sources(kvm: str, cpu: str) -> tuple[str, str]:
    if "kvm_vmport_tss_enable_user_io" in kvm or "KVM_VMPORT_TSS_" in kvm:
        raise ValueError("Refusing to layer breakpoints on top of old TSS mutation")
    if '"vmport-bp.inc"' in kvm or "} vmport_bp;" in cpu:
        raise ValueError("Breakpoint experiment is already installed")
    pre = "void kvm_arch_pre_run(CPUState *cpu, struct kvm_run *run)\n"
    post = "MemTxAttrs kvm_arch_post_run(CPUState *cpu, struct kvm_run *run)\n"
    debug = "static int kvm_handle_debug(X86CPU *cpu,\n"
    update = "void kvm_arch_update_guest_debug(CPUState *cpu, struct kvm_guest_debug *dbg)\n"
    kvm = replace_once(kvm, pre, '#include "vmport-bp.inc"\n\n' + pre, "include")
    kvm = edit_function(kvm, pre, "    int ret;\n", "    int ret;\n\n    vmbp_pre_run(cpu);\n")
    kvm = edit_function(kvm, post, "    return cpu_get_mem_attrs(env);\n",
                        "    vmbp_poll(cpu);\n    return cpu_get_mem_attrs(env);\n")
    kvm = edit_function(kvm, debug, "    int n;\n", "    int n;\n\n"
                        "    if (vmbp_handle_debug(cpu, arch_info)) {\n"
                        "        return 0;\n    }\n")
    kvm = edit_function(kvm, update, "\n}\n", "\n"
                        "    vmbp_populate_debug(cpu, dbg, nb_hw_breakpoint);\n}\n")
    cpu = replace_once(cpu, "    struct kvm_msrs *kvm_msr_buf;\n",
                       "    struct kvm_msrs *kvm_msr_buf;\n" + CPU_FIELDS,
                       "X86CPU state")
    for call in ("vmbp_pre_run(cpu);", "vmbp_poll(cpu);",
                 "vmbp_handle_debug(cpu, arch_info)",
                 "vmbp_populate_debug(cpu, dbg, nb_hw_breakpoint);"):
        if kvm.count(call) != 1:
            raise ValueError(f"Invalid installed call count: {call}")
    return kvm, cpu


def main() -> int:
    if len(sys.argv) != 2:
        return 2
    root = Path(sys.argv[1])
    here = Path(__file__).resolve().parent
    kvm_path = root / "target/i386/kvm/kvm.c"
    cpu_path = root / "target/i386/cpu.h"
    try:
        kvm, cpu = patch_sources(kvm_path.read_text(), cpu_path.read_text())
        for name in ("vmport-bp-core.h", "vmport-bp.inc"):
            (kvm_path.parent / name).write_text((here / name).read_text())
        kvm_path.write_text(kvm)
        cpu_path.write_text(cpu)
        print("Installed LSTAR/handle-watch loader-triggered vmport breakpoints; no recurring scan")
        return 0
    except (OSError, ValueError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
EOF_VMBP_INSTALL

  python3 /tmp/vmport-bp/apply_vmport_bp.py /src/qemu

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

  strings /out/qemu-system-x86_64 | grep -Fq 'vmport-bp: LSTAR/handle-watch x64 UMD breakpoints enabled;' || {
    echo "FAIL: experimental vmport breakpoint code was not compiled in."
    exit 1
  }

  strings /out/qemu-system-x86_64 | grep -Fq 'vmport-bp: emulated vcpu=' || {
    echo "FAIL: vmport breakpoint handler was not compiled in."
    exit 1
  }
  if strings /out/qemu-system-x86_64 | grep -Fq 'vmport-tss:'; then
    echo "FAIL: obsolete vmport TSS mutation is still in the executable."
    exit 1
  fi

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
