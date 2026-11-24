#!/usr/bin/env bash
# Builds brilliant-hq/pequalnp-proofs' Lean project against Mathlib's prebuilt cache and packs three bundles for IMD's
# outside proof desks: the Lean toolchain the project names, as Lean publishes it (`lean`); the project's packages,
# Mathlib and what it needs, built (`lean-packages`); and the project itself, built (`pequalnp`). Nothing built is left
# out but the git folders: Mathlib uses Lean's module system, whose interpreter reads the IR files beside the .olean
# ones, so a tactic of Mathlib's needs them to run.
#
# A goal item gets each read only at .imd/fetch/<name>/, so nothing relies on Lake at run time: imd-env.sh puts the
# toolchain on PATH and the built libraries on LEAN_PATH, and `lean <file>` elaborates writing nothing. The check file
# is elaborated twice before anything is published: in the built project through Lake, and then from the three bundles
# unpacked in another folder, read only, with the build moved away, so a bundle leaning on this runner's paths fails.
#
#   bash scripts/pequalnp.sh <checkout of pequalnp-proofs> <output folder>
set -euo pipefail

src=$(cd "$1" && pwd)
out=$2
mkdir -p "$out"
work=${RUNNER_TEMP:-$(mktemp -d)}
project_lib=${PROJECT_LIB:-PEqualNP}
max_asset=$((2 * 1024 * 1024 * 1024 - 1))

commit=$(git -C "$src" rev-parse HEAD)
short=${commit:0:12}

# The Lake project: the checkout's root or its lean/ folder.
if [ -f "$src/lakefile.lean" ] || [ -f "$src/lakefile.toml" ]; then root=$src
elif [ -f "$src/lean/lakefile.lean" ] || [ -f "$src/lean/lakefile.toml" ]; then root=$src/lean
else echo "::error::no lakefile at the checkout's root or in lean/"; exit 1; fi

