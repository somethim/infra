#!/usr/bin/env bash
# Tests the release path against fakes: build-bundle.sh, infra-deploy-gate,
# infra-apply and infra-compose-guard. Fake docker, curl and sudo go first on
# PATH; `docker compose config` is delegated to the real Docker CLI (it needs
# no daemon), flock is real, and every host path is a temp dir through the
# INFRA_APPLY_* overrides. Nothing here contacts a server or a registry.
#
#   bash ci/release-scripts.sh
#
# Prints "ok   ..." per case and stops with "FAIL ..." on the first failure.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
apply="$root/roles/common/files/infra-apply"
gate="$root/roles/common/files/infra-deploy-gate"
guard="$root/roles/common/files/infra-compose-guard"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
# shellcheck source=ci/release-fakes.sh
. "$here/release-fakes.sh"

current_release() {
  readlink "$state/stack/current" | sed 's,^releases/,,'
}

# A state with one verified release installed; refusals must leave it as it is.
# The first call installs it; later calls copy that state.
installed_template=""
installed_state() {
  if [ -z "$installed_template" ]; then
    new_state
    run_apply "$work/good.tgz" release || { cat "$work/out"; echo "FAIL the base release did not install"; exit 1; }
    installed_template="$state"
    template_id="$(current_release)"
  fi
  count=$((count + 1))
  state="$work/state$count"
  cp -a "$installed_template" "$state"
  base_id="$template_id"
  : >"$state/calls"
}

expect_untouched() {
  local name="$1"
  if grep -qE '^compose .* (pull|up)( |$)' "$state/calls" || grep -q '^login' "$state/calls"; then
    echo "FAIL the stacks were touched after a refusal: $name"; exit 1
  fi
  [ "$(current_release)" = "$base_id" ] || { echo "FAIL current moved after a refusal: $name"; exit 1; }
  [ "$(find "$state/stack/releases" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] || { echo "FAIL a release was left on disk after a refusal: $name"; exit 1; }
  [ -z "$(find "$state/stack" -maxdepth 1 -name '.incoming.*')" ] || { echo "FAIL the incoming bundle was left behind: $name"; exit 1; }
}

refused_bundle() {
  local name="$1" want="$2" bundle="$3"
  installed_state
  expect_refused "$name" "$want" "$bundle" release
  grep -q 'infra-apply: FAILED: ' "$work/out" || { cat "$work/out"; echo "FAIL no FAILED line: $name"; exit 1; }
  expect_untouched "$name"
}

unpack() {
  rm -rf "$2"
  mkdir -p "$2"
  tar -xzf "$1" -C "$2"
}

manifest() {
  local dir="$1"
  local -a files
  mapfile -t files < <(cd "$dir" && find . -type f ! -name manifest.sha256 -printf '%P\n' | LC_ALL=C sort)
  (cd "$dir" && sha256sum -- "${files[@]}") >"$dir/manifest.sha256"
}

# pack <dir> <out> [tar options]: file entries only, like build-bundle.sh.
pack() {
  local dir="$1" out="$2"
  shift 2
  local -a files
  mapfile -t files < <(cd "$dir" && find . -mindepth 1 ! -type d -printf '%P\n' | LC_ALL=C sort)
  tar --create --gzip --no-recursion --file "$out" --owner=0 --group=0 "$@" -C "$dir" -- "${files[@]}"
}

# variant <name>: unpack the good bundle into $work/<name> for editing; then
# repack <name> rewrites the manifest and packs it to $work/<name>.tgz.
variant() {
  unpack "$work/good.tgz" "$work/$1"
}
repack() {
  manifest "$work/$1"
  pack "$work/$1" "$work/$1.tgz"
}

### Bundles from the real templates

cat >"$work/deploy_key.pub" <<'KEY'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHarnessHarnessHarnessHarnessHarnessHarness01 infra-deploy-test
KEY
cat >"$work/vars.json" <<JSON
{
  "ghcr_username": "infra-bot",
  "ghcr_token": "ghp_HarnessToken0123456789",
  "postgres_superuser_password": "HarnessPgSuperuser0123456789abcdefA",
  "prizm_db_password": "HarnessPrizmDb0123456789abcdefABCDEF",
  "portfolio_db_password": "HarnessPortfolioDb0123456789abcdefAB",
  "portfolio_totp_encryption_key": "SGFybmVzc1RvdHBLZXkwMTIzNDU2Nzg5YWJjZGVmQUI=",
  "portfolio_admin_password": "harness-portfolio-admin",
  "portfolio_resend_api_key": "re_HarnessResendKey",
  "portfolio_google_client_id": "harness.apps.googleusercontent.com",
  "portfolio_google_client_secret": "HarnessGoogleSecret",
  "hypernova_session_secret": "HarnessHypernovaSession0123456789",
  "hypernova_admin_password": "harness-hypernova-admin",
  "deploy_key_file": "$work/deploy_key.pub"
}
JSON
secrets=(ghp_HarnessToken0123456789 HarnessPgSuperuser0123456789abcdefA HarnessPrizmDb0123456789abcdefABCDEF
  HarnessPortfolioDb0123456789abcdefAB SGFybmVzc1RvdHBLZXkwMTIzNDU2Nzg5YWJjZGVmQUI= harness-portfolio-admin
  re_HarnessResendKey HarnessGoogleSecret HarnessHypernovaSession0123456789 harness-hypernova-admin)

build() {
  "$root/build-bundle.sh" "$@" >"$work/build.log" 2>&1
}

build "$work/vars.json" "$work/good.tgz" || { cat "$work/build.log"; echo "FAIL build-bundle.sh"; exit 1; }
no_secret_in "$work/build.log" "build-bundle.sh"
build "$work/vars.json" "$work/good-again.tgz" || { cat "$work/build.log"; echo "FAIL build-bundle.sh (second build)"; exit 1; }
cmp -s "$work/good.tgz" "$work/good-again.tgz" || { echo "FAIL build-bundle.sh is not deterministic"; exit 1; }
echo "ok   bundle: two builds from the same vars are byte-identical"
if tar -tvzf "$work/good.tgz" | grep -qv '^-'; then tar -tvzf "$work/good.tgz"; echo "FAIL the bundle holds entries other than regular files"; exit 1; fi
[ "$(tar -tzf "$work/good.tgz" | wc -l)" -eq 12 ] || { tar -tzf "$work/good.tgz"; echo "FAIL the bundle does not hold exactly 12 files"; exit 1; }
echo "ok   bundle: 12 file entries, no directories"
unpack "$work/good.tgz" "$work/good"
grep -qxF "RELEASE_COMMIT=$(git -C "$root" rev-parse HEAD)" "$work/good/release.env" || { echo "FAIL release.env does not name the checked-out commit"; exit 1; }
grep -qx 'RELEASE_MODE=latest' "$work/good/release.env" || { echo "FAIL a plain build is not a latest release"; exit 1; }

# Each secret lands only in the env file of the container that reads it.
owner_of() {
  case "$1" in
    ghp_*) echo ghcr.env ;;
    HarnessPgSuperuser*) echo "database/postgres.env database/provision.sql" ;;
    HarnessPrizmDb* | HarnessPortfolioDb*) echo "database/provision.sql $([ "${1#HarnessPrizm}" != "$1" ] && echo hypernova/provider.env || echo portfolio/portfolio.env)" ;;
    harness-hypernova-admin | HarnessHypernovaSession*) echo hypernova/provider.env ;;
    *) echo portfolio/portfolio.env ;;
  esac
}
for secret in "${secrets[@]}"; do
  found="$(cd "$work/good" && grep -rlF -- "$secret" . | sed 's,^\./,,' | LC_ALL=C sort | tr '\n' ' ')"
  want="$(owner_of "$secret" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')"
  [ "$found" = "$want" ] || { echo "FAIL a secret is in '$found', expected only '$want'"; exit 1; }
