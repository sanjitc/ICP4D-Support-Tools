# ICP4D Serviceability CLI Tool

icp4d_tools.sh is a command line utlity to host all of the troubleshooting and serviceability tooling around ICP4D. The tool must be run from the first master node of an existing installed ICP4D cluster.

```

Usage:
./icp4d_tools.sh [OPTIONS]

  OPTIONS:
       --preinstall: Run pre-installation requirements checks (CPU, RAM, and Disk space, etc.)
          --type=master|worker: If the current node will be master or worker. For add-ons, choose worker
          --install_dir=<install directory>
          --data_dir=<data directory> mandatory for worker node
       --health: Run post-installation cluster health checker
       --health=local: Run post-installation health check locally on individual node
       --collect=smart|standard: Run log collection tool to collect diagnostics and logs files from every pod/container. Default is smart
          --component=db2,dsx,dv: Run DB2 Hand log collection,DSX, Data Virtualization Diagnostics logs collection.
                      Works with --collect=standard option
          --persona=c,a,o: Runs a focused log collection from specific pods related to a personas Collect, Organize and Analyze. Works with --collect=standard option
          --line=N: Capture N number of rows from pod log
          --namespace=xx,yy,zz: Run the tool in context of the provided namespaces. By default 'zen' namespace is always included. 
       --help: Prints this message

  EXAMPLES:
      ./icp4d_tools.sh --preinstall --type=worker --install_dir=/ibm --data_dir=/data
      ./icp4d_tools.sh --health
      ./icp4d_tools.sh --health=local
      ./icp4d_tools.sh --collect=smart
      ./icp4d_tools.sh --collect=standard --component=db2,dsx,dv
      ./icp4d_tools.sh --collect=standard --persona=c,a

```
