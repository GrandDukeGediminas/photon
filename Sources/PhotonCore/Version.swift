import CPhotonVersion

/// photon2's version: the one packaging stamped at build time (`-Xcc -DPHOTON_VERSION="…"`), else
/// `PHOTON_VERSION_BASE` from Sources/CPhotonVersion/include/photon_version.h with "-dev" appended.
public enum PhotonVersion {
    public static let string = String(cString: photon_version())
}
