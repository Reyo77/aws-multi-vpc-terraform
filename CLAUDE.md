# Project 1: Segmented Multi-VPC Network on AWS (Terraform)

## What we're building

Three isolated AWS networks (VPCs), all built from Terraform code:

- **shared-services** (10.0.0.0/16): holds the bastion host, the single entry point for SSH.
- **dev** (10.1.0.0/16): development workloads.
- **prod** (10.2.0.0/16): production workloads.

Each VPC has one public /24 subnet and one private /24 subnet in a single AZ.
shared-services is peered with dev and with prod. Dev and prod are NOT peered, so they can't reach each other.
Security groups and NACLs control traffic. VPC Flow Logs from all three VPCs go to one S3 bucket.
Small test instances prove what is allowed and what is blocked.

## My setup

- OS: macOS
- AWS region: `ap-southeast-2` (Sydney). Use only this region.
- Availability zone: `ap-southeast-2a`
- My public IP for SSH: detected automatically by Terraform (see Phase 1). My connection has an IPv6 address (`2409:40c1:...`), but the bastion is reached over IPv4, so the SSH rule must use my public **IPv4** address. Mobile/Jio IPv4 addresses change often, so it is looked up fresh on every `plan`/`apply`.
- SSH public key: `~/.ssh/project1.pub`
- Name prefix for all resources: `p1`
- AWS account is on the Free plan under an Organization SCP that denies EC2/VPC/SSM in us-east-1 (statement `UsEast1Partitional`). Sydney (`ap-southeast-2`) is allowed, so the whole project uses it. See NOTES.md.

## Rules for Claude (follow these every time)

1. **One phase at a time.** Finish a phase, run its tests, show me the results, then STOP and wait for me to say "next".
2. **Explain before writing.** Before creating a file, tell me in plain words what each resource does and why it's needed.
3. **Never run `terraform apply` or `terraform destroy` without my approval.** Run `terraform plan` first, show me the summary (add/change/destroy counts and resource list), and wait for "yes".
4. **Never read, print, or copy** `~/.ssh/project1` (the private key) or `~/.aws/credentials`. You may pass the key path to `ssh -i`, nothing else.
5. **Every phase must pass its tests** before moving on. If a test fails, explain why in simple words, fix it, and re-run the test.
6. **After a phase passes,** run `terraform fmt -recursive` and `terraform validate`, then commit with a message like `phase 2: vpc peering`.
7. **Keep `NOTES.md` updated** after each phase: what was built, test results, and anything that broke and how we fixed it. This becomes the README's "what broke" section.
8. **Cost rules:** no NAT Gateway, no Transit Gateway, no VPN Gateway, no Elastic IPs, no interface VPC endpoints. Only the bastion gets a public IP. Instances are `t3.micro`. Tag every resource with `Project = "project1"`.
9. **End of session:** when I say "end session", destroy the network stack (not the logging stack), then confirm with AWS CLI that no instances or project VPCs are left.
10. **Quiz me** with 3 short questions at the end of each phase. Wait for my answers before the "next".

## Folder layout

```
aws-multi-vpc-terraform/
├── CLAUDE.md
├── NOTES.md
├── README.md
├── logging/                 # separate Terraform stack, survives destroy
│   ├── main.tf              # S3 bucket for flow logs
│   ├── variables.tf
│   └── outputs.tf
├── network/                 # main stack, destroyed after each session
│   ├── versions.tf          # Terraform + AWS provider versions
│   ├── providers.tf         # region + default tags
│   ├── variables.tf
│   ├── terraform.tfvars     # region, az, my_ip, key path (not secret)
│   ├── main.tf              # calls the VPC module 3 times
│   ├── peering.tf
│   ├── security_groups.tf
│   ├── nacls.tf
│   ├── flowlogs.tf
│   ├── instances.tf
│   └── outputs.tf
├── modules/vpc/
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── tests/
│   ├── check_network.sh     # AWS CLI checks for VPCs, peering, routes, SGs, NACLs
│   ├── connectivity.sh      # SSH/ping test matrix, prints PASS/FAIL
│   └── check_flowlogs.sh    # finds ACCEPT and REJECT records in S3
└── docs/                    # diagram + screenshots
```

---

## Phase 0: Preflight

**Build:** nothing in AWS. Check the local setup.

**Test:**
- `terraform -version`, `aws --version`, `aws sts get-caller-identity` all work.
- The caller identity is an IAM user, not root.
- `~/.ssh/project1.pub` exists.
- AZ/instance check (replaces `describe-instance-type-offerings`, which the Free plan policy blocks) using dry-runs:
  1. `aws ec2 describe-availability-zones --region ap-southeast-2`
  2. `aws ec2 create-vpc --cidr-block 10.99.0.0/16 --dry-run`
  3. `aws ec2 run-instances --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --instance-type t3.micro --placement AvailabilityZone=ap-southeast-2a --dry-run`
  4. `aws s3 ls`
  For 2 and 3, "DryRunOperation" means ALLOWED. "UnauthorizedOperation" or "explicit deny" means BLOCKED. If 3 says t3.micro is unsupported in ap-southeast-2a, try ap-southeast-2b and update this file.
