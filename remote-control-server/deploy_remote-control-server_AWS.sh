#!/bin/bash

# ===== Variables =====
read -p "Hostname: " -r _HOSTNAME
[ -z "$_HOSTNAME" ] && _HOSTNAME=$(curl -s http://169.254.169.254/latest/meta-data/public-hostname)

read -p "Secret (empty for auto): " -r _SECRET
[ -z "$_SECRET" ] && _SECRET=$(uuidgen)

read -p "Confirm? " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]] ; then [[ "$0" = "$BASH_SOURCE" ]] && exit 1 ; fi



_PUBLICIP=$(curl -s http://checkip.amazonaws.com)
_EC2ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
_EC2REGION="`echo \"$_EC2ZONE\" | sed 's/[a-z]$//'`"
_AWSACCOUNT="`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | sed -nE 's/.*"accountId"\s*:\s*"(.*)".*/\1/p'`"


# ===== Basic ENV =====
yum -y update

echo alias vi=vim >> /etc/bashrc
echo set autolist >> /etc/bashrc

echo set background=dark >> /etc/vimrc
echo set softtabstop=2 >> /etc/vimrc
echo set nohlsearch >> /etc/vimrc
echo set sw=2 >> /etc/vimrc
echo set tabstop=2 >> /etc/vimrc
echo set autoindent >> /etc/vimrc

hostnamectl set-hostname $_HOSTNAME
mkdir -p /etc/docker.cmd/coturn

aws configure

# ===== Install Packages =====
amazon-linux-extras install -y nginx1 epel
yum -y update
yum -y install docker certbot certbot-nginx


# ===== Docker =====
systemctl enable docker
service docker start

aws ecr get-login-password --region $_EC2REGION | docker login --username AWS --password-stdin $_AWSACCOUNT.dkr.ecr.$_EC2REGION.amazonaws.com


# ===== CRONTAB =====
echo "0 0 * * * root yum -y update --security" >> /etc/crontab
echo "@reboot   root /etc/docker.cmd/signaling.run.sh" >> /etc/crontab
echo "@reboot   root /etc/docker.cmd/coturn.run.sh" >> /etc/crontab
echo "13 0,12 * * * root certbot renew" >> /etc/crontab


# ===== SIGNALING SCRIPT =====
echo '#!/bin/bash' > /etc/docker.cmd/signaling.run.sh
echo "ServerName=SignalingServer" >> /etc/docker.cmd/signaling.run.sh
echo "docker kill \$ServerName" >> /etc/docker.cmd/signaling.run.sh
echo "docker run --rm -d --name \$ServerName -p 8080:8080 $_AWSACCOUNT.dkr.ecr.$_EC2REGION.amazonaws.com/iadea.com-remotecontrol-signaling:latest" >> /etc/docker.cmd/signaling.run.sh
chmod +x /etc/docker.cmd/signaling.run.sh


# ===== COTURN SCRIPT =====
echo '#!/bin/bash' > /etc/docker.cmd/coturn.run.sh
echo "ServerName=CoturnServer" >> /etc/docker.cmd/coturn.run.sh
echo "docker kill \$ServerName" >> /etc/docker.cmd/coturn.run.sh
echo "docker run --rm -d --name \$ServerName --network=host -v "/etc/docker.cmd/coturn":/etc/coturn --mount type=tmpfs,destination=/var/lib/coturn coturn/coturn" >> /etc/docker.cmd/coturn.run.sh
chmod +x /etc/docker.cmd/coturn.run.sh



# ===== COTURN SETTING =====
echo "server-name=$_HOSTNAME" > /etc/docker.cmd/coturn/turnserver.conf
echo "realm=$_HOSTNAME" >> /etc/docker.cmd/coturn/turnserver.conf
echo "external-ip=$_PUBLICIP" >> /etc/docker.cmd/coturn/turnserver.conf
echo "listening-port=3478" >> /etc/docker.cmd/coturn/turnserver.conf
echo "tls-listening-port=5349" >> /etc/docker.cmd/coturn/turnserver.conf
echo "alt-listening-port=3479" >> /etc/docker.cmd/coturn/turnserver.conf
echo "alt-tls-listening-port=5350" >> /etc/docker.cmd/coturn/turnserver.conf
echo "fingerprint" >> /etc/docker.cmd/coturn/turnserver.conf
echo "use-auth-secret" >> /etc/docker.cmd/coturn/turnserver.conf
echo "static-auth-secret=$_SECRET" >> /etc/docker.cmd/coturn/turnserver.conf
echo "cert=/etc/coturn/cert.pem" >> /etc/docker.cmd/coturn/turnserver.conf
echo "pkey=/etc/coturn/privkey.pem" >> /etc/docker.cmd/coturn/turnserver.conf
echo "cipher-list="DEFAULT"" >> /etc/docker.cmd/coturn/turnserver.conf
echo "log-file=/var/log/turnserver.log" >> /etc/docker.cmd/coturn/turnserver.conf
echo "simple-log" >> /etc/docker.cmd/coturn/turnserver.conf
echo "verbose" >> /etc/docker.cmd/coturn/turnserver.conf
echo "TURNSERVER_ENABLED=1" >> /etc/docker.cmd/coturn/turnserver.conf

ln -s /etc/letsencrypt/live/$_HOSTNAME/cert.pem /etc/docker.cmd/coturn/cert.pem
ln -s /etc/letsencrypt/live/$_HOSTNAME/privkey.pem /etc/docker.cmd/coturn/privkey.pem

# ===== NGINX =====
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.original ;
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
sed -i '/^    server {/,/^    }/d' /etc/nginx/nginx.conf ;
sed -i '/include \/etc\/nginx\/conf\.d\/\*\.conf/a \ \ \ \ include /etc/nginx/sites-enabled/*.conf ;' /etc/nginx/nginx.conf ;

echo "server" > /etc/nginx/sites-available/${_HOSTNAME}_.conf
echo "{" >> /etc/nginx/sites-available/${_HOSTNAME}_.conf
echo "  server_name $_HOSTNAME ;"  >> /etc/nginx/sites-available/${_HOSTNAME}_.conf
echo "  listen 80 ;"  >> /etc/nginx/sites-available/${_HOSTNAME}_.conf
echo "  location / {" >> /etc/nginx/sites-available/${_HOSTNAME}_.conf
echo "    add_header Access-Control-Allow-Origin *;" >> /etc/nginx/sites-available/${_HOSTNAME}_.conf
echo "    proxy_pass http://localhost:8080 ;"  >> /etc/nginx/sites-available/${_HOSTNAME}_.conf
echo "    proxy_http_version 1.1;"  >> /etc/nginx/sites-available/${_HOSTNAME}_.conf
echo "    proxy_set_header Upgrade \$http_upgrade;"  >> /etc/nginx/sites-available/${_HOSTNAME}_.conf
echo "    proxy_set_header Connection 'upgrade';"  >> /etc/nginx/sites-available/${_HOSTNAME}_.conf
echo "    proxy_set_header Host \$host;"  >> /etc/nginx/sites-available/${_HOSTNAME}_.conf
echo "    proxy_cache_bypass \$http_upgrade;"  >> /etc/nginx/sites-available/${_HOSTNAME}_.conf
echo "  }"  >> /etc/nginx/sites-available/${_HOSTNAME}_.conf
echo "}"  >> /etc/nginx/sites-available/${_HOSTNAME}_.conf

ln -s /etc/nginx/sites-available/${_HOSTNAME}_.conf /etc/nginx/sites-enabled/${_HOSTNAME}_.conf

systemctl enable nginx
service nginx start

# ===== Final =====
cd /etc/docker.cmd
./signaling.run.sh

certbot --nginx -d $_HOSTNAME --redirect -m rich.hsu@iadea.com --agree-tos -n

./coturn.run.sh

echo "===== Done ====="
echo ""

