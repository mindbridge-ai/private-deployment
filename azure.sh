#!/bin/bash
#
# Copyright MindBridge Analytics Inc. All rights reserved.
#
# This material is confidential and may not be copied, distributed,
# reverse engineered, decompiled or otherwise disseminated without
# the prior written consent of MindBridge Analytics Inc.
#
# curl -sSL https://github.com/mindbridge-ai/private-deployment/raw/main/azure.sh | sudo bash

# Bash strict mode
set -euo pipefail
IFS=$'\n\t'

fatal() {
    logFail "$@"
    exit 1
}

# Coloured output routines from the kurl.io setup script.
GREEN='\033[0;32m'
BLUE='\033[0;94m'
LIGHT_BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

logSuccess() {
    printf "${GREEN}✔ $1${NC}\n" 1>&2
}

logStep() {
    printf "${BLUE}⚙  $1${NC}\n" 1>&2
}

logSubstep() {
    printf "\t${LIGHT_BLUE}- $1${NC}\n" 1>&2
}

logFail() {
    printf "${RED}$1${NC}\n" 1>&2
}

logWarn() {
    printf "${YELLOW}$1${NC}\n" 1>&2
}

# Mounts a filesystem, creating a logical volume for it first.
prep_filesystem() {
    local volume_group=$1
    local logical_volume=$2
    local mountpoint=$3

    if mountpoint -q "$mountpoint"
    then
        logSuccess "$mountpoint already mounted"
    else
        logStep "Preparing $mountpoint"
        prep_logical_volume "$volume_group" "$logical_volume"
        do_mount "$volume_group" "$logical_volume" "$mountpoint"
    fi
}

prep_logical_volume() {
    local volume_group=$1
    local logical_volume=$2

    if lvdisplay "${volume_group}/${logical_volume}" &>/dev/null
    then
        logSuccess "Logical volume ${logical_volume} already exists"
    else
        prep_volume_group "$volume_group"

        logSubstep "Creating logical volume ${logical_volume}"
        lvcreate --extents +100%FREE "$volume_group" --name "$logical_volume" \
            --activate y

        logSubstep "Creating XFS filesystem on ${logical_volume}"
        mkfs.xfs "$(lv_device "$volume_group" "$logical_volume")"
        logSuccess "Logical volume ${logical_volume} created"
    fi
}

lv_device() {
    local volume_group=$1
    local logical_volume=$2

    echo "/dev/mapper/${volume_group}-${logical_volume}"
}

do_mount() {
    local volume_group=$1
    local logical_volume=$2
    local mountpoint=$3

    mkdir -p "$mountpoint"
    prep_fstab "$volume_group" "$logical_volume" "$mountpoint"
    logSubstep "Mounting $mountpoint"
    mount "$mountpoint"
    logSuccess "Mounted $mountpoint"
}

prep_fstab() {
    local volume_group=$1
    local logical_volume=$2
    local mountpoint=$3

    device=$(lv_device "$volume_group" "$logical_volume")
    if grep -q "[[:space:]]${mountpoint}[[:space:]]" /etc/fstab
    then
        logSuccess "$mountpoint already exists in /etc/fstab"
    else
        logSubstep "Creating /etc/fstab entry for $mountpoint"
        echo "${device} ${mountpoint} xfs defaults,noatime 0 0" >> /etc/fstab
    fi
}

prep_volume_group() {
    local volume_group=$1

    if vgdisplay "$volume_group" &>/dev/null
    then
        logSuccess "Volume group ${volume_group} already exists."
    else
        local disk_dev
        if ! disk_dev=$(find_first_unused_data_disk)
        then
            fatal "Could not find an unused Azure data disk for $volume_group"
        else
            logSubstep "Creating volume group $volume_group using $disk_dev"
            pvcreate "$disk_dev"
            vgcreate "$volume_group" "$disk_dev"
        fi
    fi
}

find_first_unused_data_disk() {
    # From /etc/udev/rules.d/66-azure-storage.rules:
    # Data disks will appear in /dev/disk/azure/scsi[0-3]/lun[0-9][0-9] (0-63)
    # We don't want anything with partitions ("-part*")
    # Note that lun10 will sort before lun2.
    local disk
    for disk in /dev/disk/azure/scsi*/lun[0-9] /dev/disk/azure/scsi*/lun[1-9][0-9]
    do
        # No wildcard match
        if [ ! -e "$disk" ]
        then
            continue
        fi

        if ls "${disk}-part"* &>/dev/null
        then
            # Disk has a partition table, so the system owner probably has
            # plans for it
            continue
        fi

        if ! is_disk_available "$disk"
        then
            continue
        fi

        echo "$disk"
        return 0
    done
    return 1
}

is_disk_available() {
    local disk=$1

    # There are many ways a disk can be used, some examples here:
    # https://unix.stackexchange.com/a/111791

    # Already used by LVM
    if pvdisplay "$disk" &>/dev/null
    then
        return 1
    fi

    # Directly mounted
    if grep -q "$disk" /proc/mounts
    then
        return 1
    fi

    # Used as swap
    if grep -q "$disk" /proc/swaps
    then
        return 1
    fi

    # Used as part of a dm-mapper RAID group
    if grep -q "$disk" /proc/mdstat
    then
        return 1
    fi

    # It could be directly opened by an application or user. This is super
    # unlikely for a fresh VM, so we'll ignore it.

    return 0
}

[ "$(id -u)" -eq 0 ] || fatal 'Use "sudo bash" to run this script as root'

prep_filesystem vg_data lv_data /data
prep_filesystem vg_backup lv_backup /backup

mkdir -p /backup/mongo /backup/postgres

# Create /opt/replicated/rook as a symlink to /data/rook to keep Replicated's
# internal volumes on the larger data filesystem.
if [ -e /opt/replicated/rook ]
then
    if [ -L /opt/replicated/rook ]
    then
        logSuccess "/opt/replicated/rook is already a symlink"
    else
        logWarn "/opt/replicated/rook already exists - cannot link to data volume"
    fi
else
    mkdir -p /data/rook
    mkdir -p /opt/replicated
    ln -s /data/rook /opt/replicated/rook
    logSuccess "Linked /opt/replicated/rook to data volume"
fi

# We don't use openebs yet, but may in the future
if [ -e /var/openebs/local ]
then
    if [ -L /var/openebs/local ]
    then
        logSuccess "/var/openebs/local is already a symlink"
    else
        logWarn "/var/openebs/local already exists - cannot link to data volume"
    fi
else
    mkdir -p /data/openebs-local
    mkdir -p /var/openebs
    ln -s /data/openebs-local /var/openebs/local
    logSuccess "Linked /var/openebs/local to data volume"
fi

if [ -e /var/lib/docker ]
then
    if [ -L /var/lib/docker ]
    then
        logSuccess "/var/lib/docker is already a symlink"
    else
        logWarn "/var/lib/docker already exists - cannot link to data volume"
    fi
else
    mkdir -p /data/docker
    ln -s /data/docker /var/lib/docker
    # Match /var/lib/docker perms
    chmod 711 /data/docker
    logSuccess "Linked /var/lib/docker to data volume"
fi

echo
read -p "Proceed with Kubernetes installation? [y/N] " PROCEED < /dev/tty
case "$PROCEED" in
y|Y*) ;;
*) exit 0 ;;
esac

logStep "Fetching Replicated (kURL/KOTS) installer."
curl -sSL https://k8s.kurl.sh/ai-auditor > /root/kurl.sh
logSuccess "Downloaded installer."

exec bash /root/kurl.sh
