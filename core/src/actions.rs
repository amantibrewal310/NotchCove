use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Finder-style naming (`<name>.zip` or `Archive.zip`); `ditto` keeps resource forks and xattrs.
pub fn zip_paths(paths: &[String], out_dir: &Path) -> Result<PathBuf, String> {
    let sources: Vec<&Path> = paths.iter().map(Path::new).filter(|p| p.exists()).collect();
    if sources.is_empty() {
        return Err("Nothing to compress".to_string());
    }
    fs::create_dir_all(out_dir).map_err(|e| e.to_string())?;

    let base_name = if sources.len() == 1 {
        sources[0]
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| "Archive".to_string())
    } else {
        "Archive".to_string()
    };
    let dest = unique_path(out_dir, &base_name, "zip");

    if sources.len() == 1 {
        // --keepParent keeps a folder as the archive's top level, but for a
        // plain file it would also embed the file's parent folder.
        run_ditto(sources[0], &dest, sources[0].is_dir())?;
    } else {
        // ditto takes a single source, so gather items into a folder of
        // APFS clones (cheap, no extra disk use) and archive its contents.
        let staging = out_dir.join(format!(".zip-staging-{}", std::process::id()));
        let _ = fs::remove_dir_all(&staging);
        fs::create_dir_all(&staging).map_err(|e| e.to_string())?;
        let result = (|| {
            for src in &sources {
                let name = src.file_name().ok_or("Invalid file name")?;
                let status = Command::new("/bin/cp")
                    .arg("-cR")
                    .arg(src)
                    .arg(staging.join(name))
                    .status()
                    .map_err(|e| e.to_string())?;
                if !status.success() {
                    return Err(format!("Failed to copy {}", src.display()));
                }
            }
            run_ditto(&staging, &dest, false)
        })();
        let _ = fs::remove_dir_all(&staging);
        result?;
    }
    Ok(dest)
}

fn run_ditto(src: &Path, dest: &Path, keep_parent: bool) -> Result<(), String> {
    let mut cmd = Command::new("/usr/bin/ditto");
    cmd.args(["-c", "-k", "--sequesterRsrc"]);
    if keep_parent {
        cmd.arg("--keepParent");
    }
    let output = cmd.arg(src).arg(dest).output().map_err(|e| e.to_string())?;
    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

/// Returns `dir/name.ext`, or `dir/name 2.ext`, `dir/name 3.ext`… if taken.
pub fn unique_path(dir: &Path, name: &str, ext: &str) -> PathBuf {
    let candidate = dir.join(format!("{}.{}", name, ext));
    if !candidate.exists() {
        return candidate;
    }
    (2..)
        .map(|n| dir.join(format!("{} {}.{}", name, n, ext)))
        .find(|p| !p.exists())
        .unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zips_single_and_multiple() {
        let dir = std::env::temp_dir().join(format!("cove-zip-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let a = dir.join("a.txt");
        let b = dir.join("b.txt");
        fs::write(&a, "a").unwrap();
        fs::write(&b, "b").unwrap();
        let out = dir.join("out");

        let single = zip_paths(&[a.to_string_lossy().to_string()], &out).unwrap();
        assert_eq!(single.file_name().unwrap(), "a.txt.zip");
        assert_eq!(zip_entries(&single), vec!["a.txt"]);

        let folder = dir.join("Folder");
        fs::create_dir_all(&folder).unwrap();
        fs::write(folder.join("inner.txt"), "i").unwrap();
        let folder_zip = zip_paths(&[folder.to_string_lossy().to_string()], &out).unwrap();
        assert_eq!(zip_entries(&folder_zip), vec!["Folder/", "Folder/inner.txt"]);

        let paths = vec![a.to_string_lossy().to_string(), b.to_string_lossy().to_string()];
        let multi = zip_paths(&paths, &out).unwrap();
        assert_eq!(multi.file_name().unwrap(), "Archive.zip");
        let multi2 = zip_paths(&paths, &out).unwrap();
        assert_eq!(multi2.file_name().unwrap(), "Archive 2.zip");

        assert_eq!(zip_entries(&multi), vec!["a.txt", "b.txt"]);
        let _ = fs::remove_dir_all(&dir);
    }

    /// Archive entry names, ignoring macOS metadata.
    fn zip_entries(zip: &Path) -> Vec<String> {
        let out = Command::new("/usr/bin/zipinfo").arg("-1").arg(zip).output().unwrap();
        let mut names: Vec<String> = String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter(|l| !l.starts_with("__MACOSX"))
            .map(str::to_string)
            .collect();
        names.sort();
        names
    }
}
