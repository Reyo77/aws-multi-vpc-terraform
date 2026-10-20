# NOTES

## Phase 0: Preflight (passed)
- Terraform v1.16.6, aws-cli 2.38.1, caller is IAM user `admin` (not root), `~/.ssh/project1.pub` exists, outbound IPv4 works.
- Dry-runs in ap-southeast-2: describe-availability-zones OK (2a/2b/2c available), create-vpc DryRunOperation (allowed), run-instances t3.micro in 2a with AL2023 SSM AMI DryRunOperation (allowed), `aws s3 ls` OK.

### What broke
- us-east-1 was unusable: `ec2:DescribeInstanceTypeOfferings`, `DescribeAvailabilityZones`, `CreateVpc` and `ssm:GetParameters` all hit an explicit deny from the Organization SCP. Decoded message: statement `UsEast1Partitional`, applies when `aws:RequestedRegion` = us-east-1, and EC2/VPC/SSM are not in its list of exceptions.
- Fix: moved the whole project to `ap-southeast-2` (Sydney), AZ `ap-southeast-2a`. CLAUDE.md updated.

## Phase 1: Terraform foundation (passed with one known caveat)
- Built `network/` versions (aws ~> 6.0, http ~> 3.4), provider with default tag `Project = "project1"`, variables, tfvars (ap-southeast-2 / 2a), `data "http"` IP lookup with an IPv4 postcondition, `local.my_ip_cidr` with optional `my_ip_override` (validated as IPv4 /32), and an `my_ip_cidr` output.
- `init`, `validate` OK. `plan` shows no changes to AWS.
- `terraform console` showed `(known after apply)` because data sources are not in state until an apply. Fix: expose the value as an output, so `plan` prints it.

### What broke
- Terraform's lookup returned 152.58.60.121 but `curl -4` returned 152.58.35.206 (stable per tool; Python matched Terraform). Likely Jio carrier-grade NAT giving different public IPs per destination server.
- Decision: carry on. The real check is SSH to the bastion in Phase 8. If it times out, set `my_ip_override` or read the source IP the bastion sees. Phase 5's "SG source equals curl IP" test must account for this.

## Phase 2: VPC module, shared-services only (passed)
- Built `modules/vpc` (VPC with DNS on, public /24 + private /24 derived with `cidrsubnet`, IGW, public RT with 0.0.0.0/0 -> IGW, private RT with local route only, associations). Called once as `module.shared` (10.0.0.0/16).
- Applied: 8 added, 0 changed, 0 destroyed. `tests/check_network.sh`: 6/6 PASS.
- Nothing broke in this phase.

## Phase 3: dev and prod VPCs (passed)
- Added `module.dev` (10.1.0.0/16) and `module.prod` (10.2.0.0/16). Plan was add-only: 16 added, 0 changed, 0 destroyed; shared untouched.
- `check_network.sh`: 16/16 PASS (3 VPCs exist with right CIDRs, 2 subnets each, no CIDR overlap).
- Small snag: `terraform validate` said "Module not installed" after adding the new module calls. Fix: run `terraform init` whenever a module call is added.

## Phase 4: VPC peering (passed)
- `network/peering.tf`: shared<->dev and shared<->prod peering (`auto_accept`), routes both ways in the public and private route tables of every VPC. No dev<->prod peering or routes.
- Applied: 10 added, 0 changed, 0 destroyed. `check_network.sh`: all PASS (both peerings active, shared routes to 10.1/10.2 via pcx, dev/prod route to 10.0 via pcx, dev has no route to 10.2, prod none to 10.1, no dev<->prod peering).
- Why dev can't reach prod via shared: peering is non-transitive. AWS only forwards traffic whose source or destination is one of the two peered VPCs, and dev has no route to 10.2.0.0/16 anyway.
- Nothing broke in this phase.

## Phase 5: Security groups (passed)
- `network/security_groups.tf`: bastion-sg (SSH in from my IP only; SSH/ICMP out to dev+prod; TCP 3306 out to prod only to create a blocked-traffic test), dev-workload-sg and prod-workload-sg (SSH/ICMP in from 10.0.0.0/16 only, outbound all, nothing on 3306).
- Applied: 15 added, 3 imported, 0 changed, 0 destroyed. `check_network.sh`: all PASS.
- The "SG source equals my IP" check compares against Terraform's detected IPv4, not curl's (see Phase 1 caveat). The script prints a NOTE when they differ.

