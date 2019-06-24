#!/bin/bash

# formatting
LINE=$(printf "%*s\n" "30" | tr ' ' "#")


Print_Usage() {
  echo "Usage:"
  echo "$0 [OPTIONS]"
  echo -e "\n  OPTIONS:"
  echo "       --preinstall: Run pre-installation requirements checks (CPU, RAM, and Disk space, etc.)"
  echo "          --type=master|worker: If the current node will be master or worker. For add-ons, choose worker"
  echo "          --install_dir=<install directory>"
  echo "          --data_dir=<data directory> mandatory for worker node"
  echo "       --health: Run post-installation cluster health checker"
  echo "       --health=local: Run post-installation health check locally on individual node"
  echo "       --collect=smart|standard: Run log collection tool to collect diagnostics and logs files from every pod/container. Default is smart"
  echo "          --component=db2,dsx,dv,ca: Run DB2 Hand log collection,DSX, Data Virtualization Diagnostics logs collection."
  echo "                      Works with --collect=standard option"
  echo "          --persona=c,a,o: Runs a focused log collection from specific pods related to a personas Collect, Organize and Analyze. Works with --collect=standard option"
  echo "          --line=N: Capture N number of rows from pod log"
  echo "          --namespace=xx,yy,zz: Run the tool in context of the provided namespaces. By default 'zen' namespace is always included. "
  echo "       --help: Prints this message"
  echo -e "\n  EXAMPLES:"
  echo "      $0 --preinstall --type=master --install_dir=/ibm"
  echo "      $0 --preinstall --type=worker --install_dir=/ibm --data_dir=/data"
  echo "      $0 --health"
  echo "      $0 --health=local"
  echo "      $0 --collect=smart"
  echo "      $0 --collect=standard --component=db2,dsx,dv"
  echo "      $0 --collect=standard --persona=c,a"
  echo
  exit 0
}

