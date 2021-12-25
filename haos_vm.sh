#!/usr/bin/env bash

while true; do
    read -p "This will create a New Home Assistant OS VM. Proceed(y/n)?" yn
    case $yn in
        [Yy]* ) break;;
        [Nn]* ) exit;;
        * ) echo "Please answer yes or no.";;
    esac
done
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
CHECKMARK='\033[0;32m\xE2\x9C\x94\033[0m'
trap die ERR
trap cleanup EXIT
function error_exit() {
  trap - ERR
  local DEFAULT='Unknown failure occured.'
  local REASON="\e[97m${1:-$DEFAULT}\e[39m"
  local FLAG="\e[91m[ERROR] \e[93m$EXIT@$LINE"
  msg "$FLAG $REASON"
  [ ! -z ${VMID-} ] && cleanup_vmid
  exit $EXIT
}
function warn() {
  local REASON="\e[97m$1\e[39m"
  local FLAG="\e[93m[WARNING]\e[39m"
  msg "$FLAG $REASON"
}
function info() {
  local REASON="$1"
  local FLAG="\e[36m[INFO]\e[39m"
  msg "$FLAG $REASON"
}
function msg() {
  local TEXT="$1"
  echo -e "$TEXT"
}
function cleanup_vmid() {
  if $(qm status $VMID &>/dev/null); then
    if [ "$(qm status $VMID | awk '{print $2}')" == "running" ]; then
      qm stop $VMID
    fi
    qm destroy $VMID
  fi
}
function cleanup() {
  popd >/dev/null
  rm -rf $TEMP_DIR
}
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null
while read -r line; do
  TAG=$(echo $line | awk '{print $1}')
  TYPE=$(echo $line | awk '{printf "%-10s", $2}')
  FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Type: $TYPE Free: $FREE "
  OFFSET=2
  if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
  fi
  STORAGE_MENU+=( "$TAG" "$ITEM" "OFF" )
done < <(pvesm status -content images | awk 'NR>1')
if [ $((${#STORAGE_MENU[@]}/3)) -eq 0 ]; then
  warn "'Disk image' needs to be selected for at least one storage location."
  die "Unable to detect valid storage location."
elif [ $((${#STORAGE_MENU[@]}/3)) -eq 1 ]; then
  STORAGE=${STORAGE_MENU[0]}
else
  while [ -z "${STORAGE:+x}" ]; do
    STORAGE=$(whiptail --title "Storage Pools" --radiolist \
    "Which storage pool you would like to use for the container?\n\n" \
    16 $(($MSG_MAX_LENGTH + 23)) 6 \
    "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit
  done
fi
info "Using '$STORAGE' for storage location."
VMID=$(pvesh get /cluster/nextid)
info "Container ID is $VMID."
echo -e "\e[1;33m Getting URL for latest Home Assistant disk image... \e[0m"
RELEASE_TYPE=qcow2
URL=$(cat<<EOF | python3
import requests
url = "https://api.github.com/repos/home-assistant/operating-system/releases"
r = requests.get(url).json()
if "message" in r:
    exit()
for release in r:
    if release["prerelease"]:
        continue
    for asset in release["assets"]:
        if asset["name"].find("$RELEASE_TYPE") != -1:
            image_url = asset["browser_download_url"]
            print(image_url)
            exit()
EOF
)
if [ -z "$URL" ]; then
  die "Github has returned an error. A rate limit may have been applied to your connection."
fi
echo -e "${CHECKMARK} \e[1;92m Downloading disk image... \e[0m"
wget -q --show-progress $URL
echo -en "\e[1A\e[0K"
FILE=$(basename $URL)
if [[ $FILE == *.zip ]]; then
  echo -e "${CHECKMARK} \e[1;92m Checking for unzip command... \e[0m"
  if ! command -v unzip &> /dev/null; then
    echo -e "${CHECKMARK} \e[1;92m Installing Unzip... \e[0m"
    apt-get update >/dev/null
    apt-get -qqy install unzip &>/dev/null
  fi
fi
echo -e "${CHECKMARK} \e[1;92m Extracting disk image... \e[0m"
case $FILE in
  *"gz") gunzip -f $FILE;;
  *"zip") unzip -o $FILE;;
  *"xz") xz -d $FILE;;
  *) die "Unable to handle file extension '${FILE##*.}'.";;
esac
STORAGE_TYPE=$(pvesm status -storage $STORAGE | awk 'NR>1 {print $2}')
case $STORAGE_TYPE in
  nfs|dir)
        DISK_EXT=".qcow2"
        DISK_REF="$VMID/"
        IMPORT_OPT="-format qcow2"
esac
for i in {0,1}; do
  disk="DISK$i"
  eval DISK${i}=vm-${VMID}-disk-${i}${DISK_EXT:-}
  eval DISK${i}_REF=${STORAGE}:${DISK_REF:-}${!disk}
done
echo -e "${CHECKMARK} \e[1;92m Creating VM... \e[0m"
VM_NAME=$(sed -e "s/\_//g" -e "s/.${RELEASE_TYPE}.*$//" <<< $FILE)
qm create $VMID -agent 1 -bios ovmf -cores 2 -memory 4096 -name $VM_NAME -net0 virtio,bridge=vmbr0 \
  -onboot 1 -ostype l26 -scsihw virtio-scsi-pci
pvesm alloc $STORAGE $VMID $DISK0 128 1>&/dev/null
qm importdisk $VMID ${FILE%.*} $STORAGE ${IMPORT_OPT:-} 1>&/dev/null
qm set $VMID \
  -efidisk0 ${DISK0_REF},size=128K \
  -sata0 ${DISK1_REF},size=2G > /dev/null
qm set $VMID \
  -boot order=sata0 > /dev/null
set +o errtrace
(
  echo -e "${CHECKMARK} \e[1;92m Adding serial port and configuring console... \e[0m"
  trap '
    warn "Unable to configure serial port. VM is still functional."
    if [ "$(qm config $VMID | sed -n ''/serial0/p'')" != "" ]; then
      qm set $VMID --delete serial0 >/dev/null
    fi
    exit
  ' ERR
  if [ "$(command -v kpartx)" = "" ]; then
    echo -e "${CHECKMARK} \e[1;92m Installing kpartx... \e[0m"
    apt-get update >/dev/null
    apt-get -qqy install kpartx &>/dev/null
  fi
  DISK1_PATH="$(pvesm path $DISK1_REF)"
  DISK1_PART1="$(kpartx -al $DISK1_PATH | awk 'NR==1 {print $1}')"
  DISK1_PART1_PATH="/dev/mapper/$DISK1_PART1"
  TEMP_MOUNT="${TEMP_DIR}/mnt"
  trap '
    findmnt $TEMP_MOUNT >/dev/null && umount $TEMP_MOUNT
    command -v kpartx >/dev/null && kpartx -d $DISK1_PATH
  ' EXIT
  kpartx -a $DISK1_PATH
  mkdir $TEMP_MOUNT
  mount $DISK1_PART1_PATH $TEMP_MOUNT
  sed -i 's/$/ console=ttyS0/' ${TEMP_MOUNT}/cmdline.txt
  qm set $VMID -serial0 socket >/dev/null
)

info "Completed Successfully! New VM ID is \e[1m$VMID\e[0m."
