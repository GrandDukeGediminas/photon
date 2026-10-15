#ifndef PHOTON_CVULKAN_SHIM_H
#define PHOTON_CVULKAN_SHIM_H
#include <vulkan/vulkan.h>

// VK_KHR_xlib_surface without the X11 headers (PhotonVulkan must not depend on Xlib; the host passes its Display* and
// Window): the create-info layout of vulkan_xlib.h, called through vkGetInstanceProcAddr.
typedef struct PhotonXlibSurfaceCreateInfo {
    VkStructureType sType;
    const void *pNext;
    VkFlags flags;
    void *dpy;
    unsigned long window;
} PhotonXlibSurfaceCreateInfo;

static inline VkResult photon_vkCreateXlibSurfaceKHR(VkInstance instance, void *dpy, unsigned long window, VkSurfaceKHR *surface) {
    typedef VkResult (*Fn)(VkInstance, const PhotonXlibSurfaceCreateInfo *, const VkAllocationCallbacks *, VkSurfaceKHR *);
    Fn fn = (Fn)vkGetInstanceProcAddr(instance, "vkCreateXlibSurfaceKHR");
    if (!fn) return VK_ERROR_EXTENSION_NOT_PRESENT;
    PhotonXlibSurfaceCreateInfo ci = { (VkStructureType)1000004000 /* VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR */, 0, 0, dpy, window };
    return fn(instance, &ci, 0, surface);
}

// VK_KHR_wayland_surface the same way (vulkan_wayland.h's create-info layout; the host passes its wl_display and
// wl_surface).
typedef struct PhotonWaylandSurfaceCreateInfo {
    VkStructureType sType;
    const void *pNext;
    VkFlags flags;
    void *display;
    void *surface;
} PhotonWaylandSurfaceCreateInfo;

static inline VkResult photon_vkCreateWaylandSurfaceKHR(VkInstance instance, void *display, void *surface, VkSurfaceKHR *out) {
    typedef VkResult (*Fn)(VkInstance, const PhotonWaylandSurfaceCreateInfo *, const VkAllocationCallbacks *, VkSurfaceKHR *);
    Fn fn = (Fn)vkGetInstanceProcAddr(instance, "vkCreateWaylandSurfaceKHR");
    if (!fn) return VK_ERROR_EXTENSION_NOT_PRESENT;
    PhotonWaylandSurfaceCreateInfo ci = { (VkStructureType)1000006000 /* VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR */, 0, 0, display, surface };
    return fn(instance, &ci, 0, out);
}
#endif
