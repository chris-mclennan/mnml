//! Minimal CoreAudio bindings — just enough to read and set the Mac's
//! default output device.
//!
//! Needed because sending this Mac's audio to a Sonos means pointing
//! the system output at a loopback device first (see [`super::stream`]).
//! Hand-rolled FFI rather than a `coreaudio-sys` dependency: four
//! functions and a handful of four-char-code constants don't justify a
//! bindgen build step, and mnml already links frameworks this way.
//!
//! macOS only — the module isn't compiled elsewhere.

use std::ffi::{c_char, c_void};

/// CoreAudio object handle (devices, streams, the system object).
pub type DeviceId = u32;

/// The well-known handle for "the audio system itself".
const SYSTEM_OBJECT: DeviceId = 1;

/// Four-char-code property selectors/scopes, as CoreAudio spells them.
const PROP_DEVICES: u32 = fourcc(b"dev#");
const PROP_DEFAULT_OUTPUT: u32 = fourcc(b"dOut");
const PROP_NAME: u32 = fourcc(b"lnam");
const PROP_UID: u32 = fourcc(b"uid ");
const PROP_STREAM_CONFIG: u32 = fourcc(b"slay");
const SCOPE_GLOBAL: u32 = fourcc(b"glob");
const SCOPE_OUTPUT: u32 = fourcc(b"outp");
const ELEMENT_MAIN: u32 = 0;

/// UTF-8 encoding constant for `CFStringGetCString`.
const CF_UTF8: u32 = 0x0800_0100;

/// Build a four-char code the way CoreAudio's headers do.
const fn fourcc(s: &[u8; 4]) -> u32 {
    ((s[0] as u32) << 24) | ((s[1] as u32) << 16) | ((s[2] as u32) << 8) | (s[3] as u32)
}

#[repr(C)]
struct PropertyAddress {
    selector: u32,
    scope: u32,
    element: u32,
}

impl PropertyAddress {
    const fn global(selector: u32) -> Self {
        PropertyAddress {
            selector,
            scope: SCOPE_GLOBAL,
            element: ELEMENT_MAIN,
        }
    }
}

/// An `AudioBufferList` header — only `count` is read, to tell whether
/// a device has any output channels at all.
#[repr(C)]
struct BufferListHeader {
    count: u32,
}

#[link(name = "CoreAudio", kind = "framework")]
unsafe extern "C" {
    fn AudioObjectGetPropertyDataSize(
        id: DeviceId,
        addr: *const PropertyAddress,
        qualifier_size: u32,
        qualifier: *const c_void,
        size: *mut u32,
    ) -> i32;
    fn AudioObjectGetPropertyData(
        id: DeviceId,
        addr: *const PropertyAddress,
        qualifier_size: u32,
        qualifier: *const c_void,
        size: *mut u32,
        data: *mut c_void,
    ) -> i32;
    fn AudioObjectSetPropertyData(
        id: DeviceId,
        addr: *const PropertyAddress,
        qualifier_size: u32,
        qualifier: *const c_void,
        size: u32,
        data: *const c_void,
    ) -> i32;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFStringGetCString(s: *const c_void, buf: *mut c_char, size: isize, encoding: u32) -> u8;
    fn CFRelease(cf: *const c_void);
}

/// An output-capable audio device.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    pub id: DeviceId,
    pub name: String,
    /// Persistent identifier — survives reboots, unlike `id`.
    pub uid: String,
}

/// Read a `CFStringRef`-valued device property as a Rust `String`.
fn string_property(id: DeviceId, selector: u32) -> Option<String> {
    let addr = PropertyAddress::global(selector);
    let mut cf: *const c_void = std::ptr::null();
    let mut size = std::mem::size_of::<*const c_void>() as u32;
    // SAFETY: `cf` is a correctly-sized out-pointer for the CFStringRef
    // CoreAudio writes; we only read it when the call reports success.
    let status = unsafe {
        AudioObjectGetPropertyData(
            id,
            &addr,
            0,
            std::ptr::null(),
            &mut size,
            &mut cf as *mut _ as *mut c_void,
        )
    };
    if status != 0 || cf.is_null() {
        return None;
    }
    let mut buf = [0i8; 512];
    // SAFETY: `buf` is a valid, correctly-sized destination; CoreAudio
    // handed us ownership of `cf`, so we release it either way.
    let ok = unsafe { CFStringGetCString(cf, buf.as_mut_ptr(), buf.len() as isize, CF_UTF8) };
    unsafe { CFRelease(cf) };
    if ok == 0 {
        return None;
    }
    let bytes: Vec<u8> = buf
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();
    String::from_utf8(bytes).ok()
}

/// True when the device exposes at least one output channel — the
/// filter that separates speakers from microphones.
fn has_output(id: DeviceId) -> bool {
    let addr = PropertyAddress {
        selector: PROP_STREAM_CONFIG,
        scope: SCOPE_OUTPUT,
        element: ELEMENT_MAIN,
    };
    let mut size = 0u32;
    // SAFETY: size-query form — no data buffer is written.
    if unsafe { AudioObjectGetPropertyDataSize(id, &addr, 0, std::ptr::null(), &mut size) } != 0 {
        return false;
    }
    if (size as usize) < std::mem::size_of::<BufferListHeader>() {
        return false;
    }
    let mut buf = vec![0u8; size as usize];
    // SAFETY: `buf` is exactly the size CoreAudio just asked for.
    let status = unsafe {
        AudioObjectGetPropertyData(
            id,
            &addr,
            0,
            std::ptr::null(),
            &mut size,
            buf.as_mut_ptr() as *mut c_void,
        )
    };
    if status != 0 {
        return false;
    }
    // SAFETY: an AudioBufferList always begins with its buffer count.
    let header = unsafe { &*(buf.as_ptr() as *const BufferListHeader) };
    header.count > 0
}

