#!/bin/sh
#-
# Copyright (c) 2017 Google
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
# NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#-

readonly PROGNAME=$(basename "$0")
readonly ARCH=$(uname -m)
readonly REQTOOLS="xbps-install xbps-reconfigure tar xz"

# This source pulls in all the functions from lib.sh.  This set of
# functions makes it much easier to work with chroots and abstracts
# away all the problems with running binaries with QEMU.
# shellcheck source=./lib.sh
. ./lib.sh

# Die is a function provided in lib.sh which handles the cleanup of
# the mounts and removal of temporary directories if the running
# program exists unexpectedly.
trap 'die "Interrupted! exiting..."' INT TERM HUP

# Even though we only support really one target for most of these
# architectures this lets us refer to these quickly and easily by
# XBPS_ARCH.  This makes it a lot more obvious what is happening later
# in the script, and it makes it easier to consume the contents of
# these down the road in later scripts.
usage() {
    cat <<_EOF
Usage: $PROGNAME [options] <platform> <base-tarball>

Supported platforms: i686, x86_64, GCP, bananapi, beaglebone,
                     cubieboard2, cubietruck, odroid-c2, odroid-u2,
                     rpi-armv6l, rpi-armv7l, rpi-aarch64, ci20,
                     pinebookpro, pinephone, rock64

Options
    -b <syspkg> Set an alternative base-system package (defaults to base-system)
    -p <pkgs>   Additional packages to install into the rootfs (separated by blanks)
    -k <cmd>    Call "cmd <ROOTFSPATH>" after building the rootfs
    -c <dir>    Set XBPS cache directory (defaults to \$PWD/xbps-cachedir-<arch>)
    -C <file>   Full path to the XBPS configuration file
    -r <repo>   Set XBPS repository (may be set multiple times)
    -x <num>    Use <num> threads to compress the image (dynamic if unset)
    -o <file>   Filename to write the PLATFORMFS archive to
    -n          Do not compress the image, instead print out the rootfs directory
    -h          Show this help
    -V          Show version
_EOF
}

# ########################################
#      SCRIPT EXECUTION STARTS HERE
# ########################################

BASEPKG=base-system
COMPRESSION="y"

while getopts "b:p:k:c:C:r:x:o:nhV" opt; do
    case $opt in
        b) BASEPKG="$OPTARG" ;;
        p) EXTRA_PKGS="$OPTARG" ;;
        k) POST_CMD="$OPTARG" ;;
        c) XBPS_CACHEDIR="--cachedir=$OPTARG" ;;
        C) XBPS_CONFFILE="-C $OPTARG" ;;
        r) XBPS_REPOSITORY="--repository=$OPTARG $XBPS_REPOSITORY" ;;
        x) COMPRESSOR_THREADS="$OPTARG" ;;
        o) FILENAME="$OPTARG" ;;
        n) COMPRESSION="n" ;;
        h) usage; exit 0 ;;
        V) echo "$PROGNAME 0.23 c9dbeed"; exit 0 ;;
    esac
done
shift $((OPTIND - 1))
PLATFORM="$1"
BASE_TARBALL="$2"

# This is an aweful hack since the script isn't using privesc
# mechanisms selectively.  This is a TODO item.
if [ "$(id -u)" -ne 0 ]; then
    die "need root perms to continue, exiting."
fi

# Before going any further, check that the tools that are needed are
# present.  If we delayed this we could check for the QEMU binary, but
# its a reasonable tradeoff to just bail out now.
check_tools

# Most platforms have a base system package that includes specific
# packages for bringing up the hardware.  In the case of the cloud
# platforms the base package includes the components needed to inject
# SSH keys and user accounts.  The base platform packages are always
# noarch though, so we strip off the -musl extention if it was
# provided.
case "$PLATFORM" in
    bananapi*) PKGS="$BASEPKG ${PLATFORM%-*}-base" ;;
    beaglebone*) PKGS="$BASEPKG ${PLATFORM%-*}-base" ;;
    cubieboard2*|cubietruck*) PKGS="$BASEPKG ${PLATFORM%-*}-base" ;;
    odroid-u2*) PKGS="$BASEPKG ${PLATFORM%-*}-base" ;;
    odroid-c2*) PKGS="$BASEPKG ${PLATFORM%-musl}-base" ;;
    rpi*) PKGS="$BASEPKG rpi-base" ;;
    ci20*) PKGS="$BASEPKG ${PLATFORM%-*}-base" ;;
    i686*) PKGS="$BASEPKG" ;;
    x86_64*) PKGS="$BASEPKG" ;;
    GCP*) PKGS="$BASEPKG ${PLATFORM%-*}-base" ;;
    pinebookpro*) PKGS="$BASEPKG ${PLATFORM%-*}-base" ;;
    pinephone*) PKGS="$BASEPKG ${PLATFORM%-*}-base" ;;
    rock64*) PKGS="$BASEPKG ${PLATFORM%-*}-base" ;;
    *) die "$PROGNAME: invalid platform!";;
esac

# Derive the target architecture using the static map
set_target_arch_from_platform

# And likewise set the cache
set_cachedir

