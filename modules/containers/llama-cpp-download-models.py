#!/usr/bin/env python3
"""
Model downloader for llama-cpp deployment.
Downloads GGUF models from HuggingFace and organizes them for llama-cpp router mode discovery.
"""

import json
import os
import shutil
import sys
import time
import threading
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.error import HTTPError, URLError

MODELS_DIR = Path("/models")
HF_API_BASE = "https://huggingface.co/api/models"
HF_DOWNLOAD_BASE = "https://huggingface.co"

# Only attempt hard linking for files larger than 1GB
HARD_LINK_MIN_SIZE = 1024 * 1024 * 1024  # 1GB

# Progress tracking for downloads
download_progress = {}
progress_lock = threading.Lock()

# File index for hard link deduplication (populated on startup)
file_size_index: dict[int, list[Path]] = {}


def log(msg: str):
    print(msg, flush=True)


def build_file_index() -> dict[int, list[Path]]:
    """Build index of existing GGUF files by size for hard link deduplication."""
    log("Building file index for hard link deduplication...")
    index: dict[int, list[Path]] = {}
    count = 0

    for gguf_file in MODELS_DIR.rglob("*.gguf"):
        try:
            # Skip symlinks - only index real files
            if gguf_file.is_symlink():
                continue

            size = gguf_file.stat().st_size
            # Only index files larger than threshold
            if size >= HARD_LINK_MIN_SIZE:
                if size not in index:
                    index[size] = []
                index[size].append(gguf_file)
                count += 1
        except OSError:
            pass  # Skip files we can't stat

    log(f"Indexed {count} GGUF files >= 1GB for potential hard linking")
    return index


def try_hard_link(dest: Path, expected_size: int) -> bool:
    """Try to create a hard link from an existing file with matching size and name.

    Returns True if hard link was created, False otherwise.
    """
    if expected_size < HARD_LINK_MIN_SIZE:
        return False

    candidates = file_size_index.get(expected_size, [])
    for candidate in candidates:
        # Skip if in the same directory (would be self-reference)
        if candidate.parent == dest.parent:
            continue

        # Only link if filename matches exactly (safety check)
        if candidate.name != dest.name:
            continue

        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            os.link(candidate, dest)
            log(f"  Hard linked from existing: {candidate}")
            return True
        except OSError as e:
            log(f"  Warning: Hard link failed ({e}), will download instead")
            return False

    return False


