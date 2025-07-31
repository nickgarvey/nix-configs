{ lib }:
{ pkg, desktopFilePath, execPath }:

# Input validation
assert lib.isDerivation pkg;
assert lib.isString desktopFilePath;
assert lib.isString execPath;

pkg.overrideAttrs (oldAttrs: {
  # Ensure postFixup is callable or an empty string if not previously defined
  postFixup = (oldAttrs.postFixup or "") + ''
    local desktop_file="$out/${desktopFilePath}"

    echo "Attempting patch on .desktop file: $desktop_file"

    # Check if the file exists (or the path exists, even if symlink)
    # Use -e to check for existence, regardless of type (file, symlink)
    if [ -e "$desktop_file" ]; then
      # Ensure the target is a writable file copy in $out, not a symlink to /nix/store
      if [ -h "$desktop_file" ]; then
        cp -f "$(readlink -f "$desktop_file")" "$desktop_file"
      fi

      # Original substitution attempts
      substituteInPlace "$desktop_file" --replace "Exec=${execPath}" "Exec=${execPath} --disable-gpu"
      # This second line likely still doesn't match anything, but leaving it per "minimal change" request.
      substituteInPlace "$desktop_file" --replace "Exec=$out/${execPath}" "Exec=$out/${execPath} --disable-gpu"

      # Check if replacement occurred (simple check: grep for the new pattern)
      if grep -q -F -- "--disable-gpu" "$desktop_file"; then
        echo "  Successfully patched $desktop_file"
      else
        echo "  Warning: Replacement might not have occurred." >&2
      fi

    else
      echo "Warning: Desktop file path not found at expected location: $desktop_file" >&2
    fi
  '';
})