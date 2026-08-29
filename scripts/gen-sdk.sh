#!/usr/bin/env bash
# Generate the $LANGUAGE SDK from "$SCHEMA" into "$OUT/$LANGUAGE", post-processed
# to be publishable as-is.
set -euo pipefail

die() {
	echo "::error::$1"
	exit 1
}

case "${LANGUAGE:-}" in
go | nodejs | python | dotnet | java) ;;
"") die "language is required in gen-sdk mode" ;;
*) die "invalid language '$LANGUAGE'; expected go, nodejs, python, dotnet, or java" ;;
esac
command -v pulumi >/dev/null ||
	die "pulumi CLI not found on PATH; install it first (e.g. with pulumi/actions)"

pulumi package gen-sdk "$SCHEMA" --language "$LANGUAGE" --out "$OUT"

case "$LANGUAGE" in
dotnet)
	# The generated .csproj packs logo.png as the NuGet package icon, and NuGet
	# requires a raster image. Codegen fills logo.png with the schema's logoUrl
	# bytes verbatim (or not at all, on older CLIs), and the Pulumi registry
	# prefers an SVG logoUrl — so fetch the logo if it is missing, then
	# rasterize it if it is not already a PNG.
	if grep -q 'logo\.png' "$OUT"/dotnet/*.csproj 2>/dev/null; then
		LOGO="$OUT/dotnet/logo.png"
		if [ ! -f "$LOGO" ]; then
			LOGO_URL="$(jq -r '.logoUrl // empty' "$SCHEMA")"
			[ -n "$LOGO_URL" ] ||
				die "the generated .csproj packs logo.png but the schema has no logoUrl to fetch it from; set logoUrl in the schema"
			curl -fsSL "$LOGO_URL" -o "$LOGO"
		fi
		if [ "$(file --brief --mime-type "$LOGO")" != image/png ]; then
			if ! command -v rsvg-convert >/dev/null; then
				sudo apt-get update -qq
				sudo apt-get install -qq -y librsvg2-bin
			fi
			SRC="$(mktemp)"
			mv "$LOGO" "$SRC"
			rsvg-convert --width 128 --keep-aspect-ratio --output "$LOGO" "$SRC" ||
				die "could not convert the schema's logoUrl to PNG; logoUrl must point at a PNG or SVG image"
		fi
	fi
	;;
esac
