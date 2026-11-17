# What broke on AWS Emulator 1.0.322

Tested on 2026-11-12 with AWS Emulator 1.0.322 (release date 2026-11-10),
Terraform 1.15.9, AWS CLI 2.37.9, on Arch Linux. The emulator ships several
releases a day, so check each of these again before recording:

```bash
source scripts/emulator-env.sh
./known-gaps/probe/run.sh            # all six, about 5 minutes
./known-gaps/probe/run.sh ecs        # or one: aurora, security-group, provider6, ecs, rds-mysql, lambda-rds
```

It deploys a small Terraform folder for each check (Aurora, a security group,
an S3 bucket with provider 6, an ECS Fargate task, RDS for MySQL, and a Lambda
function that connects to RDS for MySQL), prints `works` or `FAILS` with what
happened, and cleans up.

Rechecked on 1.0.382 (release date 2026-11-14) on 2026-11-15 with `run.sh`:
Aurora, the security group, provider 6 and ECS still fail; RDS for MySQL works,
with limits (below).

Rechecked on 1.0.471 on 2026-11-16: ECS and RDS for MySQL unchanged (ECS now
reports the exit code as `None` instead of 127).

Rechecked on 1.0.481 (release date 2026-11-16) on 2026-11-17 with `run.sh`:
Aurora, the security group, provider 6 and ECS still fail. RDS for MySQL is
unchanged. **Lambda can now reach RDS for MySQL**: a function with no VPC
config opened a socket to the database and ran `SELECT 6*7` (server
`8.0.40`). The "Lambda networking" row below was true on 1.0.322 and 1.0.382
and isn't on 1.0.481.

Rechecked on 1.0.487 (release date 2026-11-17) on 2026-11-17, the author's
run of `run.sh`: Aurora, the security group, provider 6 and ECS still fail
(ECS: exit `None`, the image's command didn't run, a plain `echo` reached the
log). **RDS for MySQL: `NOW()` works** (`CURRENT_TIMESTAMP works, NOW()
works`); the other time functions and the error wording weren't rechecked.
Lambda reaches RDS for MySQL (`{"ok": true, "server": "8.0.40", "result":
"42"}`).

Rechecked on 1.0.488 (release date 2026-11-17) on 2026-11-17: the same six
results as 1.0.487. The notes app deploys and works; once, the first POST after
the deploy returned 500 with `RuntimeError: the invocation ran past its memory
ceiling` in the function's log although the note was saved (also seen once on
1.0.382). Send it again and it works.

