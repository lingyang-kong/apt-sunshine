#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

SCRIPT_PATH="$(
	if ! cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."; then
		exit 1
	fi
	pwd
)/scripts/sync-apt-repo.sh"
TEST_ROOT="$(mktemp --directory)"
trap 'rm --recursive --force -- "$TEST_ROOT"' EXIT

assert_equal() {
	local expected=$1
	local actual=$2
	local message=$3
	if [[ $expected != "$actual" ]]; then
		printf 'assertion failed: %s\nexpected: %s\nactual: %s\n' "$message" "$expected" "$actual" >&2
		exit 1
	fi
}

assert_contains() {
	local needle=$1
	local haystack=$2
	local message=$3
	if [[ $haystack != *"$needle"* ]]; then
		printf 'assertion failed: %s\nmissing: %s\n' "$message" "$needle" >&2
		exit 1
	fi
}

assert_file_exists() {
	local path=$1
	local message=$2
	if [[ ! -e $path ]]; then
		printf 'assertion failed: %s\nmissing path: %s\n' "$message" "$path" >&2
		exit 1
	fi
}

assert_file_absent() {
	local path=$1
	local message=$2
	if [[ -e $path ]]; then
		printf 'assertion failed: %s\nunexpected path: %s\n' "$message" "$path" >&2
		exit 1
	fi
}

write_fixture_package_manifest() {
	local release_json=$1
	local candidate_manifest=$2
	local package_size=$3
	local release_id
	release_id="$(jq --raw-output '.id' <<<"$release_json")"
	local tag_name
	tag_name="$(jq --raw-output '.tag_name // .id' <<<"$release_json")"
	local package_path="$WORK_DIR/prepared/$release_id/package.deb"
	mkdir --parents "$(dirname -- "$package_path")"
	printf 'package %s\n' "$release_id" >"$package_path"
	jq --null-input --compact-output \
		--arg release_id "$release_id" \
		--arg tag_name "$tag_name" \
		--arg package_path "$package_path" \
		--arg pool_path "pool/main/s/sunshine/ubuntu-22.04/amd64/$release_id/package.deb" \
		--argjson package_size "$package_size" \
		'{release_id: $release_id, tag_name: $tag_name, arch: "amd64", package_size: $package_size, package_path: $package_path, pool_path: $pool_path}' \
		>"$candidate_manifest"
}

run_selection_scenario() (
	local scenario_root="$TEST_ROOT/selection"
	mkdir --parents "$scenario_root/work" "$scenario_root/out"
	# shellcheck disable=SC2030,SC2031
	export WORK_DIR="$scenario_root/work" OUT_DIR="$scenario_root/out" MAX_BYTES=10
	# shellcheck source=/dev/null
	source "$SCRIPT_PATH"

	local releases_file="$scenario_root/releases.ndjson"
	local candidates_file="$scenario_root/candidates.ndjson"
	printf '%s\n' \
		'{"id":3,"tag_name":"v3","assets":[{"name":"sunshine-ubuntu-22.04-amd64.deb","size":900}]}' \
		'{"id":2,"tag_name":"v2","assets":[{"name":"source.zip","size":1}]}' \
		'{"id":1,"tag_name":"v1","assets":[{"name":"sunshine-ubuntu-22.04-amd64.deb","size":900}]}' \
		'{"id":0,"tag_name":"v0","assets":[{"name":"sunshine-ubuntu-22.04-amd64.deb","size":900}]}' \
		>"$releases_file"
	select_release_candidates "$releases_file" "$candidates_file"
	assert_equal '["v3","v1","v0"]' "$(jq --compact-output --slurp '[.[].tag_name]' "$candidates_file")" 'candidates are newest-first'
	assert_equal '3' "$(jq --slurp '[.[].assets[]] | length' "$candidates_file")" 'unsupported assets are removed in one selection pass'

	local no_assets_file="$scenario_root/no-assets.ndjson"
	local no_assets_error="$scenario_root/no-assets.err"
	printf '%s\n' \
		'{"id":9,"tag_name":"v9","assets":[{"name":"source.zip","size":1}]}' \
		'{"id":8,"tag_name":"v8","assets":[{"name":"sunshine-ubuntu-22.04-amd64.deb","size":1}]}' \
		>"$no_assets_file"
	if (select_release_candidates "$no_assets_file" "$scenario_root/no-assets.selected" 2>"$no_assets_error"); then
		printf 'assertion failed: latest release without supported assets succeeded\n' >&2
		exit 1
	fi
	assert_contains 'latest stable release has no supported Linux assets' "$(<"$no_assets_error")" 'latest no-assets failure is explicit'
)

