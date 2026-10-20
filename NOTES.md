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
