## AWS Deploy Flyspray - example installation report

The shell script `./deploy_flyspray.sh` emits a report similar to the following 
after it's complete.  The values printed here were generated during 
creation specific to this deployment (e.g. IP address) or were sent as command
line params. Specifics have been removed from this report. 


```
============================================================
  Flyspray Lightsail deployment complete
============================================================
  Instance name      : flyspray-app
  Static IP          : x.x.x.x 
  DB instance        : flyspray-db
  DB endpoint        : <db access on rds.amazonaws.com>
  App database       : flyspray
  App user           : flyspray_user
  App hostname       : flyspray.enviroweather.net, subdomain
  Instance snapshots : daily at 02:00 UTC, 7-day retention
  DB backups         : daily at 03:00-03:30 UTC, 7-day retention

  ---- NEXT STEPS (in order) ----

  1. Create DNS A record with your registrar for subdomain above
       Name:  flyspray
       Value: x.x.x.x
       TTL:   600

  2. Actually install the latest flyspray on this new resource
  
     SSH in and install Flyspray into the web root:
       aws lightsail ssh --instance-name flyspray-app --region us-east-1

     On the instance:
       cd /opt/bitnami/apache/htdocs
       sudo wget https://github.com/flyspray/flyspray/releases/download/v1.0/flyspray-1.0.tar.gz
       sudo tar xzf flyspray-1.0.tar.gz
       sudo mv flyspray/* .
       sudo mv flyspray/.htaccess . 2>/dev/null || true
       sudo rm -rf flyspray flyspray-1.0.tar.gz

  3. Place config file created by deploy script
  
  The deployment script creates an appropriate conf file and saves it in /tmp
  
  Copy flyspray.conf.php to the instance:

       scp /tmp/flyspray.conf.php bitnami@x.x.x.x:/tmp/
     On the instance:
       sudo mv /tmp/flyspray.conf.php /opt/bitnami/apache/htdocs/
       sudo chown -R bitnami:daemon /opt/bitnami/apache/htdocs
       sudo chmod -R 775 /opt/bitnami/apache/htdocs/attachments

  4. Wait for DNS propagation:
     On your computer that has dig installed, run 
       dig +short flyspray.enviroweather.net   # should return ip address above

  5. Provision SSL:
       /tmp/setup_ssl.sh

  6. Open domain provisioned above
     https://flyspray.enviroweather.net

```