run_stream_measurement_scenario() (
	local scenario_root="$TEST_ROOT/stream-measurement"
	mkdir --parents "$scenario_root/work" "$scenario_root/out"
	# shellcheck disable=SC2030,SC2031
	export WORK_DIR="$scenario_root/work" OUT_DIR="$scenario_root/out" MAX_BYTES=10
	# shellcheck source=/dev/null
	source "$SCRIPT_PATH"

	printf 'tar payload\n' >"$OUT_DIR/payload"
	ln "$OUT_DIR/payload" "$OUT_DIR/payload-hardlink"
	ln --symbolic payload "$OUT_DIR/payload-link"
	local streamed_tar_bytes
	streamed_tar_bytes="$(measure_pages_artifact_bytes)"
	local expected_tar="$scenario_root/expected.tar"
	tar \
		--dereference --hard-dereference \
		--directory "$OUT_DIR" \
		--create --file="$expected_tar" \
		.
	local expected_tar_bytes
	expected_tar_bytes="$(stat --format='%s' "$expected_tar")"
	assert_equal "$expected_tar_bytes" "$streamed_tar_bytes" 'streamed tar size matches tar archive size'
	assert_file_absent "$WORK_DIR/pages-size-check.tar" 'streamed size check leaves no temporary tar'
)

run_refresh_metadata_scenario() (
	local scenario_root="$TEST_ROOT/refresh-metadata"
	mkdir --parents "$scenario_root/work" "$scenario_root/out/dists"
	# shellcheck disable=SC2030,SC2031
	export WORK_DIR="$scenario_root/work" OUT_DIR="$scenario_root/out" MAX_BYTES=10
	# shellcheck source=/dev/null
	source "$SCRIPT_PATH"

	local selected_file="$scenario_root/selected.ndjson"
	local manifest_file="$scenario_root/manifest.ndjson"
	printf '%s\n' '{"id":3,"tag_name":"v3","assets":[]}' >"$selected_file"
	printf '%s\n' '{"release_id":"3","arch":"amd64","pool_path":"pool/main/s/sunshine/ubuntu-22.04/amd64/3/package.deb"}' >"$manifest_file"
	printf 'stale\n' >"$OUT_DIR/dists/stale"

	generate_apt_metadata() {
		local manifest=$1
		: "$manifest"
		if [[ -e "$OUT_DIR/dists/stale" ]]; then
			printf 'stale metadata remained during regeneration\n' >&2
			return 1
		fi
		: >"$WORK_DIR/generated-metadata"
	}
	sign_repository_metadata() {
		: >"$WORK_DIR/signed-metadata"
	}
	write_release_manifest() {
		local manifest=$1
		local selected=$2
		: "$manifest" "$selected"
		: >"$WORK_DIR/release-manifest-written"
	}
	refresh_repository_metadata "$selected_file" "$manifest_file" 'fixture-key'
	assert_file_absent "$OUT_DIR/dists/stale" 'metadata regeneration removes stale dists before indexing'
)