- My Mac has outbound IPv4: `curl -4 -s https://checkip.amazonaws.com` prints an IPv4 address. If it fails, STOP and tell me. We'd then need EC2 Instance Connect Endpoint instead of SSH from my IP.

**Done when:** all checks pass.

## Phase 1: Terraform foundation

**Build:** `network/versions.tf` (include the `hashicorp/http` provider), `network/providers.tf` (region from variable, default tags), `network/variables.tf`, `network/terraform.tfvars` (region `ap-southeast-2`, az `ap-southeast-2a`, key path), and a `data "http"` lookup of `https://checkip.amazonaws.com` that builds `local.my_ip_cidr = "${chomp(data.http.my_ip.response_body)}/32"`. Also allow an optional `my_ip_override` variable: if set, use it instead of the lookup.

**Test:**
- `terraform init` succeeds.
- `terraform validate` passes.
- `terraform plan` shows "No changes" to AWS resources (nothing defined yet).
- `terraform console` → `local.my_ip_cidr` prints an IPv4 /32 that matches `curl -4 https://checkip.amazonaws.com`.

**Done when:** all three pass. Commit.

## Phase 2: VPC module (shared-services only)

**Build:** `modules/vpc/` with: VPC (DNS support and hostnames on), public subnet, private subnet, internet gateway, public route table with `0.0.0.0/0 → IGW`, private route table with only the local route, route table associations. Outputs: vpc_id, vpc_cidr, subnet IDs, route table IDs.
In `network/main.tf`, call the module ONCE for shared-services only.

**Test:**
- Plan, show summary, wait for approval, apply.
- `tests/check_network.sh` (create it now, extend it each phase) confirms with AWS CLI:
  - VPC exists with CIDR 10.0.0.0/16.
  - 2 subnets exist with the right CIDRs and AZ.
  - Public route table has a 0.0.0.0/0 route to an IGW.
  - Private route table has NO 0.0.0.0/0 route.
- Each check prints PASS or FAIL.

**Done when:** every check prints PASS. Commit.

## Phase 3: Add dev and prod VPCs

**Build:** two more module calls in `network/main.tf` for dev (10.1.0.0/16) and prod (10.2.0.0/16).

**Test:**
- Plan should only ADD resources, not change shared-services. If it changes shared, stop and explain.
- Apply after approval.
- Extend `check_network.sh`: all 3 VPCs exist, CIDRs don't overlap, each has 2 subnets.

**Done when:** all checks PASS. Commit.

## Phase 4: VPC peering

**Build:** `network/peering.tf`: peering shared↔dev and shared↔prod (same account, same region, `auto_accept = true`). Add routes in BOTH directions: shared route tables → dev/prod CIDRs, and dev/prod route tables → shared CIDR. No dev↔prod peering or routes.

**Test:**
- Extend `check_network.sh`:
  - Both peering connections are `active`.
  - shared route tables have routes to 10.1.0.0/16 and 10.2.0.0/16 via pcx.
  - dev route tables have a route to 10.0.0.0/16 via pcx, and NO route to 10.2.0.0/16.
  - prod route tables have a route to 10.0.0.0/16 via pcx, and NO route to 10.1.0.0/16.
- Explain to me why dev can't reach prod through shared (non-transitive peering).

**Done when:** all checks PASS. Commit.

## Phase 5: Security groups

**Build:** `network/security_groups.tf`:
- **bastion-sg** (shared): inbound SSH (22) only from `local.my_ip_cidr`. Outbound: SSH and ICMP to 10.1.0.0/16 and 10.2.0.0/16, plus TCP 3306 to 10.2.0.0/16 (used only to generate a blocked-traffic test).
- **dev-workload-sg**: inbound SSH and ICMP only from 10.0.0.0/16. Outbound all.
- **prod-workload-sg**: inbound SSH and ICMP only from 10.0.0.0/16. Nothing on 3306. Outbound all.

**Test:**
- Extend `check_network.sh`:
  - No security group in the project has inbound `0.0.0.0/0`.
  - bastion-sg port 22 source equals my current IPv4 /32 (from `curl -4 https://checkip.amazonaws.com`).
  - dev and prod SGs only allow inbound from 10.0.0.0/16.

**Done when:** all checks PASS. Commit.

## Phase 6: NACLs on private subnets

**Build:** `network/nacls.tf`: custom NACLs for the dev and prod private subnets.
- Inbound: allow TCP 22 and ICMP from 10.0.0.0/16, allow TCP 1024–65535 from 10.0.0.0/16 (return traffic), deny everything else.
- Outbound: allow TCP 1024–65535 and ICMP to 10.0.0.0/16, deny everything else.
- Explain why NACLs need the ephemeral port rules and security groups don't (stateless vs stateful).

**Test:**
- Extend `check_network.sh`: each private subnet is associated with its custom NACL, and the rule numbers and ranges are what we expect.
- The real proof comes in Phase 9.

