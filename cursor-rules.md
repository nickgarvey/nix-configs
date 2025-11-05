# Repository Rules for AI Agents

- You are allowed to change files, but never commit anything
- Use `nix flake update --option access-tokens "github.com=$(gh auth token)"` to update flake.lock. You can run this whenever you want.
- /home/ngarvey/projects/nixpkgs contains the nixpkg source code for your reference. You should pull origin/master if the most recent commit is more than 1d out of date.