run_retention_scenario() (
	local scenario_root="$TEST_ROOT/retention"
	mkdir --parents "$scenario_root/work" "$scenario_root/out"
	# shellcheck disable=SC2030,SC2031
	export WORK_DIR="$scenario_root/work" OUT_DIR="$scenario_root/out" MAX_BYTES=10
	# shellcheck source=/dev/null
	source "$SCRIPT_PATH"

	local candidates_file="$scenario_root/candidates.ndjson"
	local selected_file="$scenario_root/selected.ndjson"
	local manifest_file="$scenario_root/manifest.ndjson"
	local candidates_snapshot="$scenario_root/candidates.snapshot"
	printf '%s\n' \
		'{"id":3,"tag_name":"v3","assets":[{"name":"sunshine-ubuntu-22.04-amd64.deb"}]}' \
		'{"id":1,"tag_name":"v1","assets":[{"name":"sunshine-ubuntu-22.04-amd64.deb"}]}' \
		'{"id":0,"tag_name":"v0","assets":[{"name":"sunshine-ubuntu-22.04-amd64.deb"}]}' \
		>"$candidates_file"
	cp -- "$candidates_file" "$candidates_snapshot"

	local prepare_calls="$WORK_DIR/prepare-calls"
	prepare_release_packages() {
		local release_json=$1
		local candidate_manifest=$2
		local release_id
		release_id="$(jq --raw-output '.id' <<<"$release_json")"
		local package_size
		case $release_id in
		3)
			package_size=4
			;;
		1)
			package_size=6
			;;
		0)
			package_size=1
			;;
		*)
			printf 'unexpected release prepared: %s\n' "$release_id" >&2
			return 1
			;;
		esac

		printf '%s\n' "$release_id" >>"$prepare_calls"
		write_fixture_package_manifest "$release_json" "$candidate_manifest" "$package_size"
	}

	refresh_calls=0
	initialize_repository_signing() {
		printf '%s\n' 'fixture-key'
	}
	refresh_repository_metadata() {
		local selected=$1
		local manifest=$2
		: "$selected" "$manifest"
		refresh_calls=$((refresh_calls + 1))
	}

	measure_pages_artifact_bytes() {
		printf '%s\n' 9
	}

	: >"$prepare_calls"
	enforce_pages_size_limit "$candidates_file" "$selected_file" "$manifest_file"
	assert_equal '[1,3]' "$(jq --compact-output --slurp '[.[].id]' "$selected_file")" 'package boundary retains newest fitting releases'
	assert_equal '[1,3]' "$(jq --compact-output --slurp '[.[].release_id | tonumber]' "$manifest_file")" 'manifest follows oldest to newest selection order'
	assert_equal '10' "$(jq --slurp '[.[].package_size] | add' "$manifest_file")" 'retention uses generated package sizes at exact boundary'
	assert_equal $'3\n1' "$(<"$prepare_calls")" 'only required releases are prepared once'
	assert_equal '1' "$refresh_calls" 'metadata is refreshed once when the initial artifact fits'
	assert_file_exists "$OUT_DIR/pool/main/s/sunshine/ubuntu-22.04/amd64/3/package.deb" 'accepted newest package is published'
	assert_file_exists "$OUT_DIR/pool/main/s/sunshine/ubuntu-22.04/amd64/1/package.deb" 'accepted older package is published'
	assert_file_absent "$OUT_DIR/pool/main/s/sunshine/ubuntu-22.04/amd64/0/package.deb" 'unprepared older candidate is absent from publication'
	if ! cmp -- "$candidates_snapshot" "$candidates_file"; then
		printf 'assertion failed: enforcement mutated the candidate file\n' >&2
		exit 1
	fi
)

run_rejected_candidate_scenario() (
	local scenario_root="$TEST_ROOT/rejected-candidate"
	mkdir --parents "$scenario_root/work" "$scenario_root/out"
	# shellcheck disable=SC2030,SC2031
	export WORK_DIR="$scenario_root/work" OUT_DIR="$scenario_root/out" MAX_BYTES=10
	# shellcheck source=/dev/null
	source "$SCRIPT_PATH"

	local candidates_file="$scenario_root/candidates.ndjson"
	local selected_file="$scenario_root/selected.ndjson"
	local manifest_file="$scenario_root/manifest.ndjson"
	printf '%s\n' \
		'{"id":3,"tag_name":"v3","assets":[{"name":"sunshine-ubuntu-22.04-amd64.deb"}]}' \
		'{"id":1,"tag_name":"v1","assets":[{"name":"sunshine-ubuntu-22.04-amd64.deb"}]}' \
		>"$candidates_file"

	prepare_release_packages() {
		local release_json=$1
		local candidate_manifest=$2
		local release_id
		release_id="$(jq --raw-output '.id' <<<"$release_json")"
		local package_size
		case $release_id in
		3)
			package_size=4
			;;
		1)
			package_size=7
			;;
		*)
			printf 'unexpected release prepared: %s\n' "$release_id" >&2
			return 1
			;;
		esac
		write_fixture_package_manifest "$release_json" "$candidate_manifest" "$package_size"
	}
	initialize_repository_signing() {
		printf '%s\n' 'fixture-key'
	}
	refresh_repository_metadata() {
		:
	}
	measure_pages_artifact_bytes() {
		printf '%s\n' 9
	}

	enforce_pages_size_limit "$candidates_file" "$selected_file" "$manifest_file"
	assert_equal '3' "$(jq --raw-output '.id' "$selected_file")" 'rejected candidate is not retained'
	assert_file_exists "$WORK_DIR/prepared/1/package.deb" 'rejected candidate remains available in private preparation storage'
	assert_file_absent "$OUT_DIR/pool/main/s/sunshine/ubuntu-22.04/amd64/1/package.deb" 'rejected candidate is never copied to publication'
)

