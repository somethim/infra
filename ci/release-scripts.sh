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
  if grep -qE '^(stop|start) ' "$state/calls"; then
    echo "FAIL Watchtower was stopped or started after a refusal: $name"; exit 1
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
  "cf_tunnel_token": "eyJHarnessTunnelToken0123456789abcdefABCDEFGHIJ",
  "webui_secret_key": "HarnessWebuiSecret0123456789abcdefABCDEF",
  "deploy_key_file": "$work/deploy_key.pub"
}
JSON
secrets=(ghp_HarnessToken0123456789 HarnessPgSuperuser0123456789abcdefA HarnessPrizmDb0123456789abcdefABCDEF
  HarnessPortfolioDb0123456789abcdefAB SGFybmVzc1RvdHBLZXkwMTIzNDU2Nzg5YWJjZGVmQUI= harness-portfolio-admin
  re_HarnessResendKey HarnessGoogleSecret HarnessHypernovaSession0123456789 harness-hypernova-admin
  eyJHarnessTunnelToken0123456789abcdefABCDEFGHIJ HarnessWebuiSecret0123456789abcdefABCDEF)

build() {
  "$root/build-bundle.sh" "$@" >"$work/build.log" 2>&1
}

build "$work/vars.json" "$work/good.tgz" || { cat "$work/build.log"; echo "FAIL build-bundle.sh"; exit 1; }
no_secret_in "$work/build.log" "build-bundle.sh"
build "$work/vars.json" "$work/good-again.tgz" || { cat "$work/build.log"; echo "FAIL build-bundle.sh (second build)"; exit 1; }
cmp -s "$work/good.tgz" "$work/good-again.tgz" || { echo "FAIL build-bundle.sh is not deterministic"; exit 1; }
echo "ok   bundle: two builds from the same vars are byte-identical"
if tar -tvzf "$work/good.tgz" | grep -qv '^-'; then tar -tvzf "$work/good.tgz"; echo "FAIL the bundle holds entries other than regular files"; exit 1; fi
[ "$(tar -tzf "$work/good.tgz" | wc -l)" -eq 19 ] || { tar -tzf "$work/good.tgz"; echo "FAIL the bundle does not hold exactly 19 files"; exit 1; }
echo "ok   bundle: 19 file entries, no directories"
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
    eyJHarnessTunnelToken*) echo tunnel/tunnel.env ;;
    HarnessWebuiSecret*) echo ai/open-webui.env ;;
    *) echo portfolio/portfolio.env ;;
  esac
}
for secret in "${secrets[@]}"; do
  found="$(cd "$work/good" && grep -rlF -- "$secret" . | sed 's,^\./,,' | LC_ALL=C sort | tr '\n' ' ')"
  want="$(owner_of "$secret" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')"
  [ "$found" = "$want" ] || { echo "FAIL a secret is in '$found', expected only '$want'"; exit 1; }
done
for file in portfolio/.env hypernova/.env ai/.env media/.env; do
  if grep -vqE '^(PORTFOLIO_IMAGE|PROVIDER_IMAGE|WEB_IMAGE|APEX_DOMAIN|WWW_DOMAIN|WEB_DOMAIN|AI_UID|AI_GID|OLLAMA_MODEL|MEDIA_UID|MEDIA_GID)=' "$work/good/$file"; then
    cat "$work/good/$file"; echo "FAIL $file holds more than image references, domains, the service accounts and the model"; exit 1
  fi
done
grep -qx 'OLLAMA_MODEL=qwen2.5:7b' "$work/good/ai/.env" || { echo "FAIL ai/.env does not name production.yml's ollama_model"; exit 1; }
grep -qx 'OLLAMA_MODEL=qwen2.5:7b' "$work/good/hypernova/provider.env" || { echo "FAIL hypernova's provider does not ask for production.yml's ollama_model"; exit 1; }
grep -qx 'OLLAMA_HOST=http://ollama:11434' "$work/good/hypernova/provider.env" || { echo "FAIL hypernova's provider does not reach Ollama on llm"; exit 1; }
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
render_refused "no tunnel token" 'del(.cf_tunnel_token)'
render_refused "a tunnel token that is not one Cloudflare issues" '.cf_tunnel_token = "not-a-tunnel-token"'
render_refused "no Open WebUI key" 'del(.webui_secret_key)'
render_refused "a short Open WebUI key" '.webui_secret_key = "short"'
printf 'REPLACE_ME_BEFORE_DEPLOYING\n' >"$work/placeholder.pub"
render_refused "the placeholder deploy key" ".deploy_key_file = \"$work/placeholder.pub\""

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
for stack in database portfolio hypernova tunnel ai media; do
  grep -q "compose model accepted: .* in the $stack stack, no privileged settings" "$work/out" || { cat "$work/out"; echo "FAIL the checked-in $stack stack did not pass the compose guard"; exit 1; }
