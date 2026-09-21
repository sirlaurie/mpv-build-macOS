#!/usr/bin/env zsh
set -eo pipefail

root=${0:A:h:h}
sandbox=$(mktemp -d "${TMPDIR:-/tmp}/mpv-incremental.XXXXXX")
print -r -- "Test files: $sandbox"
export WORKDIR="$sandbox/work" prefix="$sandbox/install" build_context=test
export with_bundle=0 force_rebuild=0 TEST_LOG="$sandbox/build.log"
export TEST_REVISIONS="$sandbox/revisions" TEST_FAIL='' TEST_GIT_FAIL=''
export TEST_SUBMODULE_DIFF='' TEST_NO_OUTPUT=''
mkdir -p "$WORKDIR/utils" "$TEST_REVISIONS" "$prefix"
cp "$root/utils/incremental-build.zsh" "$WORKDIR/utils/"
cp "$root/build.env" "$WORKDIR/build.env"
cp "$root/utils/pkg-import" "$WORKDIR/utils/pkg-import"
rg '^build_component ' "$root/build" > "$sandbox/components"

# Use the production graph to create isolated source and output declarations.
build_component() {
  local name=$1 repositories=$2 outputs=$4 repo
  for repo in ${=repositories}; do
    mkdir -p "$WORKDIR/src/$repo"
    print -r -- initial > "$TEST_REVISIONS/$repo"
  done
  print -r -- "$outputs" > "$WORKDIR/outputs-$name"
}
source "$sandbox/components"
cat > "$sandbox/stub" <<'STUB'
#!/usr/bin/env zsh
set -eo pipefail
name=${0:t}; name=${name#build-}
install_prefix=${1#--prefix=}
step=$name
[[ "$name" == freetype && "$2" == -Dharfbuzz=disabled ]] && step=freetype-disabled
print -r -- "$step" >> "$TEST_LOG"
[[ "$name" != "$TEST_FAIL" ]] || exit 42
[[ "$name" != "$TEST_NO_OUTPUT" ]] || exit 0
[[ "$name" == freetype || "$name" == harfbuzz ]] && name=fonts
for output in ${=$(cat "$WORKDIR/outputs-$name")}; do
  mkdir -p "$install_prefix/${output:h}"
  touch "$install_prefix/$output"
done
STUB
for name in vulkan moltenvk libplacebo dav1d freetype harfbuzz libass ffmpeg mpv; do
  cp "$sandbox/stub" "$WORKDIR/build-$name"
  chmod +x "$WORKDIR/build-$name"
done
cat > "$sandbox/run" <<'RUN'
#!/usr/bin/env zsh
set -eo pipefail
state_dir="$prefix/.mpv-build-state"
mkdir -p "$state_dir"
git() {
  [[ -z "$TEST_GIT_FAIL" ]] || return 43
  case "$3" in
    rev-parse) cat "$TEST_REVISIONS/${2:t}" ;;
    submodule)
      if [[ "$4" == foreach && "${2:t}" == libplacebo ]]; then
        print -r -- "$TEST_SUBMODULE_DIFF"
      fi
      ;;
    diff|clean) ;;
    *) print -u2 -- "Unexpected git command: $*"; return 44 ;;
  esac
}
source "$WORKDIR/utils/incremental-build.zsh"
source "${0:A:h}/components"
RUN
all='vulkan moltenvk libplacebo dav1d freetype-disabled harfbuzz freetype libass ffmpeg mpv'
run_check() {
  local label=$1 expected=$2 actual
  : > "$TEST_LOG"
  zsh "$sandbox/run" > "$sandbox/last-run.log" 2>&1
  actual=$(tr '\n' ' ' < "$TEST_LOG")
  [[ "${actual% }" == "$expected" ]] || {
    print -u2 -- "FAIL $label: expected [$expected], got [${actual% }]"
    cat "$sandbox/last-run.log"
    exit 1
  }
  print -r -- "PASS $label"
}
run_check initial "$all"
run_check unchanged ''
for repo expected in \
  Vulkan-Loader 'vulkan libplacebo ffmpeg mpv' \
  Vulkan-Headers 'vulkan libplacebo ffmpeg mpv' \
  MoltenVK 'moltenvk mpv' \
  libplacebo 'libplacebo ffmpeg mpv' \
  dav1d 'dav1d ffmpeg mpv' \
  freetype 'freetype-disabled harfbuzz freetype libass ffmpeg mpv' \
  harfbuzz 'freetype-disabled harfbuzz freetype libass ffmpeg mpv' \
  libass 'libass ffmpeg mpv' \
  ffmpeg 'ffmpeg mpv' \
  mpv 'mpv'; do
  print -r -- changed >> "$TEST_REVISIONS/$repo"
  run_check "source $repo" "$expected"
  run_check "settled $repo" ''
