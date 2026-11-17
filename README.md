# Hands-on: a three-tier app on AWS Emulator, with no AWS account

A notes app with a page, an API and a database, deployed with Terraform to
AWS Emulator on your own machine. No AWS account, no access keys, no bill.

| Tier | On AWS | Here |
|---|---|---|
| Frontend | S3 bucket, private, served by CloudFront with Origin Access Control | the same, on a local port |
| Server | API Gateway HTTP API and a Python Lambda function | the same; the function really runs |
| Database | DynamoDB table, reached through the function's IAM role | the same |

The Terraform has no endpoint and no keys in it. The shell decides where it
deploys, so the same code goes to a real account later.

First tested on 2026-11-12 with AWS Emulator 1.0.322, Terraform 1.15.9, AWS
CLI 2.37.9, Arch Linux. Last run end to end on 2026-11-17 with 1.0.487: the
deploy (19 resources, 36.8 s), the page in a browser, the IAM break and all
six gap checks. What didn't work, and why the design looks like this, is in
[known-gaps/](known-gaps/README.md).

## What you need

- Linux (x86_64 or arm64), or Docker on macOS and Windows
- AWS CLI v2, Terraform 1.6 or later, curl
- About 2 GB of free memory

## 1. Install the emulator

Amazon Linux, Fedora, RHEL:

```bash
sudo dnf install -y https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/latest/aws-emulator-x86_64.rpm
```

Debian, Ubuntu:

```bash
curl -fsSLo aws-emulator.deb https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/latest/aws-emulator_amd64.deb
sudo apt-get install -y ./aws-emulator.deb
```

Arch, or any Linux without root: the binary has no dependencies beyond glibc,
so unpack the Debian package into your home folder.

```bash
mkdir -p ~/.local/aws-emulator && cd ~/.local/aws-emulator
curl -fsSLo aws-emulator.deb https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/latest/aws-emulator_amd64.deb
bsdtar -xf aws-emulator.deb && bsdtar -xf data.tar.xz
ln -sf ~/.local/aws-emulator/opt/aws-emulator/bin/aws-emulator ~/.local/bin/aws-emulator
```

macOS and Windows: build the image from the Dockerfile in the
[Docker guide](https://docs.aws.amazon.com/emulator/latest/userguide/getting-started-docker.html)
and publish the port as `-p 127.0.0.1:9297:9297`, never `-p 9297:9297`, which
opens it to your network.

Check it:

```bash
aws-emulator -v
```

## 2. Start it

```bash
aws-emulator --telemetry off
```

It listens on `https://127.0.0.1:9297` and writes a fresh access key, a config
file and a certificate to `~/.aws/emulator/9297/`. Leave it running in its own
terminal.

## 3. Point your shell at it

```bash
source scripts/emulator-env.sh
aws sts get-caller-identity
```

You should see account `000000000000`. The script also unsets any real AWS
keys in this shell, so nothing you run here can reach your real account.

Run every command below from this `handson` folder, in a shell where you
sourced the script. A new terminal needs `source scripts/emulator-env.sh`
again.

## 4. Deploy

```bash
./scripts/up.sh
```

`up.sh` refuses to run unless the endpoint is `127.0.0.1` and the account is
`000000000000`. Terraform creates 19 resources in about 40 seconds, most of it
waiting for CloudFront. It prints the site's address.

## 5. Use it

Open the printed address with `http://` and `/index.html`, for example
`http://127.0.0.1:44769/index.html`. Add a note and reload.

From the terminal:

```bash
SITE=$(terraform -chdir=terraform output -raw site_url)
curl --cacert "$AWS_CA_BUNDLE" -X POST -d '{"body":"first note"}' "$SITE/api/notes"
curl --cacert "$AWS_CA_BUNDLE" "$SITE/api/notes"
aws dynamodb scan --table-name notes
```

## 6. Break the permissions on purpose

Take `dynamodb:PutItem` away from the function's role, and keep its two log
actions so the error still reaches CloudWatch Logs:

```bash
POLICY=$(aws iam list-role-policies --role-name notes-api --query 'PolicyNames[0]' --output text)
aws iam put-role-policy --role-name notes-api --policy-name $POLICY --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": "dynamodb:Query", "Resource": "*"},
    {"Effect": "Allow", "Action": ["logs:CreateLogStream", "logs:PutLogEvents"], "Resource": "*"}
  ]
}'
curl --cacert "$AWS_CA_BUNDLE" -X POST -d '{"body":"denied?"}' "$SITE/api/notes"
sleep 2; aws logs tail /aws/lambda/notes-api --since 5m | grep AccessDenied
```

The POST returns 500, and the log says the role is not authorized to perform
`dynamodb:PutItem`. If you also take the log actions away, the function's own
output never reaches the log, so you see a 500 and no reason, as on AWS. Then let Terraform put it back:

```bash
terraform -chdir=terraform plan     # shows the drift
./scripts/up.sh                     # restores the policy
```

The emulator enforced this policy in 1.0.322, but its docs say not to use it
to test security. Test permissions in a real sandbox account before you trust
them.

## 7. See what doesn't work

The app is Lambda and DynamoDB because ECS containers don't run their code,
Aurora fails in Terraform, and on 1.0.382 Lambda couldn't reach RDS for
MySQL (it can on 1.0.481 and 1.0.487). Check that on your version:

```bash
./known-gaps/probe/run.sh
```

It tries Aurora, a security group, an S3 bucket with AWS provider 6, an ECS
Fargate task, RDS for MySQL and a Lambda function that connects to it, each
in its own Terraform folder, and prints `works` or `FAILS` with what happened.
About 5 minutes. No MySQL client is
needed: `known-gaps/probe/rds-mysql/query.py` speaks enough of the protocol,
for example:

```bash
python3 known-gaps/probe/rds-mysql/query.py 127.0.0.1 PORT app probe-only-local-1 probe "SELECT 1"
``` Details are in
[known-gaps/](known-gaps/README.md).

## 8. Stop it

```bash
./scripts/down.sh
```

Or press Ctrl+C in the emulator's terminal. It keeps everything in memory, so
stopping it removes every resource, and the keys it wrote no longer work.

## 9. Deploy the same code to AWS (optional, costs money)

Open a new shell with your real credentials, without sourcing
`emulator-env.sh`, and run `terraform -chdir=terraform apply`. Read the plan
first. Lambda, API Gateway and DynamoDB on demand cost close to nothing for a
few requests, but CloudFront and the rest are billed by AWS, so run
`terraform destroy` when you finish.
