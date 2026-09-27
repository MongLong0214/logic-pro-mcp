"""A ctypes bridge to CoreFoundation, CoreGraphics and the Accessibility C API. Stdlib only.

Ported from Scripts/livekit/evidence.py:305-400 (`_AXRuntime`), which exists because PyObjC's
Quartz does not vend the AX functions in this installation, and extended with a generic CF-to-Python
conversion so CGWindowListCopyWindowInfo and CGSessionCopyCurrentDictionary can be read without
PyObjC at all (the verifier must run under /usr/bin/python3 with nothing installed).

Frameworks are loaded on first use, never at import: the offline tests import the modules that use
this one on machines (CI Linux) where there is no framework to load.

AX status codes kept from the measured record (reference_ax_status_traps_and_dead_tuple_expect):
-25205 (attribute unsupported) and -25212 (no value) are ANSWERS -- the element has no such value.
Every other non-zero status is a failure to read, and is reported with its number, never as absent.
-25204 (cannot complete) is a timing statement (evidence.py:622-629), the one worth asking again.
"""

import ctypes

AX_SUCCESS = 0
AX_CANNOT_COMPLETE = -25204
AX_ATTRIBUTE_UNSUPPORTED = -25205
AX_NO_VALUE = -25212
AX_ANSWERS = (AX_ATTRIBUTE_UNSUPPORTED, AX_NO_VALUE)

_UTF8 = 0x08000100
_CF_NUMBER_SINT64 = 4
_CF_NUMBER_DOUBLE = 13
_AX_VALUE_CGPOINT = 1
_AX_VALUE_CGSIZE = 2

_LIBS = {}


class _CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


class _CGSize(ctypes.Structure):
    _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]


def libs():
    """(cf, cg, ax) with their signatures declared; loaded once, on first call."""
    if _LIBS:
        return _LIBS["cf"], _LIBS["cg"], _LIBS["ax"]
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    ax = ctypes.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
    vp, ul, lg = ctypes.c_void_p, ctypes.c_ulong, ctypes.c_long
    sig = [
        (cf.CFGetTypeID, ul, (vp,)), (cf.CFRelease, None, (vp,)), (cf.CFRetain, vp, (vp,)),
        (cf.CFStringGetTypeID, ul, ()), (cf.CFNumberGetTypeID, ul, ()),
        (cf.CFBooleanGetTypeID, ul, ()), (cf.CFArrayGetTypeID, ul, ()),
        (cf.CFDictionaryGetTypeID, ul, ()), (cf.CFNullGetTypeID, ul, ()),
        (cf.CFStringCreateWithCString, vp, (vp, ctypes.c_char_p, ctypes.c_uint32)),
        (cf.CFStringGetLength, lg, (vp,)),
        (cf.CFStringGetMaximumSizeForEncoding, lg, (lg, ctypes.c_uint32)),
        (cf.CFStringGetCString, ctypes.c_bool, (vp, ctypes.c_char_p, lg, ctypes.c_uint32)),
        (cf.CFNumberIsFloatType, ctypes.c_bool, (vp,)),
        (cf.CFNumberGetValue, ctypes.c_bool, (vp, lg, vp)),
        (cf.CFBooleanGetValue, ctypes.c_bool, (vp,)),
        (cf.CFArrayGetCount, lg, (vp,)), (cf.CFArrayGetValueAtIndex, vp, (vp, lg)),
        (cf.CFDictionaryGetCount, lg, (vp,)),
        (cf.CFDictionaryGetKeysAndValues, None, (vp, ctypes.POINTER(vp), ctypes.POINTER(vp))),
        (cf.CFCopyDescription, vp, (vp,)),
        (cg.CGWindowListCopyWindowInfo, vp, (ctypes.c_uint32, ctypes.c_uint32)),
        (cg.CGSessionCopyCurrentDictionary, vp, ()),
        (cg.CGWindowLevelForKey, ctypes.c_int32, (ctypes.c_int32,)),
        (ax.AXUIElementCreateApplication, vp, (ctypes.c_int,)),
        (ax.AXUIElementCopyAttributeValue, ctypes.c_int, (vp, vp, ctypes.POINTER(vp))),
        (ax.AXUIElementSetMessagingTimeout, ctypes.c_int, (vp, ctypes.c_float)),
        (ax.AXUIElementGetTypeID, ul, ()),
        (ax.AXValueGetTypeID, ul, ()), (ax.AXValueGetType, ctypes.c_int, (vp,)),
        (ax.AXValueGetValue, ctypes.c_bool, (vp, ctypes.c_int, vp)),
        (ax.AXIsProcessTrusted, ctypes.c_bool, ()),
    ]
    for fn, restype, argtypes in sig:
        fn.restype = restype
        fn.argtypes = argtypes
    _LIBS.update(cf=cf, cg=cg, ax=ax)
    return cf, cg, ax


def cfstring(text):
    cf, _, _ = libs()
    return cf.CFStringCreateWithCString(None, text.encode("utf-8"), _UTF8)


def _string(ref):
    cf, _, _ = libs()
    length = cf.CFStringGetLength(ref)
    capacity = cf.CFStringGetMaximumSizeForEncoding(length, _UTF8) + 1
    buffer = ctypes.create_string_buffer(max(capacity, 1))
    if not cf.CFStringGetCString(ref, buffer, capacity, _UTF8):
        return {"cf_unconvertible": "CFString did not decode as UTF-8"}
    return buffer.value.decode("utf-8", "replace")


