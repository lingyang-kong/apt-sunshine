#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
ROOT_DIR="$(
	if ! cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."; then
		exit 1
	fi
	pwd
)"

readonly SCRIPT_NAME
readonly ROOT_DIR
readonly WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build/sunshine-apt}"
readonly OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
readonly CACHE_DIR="${CACHE_DIR:-$ROOT_DIR/.build/sunshine-cache}"
readonly PACKAGE_CACHE_FORMAT='1'
readonly API_REPO="${API_REPO:-LizardByte/Sunshine}"
readonly API_URL="https://api.github.com/repos/$API_REPO/releases"
readonly MAX_BYTES="${MAX_BYTES:-1000000000}"
readonly PACKAGE_CACHE_EXTRA_BYTES="${PACKAGE_CACHE_EXTRA_BYTES:-$MAX_BYTES}"
readonly USER_AGENT='sunshine-apt-sync'
readonly INDEX_TEMPLATE="$ROOT_DIR/templates/index.html"
readonly SUPPORTED_ASSET_REGEX='\.deb$'
readonly APT_ORIGIN='Unofficial Sunshine Mirror'
readonly APT_LABEL='Unofficial Sunshine Mirror'
readonly APT_DESCRIPTION='Unofficial APT repository for Sunshine upstream Debian and Ubuntu packages'
readonly PACKAGE_NAME='sunshine'
readonly PACKAGE_CACHE_FILE="$ROOT_DIR/scripts/package-cache.sh"
# shellcheck source=scripts/package-cache.sh
source "$PACKAGE_CACHE_FILE"

# jq expands these variables when serializing the manifest.
# shellcheck disable=SC2016
readonly RELEASES_MANIFEST_FILTER='
{
	source_repo: $api_repo,
	generated_at: $generated_at,
	max_bytes: $max_bytes,
	package_name: $package_name,
	newest_release: $newest_release,
	mirrored_assets: .
}
'

fail() {
	echo "$1" >&2
	exit 1
}

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		fail "missing required command: $1"
	fi
}

github_api_get() {
	local url=$1
	local args=(
		--fail --silent --show-error --location
		--header 'Accept: application/vnd.github+json'
		--header "User-Agent: $USER_AGENT"
	)

	if [[ -n ${GITHUB_TOKEN:-} ]]; then
		args+=(--header "Authorization: Bearer $GITHUB_TOKEN")
	fi

	curl "${args[@]}" "$url"
}

normalize_release_file() {
	local source=$1
	local target=$2
	local suite=$3
	SUITE="$suite" DESCRIPTION="$APT_DESCRIPTION" ORIGIN="$APT_ORIGIN" LABEL="$APT_LABEL" perl -0pe '
		s/^Suite: .*/Suite: $ENV{SUITE}/m;
		s/^Codename: .*/Codename: $ENV{SUITE}/m;
		s/^Origin: .*/Origin: $ENV{ORIGIN}/m;
		s/^Label: .*/Label: $ENV{LABEL}/m;
		s/^Description: .*/Description: $ENV{DESCRIPTION}/m;
	' "$source" >"$target"
}

suite_from_filename() {
	local filename=$1
	local suite

	case $filename in
	sunshine*.deb)
		suite=${filename#sunshine}
		suite=${suite%.deb}
		;;
	*)
		return 1
		;;
	esac

	case $suite in
	-debian | '')
		suite=${suite#-}
		printf '%s-legacy\n' "${suite:-generic}"
		;;
	_* | -*-*)
		local arch
		if ! arch=$(arch_from_filename "$filename"); then
			return 1
		fi
		suite=${suite%[-_]"$arch"}
		case $suite in
		_*)
			if [[ $suite =~ ^_[^_]+\+(debian|ubuntu)([^_]+)$ ]]; then
				printf '%s-%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
			else
				return 1
			fi
			;;
		-*)
			printf '%s\n' "${suite#-}"
			;;
		esac
		;;
	-ubuntu_[0-9][0-9]_[0-9][0-9] | -[0-9][0-9].[0-9][0-9] | [0-9][0-9][.-][0-9][0-9] | -[0-9][0-9][0-9][0-9])
		suite=${suite#-ubuntu}
		suite=${suite//[-._]/}
		printf 'ubuntu-%s.%s\n' "${suite:0:2}" "${suite:2:2}"
		;;
	*)
		return 1
		;;
	esac
}

