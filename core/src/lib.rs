pub mod shelf;

use shelf::ShelfManager;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::Mutex;

static SHELF: Mutex<Option<ShelfManager>> = Mutex::new(None);

fn with_shelf<F, R>(f: F) -> R
where
    F: FnOnce(&mut ShelfManager) -> R,
{
    let mut guard = SHELF.lock().unwrap();
    if guard.is_none() {
        *guard = Some(ShelfManager::new(20));
    }
    f(guard.as_mut().unwrap())
}

#[no_mangle]
pub extern "C" fn cove_init() {
    let mut guard = SHELF.lock().unwrap();
    if guard.is_none() {
        *guard = Some(ShelfManager::new(20));
    }
}

#[no_mangle]
pub extern "C" fn cove_stage_file(c_path: *const c_char) -> *mut c_char {
    if c_path.is_null() {
        return std::ptr::null_mut();
    }

    let path_str = match unsafe { CStr::from_ptr(c_path) }.to_str() {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };

    let result = with_shelf(|shelf| shelf.stage_file(path_str));

    match result {
        Ok(item) => match serde_json::to_string(&item) {
            Ok(json) => CString::new(json).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut()),
            Err(_) => std::ptr::null_mut(),
        },
        Err(err_msg) => {
            eprintln!("[NotchCove Core] Error staging file: {}", err_msg);
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn cove_get_staged_files() -> *mut c_char {
    let items = with_shelf(|shelf| shelf.get_items().to_vec());
    match serde_json::to_string(&items) {
        Ok(json) => CString::new(json).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut()),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn cove_remove_item(c_id: *const c_char) -> bool {
    if c_id.is_null() {
        return false;
    }

    let id_str = match unsafe { CStr::from_ptr(c_id) }.to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    with_shelf(|shelf| shelf.remove_item(id_str))
}

#[no_mangle]
pub extern "C" fn cove_clear_all() {
    with_shelf(|shelf| shelf.clear_all());
}

#[no_mangle]
pub extern "C" fn cove_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}