done
for file in portfolio/.env hypernova/.env; do
  if grep -vqE '^(PORTFOLIO_IMAGE|PROVIDER_IMAGE|WEB_IMAGE|APEX_DOMAIN|WWW_DOMAIN|WEB_DOMAIN)=' "$work/good/$file"; then
    cat "$work/good/$file"; echo "FAIL $file holds more than image references and domains"; exit 1
  fi
done
echo "ok   bundle: each secret is only in the env file of the container that reads it"

jq '.portfolio_admin_password = "second-admin-password"' "$work/vars.json" >"$work/vars-second.json"
secrets+=(second-admin-password)
build "$work/vars-second.json" "$work/second.tgz" || { cat "$work/build.log"; echo "FAIL build-bundle.sh (second release)"; exit 1; }

printf 'RELEASE_MODE=pinned\nPORTFOLIO_IMAGE=%s:%s@%s\nPROVIDER_IMAGE=%s:latest\nWEB_IMAGE=%s:latest@%s\n' \
  "$portfolio_repo" "$(printf '1%.0s' $(seq 40))" "$(d 10)" "$provider_repo" "$web_repo" "$(d 30)" >"$work/pins.env"
build --pin "$work/pins.env" "$work/vars.json" "$work/pinned.tgz" || { cat "$work/build.log"; echo "FAIL build-bundle.sh --pin"; exit 1; }
unpack "$work/pinned.tgz" "$work/pinned"
grep -qx 'RELEASE_MODE=pinned' "$work/pinned/release.env" || { echo "FAIL a --pin build is not a pinned release"; exit 1; }
grep -qxF "PORTFOLIO_IMAGE=$portfolio_repo:$(printf '1%.0s' $(seq 40))@$(d 10)" "$work/pinned/portfolio/.env" || { echo "FAIL the portfolio pin is not in portfolio/.env"; exit 1; }
grep -qxF "PROVIDER_IMAGE=$provider_repo:latest" "$work/pinned/hypernova/.env" || { echo "FAIL the unpinned provider does not follow :latest"; exit 1; }
grep -qxF "WEB_IMAGE=$web_repo:latest@$(d 30)" "$work/pinned/hypernova/.env" || { echo "FAIL the web pin is not in hypernova/.env"; exit 1; }
echo "ok   bundle: --pin writes the pins into portfolio/.env and hypernova/.env"

pin_refused() {
  local name="$1" want="$2" body="$3"
  printf '%b' "$body" >"$work/bad-pins.env"
  rm -f "$work/refused.tgz"
  if build --pin "$work/bad-pins.env" "$work/vars.json" "$work/refused.tgz"; then echo "FAIL build-bundle.sh accepted $name"; exit 1; fi
  grep -qE -- "$want" "$work/build.log" || { cat "$work/build.log"; echo "FAIL build-bundle.sh refused $name for the wrong reason"; exit 1; }
  [ ! -e "$work/refused.tgz" ] || { echo "FAIL build-bundle.sh left a bundle behind: $name"; exit 1; }
  echo "ok   bundle refuses: $name"
}
pin_refused "a pins file without RELEASE_MODE" "must hold exactly" "PORTFOLIO_IMAGE=$portfolio_repo:latest\nPROVIDER_IMAGE=$provider_repo:latest\nWEB_IMAGE=$web_repo:latest\n"
pin_refused "a pins file with an unpinned tag" "PORTFOLIO_IMAGE is neither" "RELEASE_MODE=pinned\nPORTFOLIO_IMAGE=$portfolio_repo:v2\nPROVIDER_IMAGE=$provider_repo:latest\nWEB_IMAGE=$web_repo:latest\n"
pin_refused "a pins file that pins nothing" "pins no image to a digest" "RELEASE_MODE=pinned\nPORTFOLIO_IMAGE=$portfolio_repo:latest\nPROVIDER_IMAGE=$provider_repo:latest\nWEB_IMAGE=$web_repo:latest\n"
pin_refused "a pins file naming another repository" "names ghcr.io/evil/portfolio" "RELEASE_MODE=pinned\nPORTFOLIO_IMAGE=ghcr.io/evil/portfolio:latest@$(d 1)\nPROVIDER_IMAGE=$provider_repo:latest\nWEB_IMAGE=$web_repo:latest\n"
pin_refused "a pins file that sets a key twice" "must hold exactly|exactly once" "RELEASE_MODE=pinned\nPORTFOLIO_IMAGE=$portfolio_repo:latest@$(d 1)\nPORTFOLIO_IMAGE=$portfolio_repo:latest@$(d 1)\nWEB_IMAGE=$web_repo:latest\n"

