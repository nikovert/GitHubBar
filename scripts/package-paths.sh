#!/bin/zsh

# Shared preflight only: never create or remove paths here.
githubbar_validate_package_paths() {
  local repository="${1:A}" build="$2" distribution="$3" version="$4" number="$5"
  if [[ "$build" != /* || "$distribution" != /* ]]; then
    print -u2 "Packaging build and distribution directories must be absolute paths."
    return 1
  fi

  # Resolve symlinks and .. before checking the cleanup boundary.
  build="${build:A}"
  distribution="${distribution:A}"
  if [[ "$build" != "$repository/.build/"* ]]; then
    print -u2 "GITHUBBAR_BUILD_DIR must be a dedicated directory beneath $repository/.build."
    return 1
  fi
  if [[ "$distribution" != "$repository/dist" && "$distribution" != "$repository/dist/"* ]]; then
    print -u2 "GITHUBBAR_DIST_DIR must be $repository/dist or a directory beneath it."
    return 1
  fi
  if [[ -e "$build" && ! -d "$build" ]] || [[ -e "$distribution" && ! -d "$distribution" ]]; then
    print -u2 "Packaging output paths must be directories."
    return 1
  fi
  if [[ ! "$version" =~ '^[A-Za-z0-9][A-Za-z0-9.+_-]*$' || ! "$number" =~ '^[0-9]+$' ]]; then
    print -u2 "Version must be a filename-safe identifier; build number must contain digits only."
    return 1
  fi
  return 0
}