def get_hf_files(repo: str, subdir: str = None) -> list[dict]:
    """Fetch file listing from HuggingFace API."""
    if subdir:
        url = f"{HF_API_BASE}/{repo}/tree/main/{subdir}"
    else:
        url = f"{HF_API_BASE}/{repo}/tree/main"

    try:
        with urlopen(url, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except (HTTPError, URLError) as e:
        log(f"  Warning: Failed to fetch {url}: {e}")
        return []


def find_gguf_files(repo: str, filter_pattern: str) -> list[dict]:
    """Find GGUF files matching the filter pattern."""
    # First try to find files in a subdirectory matching the filter
    files = get_hf_files(repo, filter_pattern)
    gguf_files = [f for f in files if f.get("path", "").lower().endswith(".gguf")]

    if gguf_files:
        return gguf_files

    # Fall back to root directory with filter
    files = get_hf_files(repo)
    gguf_files = []
    for f in files:
        path = f.get("path", "")
        if path.lower().endswith(".gguf") and filter_pattern.lower() in path.lower():
            gguf_files.append(f)

    return gguf_files


def get_model_dir_name(gguf_files: list[dict]) -> str:
    """Extract the model directory name from GGUF filenames.

    For split models like 'Q3_K_S/Qwen3-VL-235B-A22B-Instruct-1M-Q3_K_S-00001-of-00003.gguf',
    returns 'Qwen3-VL-235B-A22B-Instruct-1M-Q3_K_S'.

    For single models like 'Qwen3-VL-30B-A3B-Thinking-Q5_K_M.gguf',
    returns 'Qwen3-VL-30B-A3B-Thinking-Q5_K_M'.
    """
    if not gguf_files:
        return None

    first_file = gguf_files[0].get("path", "")
    filename = Path(first_file).name  # Get just the filename without path

    # Remove .gguf extension
    name = filename.replace(".gguf", "")

    # If it's a split model (contains -00001-of-), extract the base name
    if "-00001-of-" in name:
        name = name.split("-00001-of-")[0]

    return name


def progress_reporter():
    """Background thread to report download progress every 30 seconds."""
    while True:
        time.sleep(30)
        with progress_lock:
            for filename, info in download_progress.items():
                if info.get("active"):
                    downloaded = info.get("downloaded", 0)
                    total = info.get("total", 0)
                    if total > 0:
                        pct = (downloaded / total) * 100
                        downloaded_gb = downloaded / (1024**3)
                        total_gb = total / (1024**3)
                        log(f"  [Progress] {filename}: {downloaded_gb:.2f}/{total_gb:.2f} GB ({pct:.1f}%)")


def download_file(url: str, dest: Path, expected_size: int = None) -> bool:
    """Download a file with progress tracking."""
    filename = dest.name

    # Check if file already exists with correct size
    if dest.exists():
        actual_size = dest.stat().st_size
        if expected_size and actual_size == expected_size:
            log(f"  {filename} exists with correct size ({actual_size:,} bytes), skipping")
            return True
        else:
            log(f"  {filename} exists but size mismatch (got {actual_size:,}, expected {expected_size:,}), re-downloading")

    # Try hard linking from existing file before downloading
    if try_hard_link(dest, expected_size):
        # Add newly hard-linked file to index for future use
        if expected_size >= HARD_LINK_MIN_SIZE:
            if expected_size not in file_size_index:
                file_size_index[expected_size] = []
            file_size_index[expected_size].append(dest)
        return True

    log(f"  Downloading {filename} ({expected_size:,} bytes)...")

    # Initialize progress tracking
    with progress_lock:
        download_progress[filename] = {"active": True, "downloaded": 0, "total": expected_size or 0}

    try:
        req = Request(url, headers={"User-Agent": "llama-cpp-downloader"})
        with urlopen(req, timeout=60) as resp:
            dest.parent.mkdir(parents=True, exist_ok=True)

            with open(dest, "wb") as f:
                downloaded = 0
                chunk_size = 1024 * 1024  # 1MB chunks

                while True:
                    chunk = resp.read(chunk_size)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)

                    with progress_lock:
                        download_progress[filename]["downloaded"] = downloaded

        # Verify download size
        actual_size = dest.stat().st_size
        if expected_size and actual_size != expected_size:
            log(f"  WARNING: Downloaded size ({actual_size:,}) doesn't match expected ({expected_size:,})")
        else:
            log(f"  Downloaded {filename} successfully")

        # Add successfully downloaded file to index for future hard linking
        if expected_size and expected_size >= HARD_LINK_MIN_SIZE:
            if expected_size not in file_size_index:
                file_size_index[expected_size] = []
            file_size_index[expected_size].append(dest)

        return True

    except Exception as e:
        log(f"  ERROR downloading {filename}: {e}")
        return False
    finally:
        with progress_lock:
            download_progress[filename]["active"] = False


def download_model(config: dict) -> Path | None:
    """Download a single model based on its configuration.

    Returns the model directory on success, None on failure.
    """
    name = config.get("name")
    repo = config.get("repo")
    filter_pattern = config.get("filter", "")
    mmproj_file = config.get("mmproj", "")

    log("=" * 60)
    log(f"Processing model: {name}")
    log(f"  Repo: {repo}")
    log(f"  Filter: {filter_pattern}")
    log("=" * 60)

    # Find GGUF files
    log(f"Fetching file list from HuggingFace...")
    gguf_files = find_gguf_files(repo, filter_pattern)

    if not gguf_files:
        log(f"ERROR: No GGUF files found matching filter '{filter_pattern}' in {repo}")
        return None

    # Determine model directory name from GGUF files
    model_dir_name = get_model_dir_name(gguf_files)
    if not model_dir_name:
        log(f"ERROR: Could not determine model directory name")
        return None

    model_dir = MODELS_DIR / model_dir_name
    log(f"Model directory: {model_dir}")

    model_dir.mkdir(parents=True, exist_ok=True)

    log(f"Found {len(gguf_files)} GGUF file(s):")
    for f in gguf_files:
        log(f"  - {f['path']} ({f.get('size', 'unknown'):,} bytes)")

    # Download each GGUF file (download_file handles size verification
    # and skips files that already exist with the correct size)
    for f in gguf_files:
        filepath = f.get("path", "")
        filesize = f.get("size", 0)
        filename = Path(filepath).name  # Just the filename, flatten directory structure

        download_url = f"{HF_DOWNLOAD_BASE}/{repo}/resolve/main/{filepath}"
        dest_path = model_dir / filename

        if not download_file(download_url, dest_path, filesize):
            return None

    # Write .model_path file
    model_files = sorted([f for f in model_dir.glob("*.gguf") if not f.name.lower().startswith("mmproj")])
    if model_files:
        first_gguf = model_files[0]
        model_path_file = model_dir / ".model_path"
        model_path_file.write_text(str(first_gguf))
        log(f"Model path: {first_gguf}")

    # Download mmproj file for vision support
    if mmproj_file and mmproj_file != "null":
        log(f"Downloading mmproj file for vision support...")

        # Get mmproj file info from API
        files = get_hf_files(repo)
        mmproj_info = next((f for f in files if f.get("path") == mmproj_file), None)

        if mmproj_info:
            mmproj_size = mmproj_info.get("size", 0)
            download_url = f"{HF_DOWNLOAD_BASE}/{repo}/resolve/main/{mmproj_file}"
            dest_path = model_dir / mmproj_file

            if download_file(download_url, dest_path, mmproj_size):
                mmproj_path_file = model_dir / ".mmproj_path"
                mmproj_path_file.write_text(str(dest_path))
                log(f"Mmproj path: {dest_path}")
        else:
            log(f"WARNING: mmproj file {mmproj_file} not found in repository")

    log(f"Model {model_dir_name} ready")
    log("")
    return model_dir