done
grep -qF "compose model accepted: 3 service(s) in the ai stack, no privileged settings, no host port but open-webui $tailscale_ip:8080 on the tailnet, no bind mount but none, the GPU only for ollama, no Docker socket" "$work/out" ||
  { cat "$work/out"; echo "FAIL the ai stack summary does not name its one tailnet port and its GPU"; exit 1; }
grep -qF "compose model accepted: 3 service(s) in the media stack, no privileged settings, no host port but audiobookshelf $tailscale_ip:13378, jellyfin $tailscale_ip:8096, kavita $tailscale_ip:5000 on the tailnet, no bind mount but audiobookshelf /srv/media/audiobooks, audiobookshelf /srv/media/podcasts, jellyfin /srv/media/shows (ro), jellyfin /srv/media/movies (ro), kavita /srv/media/books (ro), the GPU only for jellyfin, no Docker socket" "$work/out" ||
  { cat "$work/out"; echo "FAIL the media stack summary does not name its tailnet ports, library mounts and GPU"; exit 1; }
echo "ok   the six checked-in stacks pass the compose guard"
[ -f "$state/stack/releases/$first_id/.verified" ] || { echo "FAIL the release was not marked verified"; exit 1; }
for file in ghcr.env database/postgres.env database/provision.sql portfolio/.env portfolio/portfolio.env hypernova/.env hypernova/provider.env tunnel/tunnel.env ai/.env ai/open-webui.env media/.env manifest.sha256; do
  [ "$(stat -c %a "$state/stack/current/$file")" = 600 ] || { echo "FAIL $file is not 0600 in the release"; exit 1; }
done
[ "$(stat -c %a "$state/stack/current/portfolio/docker-compose.yml")" = 644 ] || { echo "FAIL docker-compose.yml is not 0644"; exit 1; }
[ "$(cat "$state/login.stdin")" = ghp_HarnessToken0123456789 ] || { echo "FAIL docker login did not receive the token on stdin"; exit 1; }
grep -q '^login ghcr.io --username infra-bot --password-stdin$' "$state/calls" || { echo "FAIL docker login did not use the GHCR username"; exit 1; }
cmp -s "$state/psql.stdin" "$work/good/database/provision.sql" || { echo "FAIL provision.sql was not fed to psql"; exit 1; }
order="$(grep -nE '^compose .*/(database|portfolio|hypernova|tunnel|ai|media) (pull --quiet|up -d.*)$|^exec -i postgresql psql -v ON_ERROR_STOP=1 -U postgres -d postgres$' "$state/calls" | sed -E 's,^[0-9]+:,,; s,^compose .*/(database|portfolio|hypernova|tunnel|ai|media) ,\1 ,; s,^exec .*,psql,')"
want_order="$(printf '%s\n' 'database pull --quiet' 'portfolio pull --quiet' 'hypernova pull --quiet' 'tunnel pull --quiet' 'ai pull --quiet' 'media pull --quiet' 'database up -d --wait --remove-orphans' psql \
  'portfolio up -d --remove-orphans' 'hypernova up -d --remove-orphans' 'tunnel up -d --remove-orphans' 'ai up -d --remove-orphans' 'media up -d --remove-orphans')"
[ "$order" = "$want_order" ] || { printf '%s\n' "$order"; echo "FAIL the stacks did not start in the order database, provision.sql, portfolio, hypernova, tunnel, ai, media"; exit 1; }
grep -qE '^compose --file [^ ]*/stack/current/portfolio/docker-compose.yml' "$state/calls" || { echo "FAIL portfolio did not start from the current link"; exit 1; }
for want in "curl route arbikullakshi.com http://172.18.0.2:80/api/health" "curl route www.arbikullakshi.com http://172.18.0.2:80/" \
  "curl route hypernova.arbikullakshi.com http://172.18.0.2:80/" "curl route hypernova.arbikullakshi.com http://172.18.0.2:80/api/health" \
  "curl ready http://172.18.0.9:2000/ready"; do
  grep -qxF "$want" "$state/calls" || { grep '^curl' "$state/calls"; echo "FAIL verify did not check: $want"; exit 1; }
