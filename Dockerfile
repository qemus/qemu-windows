# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# Production builder for the anonymix/qemus VirtIO-GPU WDDM stack.
#
# Floating source inputs are intentionally limited to the two named BuildKit
# contexts supplied by build.yml:
#   - d3d11 -> qemus/virtio-d3d11 master, resolved to one exact SHA per run
#   - kmd   -> qemus/virtio-drivers-windows master, resolved to one exact SHA per run
#
# All other project/toolchain inputs are pinned below or supplied as pinned
# build arguments by build.yml.

ARG BUILDER_IMAGE=buildpack-deps:sid@sha256:dfc7595de3e15149f7eefe40b41477d6dc90fd46bf901890fd97f9a32d2b2fa0
ARG DEBIAN_SNAPSHOT=20260831T235959Z
ARG MINGW_GCC_PKG_VERSION=16.2.0-1+29
ARG MINGW_HEADERS_PKG_VERSION=14.0.0-1

FROM ${BUILDER_IMAGE} AS toolchain

ARG DEBIAN_FRONTEND=noninteractive
ARG DEBIAN_SNAPSHOT
ARG MINGW_GCC_PKG_VERSION
ARG MINGW_HEADERS_PKG_VERSION
ARG RUST_TOOLCHAIN=nightly-2026-08-31
ARG CBINDGEN_VERSION=0.29.4

ENV RUSTUP_HOME=/opt/rustup
ENV CARGO_HOME=/opt/cargo
ENV PATH=/opt/cargo/bin:/opt/mingw-posix/bin:${PATH}

