## Kibana/Grafana Dashboard creation 


###### Usage:


```` 
$ cd dashboard
$ sh ./icp4d-dashbord.sh
````
The above command will create IBM Cloud private for Data dashboards in Grafana and Kibana.

Note:  It uses the default icp admin id and password.  icp_user/icp_password environment variable can be used 
to set alternative user/password.

###### Accessing the Dashboard

    Kibana URL:   https://mycluster.icp:8443/kibana
    Grafana URL:  https://mycluster.icp:8443/grafana

To access above links, users should add cluster IP address in client machine's /etc/hosts under domain name "mycluster.icp"
    ####### For Linux and Mac clients:
    /etc/host
 
    <ip address>  mycluster.icp
    
    ####### For Windows clients:
    C:\Windows\System32\Drivers\etc\hosts
    <ip address>  mycluster.icp
   
Note: You need admin permission to edit this file.