render_refused() {
  local name="$1" filter="$2"
  jq "$filter" "$work/vars.json" >"$work/bad-vars.json"
  rm -f "$work/refused.tgz"
  if build "$work/bad-vars.json" "$work/refused.tgz"; then echo "FAIL build-bundle.sh rendered $name"; exit 1; fi
  grep -q 'release.yml refused to render the bundle' "$work/build.log" || { cat "$work/build.log"; echo "FAIL build-bundle.sh refused $name for the wrong reason"; exit 1; }
  no_secret_in "$work/build.log" "build-bundle.sh refusing $name"
  [ ! -e "$work/refused.tgz" ] || { echo "FAIL build-bundle.sh left a bundle behind: $name"; exit 1; }
  echo "ok   bundle refuses: $name"
}
render_refused "a short database password" '.prizm_db_password = "short"'
render_refused "two equal database passwords" '.portfolio_db_password = .prizm_db_password'
# shellcheck disable=SC2016 # a jq filter; the $$ is literal
render_refused "a value holding \$" '.portfolio_admin_password = "pa$$word"'
render_refused "a TOTP key that is not base64 of 32 bytes" '.portfolio_totp_encryption_key = "short"'
render_refused "the placeholder deploy key" 'del(.deploy_key_file)'

scratch="$work/scratch-repo"
mkdir "$scratch"
tar --exclude=.git -C "$root" -cf - . | tar -xf - -C "$scratch"
sed -i 's,image: traefik:v3[^[:space:]]*,image: traefik:v3,' "$scratch/roles/edge/files/docker-compose.yml"
(
  cd "$scratch"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
  git init -q . && git add -A && git commit -qm "test(release): unpinned image"
)
if "$scratch/build-bundle.sh" "$work/vars.json" "$work/refused.tgz" >"$work/build.log" 2>&1; then echo "FAIL build-bundle.sh accepted an unpinned third-party image"; exit 1; fi
grep -q 'roles/edge/files/docker-compose.yml runs traefik:v3, which is not pinned' "$work/build.log" || { cat "$work/build.log"; echo "FAIL wrong refusal for an unpinned image"; exit 1; }
echo "ok   bundle refuses: an unpinned third-party image"

### Accepted releases

new_state
expect_ok "the bundle build-bundle.sh renders from the real templates" "RELEASE OK: [0-9]{8}T[0-9]{6}Z-[0-9a-f]{12} is current, following :latest, auto-updates on$" "$work/good.tgz" release
first_id="$(current_release)"
for stack in database portfolio hypernova; do
  grep -q "compose model accepted: .* in the $stack stack, no privileged settings" "$work/out" || { cat "$work/out"; echo "FAIL the checked-in $stack stack did not pass the compose guard"; exit 1; }
done
echo "ok   the three checked-in stacks pass the compose guard"
[ -f "$state/stack/releases/$first_id/.verified" ] || { echo "FAIL the release was not marked verified"; exit 1; }
for file in ghcr.env database/postgres.env database/provision.sql portfolio/.env portfolio/portfolio.env hypernova/.env hypernova/provider.env manifest.sha256; do
  [ "$(stat -c %a "$state/stack/current/$file")" = 600 ] || { echo "FAIL $file is not 0600 in the release"; exit 1; }
done
[ "$(stat -c %a "$state/stack/current/portfolio/docker-compose.yml")" = 644 ] || { echo "FAIL docker-compose.yml is not 0644"; exit 1; }
[ "$(cat "$state/login.stdin")" = ghp_HarnessToken0123456789 ] || { echo "FAIL docker login did not receive the token on stdin"; exit 1; }
grep -q '^login ghcr.io --username infra-bot --password-stdin$' "$state/calls" || { echo "FAIL docker login did not use the GHCR username"; exit 1; }
cmp -s "$state/psql.stdin" "$work/good/database/provision.sql" || { echo "FAIL provision.sql was not fed to psql"; exit 1; }
order="$(grep -nE '^compose .*/(database|portfolio|hypernova) (pull --quiet|up -d.*)$|^exec -i postgresql psql -v ON_ERROR_STOP=1 -U postgres -d postgres$' "$state/calls" | sed -E 's,^[0-9]+:,,; s,^compose .*/(database|portfolio|hypernova) ,\1 ,; s,^exec .*,psql,')"
want_order="$(printf '%s\n' 'database pull --quiet' 'portfolio pull --quiet' 'hypernova pull --quiet' 'database up -d --wait --remove-orphans' psql 'portfolio up -d --remove-orphans' 'hypernova up -d --remove-orphans')"
[ "$order" = "$want_order" ] || { printf '%s\n' "$order"; echo "FAIL the stacks did not start in the order database, provision.sql, portfolio, hypernova"; exit 1; }
grep -qE '^compose --file [^ ]*/stack/current/portfolio/docker-compose.yml' "$state/calls" || { echo "FAIL portfolio did not start from the current link"; exit 1; }
[ "$(grep -c '^curl ' "$state/calls")" -eq 4 ] || { echo "FAIL the routes for apex, www, hypernova / and /api/ were not all checked"; exit 1; }
[ ! -e "$state/stack/previous" ] || { echo "FAIL a first release has no previous release"; exit 1; }
printf '%s\n' "portfolio=$portfolio_repo@$(d 11)" "prizm-provider=$provider_repo@$(d 21)" "prizm-web=$web_repo@$(d 31)" |
  cmp -s - "$state/stack/current/running-images.env" || { cat "$state/stack/current/running-images.env"; echo "FAIL running-images.env does not record the running digests"; exit 1; }
echo "ok   a first release pulls, starts database, provision.sql, portfolio, hypernova in order and records the running digests"

running_image portfolio "$portfolio_repo:latest" 12
sleep 1
expect_ok "a second release keeps the first as the previous release" "following :latest, auto-updates on; $first_id is kept as the previous release" "$work/second.tgz" release
second_id="$(current_release)"
[ "$second_id" != "$first_id" ] || { echo "FAIL the second release reused the first id"; exit 1; }
[ "$(readlink "$state/stack/previous")" = "releases/$first_id" ] || { echo "FAIL previous does not point at the first release"; exit 1; }
grep -q '^ADMIN_PASSWORD=second-admin-password$' "$state/stack/current/portfolio/portfolio.env" || { echo "FAIL current is not the second release"; exit 1; }

