#!/bin/bash

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
    sudo apt-get update -yq
    sudo apt-get install -yq aptitude build-essential vim-nox git unzip tree \
       libxslt-dev libxslt1.1 libxslt1-dev libxml2 libxml2-dev \
      libpq-dev libmysqlclient-dev libsqlite3-dev \
      g++ gcc make libc6-dev libreadline6-dev zlib1g-dev libssl-dev libyaml-dev \
      libsqlite3-dev sqlite3 autoconf libgdbm-dev libncurses5-dev automake \
      libtool bison pkg-config libffi-dev cmake tmux htop iftop iotop tcpdump kpartx
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

# There is a specific branch of cf-boshworkspace that we use for terraform. This
# may change in the future if we come up with a better way to handle maintaining
# configs in a git repo
if [[ ! -d "$HOME/workspace/deployments/cf-boshworkspace" ]]; then
  git clone --branch  ${CF_BOSHWORKSPACE_VERSION} http://github.com/cloudfoundry-community/cf-boshworkspace
fi
pushd cf-boshworkspace
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

function disable {
  if [ -e $1 ]
  then
    sudo mv $1 $1.back
    sudo ln -s /bin/true $1
  fi
}

function enable {
  if [ -L $1 ]
  then
    sudo mv $1.back $1
  else
    # No longer a symbolic link, must have been overwritten
    sudo rm -f $1.back
  fi
}

function run_in_chroot {
  local chroot=$1
  local script=$2

  # Disable daemon startup
  disable $chroot/sbin/initctl
  disable $chroot/usr/sbin/invoke-rc.d

  sudo unshare -m $SHELL <<EOS
    sudo mkdir -p $chroot/dev
    sudo mount -n --bind /dev $chroot/dev
    sudo mount -n --bind /dev/pts $chroot/dev/pts

    sudo mkdir -p $chroot/proc
    sudo mount -n --bind /proc $chroot/proc

    sudo chroot $chroot env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin http_proxy=${http_proxy:-} sudo bash -e -c "$script"
EOS

  # Enable daemon startup
  enable $chroot/sbin/initctl
  enable $chroot/usr/sbin/invoke-rc.d
}

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

uploadedStemcellVersion=$(bosh stemcells | grep " ${stemcellVersion}" | awk '{print $4}')
uploadedStemcellVersion="${uploadedStemcellVersion//[^[:alnum:]]/}"

if [[ "$uploadedStemcellVersion" != "${stemcellVersion}" ]]; then
  STEMCELL_URL="https://d26ekeud912fhb.cloudfront.net/bosh-stemcell/aws/bosh-stemcell-$stemcellVersion-aws-xen-ubuntu-trusty-go_agent.tgz"
  STEMCELL_NAME="stemcell_base.tgz"
  BUILD_DIR="./stemcell"
  wget -O $STEMCELL_NAME $STEMCELL_URL

  rm -rf $BUILD_DIR
  mkdir -p $BUILD_DIR

  echo "Extract stemcell"
  tar xzf $STEMCELL_NAME
  echo "Extract image"
  tar xzf image

  echo "Mount image"
  sudo losetup /dev/loop0 root.img
  sudo kpartx -a /dev/loop0
  sudo mount /dev/mapper/loop0p1 $BUILD_DIR

  echo "Download AppFirst package"
  downloaded_file="af_package.deb"
  url="https://www.dropbox.com/s/0xsp6jdc1b3wqtz/distrodeb64.deb"
  wget $url -qO $downloaded_file
  sudo cp $downloaded_file $BUILD_DIR/$downloaded_file

  echo "Install AppFirst package"
  run_in_chroot $BUILD_DIR "dpkg -i $downloaded_file"
  run_in_chroot $BUILD_DIR "chown root:root /etc/init.d/afcollector"
  run_in_chroot $BUILD_DIR "/usr/sbin/update-rc.d afcollector defaults 15 85"

  ls -la $BUILD_DIR/etc/init.d/

  rm $downloaded_file
  sudo rm $BUILD_DIR/$downloaded_file

  echo "<configuration>" | sudo tee $BUILD_DIR/etc/AppFirst
  echo "URLfront $APPFIRST_FRONTEND_URL" | sudo tee --append $BUILD_DIR/etc/AppFirst
  echo "Tenant $APPFIRST_TENANT_ID" | sudo tee --append $BUILD_DIR/etc/AppFirst
  echo "</configuration>" | sudo tee --append $BUILD_DIR/etc/AppFirst

  echo "server_tags: [$APPFIRST_SERVER_TAGS]" | sudo tee --append $BUILD_DIR/etc/AppFirst.init
  sudo rm -rf $BUILD_DIR/etc/init/afcollector.conf
  sudo rm -rf $BUILD_DIR/var/log/*collector*

  echo "Unmount image"
  sudo umount $BUILD_DIR
  sudo dmsetup remove /dev/mapper/loop0p1
  sudo losetup -d /dev/loop0

  rm image
  echo "Compress image"
  tar -czf image root.img

  echo "Change SHA1"
  SHA1SUM=`sha1sum image | awk '{print $1}'`
  sudo sed -i "/sha1:/c\sha1: $SHA1SUM" stemcell.MF

  echo "Compress stemcell"
  tar -czf af_stemcell.tgz image stemcell.MF apply_spec.yml

  rm image
  rm root.img
  rm stemcell.MF
  rm apply_spec.yml

  rm -rf $STEMCELL_NAME
  rm -rf $BUILD_DIR

  bosh upload stemcell ./af_stemcell.tgz
  rm -rf ./af_stemcell.tgz
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

echo "Provision script completed..."
exit 0

# FIXME: enable this again when smoke_tests work
# bosh run errand smoke_tests
