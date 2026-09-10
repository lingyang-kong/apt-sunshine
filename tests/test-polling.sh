#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(
	if ! cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."; then
		exit 1
	fi
	pwd
)"
SCRIPT="$SCRIPT_DIR/scripts/sync-apt-repo.sh"
TEST_DIRECTORY="$(mktemp --directory)"
trap 'rm --recursive --force -- "$TEST_DIRECTORY"' EXIT

# shellcheck disable=SC1090,SC1091
source "$SCRIPT"

API_MODE=first_page
MANIFEST_MODE=available
API_CALL_LOG="$TEST_DIRECTORY/api-calls"
MANIFEST_URL='https://example.invalid/releases.json'

make_release() {
	local release_id=$1
	local tag_name=$2
	local asset_id=$3

	jq --compact-output --null-input \
		--arg release_id "$release_id" \
		--arg tag_name "$tag_name" \
		--arg asset_id "$asset_id" \
		'{
			id: $release_id,
			tag_name: $tag_name,
			draft: false,
			prerelease: false,
			assets: [{
				id: $asset_id,
				name: "sunshine-ubuntu-22.04-amd64.deb",
				size: 1,
				browser_download_url: "https://example.invalid/sunshine.deb",
				content_type: "application/vnd.debian.binary-package",
				state: "uploaded",
				digest: "sha256:fixture"
			}]
		}'
}

STABLE_ONE="$(make_release 101 v1.0.0 1001)"
STABLE_TWO="$(make_release 202 v2.0.0 2002)"
STABLE_OLD="$(make_release 303 v0.9.0 3003)"
PRE_RELEASE_PAGE="$(jq --compact-output --null-input '[range(0; 100) | {
		id: (10000 + .),
		draft: false,
		prerelease: true,
		assets: []
	}]')"

FIRST_PAGE="$(jq --compact-output --null-input --argjson stable "$STABLE_ONE" '[$stable] + [range(0; 99) | {
		id: (4000 + .),
		draft: false,
		prerelease: true,
		assets: []
	}]')"
SECOND_PAGE="$(jq --compact-output --null-input --argjson stable "$STABLE_TWO" --argjson old "$STABLE_OLD" '[$stable, $old]')"

github_api_get() {
	local url=$1
	printf '%s\n' "$url" >>"$API_CALL_LOG"

	case "$API_MODE" in
	first_page)
		if [[ $url == *'page=1' ]]; then
			printf '%s\n' "$FIRST_PAGE"
		else
			printf '%s\n' '[]'
		fi
		;;
	prerelease_first)
		if [[ $url == *'page=1' ]]; then
			printf '%s\n' "$PRE_RELEASE_PAGE"
		else
			printf '%s\n' "$SECOND_PAGE"
		fi
		;;
	api_failure)
		return 42
		;;
	json_failure)
		printf '%s\n' '{not-json'
		;;
	*)
		printf '%s\n' "unknown test API mode: $API_MODE" >&2
		return 1
		;;
	esac
}

curl() {
	case "$MANIFEST_MODE" in
	available)
		printf '%s\n' "$PREVIOUS_MANIFEST"
		;;
	missing)
		printf '%s\n' '{}'
		;;
	malformed)
		printf '%s\n' '{not-json'
		;;
	unavailable)
		return 22
		;;
	*)
		printf '%s\n' "unknown test manifest mode: $MANIFEST_MODE" >&2
		return 1
		;;
	esac
}

assert_equal() {
	local expected=$1
	local actual=$2
	local description=$3

	if [[ $actual != "$expected" ]]; then
		printf 'FAIL: %s (expected %q, got %q)\n' "$description" "$expected" "$actual" >&2
		exit 1
	fi
}

assert_call_count() {
	local expected=$1
	local description=$2
	local actual
	actual="$(wc --lines <"$API_CALL_LOG")"
	assert_equal "$expected" "$actual" "$description"
}

snapshot_for() {
	newest_release_snapshot <<<"$1"
}

PREVIOUS_MANIFEST="$(jq --compact-output --null-input --argjson snapshot "$(snapshot_for "$STABLE_ONE")" '{newest_release: $snapshot}')"
: >"$API_CALL_LOG"
if ! result="$(check_newest_release_changed "$MANIFEST_URL")"; then
	printf '%s\n' 'FAIL: first-page no-op poll failed' >&2
	exit 1
fi
assert_equal 'false' "$result" 'same first-page release is unchanged'
assert_call_count 1 'first-page no-op stops after one API request'

updated_release="$(jq '.assets[0].updated_at = "2026-09-10T00:00:00Z"' <<<"$STABLE_ONE")"
if [[ $(snapshot_for "$updated_release") == "$(snapshot_for "$STABLE_ONE")" ]]; then
	printf '%s\n' 'FAIL: asset update timestamp did not change the snapshot' >&2
	exit 1
fi

API_MODE=prerelease_first
: >"$API_CALL_LOG"
if ! result="$(check_newest_release_changed "$MANIFEST_URL")"; then
	printf '%s\n' 'FAIL: prerelease-only first page poll failed' >&2
	exit 1
fi
assert_equal 'true' "$result" 'stable release after prerelease-only page is detected'
assert_call_count 2 'prerelease-only first page is followed by the next API page'

output_file="$TEST_DIRECTORY/stable-releases.ndjson"
: >"$API_CALL_LOG"
if ! collect_stable_releases false >"$output_file"; then
	printf '%s\n' 'FAIL: full stable release collection failed' >&2
	exit 1
