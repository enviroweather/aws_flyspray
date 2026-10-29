

```
============================================================
  Flyspray Lightsail deployment complete
============================================================
  Instance name      : flyspray-app
  Static IP          : 23.23.183.225  (permanent — survives reboots)
  DB instance        : flyspray-db
  DB endpoint        : ls-0cc651625e76166a8370fee34b3c98c860925e66.con0iiu8wblf.us-east-1.rds.amazonaws.com:5432
  App database       : flyspray
  App user           : flyspray_user
  App hostname       : flyspray.enviroweather.net
  Instance snapshots : daily at 02:00 UTC, 7-day retention
  DB backups         : daily at 03:00-03:30 UTC, 7-day retention

  ---- NEXT STEPS (in order) ----

  1. Create GoDaddy DNS A record:
       Name:  flyspray
       Value: 23.23.183.225
       TTL:   600

  2. SSH in and install Flyspray into the web root:
     Correct way to SSH in

Step 1 — Download your Lightsail default key pair

aws lightsail download-default-key-pair \
  --region us-east-1 \
  --query 'privateKeyBase64' \
  --output text | base64 --decode > ~/.ssh/lightsail-default.pem

chmod 600 ~/.ssh/lightsail-default.pem

     On the instance:
cd /opt/bitnami/apache/htdocs
sudo wget https://github.com/flyspray/flyspray/releases/download/v1.0/flyspray-1.0.tar.gz
sudo tar xzf flyspray-1.0.tar.gz
sudo mv flyspray/* .
sudo mv flyspray/.htaccess . 2>/dev/null || true
sudo rm -rf flyspray flyspray-1.0.tar.gz

  3. Copy flyspray.conf.php to the instance:
       scp /tmp/flyspray.conf.php bitnami@23.23.183.225:/tmp/
     On the instance:
       sudo mv /tmp/flyspray.conf.php /opt/bitnami/apache/htdocs/
       sudo chown -R bitnami:daemon /opt/bitnami/apache/htdocs
       sudo chmod -R 775 /opt/bitnami/apache/htdocs/attachments

  4. Wait for DNS propagation:
       dig +short flyspray.enviroweather.net   # should return: 23.23.183.225

  5. Provision SSL:
       /tmp/setup_ssl.sh

  6. Open https://flyspray.enviroweather.net

  ```