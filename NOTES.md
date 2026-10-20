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
