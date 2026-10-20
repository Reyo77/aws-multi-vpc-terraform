# NOTES

## Phase 0: Preflight (passed)
- Terraform v1.16.6, aws-cli 2.38.1, caller is IAM user `admin` (not root), `~/.ssh/project1.pub` exists, outbound IPv4 works.
- Dry-runs in ap-southeast-2: describe-availability-zones OK (2a/2b/2c available), create-vpc DryRunOperation (allowed), run-instances t3.micro in 2a with AL2023 SSM AMI DryRunOperation (allowed), `aws s3 ls` OK.

### What broke
- us-east-1 was unusable: `ec2:DescribeInstanceTypeOfferings`, `DescribeAvailabilityZones`, `CreateVpc` and `ssm:GetParameters` all hit an explicit deny from the Organization SCP. Decoded message: statement `UsEast1Partitional`, applies when `aws:RequestedRegion` = us-east-1, and EC2/VPC/SSM are not in its list of exceptions.
- Fix: moved the whole project to `ap-southeast-2` (Sydney), AZ `ap-southeast-2a`. CLAUDE.md updated.
