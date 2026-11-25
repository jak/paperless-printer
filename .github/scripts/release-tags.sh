#!/bin/bash
# release-tags.sh TAG IMAGE -> comma-separated image tags to publish TAG under.
#
# vX.Y.Z always gets X.Y.Z; it also gets the floating X.Y, X and latest tags only while it is
# the newest stable release in that line, so a backport (v1.9.1 after v2.0.0) or a late
# rebuild of an older release never moves them backwards. Reads tags from the local clone,
# so fetch tags first. Pre-releases (vX.Y.Z-rc.1) get only their exact version.
set -euo pipefail
tag=$1 image=$2
[[ $tag =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?$ ]] ||
  { echo "'$tag' is not vMAJOR.MINOR.PATCH[-pre]" >&2; exit 1; }
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} pre=${BASH_REMATCH[4]}
tags="$image:${tag#v}"
if [[ -z $pre ]]; then
  stable=$(git tag --list 'v*.*.*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V || true)
  newest_in() { grep -E "^v$1" <<<"$stable" | tail -n1; }
  [[ $(newest_in "${major}\.${minor}\.") == "$tag" ]] && tags+=",$image:$major.$minor"
  [[ $(newest_in "${major}\.") == "$tag" ]] && tags+=",$image:$major"
  [[ $(tail -n1 <<<"$stable") == "$tag" ]] && tags+=",$image:latest"
fi
printf '%s\n' "$tags"
