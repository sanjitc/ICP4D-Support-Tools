#!/bin/bash

#setup output file
OUTPUT="/tmp/preInstallCheckResult"
rm -f ${OUTPUT}

bash -n "$BASH_SOURCE" 2> /dev/null
syntax_result=$?

if [ $syntax_result != 0 ]; then
  echo "Finished with Syntax Error." | tee -a ${OUTPUT}
  exit 3
fi


function checkRAM(){
    local size="$1"
    local limit="$2"
    local message="$3"
    if [[ ${size} -lt ${limit} ]]; then
        eval "$message='ERROR: RAM size is ${size}GB, while requirement is ${limit}GB'"
        return 1
    fi
}

function checkCPU(){
    local size="$1"
    local limit="$2"
    local message="$3"
    if [[ ${size} -lt ${limit} ]]; then
        eval "$message='ERROR: CPU cores are ${size}, while requirement are ${limit}'"
        return 1
    fi
}

function usage(){
    echo "This script checks if this node meets requirements for installation."
    echo "Arguments: "
    echo "--type=[master|worker|management|proxy]     To specify a node type"
    echo "--help                                                          To see help "
}


function checkkube(){
    if [ -d $line/.kube ] 
    then
        echo "ERROR: Found .kube directory in $line. Please remove the old version of kubernetes (rm -rf .kube) and try the installation again. " | tee -a ${OUTPUT}
        return 1
    else
        return 0
    fi
     
}

