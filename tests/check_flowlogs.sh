#!/usr/bin/env bash
# Finds ACCEPT and REJECT flow log records in the S3 bucket. Flow logs take 5-10 minutes to
# arrive, so this polls (every 60s, up to MAX_WAIT seconds) until both pieces of evidence exist.
# Default flow log format (space separated, 1-based awk columns):
#  1 version 2 account-id 3 interface-id 4 srcaddr 5 dstaddr 6 srcport 7 dstport 8 protocol
#  9 packets 10 bytes 11 start 12 end 13 action 14 log-status
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="ap-southeast-2"
MAX_WAIT="${MAX_WAIT:-900}"
BUCKET=$(terraform -chdir="$ROOT/logging" output -raw bucket_name)
OUT=$(terraform -chdir="$ROOT/network" output -json)
getout() { echo "$OUT" | python3 -I -c "import json,sys; print(json.load(sys.stdin)['$1']['value'])"; }
BASTION_IP=$(getout bastion_private_ip)
PROD_IP=$(getout prod_app_private_ip)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { # download and unzip every log object into $TMP/logs/all.txt
  rm -rf "$TMP/logs"; mkdir -p "$TMP/logs"
  aws s3 cp "s3://$BUCKET/" "$TMP/logs/" --recursive --region "$REGION" --quiet 2>/dev/null
  find "$TMP/logs" -name '*.gz' -exec gunzip -f {} + 2>/dev/null
  find "$TMP/logs" -name '*.log' -exec cat {} + 2>/dev/null | grep -v '^version' >"$TMP/all.txt"
  : >>"$TMP/all.txt"
}
reject_3306() { awk -v ip="$PROD_IP" -v src="$BASTION_IP" '$5==ip && $7==3306 && $13=="REJECT" && $4==src' "$TMP/all.txt"; }
accept_22() { awk -v src="$BASTION_IP" '$4==src && $7==22 && $13=="ACCEPT"' "$TMP/all.txt"; }

echo "Bucket: s3://$BUCKET | bastion $BASTION_IP | prod-app $PROD_IP"
START=$(date +%s)
while :; do
  fetch
  R=$(reject_3306 | wc -l | tr -d ' ')
  A=$(accept_22 | wc -l | tr -d ' ')
  ELAPSED=$(($(date +%s) - START))
  echo "[$(printf '%3ss' "$ELAPSED")] objects: $(find "$TMP/logs" -type f | wc -l | tr -d ' ') | records: $(wc -l <"$TMP/all.txt" | tr -d ' ') | REJECT:3306 found: $R | ACCEPT:22 found: $A"
  [ "$R" -gt 0 ] && [ "$A" -gt 0 ] && break
  [ "$ELAPSED" -ge "$MAX_WAIT" ] && break
  sleep 60
done

echo
echo "=== Newest objects in the bucket ==="
aws s3 ls "s3://$BUCKET/" --recursive --region "$REGION" | sort -k1,2 | tail -5
echo
echo "=== ACCEPT vs REJECT counts (all records) ==="
awk '$13=="ACCEPT"{a++} $13=="REJECT"{r++} END{printf "ACCEPT: %d\nREJECT: %d\n", a, r}' "$TMP/all.txt"
echo
echo "=== REJECT records: bastion ($BASTION_IP) -> prod-app ($PROD_IP) port 3306 (test 8) ==="
reject_3306 | head -5
echo
echo "=== ACCEPT records: port 22 from the bastion ($BASTION_IP) ==="
accept_22 | head -5

echo
if [ "$R" -gt 0 ] && [ "$A" -gt 0 ]; then
  echo "PASS: found REJECT for port 3306 toward prod-app and ACCEPT for port 22 from the bastion"
else
  echo "FAIL: REJECT:3306=$R ACCEPT:22=$A (logs can take up to ~10 min; re-run)"
  exit 1
fi