done
[ "$(grep -c '^curl ' "$state/calls")" -eq 5 ] || { grep '^curl' "$state/calls"; echo "FAIL verify checked more than the four routes and the tunnel"; exit 1; }
grep -qF "infra-apply: the tailnet-only ports open-webui:8080 jellyfin:8096 audiobookshelf:13378 kavita:5000 are bound to $tailscale_ip alone" "$work/out" || { cat "$work/out"; echo "FAIL verify did not read back the tailnet-only port"; exit 1; }
[ ! -e "$state/stack/previous" ] || { echo "FAIL a first release has no previous release"; exit 1; }
printf '%s\n' "portfolio=$portfolio_repo@$(d 11)" "prizm-provider=$provider_repo@$(d 21)" "prizm-web=$web_repo@$(d 31)" |
  cmp -s - "$state/stack/current/running-images.env" || { cat "$state/stack/current/running-images.env"; echo "FAIL running-images.env does not record the running digests"; exit 1; }
echo "ok   a first release pulls, starts database, provision.sql, portfolio, hypernova, tunnel in order, checks each route through Traefik and the tunnel's /ready, and records the running digests"

# watchtower_order <name> [steps]: Watchtower was stopped before the first pull,
# started after the last app `up` and before verify read its logs, and runs again.
watchtower_order() {
  local name="$1" want="${2:-stop pull up start logs}" got
  got="$(grep -nE '^stop --time [0-9]+ watchtower$|^start watchtower$|^compose .* pull --quiet$|^compose .*/hypernova up |^logs --since .* watchtower$' "$state/calls" |
    sed -E 's,^[0-9]+:,,; s,^stop .*,stop,; s,^start .*,start,; s,^compose .* pull .*,pull,; s,^compose .* up .*,up,; s,^logs .*,logs,' | uniq)"
  [ "$got" = "$(tr ' ' '\n' <<<"$want")" ] || { printf '%s\n' "$got"; echo "FAIL Watchtower was not stopped from the pull to the app up: $name"; exit 1; }
  [ "$(cat "$state/running/watchtower")" = "true false" ] || { echo "FAIL Watchtower does not run after: $name"; exit 1; }
}
watchtower_order "a first release"
echo "ok   Watchtower is stopped from the first pull until the app stacks are up, then started before verify"

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
printf '000' >"$state/curl.hypernova.arbikullakshi.com"
echo 7 >"$state/curl.hypernova.arbikullakshi.com.rc"
expect_refused "Traefik refuses the connection" "Traefik answered 000 for hypernova\\.arbikullakshi\\.com/, expected" "$work/good.tgz" release
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a release Traefik did not answer for was marked verified"; exit 1; }

new_state
printf '503' >"$state/curl.ready"
expect_refused "a tunnel with no connection to Cloudflare" "cloudflared answered 503 on /ready: the tunnel holds no connection to Cloudflare" "$work/good.tgz" release
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a release whose tunnel is down was marked verified"; exit 1; }

new_state
printf '000' >"$state/curl.ready"
echo 7 >"$state/curl.ready.rc"
expect_refused "a cloudflared that does not answer on its metrics port" "cloudflared answered 000 on /ready" "$work/good.tgz" release

new_state
: >"$state/ip/cloudflared"
expect_refused "a cloudflared with no edge address" "cloudflared has no address on the edge network" "$work/good.tgz" release

new_state
rm "$state/ip/edge-traefik"
expect_refused "a Traefik with no edge address" "edge-traefik has no address on the edge network" "$work/good.tgz" release

new_state
printf '200' >"$state/curl.www.arbikullakshi.com"
expect_refused "www served instead of redirected to the apex" "Traefik answered 200 for www\\.arbikullakshi\\.com/, expected \\^30\\[18\\]\\$" "$work/good.tgz" release
echo "ok   verify requires each route's own status through Traefik and a connected tunnel"