def to_python(ref, depth=0):
    """A CF object as plain Python. Unknown types keep their CFCopyDescription, never vanish."""
    if not ref:
        return None
    cf, _, ax = libs()
    kind = cf.CFGetTypeID(ref)
    if kind == cf.CFStringGetTypeID():
        return _string(ref)
    if kind == cf.CFBooleanGetTypeID():
        return bool(cf.CFBooleanGetValue(ref))
    if kind == cf.CFNumberGetTypeID():
        if cf.CFNumberIsFloatType(ref):
            out = ctypes.c_double()
            ok = cf.CFNumberGetValue(ref, _CF_NUMBER_DOUBLE, ctypes.byref(out))
        else:
            out = ctypes.c_int64()
            ok = cf.CFNumberGetValue(ref, _CF_NUMBER_SINT64, ctypes.byref(out))
        return out.value if ok else {"cf_unconvertible": "CFNumber"}
    if kind == cf.CFNullGetTypeID():
        return None
    if depth > 16:
        return {"cf_unconvertible": "nesting deeper than 16"}
    if kind == cf.CFArrayGetTypeID():
        return [to_python(cf.CFArrayGetValueAtIndex(ref, i), depth + 1)
                for i in range(cf.CFArrayGetCount(ref))]
    if kind == cf.CFDictionaryGetTypeID():
        count = cf.CFDictionaryGetCount(ref)
        keys = (ctypes.c_void_p * count)()
        values = (ctypes.c_void_p * count)()
        cf.CFDictionaryGetKeysAndValues(ref, keys, values)
        out = {}
        for key, value in zip(keys, values):
            name = to_python(key, depth + 1)
            out[name if isinstance(name, str) else repr(name)] = to_python(value, depth + 1)
        return out
    if kind == ax.AXUIElementGetTypeID():
        return {"ax_element": True}
    if kind == ax.AXValueGetTypeID():
        value_type = ax.AXValueGetType(ref)
        if value_type == _AX_VALUE_CGPOINT:
            point = _CGPoint()
            if ax.AXValueGetValue(ref, value_type, ctypes.byref(point)):
                return {"x": point.x, "y": point.y}
        if value_type == _AX_VALUE_CGSIZE:
            size = _CGSize()
            if ax.AXValueGetValue(ref, value_type, ctypes.byref(size)):
                return {"w": size.width, "h": size.height}
    described = cf.CFCopyDescription(ref)
    try:
        return {"cf_type_id": int(kind), "description": _string(described) if described else None}
    finally:
        if described:
            cf.CFRelease(described)


def copy_owned(fn, *args):
    """Call a CF *Copy* function, convert its result, release it. None when it returned NULL."""
    cf, _, _ = libs()
    ref = fn(*args)
    if not ref:
        return None
    try:
        return to_python(ref)
    finally:
        cf.CFRelease(ref)


class AX:
    """One AX session against one process. Every copied value is released by `close()`.

    `messaging_timeout_s` bounds every AX call on the application element (AXUIElementSet
    MessagingTimeout); without it a wedged Logic blocks the reader for the system default of six
    seconds per call, which over a tree walk is unbounded in practice.
    """

    def __init__(self, pid, messaging_timeout_s=3.0):
        self.cf, _, self.ax = libs()
        self.pid = pid
        self._owned = []
        self.app = self.ax.AXUIElementCreateApplication(pid)
        if self.app:
            self._owned.append(self.app)
            self.timeout_status = self.ax.AXUIElementSetMessagingTimeout(
                self.app, ctypes.c_float(messaging_timeout_s))
        else:
            self.timeout_status = None

    def copy(self, element, name):
        """(status, ref). A successful ref is owned by this session."""
        key = cfstring(name)
        value = ctypes.c_void_p()
        try:
            status = self.ax.AXUIElementCopyAttributeValue(element, key, ctypes.byref(value))
        finally:
            self.cf.CFRelease(key)
        if status == AX_SUCCESS and value.value:
            self._owned.append(value.value)
            return status, value.value
        return status, None

    def value(self, element, name):
        """{"status", "value"}: the attribute as Python, or the status that says why not."""
        status, ref = self.copy(element, name)
        return {"status": status, "value": to_python(ref) if ref else None}

    def elements(self, element, name):
        """{"status", "elements"}: an array attribute as element refs (owned by this session)."""
        status, ref = self.copy(element, name)
        if status != AX_SUCCESS or not ref:
            return {"status": status, "elements": None}
        if self.cf.CFGetTypeID(ref) != self.cf.CFArrayGetTypeID():
            return {"status": status, "elements": None, "not_an_array": True}
        return {"status": status,
                "elements": [self.cf.CFArrayGetValueAtIndex(ref, i)
                             for i in range(self.cf.CFArrayGetCount(ref))]}

    def close(self):
        for ref in reversed(self._owned):
            self.cf.CFRelease(ref)
        self._owned.clear()


def text_of(read):
    """A string attribute read as (text, error). -25205/-25212 are answers: ('', None)."""
    status = read["status"]
    if status == AX_SUCCESS:
        value = read["value"]
        return (value, None) if isinstance(value, str) else ("", f"non-string {type(value).__name__}")
    if status in AX_ANSWERS:
        return "", None
    return "", status
