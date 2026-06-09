//! Extraction module for converting Solidity source to TRAP.
//!
//! This module handles:
//! - Parallel file processing
//! - Tree-sitter parsing
//! - AST traversal and TRAP generation
//! - Source archive management

mod constfold;
mod extractor;

use anyhow::{Context, Result};
use rayon::prelude::*;
use std::fs::{self, File};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use tracing::{error, info, warn};
use walkdir::WalkDir;

use crate::trap::Compression;

pub use extractor::Extractor;

/// Options for the extract command.
pub struct ExtractOptions {
    /// File containing list of source files to extract
    pub file_list: PathBuf,
    /// Output directory for TRAP files
    pub trap_dir: PathBuf,
    /// Output directory for source archive
    pub source_archive_dir: PathBuf,
    /// Compression mode
    pub compression: Compression,
    /// Number of threads (None = use all available)
    pub threads: Option<usize>,
}

/// Options for the autobuild command.
pub struct AutobuildOptions {
    /// Root directory to search
    pub root: PathBuf,
    /// Output directory for TRAP files
    pub trap_dir: PathBuf,
    /// Output directory for source archive
    pub source_archive_dir: PathBuf,
}

/// Run extraction on a list of files.
pub fn run(options: ExtractOptions) -> Result<()> {
    // Configure thread pool if specified
    if let Some(threads) = options.threads {
        rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .build_global()
            .context("Failed to configure thread pool")?;
    }

    // Ensure output directories exist
    fs::create_dir_all(&options.trap_dir).context("Failed to create TRAP directory")?;
    fs::create_dir_all(&options.source_archive_dir)
        .context("Failed to create source archive directory")?;

    // Read file list
    let file_list = File::open(&options.file_list)
        .with_context(|| format!("Failed to open file list: {}", options.file_list.display()))?;
    let reader = BufReader::new(file_list);
    let files: Vec<PathBuf> = reader
        .lines()
        .map_while(Result::ok)
        .filter(|line| !line.trim().is_empty())
        .map(PathBuf::from)
        .collect();

    let total = files.len();
    info!("Processing {} files", total);

    // Periodic progress reporting. `done` is bumped once per finished file
    // across all rayon worker threads; we log roughly every 5% (and on the last
    // file) so a long run shows steady progress instead of going silent.
    let done = AtomicUsize::new(0);
    let progress_step = (total / 20).max(1);

    // Process files in parallel
    let results: Vec<Result<(), String>> = files
        .par_iter()
        .map(|file| {
            let result = process_file(
                file.as_path(),
                options.trap_dir.as_path(),
                options.source_archive_dir.as_path(),
                options.compression,
            )
            .map_err(|e| format!("{}: {}", file.display(), e));

            let n = done.fetch_add(1, Ordering::Relaxed) + 1;
            if n % progress_step == 0 || n == total {
                info!("Progress: {}/{} files ({}%)", n, total, n * 100 / total);
            }

            result
        })
        .collect();

    // Report errors
    let mut success_count = 0;
    let mut error_count = 0;
    for result in results {
        match result {
            Ok(()) => success_count += 1,
            Err(e) => {
                error!("{}", e);
                error_count += 1;
            }
        }
    }

    info!(
        "Extraction complete: {} succeeded, {} failed",
        success_count, error_count
    );

    if error_count > 0 && error_count == files.len() {
        anyhow::bail!("All {} files failed to extract", error_count);
    } else if error_count > 0 && error_count > files.len() / 2 {
        anyhow::bail!(
            "Too many extraction failures: {}/{} files failed",
            error_count,
            files.len()
        );
    } else if error_count > 0 {
        warn!(
            "{} files failed to extract (continuing with {} successful)",
            error_count, success_count
        );
    }

    Ok(())
}