arch_from_filename() {
	local filename=$1
	local arch

	case $filename in
	sunshine-?*-*.deb | sunshine_?*_*.deb)
		arch=${filename%.deb}
		arch=${arch##*[-_]}
		;;
	*)
		return 1
		;;
	esac

	case $arch in
	amd64 | arm64)
		printf '%s\n' "$arch"
		;;
	*)
		return 1
		;;
	esac
}

collect_stable_releases() {
	local first_stable=${1:-false}
	local page=1
	local page_size=100
	local payload count stable
	while :; do
		if ! payload="$(github_api_get "$API_URL?per_page=$page_size&page=$page")"; then
			printf 'GitHub releases API request failed on page %s\n' "$page" >&2
			return 1
		fi
		if ! count="$(jq --exit-status 'if type == "array" then length else error("expected a releases array") end' <<<"$payload")"; then
			printf 'GitHub releases API returned invalid JSON on page %s\n' "$page" >&2
			return 1
		fi
		if ! stable="$(jq --compact-output --argjson first "$first_stable" '
			def stable: .[] | select(.draft | not) | select(.prerelease | not);
			if $first then first(stable) else stable end
		' <<<"$payload")"; then
			return 1
		fi
		if [[ -n $stable ]]; then
			if ! printf '%s\n' "$stable"; then
				return 1
			fi
		fi
		if [[ (-n $stable && $first_stable == true) || $count -lt $page_size ]]; then
			return 0
		fi
		page=$((page + 1))
	done
}

newest_release_snapshot() {
	jq --sort-keys --compact-output --arg supported_asset_regex "$SUPPORTED_ASSET_REGEX" '{
		release_id: (.id | tostring),
		tag_name,
		assets: [
			.assets[]
			| select(.name | test($supported_asset_regex))
			| {
				asset_id: (.id | tostring),
				name,
				size,
				browser_download_url,
				content_type,
				state,
				updated_at,
				digest
			}
		] | sort_by(.asset_id)
	}'
}

check_newest_release_changed() {
	local previous_manifest_url=$1
	local release_json
	if ! release_json="$(collect_stable_releases true)"; then
		printf '%s\n' 'unable to collect stable releases' >&2
		return 1
	fi
	if [[ -z $release_json ]]; then
		printf '%s\n' 'no stable releases found' >&2
		return 1
	fi

	local current_snapshot
	if ! current_snapshot="$(newest_release_snapshot <<<"$release_json")"; then
		printf '%s\n' 'unable to build newest stable release snapshot' >&2
		return 1
	fi

	local previous_manifest
	if ! previous_manifest="$(curl --fail --silent --show-error --location --header "User-Agent: $USER_AGENT" "$previous_manifest_url")"; then
		printf '%s\n' 'true'
		return 0
	fi

	local previous_snapshot
	if ! previous_snapshot="$(jq --exit-status --sort-keys --compact-output '.newest_release' <<<"$previous_manifest" 2>/dev/null)"; then
		printf '%s\n' 'true'
		return 0
	fi
	if [[ $previous_snapshot != "$current_snapshot" ]]; then
		printf '%s\n' 'true'
		return 0
	fi

	printf '%s\n' 'false'
}