running_image portfolio "$portfolio_repo:$(printf '1%.0s' $(seq 40))@$(d 10)" 10
running_image prizm-web "$web_repo:latest@$(d 30)" 30
sleep 1
expect_ok "a pinned release" "RELEASE OK: .* is current, pinned \\(PORTFOLIO_IMAGE WEB_IMAGE\\), auto-updates paused for them; $second_id is kept as the previous release" "$work/pinned.tgz" release
pinned_id="$(current_release)"
[ "$(find "$state/stack/releases" -mindepth 1 -maxdepth 1 | wc -l)" -eq 2 ] || { echo "FAIL old releases were not pruned"; exit 1; }
[ ! -e "$state/stack/releases/$first_id" ] || { echo "FAIL the oldest release was kept"; exit 1; }

printf '%s\n' "$(d 30) 2026-10-12 10:00:00 +0000 UTC" "$(d 31) 2026-10-01 10:00:00 +0000 UTC" "<none> 2026-09-01 10:00:00 +0000 UTC" "$(d 31) 2026-10-01 10:00:00 +0000 UTC" >"$state/known/$(printf '%s' "$web_repo" | tr / _)"
expect_ok "status after a pinned release" "current release: $pinned_id \\(verified\\), pinned \\(PORTFOLIO_IMAGE WEB_IMAGE\\), auto-updates paused for them" /dev/null status
for want in \
  "infra-apply: previous release: $second_id (verified), following :latest, auto-updates on" \
  "infra-apply: image portfolio ref=$portfolio_repo:$(printf '1%.0s' $(seq 40))@$(d 10) digest=$(d 10) created=2026-10-11T10:00:00Z" \
  "infra-apply: image prizm-provider ref=$provider_repo:latest digest=$(d 21) created=2026-10-22T10:00:00Z" \
  "infra-apply: image prizm-web ref=$web_repo:latest@$(d 30) digest=$(d 30) created=" \
  "infra-apply: known $web_repo digest=$(d 30) created=2026-10-12 10:00:00 +0000 UTC" \
  "infra-apply: known $web_repo digest=$(d 31) created=2026-10-01 10:00:00 +0000 UTC" \
  "infra-apply: recorded $pinned_id portfolio=$portfolio_repo@$(d 10)" \
  "infra-apply: recorded $second_id portfolio=$portfolio_repo@$(d 12)" \
  "infra-apply: recorded $second_id prizm-web=$web_repo@$(d 31)" \
  "NAME IMAGE STATUS (hypernova)"; do
  grep -qF -- "$want" "$work/out" || { cat "$work/out"; echo "FAIL status does not print: $want"; exit 1; }
done
[ "$(grep -c "known $web_repo " "$work/out")" -eq 2 ] || { cat "$work/out"; echo "FAIL status lists a known digest twice or lists <none>"; exit 1; }
[ "$(grep -n "known $web_repo digest=$(d 30)" "$work/out" | cut -d: -f1)" -lt "$(grep -n "known $web_repo digest=$(d 31)" "$work/out" | cut -d: -f1)" ] || { echo "FAIL known digests are not newest first"; exit 1; }
echo "ok   status prints both releases, image, known and recorded lines"

new_state
expect_ok "status with no release installed" "no release is installed" /dev/null status

new_state
sed -i 's/^ORIGIN_PULL=0$/ORIGIN_PULL=1/' "$state/host.env"
printf '000' >"$state/curl.hypernova.arbikullakshi.com"
echo 35 >"$state/curl.hypernova.arbikullakshi.com.rc"
expect_ok "origin pull on, the local TLS handshake is refused" "RELEASE OK" "$work/good.tgz" release
grep -q 'origin pull on: route presence not proven locally for hypernova.arbikullakshi.com/ hypernova.arbikullakshi.com/api/' "$work/out" || { cat "$work/out"; echo "FAIL the unproven routes were not logged"; exit 1; }

new_state
printf '000' >"$state/curl.hypernova.arbikullakshi.com"
echo 35 >"$state/curl.hypernova.arbikullakshi.com.rc"
expect_refused "a refused TLS handshake with origin pull off" "Traefik answered 000 for hypernova.arbikullakshi.com/" "$work/good.tgz" release

### Refused before anything changes

: >"$work/empty"
refused_bundle "an empty stdin" "no bundle arrived" "$work/empty"
head -c 1048577 /dev/urandom >"$work/big"
refused_bundle "a bundle over 1 MiB" "larger than 1048576 bytes" "$work/big"
printf 'not a tarball\n' >"$work/garbage"
refused_bundle "a bundle that is not gzip" "not a gzip-compressed tar archive" "$work/garbage"

variant extra
printf 'set -eu\n' >"$work/extra/portfolio/extra.sh"
repack extra
refused_bundle "an unexpected entry" "unexpected entry: portfolio/extra\\.sh" "$work/extra.tgz"

variant traversal
manifest "$work/traversal"
pack "$work/traversal" "$work/traversal.tgz" -P --transform 's,^ghcr.env$,../ghcr.env,'
refused_bundle "a path traversal entry" "unexpected entry: \\.\\./ghcr\\.env" "$work/traversal.tgz"

variant absolute
manifest "$work/absolute"
pack "$work/absolute" "$work/absolute.tgz" -P --transform 's,^ghcr.env$,/etc/cron.d/ghcr,'
refused_bundle "an absolute path entry" "unexpected entry: /etc/cron\\.d/ghcr" "$work/absolute.tgz"

variant symlink
rm "$work/symlink/portfolio/portfolio.env"
ln -s /etc/passwd "$work/symlink/portfolio/portfolio.env"
manifest "$work/symlink" 2>/dev/null || true
pack "$work/symlink" "$work/symlink.tgz"
refused_bundle "a symlink entry" "portfolio/portfolio\\.env is not a regular file" "$work/symlink.tgz"

variant hardlink
rm "$work/hardlink/hypernova/provider.env"
ln "$work/hardlink/portfolio/portfolio.env" "$work/hardlink/hypernova/provider.env"
repack hardlink
refused_bundle "a hard link entry" "is not a regular file" "$work/hardlink.tgz"

variant withdir
manifest "$work/withdir"
(cd "$work/withdir" && tar --create --gzip --file "$work/withdir.tgz" --owner=0 --group=0 manifest.sha256 release.env ghcr.env database portfolio hypernova)
refused_bundle "a directory entry" "unexpected entry: database/" "$work/withdir.tgz"