toolchain=$(tr -d '[:space:]' < "$root/lean-toolchain")
case "$toolchain" in
  leanprover/lean4:v[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "::error::lean-toolchain names $toolchain, not a leanprover/lean4 release"; exit 1 ;;
esac
tag=${toolchain#leanprover/lean4:}
version=${tag#v}
lean_asset="lean-$version-linux.tar.zst"
packages_asset="pequalnp-$short-packages-lean-$version-linux-x64.tar.zst"
project_asset="pequalnp-$short-lean-$version-linux-x64.tar.zst"

echo "::group::Lean $version"
curl -fsSL --retry 3 -o "$out/$lean_asset" "https://github.com/leanprover/lean4/releases/download/$tag/$lean_asset"
mkdir -p "$work/toolchain"
tar --zstd -xf "$out/$lean_asset" -C "$work/toolchain"
lean_dir=$(find "$work/toolchain" -mindepth 1 -maxdepth 1 -type d | head -n 1)
lean_top=$(basename "$lean_dir")
plain_path=$PATH
export PATH="$lean_dir/bin:$PATH"
lean --version
echo "::endgroup::"

echo "::group::Mathlib's cache and the project's build"
cd "$root"
lake exe cache get
lake build
mathlib_rev=$(jq -r '.packages[] | select(.name == "mathlib") | .rev' lake-manifest.json)
lean_path=$(lake env printenv LEAN_PATH)
echo "LEAN_PATH from Lake: $lean_path"
echo "built .olean files in the packages: $(find "$root/.lake/packages" -name '*.olean' | wc -l), in the project: $(find "$root/.lake/build" -name '*.olean' | wc -l)"
echo "::endgroup::"

# What the check imports: a Mathlib module the project itself imports, so it exists in this Mathlib, and the project's
# library root (or its first module).
mathlib_import=$(grep -rhoE '^[[:space:]]*(public[[:space:]]+)?(meta[[:space:]]+)?import[[:space:]]+Mathlib(\.[A-Za-z0-9_]+)+' \
  "$root/$project_lib" "$root/$project_lib.lean" 2>/dev/null | awk '{print $NF}' | sort | head -n 1 || true)
[ -n "$mathlib_import" ] || { echo "::error::no file of $project_lib imports a Mathlib module"; exit 1; }
if [ -f "$root/$project_lib.lean" ]; then project_import=$project_lib
else
  first=$(cd "$root" && find "$project_lib" -name '*.lean' | sort | head -n 1 || true)
  [ -n "$first" ] || { echo "::error::no $project_lib module in the project"; exit 1; }
  project_import=$(printf '%s' "${first%.lean}" | tr / .)
fi
echo "the check imports $mathlib_import and $project_import"
write_check() {
  mkdir -p "$1"
  cat > "$1/Check.lean" <<EOF
import $mathlib_import
import $project_import

theorem imd_bundle_check : 2 + 2 = 4 := by decide

#print axioms imd_bundle_check
EOF
}
olean_of() { printf '%s/%s.olean' "$1" "$(printf '%s' "$2" | tr . /)"; }
# Where an import's .olean is, under every LEAN_PATH entry: what to print when a check fails.
where_is() {
  local module=$1 paths=$2 entry
  IFS=: read -r -a dirs <<< "$paths"
  for entry in "${dirs[@]}"; do
    [ -n "$entry" ] || continue
    if [ -f "$(olean_of "$entry" "$module")" ]; then echo "  $module: found under $entry"; return; fi
  done
  echo "  $module: no .olean under any LEAN_PATH entry"
}

echo "::group::Check in the built project"
write_check "$work/in-place"
(cd "$root" && lake env lean "$work/in-place/Check.lean") || {
  echo "::error::the check file does not elaborate in the built project itself"
  where_is "$mathlib_import" "$lean_path"; where_is "$project_import" "$lean_path"
  exit 1
}
echo "::endgroup::"

# LEAN_PATH as an item has it: every entry rewritten under $IMD_FETCH, to the bundle it is in.
rewritten=""
IFS=: read -r -a entries <<< "$lean_path"
for entry in "${entries[@]}"; do
  [ -n "$entry" ] || continue
  case "$entry" in
    "$root"/.lake/packages/*) mapped="\$IMD_FETCH/lean-packages/${entry#"$root"/.lake/packages/}" ;;
    "$root"/*) mapped="\$IMD_FETCH/pequalnp/${entry#"$root"/}" ;;
    "$lean_dir"/*) mapped="\$IMD_FETCH/lean/$lean_top/${entry#"$lean_dir"/}" ;;
    *) echo "::error::LEAN_PATH names $entry, outside the project and the toolchain"; exit 1 ;;
  esac
  rewritten=${rewritten:+$rewritten:}$mapped
done

cat > "$root/imd-env.sh" <<EOF
# Sourced before any Lean command in an IMD goal item. IMD_FETCH is the workspace's .imd/fetch folder:
#   export IMD_FETCH="\$PWD/.imd/fetch" && . "\$IMD_FETCH/pequalnp/imd-env.sh" && lean <file>
# Built from brilliant-hq/pequalnp-proofs $commit, Lean $version, Mathlib $mathlib_rev.
: "\${IMD_FETCH:?set IMD_FETCH to the .imd/fetch folder of the workspace first}"
export PATH="\$IMD_FETCH/lean/$lean_top/bin:\$PATH"
export LEAN_PATH="$rewritten"
EOF
# Items may source it from sh or bash: both must read it before anything is packed.
sh -n "$root/imd-env.sh"
bash -n "$root/imd-env.sh"

echo "::group::Pack"
find "$root/.lake" -name .git -prune -exec rm -rf {} +
rm -rf "$root/.git"
pack() { tar --sort=name --owner=0 --group=0 --numeric-owner "$@" | zstd -T0 -15 -q -o "$out/$asset"; }
asset=$packages_asset pack -C "$root/.lake/packages" -cf - .
asset=$project_asset pack -C "$root" --exclude=./.lake/packages -cf - .
for asset in "$lean_asset" "$packages_asset" "$project_asset"; do
  size=$(stat -c %s "$out/$asset")
  echo "$asset: $size bytes"
  if [ "$size" -gt "$max_asset" ]; then echo "::error::$asset is $size bytes, past a release file's 2 GiB"; exit 1; fi
done
echo "::endgroup::"

echo "::group::Check from another folder, read only"
check=$work/check
fetch=$check/.imd/fetch
mkdir -p "$fetch/lean" "$fetch/lean-packages" "$fetch/pequalnp"
tar --zstd -xf "$out/$lean_asset" -C "$fetch/lean"
tar --zstd -xf "$out/$packages_asset" -C "$fetch/lean-packages"
tar --zstd -xf "$out/$project_asset" -C "$fetch/pequalnp"
chmod -R a-w "$fetch"
mv "$root" "$root.moved"
mv "$work/toolchain" "$work/toolchain.moved"
write_check "$check/item"
check_log=$work/check.log
(
  cd "$check/item"
  export PATH=$plain_path
  export IMD_FETCH="$fetch"
  . "$IMD_FETCH/pequalnp/imd-env.sh"
  /usr/bin/time -v lean Check.lean
) > "$check_log" 2>&1 || {
  cat "$check_log"
  echo "::error::the bundles did not elaborate from another folder"
  where_is "$mathlib_import" "$(IMD_FETCH=$fetch; eval "printf '%s' \"$rewritten\"")"
  exit 1
}
cat "$check_log"
grep -q "imd_bundle_check" "$check_log" || { echo "::error::lean printed no axioms line"; exit 1; }
peak_kb=$(sed -n 's/.*Maximum resident set size (kbytes): //p' "$check_log")
peak_kb=${peak_kb:-0}
seconds=$(sed -n 's/.*Elapsed (wall clock) time (h:mm:ss or m:ss): //p' "$check_log")
seconds=${seconds:-unmeasured}
echo "::endgroup::"

release=pequalnp-$short
base="https://github.com/${GITHUB_REPOSITORY:-Identity-md/lean-bundles}/releases/download/$release"
entry() {
  local name=$1 file=$2
  jq -n --arg name "$name" --arg url "$base/$file" --arg sha "$(sha256sum "$out/$file" | cut -d' ' -f1)" \
    --argjson bytes "$(stat -c %s "$out/$file")" --arg content "$(zstd -dc "$out/$file" | sha256sum | cut -d' ' -f1)" \
    '{name: $name, url: $url, sha256: $sha, bytes: $bytes, unpack: "tar.zst", contentSha256: $content}'
}
{ entry lean "$lean_asset"; entry lean-packages "$packages_asset"; entry pequalnp "$project_asset"; } | jq -s . > "$out/fetch.json"

cat > "$out/setup.txt" <<'EOF'
Lean, Mathlib with the packages it needs, and the project are prebuilt and read only at .imd/fetch/lean, .imd/fetch/lean-packages and .imd/fetch/pequalnp. Each command is a fresh shell, so run every Lean command from the workspace root as one line: export IMD_FETCH="$PWD/.imd/fetch" && . "$IMD_FETCH/pequalnp/imd-env.sh" && lean <file>. Write your file in your own workspace, never inside .imd/fetch. Never run lake build, lake update or lake exe cache: everything is read only and already built. A file that elaborates with no error and no sorry warning is accepted by Lean.
EOF

{
  echo "release=$release"
  echo "commit=$commit"
  echo "lean=$version"
  echo "mathlib=$mathlib_rev"
  echo "lean_asset=$lean_asset"
  echo "packages_asset=$packages_asset"
  echo "project_asset=$project_asset"
} >> "${GITHUB_OUTPUT:-/dev/null}"

row() { printf '| `%s` | %s | `%s` |\n' "$1" "$(stat -c %s "$out/$1")" "$(sha256sum "$out/$1" | cut -d' ' -f1)"; }
{
  echo "Prebuilt Lean files for IMD's outside proof desk on [pequalnp.com](https://pequalnp.com), built by this repository's workflow on GitHub's runner."
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Project | [brilliant-hq/pequalnp-proofs@$short](https://github.com/brilliant-hq/pequalnp-proofs/tree/$commit) |"
  echo "| Lean | $version (\`$lean_asset\`, as Lean publishes it) |"
  echo "| Mathlib | \`$mathlib_rev\`, from its prebuilt cache |"
  echo "| Check | \`import $mathlib_import\` and \`import $project_import\` elaborated from another folder, read only, in $seconds, peak $((peak_kb / 1024)) MB |"
  echo
  echo "| File | Bytes | sha256 |"
  echo "|---|---|---|"
  row "$lean_asset"; row "$packages_asset"; row "$project_asset"
  echo
  echo "\`fetch.json\` is the three files as a desk's \`fetch\`; \`setup.txt\` is how an item runs Lean with them. Lean, Mathlib and pequalnp-proofs are each Apache-2.0; their licence files are inside the archives."
} > "$out/notes.md"
cat "$out/notes.md"
