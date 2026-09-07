#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

readonly SCRIPT_NAME
readonly ROOT_DIR
readonly WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build/sunshine-apt}"
readonly OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
readonly API_REPO="${API_REPO:-LizardByte/Sunshine}"
readonly API_URL="https://api.github.com/repos/$API_REPO/releases"
readonly MAX_BYTES="${MAX_BYTES:-1000000000}"
readonly USER_AGENT='sunshine-apt-sync'
readonly INDEX_TEMPLATE="$ROOT_DIR/templates/index.html"
readonly RELEASES_MANIFEST_FILTER='
{
	source_repo: $api_repo,
	generated_at: $generated_at,
	max_bytes: $max_bytes,
	newest_release: $newest_release,
	mirrored_assets: .
}
'

fail() {
	echo "$1" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

github_api_get() {
	local url=$1
	local args=(
		-fsSL
		-H "Accept: application/vnd.github+json"
		-H "User-Agent: $USER_AGENT"
	)

	[[ -n ${GITHUB_TOKEN:-} ]] && args+=(-H "Authorization: Bearer $GITHUB_TOKEN")

	curl "${args[@]}" "$url"
}

normalize_release_file() {
	local source=$1
	local target=$2
	local suite=$3
	SUITE="$suite" perl -0pe '
		s/^Suite: .*/Suite: $ENV{SUITE}/m;
		s/^Codename: .*/Codename: $ENV{SUITE}/m;
		s/^Origin: .*/Origin: Unofficial Sunshine Mirror/m;
		s/^Label: .*/Label: Unofficial Sunshine Mirror/m;
		s/^Description: .*/Description: Unofficial mirror of Sunshine upstream APT packages/m;
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

release_deb_count() {
	jq '[.assets[] | select(.name | endswith(".deb"))] | length'
}

validate_release_assets() {
	local release_json=$1

	while IFS= read -r name; do
		[[ -n $name ]] || continue
		suite_from_filename "$name" >/dev/null || fail "unrecognized .deb naming scheme: $name"
	done < <(jq -r '.assets[] | select(.name | endswith(".deb")) | .name' <<<"$release_json")
}

release_deb_bytes() {
	jq '[.assets[] | select(.name | endswith(".deb")) | .size] | add // 0'
}

collect_stable_releases() {
	local releases_file=$1
	: >"$releases_file"

	local page=1
	local page_size=100
	while :; do
		local payload
		payload="$(github_api_get "$API_URL?per_page=$page_size&page=$page")"

		local count
		count="$(jq 'length' <<<"$payload")"
		[[ $count -eq 0 ]] && break

		jq -c '.[] | select(.draft | not) | select(.prerelease | not)' <<<"$payload" >>"$releases_file"
		((page += 1))

		[[ $count -lt $page_size ]] && break
	done
}

newest_release_snapshot() {
	jq -S -c '{
		release_id: (.id | tostring),
		tag_name,
		assets: [
			.assets[] | select(.name | endswith(".deb")) | {
				asset_id: (.id | tostring),
				name,
				size,
				updated_at,
				browser_download_url,
				content_type,
				state,
				digest
			}
		] | sort_by(.asset_id)
	}'
}

check_newest_release_changed() {
	local previous_manifest_url=$1
	local releases_file
	releases_file="$(mktemp)"

	collect_stable_releases "$releases_file"
	[[ -s $releases_file ]] || fail 'no stable releases found'

	local current_snapshot
	current_snapshot="$(head -n 1 "$releases_file" | newest_release_snapshot)"
	rm -f "$releases_file"

	local previous_manifest
	if ! previous_manifest="$(curl -fsSL -H "User-Agent: $USER_AGENT" "$previous_manifest_url")"; then
		printf '%s\n' 'true'
		return
	fi

	local previous_snapshot
	if ! previous_snapshot="$(jq -e -S -c '.newest_release' <<<"$previous_manifest" 2>/dev/null)"; then
		printf '%s\n' 'true'
		return
	fi
	if [[ -z $previous_snapshot || $previous_snapshot != "$current_snapshot" ]]; then
		printf '%s\n' 'true'
		return
	fi

	printf '%s\n' 'false'
}

write_release_list() {
	local selected_file=$1
	shift
	: >"$selected_file"

	local release_json
	for release_json in "$@"; do
		printf '%s\n' "$release_json" >>"$selected_file"
	done
}

select_retained_releases() {
	local releases_file=$1
	local selected_file=$2

	mapfile -t releases <"$releases_file"
	[[ ${#releases[@]} -eq 0 ]] && fail 'no stable releases found'
	[[ "$(release_deb_count <<<"${releases[0]}")" -eq 0 ]] && fail 'latest stable release has no .deb assets'

	local selected_releases=()
	local selected_bytes=()
	local total_bytes=0
	local idx
	for ((idx = ${#releases[@]} - 1; idx >= 0; idx--)); do
		local release_json=${releases[idx]}
		local deb_count
		deb_count="$(release_deb_count <<<"$release_json")"
		[[ $deb_count -eq 0 ]] && continue

		validate_release_assets "$release_json"

		local deb_bytes
		deb_bytes="$(release_deb_bytes <<<"$release_json")"
		((deb_bytes > MAX_BYTES)) && fail "release $(jq -r '.tag_name' <<<"$release_json") exceeds MAX_BYTES=$MAX_BYTES"

		while ((${#selected_releases[@]} > 0)) && ((MAX_BYTES - total_bytes < deb_bytes)); do
			total_bytes=$((total_bytes - selected_bytes[0]))
			selected_releases=("${selected_releases[@]:1}")
			selected_bytes=("${selected_bytes[@]:1}")
		done

		selected_releases+=("$release_json")
		selected_bytes+=("$deb_bytes")
		total_bytes=$((total_bytes + deb_bytes))
	done

	[[ ${#selected_releases[@]} -eq 0 ]] && fail 'no stable releases selected'

	write_release_list "$selected_file" "${selected_releases[@]}"
}

evict_oldest_release() {
	local selected_file=$1
	local tmp_file
	tmp_file="$(mktemp)"

	if ! tail -n +2 "$selected_file" >"$tmp_file"; then
		rm -f "$tmp_file"
		return 1
	fi

	mv "$tmp_file" "$selected_file"
	[[ ! -s $selected_file ]] && fail 'cannot evict the final retained release'
}

download_selected_assets() {
	local selected_file=$1
	local manifest_file=$2

	mkdir -p "$WORK_DIR/downloads"
	: >"$manifest_file"

	while IFS= read -r release_json; do
		[[ -n $release_json ]] || continue

		local release_id
		release_id="$(jq -r '.id' <<<"$release_json")"
		local tag_name
		tag_name="$(jq -r '.tag_name' <<<"$release_json")"
		local published_at
		published_at="$(jq -r '.published_at' <<<"$release_json")"
		local release_page_url
		release_page_url="$(jq -r '.html_url' <<<"$release_json")"
		local source_tarball_url
		source_tarball_url="$(jq -r '.tarball_url' <<<"$release_json")"
		local source_zipball_url
		source_zipball_url="$(jq -r '.zipball_url' <<<"$release_json")"

		while IFS= read -r asset_json; do
			[[ -n $asset_json ]] || continue

			local name
			name="$(jq -r '.name' <<<"$asset_json")"
			local suite
			suite="$(suite_from_filename "$name")"
			local arch=''
			arch_from_filename "$name" >/dev/null && arch="$(arch_from_filename "$name")"
			local url
			local size
			url="$(jq -r '.browser_download_url' <<<"$asset_json")"
			size="$(jq -r '.size' <<<"$asset_json")"
			local destination
			destination="$WORK_DIR/downloads/$release_id/$name"

			mkdir -p "$(dirname -- "$destination")"
			[[ -f $destination ]] || curl -fsSL -H "User-Agent: $USER_AGENT" -o "$destination" "$url"

			local package_name
			package_name="$(dpkg-deb -f "$destination" Package)"
			local version
			version="$(dpkg-deb -f "$destination" Version)"
			local package_arch
			package_arch="$(dpkg-deb -f "$destination" Architecture)"

			[[ $package_name == 'sunshine' ]] || fail "unexpected package name in $name: $package_name"
			[[ -z $arch || $package_arch == "$arch" ]] || fail "architecture mismatch for $name: expected $arch got $package_arch"
			arch="$package_arch"

			local out_pool="$OUT_DIR/pool/main/s/sunshine/$suite/$arch/$release_id"
			mkdir -p "$out_pool"
			cp "$destination" "$out_pool/$name"

			jq -nc \
				--arg release_id "$release_id" \
				--arg tag_name "$tag_name" \
				--arg published_at "$published_at" \
				--arg release_page_url "$release_page_url" \
				--arg source_tarball_url "$source_tarball_url" \
				--arg source_zipball_url "$source_zipball_url" \
				--arg suite "$suite" \
				--arg arch "$arch" \
				--arg name "$name" \
				--arg url "$url" \
				--arg version "$version" \
				--arg package_name "$package_name" \
				--arg package_arch "$package_arch" \
				--arg pool_path "pool/main/s/sunshine/$suite/$arch/$release_id/$name" \
				--arg sha256 "$(sha256sum "$destination" | awk '{print $1}')" \
				--argjson size "$size" \
				'{
					release_id: $release_id,
					tag_name: $tag_name,
					published_at: $published_at,
					release_page_url: $release_page_url,
					source_tarball_url: $source_tarball_url,
					source_zipball_url: $source_zipball_url,
					suite: $suite,
					arch: $arch,
					asset_name: $name,
					browser_download_url: $url,
					size: $size,
					package_name: $package_name,
					package_arch: $package_arch,
					version: $version,
					pool_path: $pool_path,
					sha256: $sha256
				}' >>"$manifest_file"
		done < <(jq -c '.assets[] | select(.name | endswith(".deb"))' <<<"$release_json")
	done <"$selected_file"
}

generate_apt_metadata() {
	local manifest_file=$1

	mapfile -t suites < <(jq -r '.suite' "$manifest_file" | sort -u)
	local suite
	for suite in "${suites[@]}"; do
		[[ -n $suite ]] || continue
		mapfile -t arches < <(jq -r --arg suite "$suite" 'select(.suite == $suite) | .arch' "$manifest_file" | sort -u)

		local arch
		for arch in "${arches[@]}"; do
			[[ -n $arch ]] || continue
			local binary_dir="$OUT_DIR/dists/$suite/main/binary-$arch"
			local pool_dir="pool/main/s/sunshine/$suite/$arch"
			mkdir -p "$binary_dir"
			(
				cd "$OUT_DIR"
				apt-ftparchive packages "$pool_dir" >"$binary_dir/Packages"
			)
			gzip -9c "$binary_dir/Packages" >"$binary_dir/Packages.gz"
		done

		local suite_dir="$OUT_DIR/dists/$suite"
		local release_raw="$WORK_DIR/${suite//\//_}.Release.raw"
		apt-ftparchive \
			-o "APT::FTPArchive::Release::Origin=Unofficial Sunshine Mirror" \
			-o "APT::FTPArchive::Release::Label=Unofficial Sunshine Mirror" \
			-o "APT::FTPArchive::Release::Suite=$suite" \
			-o "APT::FTPArchive::Release::Codename=$suite" \
			-o "APT::FTPArchive::Release::Architectures=${arches[*]}" \
			-o "APT::FTPArchive::Release::Components=main" \
			-o "APT::FTPArchive::Release::Description=Unofficial mirror of Sunshine upstream APT packages" \
			release "$suite_dir" >"$release_raw"
		normalize_release_file "$release_raw" "$suite_dir/Release" "$suite"
		rm -f "$release_raw"
	done
}

sign_repository_metadata() {
	[[ -n ${APT_GPG_PRIVATE_KEY:-} ]] || fail 'APT_GPG_PRIVATE_KEY is required'

	export GNUPGHOME="$WORK_DIR/gnupg"
	rm -rf "$GNUPGHOME"
	mkdir -p "$GNUPGHOME"
	chmod 700 "$GNUPGHOME"

	gpg --batch --import <<<"$APT_GPG_PRIVATE_KEY" >/dev/null 2>&1

	local key_id
	key_id="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^sec:/ { print $5; exit }')"
	[[ -n $key_id ]] || fail 'no secret key available after import'

	gpg --batch --yes --export "$key_id" >"$OUT_DIR/sunshine-archive-keyring.gpg"

	while IFS= read -r release_file; do
		[[ -n $release_file ]] || continue
		local release_dir
		release_dir="$(dirname -- "$release_file")"
		gpg --batch --yes --clearsign -u "$key_id" -o "$release_dir/InRelease" "$release_file"
		gpg --batch --yes --detach-sign -u "$key_id" -o "$release_dir/Release.gpg" "$release_file"
	done < <(find "$OUT_DIR/dists" -name Release -type f | sort)
}

write_release_manifest() {
	local manifest_file=$1
	local selected_file=$2
	local newest_release
	newest_release="$(tail -n 1 "$selected_file" | newest_release_snapshot)"

	jq -s \
		--arg api_repo "$API_REPO" \
		--arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--argjson max_bytes "$MAX_BYTES" \
		--argjson newest_release "$newest_release" \
		"$RELEASES_MANIFEST_FILTER" \
		"$manifest_file" >"$OUT_DIR/releases.json"
}

measure_pages_artifact_bytes() {
	local archive="$WORK_DIR/pages-size-check.tar"
	rm -f "$archive"
	tar \
		--dereference --hard-dereference \
		--directory "$OUT_DIR" \
		-cf "$archive" \
		.
	stat -c '%s' "$archive"
	rm -f "$archive"
}

build_repository() {
	local selected_file=$1
	local manifest_file=$2

	rm -rf "$OUT_DIR"
	mkdir -p "$OUT_DIR"

	download_selected_assets "$selected_file" "$manifest_file"
	generate_apt_metadata "$manifest_file"
	sign_repository_metadata
	write_release_manifest "$manifest_file" "$selected_file"

	cp "$INDEX_TEMPLATE" "$OUT_DIR/index.html"
}

enforce_pages_size_limit() {
	local selected_file=$1
	local manifest_file=$2

	build_repository "$selected_file" "$manifest_file"
	while (($(measure_pages_artifact_bytes) >= MAX_BYTES)); do
		evict_oldest_release "$selected_file"
		build_repository "$selected_file" "$manifest_file"
	done
}

main() {
	if [[ ${1:-} == '--check-newest-release' ]]; then
		[[ $# -eq 2 ]] || fail "usage: $SCRIPT_NAME --check-newest-release URL"
		require_command curl
		require_command jq
		check_newest_release_changed "$2"
		return
	fi
	[[ $# -eq 0 ]] || fail "usage: $SCRIPT_NAME [--check-newest-release URL]"

	local required_command_name
	for required_command_name in \
		apt-ftparchive \
		curl \
		dpkg-deb \
		gpg \
		gzip \
		jq \
		perl \
		sha256sum \
		stat \
		tar; do
		require_command "$required_command_name"
	done

	rm -rf "$WORK_DIR" "$OUT_DIR"
	mkdir -p "$WORK_DIR" "$OUT_DIR"

	local releases_file="$WORK_DIR/releases.ndjson"
	local selected_file="$WORK_DIR/selected.ndjson"
	local manifest_file="$WORK_DIR/manifest.ndjson"

	collect_stable_releases "$releases_file"
	select_retained_releases "$releases_file" "$selected_file"
	enforce_pages_size_limit "$selected_file" "$manifest_file"
}

main "$@"