variant duplicate
manifest "$work/duplicate"
mapfile -t files < <(cd "$work/duplicate" && find . -type f -printf '%P\n' | LC_ALL=C sort)
(cd "$work/duplicate" && tar --create --file "$work/duplicate.tar" --no-recursion -- "${files[@]}" && tar --append --file "$work/duplicate.tar" ghcr.env)
gzip -c "$work/duplicate.tar" >"$work/duplicate.tgz"
refused_bundle "an entry named twice" "more than once" "$work/duplicate.tgz"

variant missing
rm "$work/missing/database/provision.sql"
repack missing
refused_bundle "a missing file" "missing database/provision\\.sql" "$work/missing.tgz"

variant large
head -c 300000 /dev/zero | tr '\0' 'a' >"$work/large/hypernova/provider.env"
repack large
refused_bundle "a file over 256 KiB" "did not extract cleanly|larger than 262144 bytes" "$work/large.tgz"

variant tampered
manifest "$work/tampered"
printf 'EXTRA=1\n' >>"$work/tampered/portfolio/portfolio.env"
pack "$work/tampered" "$work/tampered.tgz"
refused_bundle "a checksum mismatch" "does not match its manifest\\.sha256 checksum" "$work/tampered.tgz"

variant short
manifest "$work/short"
grep -v ' hypernova/provider.env$' "$work/short/manifest.sha256" >"$work/short/manifest.new"
mv "$work/short/manifest.new" "$work/short/manifest.sha256"
pack "$work/short" "$work/short.tgz"
refused_bundle "a manifest that leaves a file out" "does not list exactly the files" "$work/short.tgz"

variant outside
manifest "$work/outside"
printf '%064d  ../../etc/passwd\n' 0 >>"$work/outside/manifest.sha256"
pack "$work/outside" "$work/outside.tgz"
refused_bundle "a manifest that names an extra file" "names an unexpected file" "$work/outside.tgz"

variant badenv
printf 'export EVIL=1\n' >>"$work/badenv/hypernova/provider.env"
repack badenv
refused_bundle "an env line that is not KEY=value" "hypernova/provider\\.env line 14 is not KEY=value" "$work/badenv.tgz"

variant comment
sed -i '1i # a comment' "$work/comment/portfolio/.env"
repack comment
refused_bundle "an env comment line" "portfolio/\\.env line 1 is not KEY=value" "$work/comment.tgz"

variant badghcr
printf 'GHCR_USERNAME=infra-bot\nGHCR_TOKEN=x\nGHCR_EXTRA=1\n' >"$work/badghcr/ghcr.env"
repack badghcr
refused_bundle "ghcr.env with an extra key" "must set exactly GHCR_USERNAME and GHCR_TOKEN" "$work/badghcr.tgz"

release_env_case() {
  local name="$1" want="$2" body="$3"
  variant relenv
  printf '%b' "$body" >"$work/relenv/release.env"
  repack relenv
  refused_bundle "$name" "$want" "$work/relenv.tgz"
}
commit_one=1111111111111111111111111111111111111111
release_env_case "release.env with an unknown mode" "RELEASE_MODE must be latest or pinned" "RELEASE_MODE=paused\nRELEASE_COMMIT=$commit_one\n"
release_env_case "release.env with a short commit" "RELEASE_COMMIT is not a full commit sha" "RELEASE_MODE=latest\nRELEASE_COMMIT=1111111\n"
release_env_case "release.env with an extra key" "must set exactly RELEASE_MODE and RELEASE_COMMIT" "RELEASE_MODE=latest\nRELEASE_COMMIT=$commit_one\nAUTO=1\n"
release_env_case "release.env naming a key twice" "must set exactly RELEASE_MODE and RELEASE_COMMIT" "RELEASE_MODE=latest\nRELEASE_MODE=latest\n"
release_env_case "a pinned release without a digest" "a pinned release must pin at least one image" "RELEASE_MODE=pinned\nRELEASE_COMMIT=$commit_one\n"

variant latestdigest
sed -i "s,^PORTFOLIO_IMAGE=.*,PORTFOLIO_IMAGE=$portfolio_repo:latest@$(d 1)," "$work/latestdigest/portfolio/.env"
repack latestdigest
refused_bundle "a latest release with a digest" "PORTFOLIO_IMAGE must be $portfolio_repo:latest in a latest release" "$work/latestdigest.tgz"

unpack "$work/pinned.tgz" "$work/pinnedtag"
sed -i "s,^PROVIDER_IMAGE=.*,PROVIDER_IMAGE=$provider_repo:v2," "$work/pinnedtag/hypernova/.env"
repack pinnedtag
refused_bundle "a pinned release with a moving tag" "PROVIDER_IMAGE must be $provider_repo:latest or" "$work/pinnedtag.tgz"

variant otherrepo
sed -i "s,^WEB_IMAGE=.*,WEB_IMAGE=ghcr.io/evil/hypernova-web:latest," "$work/otherrepo/hypernova/.env"
repack otherrepo
refused_bundle "an app image from another repository" "WEB_IMAGE runs ghcr\\.io/evil/hypernova-web:latest, not an image of $web_repo" "$work/otherrepo.tgz"

variant twice
printf 'PORTFOLIO_IMAGE=%s:latest\n' "$portfolio_repo" >>"$work/twice/portfolio/.env"
repack twice
refused_bundle "an image key set twice" "must set PORTFOLIO_IMAGE exactly once" "$work/twice.tgz"

installed_state
echo 1 >"$state/config.rc"
expect_refused "a compose file docker compose rejects" "docker compose rejects database/docker-compose\\.yml" "$work/good.tgz" release
expect_untouched "a compose file docker compose rejects"

installed_state
exec 8>"$state/stack/.lock"
flock -n 8
expect_refused "a release while the lock is held" "another release or status is running" "$work/good.tgz" release
expect_untouched "a release while the lock is held"
exec 8>&-

installed_state
echo 1 >"$state/login.rc"
expect_refused "a refused registry login" "docker login to ghcr.io was refused" "$work/good.tgz" release
[ "$(current_release)" = "$base_id" ] || { echo "FAIL a refused login moved current"; exit 1; }
grep -qE '^compose .* (pull|up)( |$)' "$state/calls" && { echo "FAIL the stacks were touched after a refused login"; exit 1; }