### What broke
- Phase 4 bug found while planning Phase 5: the public route tables had the IGW route as an inline `route {}` block, while the peering routes were separate `aws_route` resources. Terraform treats inline routes as the full list, so the next apply wanted to DELETE the peering routes from the public route tables. Phase 4's tests passed only because they ran right after the first apply.
- Fix: moved the IGW route into its own `aws_route.public_internet` in the module, adopted the existing routes with temporary `import` blocks (no AWS change), then deleted `imports.tf`. Re-plan shows "No changes". Lesson: never mix inline routes with `aws_route` on the same route table, and re-plan after every apply.

## Phase 6: NACLs on private subnets (passed)
- `network/nacls.tf`: custom NACLs for dev and prod private subnets, rules as separate `aws_network_acl_rule` resources (no inline rules). Inbound: 100 TCP 22, 110 ICMP, 120 TCP 1024-65535 (return traffic), all from 10.0.0.0/16, 900 deny all. Outbound: 100 ICMP, 110 TCP 1024-65535 to 10.0.0.0/16, 900 deny all.
- Applied: 16 added, 0 changed, 0 destroyed; re-plan "No changes". `check_network.sh`: all PASS.
- Stateful vs stateless: security groups remember connections so replies are automatic; NACLs judge every packet alone, so return traffic needs ephemeral-port rules in both directions.
- Test 8 (bastion -> prod TCP 3306) is now dropped by both the NACL (only 22/ICMP allowed) and the SG; either way flow logs record REJECT.
- Nothing broke in this phase.

## Phase 7: Logging stack + flow logs (passed)
- `logging/` (own state): S3 bucket `p1-flowlogs-228998979209`, all 4 public-access-block settings true (verified with `get-public-access-block`), SSE-S3, 30-day lifecycle expiry, bucket policy for `delivery.logs.amazonaws.com` scoped to the account (`aws:SourceAccount`, `aws:SourceArn`). Applied: 5 added.
- `network/flowlogs.tf`: one `aws_flow_log` per VPC, traffic ALL, S3 destination, 60s aggregation. Applied: 3 added. `describe-flow-logs`: 3 flow logs ACTIVE.
- `terraform plan -destroy` in network/: 71 resources, none is an S3 bucket, so teardown leaves the logs alone. (The flow log entries show the bucket ARN only as an attribute being cleared.)
- Nothing broke in this phase.

## Phase 8: Test instances (passed)
- `network/instances.tf`: key pair from `~/.ssh/project1.pub`, latest AL2023 AMI via SSM parameter, bastion (shared public subnet, public IP, bastion-sg), dev-app and prod-app (private subnets, no public IP, workload SGs). All t3.micro, IMDSv2 required, encrypted gp3 root volumes. Outputs: bastion public IP, private IPs.
- Applied: 4 added. All 3 instances `running` with both status checks `ok`; dev-app/prod-app have no public IP; `ssh ... hostname` works.

### What broke
- First SSH to the bastion timed out. Cause: the Terraform `http` lookup returned 152.58.60.121 but my real traffic reaches AWS as 152.58.35.206 (the address `curl`/`ssh` see). Jio carrier NAT gives different public IPs to different clients (this was the Phase 1 caveat).
- Fix: apply with `TF_VAR_my_ip_override="$(curl -4 -s https://checkip.amazonaws.com)/32"`. One in-place change to the bastion-sg ingress rule; SSH worked immediately. A plain `terraform apply` without the override would put the wrong IP back.

## Phase 9: Connectivity test matrix (8/8 PASS)
- `tests/connectivity.sh`: reads IPs from `terraform output -json`, uses `ssh -J` through the bastion, probes with remote `timeout 5` / `ping -W 3` / `curl -m 5`. Blocked-path tests include a control (probe tool works locally) so a broken tool can't produce a false PASS. Output in `docs/connectivity-results.txt`.
- Results: Mac->bastion works; Mac->dev-app direct fails; bastion->dev/prod ping+SSH work; dev<->prod ping+TCP22 fail (no route); dev-app->internet fails (no NAT); bastion->prod:3306 blocked.

### What broke
- First run: 3/8. Tests 3-7 failed with "Connection timed out during banner exchange" although ping worked. Not a network block: SSH setup from my mobile link to Sydney takes ~6s direct and ~10s through a jump (many round trips), and the script's SSH ConnectTimeout was 5s. Raising ConnectTimeout to 30s fixed it; the probes themselves still time out after 5s so blocked tests don't hang. Layer: none (test-script timeout, not route/SG/NACL).
