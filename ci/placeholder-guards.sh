#!/usr/bin/env bash
# Tests tasks/placeholder-guards.yml: the deploy key file must hold a key line
# and no REPLACE_ME_BEFORE_DEPLOYING marker outside comments. Also proves that
# provision.yml and release.yml both run the guard.
#
#   bash ci/placeholder-guards.sh
#
# Prints "ok   ..." per case and stops with "FAIL ..." on the first failure.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

run() {
  ansible-playbook -i localhost, -c local "$here/placeholder-guards.yml" "$@" </dev/null >"$work/out.log" 2>&1
}
expect_pass() {
  local name="$1"
  shift
  if run "$@"; then echo "ok   pass: $name"; else cat "$work/out.log"; echo "FAIL expected pass: $name"; exit 1; fi
}
expect_refused() {
  local name="$1"
  shift
  if run "$@"; then cat "$work/out.log"; echo "FAIL expected refusal: $name"; exit 1; fi
  grep -q "empty or still the placeholder" "$work/out.log" || { cat "$work/out.log"; echo "FAIL refused for the wrong reason: $name"; exit 1; }
  echo "ok   refused: $name"
}

key="$root/roles/common/files/deploy_key.pub"
real_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeGuardFakeGuardFakeGuardFakeGuardFake01 infra-deploy-test'
printf 'REPLACE_ME_BEFORE_DEPLOYING\n' >"$work/key-placeholder.pub"
printf '# REPLACE_ME_BEFORE_DEPLOYING was here once\n%s\n' "$real_key" >"$work/key-comment.pub"
printf '# only a comment\n\n' >"$work/key-empty.pub"

# The committed key: refused while it is still the placeholder, accepted once
# the owner commits a real key line.
if grep -v '^[[:space:]]*#' "$key" | grep -q 'REPLACE_ME_BEFORE_DEPLOYING'; then
  expect_refused "the committed deploy key (still the placeholder)"
else
  expect_pass "the committed deploy key (a real key line)"
fi
expect_refused "a placeholder deploy key" -e "deploy_key_file=$work/key-placeholder.pub"
expect_pass "the marker only in a comment above a real key" -e "deploy_key_file=$work/key-comment.pub"
expect_refused "a deploy key file with only comments" -e "deploy_key_file=$work/key-empty.pub"

# Both playbooks run the guard before anything else can happen.
guard_task="$(sed -n 's/^- name: //p' "$root/tasks/placeholder-guards.yml" | head -n 1)"
[ -n "$guard_task" ] || { echo "FAIL tasks/placeholder-guards.yml has no named task"; exit 1; }
for playbook in provision.yml release.yml; do
  inventory="localhost,"
  [ "$playbook" = provision.yml ] && inventory="$root/inventory/hosts.example"
  ansible-playbook --list-tasks -i "$inventory" "$root/$playbook" </dev/null >"$work/tasks.log" 2>&1 ||
    { cat "$work/tasks.log"; echo "FAIL ansible-playbook --list-tasks $playbook"; exit 1; }
  grep -qF -- "$guard_task" "$work/tasks.log" || { cat "$work/tasks.log"; echo "FAIL $playbook does not run the placeholder guard"; exit 1; }
  echo "ok   $playbook runs the placeholder guard"
done

echo "placeholder guards: all cases behaved"
