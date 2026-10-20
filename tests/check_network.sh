#!/usr/bin/env bash
# AWS CLI checks for the network stack. Extended every phase. Prints PASS/FAIL per check.
set -u

REGION="ap-southeast-2"
AZ="ap-southeast-2a"
FAILS=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
check() { # check <description> <actual> <expected>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi
}

aws_ec2() { aws ec2 --region "$REGION" "$@" --output text; }

vpc_id() { # vpc_id <name>
  aws_ec2 describe-vpcs --filters "Name=tag:Name,Values=p1-$1-vpc" "Name=tag:Project,Values=project1" \
    --query 'Vpcs[0].VpcId' | sed 's/^None$//'
}

# ---- Phase 2: shared-services VPC ----
SHARED=$(vpc_id shared)
if [ -z "$SHARED" ]; then
  fail "shared VPC exists"
else
  pass "shared VPC exists ($SHARED)"
  check "shared VPC CIDR" "$(aws_ec2 describe-vpcs --vpc-ids "$SHARED" --query 'Vpcs[0].CidrBlock')" "10.0.0.0/16"

  check "shared public subnet CIDR/AZ" \
    "$(aws_ec2 describe-subnets --filters "Name=vpc-id,Values=$SHARED" "Name=tag:Name,Values=p1-shared-public" --query 'Subnets[0].[CidrBlock,AvailabilityZone]' | tr '\t' ' ')" \
    "10.0.0.0/24 $AZ"
  check "shared private subnet CIDR/AZ" \
    "$(aws_ec2 describe-subnets --filters "Name=vpc-id,Values=$SHARED" "Name=tag:Name,Values=p1-shared-private" --query 'Subnets[0].[CidrBlock,AvailabilityZone]' | tr '\t' ' ')" \
    "10.0.1.0/24 $AZ"

  PUB_RT=$(aws_ec2 describe-route-tables --filters "Name=vpc-id,Values=$SHARED" "Name=tag:Name,Values=p1-shared-public-rt" --query 'RouteTables[0].RouteTableId')
  PRIV_RT=$(aws_ec2 describe-route-tables --filters "Name=vpc-id,Values=$SHARED" "Name=tag:Name,Values=p1-shared-private-rt" --query 'RouteTables[0].RouteTableId')

  PUB_DEFAULT=$(aws_ec2 describe-route-tables --route-table-ids "$PUB_RT" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]')
  case "$PUB_DEFAULT" in
    igw-*) pass "public route table: 0.0.0.0/0 -> $PUB_DEFAULT" ;;
    *) fail "public route table: 0.0.0.0/0 -> IGW (got '$PUB_DEFAULT')" ;;
  esac

  PRIV_DEFAULT=$(aws_ec2 describe-route-tables --route-table-ids "$PRIV_RT" \
    --query 'length(RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`])')
  check "private route table has NO 0.0.0.0/0 route" "$PRIV_DEFAULT" "0"
fi

# ---- Phase 3: dev and prod VPCs ----
DEV=$(vpc_id dev)
PROD=$(vpc_id prod)
for pair in "shared:$SHARED:10.0.0.0/16" "dev:$DEV:10.1.0.0/16" "prod:$PROD:10.2.0.0/16"; do
  IFS=: read -r n id cidr <<<"$pair"
  if [ -z "$id" ]; then fail "$n VPC exists"; continue; fi
  pass "$n VPC exists ($id)"
  check "$n VPC CIDR" "$(aws_ec2 describe-vpcs --vpc-ids "$id" --query 'Vpcs[0].CidrBlock')" "$cidr"
  check "$n VPC has 2 subnets" "$(aws_ec2 describe-subnets --filters "Name=vpc-id,Values=$id" --query 'length(Subnets)')" "2"
done

