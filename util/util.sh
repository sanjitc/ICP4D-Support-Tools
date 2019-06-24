#!/bin/bash

# output colors
export COLOR_RED='\033[0;31m'
export COLOR_GREEN='\033[0;32m'
export COLOR_YELLOW='\033[0;33m'
export COLOR_NC='\033[0m' # No Color

INSTALL_PATH=/dp/ibm-cp-app/cluster/  ### Added by sanjit ###
OUTPUT_DIR=$1    ### added by sanjit ###
CONFIG_DIR="$INSTALL_PATH"
CONFIG_FILENAME="config.yaml"
HOSTS_FILENAME="hosts"

print_error_message(){
    echo -e  ${COLOR_GREEN}\[$1\]${COLOR_NC}
}

print_warning_message(){
    echo -e  ${COLOR_ORANGE}\[$1\]${COLOR_NC}
}

print_passed_message() {
    echo -e $1 ${COLOR_GREEN}\[OK\]${COLOR_NC}
}

print_failed_message() {
    echo -e $1 ${COLOR_RED}\[FAILED\]${COLOR_NC}
}

print_failed_warn_message() {
    echo -e $1 ${COLOR_RED}\[FAILED\]${COLOR_NC}${COLOR_YELLOW}\[$2\]${COLOR_NC}
}

get_os_version() {
    # ubuntu
    os_version=$(lsb_release -a 2>/dev/null)
    if [ $? -eq 0 ]; then
        os_version=$(echo $os_version | grep "Description:" | awk '{print $2,$3}')
        echo $os_version
        return
    fi

    # redhat
    os_version=$(cat /etc/redhat-release)
    if [ $? -eq 0 ]; then
        echo $os_version
        return
    fi
}

get_temp_dir() {
    mktemp -d
}
#    TEMP_DIR=$(mktemp -d)
#    OUTPUT_DIR=$(mktemp -d)
#    TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")
#    PRE_STR=$TIMESTAMP"-"$$

get_prefix() {
    local TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")
    echo $TIMESTAMP"-"$$
}

build_archive() {
    local output_dir=$1
    local archive_name=$2
    local target_dir=$3
    shift
    shift
    shift
    cd $target_dir && tar czvf $output_dir/$archive_name $@ 2>/dev/null >/dev/null
}


clean_up() {
    local temp_dir=$1
    local retention_period=7
    rm -rf $temp_dir
    find /tmp -type d -mtime $retention_period -name 'icp4d_collect_log.*' -exec rm -Rf {} \;
}

sanity_checks() {
    echo
    echo Running sanity checks...
    echo ----------------------------
    config_file_count=$(find $CONFIG_DIR -name $CONFIG_FILENAME -type f |wc -l)
    if [ ! $config_file_count -ge 1 ]; then
        echo -e could not find $CONFIG_FILENAME in $(readlink --canonicalize $CONFIG_DIR) ${COLOR_RED}\[FAILED\]${COLOR_NC}
        exit 1
    else
        CONFIG_FILE=$(find $CONFIG_DIR -name $CONFIG_FILENAME -type f)
        echo -e Config file found: $(readlink --canonicalize $CONFIG_FILE) ${COLOR_GREEN}\[OK\]${COLOR_NC}
    fi

    hosts_file_count=$(find $CONFIG_DIR -name $HOSTS_FILENAME | wc -l)
    if [ ! $hosts_file_count -eq 1 ]; then
        echo Error: could not find $HOSTS_FILE in $(readlink --canonicalize $CONFIG_DIR)${COLOR_RED}\[FAILED\]${COLOR_NC}
        exit 1
    else
        HOSTS_FILE=$(find $CONFIG_DIR -name $HOSTS_FILENAME | head -n 1)
        echo -e Hosts file found: $(readlink --canonicalize $HOSTS_FILE) ${COLOR_GREEN}\[OK\]${COLOR_NC}
    fi

    verify_running_as_root
    verify_kubectl
    verify_authentication
    #TODO
    #verify_execution_host_is_master
}

verify_running_as_root() {
    if [ `whoami` != 'root' ]; then
        echo -e Running as user $(whoami), need to be root ${COLOR_RED}\[FAILED\]${COLOR_NC}
        echo Cannot perform further checks, exiting...
        exit 1
    else
        echo -e Running as user root ${COLOR_GREEN}\[OK\]${COLOR_NC}
    fi
}

