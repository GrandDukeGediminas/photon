#pragma once
// photon2's version (docs/linux-port.md §6.2). PHOTON_VERSION_BASE is the one place the version is written down: the
// packaging scripts read it as their default (scripts/linux/env.sh photon_version, after `git describe --tags`), and
// builds that do not stamp a version report it with "-dev" appended. A packaging build stamps the version it packages
// with `swift build -Xcc '-DPHOTON_VERSION="<version>"'` (package-build.sh, the Flatpak manifest).
#define PHOTON_VERSION_BASE "0.9.0"

/// The stamped version, or PHOTON_VERSION_BASE "-dev".
const char *photon_version(void);
