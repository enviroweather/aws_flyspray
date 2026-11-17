# Notes on building flyspray instance on AWS lightsail

### 11/16 11pm 

add this to prevent IP address from being destroyed:

```
resource "aws_lightsail_static_ip" "flyspray" {
  name = local.static_ip_name

  lifecycle {
    prevent_destroy = true
  }
}

```

How can you destroy all the things, but keep the ip address?

**Step 1 — Detach the static IP first (before destroying the instance)**
terraform destroy \
  -target=aws_lightsail_static_ip_attachment.flyspray

**Step 2 — Destroy the instance, database, and dependent resources (NOT the static IP)**

terraform destroy \
  -target=null_resource.instance_auto_snapshot \
  -target=aws_lightsail_instance_public_ports.flyspray \
  -target=aws_lightsail_instance.flyspray \
  -target=aws_lightsail_database.flyspray

## 11/16 10pm switching away from bitnaming to an AWS blueprint

Important: SELinux Note

The lamp_ls_1_0
blueprint runs Amazon Linux 2023, which has SELinux enforcing by default. Without the setsebool
and chcon
commands in step 8, Apache will silently fail to write to the attachments
folder and flyspray.log
even though the Unix permissions look correct. This is a very common gotcha when migrating from Bitnami.

You can verify SELinux is the issue after boot by running:

sudo ausearch -m avc -ts recent | grep httpd

lamp_8_bitnami
is actually still active (not truly deprecated in the API sense) — but AWS has released a newer first-party replacement:
Use lamp_ls_1_0
— LAMP PHP 8.5.12 (AWS-native, not Bitnami)

blueprint_id = "lamp_ls_1_0"

