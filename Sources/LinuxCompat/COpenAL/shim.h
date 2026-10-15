#ifndef PHOTON_COPENAL_SHIM_H
#define PHOTON_COPENAL_SHIM_H
// OpenAL Soft, the library the engine plays sound objects through (mediaextensions64.dll links OpenAL Soft 1.21.1,
// docs/re/06 §4.1, loader-keys §6.9). Extension prototypes (ALC_SOFT_loopback, ALC_SOFT_HRTF, AL_SOFT_source_spatialize)
// are declared so the loopback device can render offline for the checks in `photon-linux sound-check`.
#define AL_ALEXT_PROTOTYPES 1
#include <AL/al.h>
#include <AL/alc.h>
#include <AL/alext.h>
#endif