Selected_Option() {
  #entry to the tool
      
  if [ $# -eq 0 ] || [ ! -z ${_ICP_HELP} ] ; then
    Print_Usage
    exit 0
  fi

  if [ ! -z ${_ICP_HELP} ]; then
    Print_Usage;
    exit
  fi

  if [ ! -z $_ICP_LINE ]; then
    export LINE=$_ICP_LINE
  fi
  
  #sanity_checks
		
	
  if [ ! -z ${_ICP_COLLECT} ]; then
    Collect_Logs $@;
  fi

  if [ ! -z ${_ICP_HEALTH} ]; then
    Health_CHK;
  fi
	
  if [ ! -z ${_ICP_PREINSTALL} ]; then
    Prereq_CHK;
  fi
}


setup() {
  export HOME_DIR=`pwd`
  export UTIL_DIR=`pwd`"/util"
  export LOG_COLLECT_DIR=`pwd`"/log_collector"
  export PLUGINS=`pwd`"/log_collector/plugins"
  export INSTALL_HOME="/dp"
  export PREINSTALL_CHECK=`pwd`"/pre_install/pre_install_check.sh.j2"

  export LINE=500

  source $UTIL_DIR/util.sh
  . $UTIL_DIR/get_params.sh 

}




setupCollectionDirectory()
{
  if [ -z "$LOGS_DIR" ]; then 
    LOGS_DIR=`mktemp -d`
	    
  fi
}


Prereq_CHK() {


  [ ! -z ${_ICP_TYPE} ] && [[ ${_ICP_TYPE} != "yes" ]] &&  TYPE=${_ICP_TYPE} || { echo "Node Type mandatory for running a precheck"; exit 0; } 
  [ ! -z ${_ICP_INSTALL_DIR} ] && [[ ${_ICP_INSTALL_DIR} != "yes" ]] && INSTALL_DIR=${_ICP_INSTALL_DIR} || { echo "Install Directory mandatory for running a precheck"; exit 0; }  

  [ ! -z ${_ICP_DATA_DIR} ] && [[ ${_ICP_DATA_DIR} != "yes" ]] && DATA_DIR=${_ICP_DATA_DIR} 

  if [ $TYPE == "worker" ]  &&  [ -z ${DATA_DIR} ]; then
	 echo "Worker node must have valid data directory" 
	 exit
  fi


  #[ ! -z ${_ICP_DATA_DIR} ] && DATA_DIR=${_ICP_DATA_DIR} || { echo "Worker nodes must have data diretory specified"; exit 0; }


  #replace the values and generate a temporary run file. 
  tmpFileForResource=$(mktemp /tmp/icpd-temp.XXXXXXXXXX)
  chmod 777 $tmpFileForResource
  cat $PREINSTALL_CHECK > $tmpFileForResource
  sed -i "s|NODETYPE=\"{{ type }}\"|NODETYPE=\"$TYPE\"|g" $tmpFileForResource
  sed -i "s|INSTALLPATH=\"{{ path }}\"|INSTALLPATH=\"$INSTALL_DIR\"|g" $tmpFileForResource

  [ ! -z ${DATA_DIR} ] &&  sed -i "s|DATAPATH_PLACEHOLDER|$DATA_DIR|g" $tmpFileForResource
  sed -i "s|NODENUMBER=|#NODENUMBER=|g" $tmpFileForResource


  #DOCKERDISK="DOCKERDISK_PLACEHOLDER"


   [ -f $tmpFileForResource ] &&  $tmpFileForResource --type=${_ICP_TYPE}  | tee preinstall_check.log || echo "PreInstall Check $PREINSTALL_CHECK not available"

}


Health_CHK() {
  local logs_dir=`mktemp -d`
  local current_node=`hostname -i|awk '{print $1}'`
  cd $HOME_DIR
  if [ ! -z $_ICP_HEALTH ] && [ $_ICP_HEALTH = local ]; then
      ./health_check/icpd-health-check-local.sh | tee health_check_$current_node.log
  else
      ./health_check/icpd-health-check-master.sh | tee health_check.log
  fi
}



Collect_Logs() {
  local logs_dir=`mktemp -d`
  cd $HOME_DIR

  #set defaultnamespace 
  NAMESPACE="zen"
  DEFAULT_NAMESPACE="zen"

  #Prepare the collector sets
  #1. Add system and kube level collectors
  
  commonset="./log_collector/component_sets/system_commons.set
            ./log_collector/component_sets/kube_commons.set"
  

  if [[ "$_ICP_COLLECT" == standard ]]; then

    pluginset="./log_collector/component_sets/collect_all_pod_logs.set"

    # Check for component
    if [ ! -z $_ICP_COMPONENT ] && [ $_ICP_COMPONENT = db2 ]; then
       export COMPONENT=db2
       export DB2POD=`kubectl get pod --all-namespaces --no-headers -o custom-columns=NAME:.metadata.name|grep $COMPONENT`
       pluginset="./log_collector/component_sets/db2_hang_log.set 
                  ./log_collector/component_sets/collect_all_pod_logs.set"

    elif [ ! -z $_ICP_COMPONENT ] && [ $_ICP_COMPONENT = dsx ]; then
       export COMPONENT=dsx
       pluginset="./log_collector/component_sets/dsx_logs.set 
                  ./log_collector/component_sets/collect_all_pod_logs.set"
    elif [ ! -z $_ICP_COMPONENT ] && [ $_ICP_COMPONENT = dv ]; then
       export COMPONENT=dv
       pluginset="./log_collector/component_sets/dv_logs.set 
                  ./log_collector/component_sets/collect_all_pod_logs.set"
    elif [ ! -z $_ICP_COMPONENT ] && [ $_ICP_COMPONENT = ca ]; then
       export COMPONENT=ca
       pluginset="./log_collector/component_sets/ca_logs.set
                  ./log_collector/component_sets/collect_all_pod_logs.set"
    elif [ ! -z $_ICP_PERSONA ]; then
       export PERSONA=`echo $_ICP_PERSONA| awk '{print toupper($0)}'`
       pluginset="./log_collector/component_sets/collect_all_pod_logs.set"

    elif [ ! -z $_ICP_NAMESPACE ]; then
       if [[ ! ",$_ICP_NAMESPACE," = *",$DEFAULT_NAMESPACE,"* ]]; then  
        #Add zen to the list of namespaces
        _ICP_NAMESPACE+=",$DEFAULT_NAMESPACE"
       fi  
       NAMESPACE=$_ICP_NAMESPACE
       
    fi

  elif [[ "$_ICP_COLLECT" == smart ]]; then

    pluginset="./log_collector/component_sets/collect_down_pod_logs.set"

  else

    #future we might have more modes, for now defaulting to smart.
    pluginset="./log_collector/component_sets/collect_down_pod_logs.set"

  fi

   echo logs for common tasks 
     for cmd in `cat ${commonset}`
     do
    	. $PLUGINS/$cmd
     done

   nsOptions=($(echo $NAMESPACE | tr ',' "\n"))
   for element in "${nsOptions[@]}"
   do
     kubectl get ns $element > /dev/null 2>&1
     if [ $? -eq 0 ] ; then
       print_passed_message "Validating Namespace $element" 
     else
       print_failed_warn_message "Validating Namespace $element" "Ignoring"
       continue
      
     fi
     
     export KUBETAIL_NAMESPACE=$element

     for cmd in `cat ${pluginset}`
     do
    	. $PLUGINS/$cmd
     done
   done

  local timestamp=`date +"%Y-%m-%d-%H-%M-%S"`
  local archive_name="logs_"$$"_"$timestamp".tar.gz"
  local output_dir=`mktemp -d -t icp4d_collect_log.XXXXXXXXXX`
  build_archive $output_dir $archive_name $logs_dir "./"
  echo Logs collected at $output_dir/$archive_name
  clean_up $logs_dir
}



Collect_Component_Logs() {
  export COMPONENT=dsx
  export logs_dir=`mktemp -d`
  #export LINE=500

  cd $HOME_DIR
  for cmd in `cat ./log_collector/component_sets/dsx_logs.set`
  do
    . $PLUGINS/$cmd
  done
  local timestamp=`date +"%Y-%m-%d-%H-%M-%S"`
  local archive_name="logs_"$$"_"$timestamp".tar.gz"
  local output_dir=`mktemp -d -t icp4d_collect_log.XXXXXXXXXX`
  build_archive $output_dir $archive_name $logs_dir "./"
  echo Logs collected at $output_dir/$archive_name
  clean_up $logs_dir
}


Collect_DB2_Hang_Logs() {
  export COMPONENT=db2
  export logs_dir=`mktemp -d`
  export LINE=500
  export DB2POD=`kubectl get pod --all-namespaces --no-headers -o custom-columns=NAME:.metadata.name|grep $COMPONENT`

  echo "Collecting diagnostics data for $COMPONENT"
  echo "------------------------------------------"

  cd $HOME_DIR
  for cmd in `cat ./log_collector/component_sets/db2_hang_log.set`
  do
     . $PLUGINS/$cmd
  done
  local timestamp=`date +"%Y-%m-%d-%H-%M-%S"`
  local archive_name="logs_"$$"_"$timestamp".tar.gz"
  local output_dir=`mktemp -d -t icp4d_collect_log.XXXXXXXXXX`
  build_archive $output_dir $archive_name $logs_dir "./"
  echo Logs collected at $output_dir/$archive_name
  clean_up $logs_dir
}


Resource_CHK(){
  echo -e "****************** \n";
  echo -e "Resources Usage at cluster level....\n"
  kubectl top node
  echo -e "Detailed Resource Usage for every node.......";
  echo
  nodes=$(kubectl get node --no-headers -o custom-columns=NAME:.metadata.name)
  for node in $nodes; do
    echo "Rescoure usage for Node: $node"
    kubectl describe node "$node" | sed '1,/Non-terminated Pods/d'
    echo
    echo "Disk usages for Node: $node"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=no \
        -o ConnectTimeout=10 -Tn $node 'du -h'
    echo
  done
}



exitSCRIPT(){
  echo -e "Exiting...";
  exit 0;
}

setup $@
Selected_Option $@
