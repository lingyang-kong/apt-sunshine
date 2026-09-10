#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

REPO_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_ROOT="$(mktemp --directory)"
trap 'rm --recursive --force -- "$TEST_ROOT"' EXIT
export WORK_DIR="$TEST_ROOT/work" OUT_DIR="$TEST_ROOT/out" CACHE_DIR="$TEST_ROOT/cache"
# shellcheck source=/dev/null
source "$REPO_DIR/scripts/sync-apt-repo.sh"
mkdir --parents "$WORK_DIR" "$TEST_ROOT/package/DEBIAN"

assert_equal() {
	if [[ $1 != "$2" ]]; then
		fail "$3: expected $1, got $2"
	fi
}

make_package() {
	local name=$1 arch=$2 version=$3 path=$4
	printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: Test <test@example.invalid>\nDescription: test fixture\n' \
		"$name" "$version" "$arch" >"$TEST_ROOT/package/DEBIAN/control"
	dpkg-deb --build --root-owner-group "$TEST_ROOT/package" "$path" >/dev/null
}

make_release() {
	local path=$1 name=$2 id=$3
	jq --null-input --compact-output \
		--arg url "file://$path" --arg name "$name" --argjson id "$id" \
		--argjson size "$(stat --format='%s' "$path")" \
		--arg digest "sha256:$(sha256sum "$path" | awk '{print $1}')" \
		'{id: $id, tag_name: "v2026.1", published_at: "2026-01-01T00:00:00Z",
		  html_url: "https://example.invalid/release", tarball_url: "https://example.invalid/source.tar.gz",
		  zipball_url: "https://example.invalid/source.zip", draft: false, prerelease: false,
		  assets: [{id: $id, name: $name, size: $size, digest: $digest,
		            browser_download_url: $url, updated_at: "2026-01-01T00:00:00Z"}]}'
}

while IFS='|' read -r name suite; do
	assert_equal "$suite" "$(suite_from_filename "$name")" "suite for $name"
done <<'EOF'
sunshine_2026.906.222525-1+debiantrixie_amd64.deb|debian-trixie
sunshine_2026.1-1+ubuntu26.04_arm64.deb|ubuntu-26.04
sunshine-ubuntu-22.04-amd64.deb|ubuntu-22.04
sunshine-debian-bookworm-arm64.deb|debian-bookworm
sunshine-ubuntu_22_04.deb|ubuntu-22.04
sunshine-22.04.deb|ubuntu-22.04
sunshine20.04.deb|ubuntu-20.04
sunshine-2004.deb|ubuntu-20.04
sunshine-debian.deb|debian-legacy
sunshine.deb|generic-legacy
EOF

AMD="$TEST_ROOT/amd64.deb"
ARM="$TEST_ROOT/arm64.deb"
make_package sunshine amd64 '2026.1-1' "$AMD"
make_package sunshine arm64 '2026.2-1' "$ARM"
RELEASE="$(make_release "$AMD" sunshine-ubuntu-22.04-amd64.deb 1)"
ARM_RELEASE="$(make_release "$ARM" sunshine_2026.2-1+debiantrixie_arm64.deb 2)"
MANIFEST="$TEST_ROOT/manifest.ndjson"
SELECTED="$TEST_ROOT/selected.ndjson"
DOWNLOADS="$TEST_ROOT/downloads"
: >"$DOWNLOADS"
curl() {
	printf 'download\n' >>"$DOWNLOADS"
	command curl "$@"
}

prepare_release_packages "$RELEASE" "$MANIFEST"
CACHED="$(jq --raw-output '.package_path' "$MANIFEST")"
FIRST_KEY="$(jq --raw-output '.cache_key' "$MANIFEST")"
cmp -- "$AMD" "$CACHED"
assert_equal '2026.1-1' "$(jq --raw-output '.version' "$MANIFEST")" 'version comes from package control'
prepare_release_packages "$RELEASE" "$MANIFEST"
assert_equal 1 "$(wc --lines <"$DOWNLOADS")" 'cache hit avoids download'