done
for change in first second; do
  export TEST_SUBMODULE_DIFF=$change
  run_check "submodule edit $change" 'libplacebo ffmpeg mpv'
  run_check "settled submodule $change" ''
done
print -r -- '# changed build recipe' >> "$WORKDIR/build-dav1d"
run_check recipe 'dav1d ffmpeg mpv'
export build_context=changed
run_check context "$all"
# Moving a test artifact simulates a missing installation without deletion.
mv "$prefix/lib/libdav1d.dylib" "$sandbox/missing-dav1d"
run_check missing-output 'dav1d ffmpeg mpv'
mv "$prefix/bin/ffplay" "$sandbox/missing-ffplay"
run_check missing-ffplay 'ffmpeg mpv'
old_prefix=$prefix
export prefix="$sandbox/other-install"
run_check new-prefix "$all"
export prefix=$old_prefix
run_check original-prefix ''
export with_bundle=1
run_check bundle 'mpv'
export with_bundle=0
run_check unbundle 'mpv'
export force_rebuild=1
run_check rebuild "$all"
export force_rebuild=0
run_check after-rebuild ''

print -r -- retry >> "$TEST_REVISIONS/dav1d"
export TEST_FAIL=dav1d
: > "$TEST_LOG"
# Run the child independently; an if around build_component disables errexit.
set +e
zsh "$sandbox/run" > "$sandbox/last-run.log" 2>&1
result=$?
set -e
[[ $result == 42 && ! -s "$prefix/.mpv-build-state/dav1d" ]]
[[ "$(cat "$TEST_LOG")" == dav1d ]]
export TEST_FAIL=''
run_check retry 'dav1d ffmpeg mpv'
run_check after-retry ''

mv "$prefix/lib/libdav1d.dylib" "$sandbox/unproduced-dav1d"
export TEST_NO_OUTPUT=dav1d
: > "$TEST_LOG"
set +e
zsh "$sandbox/run" > "$sandbox/last-run.log" 2>&1
result=$?
set -e
[[ $result != 0 && ! -s "$prefix/.mpv-build-state/dav1d" ]]
[[ "$(cat "$TEST_LOG")" == dav1d ]]
export TEST_NO_OUTPUT=''
run_check retry-missing-output 'dav1d ffmpeg mpv'

before=$(shasum "$prefix/.mpv-build-state/vulkan")
export TEST_GIT_FAIL=1
: > "$TEST_LOG"
set +e
zsh "$sandbox/run" > "$sandbox/last-run.log" 2>&1
result=$?
set -e
[[ $result != 0 && ! -s "$TEST_LOG" ]]
[[ "$(shasum "$prefix/.mpv-build-state/vulkan")" == "$before" ]]
export TEST_GIT_FAIL=''
print -r -- 'PASS fingerprint input failure'
mv "$WORKDIR/build-vulkan" "$sandbox/missing-recipe"
: > "$TEST_LOG"
set +e
zsh "$sandbox/run" > "$sandbox/last-run.log" 2>&1
result=$?
set -e
[[ $result != 0 && ! -s "$TEST_LOG" ]]
[[ "$(shasum "$prefix/.mpv-build-state/vulkan")" == "$before" ]]
mv "$sandbox/missing-recipe" "$WORKDIR/build-vulkan"
print -r -- 'PASS missing fingerprint file'
print -r -- "All checks passed. Test files retained: $sandbox"