/// Run autobuild: find all .sol files and extract them.
pub fn autobuild(options: AutobuildOptions) -> Result<()> {
    // Find all .sol files
    let files: Vec<PathBuf> = WalkDir::new(&options.root)
        .follow_links(true)
        .into_iter()
        .filter_map(|entry| entry.ok())
        .filter(|entry| {
            entry.file_type().is_file() && entry.path().extension().is_some_and(|ext| ext == "sol")
        })
        .filter(|entry| {
            // Skip node_modules and other common excluded directories
            let path = entry.path();
            !path.components().any(|c| {
                matches!(
                    c.as_os_str().to_str(),
                    Some("node_modules" | ".git" | "cache")
                )
            })
        })
        .map(|entry| entry.into_path())
        .collect();

    if files.is_empty() {
        warn!("No Solidity files found in {}", options.root.display());
        return Ok(());
    }

    info!("Found {} Solidity files", files.len());

    // Create temporary file list
    let file_list = options.trap_dir.join("file_list.txt");
    fs::write(
        &file_list,
        files
            .iter()
            .map(|p| p.to_string_lossy().to_string())
            .collect::<Vec<_>>()
            .join("\n"),
    )?;

    // Run extraction
    run(ExtractOptions {
        file_list,
        trap_dir: options.trap_dir,
        source_archive_dir: options.source_archive_dir,
        compression: Compression::from_env(),
        threads: None,
    })
}

/// Process a single file.
fn process_file(
    file: &Path,
    trap_dir: &Path,
    source_archive_dir: &Path,
    compression: Compression,
) -> Result<()> {
    // Read source file
    let source = fs::read_to_string(file)
        .with_context(|| format!("Failed to read file: {}", file.display()))?;

    // Get canonical path
    let canonical = file.canonicalize().unwrap_or_else(|_| file.to_path_buf());
    let file_str = canonical.to_string_lossy();

    // Create extractor and process
    let mut extractor = Extractor::new(&file_str);
    extractor.extract(&source)?;

    // Compute output paths
    let trap_path = compute_trap_path(trap_dir, canonical.as_path(), compression);
    let archive_path = compute_archive_path(source_archive_dir, canonical.as_path());

    // Ensure parent directories exist
    if let Some(parent) = trap_path.parent() {
        fs::create_dir_all(parent)?;
    }
    if let Some(parent) = archive_path.parent() {
        fs::create_dir_all(parent)?;
    }

    // Write TRAP file
    extractor.write_trap(&trap_path, compression)?;

    // Copy to source archive
    fs::copy(file, &archive_path)
        .with_context(|| format!("Failed to copy to archive: {}", archive_path.display()))?;

    Ok(())
}

/// Compute the TRAP file output path.
fn compute_trap_path(trap_dir: &Path, source_file: &Path, compression: Compression) -> PathBuf {
    // Use a hash-based path to avoid path length issues
    let file_str = source_file.to_string_lossy();
    let hash = {
        use sha2::{Digest, Sha256};
        let mut hasher = Sha256::new();
        hasher.update(file_str.as_bytes());
        let result = hasher.finalize();
        format!(
            "{:x}",
            &result[..8]
                .iter()
                .fold(0u64, |acc, &b| (acc << 8) | b as u64)
        )
    };

    // Use first 2 chars as subdirectory for distribution
    let subdir = &hash[..2];
    let filename = format!("{}{}", hash, compression.extension());

    trap_dir.join(subdir).join(filename)
}

/// Compute the source archive output path.
fn compute_archive_path(archive_dir: &Path, source_file: &Path) -> PathBuf {
    // Preserve the original path structure in the archive
    let path_str = source_file
        .to_string_lossy()
        .trim_start_matches('/')
        .to_string();
    archive_dir.join(path_str)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compute_trap_path() {
        let trap_dir = PathBuf::from("/tmp/trap");
        let source = PathBuf::from("/home/user/contracts/Token.sol");
        let path = compute_trap_path(&trap_dir, &source, Compression::Gzip);

        assert!(path.to_string_lossy().ends_with(".trap.gz"));
        assert!(path.starts_with("/tmp/trap"));
    }

    #[test]
    fn test_compute_archive_path() {
        let archive_dir = PathBuf::from("/tmp/archive");
        let source = PathBuf::from("/home/user/contracts/Token.sol");
        let path = compute_archive_path(&archive_dir, &source);

        assert_eq!(
            path,
            PathBuf::from("/tmp/archive/home/user/contracts/Token.sol")
        );
    }
}