# A digest permits reuse across release IDs, filenames, and URLs.
RENAMED="$(jq '.id = 3 | .assets[0].id = 3 | .assets[0].name = "sunshine-ubuntu-24.04-amd64.deb" |
	.assets[0].browser_download_url = "file:///unavailable" | .assets[0].digest |= ascii_upcase |
	.assets[0].digest |= sub("SHA256:"; "sha256:")' <<<"$RELEASE")"
prepare_release_packages "$RENAMED" "$MANIFEST"
assert_equal 1 "$(wc --lines <"$DOWNLOADS")" 'digest reuse avoids unavailable URL'
assert_equal ubuntu-24.04 "$(jq --raw-output '.suite' "$MANIFEST")" 'reuse updates provenance'
assert_equal "$FIRST_KEY" "$(jq --raw-output '.cache_key' "$MANIFEST")" 'digest key is stable'

printf 'corruption' >>"$CACHED"
prepare_release_packages "$RELEASE" "$MANIFEST"
assert_equal 2 "$(wc --lines <"$DOWNLOADS")" 'corruption redownloads package'
cmp -- "$AMD" "$CACHED"

NO_DIGEST="$(jq 'del(.assets[0].digest)' <<<"$RELEASE")"
prepare_release_packages "$NO_DIGEST" "$MANIFEST"
prepare_release_packages "$NO_DIGEST" "$MANIFEST"
assert_equal 3 "$(wc --lines <"$DOWNLOADS")" 'digest-less cache reuse'
UPDATED="$(jq '.assets[0].updated_at = "2026-02-01T00:00:00Z"' <<<"$NO_DIGEST")"
prepare_release_packages "$UPDATED" "$MANIFEST"
assert_equal 4 "$(wc --lines <"$DOWNLOADS")" 'digest-less update invalidates cache'

expect_rejected() {
	if (prepare_release_packages "$1" "$MANIFEST" >/dev/null 2>&1); then
		fail "$2 unexpectedly accepted"
	fi
}
expect_rejected "$(jq '.assets[0].digest = ("sha256:" + ("0" * 64))' <<<"$RELEASE")" 'wrong digest'
expect_rejected "$(jq '.assets[0].size += 1' <<<"$RELEASE")" 'wrong size'
expect_rejected "$(jq '.assets[0].name = "sunshine-ubuntu-22.04-arm64.deb"' <<<"$RELEASE")" 'wrong architecture on cache hit'
expect_rejected "$(jq '.assets[0].name = "../sunshine.deb"' <<<"$RELEASE")" 'unsafe filename'
expect_rejected "$(jq '.assets[0].name = "sunshine-unknown.deb"' <<<"$RELEASE")" 'unknown filename'
BAD="$TEST_ROOT/wrong.deb"
make_package other amd64 1 "$BAD"
expect_rejected "$(make_release "$BAD" sunshine.deb 9)" 'wrong package name'
printf 'invalid deb\n' >"$BAD"
expect_rejected "$(make_release "$BAD" sunshine.deb 10)" 'invalid package'
prepare_release_packages "$(jq '.assets[0].name = "sunshine.deb"' <<<"$RELEASE")" "$MANIFEST"
assert_equal amd64 "$(jq --raw-output '.arch' "$MANIFEST")" 'legacy architecture comes from control'

# Real multi-suite publication, signing, and whole-release eviction.
prepare_release_packages "$RELEASE" "$MANIFEST"
prepare_release_packages "$ARM_RELEASE" "$TEST_ROOT/arm.ndjson"
cat "$TEST_ROOT/arm.ndjson" >>"$MANIFEST"
printf '%s\n%s\n' "$RELEASE" "$ARM_RELEASE" >"$SELECTED"
publish_manifest_packages "$MANIFEST"
SIGNING_HOME="$TEST_ROOT/signing"
mkdir --mode=700 "$SIGNING_HOME"
# shellcheck disable=SC2218
command gpg --homedir "$SIGNING_HOME" --batch --passphrase '' \
	--quick-generate-key 'Test <test@example.invalid>' ed25519 sign 0 >/dev/null 2>&1