**Done when:** all checks PASS. Commit.

## Phase 7: Logging stack + flow logs

**Build:**
- `logging/` (its own Terraform stack with its own state): S3 bucket `p1-flowlogs-<account-id>`, block all public access, SSE-S3 encryption, lifecycle rule expiring objects after 30 days, bucket policy allowing `delivery.logs.amazonaws.com` to write, scoped to my account ID. Output the bucket ARN.
- `network/flowlogs.tf`: one `aws_flow_log` per VPC, traffic type ALL, destination S3 (bucket ARN passed in as a variable), 1-minute aggregation interval.

**Test:**
- Apply `logging/` first, then `network/`.
- `aws s3api get-public-access-block` shows all four settings true.
- `aws ec2 describe-flow-logs` shows 3 flow logs with status ACTIVE.
- Confirm that destroying `network/` would NOT touch the bucket (run `terraform plan -destroy` in network/ and show me it doesn't list the bucket).

**Done when:** all checks PASS. Commit.

## Phase 8: Test instances

**Build:** `network/instances.tf`:
- `aws_key_pair` from `~/.ssh/project1.pub`.
- Latest Amazon Linux 2023 AMI via the SSM parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`.
- **bastion**: shared public subnet, public IP, bastion-sg.
- **dev-app**: dev private subnet, no public IP, dev-workload-sg.
- **prod-app**: prod private subnet, no public IP, prod-workload-sg.
- All `t3.micro`, IMDSv2 required, root volume encrypted.
- Outputs: bastion public IP, dev and prod private IPs.

**Test:**
- All 3 instances reach `running` and pass both status checks (`aws ec2 describe-instance-status`).
- dev-app and prod-app have no public IP.
- `ssh -i ~/.ssh/project1 ec2-user@<bastion-ip> 'hostname'` works.

**Done when:** all checks PASS. Commit.

## Phase 9: Connectivity test matrix

**Build:** `tests/connectivity.sh`. Read IPs from `terraform output -json`. Use `ssh -J` (ProxyJump) through the bastion. Each test prints PASS when the result matches the expected result, else FAIL. Use short timeouts (5s) so blocked tests don't hang.

| # | From | To | Expected |
|---|------|----|----------|
| 1 | My Mac | Bastion SSH | Works |
| 2 | My Mac | dev-app directly | Fails (no public IP) |
| 3 | Bastion | dev-app ping + SSH | Works |
| 4 | Bastion | prod-app ping + SSH | Works |
| 5 | dev-app | prod-app ping + TCP 22 | Fails (no route) |
| 6 | prod-app | dev-app ping + TCP 22 | Fails (no route) |
| 7 | dev-app | internet (`curl -m 5 https://example.com`) | Fails (no NAT) |
| 8 | Bastion | prod-app TCP 3306 | Fails (SG blocks, logged as REJECT) |

For tests that start inside dev-app or prod-app, hop through the bastion and use `timeout 5 bash -c '</dev/tcp/IP/PORT'` for TCP checks.

**Test:** run the script, all 8 rows print PASS. If a row fails, explain which layer caused it (route table, SG, or NACL), fix it, and re-run.

**Done when:** 8/8 PASS. Save the output to `docs/connectivity-results.txt`. Commit.

## Phase 10: Prove it with flow logs

**Build:** `tests/check_flowlogs.sh`: wait for logs (they take 5–10 minutes), list the newest objects in the bucket, download them, unzip, and print:
- a count of ACCEPT vs REJECT records,
- the REJECT records for port 3306 toward prod-app's IP (test 8),
- the ACCEPT records for port 22 from the bastion.

**Test:** at least one REJECT record for port 3306 and one ACCEPT for port 22 are found. Explain each field in one REJECT line to me.

**Done when:** both are found. Save the output to `docs/flowlog-evidence.txt`. Commit.

## Phase 11: Documentation and teardown

**Build:**
- `README.md`: what it is, the problem it solves, architecture (with a Mermaid diagram; I'll also add a draw.io image to `docs/`), IP plan table, how to deploy and destroy, test matrix with results, flow log evidence, "what broke and how I fixed it" (from NOTES.md), cost notes, and a short section on when to swap peering for Transit Gateway.
- Screenshot checklist for me: VPC list, peering connections, route tables, SG rules, test script output, S3 flow log objects.

**Test:**
- `terraform destroy` in `network/` (after my approval).
- AWS CLI confirms: no running instances tagged Project=project1, no p1 VPCs left, no peering connections left.
- The logging bucket still exists with its logs.

**Done when:** everything is cleaned up except the bucket. Final commit and push.

---

## Resuming a session

At the start of each session: read `NOTES.md`, tell me where we stopped, run `curl -4 https://checkip.amazonaws.com` to show my current IPv4, and re-apply up to the last completed phase before continuing.

If SSH to the bastion suddenly times out mid-session, my IPv4 has probably changed. Run `terraform apply` again to update the bastion-sg rule.
