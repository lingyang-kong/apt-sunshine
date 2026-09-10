#!/usr/bin/env bash
# Cache verified upstream Debian packages without repacking them.
# PACKAGE_NAME and PACKAGE_CACHE_FORMAT are supplied by the publisher.
# shellcheck disable=SC2153

package_cache_key() {
	local asset_json=$1
	local release_id=$2
	local asset_identity
	# A verified digest identifies the bytes; provenance only identifies assets
	# that do not provide one. Publication metadata still comes from the release.
	if ! asset_identity="$(jq --sort-keys --compact-output --arg release_id "$release_id" '
		if (.digest // "") != "" then
			{sha256: (.digest | ltrimstr("sha256:") | ascii_downcase)}
		else
			{
				release_id: $release_id,
				asset_id: ((.id // "") | tostring),
				size: (.size // ""),
				url: (.browser_download_url // ""),
				updated_at: (.updated_at // "")
			}
		end' <<<"$asset_json")"; then
		return 1
	fi

	printf '%s\0' \
		"$PACKAGE_CACHE_FORMAT" \
		"$asset_identity" |
		sha256sum | awk '{print $1}'
}

normalize_sha256_digest() {
	local digest=${1#sha256:}
	digest=${digest,,}

	if [[ $digest =~ ^[[:xdigit:]]{64}$ ]]; then
		printf '%s\n' "$digest"
		return 0
	fi

	return 1
}

validate_upstream_asset() {
	local asset_path=$1
	local expected_size=$2
	local expected_digest=$3
	if [[ ! -f $asset_path ]]; then
		return 1
	fi
	local actual_size actual_digest
	if ! actual_size="$(stat --format='%s' "$asset_path")"; then
		return 1
	fi
	if [[ $actual_size != "$expected_size" ]]; then
		return 1
	fi
	if ! actual_digest="$(sha256sum "$asset_path" | awk '{print $1}')"; then
		return 1
	fi
	if [[ -n $expected_digest && $actual_digest != "$expected_digest" ]]; then
		return 1
	fi
	printf '%s\n' "$actual_digest"
}

download_upstream_asset() {
	local destination=$1
	local url=$2
	local size=$3
	local digest=$4

	local asset_sha256
	local destination_dir
	if ! destination_dir="$(dirname -- "$destination")"; then
		return 1
	fi
	if ! mkdir --parents "$destination_dir"; then
		return 1
	fi
	local temporary_download
	if ! temporary_download="$(mktemp "$destination_dir/.asset.XXXXXX")"; then
		return 1
	fi
	if ! curl \
		--fail \
		--silent \
		--show-error \
		--location \
		--header "User-Agent: $USER_AGENT" \
		--output "$temporary_download" \
		"$url"; then
		rm --force -- "$temporary_download"
		return 1
	fi
	if ! asset_sha256="$(validate_upstream_asset "$temporary_download" "$size" "$digest")"; then
		rm --force -- "$temporary_download"
		return 1
	fi
	if ! mv -- "$temporary_download" "$destination"; then
		rm --force -- "$temporary_download"
		return 1
	fi
	printf '%s\n' "$asset_sha256"
}

package_metadata() {
	local cache_key=$1
	local size=$2
	local sha256=$3
	local expected_arch=$4
	local fields package_name version arch
	# shellcheck disable=SC2016
	if ! fields="$(dpkg-deb --show --showformat='${Package}\t${Version}\t${Architecture}' "$CACHE_DIR/$cache_key/package.deb" 2>/dev/null)"; then
		return 1
	fi
	IFS=$'\t' read -r package_name version arch <<<"$fields"
	if [[ $package_name != "$PACKAGE_NAME" || -z $version || ! $arch =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
		return 1
	fi
	if [[ -n $expected_arch && $arch != "$expected_arch" ]]; then
		return 1
	fi
	jq --null-input --compact-output \
		--arg cache_key "$cache_key" \
		--arg package_name "$package_name" \
		--arg version "$version" \
		--arg package_arch "$arch" \
		--argjson package_size "$size" \
		--arg sha256 "$sha256" \
		'{cache_key: $cache_key, package_name: $package_name, version: $version,
		  package_arch: $package_arch, package_size: $package_size, sha256: $sha256}'
}

read_cached_package() {
	local cache_key=$1
	local size=$2
	local digest=$3
	local arch=$4
	local metadata_path="$CACHE_DIR/$cache_key/metadata.json"
	local recorded_digest actual_digest metadata
	if ! recorded_digest="$(jq --exit-status --raw-output --arg cache_key "$cache_key" \
		'select(.cache_key == $cache_key) | .sha256 | select(type == "string" and test("^[0-9a-f]{64}$"))' \
		"$metadata_path" 2>/dev/null)"; then
		return 1
	fi
	if [[ -n $digest && $digest != "$recorded_digest" ]]; then
		return 1
	fi
	if ! actual_digest="$(validate_upstream_asset "$CACHE_DIR/$cache_key/package.deb" "$size" "$recorded_digest")"; then
		return 1
	fi
	if ! metadata="$(package_metadata "$cache_key" "$size" "$actual_digest" "$arch")"; then
		return 1
	fi
	if ! touch -- "$metadata_path"; then
		return 1
	fi
	printf '%s\n' "$metadata"
}

record_cached_package() {
	local cache_key=$1
	local size=$2
	local sha256=$3
	local arch=$4
	local metadata temporary_metadata
	if ! metadata="$(package_metadata "$cache_key" "$size" "$sha256" "$arch")"; then
		return 1
	fi
	if ! temporary_metadata="$(mktemp "$CACHE_DIR/$cache_key/.metadata.XXXXXX")"; then
		return 1
	fi
	if ! printf '%s\n' "$metadata" >"$temporary_metadata" ||
		! mv -- "$temporary_metadata" "$CACHE_DIR/$cache_key/metadata.json"; then
		rm --force -- "$temporary_metadata"
		return 1
	fi
	printf '%s\n' "$metadata"
}

prune_package_cache() {
	local manifest_file=$1
	local extra_budget=$2
	if [[ ! -d $CACHE_DIR ]]; then
		return 0
	fi
	local -A retained_keys=()
	local cache_key
	local manifest_keys
	if ! manifest_keys="$(jq --raw-output '.cache_key // empty' "$manifest_file")"; then
		return 1
	fi
	while IFS= read -r cache_key; do
		if [[ $cache_key =~ ^[[:xdigit:]]{64}$ ]]; then
			retained_keys[${cache_key,,}]=1
		fi
	done <<<"$manifest_keys"

	local candidates
	candidates="$(
		local entry_dir metadata_path package_path modified_at package_bytes
		for entry_dir in "$CACHE_DIR"/*; do
			if [[ ! -d $entry_dir ]]; then
				continue
			fi
			cache_key=${entry_dir##*/}
			if [[ ! $cache_key =~ ^[[:xdigit:]]{64}$ ]]; then
				continue
			fi
			if [[ -n ${retained_keys[${cache_key,,}]+present} ]]; then
				continue
			fi
			metadata_path="$entry_dir/metadata.json"
			if [[ ! -f $metadata_path ]]; then
				rm --recursive --force -- "$entry_dir"
				continue
			fi
			if ! jq --exit-status 'type == "object"' "$metadata_path" >/dev/null 2>&1; then
				rm --recursive --force -- "$entry_dir"
				continue
			fi
			package_path="$(find "$entry_dir" -maxdepth 1 -type f -name '*.deb' -print -quit)"
			if [[ ! -f $package_path ]]; then
				rm --recursive --force -- "$entry_dir"
				continue
			fi
			if ! package_bytes="$(stat --format='%s' "$package_path")"; then
				return 1
			fi
			if ! modified_at="$(stat --format='%Y' "$metadata_path")"; then
				return 1
			fi
			printf '%s\t%s\t%s\n' "$modified_at" "$package_bytes" "$entry_dir"
		done | sort --numeric-sort --reverse --key=1,1
	)"

	local extra_bytes=0
	local modified_at package_size entry_dir
	while IFS=$'\t' read -r modified_at package_size entry_dir; do
		if [[ -z $entry_dir ]]; then
			continue
		fi
		if ((extra_bytes + package_size <= extra_budget)); then
			extra_bytes=$((extra_bytes + package_size))
			continue
		fi
		if ! rm --recursive --force -- "$entry_dir"; then
			return 1
		fi
	done <<<"$candidates"
}
