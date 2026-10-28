# Flyspray on AWS

These are scripts and support docs for creating an instance of [AWS Lightsail] 
with Postgresql to run [Flyspray](https://www.flyspray.org/), a a lightweight, web-based bug tracking system written in PHP.  

the end result is a lightsail application that runs Flyspray and Postgresql and 
that is all. Therefore it launches the Flyspray app on the root.  We designed 
this to use a subdomain (cause it's easy) so (for example)
flyspray.yoursite.whatever -> Flyspray app (instead of in a subfolder 
like `yoursite.whatever/flyspray`)

The script does many things, and was developed with the assistance of AWS "Q" 
in the AWS console. 

## Pre-requisites:

 - AWS account with money.  This will create an app that costs money. 
 - AWS user id with power to create things
 - A SQL dump file to import. Right now that was our use case so it's not 
   set for working without that. 
 - An S3 bucket containing the SQL dump file. This should probably be in the
   same region that you are creating this service in ( and running this script), 
   and the ability to read it from the account that you are running this from
   *tip* set up AWS and the region, then create the bucket in that region, 
   and upload the SQL dump file there. 

### Pre-req's for Option A.  On your computer

 - terminal with shell interpreter.  This is a shell script to be run from the terminal
 - bash > version 4.  On Mac this will require installing bash, easiest with homebrew
   Mac: `brew install bash`  
 - AWS CLIv2: see [Installing AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
 - a working subdomain that you have control of and can work
   with ssl certificates.  That usually involves editing DNS records on your domain
   registrar.  For example flyspray.mydomain.whatever
 - to work with the SSL installer, and a working email address
 - several environment variables set, which means decisions made on passwords, 
   etc.  See 'running' below

### Alternative Pre-requisites

Given you have an AWS account,  you could run all of this in the [AWS Cloud Shell]
which comes with bash, AWS CLI, and knows what region you want based on what you 
set in the  

## Running 

### 1. Set the AWS config.  See https://docs.aws.amazon.com/cli/latest/reference/configure/
for how to do this.  For one, you need to do this and log-in to AWS in order for this
script to run.

### 2. Set variables
Variables with Secrets () have NO default and will
cause the script to exit if not supplied via environment. Other variables have
no reasonable 'default' value so you must set those, too. 

export APP_PASSWORD=
export DB_MASTER_PASSWORD=
export APP_HOSTNAME=
export SSL_EMAIL=

You could put these things in a  file and source it

For example, `aws_flyspray_config.sh`  ( **DON'T CHEDCK THIS INTO GIT**)

then, before each run, do `source aws_flyspray_config.sh`

(using the source command ensure the variables are set in current shell
environment and not a subshell)

### 3. Run with command line options (see below)

`./deploy_flyspray.sh option1, option2 option2`

### Usage examples:

Minimum options set: 
```
export FLYSPRAY_DB_MASTER_PASSWORD="..."
export FLYSPRAY_APP_PASSWORD="..."
export FLYSPRAY_HOSTNAME="flyspray.example.com"
export FLYSPRAY_SSL_EMAIL="admin@example.com"
./deploy_flyspray.sh
```

Override instance name and hostname via positional args:

```
# set vars as above
./deploy_flyspray.sh flyspray-dev dev.example.com admin@example.com
```


Create a Dev/test version of a FlySpray server with a different LightSail 
type (aka bundle) :

```
# export required options as above
export FLYSPRAY_INSTANCE_BUNDLE="nano_3_0"
export FLYSPRAY_DB_BUNDLE="micro_2_0"
./deploy_flyspray.sh flyspray-dev fs-dev.example.com admin@example.com
```

## Outputs 

### setup_ssl.sh
    
is generated automatically at /tmp/setup_ssl.sh
as part of the script run. It includes a DNS verification check before attempting the certificate — if your A record hasn't propagated yet it will exit cleanly with a clear error rather than failing mid-way through bncert
    .
### flyspray.conf.php

is created for the app based on variables set here.  In the Lightsail instance,
it's destination is /opt/bitnami/apache/htdocs/flyspray.conf.php

Two things to double-check before running

    Change the four values at the top: 
    .
    dig
    must be available on the machine running setup_ssl.sh
    — it's used to verify DNS propagation. On macOS it's built in; on Ubuntu/Debian: apt install dnsutils
    .

Order of operations after the script finishes

The printed summary walks you through it step by step, but the critical sequencing rule is: DNS A record must be live and verified before running setup_ssl.sh
— Let's Encrypt will fail the HTTP-01 challenge if the domain doesn't resolve to the instance yet.


## Epilogue: Instance automatic snapshots

We like snapshots.  Things go wrong, we want to go back in time.  
Lightsail has a built-in automatic snapshot feature for instances — it takes a daily snapshot and retains the last 7 days. Here are This CLI calls that enables it, but they 
are both baked in the shell script, just here for reference 

```
# don't run this, already in the builder script
export LIGHTSAIL_APP_NAME=your-app-name-here
aws lightsail enable-add-on \
  --resource-name "$LIGHTSAIL_APP_NAME" \
  --add-on-request addOnType=AutoSnapshot,autoSnapshotAddOnRequest={snapshotTimeOfDay="02:00"} \
  --region us-east-1
```

The managed PostgreSQL database has its own independent backup mechanism — also a single flag:
```
# dont' run this, already in the builder script

aws lightsail update-relational-database \
  --relational-database-name "flyspray-db" \
  --preferred-backup-window "03:00-03:30" \
  --backup-retention-enabled \
  --region us-east-1
```

### Restoring from a snapshot — quick reference

Snapshots are worthless if you can use them to restore your hard work. 

1. Instance snapshot → new instance:

You hve to set things to match your LightSail settings
- region
- name of the snapshot
- type of bundle to match (maybe?)

```
export LIGHTSAIL_SNAPSHOT_NAME=yournamehere
# set the restorename
# set the region, maybe using aws config
export LIGHTSAIL_REGION=us-east-1
aws lightsail create-instances-from-snapshot \
  --instance-snapshot-name $LIGHTSAIL_SNAPSHOT_NAME \
  --instance-names "my-lightsail-app-restored" \
  --region $LIGHTSAIL_REGION \
  --availability-zone ${LIGHTSAIL_REGION}a \
  --bundle-id micro_3_0 
```



DB snapshot → new database

Again, there are things to set here, like the name of the database (that 
will be used by the restored version of flyspray in the config file)
```
# using the same region as set above
export LIGHTSAIL_SNAPSHOT_NAME=yournamehere
aws lightsail create-relational-database-from-snapshot \
  --relational-database-snapshot-name $LIGHTSAIL_SNAPSHOT_NAME \
  --relational-database-name "flyspray-db-restored" \
  --availability-zone ${LIGHTSAIL_REGION}a \
  --region $LIGHTSAIL_REGION
```
