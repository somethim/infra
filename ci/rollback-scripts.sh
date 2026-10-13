#!/usr/bin/env bash
# Tests rollback resolution against fakes: release-images.sh resolve reads a
# status fixture and asks a fake registry (docker buildx imagetools inspect) for
# digests; the pins it prints then build a --pin bundle that infra-apply
# releases in the fake host from ci/release-fakes.sh. Nothing here contacts a
# server or a registry.
#
#   bash ci/rollback-scripts.sh
#
# Prints "ok   ..." per case and stops with "FAIL ..." on the first failure.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/release-images.sh"
apply="$root/roles/common/files/infra-apply"
guard="$root/roles/common/files/infra-compose-guard"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/registry-bin"
# shellcheck source=ci/release-fakes.sh
. "$here/release-fakes.sh"

# The registry fake lives apart from the host fakes: resolve only ever runs
# `docker buildx imagetools inspect`.
cat >"$work/registry-bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_REGISTRY.calls"
if [ "$1 $2 $3" != "buildx imagetools inspect" ] || [ "$4" != --format ] || [ "$5" != '{{json .Manifest.Digest}}' ]; then
  echo "fake docker: unsupported $*" >&2
  exit 2
fi
digest="$(awk -v ref="$6" '$1 == ref { print $2 }' "$FAKE_REGISTRY")"
[ -n "$digest" ] || { echo "ERROR: $6: not found" >&2; exit 1; }
printf '"%s"\n' "$digest"
SH
chmod +x "$work/registry-bin/docker"

P="$portfolio_repo"
V="$provider_repo"
W="$web_repo"
sha=0123456789abcdef0123456789abcdef01234567
registry="$work/registry"
printf '%s %s\n' "$P:$sha" "$(d 7)" "$W@$(d 5)" "$(d 5)" >"$registry"

cur=20261014T100000Z-aaaaaaaaaaaa
prev=20261013T100000Z-bbbbbbbbbbbb

# Normal: three images run, the current release recorded them, and the host
# still holds two older digests of each repository.
cat >"$work/normal.txt" <<ST
infra-apply: current release: $cur (verified), following :latest, auto-updates on
infra-apply: previous release: none
infra-apply: image portfolio ref=$P:latest digest=$(d 12) created=2026-10-12T10:00:00Z
infra-apply: image prizm-provider ref=$V:latest digest=$(d 21) created=2026-10-10T10:00:00Z
infra-apply: image prizm-web ref=$W:latest digest=$(d 31) created=2026-10-11T10:00:00Z
infra-apply: known $P digest=$(d 12) created=2026-10-12 10:00:00 +0000 UTC
infra-apply: known $P digest=$(d 11) created=2026-10-05 10:00:00 +0000 UTC
infra-apply: known $P digest=$(d 10) created=2026-09-28 10:00:00 +0000 UTC
infra-apply: known $V digest=$(d 21) created=2026-10-10 10:00:00 +0000 UTC
infra-apply: known $V digest=$(d 20) created=2026-10-03 10:00:00 +0000 UTC
infra-apply: known $V digest=$(d 19) created=2026-09-26 10:00:00 +0000 UTC
infra-apply: known $W digest=$(d 31) created=2026-10-11 10:00:00 +0000 UTC
infra-apply: known $W digest=$(d 30) created=2026-10-04 10:00:00 +0000 UTC
infra-apply: known $W digest=$(d 29) created=2026-09-27 10:00:00 +0000 UTC
infra-apply: recorded $cur portfolio=$P@$(d 12)
infra-apply: recorded $cur prizm-provider=$V@$(d 21)
infra-apply: recorded $cur prizm-web=$W@$(d 31)
NAME IMAGE STATUS
ST

