#!/bin/bash
set -e
# install basics
yum update -y
# install curl, git
yum install -y git

# install Node 20 from NodeSource
curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
yum install -y nodejs gcc-c++ make

# install pm2 globally
npm install -g pm2

# clone repo
cd /opt || exit 1
# remove folder if exists
rm -rf app
git clone "${git_repo}" app
cd app || exit 1

# create .env with DB and S3 settings (adjust keys per your Strapi config)
cat > .env <<EOF
DATABASE_CLIENT=postgres
DATABASE_HOST=${db_host}
DATABASE_PORT=${db_port}
DATABASE_NAME=${db_name}
DATABASE_USERNAME=${db_user}
DATABASE_PASSWORD=${db_password}
AWS_S3_BUCKET=${s3_bucket}
NODE_ENV=production
EOF

# install production deps and build
npm install --production --legacy-peer-deps
npm run build

# start via pm2
pm2 start npm --name "strapi" -- start
pm2 save
pm2 startup systemd -u ec2-user --hp /home/ec2-user || true

