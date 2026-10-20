#!/usr/bin/env bash
# Connectivity test matrix. Reads IPs from `terraform output -json`, hops through the bastion
# with ssh -J, and prints PASS when the result matches the expected one. Probes time out after 5s.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${KEY:-$HOME/.ssh/project1}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OUT=$(terraform -chdir="$ROOT/network" output -json)
getout() { echo "$OUT" | python3 -I -c "import json,sys; print(json.load(sys.stdin)['$1']['value'])"; }
BASTION=$(getout bastion_public_ip)
DEV=$(getout dev_app_private_ip)
PROD=$(getout prod_app_private_ip)

cat >"$TMP/ssh_config" <<EOF
Host *
  User ec2-user
  IdentityFile $KEY
  IdentitiesOnly yes
  BatchMode yes
  # Generous: SSH setup from a mobile link to Sydney takes ~10s via a jump. The probes themselves
  # (timeout 5, ping -W 3, curl -m 5) stay short, and test 2 overrides this with 5s.
  ConnectTimeout 30
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $TMP/known_hosts
  LogLevel ERROR
EOF
SSH="ssh -F $TMP/ssh_config"

FAILS=0
pass() { echo "PASS  #$1  $2"; }
fail() { echo "FAIL  #$1  $2"; FAILS=$((FAILS + 1)); }
# run_on <target> <cmd>: target is "bastion", "dev" or "prod". Prints the command's output, returns ssh's exit code.
run_on() {
  case "$1" in
    bastion) $SSH "$BASTION" "$2" 2>&1 ;;
    dev) $SSH -J "$BASTION" "$DEV" "$2" 2>&1 ;;
    prod) $SSH -J "$BASTION" "$PROD" "$2" 2>&1 ;;
  esac
}
# TCP probe run on the remote host. Prints OPEN or CLOSED, and TOOL_MISSING if bash /dev/tcp is unusable.
tcp_probe() { echo "timeout 5 bash -c '</dev/tcp/$1/$2' >/dev/null 2>&1 && echo OPEN || echo CLOSED"; }
ping_probe() { echo "command -v ping >/dev/null || { echo TOOL_MISSING; exit 0; }; ping -c 2 -W 3 $1 >/dev/null 2>&1 && echo UP || echo DOWN"; }

echo "Bastion $BASTION | dev-app $DEV | prod-app $PROD"
echo "------------------------------------------------------------"

# 1. Mac -> Bastion SSH: works
R=$(run_on bastion 'hostname')
if [ $? -eq 0 ] && [[ "$R" == ip-* ]]; then pass 1 "Mac -> Bastion SSH works ($R)"; else fail 1 "Mac -> Bastion SSH should work (got: $R). Layer: bastion-sg source IP / IGW route"; fi

# 2. Mac -> dev-app directly: fails (private IP, no public IP)
DEV_PUB=$(aws ec2 describe-instances --region ap-southeast-2 --filters "Name=private-ip-address,Values=$DEV" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null)
$SSH -o ConnectTimeout=5 "$DEV" 'hostname' >/dev/null 2>&1
RC=$?
if [ "$DEV_PUB" = "None" ] && [ $RC -ne 0 ]; then pass 2 "Mac -> dev-app directly fails (no public IP, ssh exit $RC)"; else fail 2 "Mac -> dev-app directly should fail (public ip: $DEV_PUB, ssh exit $RC)"; fi

# 3 / 4. Bastion -> dev-app / prod-app: ping + SSH work
for pair in "3:dev:$DEV" "4:prod:$PROD"; do
  IFS=: read -r n name ip <<<"$pair"
  P=$(run_on bastion "$(ping_probe "$ip")")
  H=$(run_on "$name" 'hostname')
  if [ "$P" = "UP" ] && [[ "$H" == ip-* ]]; then
    pass "$n" "Bastion -> $name-app ping + SSH work ($H)"
  else
    fail "$n" "Bastion -> $name-app ping + SSH should work (ping=$P, ssh=$H). Layer: route table, SG or NACL"
  fi
done

# 5 / 6. dev-app <-> prod-app: ping + TCP 22 fail (no route; peering is not transitive)
for pair in "5:dev:prod:$PROD" "6:prod:dev:$DEV"; do
  IFS=: read -r n from to ip <<<"$pair"
  CTRL=$(run_on "$from" "$(tcp_probe 127.0.0.1 22)")          # control: the probe tool itself works
  P=$(run_on "$from" "$(ping_probe "$ip")")
  T=$(run_on "$from" "$(tcp_probe "$ip" 22)")
  if [ "$CTRL" != "OPEN" ] || [ "$P" = "TOOL_MISSING" ]; then
    fail "$n" "$from-app -> $to-app: test tooling broken (control=$CTRL, ping=$P)"
  elif [ "$P" = "DOWN" ] && [ "$T" = "CLOSED" ]; then
    pass "$n" "$from-app -> $to-app ping + TCP 22 fail (no route)"
  else
    fail "$n" "$from-app -> $to-app should fail (ping=$P, tcp22=$T). Layer: route table"
  fi
done

# 7. dev-app -> internet: fails (no NAT, no default route)
C=$(run_on dev "command -v curl >/dev/null || { echo TOOL_MISSING; exit 0; }; curl -m 5 -s -o /dev/null https://example.com && echo REACHED || echo BLOCKED")
if [ "$C" = "BLOCKED" ]; then pass 7 "dev-app -> internet fails (no NAT)"; else fail 7 "dev-app -> internet should fail (got: $C). Layer: route table"; fi

# 8. Bastion -> prod-app TCP 3306: fails (NACL + SG block, logged as REJECT). Control: port 22 works (test 4).
T=$(run_on bastion "$(tcp_probe "$PROD" 3306)")
if [ "$T" = "CLOSED" ]; then pass 8 "Bastion -> prod-app TCP 3306 blocked (NACL + SG, REJECT in flow logs)"; else fail 8 "Bastion -> prod-app TCP 3306 should be blocked (got: $T). Layer: SG/NACL"; fi

echo "------------------------------------------------------------"
if [ "$FAILS" -eq 0 ]; then echo "8/8 PASS"; else echo "$((8 - FAILS))/8 PASS, $FAILS FAIL"; exit 1; fi