# The weekly prune removed the old images: the previous digests are known only
# from the previous release's record.
cat >"$work/recorded.txt" <<ST
infra-apply: current release: $cur (verified), following :latest, auto-updates on
infra-apply: previous release: $prev (verified), following :latest, auto-updates on
infra-apply: image portfolio ref=$P:latest digest=$(d 12) created=2026-10-12T10:00:00Z
infra-apply: image prizm-provider ref=$V:latest digest=$(d 21) created=2026-10-10T10:00:00Z
infra-apply: image prizm-web ref=$W:latest digest=$(d 31) created=2026-10-11T10:00:00Z
infra-apply: known $P digest=$(d 12) created=2026-10-12 10:00:00 +0000 UTC
infra-apply: known $V digest=$(d 21) created=2026-10-10 10:00:00 +0000 UTC
infra-apply: known $W digest=$(d 31) created=2026-10-11 10:00:00 +0000 UTC
infra-apply: recorded $cur portfolio=$P@$(d 12)
infra-apply: recorded $cur prizm-provider=$V@$(d 21)
infra-apply: recorded $cur prizm-web=$W@$(d 31)
infra-apply: recorded $prev portfolio=$P@$(d 41)
infra-apply: recorded $prev prizm-provider=$V@$(d 42)
infra-apply: recorded $prev prizm-web=$W@$(d 43)
NAME IMAGE STATUS
ST

# A first release: nothing but the running digests is known.
grep -v -e ' known ' "$work/recorded.txt" | grep -v -e "recorded $prev " |
  sed "s/^infra-apply: previous release: .*/infra-apply: previous release: none/" >"$work/noprev.txt"

resolve() {
  local status="$1"
  shift
  PATH="$work/registry-bin:$PATH" FAKE_REGISTRY="$registry" "$script" resolve "$@" <"$status" >"$work/pins" 2>"$work/err"
}
resolves() {
  local name="$1" want="$2" status="$3"
  shift 3
  resolve "$status" "$@" || { cat "$work/err"; echo "FAIL expected a resolution: $name"; exit 1; }
  printf '%b' "$want" | cmp -s - "$work/pins" || { printf 'got:\n'; cat "$work/pins"; printf 'wanted:\n%b' "$want"; echo "FAIL wrong pins: $name"; exit 1; }
  echo "ok   resolved: $name"
}
refuses() {
  local name="$1" want="$2" status="$3"
  shift 3
  if resolve "$status" "$@"; then cat "$work/pins"; echo "FAIL expected a refusal: $name"; exit 1; fi
  grep -qE -- "$want" "$work/err" || { cat "$work/err"; echo "FAIL refused for the wrong reason (wanted '$want'): $name"; exit 1; }
  [ ! -s "$work/pins" ] || { cat "$work/pins"; echo "FAIL printed pins despite refusing: $name"; exit 1; }
  echo "ok   refused: $name"
}
pins() {
  printf 'RELEASE_MODE=pinned\\nPORTFOLIO_IMAGE=%s\\nPROVIDER_IMAGE=%s\\nWEB_IMAGE=%s\\n' "$1" "$2" "$3"
}

### Resolution

resolves "previous for all three, from the older images on the host" \
  "$(pins "$P:latest@$(d 11)" "$V:latest@$(d 20)" "$W:latest@$(d 30)")" "$work/normal.txt" previous previous previous
cp "$work/pins" "$work/previous-pins.env"
resolves "previous for all three, from the previous release's record" \
  "$(pins "$P:latest@$(d 41)" "$V:latest@$(d 42)" "$W:latest@$(d 43)")" "$work/recorded.txt" previous previous previous
resolves "a portfolio commit sha, the running provider, web on :latest" \
  "$(pins "$P:$sha@$(d 7)" "$V:latest@$(d 21)" "$W:latest")" "$work/normal.txt" "$sha" current latest
grep -qx "buildx imagetools inspect --format {{json .Manifest.Digest}} $P:$sha" "$registry.calls" || { echo "FAIL the commit tag was not looked up in the registry"; exit 1; }
resolves "current for all three" \
  "$(pins "$P:latest@$(d 12)" "$V:latest@$(d 21)" "$W:latest@$(d 31)")" "$work/normal.txt" current current current
resolves "an explicit sha256 digest the registry has" \
  "$(pins "$P:latest" "$V:latest" "$W:latest@$(d 5)")" "$work/normal.txt" latest latest "$(d 5)"
grep -qx "buildx imagetools inspect --format {{json .Manifest.Digest}} $W@$(d 5)" "$registry.calls" || { echo "FAIL the digest was not checked in the registry"; exit 1; }

### Refusals