new_state
tailnet_binding open-webui 8080 0.0.0.0
expect_refused "Open WebUI bound to every interface" "open-webui publishes .*0\\.0\\.0\\.0.*, expected only $tailscale_ip:8080" "$work/good.tgz" release
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a release with a port off the tailnet was marked verified"; exit 1; }
new_state
printf '{"8080/tcp":[{"HostIp":"%s","HostPort":"8080"}],"9090/tcp":[{"HostIp":"%s","HostPort":"9090"}]}\n' "$tailscale_ip" "$tailscale_ip" >"$state/ports/open-webui"
expect_refused "Open WebUI with a second binding" "open-webui publishes .*9090.*, expected only" "$work/good.tgz" release
new_state
tailnet_binding jellyfin 8096 192.168.1.50
expect_refused "Jellyfin on the LAN address" "jellyfin publishes .*192\\.168\\.1\\.50.*, expected only $tailscale_ip:8096" "$work/good.tgz" release
new_state
rm "$state/ports/kavita"
expect_refused "Kavita not published at all" "kavita publishes \\{\\}, expected only $tailscale_ip:5000" "$work/good.tgz" release
echo "ok   verify requires each tailnet-only port bound to the Tailscale address alone"

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
(cd "$work/withdir" && tar --create --gzip --file "$work/withdir.tgz" --owner=0 --group=0 manifest.sha256 release.env ghcr.env database portfolio hypernova tunnel ai media)
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

variant badtunnel
printf 'TUNNEL_TOKEN=eyJx\nTUNNEL_ORIGIN_CERT=/etc/passwd\n' >"$work/badtunnel/tunnel/tunnel.env"
repack badtunnel
refused_bundle "tunnel.env with an extra key" "tunnel/tunnel\\.env must set exactly TUNNEL_TOKEN" "$work/badtunnel.tgz"

variant badwebui
printf 'WEBUI_SECRET_KEY=HarnessWebuiSecret0123456789abcdefABCDEF\nOPENAI_API_KEY=x\n' >"$work/badwebui/ai/open-webui.env"
repack badwebui
refused_bundle "open-webui.env with an extra key" "ai/open-webui\\.env must set exactly WEBUI_SECRET_KEY" "$work/badwebui.tgz"

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
grep -q '^stop --time [0-9]* watchtower$' "$state/calls" || { echo "FAIL Watchtower was not stopped before the pull"; exit 1; }
grep -q '^start watchtower$' "$state/calls" || { echo "FAIL Watchtower was not started again after a failed pull"; exit 1; }
[ "$(cat "$state/running/watchtower")" = "true false" ] || { echo "FAIL Watchtower does not run after a failed pull"; exit 1; }
echo "ok   a failed pull starts Watchtower again"

