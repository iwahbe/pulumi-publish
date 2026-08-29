#!/usr/bin/env bash
# Resolve "$REF" to its artifacts commit on "$BRANCH" via the git note in
# refs/notes/$BRANCH, output it as `commit`, and optionally extract the
# artifacts tree into "$DEST".
set -euo pipefail

die() {
	echo "::error::$1"
	exit 1
}

git rev-parse --git-dir >/dev/null 2>&1 ||
	die "dump mode must run inside a checkout of the repository (use actions/checkout first)"
git check-ref-format "refs/heads/$BRANCH" || die "invalid branch name '$BRANCH'"

# Resolve against origin first so a stale local ref never wins; fall back to
# local resolution for expressions fetch cannot serve (HEAD~2, etc.).
if git fetch origin "$REF" 2>/dev/null; then
	SHA="$(git rev-parse 'FETCH_HEAD^{commit}')"
elif ! SHA="$(git rev-parse --verify --quiet "$REF^{commit}")"; then
	die "cannot resolve ref '$REF'; in a shallow CI checkout use a full SHA, tag, or branch name"
fi

NOTES_REF="refs/notes/$BRANCH"
git fetch origin "+$NOTES_REF:$NOTES_REF" 2>/dev/null ||
	die "no notes ref '$NOTES_REF' on origin; has commit mode ever run for branch '$BRANCH'?"
ARTIFACTS_SHA="$(git notes --ref="$BRANCH" show "$SHA" 2>/dev/null)" ||
	die "no artifacts recorded for $SHA on branch '$BRANCH'"

echo "commit=$ARTIFACTS_SHA" >>"${GITHUB_OUTPUT:-/dev/null}"
echo "Artifacts for $SHA: $ARTIFACTS_SHA"

if [ -n "${DEST:-}" ]; then
	git cat-file -e "$ARTIFACTS_SHA^{commit}" 2>/dev/null ||
		git fetch --depth 1 origin "$ARTIFACTS_SHA"
	mkdir -p "$DEST"
	git archive "$ARTIFACTS_SHA" | tar -x -C "$DEST"
	echo "Checked out the artifacts tree into '$DEST'."
fi