This is the new AWS-managed LAMP stack (the _ls_1_0
suffix = "Lightsail 1.0", AWS's own stack replacing Bitnami). Key differences that affect your user_data
script:
Item	lamp_8_bitnami
(old)	lamp_ls_1_0
(new)
PHP config path	/opt/bitnami/php/etc/php.ini
	/etc/php.ini
or /etc/php.d/
Web root	/opt/bitnami/apache/htdocs
	/var/www/html
Restart command	/opt/bitnami/ctlscript.sh restart apache
	systemctl restart httpd
or apache2
User	bitnami
	apache
or ec2-user
SSL tool	bncert-tool
	Use certbot
directly

### Outputs

Outputs:

app_url = "https://flyspray.enviroweather.net"
db_endpoint = "ls-02d346a02a4b8f66dcec27e73aad585277082c4b.c5k4kueayxhx.us-east-2.rds.amazonaws.com"
db_instance_name = "ewx-flyspray-db"
db_port = 5432
flyspray_conf_path = "./output/flyspray.conf.php"
instance_name = "flyspray-app"
next_steps = <<EOT

---- NEXT STEPS (in order) ----

Note: Flyspray and flyspray.conf.php are automatically installed and
configured on the Lightsail instance on first boot via user_data.

1. Create GoDaddy DNS A record:
     Name:  flyspray
     Value: 3.138.88.53
     TTL:   600

2. Run the DB import (loads dump from S3 into managed PostgreSQL):
     cd terraform/
     ./scripts/import_db.sh

3. Wait for DNS propagation:
     dig +short flyspray.enviroweather.net   # should return 3.138.88.53

4. Provision SSL (Let's Encrypt):
     output/setup_ssl.sh

5. Open https://flyspray.enviroweather.net

To tear everything down:
     terraform destroy

EOT
region = "us-east-2"
s3_bucket = "ewx-flyspray-config-941061635635-us-east-2-an"
s3_dump_key = "flyspray_22_10_2026.sql"
setup_ssl_path = "./output/setup_ssl.sh"
static_ip = "3.138.88.53"


### IAM policies

we don't have good AWS IAM here at msu. you have to use an IAM user

you have to give that user access to lightsail stuff for this to work

```
export FLYSPRAY_IAM_USER=
aws iam put-user-policy \
  --user-name $FLYSPRAY_IAM_USER \
  --policy-name LightsailFullAccess \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": "lightsail:*",
        "Resource": "*"
      }
    ]
  }'

```

---

## How CLI + MFA works for IAM users

Your IAM user has a long-term access key (the AWS_ACCESS_KEY_ID
/ AWS_SECRET_ACCESS_KEY
stored on disk). MFA adds a second factor by requiring you to get a temporary session token before running commands. The flow is:

    You run one command with your long-term key + a 6-digit MFA code
    AWS returns temporary credentials (valid for up to 12 hours)
    You use those temporary credentials for all your actual work

Step-by-step setup
Step 1: Assign a virtual MFA device to billspat-ewx

    Go to IAM → Users → billspat-ewx → Security credentials tab 
    Under Multi-factor authentication (MFA), click Assign MFA device
    Choose Authenticator app (Google Authenticator, Authy, 1Password, etc. — any TOTP app works)
    Scan the QR code and enter two consecutive codes to confirm
    Note the MFA device ARN — it looks like: arn:aws:iam::941061635635:mfa/billspat-ewx

Step 2: Get a temporary session token via CLI

aws sts get-session-token \
  --serial-number arn:aws:iam::941061635635:mfa/billspat-ewx \
  --token-code 123456 \
  --duration-seconds 43200
Run in CloudShell

Replace 123456
with the current 6-digit code from your authenticator app. 43200
= 12 hours.

This returns:

{
  "Credentials": {
    "AccessKeyId": "ASIA...",
    "SecretAccessKey": "...",
    "SessionToken": "...",
    "Expiration": "2026-11-17T13:44:00Z"
  }
}

Step 3: Use the temporary credentials

You have two options:

Option A — Export as environment variables (easiest, lasts for your terminal session):

export AWS_ACCESS_KEY_ID=ASIA...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...
Run in CloudShell

Then run your normal aws lightsail ...
commands as usual.

Option B — Add a named profile to ~/.aws/credentials
:

[billspat-mfa]
aws_access_key_id = ASIA...
aws_secret_access_key = ...
aws_session_token = ...

Then use --profile billspat-mfa
on your commands, or set export AWS_PROFILE=billspat-mfa
.
Making it less painful — a helper script

Since you'll do this regularly, a small shell script saves time:

#!/bin/bash
# get-mfa-creds.sh
read -p "Enter MFA code: " MFA_CODE
CREDS=$(aws sts get-session-token \
  --serial-number arn:aws:iam::941061635635:mfa/billspat-ewx \
  --token-code $MFA_CODE \
  --duration-seconds 43200 \
  --output json)

export AWS_ACCESS_KEY_ID=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['AccessKeyId'])")
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['SecretAccessKey'])")
export AWS_SESSION_TOKEN=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['SessionToken'])")
echo "Temporary credentials set — valid for 12 hours."
Run in CloudShell

Run it with source get-mfa-creds.sh
(must use source
so the exports apply to your current shell).
Summary
	Long-term key (current)	With MFA
Stored on disk	✅	✅ (same key stays on disk)
Needs SSO/Control Tower	❌	❌
Needs institution support	❌	❌
Protected if key is leaked	❌	✅
Extra step to start working	None	~30 seconds once per 12 hours

No SSO, no Control Tower, no institution involvement needed — it's entirely self-contained to your IAM user and a free authenticator app on your phone.


---



### prompt for holding on to the IP Address

thank you for this.   can you confirm that this is the curre  workflow very broadly : build on aws -> get an IP assigned -> update godaddy DNS  .  I already have to setup the S3 bucket separately to hold the SQL dump file. That means that is some prequisite AWS setup to do before building.  Could I also get an IP address from AWS before building this that I can re-use and hold on-to if I need to build again (because it didn't work OR because I did something wrong in the terraform code).  updating the IP in GoDaddy is time consuming and it takes a while to propagate.   I do not have enough experience with Terraform to know how to update/fix part of this architecture and leaving other parts - specifically the IPv4 address assignment -  alone.  Is this a better workflow to el
1. setup s3 and get an AWS IPv4 address-> 
2. update subdomain DNS On godaddy -> 
3. set IP and s3 on tfvars
4. build with TF, using the IP address for lightsail (don't provision a new one) -> 
5. find a problem / fix TF  or script issue -> 
6. rebuild with TF -> 
7. iterate 5 and 6 until awesome

