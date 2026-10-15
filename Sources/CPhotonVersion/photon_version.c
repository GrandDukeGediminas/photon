#include "photon_version.h"

#ifndef PHOTON_VERSION
#define PHOTON_VERSION PHOTON_VERSION_BASE "-dev"
#endif

const char *photon_version(void) { return PHOTON_VERSION; }
