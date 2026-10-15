# photon2 Linux build + headless test image (docs/linux-port.md §8).
# Swift toolchain, Vulkan loader + Mesa lavapipe (CPU Vulkan, no GPU needed), glslang + SPIRV-Cross, the C libraries the
# Linux shims wrap (libpng, libjpeg-turbo, lz4, FreeType/fontconfig, JavaScriptCore from WebKitGTK, X11/XRandR, OpenAL),
# Xvfb + ImageMagick for desktop-host screenshots, and the phase-3 media and text libraries below.
ARG SWIFT_IMAGE=swift:6.2-noble
FROM ${SWIFT_IMAGE}

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libvulkan-dev mesa-vulkan-drivers vulkan-tools \
        glslang-tools spirv-cross \
        libpng-dev libturbojpeg0-dev liblz4-dev zlib1g-dev \
        libfreetype-dev libfontconfig-dev fontconfig fonts-dejavu-core fonts-liberation2 fonts-noto-cjk \
        libjavascriptcoregtk-4.1-dev \
        libx11-dev libxrandr-dev libxext-dev xvfb x11-utils imagemagick \
        libopenal-dev \
        python3 python3-numpy python3-pil \
    && rm -rf /var/lib/apt/lists/*

# Phase 3 (media and text, docs/linux-port.md §3.3, §3.5): GStreamer for video textures and video wallpapers (qtdemux,
# matroska/vpx from plugins-good, H.264/HEVC through gst-libav), HarfBuzz for shaping, stb_image for GIFs (the decoder
# the engine's resourceutil64.dll uses), and metric-compatible substitutes for the Windows/macOS fonts wallpapers name
# (Arimo/Tinos/Cousine from croscore, Carlito/Caladea), plus fallback coverage like a desktop install: Noto Color
# Emoji (CBDT) and fonts-noto-core (Thai, Arabic, Hebrew, Indic, ...).
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
        gstreamer1.0-libav gstreamer1.0-tools \
        libharfbuzz-dev libstb-dev \
        fonts-croscore fonts-crosextra-carlito fonts-crosextra-caladea fonts-noto-color-emoji fonts-noto-core \
    && rm -rf /var/lib/apt/lists/*

# Force lavapipe so renders are deterministic and identical across hosts.
ENV VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json \
    VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.json \
    PHOTON_GLSLANG=/usr/bin/glslangValidator \
    PHOTON_SPIRV_CROSS=/usr/bin/spirv-cross

WORKDIR /src

# Phase 4 (audio and system integration, docs/linux-port.md §3.6, §5): OpenAL Soft pinned to 1.21.1, the version linked
# into the engine's mediaextensions64.dll ("1.1 ALSOFT 1.21.1"), built from the release tag with its embedded default
# HRTF (the MinPHR03 set the dll carries) and the PulseAudio/ALSA backends; it replaces the distro's 1.23.1 so pkg-config
# and the loader find only 1.21.1. One patch: `fastf2i` rounds to nearest (lrintf) on every CPU. 1.21.1 rounds with
# cvtss2si only on x86 and truncates elsewhere, so on arm64 every fractional HRTF delay came out one sample shorter
# than in the engine's x86 build (GetHrtfCoeffs); x86_64 builds are unchanged by it. PipeWire (daemon, pipewire-pulse, WirePlumber, pw-cat) and the PulseAudio client
# library for spectrum capture from the default sink's monitor; GIO for D-Bus (MPRIS, UPower, logind, screensaver);
# python3-gi for the fake D-Bus services in the tests; XScreenSaver/DPMS headers and xset.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        cmake g++ make curl ca-certificates libpulse-dev libasound2-dev \
        pipewire pipewire-pulse pipewire-bin wireplumber libpipewire-0.3-dev pulseaudio-utils \
        libglib2.0-dev python3-gi gir1.2-glib-2.0 dbus-daemon \
        libxss-dev x11-xserver-utils \
    && apt-get purge -y libopenal-dev libopenal1 libopenal-data \
    && rm -rf /var/lib/apt/lists/*
ARG OPENAL_VERSION=1.21.1
RUN curl -fsSL https://github.com/kcat/openal-soft/archive/refs/tags/${OPENAL_VERSION}.tar.gz -o /tmp/openal.tar.gz \
    && mkdir /tmp/openal && tar -xzf /tmp/openal.tar.gz -C /tmp/openal --strip-components=1 \
    && sed -i '/^inline int fastf2i/,/^}/ s/return static_cast<int>(f);/return static_cast<int>(__builtin_lrintf(f));/' \
        /tmp/openal/common/alnumeric.h \
    && grep -q "__builtin_lrintf(f)" /tmp/openal/common/alnumeric.h \
    && cmake -S /tmp/openal -B /tmp/openal/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF -DALSOFT_REQUIRE_PULSEAUDIO=ON \
        -DALSOFT_EMBED_HRTF_DATA=ON -DALSOFT_INSTALL_HRTF_DATA=ON \
    && cmake --build /tmp/openal/build -j"$(nproc)" && cmake --install /tmp/openal/build \
    && cp "/tmp/openal/hrtf/Default HRTF.mhr" /usr/local/share/openal/default-hrtf-1.21.1.mhr \
    && ldconfig && rm -rf /tmp/openal /tmp/openal.tar.gz

# llvmpipe samples 8-bit textures through its AoS fixed-point path by default; its bilinear weights truncate, which made
# every textured blur/downsample pass about half a level darker than the Apple GPU (2902406982 −2.4 to −2.9 levels
# overall, docs/linux-port.md §7). The float SoA sampler has no such bias; renders are still deterministic.
ENV GALLIVM_PERF=no_aos_sampling

# Phase 5 (Wayland host and web wallpapers, docs/linux-port.md §5.2, §5.3): libwayland (client + wayland-scanner) and
# wayland-protocols (xdg-shell, xdg-output, viewporter, fractional-scale) for the layer-shell host; the wlr protocols
# (layer-shell, foreign-toplevel-management) are vendored in vendor/wayland-protocols. sway and labwc (wlroots, headless
# backend; labwc is a stacking compositor with a maximized state) and grim (wlr-screencopy) to run and screenshot the host
# without a GPU or a display. WebKitGTK 4.1 (GTK 3; its
# JavaScriptCore is the javascriptcoregtk-4.1 SceneScript already links, so the process has one JSC) and
# gtk-layer-shell for web wallpapers; gsettings-desktop-schemas + gsettings for the GNOME static-background fallback.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libwayland-dev libwayland-bin wayland-protocols sway labwc grim \
        libwebkit2gtk-4.1-dev libgtk-layer-shell-dev \
        gsettings-desktop-schemas libglib2.0-bin dconf-gsettings-backend \
    && rm -rf /var/lib/apt/lists/*

# Phase 6 (the app and packaging, docs/linux-port.md §6): the SVG pixbuf loader and the Adwaita / hicolor icon themes the
# GTK 3 windows draw their icons with, rsvg-convert for the app icon PNGs, desktop-file-validate for the .desktop entries,
# and rpm (rpmbuild) next to dpkg-deb for scripts/linux/package.sh. GTK 3's headers come with libwebkit2gtk-4.1-dev above.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        librsvg2-common librsvg2-bin adwaita-icon-theme hicolor-icon-theme desktop-file-utils rpm file \
    && rm -rf /var/lib/apt/lists/*

# Desktop environments (docs/linux-port.md §5.2): KWin 5.27 (`kwin_wayland --virtual`) for the Plasma window-management
# rule inputs, and GNOME Shell 46 (`gnome-shell --headless --wayland --virtual-monitor`) for the GNOME extension host.
# kwin_wayland carries file capabilities (cap_sys_resource), which a container's bounding set refuses at exec, so they are
# removed. zip packs the extension; wayland-info lists a compositor's globals.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        kwin-wayland plasma-wayland-protocols gnome-shell libcap2-bin wayland-utils zip unzip \
    && setcap -r /usr/bin/kwin_wayland \
    && rm -rf /var/lib/apt/lists/*
