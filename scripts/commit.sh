#!/usr/bin/env bash
# Commit the staged artifacts tree ("$STAGE": schema.json plus sdk-<language>
# artifact directories) onto "$BRANCH", and record the mapping from the source
# commit (HEAD) to the artifacts commit as a git note in refs/notes/$BRANCH.
#
# Safe to run concurrently: branch and notes pushes retry on races, and a
# source commit that is already recorded is skipped.
set -euo pipefail

die() {
	echo "::error::$1"
	exit 1
}

git rev-parse --git-dir >/dev/null 2>&1 ||
	die "commit mode must run inside a checkout of the repository (use actions/checkout first)"
git check-ref-format "refs/heads/$BRANCH" || die "invalid branch name '$BRANCH'"
[ -f "$STAGE/schema.json" ] ||
	die "no schema.json staged; did a schema-mode job run earlier in this workflow?"

DEFAULT_BRANCH="$(git ls-remote --symref origin HEAD |
	awk '$1 == "ref:" { sub("^refs/heads/", "", $2); print $2 }')"
[ -n "$DEFAULT_BRANCH" ] || die "could not determine the default branch of origin"
[ "$BRANCH" != "$DEFAULT_BRANCH" ] ||
	die "refusing to write artifacts over the default branch '$DEFAULT_BRANCH'"

SRC_SHA="$(git rev-parse HEAD)"
NOTES_REF="refs/notes/$BRANCH"

export GIT_AUTHOR_NAME="github-actions[bot]"
export GIT_AUTHOR_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# Make the local notes ref mirror origin exactly; a stale local note must not
# mask a failed push.
fetch_notes() {
	git update-ref -d "$NOTES_REF" 2>/dev/null || true
	git fetch origin "+$NOTES_REF:$NOTES_REF" 2>/dev/null || true
}

recorded() { git notes --ref="$BRANCH" show "$SRC_SHA" 2>/dev/null; }

fetch_notes
if ARTIFACTS_SHA="$(recorded)"; then
	echo "Artifacts for $SRC_SHA already recorded as $ARTIFACTS_SHA; skipping." \
		"Delete the note to force regeneration."
	echo "commit=$ARTIFACTS_SHA" >>"${GITHUB_OUTPUT:-/dev/null}"
	exit 0
fi

# The sdk-<language> artifact names become sdk/<language> directories.
shopt -s nullglob
for d in "$STAGE"/sdk/sdk-*/; do
	d="${d%/}"
	mv "$d" "$STAGE/sdk/${d##*/sdk-}"
done
shopt -u nullglob

# Build the tree from the staging directory with a throwaway index, leaving the
# real index and working tree untouched.
GIT_DIR="$(git rev-parse --absolute-git-dir)"
export GIT_DIR
export GIT_WORK_TREE="$STAGE"
export GIT_INDEX_FILE="$STAGE.index"
# -f: a .gitignore inside a generated SDK must not filter its siblings out of
# the committed tree.
(cd "$STAGE" && git add -Af .)
TREE="$(git write-tree)"
unset GIT_WORK_TREE GIT_INDEX_FILE

MSG="Regenerate for $SRC_SHA

Source-Commit: $SRC_SHA"

ARTIFACTS_SHA=""
for attempt in 1 2 3 4 5; do
	if PARENT="$(git ls-remote --exit-code origin "refs/heads/$BRANCH" | cut -f1)"; then
		git fetch --depth 1 origin "$PARENT"
		COMMIT="$(git commit-tree "$TREE" -p "$PARENT" -m "$MSG")"
	else
		COMMIT="$(git commit-tree "$TREE" -m "$MSG")"
	fi
	if git push origin "$COMMIT:refs/heads/$BRANCH"; then
		ARTIFACTS_SHA="$COMMIT"
		break
	fi
	echo "Push to $BRANCH raced with another run; retrying ($attempt/5)."
	sleep "$attempt"
done
[ -n "$ARTIFACTS_SHA" ] || die "could not push to '$BRANCH' after 5 attempts"

NOTED=""
for attempt in 1 2 3 4 5; do
	fetch_notes
	if EXISTING="$(recorded)"; then
		echo "Another run recorded $EXISTING for $SRC_SHA first; using it."
		ARTIFACTS_SHA="$EXISTING"
		NOTED=1
		break
	fi
	git notes --ref="$BRANCH" add -m "$ARTIFACTS_SHA" "$SRC_SHA"
	if git push origin "$NOTES_REF:$NOTES_REF"; then
		NOTED=1
		break
	fi
	echo "Notes push raced with another run; retrying ($attempt/5)."
	sleep "$attempt"
done
[ -n "$NOTED" ] || die "could not push '$NOTES_REF' after 5 attempts"

echo "commit=$ARTIFACTS_SHA" >>"${GITHUB_OUTPUT:-/dev/null}"
echo "Recorded artifacts commit $ARTIFACTS_SHA for source commit $SRC_SHA on '$BRANCH'."