installed_state
echo 1 >"$state/stop.rc"
expect_refused "Watchtower cannot be stopped" "Watchtower could not be stopped, so it could race the release; the running release is untouched" "$work/good.tgz" release
grep -qE '^compose .* (pull|up)( |$)' "$state/calls" && { echo "FAIL the stacks were touched when Watchtower could not be stopped"; exit 1; }
grep -q '^start watchtower$' "$state/calls" || { echo "FAIL Watchtower was not started after a failed stop"; exit 1; }
[ "$(current_release)" = "$base_id" ] || { echo "FAIL a failed Watchtower stop moved current"; exit 1; }
[ "$(find "$state/stack/releases" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] || { echo "FAIL a failed Watchtower stop left its release on disk"; exit 1; }

installed_state
rm "$state/running/watchtower"
expect_refused "a release on a host without Watchtower" "watchtower is not running; run provisioning" "$work/second.tgz" release
grep -qE '^(stop|start) ' "$state/calls" && { echo "FAIL infra-apply stopped or started a Watchtower that was not running"; exit 1; }
echo "ok   a Watchtower that is not running is neither stopped nor started"

new_state
rm "$state/edge/docker-compose.yml"
expect_refused "a host whose edge was never provisioned" "edge/docker-compose\\.yml does not exist, so no Traefik routes the stacks" "$work/good.tgz" release
new_state
sed -i "s,^PORTFOLIO_IMAGE_REPO=.*,PORTFOLIO_IMAGE_REPO=not a repo," "$state/host.env"
expect_refused "a host.env with a malformed repository" "PORTFOLIO_IMAGE_REPO is not an image repository" "$work/good.tgz" release
new_state
sed -i '/^TAILSCALE_IP=/d' "$state/host.env"
expect_refused "a host.env without the Tailscale address" "TAILSCALE_IP is not this host's Tailscale IPv4" "$work/good.tgz" release
new_state
sed -i 's,^TAILSCALE_IP=.*,TAILSCALE_IP=192.168.1.50,' "$state/host.env"
expect_refused "a host.env naming a LAN address as the Tailscale address" "TAILSCALE_IP is not this host's Tailscale IPv4" "$work/good.tgz" release
new_state
sed -i 's,^AI_USER=.*,AI_USER=0:0,' "$state/host.env"
expect_refused "a host.env naming root as the ai account" "AI_USER is not the <uid>:<gid> of the ai account" "$work/good.tgz" release
new_state
sed -i '/^MEDIA_USER=/d' "$state/host.env"
expect_refused "a host.env without the media account" "MEDIA_USER is not the <uid>:<gid> of the media account" "$work/good.tgz" release
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
compose_case "a traefik label on cloudflared" tunnel "service cloudflared sets the label traefik.enable; the tunnel stack is never routed or auto-updated" "text = text.replace('      - autoheal=true\n', '      - autoheal=true\n      - traefik.enable=true\n')"
compose_case "a published metrics port" tunnel "service cloudflared sets ports, which publishes a host port" "text = text.replace('    restart: always\n', '    restart: always\n    ports: [\"2000:2000\"]\n')"
compose_case "cloudflared on the data network" tunnel 'network data is "data"; the tunnel stack may only join the existing network\(s\) edge' "text = text.replace('    networks:\n      - edge\n    labels:', '    networks:\n      - edge\n      - data\n    labels:').replace('networks:\n  edge:\n    name: edge\n    external: true\n', 'networks:\n  edge:\n    name: edge\n    external: true\n  data:\n    name: data\n    external: true\n')"
compose_case "a volume on the tunnel" tunnel 'the volumes are \["state"\]; the tunnel stack uses exactly \[\]' "text = text.replace('    labels:\n      - autoheal', '    volumes:\n      - state:/state\n    labels:\n      - autoheal') + 'volumes:\n  state:\n'"
compose_case "an unpinned cloudflared" tunnel 'service cloudflared runs "cloudflare/cloudflared:latest"' "import re; text = re.sub(r'image: cloudflare/cloudflared:\S+', 'image: cloudflare/cloudflared:latest', text)"
# The ai stack: tailnet-only, hardened, the GPU for Ollama alone.
# shellcheck disable=SC2016 # the compose text, ${TAILSCALE_IP} literal
owui_port='      - "${TAILSCALE_IP}:8080:8080"\n'
compose_case "Open WebUI on every interface" ai 'service open-webui publishes \["8080:8080"\]; it may publish exactly \["\$\{TAILSCALE_IP\}:8080:8080"\]' "text = text.replace('$owui_port', '      - \"8080:8080\"\n')"
compose_case "Open WebUI on a literal address" ai 'service open-webui publishes \["100.101.102.103:8080:8080"\]' "text = text.replace('$owui_port', '      - \"100.101.102.103:8080:8080\"\n')"
compose_case "Open WebUI on a LAN address by default" ai 'service open-webui publishes \["\$\{OWUI_IP:-192.168.1.50\}:8080:8080"\]' "text = text.replace('\${TAILSCALE_IP}:8080:8080', '\${OWUI_IP:-192.168.1.50}:8080:8080')"
compose_case "a second Open WebUI port" ai 'service open-webui publishes \[".*8080:8080", ".*:8081:8080"\]' "text = text.replace('$owui_port', '$owui_port      - \"\${TAILSCALE_IP}:8081:8080\"\n')"
compose_case "ports in flow style" ai "service open-webui writes ports in a form other than a list" "text = text.replace('    ports:\n$owui_port', '    ports: [\"\${TAILSCALE_IP}:8080:8080\"]\n')"
compose_case "Ollama published on the tailnet" ai "service ollama sets ports, which publishes a host port" "text = text.replace('    container_name: ollama\n', '    container_name: ollama\n    ports:\n      - \"\${TAILSCALE_IP}:11434:11434\"\n')"
compose_case "the GPU for Open WebUI" ai "service open-webui sets deploy, which can reserve host devices; only jellyfin, ollama may reserve the GPU" "text = text.replace('    container_name: open-webui\n', '    container_name: open-webui\n    deploy:\n      resources:\n        reservations:\n          devices:\n            - driver: nvidia\n              count: all\n              capabilities: [gpu]\n')"
compose_case "Ollama with deploy labels" ai "service ollama sets deploy .*; it may only reserve all NVIDIA GPUs" "text = text.replace('    deploy:\n      resources:', '    deploy:\n      labels:\n        x-extra: \"1\"\n      resources:', 1)"
compose_case "Ollama reserving more than the GPU" ai "service ollama sets deploy .*; it may only reserve all NVIDIA GPUs" "text = text.replace('capabilities: [gpu]', 'capabilities: [gpu, utility]')"
compose_case "Ollama as root" ai 'service ollama runs as "0:0"; it must run as 2001:2001' "text = text.replace('    container_name: ollama\n    user: \"\${AI_UID}:\${AI_GID}\"\n', '    container_name: ollama\n    user: \"0:0\"\n')"
compose_case "Open WebUI without a memory limit" ai "service open-webui sets no mem_limit" "text = text.replace('    mem_limit: 2g\n', '')"
compose_case "Open WebUI keeping its capabilities" ai "service open-webui does not drop every capability" "text = text.replace('    container_name: open-webui\n    user: \"\${AI_UID}:\${AI_GID}\"\n    mem_limit: 2g\n    restart: always\n    cap_drop: [ALL]\n', '    container_name: open-webui\n    user: \"\${AI_UID}:\${AI_GID}\"\n    mem_limit: 2g\n    restart: always\n')"
compose_case "Ollama on the data network" ai 'network data is "data"; the ai stack may only join' "text = text.replace('      - ai\n      - llm\n', '      - ai\n      - llm\n      - data\n', 1).replace('networks:\n  ai:\n', 'networks:\n  data:\n    name: data\n    external: true\n  ai:\n')"
compose_case "Open WebUI on llm" ai "service open-webui joins llm; open-webui may only join ai" "text = text.replace('    depends_on:\n      - ollama\n    networks:\n      - ai\n', '    depends_on:\n      - ollama\n    networks:\n      - ai\n      - llm\n')"
compose_case "Ollama reading Open WebUI's secret" ai 'service ollama reads env_file ".*open-webui.env"; in the ai stack open-webui may read an env file' "text = text.replace('    environment:\n      # The models', '    env_file: open-webui.env\n    environment:\n      # The models')"
compose_case "a bind mount into Ollama" ai 'service ollama has a "bind" mount of "/srv/media"' "text = text.replace('    volumes:\n      - type: volume\n        source: ollama-models\n', '    volumes:\n      - /srv/media:/media:ro\n      - type: volume\n        source: ollama-models\n')"
compose_case "a Watchtower label on Ollama" ai "service ollama sets the label com.centurylinklabs.watchtower.enable" "text = text.replace('      - autoheal=true\n', '      - autoheal=true\n      - com.centurylinklabs.watchtower.enable=true\n', 1)"
compose_case "a service named apart from its container" ai 'service pull names its container "ollama-pull"' "text = text.replace('  ollama-pull:\n    image:', '  pull:\n    image:')"
compose_case "the tailnet port moved to another service name" ai "service webui sets ports, which publishes a host port" "text = text.replace('  open-webui:\n    image:', '  webui:\n    image:')"
compose_case "the models volume created by the release" ai 'volume ollama-models is "ollama-models"; the ai stack keeps its data in "ollama-models" \(external\)' "text = text.replace('  ollama-models:\n    name: ollama-models\n    external: true\n', '  ollama-models:\n    name: ollama-models\n')"
compose_case "hypernova's web app on llm" hypernova "service web joins llm; prizm-web may only join edge" "text = text.replace('    networks:\n      - edge\n    labels:', '    networks:\n      - edge\n      - llm\n    labels:')"

# The media stack: tailnet-only, hardened, only the library folders, the GPU for Jellyfin alone.
shows_mount='      - type: bind\n        source: /srv/media/shows\n        target: /media/shows\n        read_only: true\n'
compose_case "Jellyfin on every interface" media 'service jellyfin publishes \["0.0.0.0:8096:8096"\]' "text = text.replace('\${TAILSCALE_IP}:8096:8096', '0.0.0.0:8096:8096')"
compose_case "Kavita published on a second port" media 'service kavita publishes \[".*:5000:5000", ".*:5001:5001"\]' "text = text.replace('      - \"\${TAILSCALE_IP}:5000:5000\"\n', '      - \"\${TAILSCALE_IP}:5000:5000\"\n      - \"\${TAILSCALE_IP}:5001:5001\"\n')"
compose_case "the whole disk in Jellyfin" media 'service jellyfin has a "bind" mount of "/srv/media"; a release may only use its named volumes and tmpfs, and /srv/media/movies, /srv/media/shows' "text = text.replace('        source: /srv/media/shows\n', '        source: /srv/media\n')"
compose_case "Jellyfin writing the library" media 'service jellyfin mounts /srv/media/shows as .*; it may only mount it at /media/shows read-only' "text = text.replace('$shows_mount', '$shows_mount'.replace('        read_only: true\n', ''))"
compose_case "a library folder in the short syntax" media 'service kavita mounts /srv/media/books as .*"bind": \{(\}|"create_host_path": true\})' "text = text.replace('      - type: bind\n        source: /srv/media/books\n        target: /books\n        read_only: true\n        bind:\n          create_host_path: false\n', '      - /srv/media/books:/books:ro\n')"
compose_case "a shared mount propagation" media 'service jellyfin mounts /srv/media/movies as' "text = text.replace('        target: /media/movies\n        read_only: true\n        bind:\n          create_host_path: false\n', '        target: /media/movies\n        read_only: true\n        bind:\n          create_host_path: false\n          propagation: rshared\n')"
compose_case "the podcasts folder in Kavita" media 'service kavita has a "bind" mount of "/srv/media/podcasts"' "text = text.replace('        source: /srv/media/books\n', '        source: /srv/media/podcasts\n')"
compose_case "the host's /etc in Audiobookshelf" media 'service audiobookshelf has a "bind" mount of "/etc"' "text = text.replace('        source: /srv/media/podcasts\n', '        source: /etc\n')"
compose_case "Kavita as root" media 'service kavita runs as "0:0"; it must run as 2000:2000' "text = text.replace('    container_name: kavita\n    user: \"\${MEDIA_UID}:\${MEDIA_GID}\"\n', '    container_name: kavita\n    user: \"0:0\"\n')"
compose_case "the GPU for Audiobookshelf" media "service audiobookshelf sets deploy, which can reserve host devices; only jellyfin, ollama may reserve the GPU" "text = text.replace('    container_name: audiobookshelf\n', '    container_name: audiobookshelf\n    deploy:\n      resources:\n        reservations:\n          devices:\n            - driver: nvidia\n              count: all\n              capabilities: [gpu]\n')"
compose_case "Jellyfin on the edge network" media 'network edge is "edge"; the media stack may only join the existing network\(s\) media' "text = text.replace('    networks:\n      - media\n    labels:', '    networks:\n      - media\n      - edge\n    labels:', 1).replace('networks:\n  media:\n', 'networks:\n  edge:\n    name: edge\n    external: true\n  media:\n')"
compose_case "a Traefik route to Jellyfin" media "service jellyfin sets the label traefik.enable" "text = text.replace('      - autoheal=true\n', '      - autoheal=true\n      - traefik.enable=true\n', 1)"
compose_case "an env file in the media stack" media 'service kavita reads env_file ".*"; the media stack may only read no env file' "text = text.replace('    container_name: kavita\n', '    container_name: kavita\n    env_file: ../ai/open-webui.env\n')"
# The guard on its own, against the resolved models of the checked-in stacks.
for stack in database portfolio hypernova tunnel ai media; do
  repos=()
  case "$stack" in
    portfolio) repos=("$portfolio_repo") ;;
    hypernova) repos=("$provider_repo" "$web_repo") ;;
    ai) repos=(--service-user=2001:2001) ;;
    media) repos=(--service-user=2000:2000) ;;
  esac
  TAILSCALE_IP="$tailscale_ip" "$REAL_DOCKER" compose --file "$work/good/$stack/docker-compose.yml" --project-directory "$work/good/$stack" config --no-env-resolution --format json >"$work/$stack.json"
  python3 -I "$guard" "$work/$stack.json" "$work/good/$stack" "$stack" "--tailscale-ip=$tailscale_ip" "${repos[@]}" >"$work/guard.out" || { cat "$work/guard.out"; echo "FAIL the guard refuses the checked-in $stack stack"; exit 1; }