# CIDRs must not overlap: all /16 network addresses distinct and in different 10.x ranges.
CIDRS=$(for id in "$SHARED" "$DEV" "$PROD"; do aws_ec2 describe-vpcs --vpc-ids "$id" --query 'Vpcs[0].CidrBlock'; done)
check "VPC CIDRs do not overlap" "$(echo "$CIDRS" | cut -d. -f2 | sort -u | wc -l | tr -d ' ')" "3"

# ---- Phase 4: VPC peering ----
pcx_status() { # pcx_status <name>
  aws_ec2 describe-vpc-peering-connections --filters "Name=tag:Name,Values=$1" "Name=status-code,Values=active,pending-acceptance,provisioning,failed,rejected" \
    --query 'VpcPeeringConnections[0].Status.Code'
}
check "shared<->dev peering is active" "$(pcx_status p1-shared-dev-pcx)" "active"
check "shared<->prod peering is active" "$(pcx_status p1-shared-prod-pcx)" "active"

# Only the project's own route tables (public + private); the VPC main route table is not ours.
routes_to_ours() { # routes_to_ours <vpc-name> <dest-cidr>
  local id; id=$(vpc_id "$1")
  for rt in $(aws_ec2 describe-route-tables --filters "Name=vpc-id,Values=$id" "Name=tag:Project,Values=project1" --query 'RouteTables[].RouteTableId'); do
    r=$(aws_ec2 describe-route-tables --route-table-ids "$rt" \
      --query "RouteTables[0].Routes[?DestinationCidrBlock=='$2'].VpcPeeringConnectionId | [0]")
    case "$r" in pcx-*) echo "pcx" ;; *) echo "none" ;; esac
  done | sort -u | tr '\n' ' ' | sed 's/ $//'
}

check "shared route tables -> 10.1.0.0/16 via pcx" "$(routes_to_ours shared 10.1.0.0/16)" "pcx"
check "shared route tables -> 10.2.0.0/16 via pcx" "$(routes_to_ours shared 10.2.0.0/16)" "pcx"
check "dev route tables -> 10.0.0.0/16 via pcx" "$(routes_to_ours dev 10.0.0.0/16)" "pcx"
check "dev route tables have NO route to 10.2.0.0/16" "$(routes_to_ours dev 10.2.0.0/16)" "none"
check "prod route tables -> 10.0.0.0/16 via pcx" "$(routes_to_ours prod 10.0.0.0/16)" "pcx"
check "prod route tables have NO route to 10.1.0.0/16" "$(routes_to_ours prod 10.1.0.0/16)" "none"
check "no dev<->prod peering exists" \
  "$(aws_ec2 describe-vpc-peering-connections --filters "Name=requester-vpc-info.vpc-id,Values=$DEV" "Name=accepter-vpc-info.vpc-id,Values=$PROD" "Name=status-code,Values=active,pending-acceptance,provisioning" --query 'length(VpcPeeringConnections)')" "0"

# ---- Phase 5: security groups ----
SG_IDS=$(aws_ec2 describe-security-groups --filters "Name=tag:Project,Values=project1" --query 'SecurityGroups[].GroupId')
OPEN_INGRESS=0
for sg in $SG_IDS; do
  n=$(aws_ec2 describe-security-group-rules --filters "Name=group-id,Values=$sg" \
    --query 'length(SecurityGroupRules[?IsEgress==`false` && CidrIpv4==`0.0.0.0/0`])')
  OPEN_INGRESS=$((OPEN_INGRESS + n))
done
check "no project security group allows inbound 0.0.0.0/0" "$OPEN_INGRESS" "0"