verify_kubectl() {
    if ! [ -x "$(command -v kubectl)" ]; then
        echo -e kubectl not found ${COLOR_RED}\[FAILED\]${COLOR_NC}
        echo Cannot perform further checks, exiting...
  	exit 1
    else
        echo -e kubectl found ${COLOR_GREEN}\[OK\]${COLOR_NC}
    fi
}

verify_execution_host_is_master() {
    #TODO
    #MASTER_IP=$(grep -A 1 -i '^\[master\]' $HOSTS_FILE | tail -n 1)
    MASTER_IP=$(cut -f1 -d' ' $HOSTS_FILE  | tr '\n' ' ' | grep -o -P '(?<=\[master\]).*(?=\[worker\])')
    #MASTER_IP=$(grep -o -P '(?<=\[master\]).*(?=\[worker\])' $HOSTS_FILE)
    host_ips=$(ip addr show | grep inet | awk '{print $2}' | tr '/' ' '|cut -f1 -d' ')
    #grep $MASTER_IP <<< $host_ips >/dev/null
    for item1 in "${MASTER_IP[@]}"; do 
    	for item2 in "${host_ips[@]}"; do
        echo matching $item1 $item2
        [[ $item1 == "$item2" ]] && continue 2
    	done

    	# If we reached here, nothing matched.
   	 not_in_a+=( "$item1" )
    done 
    if [[ $? = 0 ]]; then
        echo -e Running on a master node ${COLOR_GREEN}\[OK\]${COLOR_NC}
    else
        echo -e Running on a master node: IP $MASTER_IP not found on current host ${COLOR_RED}\[FAILED\]${COLOR_NC}
        echo Cannot perform further checks, exiting...
  	exit 1
    fi
}

verify_authentication() {
    kubectl api-versions >/dev/null 2>&1 
    if [ $? -ne 0 ]; then
        /dp/icp-patch/kubectl-auth.sh localhost
        echo -e  Authentication set for kubectl commnd ${COLOR_GREEN}\[OK\]${COLOR_NC}
    fi
}


get_master_nodes() {
    local CONFIG_DIR=$1
    local HOSTS=$CONFIG_DIR/"hosts"
    awk '/^\[master\]/{p=1;next}/^\[/{p=0}p' $HOSTS |sed '/^\s*$/d'
}

is_master_node() {
    local CONFIG_DIR=$1
    local node_name=$2
    local HOSTS=$(get_master_nodes $CONFIG_DIR)
    echo $HOSTS | grep $2 | wc -l 
}

get_worker_nodes() {
    local CONFIG_DIR=$1
    local HOSTS=$CONFIG_DIR/"hosts"
    awk '/^\[worker\]/{p=1;next}/^\[/{p=0}p' $HOSTS |sed '/^\s*$/d'
}

is_worker_node() {
    local CONFIG_DIR=$1
    local node_name=$2
    local HOSTS=$(get_worker_nodes $CONFIG_DIR)
    echo $HOSTS | grep $2 | wc -l 
}