installed_state
echo 1 >"$state/pull.rc"
expect_refused "an image pull that fails" "pulling the database images failed; the running release is untouched" "$work/good.tgz" release
grep -qE '^compose .* up( |$)' "$state/calls" && { echo "FAIL a stack started after a failed pull"; exit 1; }
[ "$(current_release)" = "$base_id" ] || { echo "FAIL a failed pull moved current"; exit 1; }
[ "$(find "$state/stack/releases" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] || { echo "FAIL a failed pull left its release on disk"; exit 1; }

new_state
rm "$state/edge/dynamic/dynamic.yml"
expect_refused "an edge without the cloudflare-only allowlist" "dynamic\\.yml does not exist" "$work/good.tgz" release
new_state
sed -i "s,^PORTFOLIO_IMAGE_REPO=.*,PORTFOLIO_IMAGE_REPO=not a repo," "$state/host.env"
expect_refused "a host.env with a malformed repository" "PORTFOLIO_IMAGE_REPO is not an image repository" "$work/good.tgz" release
rm "$state/host.env"
expect_refused "a host that was never provisioned" "host\\.env does not exist; run provisioning" "$work/good.tgz" release

### The compose guard

# compose_case <name> <stack> <want> <python edit of the compose text>
compose_case() {
  local name="$1" stack="$2" want="$3" edit="$4"
  variant compose
  python3 -I -c "
import sys
path = sys.argv[1]
text = open(path).read()
$edit
open(path, 'w').write(text)
" "$work/compose/$stack/docker-compose.yml"
  repack compose
  refused_bundle "the guard: $name" "$stack/docker-compose\\.yml: $want" "$work/compose.tgz"
}
db_service='    restart: always\n'
compose_case "privileged" database "service postgres sets privileged, which gives it root" "text = text.replace('$db_service', '$db_service    privileged: true\n')"
compose_case "cap_add" database "service postgres sets cap_add, which adds kernel capabilities" "text = text.replace('$db_service', '$db_service    cap_add: [NET_ADMIN]\n')"
compose_case "ports" portfolio "service portfolio sets ports, which publishes a host port" "text = text.replace('    restart: always\n', '    restart: always\n    ports: [\"3000:3000\"]\n')"
compose_case "a bind mount" portfolio 'service portfolio has a "bind" mount of "/etc"' "text = text.replace('      - portfolio-media:/app/media\n', '      - portfolio-media:/app/media\n      - /etc:/host-etc:ro\n')"
compose_case "the Docker socket" hypernova 'service provider mounts the Docker socket "/var/run/docker.sock"' "text = text.replace('      - prizm-storage:/app/storage\n', '      - prizm-storage:/app/storage\n      - /var/run/docker.sock:/var/run/docker.sock:ro\n')"
compose_case "network_mode host" hypernova "service web sets network_mode, which a release may not set" "text = text.replace('    networks:\n      - edge\n    labels:', '    network_mode: host\n    labels:')"
compose_case "pid host" database "service postgres sets pid, which a release may not set" "text = text.replace('$db_service', '$db_service    pid: host\n')"
compose_case "a foreign env_file" portfolio 'service portfolio reads env_file "../ghcr.env"' "text = text.replace('    env_file: portfolio.env\n', '    env_file: [portfolio.env, ../ghcr.env]\n')"
compose_case "another stack's env_file" hypernova 'service web reads env_file "../portfolio/portfolio.env"' "text = text.replace('    environment:\n      NODE_ENV', '    env_file: ../portfolio/portfolio.env\n    environment:\n      NODE_ENV')"
compose_case "pgdata without external or name" database 'volume pgdata is "database_pgdata"; the database stack keeps its data in "pgdata-v18" \(external\)' "text = text.replace('    name: pgdata-v18\n    external: true\n', '')"
compose_case "the media volume under the project prefix" portfolio 'volume portfolio-media is "portfolio_portfolio-media"' "text = text.replace('    name: portfolio-media\n', '    name: portfolio_portfolio-media\n')"
compose_case "an extra volume" hypernova 'the volumes are \["extra", "prizm-storage"\]' "text = text.replace('      - prizm-storage:/app/storage\n', '      - prizm-storage:/app/storage\n      - extra:/extra\n').replace('volumes:\n  prizm-storage:\n', 'volumes:\n  prizm-storage:\n  extra:\n')"
compose_case "an external network other than edge and data" portfolio 'network edge is "bridge"; the portfolio stack may only join' "text = text.replace('    name: edge\n', '    name: bridge\n')"
compose_case "edge on the database" database 'network data is "edge"; the database stack may only join the existing network\(s\) data' "text = text.replace('    name: data\n', '    name: edge\n')"
compose_case "a wrong container_name" hypernova 'service web sets container_name "hypernova-web"' "text = text.replace('container_name: prizm-web', 'container_name: hypernova-web')"
compose_case "a Watchtower label on postgres" database "service postgres sets the label com.centurylinklabs.watchtower.enable" "text = text.replace('$db_service', '$db_service    labels: [com.centurylinklabs.watchtower.enable=true]\n')"
compose_case "a traefik label on postgres" database "service postgres sets the label traefik.enable" "text = text.replace('$db_service', '$db_service    labels:\n      traefik.enable: \"true\"\n')"
compose_case "extends" database "service postgres extends another service" "text = text.replace('  postgres:\n', '  base:\n    image: postgres:18.6-alpine@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873\n    container_name: postgresql-base\n    networks: [data]\n  postgres:\n    extends: base\n')"
compose_case "include" hypernova "includes another compose file" "text = text.replace('name: hypernova\n', 'name: hypernova\ninclude:\n  - ../database/docker-compose.yml\n')"
compose_case "a YAML merge key" portfolio "uses a YAML merge key" "text = text.replace('name: portfolio\n', 'name: portfolio\nx-base: &base\n  restart: always\n', 1).replace('    restart: always\n    security_opt', '    <<: *base\n    security_opt')"
compose_case "profiles" hypernova "service debug sets profiles" "text = text.replace('\nnetworks:\n  edge:', '\n  debug:\n    image: alpine:3.22@sha256:$(printf '0%.0s' $(seq 64))\n    container_name: prizm-web\n    profiles: [debug]\n\nnetworks:\n  edge:', 1)"
compose_case "an unpinned third-party image" database 'service postgres runs "postgres:18-alpine"' "import re; text = re.sub(r'image: postgres:\S+', 'image: postgres:18-alpine', text)"
compose_case "a root user" portfolio 'service portfolio sets user "0:0"' "text = text.replace('    restart: always\n', '    restart: always\n    user: \"0:0\"\n')"
compose_case "another security_opt" portfolio 'service portfolio sets security_opt "seccomp=unconfined"' "text = text.replace('      - no-new-privileges:true\n', '      - no-new-privileges:true\n      - seccomp=unconfined\n')"
compose_case "a privileged flag hidden behind a default" database "service postgres sets privileged" "text = text.replace('$db_service', '$db_service    privileged: \${X_FLAG:-false}\n')"
compose_case "a wrong project name" portfolio 'the project name is "other", not portfolio' "text = text.replace('name: portfolio\n', 'name: other\n', 1)"

# The guard on its own, against the resolved models of the checked-in stacks.
for stack in database portfolio hypernova; do
  repos=()
  case "$stack" in
    portfolio) repos=("$portfolio_repo") ;;
    hypernova) repos=("$provider_repo" "$web_repo") ;;
  esac
  "$REAL_DOCKER" compose --file "$work/good/$stack/docker-compose.yml" --project-directory "$work/good/$stack" config --no-env-resolution --format json >"$work/$stack.json"
  python3 -I "$guard" "$work/$stack.json" "$work/good/$stack" "$stack" "${repos[@]}" >"$work/guard.out" || { cat "$work/guard.out"; echo "FAIL the guard refuses the checked-in $stack stack"; exit 1; }