refuses "every target latest" "use resume" "$work/normal.txt" latest latest latest
refuses "a sha256 digest the registry does not have" "$W@$(d 6) does not exist in the registry" "$work/normal.txt" latest latest "$(d 6)"
refuses "no previous digest known" "no previous digest of $P is known for portfolio; pass an explicit sha256 digest; see status" "$work/noprev.txt" previous latest latest
refuses "no previous provider digest known" "no previous digest of $V is known for prizm-provider; .*see status" "$work/noprev.txt" latest previous latest
refuses "a 12-character portfolio sha (the portfolio publishes the full sha)" "is not latest, current, previous, a 40-character commit sha" "$work/normal.txt" "${sha:0:12}" latest latest
refuses "a portfolio sha the registry does not have" "does not exist in the registry" "$work/normal.txt" "$(printf 'f%.0s' $(seq 40))" latest latest
refuses "a commit sha for the hypernova provider" "only the portfolio publishes commit tags" "$work/normal.txt" latest "$sha" latest
refuses "a commit sha for hypernova web" "only the portfolio publishes commit tags" "$work/normal.txt" latest latest "$sha"
refuses "a version tag" "is not latest, current, previous, a 40-character commit sha" "$work/normal.txt" v1.2.3 latest latest
refuses "a short digest" "is not sha256:<64 hex" "$work/normal.txt" latest sha256:abc latest
grep -v 'image prizm-web' "$work/normal.txt" >"$work/noweb.txt"
refuses "no running web digest" "status names no running digest for prizm-web" "$work/noweb.txt" latest latest current
: >"$work/empty.txt"
refuses "an empty status" "no status output arrived" "$work/empty.txt" previous latest latest
refuses "the wrong argument count" "usage" "$work/normal.txt" previous previous

### The resolved pins build a bundle infra-apply releases as pinned

printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeRollbackFakeRollbackFakeRollbackFake01 infra-deploy-test' >"$work/deploy_key.pub"
jq --arg key "$work/deploy_key.pub" '. + {deploy_key_file: $key}' "$here/sample-extra-vars.json" >"$work/vars.json"
mapfile -t secrets < <(jq -r 'del(.ghcr_username, .portfolio_google_client_id) | .[]' "$here/sample-extra-vars.json")
"$root/build-bundle.sh" --pin "$work/previous-pins.env" "$work/vars.json" "$work/rollback.tgz" >"$work/build.log" 2>&1 ||
  { cat "$work/build.log"; echo "FAIL build-bundle.sh --pin refused the resolved pins"; exit 1; }
no_secret_in "$work/build.log" "build-bundle.sh --pin"
mkdir "$work/rollback"
tar -xzf "$work/rollback.tgz" -C "$work/rollback"
grep -qx 'RELEASE_MODE=pinned' "$work/rollback/release.env" || { echo "FAIL the rollback bundle is not a pinned release"; exit 1; }
grep -qxF "PORTFOLIO_IMAGE=$P:latest@$(d 11)" "$work/rollback/portfolio/.env" || { echo "FAIL the portfolio pin is not in portfolio/.env"; exit 1; }
grep -qxF "WEB_IMAGE=$W:latest@$(d 30)" "$work/rollback/hypernova/.env" || { echo "FAIL the web pin is not in hypernova/.env"; exit 1; }
echo "ok   bundle: build-bundle.sh --pin applies the resolved pins"

new_state
running_image portfolio "$P:latest@$(d 11)" 11
running_image prizm-provider "$V:latest@$(d 20)" 20
running_image prizm-web "$W:latest@$(d 30)" 30
expect_ok "the rollback bundle" "RELEASE OK: [0-9]{8}T[0-9]{6}Z-[0-9a-f]{12} is current, pinned \\(PORTFOLIO_IMAGE PROVIDER_IMAGE WEB_IMAGE\\), auto-updates paused for them" "$work/rollback.tgz" release
printf '%s\n' "portfolio=$P@$(d 11)" "prizm-provider=$V@$(d 20)" "prizm-web=$W@$(d 30)" |
  cmp -s - "$state/stack/current/running-images.env" || { cat "$state/stack/current/running-images.env"; echo "FAIL the rollback release did not record the pinned digests"; exit 1; }
echo "ok   infra-apply runs the rolled-back digests and records them"

echo "rollback scripts: all cases passed"
