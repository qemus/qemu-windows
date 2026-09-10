<h1 align="center">QEMU Windows<br />
<div align="center">
  
[![Build]][build_url]
[![Version]][release_url]
[![Size]][release_url]

</div></h1>

Custom Linux build of QEMU for running Windows guests, focused on hardware-accelerated graphics and system compatibility.

## What is QEMU Windows? 🪟

QEMU already provides excellent general-purpose virtualization, but accelerated graphics for Windows guests still requires a number of pieces that are either experimental, outside upstream QEMU, or aimed at different generations of Windows.

QEMU Windows combines those pieces into a single reproducible QEMU build.

The project is intended to provide one QEMU binary that works well across a wide range of Windows guests, from legacy releases using VMware SVGA II to newer Windows versions using accelerated `virtio-gpu` graphics.

## Graphics acceleration 🚀

### VMware SVGA II

QEMU Windows includes the enhanced [qemu-vmvga](https://github.com/qemus/qemu-vmvga) implementation.

The goal of `vmvga` is to extend QEMU's VMware SVGA II device with improved compatibility and hardware-accelerated 3D support for Windows guests. This is especially useful for older Windows versions for which modern paravirtualized graphics drivers are not an option.

### virtio-gpu and Vulkan

For newer Windows guests, QEMU Windows also includes the host-side support needed by accelerated `virtio-gpu` graphics stacks using Vulkan and Venus.

The build uses a Vulkan-enabled virglrenderer and contains additional scanout, DMA-BUF, host-memory and display-path compatibility fixes needed by Windows graphics workloads.

This allows rendering work to be performed by the host GPU without assigning the physical GPU directly to the virtual machine.

## Why a custom QEMU build? 🧩

The graphics paths used by Windows guests can exercise combinations that stock QEMU does not currently handle completely, particularly around native Vulkan images, DMA-BUF scanout, host-visible graphics memory and legacy VMware SVGA 3D commands.

QEMU Windows provides a practical integration point for those changes while individual components continue to evolve independently.

The build currently combines:

- upstream QEMU;
- Hyper-V compatibility patches
- core pinning on heterogeneous CPUs
- the enhanced SVGA implementation;
- a Vulkan/Venus-enabled virglrenderer build;
- additional Windows graphics compatibility fixes;

## Builds 📦

The repository builds a Linux `qemu-system-x86_64` binary through GitHub Actions and publishes it with each release.

The build is intentionally reproducible around upstream QEMU v11.1.0 while external graphics components are integrated during the Docker build.

Prebuilt binaries are available from the [releases][release_url] page.

## License 📄

QEMU Windows follows the licensing of QEMU and the individual components incorporated into the build. See [license.md](license.md) for the repository license information.

[Build]: https://github.com/qemus/qemu-windows/actions/workflows/build.yml/badge.svg
[Version]: https://img.shields.io/github/v/release/qemus/qemu-windows?label=version
[Size]: https://img.shields.io/badge/size-29.2_MB-steelblue?style=flat&color=066da5
[build_url]: https://github.com/qemus/qemu-windows/actions/workflows/build.yml
[release_url]: https://github.com/qemus/qemu-windows/releases
