#!/usr/bin/env bash
# Extract the package schema from a provider binary into "$OUT/schema.json".
set -euo pipefail

die() {
	echo "::error::$1"
	exit 1
}

command -v pulumi >/dev/null ||
	die "pulumi CLI not found on PATH; install it first (e.g. with pulumi/actions)"
[ -n "${PROVIDER_PATH:-}" ] || die "provider-path is required in schema mode"
[ -f "$PROVIDER_PATH" ] || die "provider binary '$PROVIDER_PATH' does not exist"
[ -x "$PROVIDER_PATH" ] || die "provider binary '$PROVIDER_PATH' is not executable"

mkdir -p "$OUT"
pulumi package get-schema "$PROVIDER_PATH" >"$OUT/schema.json"

NAME="$(jq -r '.name // empty' "$OUT/schema.json")"
VERSION="$(jq -r '.version // empty' "$OUT/schema.json")"
[ -n "$VERSION" ] ||
	die "the schema reported by '$PROVIDER_PATH' has no version, so its SDKs would not be publishable; build the provider with a version embedded"

echo "Generated schema for $NAME v$VERSION"
