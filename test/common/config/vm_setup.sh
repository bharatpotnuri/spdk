#! /usr/bin/env bash

# Virtual Machine environment requirements:
# 8 GiB of RAM (for DPDK)
# enable intel_kvm on your host machine

# The purpose of this script is to provide a simple procedure for spinning up a new
# virtual test environment capable of running our whole test suite. This script, when
# applied to a fresh install of fedora 26 server will install all of the necessary dependencies
# to run almost the complete test suite. The main exception being VHost. Vhost requires the
# configuration of a second virtual machine. instructions for how to configure
# that vm are included in the file TEST_ENV_SETUP_README inside this repository

# it is important to enable nesting for vms in kernel command line of your machine for the vhost tests.
#     in /etc/default/grub
#     append the following to the GRUB_CMDLINE_LINUX line
#     intel_iommu=on kvm-intel.nested=1

# We have made a lot of progress with removing hardcoded paths from the tests,

set -e

VM_SETUP_PATH=$(readlink -f ${BASH_SOURCE%/*})

UPGRADE=false
INSTALL=false
CONF="librxe,iscsi,rocksdb,fio,flamegraph,tsocks,qemu,vpp,libiscsi"
CONF_PATH="${VM_SETUP_PATH}/vm_setup.conf"

function usage()
{
    echo "This script is intended to automate the environment setup for a fedora linux virtual machine."
    echo "Please run this script as your regular user. The script will make calls to sudo as needed."
    echo ""
    echo "./vm_setup.sh"
    echo "  -h --help"
    echo "  -u --upgrade Run dnf upgrade"
    echo "  -i --install-deps Install dnf based dependencies"
    echo "  -t --test-conf List of test configurations to enable (${CONF})"
    echo "  -c --conf-path Path to configuration file"
    exit 0
}

while getopts 'iuht:c:-:' optchar; do
    case "$optchar" in
        -)
        case "$OPTARG" in
            help) usage;;
            upgrade) UPGRADE=true;;
            install-deps) INSTALL=true;;
            test-conf=*) CONF="${OPTARG#*=}";;
            conf-path=*) CONF_PATH="${OPTARG#*=}";;
            *) echo "Invalid argument '$OPTARG'"
            usage;;
        esac
        ;;
    h) usage;;
    u) UPGRADE=true;;
    i) INSTALL=true;;
    t) CONF="$OPTARG";;
    c) CONF_PATH="$OPTARG";;
    *) echo "Invalid argument '$OPTARG'"
    usage;;
    esac
done

if [ ! -f "$CONF_PATH" ]; then
	echo Configuration file does not exist: "$CONF_PATH"
	exit 1
fi

source "$CONF_PATH"

jobs=$(($(nproc)*2))

if $UPGRADE; then
    sudo dnf upgrade -y
fi

if $INSTALL; then
    sudo dnf install -y git
fi

cd ~
mkdir -p spdk_repo

cd spdk_repo
mkdir -p output
if [ -d spdk ]; then
    echo "spdk source already present, not cloning"
else
    git clone "${GIT_REPO_SPDK}"
fi
cd spdk
git config submodule.dpdk.url "${GIT_REPO_DPDK}"
git submodule update --init --recursive

if $INSTALL; then
    sudo ./scripts/pkgdep.sh

    if echo $CONF | grep -q tsocks; then
        sudo dnf install -y tsocks
    fi

    sudo dnf install -y valgrind
    sudo dnf install -y jq
    sudo dnf install -y nvme-cli
    sudo dnf install -y ceph
    sudo dnf install -y gdb
    sudo dnf install -y fio
    sudo dnf install -y librbd-devel
    sudo dnf install -y kernel-devel
    sudo dnf install -y gflags-devel
    sudo dnf install -y libasan
    sudo dnf install -y libubsan
    sudo dnf install -y autoconf
    sudo dnf install -y automake
    sudo dnf install -y libtool
    sudo dnf install -y libmount-devel
    sudo dnf install -y iscsi-initiator-utils
    sudo dnf install -y isns-utils-devel
    sudo dnf install -y pmempool
    sudo dnf install -y perl-open
    sudo dnf install -y glib2-devel
    sudo dnf install -y pixman-devel
    sudo dnf install -y astyle-devel
    sudo dnf install -y elfutils
    sudo dnf install -y elfutils-libelf-devel
    sudo dnf install -y flex
    sudo dnf install -y bison
    sudo dnf install -y targetcli
    sudo dnf install -y perl-Switch
    sudo dnf install -y librdmacm-utils
    sudo dnf install -y libibverbs-utils
    sudo dnf install -y gdisk
    sudo dnf install -y socat
fi

cd ~

if echo $CONF | grep -q librxe; then
    # rxe_cfg is used in the NVMe-oF tests
    # The librxe-dev repository provides a command line tool called rxe_cfg which makes it
    # very easy to use Soft-RoCE. The build pool utilizes this command line tool in the absence
    # of any real RDMA NICs to simulate one for the NVMe-oF tests.
    if hash rxe_cfg 2> /dev/null; then
        echo "rxe_cfg is already installed. skipping"
    else
        if [ -d librxe-dev ]; then
            echo "librxe-dev source already present, not cloning"
        else
            git clone "${GIT_REPO_LIBRXE}"
        fi

        cd librxe-dev
        ./configure --libdir=/usr/lib64/ --prefix=
        make -j${jobs}
        sudo make install
        cd ~
    fi
fi

if echo $CONF | grep -q iscsi; then
    # iscsiadm is used in the iscsi_tgt tests
    # The version of iscsiadm that ships with fedora 26 was broken as of November 3 2017.
    # There is already a bug report out about it, and hopefully it is fixed soon, but in the event that
    # that version is still broken when you do your setup, the below steps will fix the issue.
    CURRENT_VERSION=$(iscsiadm --version)
    OPEN_ISCSI_VER='iscsiadm version 6.2.0.874'
    if [ "$CURRENT_VERSION" == "$OPEN_ISCSI_VER" ]; then
        if [ ! -d open-iscsi-install ]; then
            mkdir -p open-iscsi-install
            cd open-iscsi-install
            sudo dnf download --source iscsi-initiator-utils
            rpm2cpio $(ls) | cpio -idmv
            mkdir -p patches
            mv 00* patches/
            git clone "${GIT_REPO_OPEN_ISCSI}"

            cd open-iscsi

            # the configurations of username and email are needed for applying patches to iscsiadm.
            git config user.name none
            git config user.email none

            git checkout 86e8892
            for patch in `ls ../patches`; do
                git am ../patches/$patch
            done
            sed -i '427s/.*/-1);/' usr/session_info.c
            make -j${jobs}
            sudo make install
            cd ~
        else
            echo "custom open-iscsi install located, not reinstalling"
        fi
    fi
fi

sudo mkdir -p /usr/src

if echo $CONF | grep -q rocksdb; then

    # Rocksdb is installed for use with the blobfs tests.
    if [ ! -d /usr/src/rocksdb ]; then
	git clone "${GIT_REPO_ROCKSDB}"
        git -C ./rocksdb checkout spdk-v5.6.1
        sudo mv rocksdb /usr/src/
    else
        sudo git -C /usr/src/rocksdb checkout spdk-v5.6.1
        echo "rocksdb already in /usr/src. Not checking out again"
    fi
fi

if echo $CONF | grep -q fio; then
    # This version of fio is installed in /usr/src/fio to enable
    # building the spdk fio plugin.
    if [ ! -d /usr/src/fio ]; then
        if [ ! -d fio ]; then
            git clone "${GIT_REPO_FIO}"
            sudo mv fio /usr/src/
        else
            sudo mv fio /usr/src/
        fi
        (
            cd /usr/src/fio &&
            git checkout master &&
            git pull &&
            git checkout fio-3.3 &&
            make -j${jobs} &&
            sudo make install
        )
    else
        echo "fio already in /usr/src/fio. Not installing"
    fi
fi

cd ~

if echo $CONF | grep -q flamegraph; then
    # Flamegraph is used when printing out timing graphs for the tests.
    if [ ! -d /usr/local/FlameGraph ]; then
        git clone "${GIT_REPO_FLAMEGRAPH}"
        mkdir -p /usr/local
        sudo mv FlameGraph /usr/local/FlameGraph
    else
        echo "flamegraph already installed. Skipping"
    fi
fi

if echo $CONF | grep -q qemu; then
    # Qemu is used in the vhost tests.
    SPDK_QEMU_BRANCH=spdk-2.12
    mkdir -p qemu
    cd qemu
    if [ ! -d "$SPDK_QEMU_BRANCH" ]; then
        git clone "${GIT_REPO_QEMU}" -b "$SPDK_QEMU_BRANCH" "$SPDK_QEMU_BRANCH"
    else
        echo "qemu already checked out. Skipping"
    fi

    cd "$SPDK_QEMU_BRANCH"

    declare -a opt_params=("--prefix=/usr/local/qemu/$SPDK_QEMU_BRANCH")

    # Most tsocks proxies rely on a configuration file in /etc/tsocks.conf.
    # If using tsocks, please make sure to complete this config before trying to build qemu.
    if echo $CONF | grep -q tsocks; then
        if hash tsocks 2> /dev/null; then
            opt_params+=(--with-git='tsocks git')
        fi
    fi

    ./configure "${opt_params[@]}" --target-list="x86_64-softmmu" --enable-kvm --enable-linux-aio --enable-numa

    make -j${jobs}
    sudo make install
fi

cd ~

if echo $CONF | grep -q vpp; then
    # Vector packet processing (VPP) is installed for use with iSCSI tests.
    if [ -d vpp ]; then
        echo "vpp already cloned."
        if [ ! -d vpp/build-root ]; then
            echo "build-root has not been done"
            echo "remove the `pwd` and start again"
            exit 1
        fi
    else
        git clone "${GIT_REPO_VPP}"
        cd vpp
        git checkout v18.01.1
        # VPP 18.01.1 does not support OpenSSL 1.1.
        # For compilation, a compatibility package is used temporarily.
        sudo dnf install -y --allowerasing compat-openssl10-devel
        # Installing required dependencies for building VPP
        yes | make install-dep

        make pkg-rpm -j${jobs}
        # Reinstall latest OpenSSL devel package.
        sudo dnf install -y --allowerasing openssl-devel
        cd build-root
        sudo dnf install -y \
            ./vpp-lib-18.01.1-release.x86_64.rpm \
            ./vpp-devel-18.01.1-release.x86_64.rpm \
            ./vpp-18.01.1-release.x86_64.rpm
        # Since hugepage configuration is done via spdk/scripts/setup.sh,
        # this default config is not needed.
        #
        # NOTE: Parameters kernel.shmmax and vm.max_map_count are set to
        # very low count and cause issues with hugepage total sizes above 1GB.
        sudo rm -f /etc/sysctl.d/80-vpp.conf
        cd ~
    fi
fi

if echo $CONF | grep -q libiscsi; then
    # We currently don't make any changes to the libiscsi repository for our tests, but it is possible that we will need
    # to later. Cloning from git is just future proofing the machines.
    if [ ! -d libiscsi ]; then
        git clone "${GIT_REPO_LIBISCSI}"
    else
        echo "libiscsi already checked out. Skipping"
    fi
    cd libiscsi
    ./autogen.sh
    ./configure --prefix=/usr/local/libiscsi
    make -j${jobs}
    sudo make install
fi

# create autorun-spdk.conf in home folder. This is sourced by the autotest_common.sh file.
# By setting any one of the values below to 0, you can skip that specific test. If you are
# using your autotest platform to do sanity checks before uploading to the build pool, it is
# probably best to only run the tests that you believe your changes have modified along with
# Scanbuild and check format. This is because running the whole suite of tests in series can
# take ~40 minutes to complete.
if [ ! -e ~/autorun-spdk.conf ]; then
	cat > ~/autorun-spdk.conf << EOF
# assign a value of 1 to all of the pertinent tests
SPDK_BUILD_DOC=1
SPDK_RUN_CHECK_FORMAT=1
SPDK_RUN_SCANBUILD=1
SPDK_RUN_VALGRIND=1
SPDK_TEST_UNITTEST=1
SPDK_TEST_ISCSI=1
SPDK_TEST_ISCSI_INITIATOR=1
SPDK_TEST_NVME=1
SPDK_TEST_NVME_CLI=1
SPDK_TEST_NVMF=1
SPDK_TEST_RBD=1
# requires some extra configuration. see TEST_ENV_SETUP_README
SPDK_TEST_VHOST=0
SPDK_TEST_VHOST_INIT=0
SPDK_TEST_BLOCKDEV=1
# doesn't work on vm
SPDK_TEST_IOAT=0
SPDK_TEST_EVENT=1
SPDK_TEST_BLOBFS=1
SPDK_TEST_PMDK=1
SPDK_TEST_LVOL=1
SPDK_RUN_ASAN=1
SPDK_RUN_UBSAN=1
EOF
fi