done
if python3 -I "$guard" "$work/ai.json" "$work/good/ai" ai "--tailscale-ip=$tailscale_ip" >"$work/guard.out"; then echo "FAIL the guard accepted the ai stack without its service account"; exit 1; fi
if python3 -I "$guard" "$work/ai.json" "$work/good/ai" ai --service-user=2001:2001 >"$work/guard.out"; then echo "FAIL the guard accepted a tailnet port without the Tailscale address"; exit 1; fi
if python3 -I "$guard" "$work/ai.json" "$work/good/ai" ai --tailscale-ip=100.101.102.104 --service-user=2001:2001 >"$work/guard.out"; then echo "FAIL the guard accepted a port bound to another address"; exit 1; fi
grep -qF "it may publish exactly tcp 8080 on 100.101.102.104" "$work/guard.out" || { cat "$work/guard.out"; echo "FAIL wrong refusal for a port on another address"; exit 1; }
if python3 -I "$guard" "$work/ai.json" "$work/good/ai" ai --tailscale-ip=192.168.1.50 --service-user=2001:2001 >"$work/guard.out"; then echo "FAIL the guard took a LAN address for the Tailscale one"; exit 1; fi
if python3 -I "$guard" "$work/media.json" "$work/good/media" media "--tailscale-ip=$tailscale_ip" --service-user=2001:2001 >"$work/guard.out"; then echo "FAIL the guard ran the media stack as the ai account"; exit 1; fi
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
grep -q '^start watchtower$' "$state/calls" || { echo "FAIL Watchtower was not started again after a provision failure"; exit 1; }
[ "$(cat "$state/running/watchtower")" = "true false" ] || { echo "FAIL Watchtower does not run after a provision failure"; exit 1; }
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
grep -q '^start watchtower$' "$state/calls" || { echo "FAIL Watchtower was not started again after an app start failure"; exit 1; }
[ "$(cat "$state/running/watchtower")" = "true false" ] || { echo "FAIL Watchtower does not run after an app start failure"; exit 1; }
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
watchtower_order "a crash-looping release" "stop pull up start"
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