# Append any additional packages if they were requested
if [ -n "$EXTRA_PKGS" ] ; then
    PKGS="$PKGS $EXTRA_PKGS"
fi

# We need to operate on a tempdir, if this fails to create, it is
# absolutely crucial to bail out so that we don't hose the system that
# is running the script.
ROOTFS=$(mktemp -d) || die "failed to create tempdir, exiting..."

# Now that we have a directory for the ROOTFS, we can expand the
# existing base filesystem into the directory
if [ ! -e "$BASE_TARBALL" ]; then
    die "no valid base tarball given, exiting."
fi

info_msg "Expanding base tarball $BASE_TARBALL into $ROOTFS for $PLATFORM build."
tar xf "$BASE_TARBALL" -C "$ROOTFS"

# This will install, but not configure, the packages specified by
# $PKGS.  After this step we will do an xbps-reconfigure -f $PKGS
# under the correct architecture to ensure the system is setup
# correctly.
run_cmd_target "xbps-install -SU $XBPS_CONFFILE $XBPS_CACHEDIR $XBPS_REPOSITORY -r $ROOTFS -y $PKGS"

# Now that the packages are installed, we need to chroot in and
# reconfigure.  This needs to be done as the right architecture.
# Since this is the only thing we're doing in the chroot, we clean up
# right after.
run_cmd_chroot "$ROOTFS" "xbps-reconfigure -a"

# Before final cleanup the ROOTFS needs to be checked to make sure it
# contains an initrd and if its a platform with arch 'arm*' it needs
# to also have a uInitrd.  For this to work the system needs to have
# the uboot-mkimage package installed.  Base system packages that do
# not provide this must provide the uInitrd pre-prepared if they are
# arm based.  x86 images will have this built using native dracut
# using post unpacking steps for platforms that consume the x86
# tarballs.  This check is very specific and ensures that applicable
# tooling is present before proceeding.
if [ ! -f "$ROOTFS/boot/uInitrd" ] ||
       [ ! -f "$ROOTFS/boot/initrd" ] &&
           [ -z "${XBPS_TARGET_ARCH##*arm*}" ] &&
           [ -x "$ROOTFS/usr/bin/dracut" ] &&
           [ -x "$ROOTFS/usr/bin/mkimage" ]; then

    # Dracut needs to know the kernel version that will be using this
    # initrd so that it can install the kernel drivers in it.  Normally
    # this check is quite complex, but since this is a clean rootfs and we
    # just installed exactly one kernel, this check can get by with a
    # really niave command to figure out the kernel version
    KERNELVERSION=$(ls "$ROOTFS/usr/lib/modules/")

    # Some platforms also have special arguments that need to be set
    # for dracut.  This allows us to kludge around issues that may
    # exist on certain specific platforms we build for.
    set_dracut_args_from_platform

    # Now that things are setup, we can call dracut and build the initrd.
    # This will pretty much step through the normal process to build
    # initrd with the exception that the autoinstaller and netmenu are
    # force added since no module depends on them.
    info_msg "Building initrd for kernel version $KERNELVERSION"
    run_cmd_chroot "$ROOTFS" "env -i /usr/bin/dracut $dracut_args /boot/initrd $KERNELVERSION"
    [ $? -ne 0 ] && die "Failed to generate the initramfs"

    run_cmd_chroot "$ROOTFS" "env -i /usr/bin/mkimage -A arm -O linux -T ramdisk -C gzip -a 0 -e 0 -n 'Void Linux' -d /boot/initrd /boot/uInitrd"
fi

cleanup_chroot

# The cache isn't that useful since by the time the ROOTFS will be
# used it is likely to be out of date.  Rather than shipping it around
# only for it to be out of date, we remove it now.
rm -rf "$ROOTFS/var/cache/*" 2>/dev/null

# Now we can run the POST_CMD script. This user-supplied script gets the
# $ROOTFS as a parameter.
if [ -n "$POST_CMD" ]; then
    info_msg "Running user supplied command: $POST_CMD"
    run_cmd $POST_CMD $ROOTFS
fi


# Compress the tarball or just print out the path?
if [ "$COMPRESSION" = "y" ]; then
    # Finally we can compress the tarball, the name will include the
    # platform and the date on which the tarball was built.
    tarball=${FILENAME:-void-${PLATFORM}-PLATFORMFS-$(date '+%Y%m%d').tar.xz}
    run_cmd "tar -cp --posix --xattrs -C $ROOTFS . | xz -T${COMPRESSOR_THREADS:-0} -9 > $tarball "
    [ $? -ne 0 ] && die "Failed to compress tarball"

    # Now that we have the tarball we don't need the rootfs anymore, so we
    # can get rid of it.
    rm -rf "$ROOTFS"

    # Last thing to do before closing out is to let the user know that
    # this succeeded.  This also ensures that there's something visible
    # that the user can look for at the end of the script, which can make
    # it easier to see what's going on if something above failed.
    info_msg "Successfully created $tarball ($PLATFORM)"
else
    # User requested just printing out the path to the rootfs, here it comes.
    info_msg "Successfully created rootfs under $ROOTFS"
fi