sg_id() { aws_ec2 describe-security-groups --filters "Name=group-name,Values=$1" "Name=tag:Project,Values=project1" --query 'SecurityGroups[0].GroupId'; }
inbound_sources() { # inbound_sources <sg-id>: sorted unique inbound CIDRs
  aws_ec2 describe-security-group-rules --filters "Name=group-id,Values=$1" \
    --query 'SecurityGroupRules[?IsEgress==`false`].CidrIpv4' | tr '\t' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

BASTION_SG=$(sg_id p1-bastion-sg)
DEV_SG=$(sg_id p1-dev-workload-sg)
PROD_SG=$(sg_id p1-prod-workload-sg)

# The source must equal the IPv4 Terraform looked up (state output). On carrier NAT (Jio) that can differ
# from what curl sees, so also print curl's value as information.
TF_IP=$(terraform -chdir="$(dirname "$0")/../network" output -raw my_ip_cidr 2>/dev/null)
CURL_IP="$(curl -4 -s -m 10 https://checkip.amazonaws.com)/32"
check "bastion-sg port 22 source equals my Terraform-detected IPv4 /32" \
  "$(aws_ec2 describe-security-group-rules --filters "Name=group-id,Values=$BASTION_SG" \
    --query 'SecurityGroupRules[?IsEgress==`false` && FromPort==`22`].CidrIpv4 | [0]')" "$TF_IP"
[ "$TF_IP" = "$CURL_IP" ] || echo "NOTE: curl sees $CURL_IP but Terraform used $TF_IP (carrier NAT?). Real test is SSH in Phase 8."

check "bastion-sg has only one inbound source (my IP)" "$(inbound_sources "$BASTION_SG")" "$TF_IP"
check "dev-workload-sg inbound only from 10.0.0.0/16" "$(inbound_sources "$DEV_SG")" "10.0.0.0/16"
check "prod-workload-sg inbound only from 10.0.0.0/16" "$(inbound_sources "$PROD_SG")" "10.0.0.0/16"
check "prod-workload-sg has no inbound 3306" \
  "$(aws_ec2 describe-security-group-rules --filters "Name=group-id,Values=$PROD_SG" \
    --query 'length(SecurityGroupRules[?IsEgress==`false` && FromPort<=`3306` && ToPort>=`3306`])')" "0"

# ---- Phase 6: NACLs on dev and prod private subnets ----
# Expected non-default rules, one per line: egress rule# action protocol from to cidr
EXPECTED_NACL=$(sort <<'EOF'
False 100 allow 6 22 22 10.0.0.0/16
False 110 allow 1 None None 10.0.0.0/16
False 120 allow 6 1024 65535 10.0.0.0/16
False 900 deny -1 None None 0.0.0.0/0
True 100 allow 1 None None 10.0.0.0/16
True 110 allow 6 1024 65535 10.0.0.0/16
True 900 deny -1 None None 0.0.0.0/0
EOF
)
for env in dev prod; do
  vpc=$(vpc_id "$env")
  subnet=$(aws_ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" "Name=tag:Name,Values=p1-$env-private" --query 'Subnets[0].SubnetId')
  nacl=$(aws_ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$subnet" --query 'NetworkAcls[0].NetworkAclId')
  check "$env private subnet uses a custom (non-default) NACL" \
    "$(aws_ec2 describe-network-acls --network-acl-ids "$nacl" --query 'NetworkAcls[0].IsDefault')" "False"
  check "$env NACL is named p1-$env-private-nacl" \
    "$(aws_ec2 describe-network-acls --network-acl-ids "$nacl" --query 'NetworkAcls[0].Tags[?Key==`Name`].Value | [0]')" "p1-$env-private-nacl"
  ACTUAL_NACL=$(aws_ec2 describe-network-acls --network-acl-ids "$nacl" \
    --query 'NetworkAcls[0].Entries[?RuleNumber!=`32767`].[Egress,RuleNumber,RuleAction,Protocol,PortRange.From,PortRange.To,CidrBlock]' | tr '\t' ' ' | sort)
  check "$env NACL rule numbers, ports and CIDRs are as expected" "$ACTUAL_NACL" "$EXPECTED_NACL"
done

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "$FAILS CHECK(S) FAILED"; exit 1; fi