# buildpack-deps already contains the generic native source-build stack
# (gcc/g++/make, git, curl, file, common development libraries, etc.).
# Only install the project-specific tools and the Windows cross compiler.
# Use an immutable Debian archive snapshot so Sid cannot drift between runs.
RUN set -eux; \
    rm -f /etc/apt/sources.list.d/*.sources /etc/apt/sources.list; \
    printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/%s/ sid main\n' \
      "${DEBIAN_SNAPSHOT}" > /etc/apt/sources.list; \
    apt-get -o Acquire::Retries=5 update; \
    apt-get install -y --no-install-recommends \
      aria2 \
      bison \
      clang \
      cmake \
      flex \
      gettext \
      glslang-tools \
      jq \
      libclang-dev \
      libexpat1-dev \
      libwine-dev \
      lld \
      gcc-mingw-w64-x86-64-posix="${MINGW_GCC_PKG_VERSION}" \
      g++-mingw-w64-x86-64-posix="${MINGW_GCC_PKG_VERSION}" \
      mingw-w64-x86-64-dev="${MINGW_HEADERS_PKG_VERSION}" \
      ninja-build \
      openssl \
      osslsigncode \
      p7zip-full \
      pkg-config \
      python3 \
      python3-dev \
      python3-venv; \
    test "$(dpkg-query -W -f='${Version}' gcc-mingw-w64-x86-64-posix)" = "${MINGW_GCC_PKG_VERSION}"; \
    test "$(dpkg-query -W -f='${Version}' g++-mingw-w64-x86-64-posix)" = "${MINGW_GCC_PKG_VERSION}"; \
    test "$(dpkg-query -W -f='${Version}' mingw-w64-x86-64-dev)" = "${MINGW_HEADERS_PKG_VERSION}"; \
    rm -rf /var/lib/apt/lists/*

# Make the POSIX-threading MinGW compiler the unqualified x86_64-w64-mingw32
# toolchain used by Mesa and virtio-d3d11.
RUN set -eux; \
    mkdir -p /opt/mingw-posix/bin; \
    ln -s "$(command -v x86_64-w64-mingw32-gcc-posix)" /opt/mingw-posix/bin/x86_64-w64-mingw32-gcc; \
    ln -s "$(command -v x86_64-w64-mingw32-g++-posix)" /opt/mingw-posix/bin/x86_64-w64-mingw32-g++; \
    for tool in ar gcc-ar ld objcopy ranlib strip windres; do \
      ln -s "$(command -v x86_64-w64-mingw32-${tool})" "/opt/mingw-posix/bin/x86_64-w64-mingw32-${tool}"; \
    done; \
    test "$(x86_64-w64-mingw32-gcc -dumpfullversion)" = "16.2.0"; \
    printf '#include <windows.h>\nint main(void) { bool ok = true; return ok ? 0 : 1; }\n' > /tmp/c23-probe.c; \
    x86_64-w64-mingw32-gcc -c /tmp/c23-probe.c -o /tmp/c23-probe.o; \
    printf '#include <windows.h>\n_Maybenull_ int *p;\nint main(void) { return p != 0; }\n' > /tmp/sal-probe.c; \
    x86_64-w64-mingw32-gcc -c /tmp/sal-probe.c -o /tmp/sal-probe.o; \
    rm -f /tmp/c23-probe.c /tmp/c23-probe.o /tmp/sal-probe.c /tmp/sal-probe.o; \
    x86_64-w64-mingw32-gcc --version | head -1

# Pin the Rust compiler date and cbindgen version. rustup itself is only the
# bootstrap mechanism; the installed compiler/toolchain is the dated nightly.
RUN curl --proto '=https' --tlsv1.2 --fail --location \
      https://sh.rustup.rs -o /tmp/rustup.sh \
 && sh /tmp/rustup.sh -y --no-modify-path --profile minimal --default-toolchain none \
 && rm /tmp/rustup.sh \
 && rustup toolchain install "${RUST_TOOLCHAIN}" --profile minimal --component rust-src \
 && rustup default "${RUST_TOOLCHAIN}" \
 && rustup target add x86_64-pc-windows-msvc --toolchain "${RUST_TOOLCHAIN}" \
 && cargo install cbindgen --version "${CBINDGEN_VERSION}" --locked \
 && rustc --version \
 && cargo --version \
 && cbindgen --version


FROM toolchain AS ewdk

ARG EWDK_VERSION=26100.6584
ARG EWDK_URL
ARG EWDK_SHA256
ARG VCTOOLSVER=14.44.35207
ARG WINSDKVER=10.0.26100.0
ARG CLANG_CL_LINUX_REF=84e723d170e7611c55fff30c44d24c5a04bd4cb7

# The 18.6 GB ISO only exists during this RUN. It is deleted before the layer
# is committed, so the cache stores the extracted toolchain subset, not the ISO.
RUN set -eux; \
    test -n "${EWDK_URL}"; \
    test -n "${EWDK_SHA256}"; \
    iso=/tmp/ewdk.iso; \
    aria2c \
      --continue=true \
      --max-connection-per-server=8 \
      --min-split-size=10M \
      --split=8 \
      --file-allocation=none \
      --dir=/tmp \
      --out=ewdk.iso \
      "${EWDK_URL}"; \
    echo "${EWDK_SHA256}  ${iso}" | sha256sum --check -; \
    mkdir -p /opt/ewdk; \
    7z x -y -r "${iso}" -o/opt/ewdk \
      "Program Files/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/${VCTOOLSVER}/include/*" \
      "Program Files/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/${VCTOOLSVER}/lib/x64/*" \
      "Program Files/Windows Kits/10/Include/${WINSDKVER}/*" \
      "Program Files/Windows Kits/10/Include/wdf/kmdf/1.27/*" \
      "Program Files/Windows Kits/10/Lib/${WINSDKVER}/km/x64/*" \
      "Program Files/Windows Kits/10/Lib/wdf/kmdf/x64/1.27/*"; \
    rm -f "${iso}"; \
    test -d "/opt/ewdk/Program Files/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/${VCTOOLSVER}/include"; \
    test -f "/opt/ewdk/Program Files/Windows Kits/10/Include/${WINSDKVER}/km/ntddk.h"; \
    test -f "/opt/ewdk/Program Files/Windows Kits/10/Include/wdf/kmdf/1.27/wdf.h"; \
    test -d "/opt/ewdk/Program Files/Windows Kits/10/Lib/${WINSDKVER}/km/x64"; \
    test -d "/opt/ewdk/Program Files/Windows Kits/10/Lib/wdf/kmdf/x64/1.27"

# Pin clang-cl-linux by immutable commit and retain only the VFS generator.
RUN curl --fail --location --retry 5 \
      "https://raw.githubusercontent.com/tmp64/clang-cl-linux/${CLANG_CL_LINUX_REF}/generate_vfs.py" \
      -o /opt/ewdk/generate_vfs.py \
 && python3 /opt/ewdk/generate_vfs.py \
      --msvc "/opt/ewdk/Program Files/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC" \
      --sdk "/opt/ewdk/Program Files/Windows Kits/10" \
      --out /opt/ewdk/vfs-overlay.json \
 && test -s /opt/ewdk/vfs-overlay.json


FROM toolchain AS makecat-build

ARG MAKECAT_REF=ee7aa4dd1d10ad5f254020ca0637df5abcc95618

RUN set -eux; \
    git init /src/makecat; \
    git -C /src/makecat remote add origin https://github.com/anonymix007/makecat.git; \
    git -C /src/makecat fetch --depth=1 origin "${MAKECAT_REF}"; \
    git -C /src/makecat checkout --detach FETCH_HEAD; \
    test "$(git -C /src/makecat rev-parse HEAD)" = "${MAKECAT_REF}"

WORKDIR /src/makecat
RUN --mount=type=cache,target=/opt/cargo/registry \
    --mount=type=cache,target=/opt/cargo/git \
    cargo build --release --locked \
 && install -Dm755 target/release/makecat /out/makecat


FROM toolchain AS mesa-build

ARG MESA_ARCHIVE_URL=https://gitlab.freedesktop.org/anonymix007/mesa/-/archive/venus-win32/mesa-venus-win32.tar.gz
ARG MESA_TREE_SHA256=9f216e64201e54408342a1757c1cd2e369b352a88ce96a05e8a4d7e91cad9690
ARG WINSDKVER=10.0.26100.0

COPY --from=ewdk /opt/ewdk /opt/ewdk

# Mesa is content-pinned. The URL may name the branch, but the normalized
# extracted tree must match MESA_TREE_SHA256 exactly or the production build
# stops. Changing the pin intentionally invalidates this layer.
RUN set -eux; \
    mkdir -p /src/mesa; \
    curl --fail --location --retry 5 "${MESA_ARCHIVE_URL}" -o /tmp/mesa.tar.gz; \
    tar -xzf /tmp/mesa.tar.gz -C /src/mesa --strip-components=1; \
    rm /tmp/mesa.tar.gz; \
    actual="$(cd /src/mesa && tar \
      --sort=name \
      --mtime='UTC 1970-01-01' \
      --owner=0 \
      --group=0 \
      --numeric-owner \
      -cf - . | sha256sum | awk '{print $1}')"; \
    echo "Mesa normalized tree: ${actual}"; \
    test "${actual}" = "${MESA_TREE_SHA256}"

# Populate precisely the WDK headers listed by the pinned Mesa source tree.
RUN set -eux; \
    sdk="/opt/ewdk/Program Files/Windows Kits/10/Include/${WINSDKVER}"; \
    mkdir -p /src/mesa/include/winddk; \
    while IFS= read -r header; do \
      test -n "${header}" || continue; \
      source_header="$(find "${sdk}" -type f -iname "${header}" -print -quit)"; \
      if [ -z "${source_header}" ]; then \
        echo "Missing EWDK header for Mesa: ${header}" >&2; \
        exit 1; \
      fi; \
      cp "${source_header}" "/src/mesa/include/winddk/${header}"; \
    done < /src/mesa/include/winddk/.gitignore

RUN cat > /tmp/mingw-x86_64.ini <<'EOF'
[binaries]
c = 'x86_64-w64-mingw32-gcc'
cpp = 'x86_64-w64-mingw32-g++'
ar = 'x86_64-w64-mingw32-ar'
strip = 'x86_64-w64-mingw32-strip'
windres = 'x86_64-w64-mingw32-windres'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF

RUN python3 -m venv /opt/mesa-venv \
 && /opt/mesa-venv/bin/pip install --no-cache-dir \
      "meson==1.7.2" \
      "jinja2==3.1.6" \
      "mako==1.3.10" \
      "packaging==25.0" \
      "ply==3.11" \
      "pyyaml==6.0.2"

ENV PATH=/opt/mesa-venv/bin:/opt/cargo/bin:/opt/mingw-posix/bin:${PATH}

RUN meson setup \
      /src/mesa/build-win64 \
      /src/mesa \
      --cross-file /tmp/mingw-x86_64.ini \
      --buildtype=release \
      --prefix=/ \
      -Dplatforms=windows \
      -Dvulkan-drivers=virtio \
      -Dgallium-drivers= \
      -Dopengl=false \
      -Degl=disabled \
      -Dglx=disabled \
      -Dgbm=disabled \
      -Dllvm=disabled \
      -Dxmlconfig=disabled \
      -Dbuild-tests=false \
      -Dvulkan-manifest-per-architecture=true \
 && meson compile -C /src/mesa/build-win64 -j "$(nproc)" \
 && DESTDIR=/tmp/mesa-stage meson install -C /src/mesa/build-win64 \
 && mesa_dll="$(find /tmp/mesa-stage -type f -name vulkan_virtio.dll -print -quit)" \
 && mesa_json="$(find /tmp/mesa-stage -type f -name virtio_icd.x86_64.json -print -quit)" \
 && test -n "${mesa_dll}" \
 && test -n "${mesa_json}" \
 && mkdir -p /out \
 && cp "${mesa_dll}" /out/vulkan_virtio.dll \
 && cp "${mesa_json}" /out/virtio_icd.x86_64.json \
 && cp /src/mesa/src/virtio/virtio-gpu/wddm_hw.h /out/mesa_wddm_hw.h \
 && grep -q 'vulkan_virtio.dll' /out/virtio_icd.x86_64.json \
 && file /out/vulkan_virtio.dll | grep -q 'PE32+'


FROM toolchain AS d3d11-build

ARG D3D11_SHA
ARG DXVK_SHA
ARG WINSDKVER=10.0.26100.0

COPY --from=ewdk /opt/ewdk /opt/ewdk
COPY --from=d3d11 / /src/d3d11/

# The named Git context is recursively cloned by BuildKit, including the DXVK
# submodule. D3D11_SHA/DXVK_SHA are recorded and checked by the workflow.
RUN set -eux; \
    test -n "${D3D11_SHA}"; \
    test -n "${DXVK_SHA}"; \
    test -f /src/d3d11/thirdparty/dxvk/version.h.in; \
    test -f /src/d3d11/include/virtio_wddm_uapi.h

# Fill in the ignored WDK headers from the pinned EWDK.
RUN set -eux; \
    sdk="/opt/ewdk/Program Files/Windows Kits/10/Include/${WINSDKVER}"; \
    mkdir -p /src/d3d11/include/winddk; \
    while IFS= read -r header; do \
      test -n "${header}" || continue; \
      source_header="$(find "${sdk}" -type f -iname "${header}" -print -quit)"; \
      if [ -z "${source_header}" ]; then \
        echo "Missing EWDK header for D3D11: ${header}" >&2; \
        exit 1; \
      fi; \
      cp "${source_header}" "/src/d3d11/include/winddk/${header}"; \
    done < /src/d3d11/include/winddk/.gitignore

WORKDIR /src/d3d11
RUN set -eux; \
    vulkan_import="$(find /usr -type f -name 'libvulkan-1.a' -print -quit)"; \
    test -n "${vulkan_import}"; \
    export LIBRARY_PATH="$(dirname "${vulkan_import}")"; \
    make -j"$(nproc)" DXVK_GIT_VERSION="${DXVK_SHA}"; \
    test -f build/dist/dx11um_virtio.dll; \
    test -f build/dist/dx11um_virtio.debug; \
    mkdir -p /out; \
    cp build/dist/dx11um_virtio.dll /out/; \
    cp build/dist/dx11um_virtio.debug /out/; \
    cp include/virtio_wddm_uapi.h /out/d3d11_virtio_wddm_uapi.h; \
    file /out/dx11um_virtio.dll | grep -q 'PE32+'; \
    if x86_64-w64-mingw32-objdump -p /out/dx11um_virtio.dll \
       | grep -Eiq 'DLL Name: (libgcc_s|libstdc\+\+|libwinpthread)'; then \
      echo "Unexpected MinGW runtime dependency in dx11um_virtio.dll" >&2; \
      exit 1; \
    fi


FROM toolchain AS package

ARG BUILDER_IMAGE
ARG DEBIAN_SNAPSHOT
ARG MINGW_GCC_PKG_VERSION
ARG MINGW_HEADERS_PKG_VERSION
ARG VERSION_ARG
ARG KMD_SHA
ARG D3D11_SHA
ARG DXVK_SHA
ARG MESA_TREE_SHA256
ARG MAKECAT_REF
ARG CLANG_CL_LINUX_REF
ARG EWDK_VERSION
ARG VCTOOLSVER
ARG WINSDKVER
ARG RUST_TOOLCHAIN
ARG CBINDGEN_VERSION

ENV VCTOOLSVER=${VCTOOLSVER}
ENV WINSDKVER=${WINSDKVER}

COPY --from=ewdk /opt/ewdk /opt/ewdk
COPY --from=makecat-build /out/makecat /usr/local/bin/makecat
COPY --from=kmd / /src/kmd/
COPY --from=mesa-build /out/ /opt/mesa-artifacts/
COPY --from=d3d11-build /out/ /opt/d3d11-artifacts/

WORKDIR /src/kmd

# Configure the EWDK exactly the way the Rust WDK helper expects it.
RUN cat > /src/kmd/ewdk.env <<EOF
#!/bin/bash
export EWDK_ROOT="/opt/ewdk"
export VCTOOLSVER="${VCTOOLSVER}"
export VCTOOLSDIR="/opt/ewdk/Program Files/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/${VCTOOLSVER}"
export WINSDKVER="${WINSDKVER}"
export WINSDKDIR="/opt/ewdk/Program Files/Windows Kits/10"
export VFSOVERLAY="/opt/ewdk/vfs-overlay.json"
EOF

# The GitHub workflow owns the package version. Windows requires DriverVer to
# use four numeric components, so VERSION_ARG is already the exact value used
# for the GitHub Release (for example 20.16.0.0). Patch only the throw-away
# BuildKit copy of the floating KMD source; upstream master remains untouched.
RUN set -eux; \
    test -n "${VERSION_ARG}"; \
    echo "${VERSION_ARG}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; \
    test "$(grep -c '^DriverVer=' /src/kmd/virtio_wddm_rs.inx)" -eq 1; \
    sed -i \
      "s|^DriverVer=.*$|DriverVer=%%BUILDDATE%%, ${VERSION_ARG}|" \
      /src/kmd/virtio_wddm_rs.inx; \
    grep -Fx "DriverVer=%%BUILDDATE%%, ${VERSION_ARG}" \
      /src/kmd/virtio_wddm_rs.inx

# ABI gate:
#   1. Generate the canonical C ABI from the floating KMD master.
#   2. Require it to match the pinned Mesa snapshot.
#   3. Require it to match the floating D3D11 snapshot.
# This stage changes when either qemus context changes, but Mesa itself remains
# independently cached.
RUN set -eux; \
    mkdir -p /tmp/uapi; \
    cbindgen \
      --config /src/kmd/gpu-wddm/cbindgen.toml \
      /src/kmd/gpu-wddm/src/uapi.rs \
      > /tmp/uapi/virtio_wddm_uapi.h; \
    cmp -s /tmp/uapi/virtio_wddm_uapi.h /opt/mesa-artifacts/mesa_wddm_hw.h || { \
      echo "Mesa WDDM ABI snapshot differs from current KMD master." >&2; \
      diff -u /opt/mesa-artifacts/mesa_wddm_hw.h /tmp/uapi/virtio_wddm_uapi.h || true; \
      exit 1; \
    }; \
    cmp -s /tmp/uapi/virtio_wddm_uapi.h /opt/d3d11-artifacts/d3d11_virtio_wddm_uapi.h || { \
      echo "D3D11 WDDM ABI snapshot differs from current KMD master." >&2; \
      diff -u /opt/d3d11-artifacts/d3d11_virtio_wddm_uapi.h /tmp/uapi/virtio_wddm_uapi.h || true; \
      exit 1; \
    }; \
    echo "WDDM ABI snapshots match."

# Stage UMDs exactly where the current KMD dist.sh expects them.
RUN mkdir -p /src/kmd/target/mesa \
 && cp /opt/mesa-artifacts/vulkan_virtio.dll /src/kmd/target/mesa/ \
 && cp /opt/mesa-artifacts/virtio_icd.x86_64.json /src/kmd/target/mesa/ \
 && cp /opt/d3d11-artifacts/dx11um_virtio.dll /src/kmd/target/mesa/ \
 && cp /opt/d3d11-artifacts/dx11um_virtio.debug /src/kmd/target/mesa/

# Generate a long-lived TEST certificate. Production signing can replace this
# stage later without changing any compiler/source inputs.
RUN set -eux; \
    mkdir -p /opt/test-cert; \
    cat > /opt/test-cert/openssl.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = extensions
prompt = no

[dn]
CN = qemus VirtIO GPU CI test signing

[extensions]
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature, keyCertSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
RUN openssl req \
      -x509 \
      -newkey rsa:3072 \
      -nodes \
      -sha256 \
      -days 3650 \
      -config /opt/test-cert/openssl.cnf \
      -keyout /opt/test-cert/key.pem \
      -out /opt/test-cert/cert.pem \
 && openssl x509 \
      -in /opt/test-cert/cert.pem \
      -outform der \
      -out /opt/test-cert/virtio_test_signing.cer \
 && cat > /src/kmd/cert.env <<'EOF'
#!/bin/bash
export CERT="/opt/test-cert/cert.pem"
export KEY="/opt/test-cert/key.pem"
EOF

# Build/package the floating KMD master using the pinned environment and the
# two UMD artifacts. BuildKit reuses all upstream stages when only KMD changes.
RUN --mount=type=cache,target=/opt/cargo/registry \
    --mount=type=cache,target=/opt/cargo/git \
    ./dist.sh

RUN set -eux; \
    dist=/src/kmd/target/dist; \
    cp /opt/test-cert/virtio_test_signing.cer "${dist}/"; \
    cat > "${dist}/BUILDINFO.txt" <<EOF
qemus VirtIO GPU WDDM build
==========================

Driver / release version:           ${VERSION_ARG}

Floating sources resolved once per workflow:
qemus/virtio-d3d11 master:         ${D3D11_SHA}
  DXVK submodule:                  ${DXVK_SHA}
qemus/virtio-drivers-windows:      ${KMD_SHA}

Pinned sources/toolchain:
Mesa venus-win32 normalized tree:  ${MESA_TREE_SHA256}
anonymix007/makecat:               ${MAKECAT_REF}
tmp64/clang-cl-linux:              ${CLANG_CL_LINUX_REF}
EWDK:                              ${EWDK_VERSION}
Windows SDK:                       ${WINSDKVER}
MSVC tools:                        ${VCTOOLSVER}
Rust:                              ${RUST_TOOLCHAIN}
cbindgen:                          ${CBINDGEN_VERSION}
Builder image:                     ${BUILDER_IMAGE}
Debian package snapshot:            ${DEBIAN_SNAPSHOT}
MinGW GCC packages:                 ${MINGW_GCC_PKG_VERSION}
MinGW-w64 headers:                  ${MINGW_HEADERS_PKG_VERSION}
EOF

# Final package validation.
RUN set -eux; \
    dist=/src/kmd/target/dist; \
    for file_name in \
      virtio_wddm_rs.inf \
      virtio_wddm_rs.cat \
      virtio_wddm_rs.sys \
      virtio_gpu_wddm_rs.pdb \
      dx11um_virtio.dll \
      dx11um_virtio.debug \
      vulkan_virtio.dll \
      vulkan_virtio.debug \
      virtio_icd.x86_64.json \
      virtio_test_signing.cer \
      BUILDINFO.txt; do \
        test -s "${dist}/${file_name}"; \
    done; \
    grep -q 'dx11um_virtio.dll' "${dist}/virtio_wddm_rs.inf"; \
    grep -q 'vulkan_virtio.dll' "${dist}/virtio_wddm_rs.inf"; \
    grep -q 'virtio_icd.x86_64.json' "${dist}/virtio_wddm_rs.inf"; \
    grep -Fq ", ${VERSION_ARG}" "${dist}/virtio_wddm_rs.inf"; \
    test "$(grep -c '^DriverVer=' "${dist}/virtio_wddm_rs.inf")" -eq 1; \
    grep -q 'vulkan_virtio.dll' "${dist}/virtio_icd.x86_64.json"; \
    file "${dist}/virtio_wddm_rs.sys" | grep -q 'PE32+'; \
    file "${dist}/dx11um_virtio.dll" | grep -q 'PE32+'; \
    file "${dist}/vulkan_virtio.dll" | grep -q 'PE32+'; \
    for dll in "${dist}/dx11um_virtio.dll" "${dist}/vulkan_virtio.dll"; do \
      if x86_64-w64-mingw32-objdump -p "${dll}" \
         | grep -Eiq 'DLL Name: (libgcc_s|libstdc\+\+|libwinpthread)'; then \
        echo "Unexpected MinGW runtime dependency in ${dll}" >&2; \
        exit 1; \
      fi; \
    done; \
    find "${dist}" -maxdepth 1 -type f -printf '%f\n' | sort


FROM scratch AS artifact
COPY --from=package /src/kmd/target/dist/ /