select_release_candidates() {
	local releases_file=$1
	local candidates_file=$2
	if ! jq --compact-output --slurp --arg supported_asset_regex "$SUPPORTED_ASSET_REGEX" '
		map(.assets = [(.assets // [])[] | select(.name | test($supported_asset_regex))])
		| if length == 0 then
			error("no stable releases found")
		elif (.[0].assets | length) == 0 then
				error("latest stable release has no supported Linux assets")
		else
			map(select(.assets | length > 0))[]
		end
	' "$releases_file" >"$candidates_file"; then
		fail 'unable to select release candidates'
	fi
}

remove_manifest_packages() {
	local manifest_file=$1
	if [[ ! -s $manifest_file ]]; then
		return 0
	fi

	local pool_path
	while IFS= read -r pool_path; do
		if [[ -z $pool_path ]]; then
			continue
		fi
		rm --force -- "$OUT_DIR/$pool_path"
		local release_dir
		release_dir="$(dirname -- "$OUT_DIR/$pool_path")"
		if rmdir --ignore-fail-on-non-empty "$release_dir" 2>/dev/null; then
			:
		fi
	done < <(jq --raw-output '.pool_path // empty' "$manifest_file")
}

evict_oldest_release() {
	local selected_file=$1
	local manifest_file=$2

	if [[ ! -s $selected_file ]]; then
		fail 'cannot evict the oldest release: no retained releases'
	fi
	if [[ ! -s $manifest_file ]]; then
		fail 'cannot evict the oldest release: no package manifest'
	fi

	local release_count
	release_count="$(wc --lines <"$selected_file")"
	if ((release_count <= 1)); then
		fail 'cannot evict the final retained release: it exceeds the Pages size limit'
	fi

	local oldest_release_id
	oldest_release_id="$(head --lines=1 "$selected_file" | jq --raw-output '.id // empty')"
	if [[ -z $oldest_release_id ]]; then
		fail 'cannot evict the oldest release: selected release has no id'
	fi
	local evicted_manifest
	evicted_manifest="$(mktemp)"
	jq --compact-output --arg release_id "$oldest_release_id" \
		'select((.release_id | tostring) == $release_id)' \
		"$manifest_file" >"$evicted_manifest"
	if [[ ! -s $evicted_manifest ]]; then
		fail "cannot evict release $oldest_release_id: no package records"
	fi
	remove_manifest_packages "$evicted_manifest"
	rm --force -- "$evicted_manifest"

	local tmp_file
	tmp_file="$(mktemp)"
	if ! tail --lines=+2 "$selected_file" >"$tmp_file"; then
		rm --force -- "$tmp_file"
		return 1
	fi
	mv "$tmp_file" "$selected_file"

	local manifest_tmp
	manifest_tmp="$(mktemp)"
	jq --compact-output --arg release_id "$oldest_release_id" \
		'select((.release_id | tostring) != $release_id)' \
		"$manifest_file" >"$manifest_tmp"
	mv "$manifest_tmp" "$manifest_file"
}

prepare_release_packages() {
	local release_json=$1
	local manifest_file=$2
	mkdir --parents "$CACHE_DIR"
	: >"$manifest_file"

	local release_id asset_json
	release_id="$(jq --raw-output '.id' <<<"$release_json")"
	if [[ ! $release_id =~ ^[0-9]+$ ]]; then
		fail "invalid release ID: $release_id"
	fi
	while IFS= read -r asset_json; do
		local name suite arch='' url size expected_digest cache_key package_path metadata
		IFS=$'\t' read -r name url size < <(jq --raw-output '[.name, .browser_download_url, .size] | @tsv' <<<"$asset_json")
		if [[ $name == */* ]] || ! suite="$(suite_from_filename "$name")"; then
			fail "unrecognized .deb naming scheme: $name"
		fi
		if [[ ! $suite =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
			fail "invalid suite in $name: $suite"
		fi
		if arch="$(arch_from_filename "$name")"; then
			:
		else
			arch=''
		fi
		if [[ ! $size =~ ^[0-9]+$ || -z $url || $url == null ]]; then
			fail "invalid upstream asset size or URL: $name"
		fi
		expected_digest="$(jq --raw-output '.digest // empty' <<<"$asset_json")"
		if [[ -n $expected_digest ]]; then
			if ! expected_digest="$(normalize_sha256_digest "$expected_digest")"; then
				fail "unsupported upstream digest: $name"
			fi
		fi
		cache_key="$(package_cache_key "$asset_json" "$release_id")"
		package_path="$CACHE_DIR/$cache_key/package.deb"
		if ! metadata="$(read_cached_package "$cache_key" "$size" "$expected_digest" "$arch")"; then
			local sha256
			if ! sha256="$(download_upstream_asset "$package_path" "$url" "$size" "$expected_digest")"; then
				fail "unable to download a valid upstream asset: $name"
			fi
			if ! metadata="$(record_cached_package "$cache_key" "$size" "$sha256" "$arch")"; then
				fail "invalid upstream Debian package: $name"
			fi
		fi
		arch="$(jq --raw-output '.package_arch' <<<"$metadata")"
		jq --null-input --compact-output \
			--argjson release "$release_json" \
			--argjson asset "$asset_json" \
			--argjson metadata "$metadata" \
			--arg suite "$suite" \
			--arg package_path "$package_path" \
			--arg pool_path "pool/main/s/sunshine/$suite/$arch/$release_id/$name" \
			'{
				release_id: ($release.id | tostring),
				tag_name: $release.tag_name,
				published_at: $release.published_at,
				release_page_url: $release.html_url,
				source_tarball_url: $release.tarball_url,
				source_zipball_url: $release.zipball_url,
				suite: $suite,
				arch: $metadata.package_arch,
				asset_name: $asset.name,
				browser_download_url: $asset.browser_download_url,
				size: $metadata.package_size,
				package_path: $package_path,
				pool_path: $pool_path
			} + $metadata' >>"$manifest_file"
	done < <(jq --compact-output '.assets[]' <<<"$release_json")
}

publish_manifest_packages() {
	local manifest_file=$1
	local package_path pool_path
	while IFS=$'\t' read -r package_path pool_path; do
		mkdir --parents "$(dirname -- "$OUT_DIR/$pool_path")"
		cp -- "$package_path" "$OUT_DIR/$pool_path"
	done < <(jq --raw-output '[.package_path, .pool_path] | @tsv' "$manifest_file")
}

generate_apt_metadata() {
	local manifest_file=$1

	local suites arches
	mapfile -t suites < <(jq --raw-output '.suite' "$manifest_file" | sort --unique)
	local suite
	for suite in "${suites[@]}"; do
		if [[ -z $suite ]]; then
			continue
		fi
		mapfile -t arches < <(jq --raw-output --arg suite "$suite" 'select(.suite == $suite) | .arch' "$manifest_file" | sort --unique)

		local arch
		for arch in "${arches[@]}"; do
			if [[ -z $arch ]]; then
				continue
			fi
			local binary_dir="$OUT_DIR/dists/$suite/main/binary-$arch"
			local pool_dir="pool/main/s/sunshine/$suite/$arch"
			mkdir --parents "$binary_dir"
			(
				cd "$OUT_DIR"
				apt-ftparchive packages "$pool_dir" >"$binary_dir/Packages"
			)
			gzip --best --stdout "$binary_dir/Packages" >"$binary_dir/Packages.gz"
		done

		local suite_dir="$OUT_DIR/dists/$suite"
		local release_raw="$WORK_DIR/${suite//\//_}.Release.raw"
		apt-ftparchive \
			--option "APT::FTPArchive::Release::Origin=$APT_ORIGIN" \
			--option "APT::FTPArchive::Release::Label=$APT_LABEL" \
			--option "APT::FTPArchive::Release::Suite=$suite" \
			--option "APT::FTPArchive::Release::Codename=$suite" \
			--option "APT::FTPArchive::Release::Architectures=${arches[*]}" \
			--option "APT::FTPArchive::Release::Components=main" \
			--option "APT::FTPArchive::Release::Description=$APT_DESCRIPTION" \
			release "$suite_dir" >"$release_raw"
		normalize_release_file "$release_raw" "$suite_dir/Release" "$suite"
		rm --force "$release_raw"
	done
}

initialize_repository_signing() {
	if [[ -z ${APT_GPG_PRIVATE_KEY:-} ]]; then
		fail 'APT_GPG_PRIVATE_KEY is required'
	fi

	local gpg_home="$WORK_DIR/gnupg"
	if ! rm --recursive --force "$gpg_home"; then
		fail 'unable to clear the repository signing-key directory'
	fi
	if ! mkdir --mode=700 "$gpg_home"; then
		fail 'unable to create the repository signing-key directory'
	fi

	if ! gpg --homedir "$gpg_home" --batch --import <<<"$APT_GPG_PRIVATE_KEY" >/dev/null 2>&1; then
		fail 'unable to import the repository signing key'
	fi

	local key_id
	if ! key_id="$(gpg --homedir "$gpg_home" --batch --list-secret-keys --with-colons | awk -F: '/^sec:/ { print $5; exit }')"; then
		fail 'unable to list repository signing keys'
	fi
	if [[ -z $key_id ]]; then
		fail 'no secret key available after import'
	fi

	if ! gpg --homedir "$gpg_home" --batch --yes --export "$key_id" >"$OUT_DIR/sunshine-archive-keyring.gpg"; then
		fail 'unable to export the repository signing key'
	fi
	printf '%s\n' "$key_id"
}

sign_repository_metadata() {
	local key_id=$1

	while IFS= read -r release_file; do
		if [[ -z $release_file ]]; then
			continue
		fi
		local release_dir
		release_dir="$(dirname -- "$release_file")"
		gpg --homedir "$WORK_DIR/gnupg" --batch --yes --clearsign --local-user "$key_id" --output "$release_dir/InRelease" "$release_file"
		gpg --homedir "$WORK_DIR/gnupg" --batch --yes --detach-sign --local-user "$key_id" --output "$release_dir/Release.gpg" "$release_file"
	done < <(find "$OUT_DIR/dists" -name 'Release' -type f | sort)
}

write_release_manifest() {
	local manifest_file=$1
	local selected_file=$2
	local newest_release
	newest_release="$(tail --lines=1 "$selected_file" | newest_release_snapshot)"

	jq --slurp \
		--arg api_repo "$API_REPO" \
		--arg generated_at "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" \
		--arg package_name "$PACKAGE_NAME" \
		--argjson max_bytes "$MAX_BYTES" \
		--argjson newest_release "$newest_release" \
		'map(del(.package_path, .cache_key)) | '"$RELEASES_MANIFEST_FILTER" \
		"$manifest_file" >"$OUT_DIR/releases.json"
}

measure_pages_artifact_bytes() {
	tar \
		--dereference --hard-dereference \
		--directory "$OUT_DIR" \
		--create --file=- \
		. | wc --bytes
}

copy_site_documents() {
	cp "$INDEX_TEMPLATE" "$OUT_DIR/index.html"
	cp "$ROOT_DIR/LICENSE" "$OUT_DIR/LICENSE"
	cp "$ROOT_DIR/SECURITY.md" "$OUT_DIR/SECURITY.md"
	cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$OUT_DIR/THIRD_PARTY_NOTICES.md"
}

refresh_repository_metadata() {
	local selected_file=$1
	local manifest_file=$2
	local key_id=$3

	# A previous metadata tree can contain package indices and signatures for
	# releases evicted during this run.  Remove it before apt-ftparchive scans
	# the pool so that Release only describes the retained repository.
	rm --recursive --force "$OUT_DIR/dists"
	generate_apt_metadata "$manifest_file"
	sign_repository_metadata "$key_id"
	write_release_manifest "$manifest_file" "$selected_file"
}

enforce_pages_size_limit() {
	local candidates_file=$1
	local selected_file=$2
	local manifest_file=$3

	if [[ ! -s $candidates_file ]]; then
		fail 'no stable release candidates'
	fi
	local candidate_manifest_file="$WORK_DIR/retention-candidate-manifest.ndjson"
	local total_package_bytes=0
	local retained_release_count=0
	: >"$selected_file"
	: >"$manifest_file"
	rm --recursive --force "$OUT_DIR"
	mkdir --parents "$OUT_DIR"

	# Candidates are newest-first. Prepare that prefix once, then publish only the
	# releases that fit the package budget.
	local release_json
	while IFS= read -r release_json; do
		if [[ -z $release_json ]]; then
			continue
		fi
		if ((total_package_bytes == MAX_BYTES)); then
			break
		fi

		prepare_release_packages "$release_json" "$candidate_manifest_file"
		if [[ ! -s $candidate_manifest_file ]]; then
			fail "release $(jq --raw-output '.tag_name // .id' <<<"$release_json") produced no packages"
		fi

		local release_package_bytes
		release_package_bytes="$(jq --slurp 'map(.package_size) | add' "$candidate_manifest_file")"
		if ((release_package_bytes > MAX_BYTES - total_package_bytes)); then
			if ((retained_release_count == 0)); then
				fail "latest stable release $(jq --raw-output '.tag_name // .id' <<<"$release_json") exceeds MAX_BYTES=$MAX_BYTES in upstream packages"
			fi
			break
		fi

		printf '%s\n' "$release_json" >>"$selected_file"
		cat "$candidate_manifest_file" >>"$manifest_file"
		total_package_bytes=$((total_package_bytes + release_package_bytes))
		retained_release_count=$((retained_release_count + 1))
	done <"$candidates_file"

	if ((retained_release_count == 0)); then
		fail 'no stable releases fit within the package size limit'
	fi

	# Restore oldest-first ordering once, after appending candidates newest-first.
	local order_tmp
	order_tmp="$(mktemp)"
	jq --compact-output --slurp 'reverse[]' "$selected_file" >"$order_tmp"
	mv -- "$order_tmp" "$selected_file"
	jq --compact-output --slurp 'reverse[]' "$manifest_file" >"$candidate_manifest_file"
	mv -- "$candidate_manifest_file" "$manifest_file"
	publish_manifest_packages "$manifest_file"
	copy_site_documents
	local key_id
	key_id="$(initialize_repository_signing)"
	refresh_repository_metadata "$selected_file" "$manifest_file" "$key_id"
	local artifact_bytes
	while :; do
		artifact_bytes="$(measure_pages_artifact_bytes)"
		if ((artifact_bytes < MAX_BYTES)); then
			break
		fi

		evict_oldest_release "$selected_file" "$manifest_file"
		refresh_repository_metadata "$selected_file" "$manifest_file" "$key_id"
	done
}

main() {
	if [[ ${1:-} == '--check-newest-release' ]]; then
		if (($# != 2)); then
			fail "usage: $SCRIPT_NAME --check-newest-release URL"
		fi
		require_command curl
		require_command jq
		check_newest_release_changed "$2"
		return
	fi
	if (($# != 0)); then
		fail "usage: $SCRIPT_NAME [--check-newest-release URL]"
	fi

	local required_command_name
	for required_command_name in \
		apt-ftparchive \
		awk \
		curl \
		date \
		dpkg-deb \
		find \
		gpg \
		gzip \
		install \
		jq \
		mktemp \
		mv \
		perl \
		rmdir \
		sed \
		sha256sum \
		stat \
		tar \
		touch \
		wc; do
		require_command "$required_command_name"
	done
	if [[ ! $PACKAGE_CACHE_EXTRA_BYTES =~ ^[0-9]+$ ]]; then
		fail "PACKAGE_CACHE_EXTRA_BYTES must be a non-negative integer: $PACKAGE_CACHE_EXTRA_BYTES"
	fi
	if [[ ! $MAX_BYTES =~ ^[1-9][0-9]*$ ]]; then
		fail "MAX_BYTES must be a positive integer: $MAX_BYTES"
	fi

	rm --recursive --force "$WORK_DIR" "$OUT_DIR"
	mkdir --parents "$WORK_DIR" "$OUT_DIR" "$CACHE_DIR"

	local releases_file="$WORK_DIR/releases.ndjson"
	local selected_file="$WORK_DIR/selected.ndjson"
	local manifest_file="$WORK_DIR/manifest.ndjson"
	if ! collect_stable_releases >"$releases_file"; then
		fail 'unable to collect stable releases'
	fi
	local candidates_file="$WORK_DIR/candidates.ndjson"
	select_release_candidates "$releases_file" "$candidates_file"
	enforce_pages_size_limit "$candidates_file" "$selected_file" "$manifest_file"
	prune_package_cache "$manifest_file" "$PACKAGE_CACHE_EXTRA_BYTES"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
