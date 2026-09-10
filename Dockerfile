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

  # Experimental VMware x64 UMD execution-breakpoint compatibility.
  # Uses stock KVM guest-debug ioctls. No TSS/IDT or guest-file modifications.
  # This replaces (does not supplement) the previous TSS workaround.
  mkdir -p /tmp/vmport-bp
  cat > /tmp/vmport-bp/vmport-bp-core.h <<'EOF_VMBP_CORE'
/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Experimental, read-only discovery for the supplied VMware 11.3.5 x64 UMDs.
 * No Windows structure offsets, guest writes, or preferred load addresses.
 * The caller supplies a RAM-only physical read operation and serialization.
 */
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
#define VMBP_MAX_SITES 4

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
/* Return false when no further sites can be accepted in this scan. */
typedef bool (*VmbpFound)(void *, unsigned, uint64_t, uint64_t);

typedef struct VmbpWalk {
    VmbpRead read;
    VmbpFound found;
    void *opaque;
    uint64_t cr3;
    uint64_t start;
    uint64_t next;
    unsigned tables;
    unsigned pages;
    unsigned max_tables;
    unsigned max_pages;
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

/* Four-level paging only. Check effective U/S at every level. */
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

    if (va >= VMBP_USER_END || size > VMBP_USER_END - va) {
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

/* A build fingerprint, not a cryptographic authenticity check. */
static bool vmbp_match_image(VmbpWalk *w, unsigned profile, uint64_t base)
{
    const VmbpProfile *p = &vmbp_profiles[profile];
    uint8_t dos[64], pe[96];
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

static bool vmbp_scan_page(VmbpWalk *w, uint64_t va, uint64_t pa)
{
    unsigned i;

    for (i = 0; i < VMBP_PROFILE_COUNT; i++) {
        const VmbpProfile *p = &vmbp_profiles[i];
        unsigned offset = (p->in_rva - VMBP_IN_OFFSET) & 4095;
        uint64_t ip = va + offset + VMBP_IN_OFFSET;
        uint8_t code[sizeof(vmbp_thunk)];

        if (w->read(w->opaque, pa + offset, code, sizeof(code)) &&
            memcmp(code, vmbp_thunk, sizeof(code)) == 0 &&
            vmbp_match_site(w, i, ip) &&
            !w->found(w->opaque, i, ip - p->in_rva, ip)) {
            return false;
        }
    }
    return true;
}

/* Bounded, resumable traversal of present, executable user mappings.
 * Page-table entries are snapshots. Every hit is independently revalidated.
 */
static bool vmbp_scan_level(VmbpWalk *w, uint64_t table, unsigned level,
                            uint64_t base)
{
    uint8_t entries[4096];
    unsigned i, count = level == 4 ? 256 : 512;
    unsigned shift = 12 + 9 * (level - 1);
    uint64_t span = UINT64_C(1) << shift;

    if (w->tables >= w->max_tables) {
        return false;
    }
    w->tables++;
    if (!w->read(w->opaque, table, entries, sizeof(entries))) {
        return true;
    }
    for (i = 0; i < count; i++) {
        uint64_t va = base + (uint64_t)i * span;
        uint64_t end = va + span;
        uint64_t entry = vmbp_le64(entries + i * 8);
        uint64_t phys;

        if (end <= w->start) {
            continue;
        }
        w->next = va > w->start ? va : w->start;
        /* NX is also rejected with NXE=0, where that bit is reserved. */
        if ((entry & 5) != 5 || (entry & VMBP_NX) ||
            (level == 4 && (entry & 0x80))) {
            w->next = end;
            continue;
        }
        phys = entry & VMBP_PHYS_MASK;
        if (level > 1 && !(entry & 0x80)) {
            if (!vmbp_scan_level(w, phys, level - 1, va)) {
                return false;
            }
        } else {
            uint64_t page = w->next & ~UINT64_C(4095);
            phys &= ~(span - 1);
            for (; page < end; page += VMBP_PAGE_SIZE) {
                w->next = page;
                if (w->pages >= w->max_pages) {
                    return false;
                }
                w->pages++;
                if (!vmbp_scan_page(w, page, phys + page - va)) {
                    return false;
                }
                w->next = page + VMBP_PAGE_SIZE;
            }
        }
        w->next = end;
    }
    return true;
}

static void vmbp_scan(VmbpWalk *w)
{
    w->next = w->start;
    w->tables = w->pages = 0;
    if (vmbp_scan_level(w, w->cr3 & VMBP_PHYS_MASK, 4, 0)) {
        w->next = 0;
    }
}
#endif
EOF_VMBP_CORE

  cat > /tmp/vmport-bp/vmport-bp.inc <<'EOF_VMBP_GLUE'
/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Experimental VMware UMD execution-breakpoint compatibility.
 * Included by target/i386/kvm/kvm.c. All shared discovery state is BQL-owned;
 * generation/enabled/initialized are atomically published to vCPU threads.
 * No TSS/IDT changes and no instruction-byte or guest-file patching.
 */
#include "system/cpus.h"
#include "system/reset.h"
#include "system/memory.h"
#include "vmport-bp-core.h"

typedef struct VmbpSite {
    uint64_t ip;
    unsigned profile;
} VmbpSite;

static VmbpSite vmbp_sites[VMBP_MAX_SITES];
static unsigned vmbp_site_count;
static unsigned vmbp_generation = 1;
static bool vmbp_initialized;
static bool vmbp_enabled;
static bool vmbp_debugger_warning;
static int64_t vmbp_next_summary;
static unsigned vmbp_summary_count;

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
    /* Never dispatch a diagnostic read to a device's MMIO callbacks. */
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

static void vmbp_reset(void *opaque)
{
    CPUState *cs;

    (void)opaque;

    vmbp_site_count = 0;
    memset(vmbp_sites, 0, sizeof(vmbp_sites));
    vmbp_summary_count = 0;
    vmbp_next_summary = 0;
    CPU_FOREACH(cs) {
        memset(&X86_CPU(cs)->vmport_bp, 0, sizeof(X86_CPU(cs)->vmport_bp));
    }
    /* pre_run updates hardware debug configuration before guest re-entry. */
    qatomic_set(&vmbp_generation, qatomic_read(&vmbp_generation) + 1);
}

static void vmbp_initialize(void)
{
    const char *setting = getenv("QEMU_VMPORT_BP");

    if (qatomic_read(&vmbp_initialized)) {
        return;
    }
    /* This experimental build defaults on, but only with a vmport device. */
    if ((setting && strcmp(setting, "1")) ||
        !object_resolve_path_type("vmport", NULL)) {
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
    fprintf(stderr, "vmport-bp: experimental x64 UMD breakpoints enabled; "
                    "TSS and guest code untouched\n");
}

static bool vmbp_found(void *opaque, unsigned profile,
                      uint64_t base, uint64_t ip)
{
    CPUState *cs;
    unsigned i;

    (void)opaque;
    for (i = 0; i < vmbp_site_count; i++) {
        if (vmbp_sites[i].ip == ip) {
            return true;
        }
    }
    if (vmbp_site_count == VMBP_MAX_SITES) {
        return false;
    }
    vmbp_sites[vmbp_site_count++] = (VmbpSite) { ip, profile };
    fprintf(stderr, "vmport-bp: found %s base=0x%" PRIx64
                    " in=0x%" PRIx64 " sites=%u/4\n",
            vmbp_profiles[profile].name, base, ip, vmbp_site_count);
    qatomic_set(&vmbp_generation, qatomic_read(&vmbp_generation) + 1);
    CPU_FOREACH(cs) {
        qemu_cpu_kick(cs);
    }
    if (vmbp_site_count == VMBP_MAX_SITES) {
        fprintf(stderr, "vmport-bp: four sites found; discovery stopped "
                        "(hardware breakpoint capacity)\n");
        return false;
    }
    return true;
}

/* Called at the end of post_run. Does not synchronize/dirty QEMU CPU state. */
static void vmbp_poll(CPUState *cs)
{
    X86CPU *cpu = X86_CPU(cs);
    struct kvm_sregs sregs;
    int64_t now;
    VmbpWalk walk;

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
    cpu->vmport_bp.next_probe_us = now + 100000; /* maximum 10 polls/s/vCPU */

    bql_lock();
    if (vmbp_site_count == VMBP_MAX_SITES ||
        kvm_state->guest_state_protected ||
        kvm_vcpu_ioctl(cs, KVM_GET_SREGS, &sregs) < 0 ||
        !(sregs.efer & MSR_EFER_LMA) ||
        !(sregs.cr0 & CR0_PG_MASK) || !(sregs.cr4 & CR4_PAE_MASK) ||
        (sregs.cr4 & CR4_LA57_MASK) ||
        (cs->kvm_run->flags & KVM_RUN_X86_SMM)) {
        bql_unlock();
        return;
    }
    if (cpu->vmport_bp.scan_cr3 != (sregs.cr3 & VMBP_PHYS_MASK)) {
        cpu->vmport_bp.scan_cr3 = sregs.cr3 & VMBP_PHYS_MASK;
        cpu->vmport_bp.scan_cursor = 0;
    }
    walk = (VmbpWalk) {
        .read = vmbp_ram_read,
        .found = vmbp_found,
        .opaque = cs,
        .cr3 = sregs.cr3,
        .start = cpu->vmport_bp.scan_cursor,
        .max_tables = 256,
        .max_pages = 4096,
        .nxe = !!(sregs.efer & MSR_EFER_NXE),
    };
    vmbp_scan(&walk);
    cpu->vmport_bp.scan_cursor = walk.next;
    if (vmbp_site_count) {
        cpu->vmport_bp.next_probe_us = now + 500000;
    }
    if (now >= vmbp_next_summary && vmbp_summary_count < 12) {
        vmbp_next_summary = now + 5000000;
        vmbp_summary_count++;
        fprintf(stderr, "vmport-bp: scan vcpu=%d cr3=0x%" PRIx64
                        " tables=%u executable-pages=%u sites=%u/4 "
                        "resume=0x%" PRIx64 "\n",
                cs->cpu_index, (uint64_t)sregs.cr3,
                walk.tables, walk.pages, vmbp_site_count, walk.next);
    }
    bql_unlock();
}

/* Called from kvm_arch_update_guest_debug(), under its existing BQL. */
static void vmbp_populate_debug(CPUState *cs, struct kvm_guest_debug *dbg,
                                unsigned debugger_slots)
{
    X86CPU *cpu = X86_CPU(cs);
    unsigned n;

    dbg->pad = 0;
    cpu->vmport_bp.slot_mask = 0;
    if (!qatomic_read(&vmbp_enabled)) {
        return;
    }
    /* Preserve external debugger ownership rather than stealing its slots. */
    if (debugger_slots || kvm_sw_breakpoints_active(cs) ||
        cpu_single_stepping(cs)) {
        if (!vmbp_debugger_warning) {
            vmbp_debugger_warning = true;
            fprintf(stderr, "vmport-bp: suspended while external guest "
                            "debugging is active\n");
        }
        return;
    }
    if (!vmbp_site_count) {
        return;
    }
    memset(&dbg->arch, 0, sizeof(dbg->arch));
    dbg->control |= KVM_GUESTDBG_ENABLE | KVM_GUESTDBG_USE_HW_BP;
    dbg->arch.debugreg[7] = 0x0600;
    for (n = 0; n < vmbp_site_count; n++) {
        dbg->arch.debugreg[n] = vmbp_sites[n].ip;
        /* Execute breakpoint, length 1, global enable. No I/O breakpoint. */
        dbg->arch.debugreg[7] |= UINT64_C(2) << (n * 2);
        cpu->vmport_bp.slot_mask |= 1U << n;
        cpu->vmport_bp.slot_ip[n] = vmbp_sites[n].ip;
        cpu->vmport_bp.slot_profile[n] = vmbp_sites[n].profile;
    }
}

/* Configure each vCPU on its own thread, before entering KVM_RUN. */
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
        /* Do not silently run with an unknown debug configuration. */
        exit(EXIT_FAILURE);
    }
    cpu->vmport_bp.generation = generation;
    fprintf(stderr, "vmport-bp: %s vcpu=%d slots=0x%x generation=%u\n",
            cpu->vmport_bp.slot_mask ? "armed" : "idle",
            cs->cpu_index, cpu->vmport_bp.slot_mask, generation);
    bql_unlock();
}

/* A true return means this host-owned debug event was handled. */
static bool vmbp_handle_debug(X86CPU *cpu, struct kvm_debug_exit_arch *info)
{
    CPUState *cs = CPU(cpu);
    CPUX86State *env = &cpu->env;
    unsigned fired = info->dr6 & 15;
    struct kvm_sregs sregs;
    VmbpWalk walk;
    uint8_t data[4];
    uint32_t command;
    unsigned n;

    if (!qatomic_read(&vmbp_enabled) || info->exception != EXCP01_DB ||
        (info->dr6 & (DR6_BS | (1U << 13) | (1U << 15))) || !fired ||
        (fired & ~cpu->vmport_bp.slot_mask)) {
        return false;
    }
    for (n = 0; n < VMBP_MAX_SITES; n++) {
        if ((fired & (1U << n)) &&
            cpu->vmport_bp.slot_ip[n] == info->pc &&
            ((info->dr7 >> (16 + n * 4)) & 15) == 0) {
            break;
        }
    }
    if (n == VMBP_MAX_SITES) {
        return false;
    }
    kvm_cpu_synchronize_state(cs);
    if (kvm_vcpu_ioctl(cs, KVM_GET_SREGS, &sregs) < 0) {
        error_report("vmport-bp: failed to read breakpoint CPU state");
        exit(EXIT_FAILURE);
    }
    walk = (VmbpWalk) {
        .read = vmbp_ram_read, .opaque = cs, .cr3 = sregs.cr3,
        .nxe = !!(sregs.efer & MSR_EFER_NXE),
    };
    if (!(sregs.efer & MSR_EFER_LMA) || !sregs.cs.l ||
        (sregs.cs.selector & 3) != 3 || (sregs.cr4 & CR4_LA57_MASK) ||
        env->eip != info->pc || (uint16_t)env->regs[R_EDX] != 0x5658 ||
        (uint32_t)env->regs[R_EAX] != 0x564d5868 ||
        !vmbp_match_site(&walk, cpu->vmport_bp.slot_profile[n], info->pc)) {
        /* A reused virtual address is not permission to alter its code.
         * RF lets this instruction execute once under normal guest rules.
         * It may then fault normally; no unrelated #GP is suppressed.
         */
        env->eflags |= RF_MASK;
        if (cpu->vmport_bp.rejects++ < 4) {
            fprintf(stderr, "vmport-bp: pass-through vcpu=%d ip=0x%" PRIx64
                            " (runtime identity/operation mismatch)\n",
                    cs->cpu_index, (uint64_t)info->pc);
        }
        return true;
    }
    command = env->regs[R_ECX];
    /* Reuse the SAME I/O address-space path as ordinary KVM port-I/O.
     * vmport callbacks operate on current_cpu's synchronized registers.
     * They may update EBX/ECX/EDX/ESI/EDI as well as returning EAX.
     */
    if (address_space_read(&address_space_io, 0x5658,
                           cpu_get_mem_attrs(env), data, sizeof(data)) !=
        MEMTX_OK) {
        error_report("vmport-bp: vmport dispatch failed");
        exit(EXIT_FAILURE);
    }
    env->regs[R_EAX] = vmbp_le32(data); /* IN EAX zero-extends in 64-bit mode */
    env->eip++;                       /* verified single-byte ED opcode */
    env->eflags &= ~RF_MASK;
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
EOF_VMBP_GLUE

  cat > /tmp/vmport-bp/apply_vmport_bp.py <<'EOF_VMBP_INSTALL'
#!/usr/bin/env python3
"""Install the experiment into the pinned QEMU tree; refuse ambiguous anchors.

Usage: python3 apply_vmport_bp.py /path/to/qemu
The two vmport-bp source files must be next to this script. This script neither
compiles QEMU nor changes the host, the guest disk, or any running VM.
"""
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
    /* Experimental host debugger state; intentionally not guest CPU state.
     * Only cold boot/reset is supported for this diagnostic prototype.
     */
    struct {
        int64_t next_probe_us;
        uint64_t scan_cr3;
        uint64_t scan_cursor;
        unsigned generation;
        unsigned slot_mask;
        uint64_t slot_ip[4];
        unsigned slot_profile[4];
        uint64_t hits;
        uint64_t rejects;
    } vmport_bp;
"""


def patch_sources(kvm: str, cpu: str) -> tuple[str, str]:
    if "kvm_vmport_tss_enable_user_io" in kvm or "KVM_VMPORT_TSS_" in kvm:
        raise ValueError("Refusing to layer breakpoints on top of the old TSS mutation")
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
                       "    struct kvm_msrs *kvm_msr_buf;\n" + CPU_FIELDS, "X86CPU state")
    for call in ("vmbp_pre_run(cpu);", "vmbp_poll(cpu);",
                 "vmbp_handle_debug(cpu, arch_info)",
                 "vmbp_populate_debug(cpu, dbg, nb_hw_breakpoint);"):
        if kvm.count(call) != 1:
            raise ValueError(f"Invalid installed call count: {call}")
    return kvm, cpu


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    here = Path(__file__).resolve().parent
    kvm_path = root / "target/i386/kvm/kvm.c"
    cpu_path = root / "target/i386/cpu.h"
    try:
        # Validate everything before writing any file.
        kvm, cpu = patch_sources(kvm_path.read_text(), cpu_path.read_text())
        files = {name: (here / name).read_text()
                 for name in ("vmport-bp-core.h", "vmport-bp.inc")}
        for name, content in files.items():
            (kvm_path.parent / name).write_text(content)
        kvm_path.write_text(kvm)
        cpu_path.write_text(cpu)
        print("Installed experimental vmport execution breakpoints; no TSS mutation")
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

  strings /out/qemu-system-x86_64 | grep -Fq 'vmport-bp: experimental x64 UMD breakpoints enabled;' || {
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
