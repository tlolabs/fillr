use crate::{Engine, MediaPolicy, SortSettings, owned_ffprobe_path};
use serde_json::json;
use std::cell::RefCell;
use std::ffi::{CStr, CString, c_char};
use std::panic::AssertUnwindSafe;
use std::ptr;

thread_local! {
    static LAST_ERROR: RefCell<String> = const { RefCell::new(String::new()) };
}

fn set_error(error: impl ToString) {
    LAST_ERROR.with(|last| *last.borrow_mut() = error.to_string());
}

fn as_c_string(value: String) -> *mut c_char {
    CString::new(value)
        .unwrap_or_else(|_| CString::new("Invalid string").unwrap())
        .into_raw()
}

unsafe fn incoming(value: *const c_char) -> Result<String, String> {
    if value.is_null() {
        return Err("Missing string argument".into());
    }
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .map(str::to_owned)
        .map_err(|e| e.to_string())
}

#[unsafe(no_mangle)]
pub extern "C" fn fillr_api_version() -> u32 {
    1
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fillr_create(
    folder: *const c_char,
    ffprobe: *const c_char,
) -> *mut Engine {
    let result = std::panic::catch_unwind(|| {
        let folder = unsafe { incoming(folder) }?;
        let ffprobe = unsafe { incoming(ffprobe) }?;
        Engine::new(folder, ffprobe).map_err(|e| e.to_string())
    });
    match result {
        Ok(Ok(engine)) => Box::into_raw(Box::new(engine)),
        Ok(Err(error)) => {
            set_error(error);
            ptr::null_mut()
        }
        Err(_) => {
            set_error("Engine initialization failed");
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fillr_create_configured(
    folder: *const c_char,
    ffprobe: *const c_char,
    policy_json: *const c_char,
) -> *mut Engine {
    let result = std::panic::catch_unwind(|| {
        let folder = unsafe { incoming(folder) }?;
        let ffprobe = unsafe { incoming(ffprobe) }?;
        let policy_json = unsafe { incoming(policy_json) }?;
        let policy: MediaPolicy = serde_json::from_str(&policy_json).map_err(|e| e.to_string())?;
        Engine::new_with_policy(folder, ffprobe, policy).map_err(|e| e.to_string())
    });
    match result {
        Ok(Ok(engine)) => Box::into_raw(Box::new(engine)),
        Ok(Err(error)) => {
            set_error(error);
            ptr::null_mut()
        }
        Err(_) => {
            set_error("Engine initialization failed");
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fillr_create_configured_owned(
    folder: *const c_char,
    policy_json: *const c_char,
) -> *mut Engine {
    let result = std::panic::catch_unwind(|| {
        let folder = unsafe { incoming(folder) }?;
        let policy_json = unsafe { incoming(policy_json) }?;
        let policy: MediaPolicy = serde_json::from_str(&policy_json).map_err(|e| e.to_string())?;
        let ffprobe = owned_ffprobe_path()?;
        Engine::new_with_policy(folder, ffprobe, policy).map_err(|e| e.to_string())
    });
    match result {
        Ok(Ok(engine)) => Box::into_raw(Box::new(engine)),
        Ok(Err(error)) => {
            set_error(error);
            ptr::null_mut()
        }
        Err(_) => {
            set_error("Engine initialization failed");
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fillr_create_with_settings_owned(
    folder: *const c_char,
    policy_json: *const c_char,
    settings_json: *const c_char,
) -> *mut Engine {
    let result = std::panic::catch_unwind(|| {
        let folder = unsafe { incoming(folder) }?;
        let policy: MediaPolicy =
            serde_json::from_str(&unsafe { incoming(policy_json) }?).map_err(|e| e.to_string())?;
        let settings: SortSettings = serde_json::from_str(&unsafe { incoming(settings_json) }?)
            .map_err(|e| e.to_string())?;
        let ffprobe = owned_ffprobe_path()?;
        Engine::new_with_settings(folder, ffprobe, policy, settings).map_err(|e| e.to_string())
    });
    match result {
        Ok(Ok(engine)) => Box::into_raw(Box::new(engine)),
        Ok(Err(error)) => {
            set_error(error);
            ptr::null_mut()
        }
        Err(_) => {
            set_error("Engine initialization failed");
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fillr_set_sort_settings(
    engine: *mut Engine,
    settings_json: *const c_char,
) -> u8 {
    if engine.is_null() {
        set_error("Engine is not open");
        return 0;
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let value = unsafe { incoming(settings_json) }?;
        let settings: SortSettings = serde_json::from_str(&value).map_err(|e| e.to_string())?;
        unsafe { &*engine }
            .set_settings(settings)
            .map_err(|e| e.to_string())
    }));
    match result {
        Ok(Ok(())) => 1,
        Ok(Err(error)) => {
            set_error(error);
            0
        }
        Err(_) => {
            set_error("Unable to update sort settings");
            0
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fillr_set_media_policy(
    engine: *mut Engine,
    policy_json: *const c_char,
) -> u8 {
    if engine.is_null() {
        set_error("Engine is not open");
        return 0;
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let value = unsafe { incoming(policy_json) }?;
        let policy: MediaPolicy = serde_json::from_str(&value).map_err(|e| e.to_string())?;
        unsafe { &*engine }
            .set_policy(policy)
            .map_err(|e| e.to_string())
    }));
    match result {
        Ok(Ok(())) => 1,
        Ok(Err(error)) => {
            set_error(error);
            0
        }
        Err(_) => {
            set_error("Unable to update media preferences");
            0
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fillr_snapshot(engine: *mut Engine) -> *mut c_char {
    if engine.is_null() {
        set_error("Engine is not open");
        return ptr::null_mut();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        serde_json::to_string(&unsafe { &*engine }.snapshot())
    }));
    match result {
        Ok(Ok(snapshot)) => as_c_string(snapshot),
        _ => {
            set_error("Unable to read engine state");
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fillr_build(engine: *mut Engine) -> *mut c_char {
    if engine.is_null() {
        set_error("Engine is not open");
        return ptr::null_mut();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| unsafe { &*engine }.build()));
    let value = match result {
        Ok(Ok(build)) => json!({ "ok": true, "result": build }),
        Ok(Err(error)) => json!({ "ok": false, "error": error.to_string() }),
        Err(_) => json!({ "ok": false, "error": "Build failed unexpectedly" }),
    };
    as_c_string(value.to_string())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fillr_refresh(engine: *mut Engine) {
    if !engine.is_null() {
        unsafe { &*engine }.refresh();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn fillr_last_error() -> *mut c_char {
    LAST_ERROR.with(|last| as_c_string(last.borrow().clone()))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fillr_free_string(value: *mut c_char) {
    if !value.is_null() {
        let _ = unsafe { CString::from_raw(value) };
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fillr_destroy(engine: *mut Engine) {
    if !engine.is_null() {
        let _ = unsafe { Box::from_raw(engine) };
    }
}