/// Every output-capable device on the system.
pub fn output_devices() -> Vec<Device> {
    let addr = PropertyAddress::global(PROP_DEVICES);
    let mut size = 0u32;
    // SAFETY: size-query form — no data buffer is written.
    if unsafe {
        AudioObjectGetPropertyDataSize(SYSTEM_OBJECT, &addr, 0, std::ptr::null(), &mut size)
    } != 0
    {
        return Vec::new();
    }
    let count = size as usize / std::mem::size_of::<DeviceId>();
    let mut ids = vec![0u32; count];
    // SAFETY: `ids` holds exactly `size` bytes, as just queried.
    if unsafe {
        AudioObjectGetPropertyData(
            SYSTEM_OBJECT,
            &addr,
            0,
            std::ptr::null(),
            &mut size,
            ids.as_mut_ptr() as *mut c_void,
        )
    } != 0
    {
        return Vec::new();
    }
    ids.into_iter()
        .filter(|&id| has_output(id))
        .map(|id| Device {
            id,
            name: string_property(id, PROP_NAME).unwrap_or_default(),
            uid: string_property(id, PROP_UID).unwrap_or_default(),
        })
        .collect()
}

/// The current default output device.
pub fn default_output() -> Option<Device> {
    let addr = PropertyAddress::global(PROP_DEFAULT_OUTPUT);
    let mut id: DeviceId = 0;
    let mut size = std::mem::size_of::<DeviceId>() as u32;
    // SAFETY: `id` is a correctly-sized out-pointer for a device id.
    let status = unsafe {
        AudioObjectGetPropertyData(
            SYSTEM_OBJECT,
            &addr,
            0,
            std::ptr::null(),
            &mut size,
            &mut id as *mut _ as *mut c_void,
        )
    };
    if status != 0 || id == 0 {
        return None;
    }
    Some(Device {
        id,
        name: string_property(id, PROP_NAME).unwrap_or_default(),
        uid: string_property(id, PROP_UID).unwrap_or_default(),
    })
}

/// Make `id` the system's default output device.
pub fn set_default_output(id: DeviceId) -> Result<(), String> {
    let addr = PropertyAddress::global(PROP_DEFAULT_OUTPUT);
    // SAFETY: passing one device id of the documented size.
    let status = unsafe {
        AudioObjectSetPropertyData(
            SYSTEM_OBJECT,
            &addr,
            0,
            std::ptr::null(),
            std::mem::size_of::<DeviceId>() as u32,
            &id as *const _ as *const c_void,
        )
    };
    if status == 0 {
        Ok(())
    } else {
        Err(format!(
            "CoreAudio refused the output switch (status {status})"
        ))
    }
}

/// First output device whose name contains `needle`, case-insensitively.
///
/// Used to find the loopback device ("BlackHole") without pinning an
/// exact product name — the 2ch and 16ch builds differ in their names.
pub fn find_output(needle: &str) -> Option<Device> {
    let needle = needle.to_ascii_lowercase();
    output_devices()
        .into_iter()
        .find(|d| d.name.to_ascii_lowercase().contains(&needle))
}

/// The Mac's own speakers, for putting the system output back after a
/// stream — including one this process didn't start (if mnml is killed
/// mid-stream the output is left pointing at the loopback device, which
/// reads as "my Mac went silent").
///
/// Matched by UID first (`BuiltInSpeakerDevice` is stable across
/// machines), then by name, then by "any output that isn't a loopback".
pub fn builtin_output() -> Option<Device> {
    let devices = output_devices();
    devices
        .iter()
        .find(|d| d.uid == "BuiltInSpeakerDevice")
        .or_else(|| {
            devices
                .iter()
                .find(|d| d.name.to_ascii_lowercase().contains("built-in"))
        })
        .or_else(|| {
            devices.iter().find(|d| {
                !d.name
                    .to_ascii_lowercase()
                    .contains(super::stream::LOOPBACK_NAME)
            })
        })
        .cloned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fourcc_matches_the_documented_constants() {
        // Spot-check against the values in CoreAudio's headers.
        assert_eq!(PROP_DEVICES, 0x6465_7623);
        assert_eq!(PROP_DEFAULT_OUTPUT, 0x644F_7574);
        assert_eq!(SCOPE_GLOBAL, 0x676C_6F62);
        assert_eq!(SCOPE_OUTPUT, 0x6F75_7470);
        assert_eq!(fourcc(b"lnam"), PROP_NAME);
    }

    /// Enumeration must never panic and must agree with itself: a Mac
    /// always has at least one output, and the default is one of them.
    #[test]
    fn enumerates_real_devices_consistently() {
        let devices = output_devices();
        assert!(
            !devices.is_empty(),
            "a Mac always has at least one output device"
        );
        if let Some(def) = default_output() {
            assert!(
                devices.iter().any(|d| d.id == def.id),
                "the default output should appear in the device list"
            );
        }
    }

    #[test]
    fn builtin_output_never_returns_the_loopback_device() {
        if let Some(d) = builtin_output() {
            assert!(
                !d.name
                    .to_ascii_lowercase()
                    .contains(super::super::stream::LOOPBACK_NAME),
                "restoring output must never pick the loopback device"
            );
        }
    }

    #[test]
    fn find_output_is_case_insensitive_and_absence_is_none() {
        if let Some(first) = output_devices().into_iter().find(|d| !d.name.is_empty()) {
            let shouty = first.name.to_ascii_uppercase();
            assert_eq!(find_output(&shouty).map(|d| d.id), Some(first.id));
        }
        assert!(find_output("no such audio device anywhere").is_none());
    }
}
