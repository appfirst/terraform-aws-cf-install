#!/bin/bash

echo Provisioning start $(date)

# fail immediately on error
set -e -x

# echo "$0 $*" > ~/provision.log

fail() {
  echo "$*" >&2
  exit 1
}

# Variables passed in from terraform, see aws-vpc.tf, the "remote-exec" provisioner
AWS_KEY_ID=${1}
AWS_ACCESS_KEY=${2}
REGION=${3}
VPC=${4}
BOSH_SUBNET=${5}
IPMASK=${6}
CF_IP=${7}
CF_SUBNET1=${8}
CF_SUBNET1_AZ=${9}
CF_SUBNET2=${10}
CF_SUBNET2_AZ=${11}
BASTION_AZ=${12}
BASTION_ID=${13}
LB_SUBNET1=${14}
CF_SG=${15}
CF_ADMIN_PASS=${16}
CF_DOMAIN=${17}
CF_BOSHWORKSPACE_VERSION=${18}
CF_SIZE=${19}
DOCKER_SUBNET=${20}
INSTALL_DOCKER=${21}
APPFIRST_TENANT_ID=${22}
APPFIRST_FRONTEND_URL=${23}
APPFIRST_SERVER_TAGS=${24}
APPFIRST_USER_ID=${25}
APPFIRST_USER_KEY=${26}
CF_API=${27}

boshDirectorHost="${IPMASK}.1.4"
cfReleaseVersion="207"

cd $HOME
(("$?" == "0")) ||
  fail "Could not find HOME folder, terminating install."


# Generate the key that will be used to ssh between the bastion and the
# microbosh machine
if [[ ! -f ~/.ssh/id_rsa ]]; then
  ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
fi

# Prepare the jumpbox to be able to install ruby and git-based bosh and cf repos

