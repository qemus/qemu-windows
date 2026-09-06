<h1 align="center">QEMU Windows<br />
<div align="center">
  
[![Build]][build_url]
[![Version]][release_url]
[![Size]][release_url]

</div></h1>

A custom **Linux build of QEMU for running Windows guests**, focused on hardware-accelerated graphics and Windows compatibility.

> **QEMU Windows is not a Windows-host build of QEMU.** The produced `qemu-system-x86_64` binary runs on Linux and is intended to host Windows virtual machines.

## What is QEMU Windows? 🪟

QEMU already provides excellent general-purpose virtualization, but accelerated graphics for Windows guests still requires a number of pieces that are either experimental, outside upstream QEMU, or aimed at different generations of Windows.

QEMU Windows combines those pieces into a single reproducible QEMU build.

The project is intended to provide one QEMU binary that works well across a wide range of Windows guests, from legacy releases using VMware SVGA II to newer Windows versions using accelerated `virtio-gpu` graphics.

## Graphics acceleration 🚀

### VMware SVGA II

QEMU Windows includes the enhanced [qemu-vmvga](https://github.com/qemus/qemu-vmvga) implementation.

The goal of qemu-vmvga is to extend QEMU's VMware SVGA II device with improved compatibility and hardware-accelerated 3D support for Windows guests. This is especially useful for older Windows versions for which modern paravirtualized graphics drivers are not an option.

The qemu-vmvga source is overlaid onto the QEMU source tree during the build, so the released binary always contains the integrated VMware SVGA implementation.

### virtio-gpu and Vulkan

For newer Windows guests, QEMU Windows also includes the host-side support needed by accelerated `virtio-gpu` graphics stacks using Vulkan and Venus.

The build uses a Vulkan-enabled virglrenderer and contains additional scanout, DMA-BUF, host-memory and display-path compatibility fixes needed by Windows graphics workloads.

This allows rendering work to be performed by the host GPU without assigning the physical GPU directly to the virtual machine.

## Why a custom QEMU build? 🧩

The graphics paths used by Windows guests can exercise combinations that stock QEMU does not currently handle completely, particularly around native Vulkan images, DMA-BUF scanout, host-visible graphics memory and legacy VMware SVGA 3D commands.

QEMU Windows provides a practical integration point for those changes while individual components continue to evolve independently.

The build currently combines:

- upstream QEMU;
- the enhanced qemu-vmvga implementation;
- a Vulkan/Venus-enabled virglrenderer build;
- additional Windows graphics compatibility fixes;
- KVM and TCG support;
- EGL headless and VNC display support.

## GPU passthrough is different 🔀

QEMU Windows does not require PCI GPU passthrough for its paravirtualized graphics paths.

With passthrough, a physical GPU is assigned directly to the Windows guest and Windows uses the vendor's native GPU driver. That can provide the highest level of hardware-specific compatibility, but the device is generally dedicated to the VM while it is assigned.

With paravirtualized graphics, Linux keeps ownership of the physical GPU. The Windows guest communicates with a virtual graphics device and rendering work is forwarded to the host graphics stack.

These approaches solve different problems, and QEMU Windows does not attempt to replace PCI passthrough when direct access to native GPU hardware or vendor-specific Windows features is required.

## Builds 📦

The repository builds a Linux `qemu-system-x86_64` binary through GitHub Actions and publishes it with each release.

The build is intentionally reproducible around a selected upstream QEMU version while external graphics components are integrated during the Docker build.

Prebuilt binaries are available from the [releases][release_url] page.

## Project scope 🔧

QEMU Windows is a downstream integration project. Some changes are suitable for eventual upstreaming, while others exist to keep Windows graphics configurations working reliably today.

Development of the VMware SVGA implementation lives separately in [qemu-vmvga](https://github.com/qemus/qemu-vmvga), keeping that codebase focused on changes that can eventually be submitted upstream.

## License 📄

QEMU Windows follows the licensing of QEMU and the individual components incorporated into the build. See [license.md](license.md) for the repository license information.

[Build]: https://github.com/qemus/qemu-windows/actions/workflows/build.yml/badge.svg
[Version]: https://img.shields.io/github/v/release/qemus/qemu-windows?label=version
[Size]: https://img.shields.io/github/repo-size/qemus/qemu-windows?label=size
[build_url]: https://github.com/qemus/qemu-windows/actions/workflows/build.yml
[release_url]: https://github.com/qemus/qemu-windows/releases
