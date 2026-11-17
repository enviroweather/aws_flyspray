## AWS User Provisioning

To use Terraform or any AWS CLI scripts for our institution, you need 
an "IAM User" setup on your computer with credentials (documentation forth coming). 
The kinds of authentication AWS preferred currently don't work here (SSO, IdentityCenter, etc)

You have to create an "IAM User" 

To work on laptop you have create credentials, on the laptop run `aws configure` 
and setup the id and secret key.  (see below) 

At some point after creating that users,  you have to add permissions  to work
with the services in AWS.  These are not simple to add but requires using policy in JSON format. 

The scripts in this folder helps with that. However the IAM user does not have permissions
to give itself more permissions.  You will haave to do that in the console using 
the cloud shell (where you have full permissions).  

## Scripts

**These scripts are right now untested**

Whole new user: 

`./setup-lightsail-container-user.sh   <username> <group> <app-name>`

Existing user in an existing group: 

`./update-lightsail-container-policy.sh <username> <app-name>`


### A few things worth knowing for CloudShell specifically:

Upload the scripts using the 
CloudShell Actions → Upload file button (in the top-right of the CloudShell panel)
You could also git clone but have to set up an ssh key for your git service 
apparently you can't curl from outside without extra setup. The "CloudShell quick reference" tab has the full sequence.

A temp password generated for a new user uses openssl `rand`
which is available in CloudShell. The new user is forced to change it on first login — share it securely (not by email in plaintext).

Access keys are not created automatically by the setup script — that is intentional. You still have 
to do that in the IAM console, or run 

`aws iam create-access-key --user-name <username>`

as a separate step and save the SecretAccessKey immediately, as it is only shown once.
