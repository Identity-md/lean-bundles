#!/usr/bin/env bash
# Builds brilliant-hq/pequalnp-proofs' Lean project against Mathlib's prebuilt cache and packs two bundles for IMD's
# outside proof desks: the Lean toolchain the project names, as Lean publishes it, and the project with every .olean
# built. A goal item gets each read only at .imd/fetch/<name>/, so nothing here relies on Lake at run time: imd-env.sh
# puts the toolchain on PATH and the built libraries on LEAN_PATH, and `lean <file>` elaborates writing nothing.
# Before publishing, both are unpacked in another folder, made read only, and a file importing Mathlib and the project
# is elaborated there with the build folder moved away, so a bundle that leans on this runner's paths fails here.
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
echo "::endgroup::"

# LEAN_PATH as an item has it: every entry under the project or the toolchain, rewritten under $IMD_FETCH.
rewritten=""
IFS=: read -r -a entries <<< "$lean_path"
for entry in "${entries[@]}"; do
  [ -n "$entry" ] || continue
  case "$entry" in
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
# Git folders and the C the compiler emits are not needed to elaborate; everything else stays, licences included.
find "$root/.lake" -name .git -prune -exec rm -rf {} +
find "$root/.lake" -type d -path '*/.lake/build/ir' -prune -exec rm -rf {} +
rm -rf "$root/.git"
tar --sort=name --owner=0 --group=0 --numeric-owner -C "$root" -cf - . | zstd -T0 -15 -q -o "$out/$project_asset"
for asset in "$lean_asset" "$project_asset"; do
  size=$(stat -c %s "$out/$asset")
  echo "$asset: $size bytes"
  if [ "$size" -gt "$max_asset" ]; then echo "::error::$asset is $size bytes, past a release file's 2 GiB"; exit 1; fi
done
echo "::endgroup::"

echo "::group::Check from another folder, read only"
check=$work/check
fetch=$check/.imd/fetch
mkdir -p "$fetch/lean" "$fetch/pequalnp" "$check/item"
tar --zstd -xf "$out/$lean_asset" -C "$fetch/lean"
tar --zstd -xf "$out/$project_asset" -C "$fetch/pequalnp"
chmod -R a-w "$fetch"
mv "$root" "$root.moved"
mv "$work/toolchain" "$work/toolchain.moved"
if [ -f "$fetch/pequalnp/$project_lib.lean" ]; then project_import=$project_lib
else
  first=$(cd "$fetch/pequalnp" && find "$project_lib" -name '*.lean' | sort | head -n 1)
  [ -n "$first" ] || { echo "::error::no $project_lib module in the bundle"; exit 1; }
  project_import=$(printf '%s' "${first%.lean}" | tr / .)
fi
cat > "$check/item/Check.lean" <<EOF
import Mathlib.Logic.Basic
import $project_import

theorem imd_bundle_check : 2 + 2 = 4 := by decide

#print axioms imd_bundle_check
EOF
check_log=$work/check.log
(
  cd "$check/item"
  export PATH=$plain_path
  export IMD_FETCH="$fetch"
  . "$IMD_FETCH/pequalnp/imd-env.sh"
  /usr/bin/time -v lean Check.lean
) > "$check_log" 2>&1 || { cat "$check_log"; echo "::error::the bundle did not elaborate from another folder"; exit 1; }
cat "$check_log"
grep -q "imd_bundle_check" "$check_log" || { echo "::error::lean printed no axioms line"; exit 1; }
peak_kb=$(sed -n 's/.*Maximum resident set size (kbytes): //p' "$check_log")
peak_kb=${peak_kb:-0}
seconds=$(sed -n 's/.*Elapsed (wall clock) time (h:mm:ss or m:ss): //p' "$check_log")
seconds=${seconds:-unmeasured}
echo "::endgroup::"

content_sha() { zstd -dc "$1" | sha256sum | cut -d' ' -f1; }
lean_sha=$(sha256sum "$out/$lean_asset" | cut -d' ' -f1)
project_sha=$(sha256sum "$out/$project_asset" | cut -d' ' -f1)
lean_bytes=$(stat -c %s "$out/$lean_asset")
project_bytes=$(stat -c %s "$out/$project_asset")
lean_content=$(content_sha "$out/$lean_asset")
project_content=$(content_sha "$out/$project_asset")

release=pequalnp-$short
base="https://github.com/${GITHUB_REPOSITORY:-Identity-md/lean-bundles}/releases/download/$release"
jq -n \
  --arg lu "$base/$lean_asset" --arg ls "$lean_sha" --argjson lb "$lean_bytes" --arg lc "$lean_content" \
  --arg pu "$base/$project_asset" --arg ps "$project_sha" --argjson pb "$project_bytes" --arg pc "$project_content" \
  '[{name: "lean", url: $lu, sha256: $ls, bytes: $lb, unpack: "tar.zst", contentSha256: $lc},
    {name: "pequalnp", url: $pu, sha256: $ps, bytes: $pb, unpack: "tar.zst", contentSha256: $pc}]' > "$out/fetch.json"

cat > "$out/setup.txt" <<'EOF'
Lean and the project, with Mathlib built, are prebuilt and read only at .imd/fetch/lean and .imd/fetch/pequalnp. Each command is a fresh shell, so run every Lean command from the workspace root as one line: export IMD_FETCH="$PWD/.imd/fetch" && . "$IMD_FETCH/pequalnp/imd-env.sh" && lean <file>. Write your file in your own workspace, never inside .imd/fetch. Never run lake build, lake update or lake exe cache: the project is read only and already built. A file that elaborates with no error and no sorry warning is accepted by Lean.
EOF

{
  echo "release=$release"
  echo "commit=$commit"
  echo "lean=$version"
  echo "mathlib=$mathlib_rev"
  echo "lean_asset=$lean_asset"
  echo "project_asset=$project_asset"
  echo "peak_kb=$peak_kb"
  echo "seconds=$seconds"
} >> "${GITHUB_OUTPUT:-/dev/null}"

cat > "$out/notes.md" <<EOF
Prebuilt Lean files for IMD's outside proof desk on [pequalnp.com](https://pequalnp.com), built by this repository's workflow on GitHub's runner.

| | |
|---|---|
| Project | [brilliant-hq/pequalnp-proofs@$short](https://github.com/brilliant-hq/pequalnp-proofs/tree/$commit) |
| Lean | $version (\`$lean_asset\`, as Lean publishes it) |
| Mathlib | \`$mathlib_rev\`, from its prebuilt cache |
| Check | elaborated \`import Mathlib.Logic.Basic\` and \`import $project_import\` from another folder, read only, in $seconds, peak $((peak_kb / 1024)) MB |

| File | Bytes | sha256 |
|---|---|---|
| \`$lean_asset\` | $lean_bytes | \`$lean_sha\` |
| \`$project_asset\` | $project_bytes | \`$project_sha\` |

\`fetch.json\` is the two files as a desk's \`fetch\`; \`setup.txt\` is how an item runs Lean with them. Lean, Mathlib and pequalnp-proofs are each Apache-2.0; their licence files are inside the archives.
EOF
cat "$out/notes.md"