release=$(cat /etc/*release | tr -d '\n')
case "${release}" in
  (*Ubuntu*|*Debian*)
    sudo add-apt-repository -y ppa:git-core/ppa  
    sudo apt-get update -yq
    sudo apt-get install -yq aptitude build-essential vim-nox git unzip tree \
       libxslt-dev libxslt1.1 libxslt1-dev libxml2 libxml2-dev \
      libpq-dev libmysqlclient-dev libsqlite3-dev \
      g++ gcc make libc6-dev libreadline6-dev zlib1g-dev libssl-dev libyaml-dev \
      libsqlite3-dev sqlite3 autoconf libgdbm-dev libncurses5-dev automake \
      libtool bison pkg-config libffi-dev cmake tmux htop iftop iotop tcpdump kpartx \
      python3-pip
    ;;
  (*Centos*|*RedHat*|*Amazon*)
    sudo yum update -y
    sudo yum install -y epel-release
    sudo yum install -y git unzip xz tree rsync openssl openssl-devel \
    zlib zlib-devel libevent libevent-devel readline readline-devel cmake ntp \
    htop wget tmux gcc g++ autoconf pcre pcre-devel vim-enhanced gcc mysql-devel \
    postgresql-devel postgresql-libs sqlite-devel libxslt-devel libxml2-devel \
    yajl-ruby cmake
    ;;
esac

# Install RVM

if [[ ! -d "$HOME/rvm" ]]; then
  git clone https://github.com/rvm/rvm
fi

if [[ ! -d "$HOME/.rvm" ]]; then
  cd rvm
  ./install
fi

cd $HOME

if [[ ! "$(ls -A $HOME/.rvm/environments)" ]]; then
  ~/.rvm/bin/rvm install ruby-2.1
fi

if [[ ! -d "$HOME/.rvm/environments/default" ]]; then
  ~/.rvm/bin/rvm alias create default 2.1
fi

source ~/.rvm/environments/default
source ~/.rvm/scripts/rvm

# Install BOSH CLI, bosh-bootstrap, spiff and other helpful plugins/tools
gem install fog-aws -v 0.1.1 --no-ri --no-rdoc --quiet
gem install bundler bosh-bootstrap --no-ri --no-rdoc --quiet


# We use fog below, and bosh-bootstrap uses it as well
cat <<EOF > ~/.fog
:default:
  :aws_access_key_id: $AWS_KEY_ID
  :aws_secret_access_key: $AWS_ACCESS_KEY
  :region: $REGION
EOF

# This volume is created using terraform in aws-bosh.tf
if [[ ! -d "$HOME/workspace" ]]; then
  sudo /sbin/mkfs.ext4 /dev/xvdc
  sudo /sbin/e2label /dev/xvdc workspace
  echo 'LABEL=workspace /home/ubuntu/workspace ext4 defaults,discard 0 0' | sudo tee -a /etc/fstab
  mkdir -p /home/ubuntu/workspace
  sudo mount -a
  sudo chown -R ubuntu:ubuntu /home/ubuntu/workspace
fi

# As long as we have a large volume to work with, we'll move /tmp over there
# You can always use a bigger /tmp
if [[ ! -d "$HOME/workspace/tmp" ]]; then
  sudo rsync -avq /tmp/ /home/ubuntu/workspace/tmp/
fi

if ! [[ -L "/tmp" && -d "/tmp" ]]; then
  sudo rm -fR /tmp
  sudo ln -s /home/ubuntu/workspace/tmp /tmp
fi

# bosh-bootstrap handles provisioning the microbosh machine and installing bosh
# on it. This is very nice of bosh-bootstrap. Everyone make sure to thank bosh-bootstrap
mkdir -p {bin,workspace/deployments/microbosh,workspace/tools}
pushd workspace/deployments
pushd microbosh
cat <<EOF > settings.yml
---
bosh:
  name: bosh-${VPC}
provider:
  name: aws
  credentials:
    provider: AWS
    aws_access_key_id: ${AWS_KEY_ID}
    aws_secret_access_key: ${AWS_ACCESS_KEY}
  region: ${REGION}
address:
  vpc_id: ${VPC}
  subnet_id: ${BOSH_SUBNET}
  ip: ${boshDirectorHost}
EOF

if [[ ! -d "$HOME/workspace/deployments/microbosh/deployments" ]]; then
  bosh bootstrap deploy
fi

# We've hardcoded the IP of the microbosh machine, because convenience
bosh -n target https://${boshDirectorHost}:25555
bosh login admin admin

if [[ ! "$?" == 0 ]]; then
  #wipe the ~/workspace/deployments/microbosh folder contents and try again
  echo "Retry deploying the micro bosh..."
fi
popd

if [[ ! -d "$HOME/workspace/deployments/terraform-aws-cf-install" ]]; then
  git clone --branch ${CF_BOSHWORKSPACE_VERSION} https://github.com/appfirst/terraform-aws-cf-install.git 
fi

# There is a specific branch of cf-boshworkspace that we use for terraform. This
# may change in the future if we come up with a better way to handle maintaining
# configs in a git repo
if [[ ! -d "$HOME/workspace/deployments/cf-boshworkspace" ]]; then
  git clone --branch  ${CF_BOSHWORKSPACE_VERSION} http://github.com/appfirst/cf-boshworkspace
fi
pushd cf-boshworkspace

git reset --hard origin/{CF_BOSHWORKSPACE_VERSION}
git pull

mkdir -p ssh
gem install bundler
bundle install

# Pull out the UUID of the director - bosh_cli needs it in the deployment to
# know it's hitting the right microbosh instance
DIRECTOR_UUID=$(bosh status --uuid)

# If CF_DOMAIN is set to XIP, then use XIP.IO. Otherwise, use the variable
if [[ $CF_DOMAIN == "XIP" ]]; then
  CF_DOMAIN="${CF_IP}.xip.io"
fi

if [[ ! -f "/usr/local/bin/spiff" ]]; then
  curl -sOL https://github.com/cloudfoundry-incubator/spiff/releases/download/v1.0.3/spiff_linux_amd64.zip
  unzip spiff_linux_amd64.zip
  sudo mv ./spiff /usr/local/bin/spiff
  rm spiff_linux_amd64.zip
fi

# This is some hackwork to get the configs right. Could be changed in the future
/bin/sed -i \
  -e "s/CF_SUBNET1_AZ/${CF_SUBNET1_AZ}/g" \
  -e "s/CF_SUBNET2_AZ/${CF_SUBNET2_AZ}/g" \
  -e "s/LB_SUBNET1_AZ/${CF_SUBNET1_AZ}/g" \
  -e "s/CF_ELASTIC_IP/${CF_IP}/g" \
  -e "s/CF_SUBNET1/${CF_SUBNET1}/g" \
  -e "s/CF_SUBNET2/${CF_SUBNET2}/g" \
  -e "s/LB_SUBNET1/${LB_SUBNET1}/g" \
  -e "s/DIRECTOR_UUID/${DIRECTOR_UUID}/g" \
  -e "s/CF_DOMAIN/${CF_DOMAIN}/g" \
  -e "s/CF_ADMIN_PASS/${CF_ADMIN_PASS}/g" \
  -e "s/IPMASK/${IPMASK}/g" \
  -e "s/CF_SG/${CF_SG}/g" \
  -e "s/LB_SUBNET1_AZ/${CF_SUBNET1_AZ}/g" \
  deployments/cf-aws-${CF_SIZE}.yml


function parse_yaml () {
   local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
   sed -ne "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
   awk -F$fs '{
      indent = length($1)/2;
      vname[indent] = $2;
      for (i in vname) {if (i > indent) {delete vname[i]}}
      if (length($3) > 0) {
         vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
         printf("%s%s=\"%s\"\n", vn, $2, $3);
      }
   }'
   return 0
}

eval $(parse_yaml deployments/cf-aws-${CF_SIZE}.yml "")
stemcellVersion=$stemcells__version

# See:
# http://bosh_artifacts.cfapps.io/file_collections?type=stemcells
STEMCELL_NAME=bosh-stemcell-$stemcellVersion-aws-xen-ubuntu-trusty-go_agent.tgz
if [[ ! -f $STEMCELL_NAME ]]; then
  STEMCELL_URL="https://s3.amazonaws.com/bosh-jenkins-artifacts/bosh-stemcell/aws/bosh-stemcell-$stemcellVersion-aws-xen-ubuntu-trusty-go_agent.tgz"
  wget -O $STEMCELL_NAME $STEMCELL_URL
fi

COLLECTOR_STEMCELL_NAME=collector_$STEMCELL_NAME
if [[ ! -f $COLLECTOR_STEMCELL_NAME ]]; then
    sudo $HOME/workspace/deployments/terraform-aws-cf-install/scripts/add_collector_stemcell.sh $STEMCELL_NAME $COLLECTOR_STEMCELL_NAME $APPFIRST_TENANT_ID $APPFIRST_FRONTEND_URL $APPFIRST_SERVER_TAGS
fi

uploadedStemcellVersion=$(bosh stemcells | grep collector_ | awk '{print $4}')
uploadedStemcellVersion="${uploadedStemcellVersion//[^[:alnum:]]/}"

if [[ "$uploadedStemcellVersion" != "${stemcellVersion}" ]]; then
  bosh upload stemcell $COLLECTOR_STEMCELL_NAME 
fi

uploadedServicesContribVersion=$(bosh releases | grep cf-services-contrib | awk '{print $4}')
uploadedServicesContribVersion="${uploadedServicesContribVersion//[^[:alnum:]]/}"

if [[ "$uploadedServicesContribVersion" != "6" ]]; then
   bosh upload release https://cf-contrib.s3.amazonaws.com/boshrelease-cf-services-contrib-6.tgz
fi

# Upload the bosh release, set the deployment, and execute
deployedVersion=$(bosh releases | grep " ${cfReleaseVersion}" | awk '{print $4}')
deployedVersion="${deployedVersion//[^[:alnum:]]/}"
if [[ ! "$deployedVersion" == "${cfReleaseVersion}" ]]; then
  bosh upload release https://bosh.io/d/github.com/cloudfoundry/cf-release?v=${cfReleaseVersion}
  bosh deployment cf-aws-${CF_SIZE}
  bosh prepare deployment || bosh prepare deployment  #Seems to always fail on the first run...
else
  bosh deployment cf-aws-${CF_SIZE}
fi

# Work around until bosh-workspace can handle submodules
if [[ "cf-aws-${CF_SIZE}" == "cf-aws-large" ]]; then
  pushd .releases/cf
  ./update
  popd
fi

# We locally commit the changes to the repo, so that errant git checkouts don't
# cause havok
currentGitUser="$(git config user.name || /bin/true )"
currentGitEmail="$(git config user.email || /bin/true )"
if [[ "${currentGitUser}" == "" || "${currentGitEmail}" == "" ]]; then
  git config --global user.email "${USER}@${HOSTNAME}"
  git config --global user.name "${USER}"
  echo "blarg"
fi

gitDiff="$(git diff)"
if [[ ! "${gitDiff}" == "" ]]; then
  git commit -am 'commit of the local deployment configs'
fi

# Keep trying until there is a successful BOSH deploy.
for i in {0..2}
do bosh -n deploy
done

echo "Install Traveling CF"
if [[ "$(cat $HOME/.bashrc | grep 'export PATH=$PATH:$HOME/bin/traveling-cf-admin')" == "" ]]; then
  curl -s https://raw.githubusercontent.com/cloudfoundry-community/traveling-cf-admin/master/scripts/installer | bash
  echo 'export PATH=$PATH:$HOME/bin/traveling-cf-admin' >> $HOME/.bashrc
  source $HOME/.bashrc
fi

# Now deploy docker services if requested
if [[ $INSTALL_DOCKER == "true" ]]; then

  cd ~/workspace/deployments
  if [[ ! -d "$HOME/workspace/deployments/docker-services-boshworkspace" ]]; then
    git clone https://github.com/cloudfoundry-community/docker-services-boshworkspace.git
  fi

  echo "Update the docker-aws-vpc.yml with cf-boshworkspace parameters"
  /home/ubuntu/workspace/deployments/docker-services-boshworkspace/shell/populate-docker-aws-vpc ${CF_SIZE}
  dockerDeploymentManifest="/home/ubuntu/workspace/deployments/docker-services-boshworkspace/deployments/docker-aws-vpc.yml"
  /bin/sed -i "s/SUBNET_ID/${DOCKER_SUBNET}/g" "${dockerDeploymentManifest}"

  cd ~/workspace/deployments/docker-services-boshworkspace
  bundle install
  bosh deployment docker-aws-vpc
  bosh prepare deployment

  # Keep trying until there is a successful BOSH deploy.
  for i in {0..2}
  do bosh -n deploy
  done

fi


DIRECTOR_UUID=`bosh status | grep UUID | awk '{print $2}'`
MANIFEST_FILE="postgresql_srv.yml"
CF_DEPLOY_FILE="$HOME/workspace/deployments/cf-boshworkspace/.deployments/cf-aws-$CF_SIZE.yml"

TMP_YML="tmp.yml"
NATS_CFG="nat_cfg"
echo "properties:" > $TMP_YML
echo "  nats: (( merge ))" >> $TMP_YML

spiff merge $TMP_YML $CF_DEPLOY_FILE > $NATS_CFG
NAT_ADDRESS=`cat $NATS_CFG | grep address | awk '{print $2}'`
NAT_PORT=`cat $NATS_CFG | grep -w port | awk '{print $2}'`
NAT_USER=`cat $NATS_CFG | grep user | awk '{print $2}'`
NAT_PASSWD=`cat $NATS_CFG | grep password | awk '{print $2}'`
TOKEN=`cat $CF_DEPLOY_FILE | grep -w secret: | awk 'NR==1{print $2}'`

rm $NATS_CFG
rm $TMP_YML

echo "---
name: cf-services-contrib
director_uuid: $DIRECTOR_UUID

releases:
  - name: cf-services-contrib
    version: 6

compilation:
  workers: 3
  network: default
  reuse_compilation_vms: true
  cloud_properties:
    instance_type: m3.medium

update:
  canaries: 1
  canary_watch_time: 30000-60000
  update_watch_time: 30000-60000
  max_in_flight: 4

networks:
  - name: floating
    type: vip
    cloud_properties: {}
  - name: default
    type: dynamic
    cloud_properties:
      subnet: $CF_SUBNET1
      security_groups:
        - $CF_SG

resource_pools:
  - name: common
    network: default
    size: 2
    stemcell:
      name: collector_bosh-aws-xen-ubuntu-trusty-go_agent
      version: latest
    cloud_properties:
      instance_type: m3.medium

jobs:
  - name: gateways
    release: cf-services-contrib
    template:
    - postgresql_gateway_ng
    instances: 1
    resource_pool: common
    persistent_disk: 10000
    networks:
      - name: default
        default: [dns, gateway]
    properties:
      uaa_client_id: \"cf\"
      uaa_endpoint: https://uaa.run.$CF_IP.xip.io
      uaa_client_auth_credentials:
        username: admin
        password: $CF_ADMIN_PASS

  - name: postgresql_service_node
    release: cf-services-contrib
    template: postgresql_node_ng
    instances: 1
    resource_pool: common
    persistent_disk: 10000
    properties:
      postgresql_node:
        plan: default
    networks:
      - name: default
        default: [dns, gateway]


properties:
  networks:
    apps: default
    management: default

  cc:
    srv_api_uri: https://$CF_API

  nats:
    address: $NAT_ADDRESS
    port: $NAT_PORT
    user: $NAT_USER
    password: $NAT_PASSWD
    authorization_timeout: 5

  service_plans:
    postgresql:
      default:
        description: \"Developer, 250MB storage, 10 connections\"
        free: true
        job_management:
          high_water: 230
          low_water: 20
        configuration:
          capacity: 125
          max_clients: 10
          quota_files: 4
          quota_data_size: 240
          enable_journaling: true
          backup:
            enable: false
          lifecycle:
            enable: false
            serialization: enable
            snapshot:
              quota: 1


  postgresql_gateway:
    token: $TOKEN
    default_plan: default
    supported_versions: [\"9.3\"]
    version_aliases:
      current: \"9.3\"
    cc_api_version: v2
  postgresql_node:
    supported_versions: [\"9.3\"]
    default_version: \"9.3\"
    max_tmp: 900
    password: $TOKEN
" > $MANIFEST_FILE    

bosh deployment $MANIFEST_FILE
bosh -n deploy

echo "
---
BOSH_URL: $(bosh target | awk '{ print $4; }')
BOSH_USER: admin
BOSH_PASS: admin
AF_USER: $APPFIRST_USER_ID
AF_API_KEY: $APPFIRST_USER_KEY
AF_API_ROOT: https://${APPFIRST_FRONTEND_URL}/api
" > ~/.af_sync.yml

pip3 install --user virtualenv
test -d ~/.sync || ~/.local/bin/virtualenv-3.4 ~/.sync
(
    # load virtualenv enviroment in a subshell
    source  ~/.sync/bin/activate
    pip install -r $HOME/workspace/deployments/terraform-aws-cf-install/scripts/requirements.txt
    $HOME/workspace/deployments/terraform-aws-cf-install/scripts/af_bosh_sync.py
)



cf=/home/ubuntu/bin/traveling-cf-admin/cf

$cf login --skip-ssl-validation -a $CF_API -u admin -p $CF_ADMIN_PASS
$cf create-space me
$cf target -s me


# https://groups.google.com/a/cloudfoundry.org/forum/m/#!topic/bosh-users/b7ALPhxcQ2A
$cf security-groups | awk '{ print $2 }' | grep -q -v database_service && \
    echo "[{\"protocol\":\"all\",\"destination\":\"$(bosh vms | grep postgresql_service_node/0 | cut -d '|' -f 5 | tr -d ' ')\"}]" > database_service_group.txt &&
    $cf create-security-group database_service database_service_group.txt && \
    $cf bind-security-group database_service system me && \
    $cf bind-running-security-group database_service
    $cf bind-staging-security-group database_service

$cf service-auth-tokens | awk '{ print $1 }' | grep -q -v postgresql && \
    $cf create-service-auth-token postgresql core $TOKEN
$cf services | awk '{ print $1 }' | grep -q -v request-logger-db && \
    $cf create-service postgresql default request-logger-db

pushd $HOME/workspace/deployments

if [ ! -d cf-pyapp ]; then 
  git clone https://github.com/appfirst/cf-pyapp.git
fi

cd cf-pyapp/src && git pull
$cf push
popd

$cf bind-service request-logger request-logger-db
$cf restage request-logger

echo "Provision script completed..."
exit 0

# FIXME: enable this again when smoke_tests work
# bosh run errand smoke_tests
