# Sourced by build after source updates and build environment discovery.
build_component() {
  local name="$1" repositories="$2" dependencies="$3" outputs="$4"
  local stamp="$state_dir/$name" repo dependency output fingerprint generation
  local -a scripts=("$WORKDIR/build-$name")
  if [[ "$name" == fonts ]]; then
    scripts=("$WORKDIR/build-freetype" "$WORKDIR/build-harfbuzz")
  fi

  fingerprint=$(
    {
      print -r -- "$build_context" "$prefix" "$name" "$repositories" "$dependencies" "$outputs"
      shasum -a 256 "${scripts[@]}" "$WORKDIR/build.env" "$WORKDIR/utils/pkg-import" \
        "$WORKDIR/utils/incremental-build.zsh"
      for repo in ${=repositories}; do
        git -C "$WORKDIR/src/$repo" rev-parse HEAD
        git -C "$WORKDIR/src/$repo" diff --binary HEAD
        git -C "$WORKDIR/src/$repo" submodule status --recursive
        git -C "$WORKDIR/src/$repo" submodule foreach --recursive 'git diff --binary HEAD'
      done
      for dependency in ${=dependencies}; do
        cat "$state_dir/$dependency"
      done
      if [[ "$name" == mpv ]]; then
        print -r -- "$with_bundle"
      fi
    } | shasum -a 256
  )

  local missing=0
  for output in ${=outputs}; do
    [[ -e "$prefix/$output" ]] || missing=1
  done
  if [[ "$name" == mpv && "$with_bundle" == 1 && ! -d /Applications/mpv.app ]]; then
    missing=1
  fi
  if [[ "$force_rebuild" == 0 && "$missing" == 0 && -s "$stamp" &&
        "$(head -n 1 "$stamp")" == "$fingerprint" ]]; then
    print -r -- "Skipping $name (unchanged)"
    return
  fi

  print -r -- "Building $name"
  # Invalidate before installation: a failed build may have replaced some files.
  : > "$stamp"
  for repo in ${=repositories}; do
    git -C "$WORKDIR/src/$repo" clean -fdx
  done
  case "$name" in
    fonts)
      "$WORKDIR/build-freetype" --prefix="$prefix" -Dharfbuzz=disabled
      "$WORKDIR/build-harfbuzz" "$prefix"
      "$WORKDIR/build-freetype" --prefix="$prefix"
      ;;
    mpv) "$WORKDIR/build-mpv" "$prefix" "$with_bundle" ;;
    *) "$WORKDIR/build-$name" "$prefix" ;;
  esac
  for output in ${=outputs}; do
    if [[ ! -e "$prefix/$output" ]]; then
      print -u2 -r -- "Error: $name did not install $prefix/$output"
      return 1
    fi
  done
  # A new generation also invalidates downstream builds after repairs or retries.
  generation=$(uuidgen)
  print -rl -- "$fingerprint" "$generation" > "$stamp.tmp"
  mv "$stamp.tmp" "$stamp"
}