fi
expected_releases="$(printf '%s\n%s\n' "$STABLE_TWO" "$STABLE_OLD")"
assert_equal "$expected_releases" "$(<"$output_file")" 'full collection preserves stable release order'
assert_call_count 2 'full collection paginates beyond a prerelease-only page'

API_MODE=first_page
FIRST_PAGE="$(jq --compact-output --null-input --argjson stable "$STABLE_TWO" '[$stable]')"
PREVIOUS_MANIFEST="$(jq --compact-output --null-input --argjson snapshot "$(snapshot_for "$STABLE_ONE")" '{newest_release: $snapshot}')"
: >"$API_CALL_LOG"
if ! result="$(check_newest_release_changed "$MANIFEST_URL")"; then
	printf '%s\n' 'FAIL: changed snapshot poll failed' >&2
	exit 1
fi
assert_equal 'true' "$result" 'changed release snapshot triggers a build'
assert_call_count 1 'changed first-page poll stops after one API request'

for manifest_mode in unavailable missing malformed; do
	MANIFEST_MODE=$manifest_mode
	: >"$API_CALL_LOG"
	if ! result="$(check_newest_release_changed "$MANIFEST_URL")"; then
		printf 'FAIL: %s previous manifest should request a build\n' "$manifest_mode" >&2
		exit 1
	fi
	assert_equal 'true' "$result" "$manifest_mode previous manifest requests a build"
done
MANIFEST_MODE=available

API_MODE=api_failure
: >"$API_CALL_LOG"
if result="$(check_newest_release_changed "$MANIFEST_URL")" 2>"$TEST_DIRECTORY/api-failure"; then
	printf '%s\n' 'FAIL: API failure unexpectedly returned a poll result' >&2
	exit 1
fi

workflow_root="$TEST_DIRECTORY/workflow-repo"
mkdir --parents "$workflow_root/scripts"
workflow_script="$workflow_root/scripts/sync-apt-repo.sh"
cat >"$workflow_script" <<'EOF'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

if [[ $1 != --check-newest-release || $2 != "$POLL_EXPECTED_URL" ]]; then
	exit 43
fi

case ${POLL_MODE:-success} in
fail)
	exit 42
	;;
success)
	printf '%s\n' "${POLL_RESULT:-false}"
	;;
*)
	exit 44
	;;
esac
EOF
chmod 0755 "$workflow_script"
poll_script="$workflow_root/scripts/poll-release.sh"
cp "$SCRIPT_DIR/scripts/poll-release.sh" "$poll_script"
chmod 0755 "$poll_script"

run_poll() {
	local force_value=$1
	local poll_mode=$2
	local poll_result=$3

	: >"$TEST_DIRECTORY/workflow-output"
	PUBLISHED_MANIFEST_URL="$MANIFEST_URL" \
		FORCE_BUILD="$force_value" \
		POLL_EXPECTED_URL="$MANIFEST_URL" \
		POLL_MODE="$poll_mode" \
		POLL_RESULT="$poll_result" \
		"$poll_script" >"$TEST_DIRECTORY/workflow-output"
}

: >"$TEST_DIRECTORY/workflow-output"
PUBLISHED_MANIFEST_URL='' \
	FORCE_BUILD='' \
	POLL_EXPECTED_URL='https://lingyang-kong.github.io/apt-sunshine/releases.json' \
	POLL_MODE=success \
	POLL_RESULT=false \
	"$poll_script" >"$TEST_DIRECTORY/workflow-output"
assert_equal 'false' "$(<"$TEST_DIRECTORY/workflow-output")" 'default URL and force value preserve an unchanged release'

if run_poll true fail false; then
	printf '%s\n' 'FAIL: forced workflow poll masked API failure' >&2
	exit 1
fi
if [[ -s $TEST_DIRECTORY/workflow-output ]]; then
	printf '%s\n' 'FAIL: failed workflow poll wrote a changed output' >&2
	exit 1
fi

if ! run_poll true success false; then
	printf '%s\n' 'FAIL: forced workflow poll failed' >&2
	exit 1
fi
assert_equal 'true' "$(<"$TEST_DIRECTORY/workflow-output")" 'manual force input enables workflow build'

if run_poll false success maybe; then
	printf '%s\n' 'FAIL: invalid poll result unexpectedly succeeded' >&2
	exit 1
fi
if [[ -s $TEST_DIRECTORY/workflow-output ]]; then
	printf '%s\n' 'FAIL: invalid poll result wrote a changed output' >&2
	exit 1
fi

API_MODE=first_page
FIRST_PAGE='[{"id":404,"tag_name":"v4.0.0","draft":false,"prerelease":false,"assets":"not-an-array"}]'
: >"$API_CALL_LOG"
if result="$(check_newest_release_changed "$MANIFEST_URL")" 2>"$TEST_DIRECTORY/snapshot-failure"; then
	printf '%s\n' 'FAIL: malformed newest release snapshot unexpectedly returned a poll result' >&2
	exit 1
fi

API_MODE=json_failure
: >"$API_CALL_LOG"
if result="$(check_newest_release_changed "$MANIFEST_URL")" 2>"$TEST_DIRECTORY/json-failure"; then
	printf '%s\n' 'FAIL: malformed API JSON unexpectedly returned a poll result' >&2
	exit 1
fi

printf '%s\n' 'polling tests passed'
