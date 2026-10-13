#!/usr/bin/env bash
# Renders and packs the release bundle on the runner:
#
#   build-bundle.sh [--pin <pins.env>] <extra-vars.json> <bundle.tgz>
#
# release.yml renders the stack files and per-container env files from the
# extra vars; this script refuses unpinned third-party images, applies the
# rollback pins (release-images.sh resolve writes pins.env), writes release.env
# and manifest.sha256, and packs a deterministic tgz of file entries only.
# infra-apply on the host checks all of it again. Never prints a secret.
set -euo pipefail

usage() {
  printf 'usage: build-bundle.sh [--pin <pins.env>] <extra-vars.json> <bundle.tgz>\n' >&2
  exit 64
}

fail() {
  printf 'build-bundle: %s\n' "$*" >&2
  exit 1
}

here="$(cd "$(dirname "$0")" && pwd)"
pins=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pin)
      [ "$#" -ge 2 ] || usage
      pins="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
      shift 2
      ;;
    --*) usage ;;
    *) break ;;
  esac
done
[ "$#" -eq 2 ] || usage

readonly image_keys=(PORTFOLIO_IMAGE PROVIDER_IMAGE WEB_IMAGE)
readonly app_ref_pattern='^[a-z0-9.-]+(/[a-z0-9._-]+)+(:latest|:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64})$'
extra_vars="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
output="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
[ -f "$extra_vars" ] || fail "$1 does not exist"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bundle="$work/bundle"

env_file_for() {
  case "$1" in
    PORTFOLIO_IMAGE) printf 'portfolio/.env\n' ;;
    PROVIDER_IMAGE | WEB_IMAGE) printf 'hypernova/.env\n' ;;
  esac
}

image_repository() {
  local ref="${1%@*}"
  if [[ "${ref##*/}" == *:* ]]; then
    ref="${ref%:*}"
  fi
  printf '%s\n' "$ref"
}

pin_value() {
  local key="$1" count
  count="$(grep -c "^$key=" "$pins" || true)"
  [ "$count" -eq 1 ] || fail "$pins must set $key exactly once"
  sed -n "s/^$key=//p" "$pins"
}

check_pins() {
  local key value digests=0
  [ -f "$pins" ] || fail "$pins does not exist"
  [ "$(grep -c '' "$pins" || true)" -eq 4 ] ||
    fail "$pins must hold exactly RELEASE_MODE=pinned and the PORTFOLIO_IMAGE, PROVIDER_IMAGE and WEB_IMAGE lines"
  [ "$(pin_value RELEASE_MODE)" = pinned ] || fail "$pins must set RELEASE_MODE=pinned"
  for key in "${image_keys[@]}"; do
    value="$(pin_value "$key")"
    [[ "$value" =~ $app_ref_pattern ]] ||
      fail "$pins $key is neither <repository>:latest nor <repository>:<tag>@sha256:<digest>"
    if [[ "$value" == *@sha256:* ]]; then
      digests=$((digests + 1))
    fi
  done
  [ "$digests" -gt 0 ] || fail "$pins pins no image to a digest; a release that follows :latest is resume, not rollback"
}

# Every literal image: line in a stack or role compose file must be
# <repo>:<tag>@sha256:<digest>, one version per repository across files.
third_party_pins() {
  local file ref repo
  local -A seen=()
  for file in "$here"/stack/*/docker-compose.yml "$here"/roles/*/files/docker-compose.yml; do
    [ -f "$file" ] || continue
    while read -r ref; do
      [[ "$ref" =~ ^[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]] ||
        fail "${file#"$here"/} runs $ref, which is not pinned to a tag and a digest (RUNBOOK.md, \"Re-pinning third-party images\")"
      repo="$(image_repository "$ref")"
      if [ -n "${seen[$repo]+set}" ] && [ "${seen[$repo]}" != "$ref" ]; then
        fail "${file#"$here"/} pins $ref, another file pins ${seen[$repo]}; pin one version of $repo everywhere"
      fi
      seen[$repo]="$ref"
    done < <(sed -n 's/^[[:space:]]*image:[[:space:]]*\([^$[:space:]][^[:space:]]*\)[[:space:]]*$/\1/p' "$file")
  done
}

apply_pins() {
  local key file value rendered
  for key in "${image_keys[@]}"; do
    file="$bundle/$(env_file_for "$key")"
    [ "$(grep -c "^$key=" "$file" || true)" -eq 1 ] || fail "the rendered $(env_file_for "$key") does not set $key exactly once"
    [ "$mode" = pinned ] || continue
    value="$(pin_value "$key")"
    rendered="$(sed -n "s/^$key=//p" "$file")"
    [ "$(image_repository "$value")" = "$(image_repository "$rendered")" ] ||
      fail "$pins $key names $(image_repository "$value"), and production.yml names $(image_repository "$rendered")"
    awk -v key="$key" -v value="$value" 'index($0, key "=") == 1 { print key "=" value; next } { print }' "$file" >"$file.pinned"
    chmod 0600 "$file.pinned"
    mv "$file.pinned" "$file"
  done
}

pack() {
  local -a files
  mapfile -t files < <(cd "$bundle" && find . -type f ! -name manifest.sha256 -printf '%P\n' | LC_ALL=C sort)
  (cd "$bundle" && sha256sum -- "${files[@]}") >"$bundle/manifest.sha256"
  chmod 0600 "$bundle/manifest.sha256"
  mapfile -t files < <(cd "$bundle" && find . -type f -printf '%P\n' | LC_ALL=C sort)
  (
    umask 077
    tar --create --no-recursion --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
      --mode='u=rw,go=' -C "$bundle" -- "${files[@]}" | gzip -n -9 >"$output.new"
    mv "$output.new" "$output"
  )
}

commit="$(git -C "$here" rev-parse --verify 'HEAD^{commit}')" || fail "$here is not a git checkout"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "the release commit '$commit' is not a full sha"
if [ -n "$pins" ]; then
  check_pins
  mode=pinned
else
  mode=latest
fi
third_party_pins

ansible-playbook -i localhost, -c local "$here/release.yml" -e "@$extra_vars" -e "bundle_dir=$bundle" </dev/null >"$work/render.log" 2>&1 || {
  # The play's own messages name the failed check, never a value.
  grep -E 'msg|FAILED|ERROR' "$work/render.log" >&2 || true
  fail "release.yml refused to render the bundle"
}

apply_pins
printf 'RELEASE_MODE=%s\nRELEASE_COMMIT=%s\n' "$mode" "$commit" >"$bundle/release.env"
chmod 0600 "$bundle/release.env"
pack
printf 'bundle: %s bytes, %s release for commit %s\n' "$(wc -c <"$output")" "$mode" "$commit"