get_pod_status_with_name() {
    pod_name=$1
    status=$(curl http://127.0.0.1:8888/api/v1/pods 2>/dev/null | grep -A 200 -e '"name": "'$pod_name | grep phase |awk '{print $2}' | tr -d '",')
    echo $status
}

setup_remote_tmp_dir() {
    local remote_host=$1
    local remote_tmp_dir=`ssh $remote_host 'mktemp -d 2>/dev/null'`
    echo $remote_tmp_dir
}

copy_to_remote_tmp() {
    local to_host=$1
    local source_file=$2
    local remote_tmp_dir=$(setup_remote_tmp_dir $to_host)
    scp $source_file $to_host':/'$remote_tmp_dir >/dev/null 2>&1 
    echo $remote_tmp_dir
}

extract_remote_archive() {
    local remote_host=$1
    local archive=$2
    local archive_path=$(dirname $archive)
    local archive_name=$(basename $archive)
    ssh $remote_host "cd $archive_path && tar xzvf $archive_name" >/dev/null 2>&1 
}


archive_remote_dir() {
    local remote_host=$1
    local target_dir=$2
    local archive_name=$3
    ssh $remote_host "cd $target_dir && tar czvf $archive_name ./" >/dev/null 2>&1
}

remove_remote_tmp_dir() {
    local remote_host=$1
    local remote_dir=$2
    ssh $remote_host "rm -rf $remote_dir" >/dev/null 2>&1
}

setup_remote_output_dir() {
    local remote_host=$1
    local remote_tmp_dir=$(setup_remote_tmp_dir $remote_host)
    echo $remote_tmp_dir
}

run_script_remotely() {
    local remote_host=$1
    local remote_cwd=$2
    local remote_script=$3
    shift
    shift
    shift

    ssh $remote_host "cd $remote_cwd && $@"
}

adjust_config_for_remote() {
    local remote_topdir=$1
    local local_install=$2
    local adjusted_path=$remote_topdir/$local_install
    echo $adjusted_path
}

adjust_util_for_remote() {
    local remote_topdir=$1
    local local_util=$2
    local adjusted_path=$remote_topdir"/"$local_util
    echo $adjusted_path
}

adjust_env_for_remote() {
    local adjusted_install=$(adjust_config_for_remote $1 $2)
    local adjusted_util=$(adjust_util_for_remote $1 $3)
    local remote_output_dir=$4
    echo "env INSTALL_PATH="$adjusted_install" UTIL_DIR="$adjusted_util " OUTPUT_DIR="$remote_output_dir
}

# does all the required set up to remotely run a script.
run_remote_script() {
    local old_pwd=`pwd`
    local remote_host=$1
    local script=$2
    local output_dir=$3

    local script_dir=$(readlink -f $script|xargs dirname)
    local script_filename=$(basename $script)

    # tar up: script dir + utils dir + config: config.yaml + hosts
    local archive_dir=`mktemp -d`
    local utils_dir=$UTIL_DIR
    local config_file=$INSTALL_PATH"/config.yaml"
    local hosts_file=$INSTALL_PATH"/hosts"

    local archive_name="script.tar.gz"
    archive_file=$archive_dir/$archive_name
    build_archive $archive_dir $archive_name $archive_dir $script_dir $utils_dir $config_file $hosts_file 

    # copy over to remote host temp dir
    local remote_archive_path=$(copy_to_remote_tmp $remote_host $archive_file)
    local remote_archive_file=$remote_archive_path'/'$archive_name

    # extract all on remote host temp dir
    extract_remote_archive $remote_host $remote_archive_file   

    # adjust INSTALL_PATH according to temp dir on host
    # also set OUTPUT_DIR to the temp directory on remote host created for output files
    local remote_output_dir=$(setup_remote_output_dir $remote_host)
    local env_settings=$(adjust_env_for_remote $remote_archive_path $INSTALL_PATH $UTIL_DIR $remote_output_dir)
    # run the script
    local remote_script="$remote_archive_path""$script_dir""/"$script_filename
    local remote_script_path=$(dirname $remote_script)
    run_script_remotely $remote_host $remote_script_path $env_settings "./"$script_filename

    # collect remote output
    local timestamp=`date +"%Y-%m-%d-%H-%M-%S"`
    local remote_archive_name="data_"$script_filename"_"$remote_host"_"$timestamp".tar.gz"
    archive_remote_dir $remote_host $remote_output_dir $remote_archive_name
    scp $remote_host":/"$remote_output_dir"/"$remote_archive_name $output_dir

    # clean up
    remove_remote_tmp_dir $remote_host $remote_archive_path
    remove_remote_tmp_dir $remote_host $remote_output_dir
    rm -rf $archive_dir

    cd $old_pwd
    echo $exit_code
}

run_on_all_nodes() {
    local script=$1
    local out_dir=$2

    local hosts_file=$INSTALL_PATH/hosts
    local hosts_list=`grep -v '^\[' $hosts_file | grep -v '^#' | sort | uniq | awk '{print $1}' | sed '/^\s*$/d'`
  
    echo Running on the following hosts: $hosts_list 
    for h in $hosts_list; do
        echo
        echo
        echo
        echo ========================================
        echo Starting on host: $h
        run_remote_script $h $script $out_dir
    done
}

get_platform() {
    uname -m
}

get_os_version() {
    # ubuntu
    lsb_release -a >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        os_version=$(lsb_release -a 2>/dev/null | grep "Description" | awk '{$1=""; print $0}')
        echo $os_version
        return
    fi

    # redhat
    os_version=$(cat /etc/redhat-release)
    if [ $? -eq 0 ]; then
        echo $os_version
        return
    fi
}


typeset -fx print_passed_message
typeset -fx print_failed_message
typeset -fx get_os_version
typeset -fx get_temp_dir
typeset -fx get_prefix
typeset -fx build_archive
typeset -fx clean_up
typeset -fx get_master_nodes
typeset -fx is_master_node
typeset -fx get_worker_nodes
typeset -fx is_worker_node
typeset -fx run_remote_script
typeset -fx run_on_all_nodes
typeset -fx get_platform
typeset -fx get_os_version
