#!/usr/bin/env bash
# Checks the gaps in ../README.md against the emulator you're running now.
#   source ../../scripts/emulator-env.sh && ./run.sh [aurora|security-group|provider6|ecs|rds-mysql|lambda-rds ...]
# Each check gets its own Terraform folder and state, applies, prints what
# happened, and destroys what it made. A check that fails can also fail to
# destroy; what it made stays in the emulator's memory until you stop it, so
# the local state is dropped and the next run starts clean. It refuses to run
# anywhere but the emulator, like up.sh. All six take about 5 minutes.
set -uo pipefail
cd "$(dirname "$0")"

case "${AWS_ENDPOINT_URL:-}" in
  https://127.0.0.1:*) ;;
  *) echo "Refusing: AWS_ENDPOINT_URL is not the emulator. Source scripts/emulator-env.sh first." >&2; exit 1 ;;
esac
if [ "$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" != "000000000000" ]; then
  echo "Refusing: the account is not the emulator's 000000000000." >&2; exit 1
fi

SUFFIX="-$(date +%s)"

apply() {
  terraform -chdir="$1" init -input=false -no-color >/dev/null || return 1
  terraform -chdir="$1" apply -auto-approve -input=false -no-color -var "suffix=$SUFFIX" > "$1/apply.log" 2>&1
}
destroy() {
  terraform -chdir="$1" destroy -auto-approve -input=false -no-color -var "suffix=$SUFFIX" > "$1/destroy.log" 2>&1 || true
  rm -f "$1"/terraform.tfstate "$1"/terraform.tfstate.backup
}
report() {  # name, status, detail
  printf '%-15s %-6s %s\n' "$1" "$2" "$3"
}
first_error() {
  grep -m1 -E 'Error:|error' "$1/apply.log" | sed 's/^│ *//' | cut -c1-160
}

check_tf() {
  if apply "$1"; then report "$1" works "applied with no error"
  else report "$1" FAILS "$(first_error "$1")"; fi
  destroy "$1"
}

check_ecs() {
  if ! apply ecs; then report ecs FAILS "$(first_error ecs)"; destroy ecs; return; fi
  local cluster td subnet task status reason
  cluster=$(terraform -chdir=ecs output -raw cluster)
  td=$(terraform -chdir=ecs output -raw task_definition)
  subnet=$(terraform -chdir=ecs output -raw subnet)
  local logs
  logs=$(terraform -chdir=ecs output -raw log_group)
  # Runs one task and waits for it to stop. Prints "status (reason exit)" on
  # the first line and the task's log on the second. $1 is an optional
  # command override as JSON.
  run_one() {
    local overrides=() task status reason output
    [ -n "${1:-}" ] && overrides=(--overrides "{\"containerOverrides\":[{\"name\":\"probe\",\"command\":$1}]}")
    task=$(aws ecs run-task --cluster "$cluster" --task-definition "$td" --launch-type FARGATE \
      --network-configuration "awsvpcConfiguration={subnets=[$subnet],assignPublicIp=ENABLED}" \
      "${overrides[@]}" --query 'tasks[0].taskArn' --output text 2>&1)
    if [[ "$task" != arn:* ]]; then printf 'run-task: %s\n\n' "$task"; return; fi
    for _ in $(seq 1 40); do
      status=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task" --query 'tasks[0].lastStatus' --output text)
      [ "$status" = STOPPED ] && break
      sleep 2
    done
    reason=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task" \
      --query 'tasks[0].[stoppedReason, containers[0].exitCode]' --output text | tr '\t' ' ')
    sleep 2
    output=$(aws logs tail "$logs" --format short --since 5m 2>/dev/null | cut -c21- | tr '\n' ' ')
    aws ecs stop-task --cluster "$cluster" --task "$task" >/dev/null 2>&1 || true
    printf '%s (%s)\n%s\n' "$status" "$reason" "$output"
  }
  # First a command the emulator can answer by itself (a plain echo, no shell).
  local plain plain_log
  { read -r plain; read -r plain_log; } < <(run_one '["echo","plain-echo-ok"]')
  local plain_note="a plain echo did not reach the log"
  [[ "$plain_log" == *plain-echo-ok* ]] && plain_note="a plain echo reached the log"
  # Then the task's own command, which needs the image: busybox's sh for
  # $((6*7)) and its uname. A real busybox prints "ran-42" and "Linux", then exits 0.
  local image image_log
  { read -r image; read -r image_log; } < <(run_one)
  image_log=$(sed 's/plain-echo-ok//; s/^ *//; s/ *$//' <<<"$image_log")  # same log group as the first task
  if [[ "$image_log" == *ran-42* && "$image_log" == *Linux* ]]; then
    report ecs works "the image's command ran: $image_log ($plain_note)"
  else
    report ecs FAILS "task $image; the image's command didn't run, log: '${image_log:-nothing}' ($plain_note)"
  fi
  destroy ecs
}

