#!/usr/bin/env bash
CHECKMARK='\033[0;32m\xE2\x9C\x94\033[0m'
RD=`echo "\033[01;31m"`
BL=`echo "\033[36m"`
CM='\xE2\x9C\x94\033'
GN=`echo "\033[1;92m"`
CL=`echo "\033[m"`
while true; do
    read -p "This will create a New Vaultwarden LXC Container. Proceed(y/n)?" yn
    case $yn in
        [Yy]* ) break;;
        [Nn]* ) exit;;
        * ) echo "Please answer yes or no.";;
    esac
done
clear
function header_info {
echo -e "${BL}
 __      __         _ _                         _            
 \ \    / /        | | |                       | |           
  \ \  / /_ _ _   _| | |___      ____ _ _ __ __| | ___ _ __  
   \ \/ / _  | | | | | __\ \ /\ / / _  |  __/ _  |/ _ \  _ \ 
    \  / (_| | |_| | | |_ \ V  V / (_| | | | (_| |  __/ | | |
     \/ \__,_|\__,_|_|\__| \_/\_/ \__,_|_|  \__,_|\___|_| |_|
                                                                                                                        
${CL}"
}

header_info
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR
trap cleanup EXIT

function error_exit() {
  trap - ERR
  local DEFAULT='Unknown failure occured.'
  local REASON="\e[97m${1:-$DEFAULT}\e[39m"
  local FLAG="\e[91m[ERROR] \e[93m$EXIT@$LINE"
  msg "$FLAG $REASON"
  [ ! -z ${CTID-} ] && cleanup_ctid
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
function cleanup_ctid() {
  if [ ! -z ${MOUNT+x} ]; then
    pct unmount $CTID
  fi
  if $(pct status $CTID &>/dev/null); then
    if [ "$(pct status $CTID | awk '{print $2}')" == "running" ]; then
      pct stop $CTID
    fi
    pct destroy $CTID
  elif [ "$(pvesm list $STORAGE --vmid $CTID)" != "" ]; then
    pvesm free $ROOTFS
  fi
}
function cleanup() {
  popd >/dev/null
  rm -rf $TEMP_DIR
}
function load_module() {
  if ! $(lsmod | grep -Fq $1); then
    modprobe $1 &>/dev/null || \
      die "Failed to load '$1' module."
  fi
  MODULES_PATH=/etc/modules
  if ! $(grep -Fxq "$1" $MODULES_PATH); then
    echo "$1" >> $MODULES_PATH || \
      die "Failed to add '$1' module to load at boot."
  fi
}
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

wget -qL https://raw.githubusercontent.com/primitiv0/Proxmox/main/setup/vault_setup.sh

load_module overlay
echo -e "${RD} Expect 30+ minute install time. ${CL} \n"
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
done < <(pvesm status -content rootdir | awk 'NR>1')
if [ $((${#STORAGE_MENU[@]}/3)) -eq 0 ]; then
  warn "'Container' needs to be selected for at least one storage location."
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

CTID=$(pvesh get /cluster/nextid)
info "Container ID is $CTID."

echo -e "${CHECKMARK} \e[1;92m Updating LXC Template List... \e[0m"
pveam update >/dev/null

echo -e "${CHECKMARK} \e[1;92m Downloading LXC Template... \e[0m"
OSTYPE=debian
OSVERSION=${OSTYPE}-11
mapfile -t TEMPLATES < <(pveam available -section system | sed -n "s/.*\($OSVERSION.*\)/\1/p" | sort -t - -k 2 -V)
TEMPLATE="${TEMPLATES[-1]}"
pveam download local $TEMPLATE >/dev/null ||
  die "A problem occured while downloading the LXC template."

STORAGE_TYPE=$(pvesm status -storage $STORAGE | awk 'NR>1 {print $2}')
case $STORAGE_TYPE in
  dir|nfs)
    DISK_EXT=".raw"
    DISK_REF="$CTID/"
    ;;
  zfspool)
    DISK_PREFIX="subvol"
    DISK_FORMAT="subvol"
    ;;
esac
DISK=${DISK_PREFIX:-vm}-${CTID}-disk-0${DISK_EXT-}
ROOTFS=${STORAGE}:${DISK_REF-}${DISK}

echo -e "${CHECKMARK} \e[1;92m Creating LXC Container... \e[0m"
DISK_SIZE=8G
pvesm alloc $STORAGE $CTID $DISK $DISK_SIZE --format ${DISK_FORMAT:-raw} >/dev/null
if [ "$STORAGE_TYPE" == "zfspool" ]; then
  warn "Some containers may not work properly due to ZFS not supporting 'fallocate'."
else
  mkfs.ext4 $(pvesm path $ROOTFS) &>/dev/null
fi
ARCH=$(dpkg --print-architecture)
HOSTNAME=vaultwarden
TEMPLATE_STRING="local:vztmpl/${TEMPLATE}"
pct create $CTID $TEMPLATE_STRING -arch $ARCH -features nesting=1 \
  -hostname $HOSTNAME -net0 name=eth0,bridge=vmbr0,ip=dhcp -onboot 1 -cores 4 -memory 4096\
  -ostype $OSTYPE -rootfs $ROOTFS,size=$DISK_SIZE -storage $STORAGE >/dev/null

MOUNT=$(pct mount $CTID | cut -d"'" -f 2)
ln -fs $(readlink /etc/localtime) ${MOUNT}/etc/localtime
pct unmount $CTID && unset MOUNT

echo -e "${CHECKMARK} \e[1;92m Starting LXC Container... \e[0m"
pct start $CTID
pct push $CTID vault_setup.sh /vault_setup.sh -perms 755
pct exec $CTID /vault_setup.sh

IP=$(pct exec $CTID ip a s dev eth0 | sed -n '/inet / s/\// /p' | awk '{print $2}')
info "Successfully created a Vaultwarden LXC Container to $CTID"
echo -e "\e[1;92m Vaultwarden should be reachable by going to the following URL.
                  http://${IP}:8000
\e[0m"