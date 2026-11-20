#!/bin/sh
# Integration test: builds the image, runs it against throwaway stacks in a
# temp folder and checks every response. Needs docker, curl and jq.
#   test/run.sh
set -eu

cd "$(dirname "$0")/.."
image=deploy-hook:test
name=deploy-hook-test
stacks=$(cd "$(mktemp -d)" && pwd -P)
token=0123456789abcdef0123456789abcdef
failed=0

# shellcheck disable=SC2329 # called by the trap
cleanup() {
  for d in "$stacks"/*/; do
    docker exec "$name" sh -c 'cd "$1" && docker compose down -t 0 -v' _ "$d" > /dev/null 2>&1 || true
  done
  docker rm -f "$name" > /dev/null 2>&1 || true
  rm -rf "$stacks"
}
trap cleanup EXIT

# stack <folder> <command> [token]: a one-service stack that is healthy when
# <command> keeps running.
stack() {
  mkdir -p "$stacks/$1/.deploy"
  cat > "$stacks/$1/compose.yaml" <<EOF
services:
  app:
    image: busybox:1.37
    command: ["sh", "-c", "$2"]
    healthcheck:
      test: ["CMD", "true"]
      interval: 1s
EOF
  [ -z "${3:-}" ] || echo "$3" > "$stacks/$1/.deploy/token"
}

stack 'Good App' 'sleep 600' "$token"
# shellcheck disable=SC2016 # expanded by the hook, not here
{
  echo 'echo "pre in $DEPLOY_ID"' > "$stacks/Good App/.deploy/pre-deploy.sh"
  echo 'echo "post in $STACK_DIR"' > "$stacks/Good App/.deploy/post-deploy.sh"
}
stack broken 'exit 1' "$token"
stack custom 'sleep 600' "$token"
echo renamed > "$stacks/custom/.deploy/id"
stack short 'sleep 600' tooshort
stack no-token 'sleep 600'
stack failing-pre 'sleep 600' "$token"
echo 'exit 3' > "$stacks/failing-pre/.deploy/pre-deploy.sh"

docker build -q -t "$image" . > /dev/null
docker run -d --name "$name" -p 127.0.0.1::9000 \
  -e STACKS_DIR="$stacks" -e DEPLOY_PRUNE=false -e DEPLOY_WAIT_TIMEOUT=20 \
  -v /var/run/docker.sock:/var/run/docker.sock -v "$stacks:$stacks" \
  "$image" > /dev/null
url=http://$(docker port "$name" 9000 | head -n 1)/hooks
i=0
until curl -fs "${url%/hooks}/" > /dev/null; do
  i=$((i + 1)); [ "$i" -lt 50 ] || { docker logs "$name"; exit 1; }
  sleep 0.2
done

# check <description> <expected status> <expected text or ''> <curl args...>
check() {
  desc=$1 want=$2 text=$3
  shift 3
  body=$(curl -s -w '\n%{http_code}' -X POST "$@")
  got=$(echo "$body" | tail -n 1)
  if [ "$got" = "$want" ] && { [ -z "$text" ] || echo "$body" | grep -q "$text"; }; then
    echo "ok   $desc"
  else
    echo "FAIL $desc: HTTP $got, wanted $want with '$text'"
    echo "$body" | sed 's/^/     /'
    failed=1
  fi
}

check 'deploys a stack with pre and post scripts' 200 'pre in good-app' \
  -H "X-Deploy-Token: $token" "$url/good-app"
check 'runs post-deploy with STACK_DIR' 200 "post in $stacks/Good App" \
  -H "X-Deploy-Token: $token" "$url/good-app"
check 'rejects a wrong token' 401 '' -H 'X-Deploy-Token: nope' "$url/good-app"
check 'rejects a missing token' 401 '' "$url/good-app"
check 'answers GET with 405' 405 '' -X GET -H "X-Deploy-Token: $token" "$url/good-app"
check 'fails when a service never gets healthy' 500 '== up' \
  -H "X-Deploy-Token: $token" "$url/broken"
check 'stops when pre-deploy fails' 500 '== pre-deploy' \
  -H "X-Deploy-Token: $token" "$url/failing-pre"
check 'uses .deploy/id' 200 '== up' -H "X-Deploy-Token: $token" "$url/renamed"
check 'skips a short token' 404 '' -H 'X-Deploy-Token: tooshort' "$url/short"
check 'has no hook without a token' 404 '' -H "X-Deploy-Token: $token" "$url/no-token"

echo "$token" > "$stacks/no-token/.deploy/token"
docker exec "$name" deploy-hook reload > /dev/null 2>&1
check 'picks up a new token on reload' 200 '== up' \
  -H "X-Deploy-Token: $token" "$url/no-token"

if docker logs "$name" 2>&1 | grep -q "$token"; then
  echo 'FAIL the log shows a token'
  failed=1
else
  echo 'ok   the log shows no token'
fi

exit "$failed"