check_mysql() {
  if ! apply rds-mysql; then report rds-mysql FAILS "$(first_error rds-mysql)"; destroy rds-mysql; return; fi
  local host port out
  host=$(terraform -chdir=rds-mysql output -raw address)
  port=$(terraform -chdir=rds-mysql output -raw port)
  out=$(python3 -I rds-mysql/query.py "$host" "$port" app probe-only-local-1 probe \
    "CREATE TABLE t (id INT PRIMARY KEY, body VARCHAR(50)); INSERT INTO t VALUES (1, 'saved'); SELECT body FROM t; SELECT CURRENT_TIMESTAMP; SELECT NOW()" 2>&1)
  if [[ "$out" == *saved* ]]; then
    local server now_note ts_note
    server=$(head -1 <<<"$out" | sed 's/connected: //')
    now_note="NOW() works"
    [[ "$(tail -1 <<<"$out")" == ERROR* ]] && now_note="but SELECT NOW() fails: $(tail -1 <<<"$out" | cut -c1-60)"
    # The line after "> SELECT CURRENT_TIMESTAMP" is its header, then its value.
    ts_note="CURRENT_TIMESTAMP fails"
    [[ "$(grep -A2 '^> SELECT CURRENT_TIMESTAMP$' <<<"$out" | tail -1)" =~ ^[0-9]{4}- ]] && ts_note="CURRENT_TIMESTAMP works"
    report rds-mysql works "SQL ran on $server at $host:$port; $ts_note, $now_note"
  else
    report rds-mysql FAILS "$(tail -1 <<<"$out")"
  fi
  destroy rds-mysql
}

check_lambda_rds() {
  # The function's zip: its handler and the MySQL client from rds-mysql.
  mkdir -p lambda-rds/build
  python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.write(sys.argv[2], "handler.py"); z.write(sys.argv[3], "query.py")' \
    lambda-rds/build/fn.zip lambda-rds/handler.py rds-mysql/query.py
  if ! apply lambda-rds; then report lambda-rds FAILS "$(first_error lambda-rds)"; destroy lambda-rds; return; fi
  local fn host port out
  fn=$(terraform -chdir=lambda-rds output -raw function)
  host=$(terraform -chdir=lambda-rds output -raw address)
  port=$(terraform -chdir=lambda-rds output -raw port)
  aws lambda invoke --function-name "$fn" --cli-binary-format raw-in-base64-out \
    --payload "{\"host\":\"$host\",\"port\":$port}" lambda-rds/build/out.json >/dev/null 2>&1
  out=$(cat lambda-rds/build/out.json 2>/dev/null)
  if [[ "$out" == *'"ok": true'* ]]; then
    report lambda-rds works "Lambda opened a socket to $host:$port and ran SQL: $out"
  else
    report lambda-rds FAILS "Lambda couldn't reach the database: ${out:-no reply}"
  fi
  destroy lambda-rds
}

aws-emulator -v 2>/dev/null | head -1
for check in "${@:-aurora security-group provider6 ecs rds-mysql lambda-rds}"; do
  for c in $check; do
    case "$c" in
      ecs) check_ecs ;;
      rds-mysql) check_mysql ;;
      lambda-rds) check_lambda_rds ;;
      aurora|security-group|provider6) check_tf "$c" ;;
      *) echo "unknown check: $c" >&2 ;;
    esac
  done
done