done
if python3 -I "$guard" "$work/hypernova.json" "$work/good/hypernova" hypernova >"$work/guard.out"; then echo "FAIL the guard accepted app images no host.env names"; exit 1; fi
if python3 -I "$guard" "$work/portfolio.json" "$work/good/portfolio" crm >"$work/guard.out"; then echo "FAIL the guard accepted an unknown stack"; exit 1; fi
echo "ok   the guard alone passes the checked-in stacks and needs the host's app repositories"

### Failed after install: the previous verified release is named

installed_state
sleep 1
echo 3 >"$state/psql.rc"
expect_refused "provision.sql fails" "FAILED: before the app stacks changed, provision\\.sql failed" "$work/second.tgz" release
grep -qF "the last verified release was $base_id" "$work/out" || { cat "$work/out"; echo "FAIL the provision failure does not name the last verified release"; exit 1; }
grep -qF "password '***'" "$work/out" || { cat "$work/out"; echo "FAIL the psql error was not shown with its literal masked"; exit 1; }
grep -qE '^compose .*/(portfolio|hypernova) up' "$state/calls" && { echo "FAIL an app stack started after provision.sql failed"; exit 1; }
[ "$(current_release)" = "$base_id" ] || { echo "FAIL a provision failure moved current"; exit 1; }
grep -qF "rollback cannot fix this" "$work/out" || { cat "$work/out"; echo "FAIL the provision failure advertises a rollback"; exit 1; }
grep -qF "revert the stack/database or secret change on master and run release" "$work/out" || { cat "$work/out"; echo "FAIL the provision failure does not name the revert recovery"; exit 1; }
grep -q 'action rollback' "$work/out" && { cat "$work/out"; echo "FAIL the provision failure recommends a rollback"; exit 1; }
rm "$state/psql.rc"
echo "ok   a provision.sql failure leaves the app stacks and current untouched and names a recovery that can fix it"

installed_state
sleep 1
echo 1 >"$state/up.database.rc"
expect_refused "the database does not come up healthy" "FAILED: before the app stacks changed, the database did not come up healthy" "$work/second.tgz" release
for want in "the last verified release was $base_id" "rollback cannot fix this" "revert the stack/database or secret change on master and run release" "current still names $base_id. A rollback cannot fix this"; do
  grep -qF -- "$want" "$work/out" || { cat "$work/out"; echo "FAIL the database failure does not print: $want"; exit 1; }
done
grep -q 'action rollback' "$work/out" && { cat "$work/out"; echo "FAIL the database failure recommends a rollback"; exit 1; }
grep -qE '^compose .*/(portfolio|hypernova) up' "$state/calls" && { echo "FAIL an app stack started after the database failed"; exit 1; }
[ "$(current_release)" = "$base_id" ] || { echo "FAIL a database failure moved current"; exit 1; }
echo "ok   a database failure leaves current untouched and names a recovery that can fix it"

new_state
echo 1 >"$state/up.database.rc"
expect_refused "the database of a first release does not come up healthy" "installed but not current; no release is current yet\\. A rollback cannot fix this" "$work/good.tgz" release
grep -q 'the last verified release was' "$work/out" && { cat "$work/out"; echo "FAIL a first release names a last verified release"; exit 1; }

installed_state
sleep 1
echo 1 >"$state/up.hypernova.rc"
expect_refused "an app stack that does not start" "FAILED: hypernova did not start" "$work/second.tgz" release
for want in "the last verified release was $base_id" "rollback only if an app image causes" "revert that change on master and run release"; do
  grep -qF -- "$want" "$work/out" || { cat "$work/out"; echo "FAIL the app start failure does not print: $want"; exit 1; }
done
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a release whose app stack did not start was marked verified"; exit 1; }
echo "ok   an app start failure says when a rollback helps and when to revert on master"

installed_state
sleep 1
sed -i 's,^c3 /prizm-provider running always healthy hypernova$,c3 /prizm-provider running always starting hypernova,' "$state/containers"
expect_refused "a container that never turns healthy" "not ready after 1s: prizm-provider:starting" "$work/second.tgz" release
grep -qF "the last verified release was $base_id" "$work/out" || { cat "$work/out"; echo "FAIL the failure does not name the last verified release"; exit 1; }
grep -qF "rollback only if an app image causes" "$work/out" || { cat "$work/out"; echo "FAIL the verify failure does not qualify the rollback"; exit 1; }
[ "$(readlink "$state/stack/previous")" = "releases/$base_id" ] || { echo "FAIL the verified release is not kept as previous"; exit 1; }
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL an unhealthy release was marked verified"; exit 1; }
failed_id="$(current_release)"
sed -i 's,starting hypernova$,healthy hypernova,' "$state/containers"
sleep 1
expect_ok "a release after a failed one keeps the last verified release" "$base_id is kept as the previous release" "$work/good.tgz" release
[ ! -e "$state/stack/releases/$failed_id" ] || { echo "FAIL the failed release was not pruned"; exit 1; }

