// C-ABI entry points take raw pointers from Swift by design.
#![allow(clippy::not_unsafe_ptr_arg_deref)]


pub mod actions;
pub mod shelf;

use shelf::ShelfManager;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::Path;
use std::sync::Mutex;

const MAX_ITEMS: usize = 500;

static SHELF: Mutex<Option<ShelfManager>> = Mutex::new(None);

fn with_shelf<F, R>(f: F) -> R
where
    F: FnOnce(&mut ShelfManager) -> R,
{
    let mut guard = SHELF.lock().unwrap_or_else(|e| e.into_inner());
    let shelf = guard.get_or_insert_with(|| ShelfManager::new(MAX_ITEMS));
    f(shelf)
}

fn read_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

fn to_c_string(s: String) -> *mut c_char {
    CString::new(s)
        .map(|c| c.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

fn to_c_json<T: serde::Serialize>(value: &T) -> *mut c_char {
    serde_json::to_string(value)
        .map(to_c_string)
        .unwrap_or(std::ptr::null_mut())
}

fn parse_paths(ptr: *const c_char) -> Option<Vec<String>> {
    serde_json::from_str(read_str(ptr)?).ok()
}

/// Initializes the shelf, persisting to `storage_dir` (may be null for an
/// in-memory shelf). Safe to call more than once; later calls are ignored.
#[no_mangle]
pub extern "C" fn cove_init(storage_dir: *const c_char) {
    let mut guard = SHELF.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_none() {
        *guard = Some(match read_str(storage_dir) {
            Some(dir) => ShelfManager::with_storage(MAX_ITEMS, Path::new(dir)),
            None => ShelfManager::new(MAX_ITEMS),
        });
    }
}

/// Stages a JSON array of paths as one stack. Returns the staged items as JSON.
#[no_mangle]
pub extern "C" fn cove_stage_files(paths_json: *const c_char) -> *mut c_char {
    let Some(paths) = parse_paths(paths_json) else {
        return std::ptr::null_mut();
    };
    match with_shelf(|shelf| shelf.stage_files(&paths)) {
        Ok(items) => to_c_json(&items),
        Err(err) => {
            eprintln!("[NotchCove Core] Error staging files: {}", err);
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn cove_get_staged_files() -> *mut c_char {
    with_shelf(|shelf| to_c_json(&shelf.get_items()))
}

#[no_mangle]
pub extern "C" fn cove_remove_item(c_id: *const c_char, delete_owned: bool) -> bool {
    match read_str(c_id) {
        Some(id) => with_shelf(|shelf| shelf.remove_item(id, delete_owned)),
        None => false,
    }
}

#[no_mangle]
pub extern "C" fn cove_remove_group(c_group_id: *const c_char) -> bool {
    match read_str(c_group_id) {
        Some(id) => with_shelf(|shelf| shelf.remove_group(id)),
        None => false,
    }
}

#[no_mangle]
pub extern "C" fn cove_ungroup(c_group_id: *const c_char) -> bool {
    match read_str(c_group_id) {
        Some(id) => with_shelf(|shelf| shelf.ungroup(id)),
        None => false,
    }
}

#[no_mangle]
pub extern "C" fn cove_clear_all() {
    with_shelf(|shelf| shelf.clear_all());
}

/// Removes items whose files no longer exist. Returns how many were removed.
#[no_mangle]
pub extern "C" fn cove_prune_missing() -> u32 {
    with_shelf(|shelf| shelf.prune_missing() as u32)
}

/// Removes items older than `max_age_secs`. Returns how many were removed.
#[no_mangle]
pub extern "C" fn cove_expire_older_than(max_age_secs: u64) -> u32 {
    with_shelf(|shelf| shelf.expire_older_than(max_age_secs, shelf::now_secs()) as u32)
}

/// Unix time when the next item expires under `max_age_secs`, or 0 if the shelf is empty.
#[no_mangle]
pub extern "C" fn cove_next_expiry(max_age_secs: u64) -> u64 {
    with_shelf(|shelf| shelf.next_expiry(max_age_secs).unwrap_or(0))
}

/// Directory where NotchCove stores files it creates (snippets, archives…).
#[no_mangle]
pub extern "C" fn cove_inbox_dir() -> *mut c_char {
    match with_shelf(|shelf| shelf.inbox_dir()) {
        Some(dir) => to_c_string(dir.to_string_lossy().to_string()),
        None => std::ptr::null_mut(),
    }
}

/// Zips a JSON array of paths into `out_dir`. Blocking; call off the main
/// thread. Returns the archive path, or null on failure.
#[no_mangle]
pub extern "C" fn cove_zip(paths_json: *const c_char, out_dir: *const c_char) -> *mut c_char {
    let (Some(paths), Some(out)) = (parse_paths(paths_json), read_str(out_dir)) else {
        return std::ptr::null_mut();
    };
    match actions::zip_paths(&paths, Path::new(out)) {
        Ok(path) => to_c_string(path.to_string_lossy().to_string()),
        Err(err) => {
            eprintln!("[NotchCove Core] Zip failed: {}", err);
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn cove_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            drop(CString::from_raw(ptr));
        }
    }
}
