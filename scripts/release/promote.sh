#!/bin/zsh
# Promotes a tested loom-dev release into the clean loom tree (plans/STAGE-L.md).
# Usage: scripts/release/promote.sh <version> <loom-tree-path>
#
# Source is the loom-dev tag release/<version>, exported with `git archive`
# (never the working tree). Only the allowlist below is exported; a release-only
# Package.swift, build.sh (from build-loom.sh), README.md (from README.release.md,
# with @VERSION@ filled in), LICENSE, VERSION and .gitignore are generated. The loom tree gets one commit
# "Loom <version> (from loom-dev release/<version> <short-sha>)" and the tag
# v<version>. Nothing is ever written into loom-dev.
#
# Refuses: missing release tag; a loom path equal to, inside or containing the
# loom-dev checkout, or inside another git repository; a non-empty directory
# that is not already a git repository; uncommitted changes in the loom tree;
# an existing tag v<version>. All validation and staging happen before the loom
# tree is touched; if the commit step fails, the tree is rolled back.
set -euo pipefail

dev=${0:A:h:h:h}
here=${0:A:h}
(( $# == 2 )) || { sed -n '2,/^set -euo/p' "$0" | sed '$d' >&2; exit 2; }
version=$1
loom=${2:A}
tag="release/$version"
version_re='^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'
[[ $version =~ $version_re ]] || { echo "Not a version number: '$version' (expected e.g. 0.1.0)" >&2; exit 2; }

fail() { echo "promote: $*" >&2; exit 1; }

# --- Allowlist: the only paths exported from the loom-dev tag (shared with scripts/check.sh). ---
source "$here/allowlist.sh"
allow=($release_allow)
allowed_top=($release_allowed_top)

# --- Validation (nothing written yet) ----------------------------------------
git -C "$dev" rev-parse --git-dir >/dev/null 2>&1 || fail "$dev is not a git checkout"
commit=$(git -C "$dev" rev-parse -q --verify "refs/tags/$tag^{commit}") || fail "loom-dev tag '$tag' does not exist"
short=$(git -C "$dev" rev-parse --short "$commit")

if [[ $loom == $dev || $loom == $dev/* ]]; then fail "loom path '$loom' is inside the loom-dev checkout"; fi
if [[ $dev == $loom/* ]]; then fail "loom path '$loom' contains the loom-dev checkout"; fi
[[ $loom != / && $loom != ${HOME:A} ]] || fail "refusing loom path '$loom'"

# Nearest existing ancestor must not be a work tree of another repository
# unless the loom path itself is the repository root.
probe=$loom
while [[ ! -d $probe ]]; do probe=${probe:h}; done
if [[ -d $loom/.git ]]; then
  [[ $(git -C "$loom" rev-parse --show-toplevel) == $loom ]] || fail "'$loom/.git' is not a repository root"
else
  if top=$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null); then fail "'$loom' would nest inside the git repository $top"; fi
  if [[ -d $loom && -n $(ls -A "$loom") ]]; then fail "'$loom' is not empty and not a git repository; refusing to replace unknown content"; fi
fi
if [[ -d $loom/.git ]]; then
  [[ -z $(git -C "$loom" status --porcelain) ]] || fail "the loom tree has uncommitted changes; commit or discard them first"
  if git -C "$loom" rev-parse -q --verify "refs/tags/v$version" >/dev/null; then fail "version $version already exists in the loom tree (tag v$version)"; fi
fi

# --- Stage: export from the tag, add generated files, check everything -------
stage=$(mktemp -d "${TMPDIR:-/tmp}/loom-promote.XXXXXX")
trap 'rm -rf "$stage"' EXIT
git -C "$dev" archive --format=tar "$tag" -- $allow $release_exclude | tar -x -C "$stage"

# Release manifest: drift guard against the tagged dev manifest.
git -C "$dev" show "${tag}:Package.swift" > "$stage/dev-Package.swift"
# Templates come from the tag too, so a release is reproducible from its tag alone.
templates=$(mktemp -d)
git -C "$dev" show "${tag}:scripts/release/Package.release.swift" > "$templates/Package.release.swift" 2>/dev/null \
  || fail "tag '$tag' has no scripts/release/Package.release.swift; commit the release scripts before tagging"
git -C "$dev" show "${tag}:scripts/release/build-loom.sh" > "$templates/build-loom.sh" 2>/dev/null \
  || fail "tag '$tag' has no scripts/release/build-loom.sh; commit the release scripts before tagging"
for template in README.release.md LICENSE; do
  git -C "$dev" show "${tag}:scripts/release/$template" > "$templates/$template" 2>/dev/null \
    || fail "tag '$tag' has no scripts/release/$template; commit the release scripts before tagging"
done
if ! python3 - "$stage/dev-Package.swift" "$templates/Package.release.swift" <<'PY'
import re, sys
def norm(path):
    text = re.sub(r"//[^\n]*", "", open(path).read())
    return re.sub(r"\s+", "", text)
def split_top(body):
    parts, depth, cur = [], 0, ""
    for c in body:
        if c in "([": depth += 1
        if c in ")]": depth -= 1
        if c == "," and depth == 0:
            parts.append(cur); cur = ""
        else:
            cur += c
    if cur: parts.append(cur)
    return parts
def targets(text):
    i = text.rindex(",targets:[") + len(",targets:[")
    depth, j = 1, i
    while depth:
        j += 1
        depth += {"[": 1, "]": -1}.get(text[j], 0)
    return set(split_top(text[i:j]))
dev, rel = norm(sys.argv[1]), norm(sys.argv[2])
errors = []
# The dev manifest builds loom-app with the evidence flavor; the release flavor has no such define. The one
# dev-only setting is stripped before the comparison, so any other build-setting drift still fails.
dev_only = ',swiftSettings:[.define("LOOM_EVIDENCE")]'
if dev_only not in dev: errors.append("the loom-dev manifest no longer defines LOOM_EVIDENCE on loom-app; update the drift normalizer")
dev = dev.replace(dev_only, "")
if "LOOM_EVIDENCE" in rel: errors.append("the release manifest must not define LOOM_EVIDENCE")
tools = lambda path: open(path).readline().strip()
if tools(sys.argv[1]) != tools(sys.argv[2]): errors.append("swift-tools-version differs")
for needle in ['platforms:[.macOS("27.0")]', '.package(path:"Vendor/SwiftTerm")']:
    if needle not in dev or needle not in rel: errors.append("missing in a manifest: " + needle)
missing = targets(rel) - targets(dev)
for m in sorted(missing): errors.append("release target declaration not found in the loom-dev manifest: " + m[:80])
for p in re.findall(r'\.executable\(name:"([^"]+)",targets:\["([^"]+)"\]\)', rel):
    if f'.executable(name:"{p[0]}",targets:["{p[1]}"])' not in dev: errors.append("product differs: " + p[0])
if errors:
    print("\n".join(errors)); sys.exit(1)
PY
then fail "scripts/release/Package.release.swift drifted from the loom-dev Package.swift at $tag; update the template"; fi
rm "$stage/dev-Package.swift"
cp "$templates/Package.release.swift" "$stage/Package.swift"
cp "$templates/build-loom.sh" "$stage/build.sh"
cp "$templates/LICENSE" "$stage/LICENSE"
sed "s/@VERSION@/$version/g" "$templates/README.release.md" > "$stage/README.md"
rm -rf "$templates"
chmod +x "$stage/build.sh"
print -r -- "$version" > "$stage/VERSION"
printf '.build/\n.swiftpm/\n.DS_Store\n' > "$stage/.gitignore"
# The README shows pictures from assets/readme; each one it names must be in the release.
! grep -q '@[A-Z]*@' "$stage/README.md" || fail "README.release.md has a placeholder promote does not fill"
for picture in ${(f)"$(grep -o 'assets/readme/[A-Za-z0-9._-]*' "$stage/README.md" | sort -u)"}; do
  [[ -f $stage/$picture ]] || fail "README.release.md shows $picture, which the release does not contain"
done

# Every staged path must be allowed: top-level entries and nothing dev-only.
bad=()
for entry in $stage/*(N) $stage/.[!.]*(N); do
  name=${entry:t}
  (( ${allowed_top[(Ie)$name]} )) || bad+=("$name")
done
unexpected=$(cd "$stage" && find . -type f \( -path '*/Tests/*' -o -path '*/plans/*' -o -path '*/design/*' -o -path '*/docs/*' \
  -o -name 'loom-probe*' -o -name 'loom-test-child*' -o -name 'loom-fake-provider*' -o -name 'loom-catalog-fixture*' \
  -o -name 'CLoomTestSupport*' -o -name 'LOOM-VENDOR.md' -o -path '*/Documentation.docc/*' -o -name '*.patch' \
  -o -path '*/loom-app/Evidence/*' -o -name 'DevelopmentEvidence*' -o -name 'EvidenceResourcePool*' \) || true)
[[ ! -e $stage/Sources/loom-app/Evidence ]] || fail "staged tree contains Sources/loom-app/Evidence (development-only evidence tooling)"
(( ${#bad} == 0 )) || fail "staged tree has unexpected top-level entries: ${bad[*]}"
[[ -z $unexpected ]] || fail "staged tree has dev-only files: $unexpected"
files=$(cd "$stage" && find . -type f | wc -l | tr -d ' ')

# --- Replace the loom tree ---------------------------------------------------
mkdir -p "$loom"
if [[ ! -d $loom/.git ]]; then git -C "$loom" init -q -b main; fi
rollback() {
  echo "promote: failed; restoring the loom tree" >&2
  if git -C "$loom" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$loom" reset -q --hard HEAD
    git -C "$loom" clean -qfdx
  else
    find "$loom" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  fi
}
trap 'rollback; rm -rf "$stage"' ERR
find "$loom" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
(cd "$stage" && tar -cf - .) | tar -xf - -C "$loom"
git -C "$loom" add -A
git -C "$loom" commit -q -m "Loom $version (from loom-dev $tag $short)"
git -C "$loom" tag -a "v$version" -m "Loom $version (from loom-dev $tag $short)"
trap 'rm -rf "$stage"' ERR

echo "Promoted Loom $version (loom-dev $tag $short) into $loom"
echo "Exported files: $files; loom commit $(git -C "$loom" rev-parse --short HEAD), tag v$version"
