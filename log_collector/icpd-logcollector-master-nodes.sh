#!/bin/bash
#run only on master nodes

ns="${KUBETAIL_NAMESPACE:-zen}"
loglines="${LOG_LINE:-15}"

setup() {
    . $UTIL_DIR/util.sh
    #commonly used func are inside of util.sh
    CONFIG_DIR=$INSTALL_PATH

    #TEMP_DIR=$OUTPUT_DIR	
    PRE_STR=$(get_prefix)

    LOG_FILE="/tmp/icp_checker.log"
    echo
    echo =============================================================
    echo
    echo Running ICP for Data Log Collector Mode [ $1 ] ...
    #echo ICP Version: $PRODUCT_VERSION
    #echo Release Date: $RELEASE_DATE
    echo =============================================================
}

myEcho()
{
  echo -n $1
}


log_collector(){

    #Smart|Standard
    #Smart option, collects 50 lines from healthy pods & all the logs from down pods
    #Standard option, collects specified number of lines from down pods only. 
    mode=$1 
    
    local tempdir=$logs_dir

    tmpFileForHealthyPods=$(mktemp /tmp/icpd-temp.XXXXXXXXXX)
    tmpFileForDownPods=$(mktemp /tmp/icpd-temp.XXXXXXXXXX)
    trap 'rm -f $TmpFileForHealthyPods' EXIT
    trap 'rm -f $TmpFileForDownPods' EXIT

    #select relevant pods first
    # Swicth between all pods and non healthy pods
    all_pods=`kubectl get pods -n $ns --no-headers | awk '{print $1}'`


    if [ !  -z "$PERSONA"  ]; then
    pOptions=($(echo $PERSONA | tr ',' "\n"))
    for element in "${pOptions[@]}"
    do
      ## Collect UG&I logs that don't send to STDOUT.
      ## Logs are hardcoded here. Needs a batter way to handel it later.
      if [ $element == "O" ]; then
         get_pod_log_by_name $tempdir zen-iis-xmetarepo-db2diag.log $ns \
            $(kubectl get pods -n zen|grep ibm-iisee-zen-iis-xmetarepo|awk '{print $1}') \
            "/home/db2inst1/sqllib/db2dump/db2diag.log"

         get_pod_log_by_name $tempdir is-en-conductor-cognition-engine-server.log $ns \
            $(kubectl get pods -n zen|grep is-en-conductor|awk '{print $1}') \
            "/opt/IBM/InformationServer/ASBNode/CognitiveDesignerEngine/logs/cognition-engine-server.log"

         get_pod_log_by_name $tempdir is-en-conductor-odfengine.log $ns \
            $(kubectl get pods -n zen|grep is-en-conductor|awk '{print $1}') \
            "/opt/IBM/InformationServer/ASBNode/logs/odfengine"

         get_pod_log_by_name $tempdir is-en-conductor-asb-agent.log $ns \
            $(kubectl get pods -n zen|grep is-en-conductor|awk '{print $1}') \
            "/opt/IBM/InformationServer/ASBNode/logs/asb-agent"
      fi
      persona_pods+=`cat util/conf/pod_maps.conf | grep zen | grep \|$element\| | cut -f2 -d '|'`
    done
      
    fi

    
    for dp in `echo $all_pods`
    do
       ## If mode is Healthy, collections select all zen pods - Live or Dead or somewhere in between.
       ## If mode is Down, collection spares the live and kicking ones from its selection
       ## If selector is defined, select only pods for that persona

       selected=false

       if [ ! -z "$persona_pods" ]; then 
         FOUND=`echo $dp | grep  "${persona_pods[*]}"| wc -l`
       	 if [ $FOUND -gt 0 ]; then 
           selected=true
         fi
       else
           selected=true 
       fi

       if [ "$selected" = true ] ; then
 
       #check if this pod is down.
       kubectl get pods -n $ns $dp --no-headers|grep -Ev '1/1 .* R|2/2 .* R|3/3 .* R|4/4 .* R|5/5 .* R|6/6 .* R' | grep -v 'Completed'  > /dev/null
       
       if [ $? -eq 0 ] ; then 
           #Pod is down
           container=`kubectl get pods -n $ns $dp -o jsonpath='{@.spec.containers[*].name}'`
           for cnt in `echo $container`
           do
               echo "echo '### '" >> $tmpFileForDownPods
               echo "echo '### NAMESPACE=$ns, POD=$dp, CONTAINER=$cnt ###'" >> $tmpFileForDownPods
               echo "echo '### kubectl logs -n $ns -p $dp -c $cnt'" >> $tmpFileForDownPods
               echo "kubectl logs -n $ns -p $dp -c $cnt > /dev/null 2>&1" >> $tmpFileForDownPods
           done
       else
            echo "echo '### '" >> $tmpFileForHealthyPods
            echo "echo '### NAMESPACE=$ns, POD=$dp ###'" >> $tmpFileForHealthyPods
            echo "echo '### kubectl logs -n $ns $dp --tail=$loglines'" >> $tmpFileForHealthyPods
            echo "echo '### ### '" >> $tmpFileForHealthyPods
            echo "kubectl logs -n $ns  $dp --tail=$loglines 2>/dev/null" >> $tmpFileForHealthyPods
       fi
      fi
    done
    get_log_by_cmd $tempdir log_for_healthy_pods_$ns "sh $tmpFileForHealthyPods"
    get_log_by_cmd $tempdir log_for_down_pods_$ns "sh $tmpFileForDownPods"
    rm -f $TmpFileForHealthyPods
    rm -f $TmpFileForDownPods
    trap - EXIT
}