| What | What happened | What the hands-on does |
|---|---|---|
| AWS provider 6.x and S3 buckets | `aws_s3_bucket` fails: the provider reads bucket tags through S3 Control, which puts the account ID in the host name (`000000000000.127.0.0.1`). The docs say S3 Control can't reach the emulator. | Pins `hashicorp/aws ~> 5.100`. |
| Security groups | `aws_security_group` fails: `RevokeSecurityGroupEgress` returns `InvalidPermission.NotFound`. The emulator creates a group without the default egress rule that AWS adds. | No security group. The app has no VPC resources. |
| Aurora through Terraform | `aws_rds_cluster` fails after create: `DescribeGlobalClusters` rejects the `db-cluster-id` filter ("the only supported filter is region"). The cluster itself works from the CLI, and so does the RDS Data API. | DynamoDB for the data tier. The Aurora version is kept in `aurora-database.tf.txt`. |
| DynamoDB on-demand tables | Every plan shows drift: the emulator reports `on_demand_throughput` as -1, and the update it plans is rejected. | `lifecycle { ignore_changes = [on_demand_throughput] }`. |
| CloudFront default root object | `GET /` returns the bucket listing (XML) instead of `index.html`, even though the bucket policy allows only `s3:GetObject`. On AWS this returns `index.html`. | Open `/index.html`. |
| CloudFront redirect to HTTPS | `http://` is served instead of redirected. | Used on purpose: the browser trusts plain HTTP on 127.0.0.1, and not the emulator's certificate, which changes on every start. |
| ECS on Fargate | The control plane works: clusters, task definitions, services, `RunTask`, task states, and even the network check (a task in a subnet with no route to the registry stops with `CannotPullContainerError`, as on AWS; give the subnet an internet gateway and it reaches `RUNNING`). But the container's own command never runs. A busybox task with `sh -c "echo ran-$((6*7)); uname -s"` stops with exit code 127 and logs nothing. A plain `echo hello` command does reach CloudWatch Logs, and `exit 7` is reported as 7, so the emulator reads simple commands itself; nothing from the image runs. On 1.0.481 the same holds, whatever the setup: with AWS's own test setup (Amazon Linux image, security group, `AmazonECSTaskExecutionRolePolicy`, the ECS service-linked role) `echo` and `sleep` work and exit 0, while `$((6*7))`, `uname`, `cat /etc/os-release` and `python3 -c ...` all stop with exit `None` and an empty log, and no Docker container starts. AWS's own passing test for ECS logs uses only `echo` and `sleep`. A service reaches `runningCount` 1 and a completed rollout, but only the control plane is real. AWS tracks this as an open issue, "ECS task data plane: container commands never execute (exit 127)" (`issues/things-that-do-not-work/20261111T145804Z-ecs-task-data-plane-container-commands-never-execute.md` in the emulator repo). | Lambda for the app tier. |
| ECR push | `docker push` to `127.0.0.1:9297` logs in but fails: "the operation is unsupported". | Not used. |
| RDS for MySQL | Works, with limits. `aws_db_instance` with `engine = "mysql"` comes up in about 17 seconds on `127.0.0.1` and a local port, and speaks the MySQL protocol (server `8.0.40`, `mysql_native_password`; a wrong password is refused). Tables, `AUTO_INCREMENT`, `DEFAULT CURRENT_TIMESTAMP`, joins with `GROUP BY`, subqueries, foreign keys, unique keys, `START TRANSACTION` and `ROLLBACK`, indexes and `JSON_EXTRACT` all worked. But it isn't MySQL underneath: `SELECT NOW()` and `DATE_FORMAT(NOW(), ...)` fail with `ERROR 1064`, and constraint errors use SQLite's wording (`UNIQUE constraint failed: users.id`, `FOREIGN KEY constraint failed`). On 1.0.481 bare `CURRENT_TIMESTAMP` works, while `NOW()`, `CURRENT_TIMESTAMP()`, `UTC_TIMESTAMP()`, `SYSDATE()` and `CURDATE()` still fail with `ERROR 1064`. On 1.0.487 `NOW()` works. Test your real queries against real MySQL too. | Not used: on 1.0.382 Lambda couldn't open a socket to the database port (next row), and ECS can't run the app. |
| Lambda networking | Function code runs (Python, inside the emulator), and calls to emulated AWS services work through the SDK. On 1.0.322 and 1.0.382 any other network use failed: "a Lambda function in this emulator has no host network to reach". So a function couldn't open a socket to the emulated RDS port. **Fixed on 1.0.481**: a function, with or without VPC config, connects to RDS for MySQL and runs SQL (`./known-gaps/probe/run.sh lambda-rds`). | The app talks only to DynamoDB through the SDK. On 1.0.481, Lambda with RDS for MySQL is an option again. |
| Lambda's SDK | The Python runtime ships its own small boto3. Some calls aren't there, for example S3 `ListBuckets` ("the AWS SDK this runtime supplies binds no ListBuckets call"). DynamoDB `PutItem` and `Query` work. | Uses only `PutItem` and `Query`. |

## What worked better than the docs say

- IAM identity policies are enforced for users and roles other than the emulator's own key. A user with no policy got `AccessDeniedException` on `GetSecretValue`. Removing `dynamodb:PutItem` from the Lambda role made `POST /api/notes` fail with `AccessDeniedException`, and the error was in CloudWatch Logs. The docs still say not to use the emulator to test security, and only the emulator's own key is never denied, so treat this as a bonus, not a guarantee.
- Rechecked on 1.0.382 (2026-11-15). Still enforced, and a user with no policy still gets `AccessDeniedException` on `PutItem`. Taking the log actions away from the role hides the function's own output, as on AWS: the denied POST left only the `START` line, with no error. Once, the first denied call after a deploy logged `RuntimeError: the invocation ran past its memory ceiling` (inside the runtime's botocore, while reading the reply) instead of `AccessDeniedException`; the next two denied calls logged `AccessDeniedException` as expected.
- The CloudFront bucket policy check worked: with no Origin Access Control and policy, CloudFront returned `403 AccessDenied`, as on AWS.
- RDS for PostgreSQL gave a working Postgres endpoint on a local port (`psql` connected, created a table and inserted rows). Aurora PostgreSQL with the RDS Data API worked from the CLI.

## Browsers and the emulator

The emulator answers `403` with the body `cross-site request` when a request
looks cross-site to it: `Sec-Fetch-Site: cross-site`, or an `Origin` header
without `Sec-Fetch-Site: same-origin`. That stops a web page you visit from
calling the AWS on your laptop. Same-origin requests from the notes page pass
(tested with curl and browser headers). A Chrome tab driven by an automation
extension was refused even for a typed address, so check the page in your own
browser before recording.
