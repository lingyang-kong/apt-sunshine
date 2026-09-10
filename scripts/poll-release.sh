#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

if [[ $# -ne 0 ]]; then
	printf 'usage: %s\n' "$(basename -- "$0")" >&2
	exit 2
fi

readonly PUBLISHED_MANIFEST_URL="${PUBLISHED_MANIFEST_URL:-https://lingyang-kong.github.io/apt-sunshine/releases.json}"
readonly FORCE_BUILD=${FORCE_BUILD:-false}
case $FORCE_BUILD in
true | false) ;;
*)
	printf 'FORCE_BUILD must be true or false\n' >&2
	exit 2
	;;
esac

SCRIPT_DIR="$(dirname -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR

if ! changed="$("$SCRIPT_DIR/sync-apt-repo.sh" --check-newest-release "$PUBLISHED_MANIFEST_URL")"; then
	printf 'newest release poll failed\n' >&2
	exit 1
fi

case $changed in
true | false) ;;
*)
	printf 'unexpected newest release poll result: %s\n' "$changed" >&2
	exit 1
	;;
esac

if [[ $FORCE_BUILD == true ]]; then
	changed=true
fi

printf '%s\n' "$changed"
