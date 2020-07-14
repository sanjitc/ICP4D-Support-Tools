#!/bin/bash

#### Global Variables ####
service_list=" wkc dv wsl ds ds-ent spark "
internal_registry="docker-registry.default.svc:5000/"
platform=`uname -p`

#### Functions ####
ValidateService()
{
   if [[ ! "${service_list}" =~ "${service}" ]]; then
      echo "Invalid service"
      exit 0
   fi
}

FindVersion()
{
   version_file=./${service}/assembly/${service}/${platform}/versions.yaml
   service_version=`grep -A1 "versions:" ./${version_file}|tail -1|awk '{print $2}'`
   echo "Service Version:  ${service_version}"
}

ValidateNamespace()
{
   if [[ ! `oc get project -o custom-columns=name:metadata.name` =~ "${ns}" ]]; then
      echo "Invalid project name"
      exit 0
   fi
}

FindOverrideFile()
{
   echo "What Storage Class you will use for install ${service} [nfs/ocs/portworx] ?"
   read sc

   if [[ $sc == "nfs" ]]; then
      ocerridefile=
   elif [[ $sc == "ocs" ]]; then
      ocerridefile=${service}-ocs-x86.yaml
   elif [[ $sc == "portworx" ]]; then
      ocerridefile=${service}-pwx-x86.yaml
   else
      echo "Invalid storage class"
      exit 0
   fi

   if [[ ! $sc == "nfs" ]] && [[ ! -f ./${ocerridefile} ]]; then
      echo "Override file not found. Create an overrride file ${ocerridefile} for install ${service}."
      exit 0
   fi
}


#### Main ####

echo "What service you want to install ?"
read service
ValidateService

echo "What you want to do with $service [download/admin/load/install] ?"
read operation

echo "Enter project name where you will install ${service} :"
read ns
ValidateNamespace

if [[ $operation == "download" ]]; then
   ./cpd-linux preloadImages \
     --repo repo.yaml \
     --assembly ${service} \
     --action download \
     --download-path ./${service} \
     --accept-all-licenses
elif [[ $operation == "load" ]]; then
   FindVersion
   ./cpd-linux preloadImages \
     --action push \
     --load-from=./${service} \
     --transfer-image-to=${internal_registry}${ns} \
     --target-registry-username=$(oc whoami) \
     --target-registry-password=$(oc whoami -t) \
     --assembly ${service} \
     --version ${service_version} \
     --accept-all-licenses
elif [[ $operation == "admin" ]]; then
   FindVersion
   ./cpd-linux adm \
     --repo repo.yaml \
     --assembly ${service} \
     --version ${service_version} \
     --arch ${platform} \
     --namespace ${ns} \
     --accept-all-licenses \
     --apply
elif [[ $operation == "install" ]]; then
   FindVersion
   FindOverrideFile
   if [[ $sc == "nfs" ]]; then
      ./cpd-linux \
        --assembly ${service} \
        --namespace ${ns} \
        --storageclass managed-nfs-storage \
        --cluster-pull-prefix=${internal_registry}${ns} \
        --cluster-pull-username=$(oc whoami) \
        --cluster-pull-password=$(oc whoami -t) \
        --version ${service_version} \
        --load-from=./${service} \
        --accept-all-licenses 
   elif [[ $sc == "ocs" ]]; then
      storageclass=ocs-storagecluster-cephfs
      ./cpd-linux \
        --assembly ${service} \
        --namespace ${ns} \
        --storageclass ocs-storagecluster-cephfs \
        --override ${ocerridefile} \
        --cluster-pull-prefix=${internal_registry}${ns} \
        --cluster-pull-username=$(oc whoami) \
        --cluster-pull-password=$(oc whoami -t) \
        --version ${service_version} \
        --load-from=./${service} \
        --accept-all-licenses 
   elif [[ $sc == "portworx" ]]; then
      ./cpd-linux \
        --assembly ${service} \
        --namespace ${ns} \
        --storageclass portworx-shared-gp3 \
        --override ${ocerridefile} \
        --cluster-pull-prefix=${internal_registry}${ns} \
        --cluster-pull-username=$(oc whoami) \
        --cluster-pull-password=$(oc whoami -t) \
        --version ${service_version} \
        --load-from=./${service} \
        --accept-all-licenses 
   fi
fi