# F-008: a container that compose ps lists but docker inspect no longer finds
# (Watchtower recreated it in between) is pending, never silently skipped.
installed_state
sleep 1
touch "$state/vanished/c4"
expect_refused "a listed container is gone before the inspect" "not ready after 1s: 1 of 11 listed containers could not be inspected" "$work/second.tgz" release
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a release with an uninspected container was marked verified"; exit 1; }
grep -q '^curl ' "$state/calls" && { echo "FAIL the routes were checked before every container was inspected"; exit 1; }

installed_state
sleep 1
for c in c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11; do touch "$state/vanished/$c"; done
expect_refused "every listed container is gone before the inspect" "not ready after 1s: 11 of 11 listed containers could not be inspected" "$work/second.tgz" release
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a release with no inspected container was marked verified"; exit 1; }

installed_state
sleep 1
touch "$state/vanished-once/c3"
expect_ok "a container gone for one poll is checked on the next" "every container is running and healthy" "$work/second.tgz" release
[ "$(grep -c '^inspect ' "$state/calls")" -ge 2 ] || { echo "FAIL verify did not poll again after an uninspected container"; exit 1; }

installed_state
sleep 1
echo 1 >"$state/ps.database.rc"
expect_refused "docker compose ps fails for one stack" "not ready after 1s: docker compose ps failed for database" "$work/second.tgz" release
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a release whose database containers were not listed was marked verified"; exit 1; }
echo "ok   a container that compose ps lists but verify cannot inspect is never taken as ready"

installed_state
sleep 1
printf '404' >"$state/curl.www.arbikullakshi.com"
expect_refused "Traefik answers 404 for a host" "Traefik answered 404 for www\\.arbikullakshi\\.com/, expected .*404: no router serves" "$work/second.tgz" release
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
