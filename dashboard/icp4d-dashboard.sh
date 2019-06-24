#!/bin/bash
#################################################################################################
# Licensed Materials - Property of IBM
# (c) Copyright IBM Corporation 2017. All Rights Reserved.
#
# Note to U.S. Government Users Restricted Rights:
# Use, duplication or disclosure restricted by GSA ADP Schedule
# Contract with IBM Corp.
#

# ./icp4d-dashboard.sh 
# This script is for cconfiguring Kibana, Grafana Dashboards for IBM cloud private for Data
#################################################################################################

icp_user=${icp_user:-"admin"}
icp_password=${icp_password:-"admin"}
KIBANA_JSON=${KIBANA_JSON:-"icp4d-kibana-dashboard-1.2.0.json"}
GRAFANA_JSON=${GRAFANA_JSON:-"icp4d-grafana-dashboard-1.2.0.json"}
GRAFANA_DS_JSON=${GRAFANA_DS_JSON:-"icp4d-grafana-datasource-1.2.0.json"}

if [[ ! -f ${KIBANA_JSON} ]]; then
    echo "Kibana dashboard file ${KIBANA_JSON} does not exist"
    exit 1
fi

if [[ ! -f ${GRAFANA_JSON} ]]; then
    echo "Grafana dashboard file ${GRAFANA_JSON} does not exist"
    exit 1
fi

if [[ ! -f ${GRAFANA_DS_JSON} ]]; then
    echo "Grafana data source file ${GRAFANA_DS_JSON} does not exist"
    exit 1
fi


usage() {
  echo "Usage: sh icp4d-dashboard.sh"
  echo "if environment variables values are not set, then"
  echo "use the following default values."
  echo "Default values:"
  echo '      icp_user="admin"; icp_password="admin"'
  echo '      KIBANA_JSON="icp4d-kibana-dashboard-1.2.0.json"'
  echo '      GRAFANA_JSON="icp4d-grafana-dashboard-1.2.0.json"'
  exit 0
}

access_token() {
 tokens=`curl -s -H 'Content-Type: application/x-www-form-urlencoded;charset=UTF-8' -d "grant_type=password&username=$icp_user&password=$icp_password&scope=openid" https://mycluster.icp:8443/idprovider/v1/auth/identitytoken --insecure`  > /dev/null
 ACCESS_TOKEN=$(echo $tokens | python -c 'import sys,json; print json.load(sys.stdin)["access_token"]' )
}
import_kibana() {
    curl -u elastic:changeme  -k -XPOST -H 'Content-Type: application/json' -H "kbn-xsrf: true" -H "Authorization:Bearer $ACCESS_TOKEN" https://mycluster.icp:8443/kibana/api/kibana/dashboards/import  -d @$KIBANA_JSON  > /dev/null
}

import_grafana_datasource() {
    curl -k -s -X POST -H "Content-Type: application/json" -H "Authorization:Bearer $ACCESS_TOKEN" https://mycluster.icp:8443/grafana/api/datasources -d @$GRAFANA_DS_JSON  >/dev/null
}

import_grafana() {
    curl -k -s -X POST -H 'Content-Type: application/json' -H "Authorization:Bearer $ACCESS_TOKEN" https://mycluster.icp:8443/grafana/api/dashboards/db -d @$GRAFANA_JSON  > /dev/null
}

onSuccess() {
echo "*******************************************************************************"
echo "Grafana dashboard: https://mycluster.icp:8443/grafana"
echo "Kibana dashboard: https://mycluster.icp:8443/kibana"
echo "please add cluster IP to your  /etc/hosts under domain name mycluser.icp"
echo "example: echo \"xxx.xxx.xxx.xxx  mycluster.icp\""
echo "********************************************************************************"
}


#Start import dashboards
access_token
import_kibana
import_grafana_datasource
import_grafana
onSuccess