run_eviction_scenario() (
	local scenario_root="$TEST_ROOT/eviction"
	mkdir --parents "$scenario_root/work" "$scenario_root/out"
	# shellcheck disable=SC2030,SC2031
	export WORK_DIR="$scenario_root/work" OUT_DIR="$scenario_root/out" MAX_BYTES=10
	# shellcheck source=/dev/null
	source "$SCRIPT_PATH"

	local candidates_file="$scenario_root/candidates.ndjson"
	local selected_file="$scenario_root/selected.ndjson"
	local manifest_file="$scenario_root/manifest.ndjson"
	printf '%s\n' \
		'{"id":3,"tag_name":"v3","assets":[{"name":"sunshine-ubuntu-22.04-amd64.deb"}]}' \
		'{"id":1,"tag_name":"v1","assets":[{"name":"sunshine-ubuntu-22.04-amd64.deb"}]}' \
		>"$candidates_file"

	local prepare_calls="$WORK_DIR/prepare-calls"
	prepare_release_packages() {
		local release_json=$1
		local candidate_manifest=$2
		local release_id
		release_id="$(jq --raw-output '.id' <<<"$release_json")"
		printf '%s\n' "$release_id" >>"$prepare_calls"
		local package_size
		case $release_id in
		3)
			package_size=4
			;;
		1)
			package_size=6
			;;
		*)
			printf 'unexpected release prepared: %s\n' "$release_id" >&2
			return 1
			;;
		esac
		write_fixture_package_manifest "$release_json" "$candidate_manifest" "$package_size"
	}

	refresh_calls=0
	initialize_repository_signing() {
		printf '%s\n' 'fixture-key'
	}
	refresh_repository_metadata() {
		local selected=$1
		local manifest=$2
		: "$selected" "$manifest"
		refresh_calls=$((refresh_calls + 1))
	}
	measure_pages_artifact_bytes() {
		if [[ ! -e "$WORK_DIR/first-measurement" ]]; then
			: >"$WORK_DIR/first-measurement"
			printf '%s\n' 10
		else
			printf '%s\n' 9
		fi
	}

	: >"$prepare_calls"
	enforce_pages_size_limit "$candidates_file" "$selected_file" "$manifest_file"
	assert_equal '3' "$(jq --raw-output '.id' "$selected_file")" 'artifact eviction keeps the newest release'
	assert_equal '3' "$(jq --raw-output '.release_id' "$manifest_file")" 'eviction removes oldest manifest rows'
	assert_equal $'3\n1' "$(<"$prepare_calls")" 'eviction does not rebuild surviving packages'
	assert_equal '2' "$refresh_calls" 'artifact eviction regenerates metadata only'
	assert_file_absent "$OUT_DIR/pool/main/s/sunshine/ubuntu-22.04/amd64/1/package.deb" 'eviction removes oldest package files'
	assert_file_exists "$OUT_DIR/pool/main/s/sunshine/ubuntu-22.04/amd64/3/package.deb" 'eviction preserves newest package files'
)

run_final_failure_scenario() (
	local scenario_root="$TEST_ROOT/final-failure"
	mkdir --parents "$scenario_root/work" "$scenario_root/out/pool/main/s/sunshine/ubuntu-22.04/amd64/3"
	# shellcheck disable=SC2030,SC2031
	export WORK_DIR="$scenario_root/work" OUT_DIR="$scenario_root/out" MAX_BYTES=10
	# shellcheck source=/dev/null
	source "$SCRIPT_PATH"

	local selected_file="$scenario_root/selected.ndjson"
	local manifest_file="$scenario_root/manifest.ndjson"
	printf '%s\n' '{"id":3,"tag_name":"v3"}' >"$selected_file"
	printf '%s\n' '{"release_id":"3","pool_path":"pool/main/s/sunshine/ubuntu-22.04/amd64/3/final.deb"}' >"$manifest_file"
	printf 'final\n' >"$OUT_DIR/pool/main/s/sunshine/ubuntu-22.04/amd64/3/final.deb"
	local final_error="$scenario_root/final.error"
	if (evict_oldest_release "$selected_file" "$manifest_file" 2>"$final_error"); then
		printf 'assertion failed: final retained release was evicted\n' >&2
		exit 1
	fi
	assert_contains 'cannot evict the final retained release' "$(<"$final_error")" 'final too-big error is explicit'
	assert_equal '3' "$(jq --raw-output '.id' "$selected_file")" 'final release remains selected after failure'
	assert_file_exists "$OUT_DIR/pool/main/s/sunshine/ubuntu-22.04/amd64/3/final.deb" 'final release package remains after failure'
)

run_selection_scenario
run_stream_measurement_scenario
run_refresh_metadata_scenario
run_retention_scenario
run_rejected_candidate_scenario
run_eviction_scenario
run_final_failure_scenario
printf '%s\n' 'retention tests passed'