installed_state
sleep 1
touch "$state/crashloop/prizm-web"
expect_refused "a prizm-web that crash-loops between polls" "not ready after 1s: prizm-web:running for [0-9]+s of 30s \\(restarted [0-9]+ times\\)" "$work/second.tgz" release
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a crash-looping release was marked verified"; exit 1; }
[ "$(readlink "$state/stack/previous")" = "releases/$base_id" ] || { echo "FAIL the verified release is not kept as previous after a crash loop"; exit 1; }
grep -q '^curl ' "$state/calls" && { echo "FAIL the routes were checked before the containers settled"; exit 1; }
rm "$state/crashloop/prizm-web"
echo "ok   a container that restarts between polls never counts as ready"

installed_state
sleep 1
date -u -d '-5 seconds' +%Y-%m-%dT%H:%M:%S.%NZ >"$state/started/prizm-web"
expect_refused "a prizm-web that started 5 s ago" "not ready after 1s: prizm-web:running for [0-9]+s of 30s \\(restarted 0 times\\)" "$work/second.tgz" release
echo "ok   a container up for less than the settle window is not ready yet"

installed_state
sleep 1
echo 'not-a-time' >"$state/started/prizm-web"
expect_refused "a container with an unreadable StartedAt" "not ready after 1s: prizm-web:started at an unreadable time" "$work/second.tgz" release

installed_state
sleep 1
printf '404' >"$state/curl.www.arbikullakshi.com"
expect_refused "Traefik answers 404 for a host" "Traefik answered 404 for www\\.arbikullakshi\\.com/ on the host itself" "$work/second.tgz" release
grep -qF "the last verified release was $base_id" "$work/out" || { cat "$work/out"; echo "FAIL the 404 failure does not name the last verified release"; exit 1; }

installed_state
sleep 1
echo 'level=WARN msg="blocked request" method=POST URL=/v1.51/containers/abc/stop' >"$state/logs/autoheal-socket-proxy"
expect_refused "a socket proxy logged a blocked request" "autoheal-socket-proxy refused Docker API calls autoheal made" "$work/second.tgz" release
grep -qF "the last verified release was $base_id" "$work/out" || { cat "$work/out"; echo "FAIL the proxy failure does not name the last verified release"; exit 1; }

installed_state
sleep 1
echo 'level=error msg="Error response from daemon: Forbidden"' >"$state/logs/watchtower"
expect_refused "Watchtower logged a Docker API error" "Watchtower cannot use the Docker API" "$work/second.tgz" release

installed_state
sleep 1
echo "true true" >"$state/running/edge-socket-proxy"
expect_refused "Traefik's socket proxy restart-looping" "edge-socket-proxy is not running" "$work/second.tgz" release

### Verbs, root and overrides

new_state
expect_refused "no verb" "usage: infra-apply" /dev/null
expect_refused "an unknown verb" "usage: infra-apply" /dev/null rollback
expect_refused "extra arguments" "usage: infra-apply" /dev/null release now
if [ "$(id -u)" -ne 0 ]; then
  if env -u INFRA_APPLY_STACK_DIR "$apply" status </dev/null >"$work/out" 2>&1; then cat "$work/out"; echo "FAIL ran without root"; exit 1; fi
  grep -q "must run as root" "$work/out" || { cat "$work/out"; echo "FAIL wrong refusal without root"; exit 1; }
  echo "ok   refused: running without root"
  if SUDO_USER=deploy INFRA_APPLY_STACK_DIR="$state/stack" INFRA_APPLY_HOST_FILE="$state/host.env" "$apply" status </dev/null >"$work/out" 2>&1; then
    cat "$work/out"; echo "FAIL honoured overrides under sudo"; exit 1
  fi
  grep -q "must run as root" "$work/out" || { cat "$work/out"; echo "FAIL overrides were honoured under sudo"; exit 1; }
  echo "ok   refused: path overrides under sudo"
fi

### The gate

gate_run() {
  rm -f "$state/sudo.args" "$state/sudo.stdin"
  PATH="$work/bin:$PATH" FAKE_STATE="$state" "$@" <"$work/good.tgz" >"$work/out" 2>&1
}
new_state
for verb in release status; do
  if ! gate_run env SSH_ORIGINAL_COMMAND="$verb" "$gate"; then cat "$work/out"; echo "FAIL gate refused $verb"; exit 1; fi
  [ "$(cat "$state/sudo.args")" = "-n /usr/local/sbin/infra-apply $verb" ] || { echo "FAIL gate ran: $(cat "$state/sudo.args")"; exit 1; }
  cmp -s "$work/good.tgz" "$state/sudo.stdin" || { echo "FAIL gate did not pass stdin through for $verb"; exit 1; }
  echo "ok   gate allows: $verb"
done
refuse_command() {
  local label="$1" rc=0
  shift
  gate_run "$@" "$gate" || rc=$?
  [ "$rc" -eq 64 ] || { cat "$work/out"; echo "FAIL gate exited $rc for: $label"; exit 1; }
  grep -q "infra-deploy-gate: refused; this key may only run one of: release, status" "$work/out" || { cat "$work/out"; echo "FAIL gate refused without its message: $label"; exit 1; }
  [ ! -e "$state/sudo.args" ] || { echo "FAIL gate called sudo for: $label"; exit 1; }
  echo "ok   gate refuses: $label"
}
refuse_command "an interactive login" env -u SSH_ORIGINAL_COMMAND
refuse_command "an empty command" env SSH_ORIGINAL_COMMAND=
refuse_command "rollback" env SSH_ORIGINAL_COMMAND=rollback
refuse_command "a chained command" env "SSH_ORIGINAL_COMMAND=release; id"
refuse_command "a verb with arguments" env SSH_ORIGINAL_COMMAND="status now"
refuse_command "a leading space" env SSH_ORIGINAL_COMMAND=" status"
refuse_command "a trailing newline" env SSH_ORIGINAL_COMMAND="$(printf 'status\nid')"
refuse_command "a shell" env SSH_ORIGINAL_COMMAND=bash
refuse_command "scp" env SSH_ORIGINAL_COMMAND="scp -t /tmp"
refuse_command "sftp" env SSH_ORIGINAL_COMMAND=internal-sftp
refuse_command "an upper-case verb" env SSH_ORIGINAL_COMMAND=RELEASE

echo "release-scripts: all cases passed"
