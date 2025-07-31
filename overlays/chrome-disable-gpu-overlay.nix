
# /etc/nixos/chrome-disable-gpu-overlay.nix
#
# This Nix expression defines an overlay function to modify Google Chrome.
# It accepts 'self' (the final package set) and 'super' (the previous package set).

self: super: {

  # Replace 'google-chrome-stable' if you use a different package name
  # (e.g., 'google-chrome'). Verify the exact package name you installed.
  google-chrome = super.google-chrome.overrideAttrs (oldAttrs: {

    # Use postFixup to modify the .desktop file after it's installed to $out
    postFixup = (oldAttrs.postFixup or "") + ''
      # Define the target desktop file path relative to the package output ($out)
      local desktop_file="$out/share/applications/google-chrome.desktop"

      # Check if the file exists before trying to patch it
      if [ -f "$desktop_file" ]; then
        echo "Patching Chrome .desktop file to add --disable-gpu: $desktop_file"

        # Attempt to replace the Exec line.
        # Prioritize the version ending with %U, common for browser launchers.
        substituteInPlace "$desktop_file" \
          --replace "Exec=$out/bin/google-chrome-stable" "Exec=$out/bin/google-chrome-stable --disable-gpu"

      else
          echo "Warning: Google Chrome desktop file not found at expected location: $desktop_file" >&2
      fi
    '';
  });
}