APT_GPG_PRIVATE_KEY="$(command gpg --homedir "$SIGNING_HOME" --batch --armor --export-secret-keys)"
export APT_GPG_PRIVATE_KEY
GPG_CALLS="$TEST_ROOT/gpg-calls"
gpg() {
	printf '%s\n' "$*" >>"$GPG_CALLS"
	command gpg "$@"
}
KEY_ID="$(initialize_repository_signing)"
refresh_repository_metadata "$SELECTED" "$MANIFEST" "$KEY_ID"
for suite in ubuntu-22.04 debian-trixie; do
	gpg --homedir "$WORK_DIR/gnupg" --batch --verify "$OUT_DIR/dists/$suite/InRelease" >/dev/null 2>&1
	gpg --homedir "$WORK_DIR/gnupg" --batch --verify "$OUT_DIR/dists/$suite/Release.gpg" \
		"$OUT_DIR/dists/$suite/Release" >/dev/null 2>&1
done
rg --quiet '^Package: sunshine$' "$OUT_DIR/dists/ubuntu-22.04/main/binary-amd64/Packages"
rg --quiet '^Version: 2026.2-1$' "$OUT_DIR/dists/debian-trixie/main/binary-arm64/Packages"
jq --exit-status '.mirrored_assets | length == 2 and all(.[]; (has("package_path") or has("cache_key")) | not)' \
	"$OUT_DIR/releases.json" >/dev/null
evict_oldest_release "$SELECTED" "$MANIFEST"
refresh_repository_metadata "$SELECTED" "$MANIFEST" "$KEY_ID"
if [[ -e $OUT_DIR/dists/ubuntu-22.04 ]]; then
	fail 'evicted suite metadata remains'
fi
gpg --homedir "$WORK_DIR/gnupg" --batch --verify "$OUT_DIR/dists/debian-trixie/InRelease" >/dev/null 2>&1
assert_equal 1 "$(rg --count -- ' --import$' "$GPG_CALLS")" 'signing key imported once'
assert_equal 1 "$(rg --count -- ' --export ' "$GPG_CALLS")" 'public key exported once'

copy_site_documents
for doc in LICENSE SECURITY.md THIRD_PARTY_NOTICES.md; do
	cmp -- "$REPO_DIR/$doc" "$OUT_DIR/$doc"
done

# Exercise the complete publisher with all packages cached.
github_api_get() {
	jq --null-input --argjson newest "$ARM_RELEASE" --argjson older "$RELEASE" '[$newest, $older]'
}
curl() {
	fail 'warm publisher attempted a download'
}
main
assert_equal 2 "$(jq '.mirrored_assets | length' "$OUT_DIR/releases.json")" 'complete warm publication'
assert_equal 2 "$(jq --raw-output '.newest_release.release_id' "$OUT_DIR/releases.json")" 'newest snapshot'

# Keep a retained package and one recently used extra package.
printf '{"cache_key":"%s"}\n' "$FIRST_KEY" >"$MANIFEST"
ARM_KEY="$(jq --raw-output '.cache_key' "$TEST_ROOT/arm.ndjson")"
touch --date='@2000000000' "$CACHE_DIR/$ARM_KEY/metadata.json"
prune_package_cache "$MANIFEST" "$(stat --format='%s' "$ARM")"
assert_equal 2 "$(find "$CACHE_DIR" -name package.deb | wc --lines)" 'bounded extra cache'
prune_package_cache "$MANIFEST" 0
assert_equal 1 "$(find "$CACHE_DIR" -name package.deb | wc --lines)" 'zero extra budget'
cmp -- "$AMD" "$CACHED"
printf '%s\n' 'package and cache tests passed'
