#ifndef PHOTON_CFREETYPE_SHIM_H
#define PHOTON_CFREETYPE_SHIM_H
// FreeType (glyph outlines, rasterisation, metrics) and fontconfig (family name → file) for the CoreText stand-in.
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_OUTLINE_H
#include FT_GLYPH_H
#include FT_TRUETYPE_TABLES_H
#include FT_SFNT_NAMES_H
#include <fontconfig/fontconfig.h>
// FcFreeTypeQuery: declared in fontconfig.h up to 2.15, only in fcfreetype.h from 2.16 (the GNOME 51 runtime).
#include <fontconfig/fcfreetype.h>
#endif
