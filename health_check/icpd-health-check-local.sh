#!/bin/bash
# Run health check locally on a single worker node


#Acceptable time difference (milliseconds) between nodes.
NODE_TIMEDIFF=400

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
    echo Running heath check locally on ICP for Data ...
    #echo ICP Version: $PRODUCT_VERSION
    #echo Release Date: $RELEASE_DATE
    echo =============================================================
}

health_check() {
    local temp_dir=$1
    current_node=`hostname -i|awk '{print $1}'`
    #master_nodes=`get_master_nodes $CONFIG_DIR|awk '{print $1}'`
    #all_nodes=`get_master_nodes $CONFIG_DIR|awk '{print $1}'; 
    #get_worker_nodes $CONFIG_DIR|awk '{print $1}'`
    #IsMaster=`is_master_node $CONFIG_DIR "$current_node"`
    IsMaster=""

        echo
        echo Checking node availability...
        echo ------------------------
        for i in `echo $all_nodes`
        do
            ping -w 30 -c 1 $i > /dev/null
            if [ $? -eq 0 ]; then
               echo -e Ping to node $i ${COLOR_GREEN}\[OK\]${COLOR_NC}
            else 
               echo -e Ping to node $i ${COLOR_RED}\[FAILED\]${COLOR_NC}
            fi
        done

        echo
        echo Checking time difference between nodes...
        echo ------------------------
        for i in `echo $all_nodes`
        do

            diff=`clockdiff $i | awk '{print $3}'`
            (( diff = $diff < 0 ? $diff * -1 : $diff ))
            if [ $diff -lt  $NODE_TIMEDIFF ]; then
               echo -e Time Diff with node $i ${COLOR_GREEN}\[OK\]${COLOR_NC}
            else
               echo -e Time diff with node $i ${COLOR_RED}\[FAILED\]${COLOR_NC}
            fi
        done

        echo
        echo Checking Docker status...
        echo ------------------------
        systemctl status docker|egrep 'Active:'|egrep 'running' > /dev/null 2>&1
        if [ $? -eq 0 ]; then
           echo -e Docker status on node $i ${COLOR_GREEN}\[OK\]${COLOR_NC}
        else 
           echo -e Docker status on node $i ${COLOR_RED}\[FAILED\]${COLOR_NC}
        fi

        echo
        echo Checking Kubelet status...
        echo ------------------------
        systemctl status kubelet|egrep 'Active:'|egrep 'running' > /dev/null 2>&1
        if [ $? -eq 0 ]; then
           echo -e Kubelet status on node $i ${COLOR_GREEN}\[OK\]${COLOR_NC}
        else 
           echo -e Kubelet status on node $i ${COLOR_RED}\[FAILED\]${COLOR_NC}
        fi

        echo
        echo Checking Glusterd status...
        echo ------------------------
        systemctl status glusterd|egrep 'Active:'|egrep 'running' > /dev/null 2>&1
        if [ $? -eq 0 ]; then
           echo -e Glusterd status on node $i ${COLOR_GREEN}\[OK\]${COLOR_NC}
        else 
           echo -e Glusterd status on node $i ${COLOR_RED}\[FAILED\]${COLOR_NC}
        fi

        echo
        echo Checking Docker availability...
        echo ------------------------
        docker ps --format '{{.Image}}' > /dev/null 2>&1
        if [ $? -eq 0 ]; then
           echo -e Docker running on node $i ${COLOR_GREEN}\[OK\]${COLOR_NC}
        else 
           echo -e Docker running on node $i ${COLOR_RED}\[FAILED\]${COLOR_NC}
        fi

        if [ "$IsMaster" ]; then
            echo
            echo Checking Docker registry...
            echo ------------------------
            ls /var/lib/registry > /dev/null 2>&1
            if [ $? -eq 0 ]; then
               echo -e Docker registry mounted on node $i ${COLOR_GREEN}\[OK\]${COLOR_NC}
            else 
               echo -e Docker registry mounted on node $i ${COLOR_RED}\[FAILED\]${COLOR_NC}
            fi
        fi

        if [ "$IsMaster" ]; then
            echo
            echo Checking PVCs on all namespaces...
            echo ------------------------
            down_pvc_count=$(kubectl get pvc --all-namespaces --no-headers|egrep -vw 'Bound|Available'|wc -l)
            if [ $down_pvc_count -gt 0 ]; then
                echo -e Not all PVCs are healthy ${COLOR_RED}\[FAILED\]${COLOR_NC}
                kubectl get pvc --all-namespaces
                #exit 1
            else
                echo -e All PVCs are healthy ${COLOR_GREEN}\[OK\]${COLOR_NC}
            fi
        fi

        echo
        echo Checking gluster volumes...
        echo ------------------------
        down_gluster_count=$(gluster volume info|egrep "Status:"|egrep -vw 'Started'|wc -l)
        if [ $down_gluster_count -gt 0 ]; then
            echo -e Not all gluster volumes are started ${COLOR_RED}\[FAILED\]${COLOR_NC}
            gluster volume info|egrep "Status:"
            #exit 1
        else
            echo -e All gluster volumes are started ${COLOR_GREEN}\[OK\]${COLOR_NC}
        fi

        if [ "$IsMaster" ]; then
            echo
            echo Checking pod status...
            echo ------------------------
            down_pod_count=$(kubectl get pods --all-namespaces --no-headers| grep -Ev '1/1 .* R|2/2 .* R|3/3 .* R|4/4 .* R|5/5 .* R|6/6 .* R' | grep -v 'Completed' |wc -l)
            if [ $down_pod_count -gt 0 ]; then
                echo -e Not all pods are ready ${COLOR_RED}\[FAILED\]${COLOR_NC}
                kubectl get pods --all-namespaces | grep -Ev '1/1 .* R|2/2 .* R|3/3 .* R|4/4 .* R|5/5 .* R|6/6 .* R' | grep -v 'Completed'  
            else
                echo -e All pods are ready ${COLOR_GREEN}\[OK\]${COLOR_NC}
            fi
        fi

        if [ "$IsMaster" ]; then
            echo
            echo Checking end-user deployments status...
            echo ------------------------
            user_deployments="spss-modeler-server|zeppelin-server|dods-processor-server|wex-server|shaper-server|rstudio-server|jupyter-server|jupyter-py36-server|jupyter-py35-server"
            older_pod_count=$(kubectl get pods --all-namespaces -o go-template --template '{{range .items}}{{.metadata.namespace}}|{{.metadata.name}}|{{.metadata.creationTimestamp}}{{"\n"}}{{end}}'|\
            awk '$3 <= "'$(date -d 'yesterday' -Ins --utc | sed 's/+0000/Z/')'" { print $1 }'|egrep "$user_deployments"|wc -l)
            if [ $older_pod_count -gt 0 ]; then
                echo -e Some end-user deployment pods running longer than 24 hrs ${COLOR_RED}\[WARNING\]${COLOR_NC}
                kubectl get pods --all-namespaces -o go-template --template '{{range .items}}{{.metadata.namespace}}|{{.metadata.name}}|{{.metadata.creationTimestamp}}{{"\n"}}{{end}}'|\
                awk '$3 <= "'$(date -d 'yesterday' -Ins --utc | sed 's/+0000/Z/')'" { print $1 }'|egrep "$user_deployments"
            else
                echo -e No end-user deployment pods running longer than 24 hrs ${COLOR_GREEN}\[OK\]${COLOR_NC}
            fi
        fi

		
        if [ "$IsMaster" ]; then
	    echo
	    echo Checking Disk Status for Nodes ...
	    echo ------------------------
		
            nodes=$(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name)
     
            for node in $nodes; do
	    
	        disk=$(kubectl describe  node $node | grep 'OutOfDisk        False' |  wc -l)
	        if [ $disk -eq 0 ]; then
	            echo -e Node $node is out of Disk Space ${COLOR_RED}\[FAILED\]${COLOR_NC}
	        else	
                    echo -e Node $node has sufficient disk space ${COLOR_GREEN}\[OK\]${COLOR_NC}
	        fi
	    done
        fi
		
        if [ "$IsMaster" ]; then
	    echo
	    echo Checking Memory Status for Nodes ...
	    echo ------------------------
	    for node in $nodes; do
		
	        mem=$(kubectl describe  node $node | grep 'MemoryPressure   False' |  wc -l)
	        if [ $mem -eq 0 ]; then
	            echo -e Node $node is out of Memory ${COLOR_RED}\[FAILED\]${COLOR_NC}
	        else	
	            echo -e Node $node has sufficient memory available ${COLOR_GREEN}\[OK\]${COLOR_NC}
	        fi
	    done
        fi
		
        if [ "$IsMaster" ]; then
		echo
		echo Checking Disk Pressure for Nodes ...
		echo ------------------------
		for node in $nodes; do
			dp=$(kubectl describe  node $node | grep 'DiskPressure     False' |  wc -l)
			if [ $dp -eq 0 ]; then
				echo -e Node $node has disk pressure ${COLOR_RED}\[FAILED\]${COLOR_NC}
			else	
			    echo -e Node $node has no disk pressure ${COLOR_GREEN}\[OK\]${COLOR_NC}
			fi
			
		done
        fi
			
        if [ "$IsMaster" ]; then
	    echo
	    echo Checking Disk PID Pressure for Nodes ...
	    echo ------------------------
	    for node in $nodes; do
	        pid=$(kubectl describe  node $node | grep 'PIDPressure      False' |  wc -l)
	        if [ $pid -eq 0 ]; then
	            echo -e Node $node has PID pressure ${COLOR_RED}\[FAILED\]${COLOR_NC}
	        else	
                    echo -e Node $node has sufficient PID available ${COLOR_GREEN}\[OK\]${COLOR_NC}
	        fi
	    done	
        fi
   
        if [ "$IsMaster" ]; then
	    echo
	    echo Checking CPU usage for Nodes ...
	    echo ------------------------
	    for node in $nodes; do
                cpu=$(kubectl top node $node|grep $node|awk '{print $3}'|awk -F "%" '{print $1}')
	        if [ $cpu -gt 80 ]; then
	            echo -e Node $node has CPU pressure ${COLOR_RED}\[WARNING\]${COLOR_NC}
                    kubectl top  node $node
	        else	
                    echo -e Node $node has sufficient CPU available ${COLOR_GREEN}\[OK\]${COLOR_NC}
	        fi
	    done	
        fi
}




check_log_file_exist() {
        local log_file=$1
        local name=$2
        if [ -f $log_file ]; then
                print_passed_message "$name collected: $log_file"
        else
                print_failed_message "failed to collect $name"
        fi
}

health_check_by_cmd(){
        local temp_dir=$1
        local name=$2
        local cmd=$3
        local log_file=$temp_dir"/$name"
        $cmd > $log_file
        check_log_file_exist $log_file $name
}

TEMP_DIR=$1
setup
#sanity_checks  # sanity_checks should be off for run health check locally
health_check