#Duplicate function also found in utils.sh
function binary_convert() {
    input=$1
    D2B=({0..1}{0..1}{0..1}{0..1}{0..1}{0..1}{0..1}{0..1})
    if (( input >=0 )) && (( input <= 255 ))
    then
        echo $((10#${D2B[${input}]}))
    else
        (>&2 echo "number ${input} is out of range [0,255]")
    fi
}

# Test the if weave subnet overlaps with node subnets
# Example --> test_subnet_overlap 9.30.168.0/16 subnet
#          subnet IP is 9.30.168.0
#          mask is 255.255.0.0
#          takes the logical AND of the subnet IP with the mask
#          Result is 9.30.0.0
#          Minimum of subnet range is 9.30.0.1
#          Add the range which is 2^(32-masknumber) - 2
#          Maximum is 9.30.255.254
#          Creates the minimum and maximum for ip route subnets
#          Compares the weave subnet which is passed to the ip route subnets
#          If the subnets overlap will return 1 and the overlapping subnet
#          If we have a non-default subnet in ip route will return 2 and the non-default field
function test_subnet_overlap() {
    local err_subnet=$3
    # Create the overlay mask
    if [[ ! "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        eval $err_subnet="$1"
        return 3
    fi
    local weave_mask_num=($(echo $1 | cut -d'/' -f2))
    local weave_mask="$(head -c $weave_mask_num < /dev/zero | tr '\0' '1')$(head -c $((32 - $weave_mask_num)) < /dev/zero | tr '\0' '0')"
    # Calculate range difference
    local diff=$((2**(32-$weave_mask_num)))
    # Break the overlay subnet IP into it's components
    local weave_sub=($(echo $1 | cut -d'/' -f1 | sed 's/\./ /g'))
    local weave_bin=""
    # Convert the overlay subnet IP to binary
    for weave in ${weave_sub[@]}; do
        cur_bin="00000000$(binary_convert $weave)"
        local weave_bin="${weave_bin}${cur_bin: -8}"
    done
    # Bitwise AND of the mask and binary overlay IP
    # Develop the range (minimum to maximum) of the overlay subnet
    local weave_min=$(echo $((2#$weave_bin & 2#$weave_mask)) | tr -d -)
    weave_min=$((weave_min + 1))
    local weave_max=($(($weave_min + $diff - 2)))
    # Perform the same steps for node routing subnets
    local ips=($2)
    for ip in ${ips[@]}; do
        if [[ ! "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            eval $err_subnet="$ip"
            return 2
        fi
        local sub_ip=($(echo $ip | cut -d'/' -f1 | sed 's/\./ /g'))
        local sub_mask_num=($(echo $ip | cut -d'/' -f2))
        local sub_mask="$(head -c $sub_mask_num < /dev/zero | tr '\0' '1')$(head -c $((32 - $sub_mask_num)) < /dev/zero | tr '\0' '0')"
        local sub_diff=$((2**(32-$sub_mask_num)))
        local sub_bin=""
        for sub in ${sub_ip[@]}; do
            bin="00000000$(binary_convert $sub)"
            local sub_bin="${sub_bin}${bin: -8}"
        done
        local sub_min=$(echo $((2#$sub_bin & 2#$sub_mask)) | tr -d -)
        sub_min=$((sub_min + 1))
        local sub_max=($(($sub_min + $sub_diff - 2)))
    # Check for if the overlay subnet and node routing subnet overlaps
        if [[ ("$sub_min" -gt "$weave_min" && "$sub_min" -le "$weave_max") || ("$weave_min" -gt "$sub_min" && "$weave_min" -le "$sub_max") || ("$sub_min" == "$weave_min" || "$sub_max" == "$weave_max") ]]; then
            echo "The overlay network ${1} is in the node routing subnet ${ip}"
         # Define problem subnet
            eval $err_subnet="$ip"
            return 1
        else
            echo "The overlay network ${1} is not in the node routing subnet ${ip}"
        fi
    done
    return 0
}

function log() {
    if [[ "$1" =~ ^ERROR* ]]; then
        eval "$2='\033[91m\033[1m$1\033[0m'"
    elif [[ "$1" =~ ^Running* ]]; then
        eval "$2='\033[1m$1\033[0m'"
    elif [[ "$1" =~ ^WARNING* ]]; then
        eval "$2='\033[1m$1\033[0m'"
    else
        eval "$2='\033[92m\033[1m$1\033[0m'"
    fi
}

function helper(){
    echo "##########################################################################################
   Help:
    ./$(basename $0) --type=[master|worker|management|proxy|va]
    Specify a node type and start the validation
    Checking preReq before installation
    Please run this script in all the nodes of your cluster
    Differnt node types have different RAM/CPU requirement
    List of validation:
    CPU
    ERROR for 9node master cpu core < 8, 9node deploy cpu core < 16, 9node compute cpu core < 16; for 3node cpu core < 16
    ERROR for 3node cpu core < 16
    RAM
    ERROR for 9node master RAM < 16GB, 9node deploy RAM < 32GB, 9node compute RAM size < 32GB; for 3node RAM size < 32GB
    ERROR for 3node RAM < 32GB
    Disk latency test:
         WARNING dd if=/dev/zero of=/root/testfile bs=512 count=1000 oflag=dsync The value should be less than 5s for copying 512 kB
         ERROR: must be less than 10s for copying 512 kB,
    Disk throughput test:
        WARNING dd if=/dev/zero of=/root/testfile bs=1G count=1 oflag=dsync The value should be less than 10s for copying 1.1 GB
        ERROR: must be less than 20s for copying 1.1 GB
    Chrony/NTP
        WARNING check is ntp/chrony is setup
    Firewall disabled
        ERROR firewalled and iptable is disabled
    Disk
        ERROR root directory should have at least 10 GB
        WARNING partition for installer files should have one xfs disk formartted and mounted > ${INSTALLPATH_SIZE}GB
        WARNING partition for data storage should have one xfs disk formartted and mounted > ${DATAPATH_SIZE}GB
    Cron job check
        ERROR check whether this node has a cronjob changes ip route, hosts file or firewall setting during installation
    Port checks
        ERROR check multiple ports are open
    SELinux check
        ERROR check SElinux is either in enforcing or permissive mode
    Gateway check
        ERROR check is gateway is setup
    DNS check
        ERROR check is DNS service is setup which allow hostname map to ip
    Docker active check
        ERROR Check to confirm Docker is active
    Kubernetes check
        ERROR Check to confirm Kubernetes is not installed
    Check firewalld
        ERROR Check if firewalld is disable on SuSE Linux
        WARNING Check if firewalld is enabled on operating systems other than SuSE linux
    IPv4 forwarding check
        ERROR Check if ipv4 forwarding is enabled
    Vmmaxmap count check
        ERROR Check if vm.max_map_count is 262144
    IP local port range check
        ERROR Check if net.ipv4.ip_local_port_range starts at 10240
    Subnet check
        WARNING: Non-default routing subnets exist and start at the following word in ip route: ${subnet} that the installer failed to parse. Please verify these subnets yourself.
        ERROR: The overlay network ${WEAVE} conflicts with the node routing subnet ${subnet}
  ##########################################################################################"
}

function checkpath(){
    local mypath="$1"
    if [[  "$mypath" = "/"  ]]; then
        echo "ERROR: Can not use root path / as path" | tee -a ${OUTPUT}
        usage
        exit 1
    fi
    if [ ! -d "$mypath" ]; then
        echo "ERROR: $mypath not found in node." | tee -a ${OUTPUT}
        usage
        exit 1
    fi
}

function printout() {
    echo "##########################################################################################"
    echo -e "$1" | tee -a ${OUTPUT}
    echo "##########################################################################################"
}

function become_cmd(){
    local BECOME_CMD="$1"
    if [[ "$(whoami)" != "root" && $pb_run -eq 0 ]]; then
        BECOME_CMD="sudo $BECOME_CMD"
    elif [[ "$(whoami)" != "root" && $pb_run -eq 1 ]]; then
        BECOME_CMD="pbrun bash -c \"$BECOME_CMD\""
    fi
    eval "$BECOME_CMD"
    return $?
}

function check_package_availability(){
    additional=""
    local error_return=$2
    # $1 - Dependency being checked
    # $2 - Parent of this dependency (if it is not a subdependency this will be "none")
    # $3 - Version of the dependency (if these is no specific version uses empty string)
    # $4 - Determines if we allow installed versions of the packages or not
    #      will be i if we want to check for installed packages otherwise it will be empty
    pack_name="$(echo $1 | cut -d'#' -f1)"
    parent="$(echo $1 | cut -d'#' -f2)"
    version="$(echo $1 | cut -d'#' -f3)"
    pre_installable="$(echo $1 | cut -d'#' -f4)"
    error=0
    INSTALLSTATE=""
    installed=0
    testInstalled=""
    testAvailable=""
    if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
        testInstalled="$(${BECOME_CMD} \"yum list installed ${pack_name} 2> /dev/null\")"
    else
        testInstalled="$(${BECOME_CMD} yum list installed ${pack_name} 2> /dev/null)"
    fi
    installed=${PIPESTATUS[0]}
    package=0
    if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
       testAvailable="$(${BECOME_CMD} \"yum list available ${pack_name} 2> /dev/null\")"
    else
        testAvailable="$(${BECOME_CMD} yum list available ${pack_name} 2> /dev/null)"
    fi
    package=${PIPESTATUS[0]}
    if [[ "$version" != "" ]]; then
        if [[ $installed -eq 0 ]]; then
            echo "$testInstalled" | grep "$version" > /dev/null
            installed=$?
        fi
        if [[ $package -eq 0 ]]; then
            echo "$testAvailable" | grep "$version" > /dev/null
            package=$?
        fi
    fi
    if [[ $installed -eq 0 ]]; then
        if [[ "${pre_installable}" != "i" ]]; then
            if [[ $package -eq 0 ]]; then
                INSTALLSTATE="already installed. Please uninstall and continue."
                error=1
            else
                INSTALLSTATE="already installed and not available from the yum repos. Please uninstall and add the package with it's dependencies to the yum repos."
                error=1
            fi
        fi
    else
        if [[ $package -ne 0 ]]; then
            if [[ "${pre_installable}" != "i" ]]; then
                INSTALLSTATE="not available from the yum repos. Please add the package with it's dependencies to the yum repos."
                error=1
            else
                INSTALLSTATE="not available from the yum repos and not installed. Please add the package with it's dependencies to the yum repos or install the package."
                error=1
            fi
        fi
    fi
    eval $error_return=""
    if [[ $error -eq 1 ]]; then
        if [[ "${version}" != "" ]]; then
            if [[ "$parent" == "none" ]]; then
                eval $error_return="ERROR: ${pack_name} with version ${version} is ${INSTALLSTATE}"
            else
                eval $error_return="ERROR: The ${pack_name} dependency with version ${version} for the $parent package is ${INSTALLSTATE}"
            fi
        else
            if [[ "$parent" == "none" ]]; then
                eval $error_return="ERROR: ${pack_name} is ${INSTALLSTATE}"
            else
                eval $error_return="ERROR: The ${pack_name} dependency for the $parent package is ${INSTALLSTATE}"
            fi
            
        fi
    fi
    return $error
}

#for internal usage
NODETYPE="master" #if master one internal run will not check docker since we already install it
NODENUMBER=0
INSTALLPATH="/ibm"
DATAPATH="DATAPATH_PLACEHOLDER"
DOCKERDISK="DOCKERDISK_PLACEHOLDER"
CPU=0
RAM=0
WEAVE=0
pb_run=0
centos_repo=0
root_size=50
install_path_size=200
data_path_size=200

#Global parameter
INSTALLPATH_SIZE=250


WARNING=0
ERROR=0
LOCALTEST=0

if [[ "$(whoami)" != "root" && $pb_run -eq 0 ]]; then
    BECOME_CMD="sudo "
elif [[ "$(whoami)" != "root" && $pb_run -eq 1 ]]; then
    BECOME_CMD="pbrun bash -c "
fi

#input check
if [[  $# -ne 1  ]]; then
    if [[ "$INSTALLPATH" != "" ]]; then
        # This mean internal call the script, the script has already edited the INSTALLPATH DATAPATH CPU RAM by sed cmd
        checkpath $INSTALLPATH
        if [[ "$DATAPATH" != "" ]]; then
            checkpath "$DATAPATH"
        fi
    else
        usage
        exit 1
    fi
else
    # This mean the user runs script, will prompt user to input the INSTALLPATH DATAPATH
    if [[  "$1" = "--help"  ]]; then
        helper
        exit 1
    elif [ "$1" == "--type=master" ] || [ "$1" == "--type=worker" ] || [ "$1" == "--type=management" ] || [ "$1" == "--type=proxy" ]; then

        if [[ "$1" = "--type=master" ]]; then       
            if [[ "${DATAPATH}" != "DATAPATH_PLACEHOLDER" ]]; then
                CPU=8
                RAM=16
            else 
                CPU=8
                RAM=16
            fi
        elif [[ "$1" = "--type=worker" ]]; then
            CPU=8
            RAM=16
        elif [[ "$1" = "--type=proxy" ]]; then
            CPU=2
            RAM=4
        elif [[ "$1" = "--type=management" ]]; then
            CPU=4
            RAM=8
        else
            echo "please only specify type among master/worker/proxy/management"
            exit 1
        fi
    else
        echo "Sorry the argument is invalid"
        usage
        exit 1
    fi
fi

echo "##########################################################################################" > ${OUTPUT} 2>&1
output="Checking Disk latency and Disk throughput\n"
become_cmd "dd if=/dev/zero of=${INSTALLPATH}/testfile bs=512 count=1000 oflag=dsync &> output"

res=$(cat output | tail -n 1 | awk '{print $6}')
# writing this since bc may not be default support in customer environment
res_int=$(echo $res | grep -E -o "[0-9]+" | head -n 1)
if [[ $res_int -gt 10 ]]; then
    log "ERROR: Disk latency test failed. By copying 512 kB, the time must be shorter than 10s, recommended to be shorter than 5s, validation result is ${res_int}s " result
    output+="$result"
    ERROR=1
    LOCALTEST=1
elif [[ $res_int -gt 5 ]]; then
    log "WARNING: Disk latency test failed. By copying 512 kB, the time recommended to be shorter than 5s, validation result is ${res_int}s " result
    output+="$result"
    WARNING=1
    LOCALTEST=1
fi

become_cmd "dd if=/dev/zero of=${INSTALLPATH}/testfile bs=1G count=1 oflag=dsync &> output"

res=$(cat output | tail -n 1 | awk '{print $6}')
# writing this since bc may not be default support in customer environment
res_int=$(echo $res | grep -E -o "[0-9]+" | head -n 1)
if [[ $res_int -gt 20 ]]; then
    log "ERROR: Disk throughput test failed. By copying 1.1 GB, the time must be shorter than 20s, recommended to be shorter than 10s, validation result is ${res_int}s " result
    output+="$result"
    ERROR=1
    LOCALTEST=1
elif [[ $res_int -gt 10 ]]; then
    log "WARNING: Disk throughput test failed. By copying 1.1 GB, the time is recommended to be shorter than 10s, validation result is ${res_int}s " result
    output+="$result"
    WARNING=1
    LOCALTEST=1
fi
if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi
rm -f output > /dev/null 2>&1
rm -f ${INSTALLPATH}/testfile > /dev/null 2>&1


LOCALTEST=0

 
output="Checking gateway\n"
become_cmd "ip route" | grep "default" > /dev/null 2>&1


if [[ $? -ne 0 ]]; then
    log "ERROR: default gateway is not setup " result
    output+="$result"
    ERROR=1
    LOCALTEST=1
fi
if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi


LOCALTEST=0


output="Checking DNS\n"

become_cmd "cat /etc/resolv.conf" | grep  -E "nameserver (25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)" &> /dev/null

if [[ $? -ne 0 ]]; then
    log "ERROR: DNS is not properly setup, please make sure a nameserver specified in /etc/resolv.conf" result
    output+="$result"
    ERROR=1
    LOCALTEST=1
fi
if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi


LOCALTEST=0


output="Checking if firewall is shutdown\n"
become_cmd "service iptables status > /dev/null 2>&1"

if [ $? -eq 0 ]; then         
    log "ERROR: iptable is not disabled" result
    output+="$result"
    LOCALTEST=1
    ERROR=1
fi
become_cmd "service ip6tables status > /dev/null 2>&1"

if [ $? -eq 0 ]; then         
    log "ERROR: ip6table is not disabled" result
    output+="$result"
    LOCALTEST=1
    ERROR=1
fi
become_cmd "systemctl status firewalld > /dev/null 2>&1"

if [ $? -eq 0 ]; then         
    log "ERROR: firewalld is not disabled" result
    output+="$result"
    LOCALTEST=1
    ERROR=1
fi
if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi


LOCALTEST=0


output="Checking SELinux\n"
if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
    selinux_res="$(${BECOME_CMD} \"getenforce\" 2>&1)"
else 
    selinux_res="$(${BECOME_CMD} getenforce 2>&1)"
fi


if [[ ! "${selinux_res}" =~ ("Permissive"|"permissive") ]]; then
    log "ERROR: SElinux is not in permissive mode, but your node currently is ${selinux_res} " result

    output+="$result"
    LOCALTEST=1
    ERROR=1
fi
if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi


LOCALTEST=0


output="Checking pre-existing cronjob\n"
become_cmd "crontab -l" | grep -E "*" &> /dev/null

if [[ $? -eq 0 ]] ; then
    log "WARNING: Found cronjob set up in background. Please make sure cronjob will not change ip route, hosts file or firewall setting during installation" result
    output+="$result"
    LOCALTEST=1
    WARNING=1
fi
if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi

cat /etc/SuSE-release > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
    LOCALTEST=0

    output="Ensuring firewalld is not active\n"
    become_cmd "systemctl status firewalld" > /dev/null 

    if [[ $? -eq 0 ]] ; then
        log "ERROR: Firewalld is currently active. Since this is a SuSE linux system, firewalld is not supported during installation, please stop and disable firewalld in that order using the following commands: \"systemctl stop firewalld\" and \"systemctl disable firewalld\"." result
        output+="$result"
        LOCALTEST=1
        ERROR=1
    fi
    if [[ ${LOCALTEST} -eq 1 ]]; then
        printout "$output"
    fi
fi


LOCALTEST=0

output="Checking size of root partition\n"

if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
    actual_root_size=$(${BECOME_CMD} "df -k -BG \"/\" | awk '{print($4 \" \" $6)}' | grep \"/\" | cut -d' ' -f1 | sed 's/G//g'")
else
    actual_root_size=$(${BECOME_CMD} df -k -BG "/" | awk '{print($4 " " $6)}' | grep "/" | cut -d' ' -f1 | sed 's/G//g')
fi
if [[ $actual_root_size -lt $root_size ]] ; then
    log "ERROR: size of root partition is smaller than ${root_size}G" result
    output+="$result"
    LOCALTEST=1
    ERROR=1
fi
if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi

LOCALTEST=0

if [[ "$DOCKERDISK" != "DOCKERDISK_PLACEHOLDER" ]]; then
    install_path_size=100
fi


output="Checking the size of installer path\n"


if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
    is_mounted=$(${BECOME_CMD} "df  \"${INSTALLPATH}\" | awk '{print($6)}' | grep \"${INSTALLPATH}\"")
else 
    is_mounted=$(${BECOME_CMD} df "${INSTALLPATH}" | awk '{print($6)}' | grep "${INSTALLPATH}" )
fi
if [ -z "$is_mounted" ]; then
    #not mounted
    log "ERROR: the install path ${INSTALLPATH} is not a mountpoint" result
    output+="$result"
    LOCALTEST=1
    ERROR=1
else
    #mounted, check size of partition
    if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
        actual_install_path_size=$(${BECOME_CMD} "df -k -BG \"${INSTALLPATH}\" | awk '{print($4 \" \" $6)}' | grep \"${INSTALLPATH}\" | cut -d' ' -f1 | sed 's/G//g'")
    else 
        actual_install_path_size=$(${BECOME_CMD} df -k -BG "${INSTALLPATH}" | awk '{print($4 " " $6)}' | grep "${INSTALLPATH}" | cut -d' ' -f1 | sed 's/G//g')
    fi
    if [[ $actual_install_path_size -lt $install_path_size ]] ; then
        log "ERROR: size of install path ${INSTALLPATH} (${actual_install_path_size}G) is smaller than ${install_path_size}G" result
        output+="$result"
        LOCALTEST=1
        ERROR=1
    fi
fi


if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi


if [[ "${DATAPATH}" != "DATAPATH_PLACEHOLDER" ]]; then
    LOCALTEST=0
    output="Checking if install path and data path are the same\n"
    if [[ "$INSTALLPATH" == "$DATAPATH" ]] ; then
        log "ERROR: Install path is the same as data path. Please ensure they are different mounted locations on your system." result
        output+="$result"
        LOCALTEST=1
        ERROR=1
    fi
    if [[ ${LOCALTEST} -eq 1 ]]; then
        printout "$output"
    fi
    
    LOCALTEST=0
    output="Checking the size of data path\n"

    if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
        is_mounted=$(${BECOME_CMD} "df  \"${DATAPATH}\" | awk '{print($6)}' | grep \"${DATAPATH}\"")
    else 
        is_mounted=$(${BECOME_CMD} df "${DATAPATH}" | awk '{print($6)}' | grep "${DATAPATH}" )
    fi
    if [ -z "$is_mounted" ]; then
        #not mounted
        log "ERROR: the data path ${DATAPATH} is not a mountpoint" result
        output+="$result"
        LOCALTEST=1
        ERROR=1
    else 
        if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
            actual_data_path_size=$(${BECOME_CMD} "df -k -BG \"${DATAPATH}\" | awk '{print($4 \" \" $6)}' | grep \"${DATAPATH}\" | cut -d' ' -f1 | sed 's/G//g'")
        else
            actual_data_path_size=$(${BECOME_CMD} df -k -BG "${DATAPATH}" | awk '{print($4 " " $6)}' | grep "${DATAPATH}" | cut -d' ' -f1 | sed 's/G//g')
        fi
        if [[ $actual_data_path_size -lt $data_path_size ]] ; then
            log "ERROR: size of install path ${DATAPATH} (${actual_data_path_size}G) is smaller than ${data_path_size}G" result
            output+="$result"
            LOCALTEST=1
            ERROR=1
        fi
    fi

    if [[ ${LOCALTEST} -eq 1 ]]; then
        printout "$output"
    fi
fi

LOCALTEST=0

become_cmd "which docker > /dev/null 2>&1"
rc1=$?

if [[ ${rc1} -eq 0 ]]; then
    output="Checking to confirm docker is active\n"
    
    become_cmd "systemctl is-active docker &> /dev/null"

    rc2=$?
    if [[ ${rc2} -ne 0 ]]; then
        log "ERROR: Docker is installed but not active (Please check \"systemctl status docker\" for more information)." result
        output+="$result"
        LOCALTEST=1
        ERROR=1
    fi
    if [[ ${LOCALTEST} -eq 1 ]]; then
        printout "$output"
    fi
fi

# Check if hostnames are all in lowercase characters
LOCALTEST=0
output="Checking if hostname is in lowercase characters\n"

if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
    host_name=$(${BECOME_CMD} "hostname")
else
    host_name=$(${BECOME_CMD} hostname)
fi

if [[ "$host_name" =~ [A-Z] ]]; then
    log "ERROR: Only lowercase characters are supported in the hostname ${host_name}\n" result
    output+="$result"
    ERROR=1
    LOCALTEST=1
fi

if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi


LOCALTEST=0


output="Checking CPU core numbers and RAM size\n"
# Get CPU numbers and min frequency
if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
    cpunum=$(${BECOME_CMD} "cat /proc/cpuinfo" | grep '^processor' |wc -l | xargs)
else
    cpunum=$(${BECOME_CMD} cat /proc/cpuinfo | grep '^processor' |wc -l | xargs)
fi
if [[ ! ${cpunum} =~ ^[0-9]+$ ]]; then
    log "ERROR: Invalid number of cpu cores ${cpunum}\n" result
    output+="$result"
else
    checkCPU ${cpunum} ${CPU} msg
    if [[ $? -eq 1 ]]; then
        log "${msg}\n" result
        output+="$result"
    LOCALTEST=1
    WARNING=1
    fi
fi
if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
    mem=$(${BECOME_CMD} "cat /proc/meminfo" | grep MemTotal | awk '{print $2}')
else
    mem=$(${BECOME_CMD} cat /proc/meminfo | grep MemTotal | awk '{print $2}')
fi
# Get Memory info
mem=$(( $mem/1000000 ))
if [[ ! ${mem} =~ ^[0-9]+$ ]]; then
    log "ERROR: Invalid memory size ${mem}\n" result
    output+="$result"
else
    checkRAM ${mem} ${RAM} message
    if [[ $? -eq 1 ]]; then
        log "${message}\n" result
        output+="$result"
    LOCALTEST=1
    WARNING=1
    fi
fi
if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi


LOCALTEST=0

output="Checking if localhost exists and is correct\n"
if [ ! -f /etc/hosts ]; then
    log "ERROR: No /etc/hosts file found" result
    output+="$result"
    ERROR=1
    LOCALTEST=1
else
    # Find a line has match "[[:space:]]\+localhost[[:space:]]\+" or "[[:space:]]\+localhost$"
    getLocal=$(grep -v '^#' /etc/hosts | grep '[[:space:]]\+localhost[[:space:]]\+\|[[:space:]]\+localhost$')
    if [[ $(echo "$getLocal" | sed '/^\s*$/d' | wc -l) > 0 ]]; then
        if [[ $(echo "$getLocal" | grep "^127.0.0.1[[:space:]]\+" | sed '/^\s*$/d' | wc -l) > 0 ]]; then
            if [[ $(echo "$getLocal" | grep -E -v '^::1 |^#'| wc -l) > 1 ]]; then
                log "ERROR: Localhost is mapped to more than one IP entry"
                output+="$result"
                ERROR=1
                LOCALTEST=1
            fi
        else
            log "ERROR: There is no localhost entry mapped to IP 127.0.0.1" result
            output+="$result"
            ERROR=1
            LOCALTEST=1
        fi
    else
        log "ERROR: There are no localhost entries in /etc/hosts" result
        output+="$result"
        ERROR=1
        LOCALTEST=1
    fi
fi
if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi

# Check hostname is externally reachable IP
LOCALTEST=0
localhost_array=("127.0.0.1", "127.0.1.1", "localhost")
output="Checking if hostname is not set to localhost:\n"

for host in "${localhost_array[@]}"; do
    if  echo $(hostname) | grep -q $host; then    
        log "ERROR: hostname is set to localhost. Please, check the file /etc/hostname." result
        output+="$result"
        ERROR=1
        LOCALTEST=1
    fi
done
if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi

# Check if hostname is resolvable
LOCALTEST=0 
hostping_test=`ping -c 1 $(hostname) 2> /dev/null | awk -F'[()]' '{print $2;exit}'`
if [ -z "$hostping_test" ]; then 
    log "ERROR: hostname is unresolvable. Please configure your hostname to resolve to an externally reachable IP" result
    output+="$result"
    ERROR=1
    LOCALTEST=1
    printout "$output"
fi

LOCALTEST=0

output="Checking if appropriate os and version\n"
osName=$(grep ^ID= /etc/os-release | cut -f2 -d'"')
if [[ "$osName" == "rhel" || "$osName" == "centos" ]]; then
    osVer=$(grep ^VERSION_ID= /etc/os-release | cut -f2 -d'"')
    if [[ "$osName" == "centos" ]]; then
        osVer=$(awk '{print $4}' /etc/centos-release | cut -d\. -f1,2)
    fi
    osVerMajor=${osVer%.*}
    osVerSub=${osVer#*.}
    if [[ $osVerMajor -lt 7 ]] || ( [[ $osVerMajor -eq 7 ]] && [[ $osVerSub -lt 5 ]] ); then
        log "ERROR: The OS version must be 7.5 or above." result
        output+="$result"
        ERROR=1
        LOCALTEST=1
    fi
else
    log "ERROR: The OS must be Red Hat or CentOS." result
    output+="$result"
    ERROR=1
    LOCALTEST=1
fi
if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi

LOCALTEST=0

output="Checking if the ansible dependency libselinux-python is installed\n"
get_rpm="rpm -qa"
if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
    se=$(${BECOME_CMD} "$get_rpm" | grep libselinux-python | wc -l)
else
    se=$(${BECOME_CMD} $get_rpm | grep libselinux-python | wc -l)
fi
if [[ $se == 0 ]]; then
    log "ERROR: The libselinux-python package needs to be installed" result
    output+="$result"
    ERROR=1
    LOCALTEST=1
fi
if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi


LOCALTEST=0

output="Ensuring the IPv4 IP Forwarding is set to enabled\n"
ipv4_forward=$(cat /proc/sys/net/ipv4/ip_forward)
if [[ $ipv4_forward -eq 0 ]]; then
    conf_check=$(sed -n -e 's/^net.ipv4.ip_forward//p' /etc/sysctl.conf | tr -d = |awk '{$1=$1};1')
    if [[ $conf_check -eq 1 ]]; then
        log "ERROR: The sysctl config file (/etc/sysctl.conf) has IPv4 IP forwarding set to enabled (net.ipv4.ip_forward = 1) but the file is not loaded. Please run the following command to load the file: sysctl -p." result
        output+="$result"
    else
        log "ERROR: The sysctl config has IPv4 IP forwarding set to disabled (net.ipv4.ip_forward = 0). IPv4 forwarding needs to be enabled (net.ipv4.ip_forward = 1). To enable IPv4 forwarding we recommend use of the following commands: \"sysctl -w net.ipv4.ip_forward=1\" or \"echo 1 > /proc/sys/net/ipv4/ip_forward\"." result
        output+="$result"
    fi
    ERROR=1
    LOCALTEST=1
fi
if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi

if [[ "$NODETYPE" == "master" ]]; then
    LOCALTEST=0
    
    output="Ensuring the vm.max_map_count under sysctl is at least 262144\n"
    vm_max_count=$(sysctl vm.max_map_count | cut -d "=" -f2)
    if [[ $vm_max_count -lt 262144 ]]; then
        log "ERROR: The sysctl configuration for vm.max_map_count is not at least 262144. Please run the following command to set it to 262144 \"sysctl -w vm.max_map_count=262144\"." result
        output+="$result"
        ERROR=1
        LOCALTEST=1
    fi
    if [[ ${LOCALTEST} -eq 1 ]]; then
        printout "$output"
    fi
        

    LOCALTEST=0
    
    output="Ensuring the net.ipv4.ip_local_port_range under sysctl starts at 10240\n" 
    port_lower=$(sysctl net.ipv4.ip_local_port_range | cut -d "=" -f2 | awk '{print $1}')

    port_higher=$(sysctl net.ipv4.ip_local_port_range | cut -d "=" -f2 | awk '{print $2}')
    if [[ $port_lower -lt 10240 ]]; then
        log "ERROR: The sysctl configuration for net.ipv4.ip_local_port_range does not start with 10240. Please run the following command to set the lower end of the range to 10240: sysctl -w net.ipv4.ip_local_port_range=\"10240  $port_higher\"" result


        output+="$result"
        ERROR=1
        LOCALTEST=1
    fi
    if [[ ${LOCALTEST} -eq 1 ]]; then
        printout "$output"
    fi

        LOCALTEST=0

    # ensure net.ipv4.conf.all.rp_filter is set to either 0 or 1, or calico will report FATAL later on
    output="Ensuring that net.ipv4.conf.all.rp_filter under sysctl is either 0 or 1\n"
    rp_filter=$(sysctl -n net.ipv4.conf.all.rp_filter)

    if [[ $rp_filter -ne 0 && $rp_filter -ne 1 ]]; then
        log "ERROR: The sysctl configuration for rp_filter needs to be either 0 or 1. Please run the following command to set ipv4 rf_filter: sysctl -w net.ipv4.conf.all.rp_filter=1" result

        output+="$result"
        ERROR=1
        LOCALTEST=1
    fi
    if [[ ${LOCALTEST} -eq 1 ]]; then
        printout "$output"
    fi
fi

LOCALTEST=0

function array_contains () {
    local array="$1[@]"
    local seeking=$2
    for element in "${!array}"; do
        if [[ $element == $seeking ]]; then
            return 1
        fi
    done
    return 0
}

output="Checking if all necessary ports are available\n"
which ss > /dev/null
if [[ $? -ne 0 ]]; then
    log "ERROR: The ss command was not found. Please ensure it was installed and check the location using \"which ss\"." result
    output+="$result"
else 
    listens=($(ss -lntu | awk '{print $5}' | tail -n +2))
    if [[ $? -eq 0 ]]; then
        for i in "${!listens[@]}"; do
            listens[$i]=${listens[$i]##*:}
        done
        listens=($(printf "%s\n" "${listens[@]}" | sort -u))
       
        ports=("31843")
        for port in "${ports[@]}"; do
            if [[ $port = *"-"* ]]; then
                portRange=(${port//-/ })
                for number in $(seq ${portRange[0]} ${portRange[1]}); do 
                    array_contains listens $number
                    if [[ $? -eq 1 ]]; then
                        log "ERROR: The port $number is not available.\n" result
                        output+="$result"
                        LOCALTEST=1
                        ERROR=1
                    fi
                done    
            else
                array_contains listens $port 
                if [[ $? -eq 1 ]]; then
                    log "ERROR: The port $port is not available.\n" result
                    output+="$result"
                    LOCALTEST=1
                    ERROR=1
                fi
            fi
        done        
    fi
fi
if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi

LOCALTEST=0

output="Ensuring node can mount directories to NFS server (only when installing with NFS) \n"
#if installing with NFS
if [ 'oketi-gluster' = 'oketi-nfs' ]; then
    mkdir -p ${INSTALLPATH}/nfs_mount
    mount -t nfs : ${INSTALLPATH}/nfs_mount
    if [[ $? -ne 0 ]]; then
        log "ERROR: directory cannot be mounted to NFS server. Please check NFS server is setup correctly. " result
        output+="$result"
        ERROR=1
        LOCALTEST=1
    else 
        # create a subdirectory, add a simple script and execute it
        subdir=${INSTALLPATH}/nfs_mount/temp
        mkdir -p ${subdir} && echo "pwd" > ${subdir}/script.sh && chmod +x ${subdir}/script.sh && ${subdir}/script.sh > /dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            log "ERROR: unable to create or execute scripts in NFS mounted directory. Please check that NFS is set up correctly" result
            output+="$result"
            ERROR=1
            LOCALTEST=1
        fi
        umount ${INSTALLPATH}/nfs_mount
        if [[ $? -ne 0 ]]; then
            log "ERROR: ${INSTALLPATH}/nfs_mount directory cannot be unmounted. Please unmount the directories manually on every node by running umount ${INSTALLPATH}/nfs_mount" result
            output+="$result"
            ERROR=1
            LOCALTEST=1
        fi
    fi
    rm -rf ${INSTALLPATH}/nfs_mount
fi
if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi

LOCALTEST=0

output="Ensuring the correct version of python is installed\n"
python_version=$(python --version 2>&1)
python --version > /dev/null 2>&1
if [[ $? -ne 0 ]]; then
    log "ERROR: Running python commands was unsuccessful, ensure any python version from 2.6 to 2.9.x is installed." result
    output+="$result"
    ERROR=1
    LOCALTEST=1
else 
    verAvail=0
    versions=("2.6" "2.7" "2.8" "2.9")
    for version in ${versions[@]}; do
        echo $python_version | grep " $version" > /dev/null
        if [[ $? -eq 0 ]]; then 
            verAvail=1
        fi
    done
    if [[ $verAvail -eq 0 ]]; then
        log "ERROR: Python version from 2.6 to 2.9.x is not installed." result
        output+="$result"
        LOCALTEST=1
        ERROR=1
    fi
fi
if [[ ${LOCALTEST} -eq 1 ]]; then
    printout "$output"
fi


osName=$(grep ^ID= /etc/os-release | cut -f2 -d'"' | cut -f2 -d'=')
if [[ $centos_repo -eq 0 && "$arch" == "x86_64" && "$osName" == "rhel" ]]; then
    LOCALTEST=0
    
    output="Checking if packages and dependencies are available\n"
    # packages array contains package information in the form "package_name#parent_package#version_number#pre_installable" 
    # The values for version number can be empty if they are not being checked for
   # The values for pre_installable are "i" if the package can be installed before hand or "" if it cannot be installed before dsx install
    packages=("docker###i" \
    "attr#glusterfs-server##i" \
    "gssproxy#glusterfs-server##i" \
    "keyutils#glusterfs-server##i" \
    "libbasicobjects#glusterfs-server##i" \
    "libcollection#glusterfs-server##i" \
    "libevent#glusterfs-server##i" \
    "libini_config#glusterfs-server##i" \
    "libnfsidmap#glusterfs-server##i" \
    "libpath_utils#glusterfs-server##i" \
    "libref_array#glusterfs-server##i" \
    "libtirpc#glusterfs-server##i" \
    "libverto-libevent#glusterfs-server##i" \
    "nfs-utils#glusterfs-server##i" \
    "psmisc#glusterfs-server##i" \
    "quota#glusterfs-server##i" \
    "quota-nls#glusterfs-server##i" \
    "rpcbind#glusterfs-server##i" \
    "tcp_wrappers#glusterfs-server##i")
    if [[ "${NODETYPE}" != "master" ]]; then
        packages=("${packages[@]:0:1}" "${packages[@]:3}")
    fi 
    for i in "${!packages[@]}"; do 
        check_package_availability "${packages[$i]}" $message
        log "${message}\n" result
        output+="$result"
        return_value=$?
        if [[ $return_value -ne 0 ]]; then
            LOCALTEST=$return_value
        fi
        if [[ $ERROR -eq 0 ]]; then
            ERROR=$return_value
        elif [[ $ERROR -eq 1 ]]; then
            ERROR=1
        fi
    done
    if [[ ${LOCALTEST} -eq 1 ]]; then
        printout "$output"
    fi
        
fi
#log result
if [[ ${ERROR} -eq 1 ]]; then
    echo "Finished with ERROR, please check ${OUTPUT}"
    exit 2
elif [[ ${WARNING} -eq 1 ]]; then
    echo "Finished with WARNING, please check ${OUTPUT}"
    exit 1
else
    echo "Finished successfully! This node meets the requirement" | tee -a ${OUTPUT}
    exit 0
fi
