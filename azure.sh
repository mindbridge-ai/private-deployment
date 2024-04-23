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
    local optional=$4

    if mountpoint -q "$mountpoint"
    then
        logSuccess "$mountpoint already mounted"
    else
        logStep "Preparing logical volume $logical_volume"
        prep_logical_volume "$volume_group" "$logical_volume" $optional
	if [ -e "/dev/$volume_group/$logical_volume" ]
        then
            logStep "Attempting to mount $mountpoint"
	    do_mount "$volume_group" "$logical_volume" "$mountpoint"
        else
            if [ "$optional" != true ]; then
                fatal "Could not find logical volume $logical_volume to create mountpoint $mountpoint"
            else
                logSuccess "Skipping creating mountpoint ${mountpoint}"
            fi
        fi
    fi
}

prep_logical_volume() {
    local volume_group=$1
    local logical_volume=$2
    local optional=$3
    local volume_group_exists=false

    if vgs | grep -q ${volume_group}; then
        volume_group_exists=true
    fi
    if [ "$volume_group_exists" = false ]
    then
        if [ "$optional" != true ]; then
            logStep "Creating volume group $volume_group"
	    prep_volume_group "$volume_group" $optional

            logSubstep "Creating logical volume ${logical_volume}"
            lvcreate --extents +100%FREE "$volume_group" --name "$logical_volume" --activate y

            logSubstep "Creating XFS filesystem on ${logical_volume}"
            mkfs.xfs "$(lv_device "$volume_group" "$logical_volume")"
            logSuccess "Logical volume ${logical_volume} created"
        else
            logSuccess "Skipping creating logical volume ${volume_group}"
        fi
    else
        logSuccess "Volume group ${volume_group} already exists"
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
    local optional=$2
    local disk_dev
    if ! disk_dev=$(find_first_unused_data_disk)
    then
        if [ "$optional" != true ]; then
            fatal "Could not find an unused Azure data disk for $volume_group"
        else
            logSuccess "Skipping creating volume group. ${volume_group} is optional and no disk available."
        fi
    else
        logSubstep "Creating volume group $volume_group using $disk_dev"
        pvcreate "$disk_dev"
        vgcreate "$volume_group" "$disk_dev"
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
            logSubstep "No wildcard match for $disk"
	    continue
        fi

        if ls "${disk}-part"* &>/dev/null
        then
            # Disk has a partition table, so the system owner probably has
            # plans for it
	    logSubstep "Disk $disk has a partition table"
            continue
        fi

        if ! is_disk_available "$disk"
        then
	    logSubstep "Disk $disk is not available"
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
	logSubstep "Disk $disk already used by lvm"
        return 1
    fi

    # Directly mounted
    if grep -q "$disk" /proc/mounts
    then
	logSubstep "Disk $disk already directly mounted"
        return 1
    fi

    # Used as swap
    if grep -q "$disk" /proc/swaps
    then
	logSubstep "Disk $disk already used as a swap"
        return 1
    fi

    # Used as part of a dm-mapper RAID group
    if grep -q "$disk" /proc/mdstat
    then
        logSubstep "Disk $disk already used in RAID group"
        return 1
    fi

    # It could be directly opened by an application or user. This is super
    # unlikely for a fresh VM, so we'll ignore it.

    return 0
}

[ "$(id -u)" -eq 0 ] || fatal 'Use "sudo bash" to run this script as root'

prep_filesystem vg_data lv_data /data false
prep_filesystem vg_backup lv_backup /backup true

# Create backup directories with correct permissions for the mongo/postgres user
mkdir -p /backup/mongo /backup/postgres
chown -R 999:999 /backup/*

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

if [ -e /var/lib/kubelet ]
then
    if [ -L /var/lib/kubelet ]
    then
        logSuccess "/var/lib/kubelet is already a symlink"
    else
        logWarn "/var/lib/kubelet already exists - cannot link to data volume"
    fi
else
    mkdir -p /data/kubelet
    ln -s /data/docker /var/lib/kubelet
    # Match /var/lib/docker perms
    chmod 711 /data/kubelet
    logSuccess "Linked /var/lib/kubelet to data volume"
fi

if [ -e /var/lib/containerd ]
then
    if [ -L /var/lib/containerd ]
    then
        logSuccess "/var/lib/containerd is already a symlink"
    else
        logWarn "/var/lib/containerd already exists - cannot link to data volume"
    fi
else
    mkdir -p /data/containerd
    ln -s /data/containerd /var/lib/containerd
    # Match /var/lib/docker perms
    chmod 711 /data/containerd
    logSuccess "Linked /var/lib/containerd to data volume"
fi

# For local blob storage
mkdir -p /var/lib/docker/blob-driver
chown -R 9999:9999 /var/lib/docker/blob-driver

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