def cleanup_stale(kept_dirs: set[Path]) -> None:
    """Remove subdirectories of MODELS_DIR not in kept_dirs.

    Multiple guards prevent this from escaping /models:
      - empty kept_dirs is treated as a misconfiguration, not as "delete all"
      - MODELS_DIR must not be a symlink and must equal its resolved path
      - entries that are symlinks are never followed or removed
      - each entry's resolved path must be a direct child of MODELS_DIR
    """
    if not kept_dirs:
        log("Skipping cleanup: no models in current config (refusing to wipe /models)")
        return

    if MODELS_DIR.is_symlink() or MODELS_DIR.resolve() != MODELS_DIR:
        log(f"REFUSING cleanup: {MODELS_DIR} is a symlink or non-canonical")
        return

    models_root = MODELS_DIR.resolve()
    removed = []
    for entry in MODELS_DIR.iterdir():
        if entry.is_symlink():
            continue
        if not entry.is_dir():
            continue
        resolved = entry.resolve()
        if resolved.parent != models_root:
            log(f"REFUSING to remove {entry}: resolves to {resolved}, outside {models_root}")
            continue
        if resolved in kept_dirs:
            continue
        log(f"Removing stale model directory: {entry}")
        shutil.rmtree(entry)
        removed.append(entry.name)
    if removed:
        log(f"Removed {len(removed)} stale model dir(s): {', '.join(removed)}")


def main():
    global file_size_index

    # Build file index for hard link deduplication
    file_size_index = build_file_index()

    # Start progress reporter thread
    reporter = threading.Thread(target=progress_reporter, daemon=True)
    reporter.start()

    # Parse models configuration
    models_config_str = os.environ.get("MODELS_CONFIG", "[]")
    try:
        models_config = json.loads(models_config_str)
    except json.JSONDecodeError as e:
        log(f"ERROR: Failed to parse MODELS_CONFIG: {e}")
        sys.exit(1)

    log(f"Found {len(models_config)} model(s) to process")
    log("")

    # Track model processing results
    model_results = []
    kept_dirs: set[Path] = set()

    # Process each model
    for config in models_config:
        model_dir = download_model(config)
        if model_dir is None:
            log(f"ERROR: Failed to download model {config.get('name')}")
            sys.exit(1)
        kept_dirs.add(model_dir.resolve())
        model_results.append({
            "name": config.get("name"),
            "repo": config.get("repo"),
            "filter": config.get("filter")
        })

    cleanup_stale(kept_dirs)

    # Print summary
    log("=" * 60)
    log("SUMMARY - All models processed successfully")
    log("=" * 60)
    log("")
    log("Models checked and ready:")
    for i, result in enumerate(model_results, 1):
        log(f"  {i}. {result['name']}")
        log(f"     Repo: {result['repo']}")
        log(f"     Filter: {result['filter']}")
    log("")
    log(f"Total models: {len(model_results)}")
    log("=" * 60)


if __name__ == "__main__":
    main()