node_resource_usage(){
    local tempdir=$logs_dir
    #myEcho "Collecting detailed resource usage for each node..."
    TmpFileForResource=$(mktemp /tmp/icpd-temp.XXXXXXXXXX)
    trap 'rm -f $TmpFileForResource' EXIT
    nodes=$(kubectl get node --no-headers -o custom-columns=NAME:.metadata.name)
    for node in $nodes; do
       echo "echo ' '" >> $TmpFileForResource
       echo "echo '### '" >> $TmpFileForResource
       echo "echo '### Rescoure usage for Node: $node ###'" >> $TmpFileForResource
       echo "kubectl describe node $node | sed '1,/Non-terminated Pods/d'" >> $TmpFileForResource
       echo "echo ' '" >> $TmpFileForResource
       echo "echo '### Disk usage for Node: $node ###'" >> $TmpFileForResource
       echo "ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=no \
                -o ConnectTimeout=10 -Tn $node 'du -h'" >> $TmpFileForResource
    done
    get_log_by_cmd $tempdir resource_usage_by_node "sh $TmpFileForResource"
    rm -f $TmpFileForResource
    trap - EXIT
}

pod_description_down_pods(){
    local tempdir=$logs_dir
    #myEcho "Collecting pod desciption for down pods..."
    tmpfile=$(mktemp /tmp/icpd-temp.XXXXXXXXXX)
    trap 'rm -f $tmpfile' EXIT
    kubectl get pods --all-namespaces --no-headers | grep -Ev '1/1 .* R|2/2 .* R|3/3 .* R|4/4 .* R|5/5 .* R|6/6 .* R' | grep -v 'Completed' | awk '{print "echo \"\n\n### Pod Name\" " $2 ";kubectl describe pod " $2 " --namespace="$1";"}' > $tmpfile
    get_log_by_cmd $tempdir down_pod_description "sh $tmpfile"
    rm -f $tmpfile
    trap - EXIT
}

component_log_collector(){
    local component=$COMPONENT
    local tempdir=$logs_dir
    local line=$LINE

    echo
    echo Collecting log for $component...
    echo -----------------------------
    pod_list=`kubectl get pods -n $ns --no-headers|egrep -i $component|awk '{print $1}'`
    for current_pod in `echo $pod_list`
    do
       container=`kubectl get pods -n $ns $current_pod -o jsonpath='{@.spec.containers[*].name}'`
       for cnt in `echo $container`
       do
          outfile=`echo "$component"PodLogs_"$name_space"_"$current_pod"_"$cnt"`
          cmd="kubectl logs -n $ns --tail=$line $current_pod -c $cnt"
          get_log_by_cmd $tempdir $outfile "$cmd"
       done
    done
}


check_log_file_exist() {
	local log_file=$1
	local name=$2
	if [ -f $log_file ]; then
                print_passed_message "$name collected:"
                #print_passed_message ""
        else
                print_failed_message "failed to collect $name"
        fi
}

get_log_by_cmd(){
	local temp_dir=$1
	local name=$2
	local cmd=$3
	local log_file=$temp_dir"/$name"
	eval $cmd > $log_file
	check_log_file_exist $log_file $name
}



get_container_log_by_name() {
    local temp_dir=$1
    local container_name=$2
    local log_file=$temp_dir"/"$container_name".log"
    local container_id=$(docker ps |grep $container_name|awk '{print $1}')
    docker logs $container_id >$log_file 2>&1
    
    if [ -f $log_file ]; then
        print_passed_message "$container_name log generated $log_file"
    else
        print_failed_message "failed to generate $container_name log:"
    fi
}


get_pod_log_by_name() {
    local temp_dir=$1
    local name=$2
    local name_space=$3
    local pod=$4
    local pod_dir=$5
    local log_file=$temp_dir"/$name.tar"

    kubectl exec -it -n $name_space $pod -- bash -c "tar cvf $pod_dir.tar $pod_dir*" &>/dev/null
    kubectl cp $name_space/$pod:$pod_dir.tar $log_file &>/dev/null
    check_log_file_exist $log_file $name
}


typeset -fx setup
typeset -fx sanity_checks
#typeset -fx log_collector $TEMP_DIR
typeset -fx log_collector
typeset -fx component_log_collector
typeset -fx check_log_file_exist
typeset -fx get_log_by_cmd
typeset -fx get_container_log_by_name
typeset -fx get_pod_log_by_name


TEMP_DIR=$1    ###sanjitc ####
