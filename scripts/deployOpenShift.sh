#!/bin/bash

echo $(date) " - Starting Script"

set -e

SUDOUSER=$1
PASSWORD="$2"
PRIVATEKEY=$3
MASTER=$4
MASTERPUBLICIPHOSTNAME=$5
MASTERPUBLICIPADDRESS=$6
INFRA=$7
NODE=$8
NODECOUNT=$9
MASTERCOUNT=${10}
ROUTING=${11}
BASTION=$(hostname -f)
AADCLIENTID=${12}
AADCLIENTSECRET="${13}"
TENANTID=${14}
SUBSCRIPTIONID=${15}
RESOURCEGROUP=${16}
LOCATION=${17}
VNETNAME=${18}
STORAGEACCOUNTNAME=${19}
INSTALLMETRICS=${20}
INSTALLLOGGING=${21}
INSTALLPROMETHEUS=${22}
INSTALLSERVICEBROKERS=${23}
SERVICEPRINCIPALURL=${24}

DOMAIN=$( awk 'NR==2' /etc/resolv.conf | awk '{ print $2 }' )

echo $(date) " - Fixing internal DNS names"

# Install Azure client
rpm --import https://packages.microsoft.com/keys/microsoft.asc
sh -c 'echo -e "[azure-cli]\nname=Azure CLI\nbaseurl=https://packages.microsoft.com/yumrepos/azure-cli\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/azure-cli.repo'
yum install azure-cli -y

# Login using VM's system identity
az login --service-principal -u $SERVICEPRINCIPALURL -p $AADCLIENTSECRET --tenant $TENANTID

az account set -s $SUBSCRIPTIONID

# Fix the internal DNS names
MASTERLOOP=$((MASTERCOUNT - 1))
NODELOOP=$((NODECOUNT - 1))

for (( c=0; c<=$MASTERLOOP; c++)); do
  az network nic update -g $RESOURCEGROUP -n $MASTER${c}nic --internal-dns-name $MASTER-$c
done

for (( c=0; c<=$MASTERLOOP; c++)); do
    az network nic update -g $RESOURCEGROUP -n $INFRA${c}nic --internal-dns-name $INFRA-$c
done

for (( c=0; c<=$NODELOOP; c++)); do
    az network nic update -g $RESOURCEGROUP -n $NODE${c}nic --internal-dns-name $NODE-$c
done


# Generate private keys for use by Ansible
echo $(date) " - Generating Private keys for use by Ansible for OpenShift Installation"
runuser -l $SUDOUSER -c "echo \"$PRIVATEKEY\" > ~/.ssh/id_rsa"
runuser -l $SUDOUSER -c "chmod 600 ~/.ssh/id_rsa*"

echo $(date) " - Generating Ansible config file"
# Create ansible config file
cat > /etc/ansible/ansible.cfg <<EOF
[defaults]
forks = 20
host_key_checking = False
remote_user = ${SUDOUSER}
roles_path = roles/
library = /usr/share/ansible/openshift-ansible/roles/lib_utils/library
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /home/${SUDOUSER}
fact_caching_timeout = 600
log_path = /home/${SUDOUSER}/ansible.log
nocows = 1
callback_whitelist = profile_tasks

[privilege_escalation]
become = True

[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=600s
control_path = %(directory)s/%%h-%%r
pipelining = True
timeout = 10
EOF

# Create Ansible Playbook for Post Installation task
echo $(date) " - Create Ansible Playbook for Post Installation task"

# Run on all nodes
cat > /home/${SUDOUSER}/preinstall.yml <<EOF
---
- hosts: nodes
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Create OpenShift Users"
  tasks:
  - name: copy hosts file
    copy:
      src: /tmp/hosts
      dest: /etc/hosts
      owner: root
      group: root
      mode: 0644
EOF

# Run on all masters
cat > /home/${SUDOUSER}/postinstall.yml <<EOF
---
- hosts: masters
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Create OpenShift Users"
  tasks:
  - name: create directory
    file: path=/etc/origin/master state=directory
  - name: add initial OpenShift user
    shell: htpasswd -cb /etc/origin/master/htpasswd ${SUDOUSER} "${PASSWORD}"
EOF

# Run on only MASTER-0
cat > /home/${SUDOUSER}/postinstall2.yml <<EOF
---
- hosts: firstmaster
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Make user cluster admin"
  tasks:
  - name: make OpenShift user cluster admin
    shell: oadm policy add-cluster-role-to-user cluster-admin $SUDOUSER --config=/etc/origin/master/admin.kubeconfig
EOF

# Run on all nodes
cat > /home/${SUDOUSER}/postinstall3.yml <<EOF
---
- hosts: nodes
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Set password for Cockpit"
  tasks:
  - name: configure Cockpit password
    shell: echo "${PASSWORD}"|passwd root --stdin
EOF


# Run on all masters
cat > /home/${SUDOUSER}/postinstall4.yml <<EOF
---
- hosts: masters
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Unset default registry DNS name"
  tasks:
  - name: copy atomic-openshift-master file
    copy:
      src: /tmp/atomic-openshift-master
      dest: /etc/sysconfig/atomic-openshift-master
      owner: root
      group: root
      mode: 0644
EOF

# Create vars.yml file for use by setup-azure-config.yml playbook

cat > /home/${SUDOUSER}/vars.yml <<EOF
g_tenantId: $TENANTID
g_subscriptionId: $SUBSCRIPTIONID
g_aadClientId: $AADCLIENTID
g_aadClientSecret: $AADCLIENTSECRET
g_resourceGroup: $RESOURCEGROUP
g_location: $LOCATION
g_vnetName: $VNETNAME
EOF

# Create Azure Cloud Provider configuration Playbook for Single Master Cluster

cat > /home/${SUDOUSER}/setup-azure-config-single-master.yml <<EOF
#!/usr/bin/ansible-playbook 
- hosts: masters
  gather_facts: no
  vars_files:
  - vars.yml
  become: yes
  vars:
    azure_conf_dir: /etc/azure
    azure_conf: "{{ azure_conf_dir }}/azure.conf"
    master_conf: /etc/origin/master/master-config.yaml
  handlers:
  - name: restart atomic-openshift-master-controllers
    systemd:
      state: restarted
      name: atomic-openshift-master-controllers
  - name: restart atomic-openshift-master-api
    systemd:
      state: restarted
      name: atomic-openshift-master-api      
  post_tasks:
  - name: make sure /etc/azure exists
    file:
      state: directory
      path: "{{ azure_conf_dir }}"
  - name: populate /etc/azure/azure.conf
    copy:
      dest: "{{ azure_conf }}"
      content: |
        aadClientID: {{ g_aadClientId }}
        aadClientSecret: {{ g_aadClientSecret }}
        subscriptionID: {{ g_subscriptionId }}
        tenantId: {{ g_tenantId }}
        aadtenantId: {{ g_tenantId }}
        resourceGroup: {{ g_resourceGroup }}
        location: {{ g_location }}
    notify:
    - restart atomic-openshift-master-controllers
    - restart atomic-openshift-master-api
  - name: insert the azure disk config into the master
    modify_yaml:
      dest: "{{ master_conf }}"
      yaml_key: "{{ item.key }}"
      yaml_value: "{{ item.value }}"
    with_items:
    - key: kubernetesMasterConfig.apiServerArguments.cloud-config
      value:
      - "{{ azure_conf }}"
    - key: kubernetesMasterConfig.apiServerArguments.cloud-provider
      value:
      - "azure"
    - key: kubernetesMasterConfig.controllerArguments.cloud-config
      value:
      - "{{ azure_conf }}"
    - key: kubernetesMasterConfig.controllerArguments.cloud-provider
      value:
      - "azure"
    notify:
    - restart atomic-openshift-master-controllers
    - restart atomic-openshift-master-api
- hosts: nodes
  gather_facts: no
  vars_files:
  - vars.yml
  become: yes
  vars:
    azure_conf_dir: /etc/azure
    azure_conf: "{{ azure_conf_dir }}/azure.conf"
    node_conf: /etc/origin/node/node-config.yaml
  handlers:
  - name: restart atomic-openshift-node
    systemd:
      state: restarted
      name: atomic-openshift-node
  post_tasks:
  - name: make sure /etc/azure exists
    file:
      state: directory
      path: "{{ azure_conf_dir }}"
  - name: populate /etc/azure/azure.conf
    copy:
      dest: "{{ azure_conf }}"
      content: |
        aadClientID: {{ g_aadClientId }}
        aadClientSecret: {{ g_aadClientSecret }}
        subscriptionID: {{ g_subscriptionId }}
        tenantId: {{ g_tenantId }}
        aadtenantId: {{ g_tenantId }}
        resourceGroup: {{ g_resourceGroup }}
        location: {{ g_location }}
  - name: insert the azure disk config into the node
    modify_yaml:
      dest: "{{ node_conf }}"
      yaml_key: "{{ item.key }}"
      yaml_value: "{{ item.value }}"
    with_items:
    - key: kubeletArguments.cloud-config
      value:
      - "{{ azure_conf }}"
    - key: kubeletArguments.cloud-provider
      value:
      - "azure"
    notify:
    - restart atomic-openshift-node
EOF

# Create Azure Cloud Provider configuration Playbook for Multi-Master Cluster

cat > /home/${SUDOUSER}/setup-azure-config-multiple-master.yml <<EOF
#!/usr/bin/ansible-playbook 
- hosts: masters
  gather_facts: no
  vars_files:
  - vars.yml
  become: yes
  vars:
    azure_conf_dir: /etc/azure
    azure_conf: "{{ azure_conf_dir }}/azure.conf"
    master_conf: /etc/origin/master/master-config.yaml
  handlers:
  - name: restart atomic-openshift-master-api
    systemd:
      state: restarted
      name: atomic-openshift-master-api
  - name: restart atomic-openshift-master-controllers
    systemd:
      state: restarted
      name: atomic-openshift-master-controllers
  post_tasks:
  - name: make sure /etc/azure exists
    file:
      state: directory
      path: "{{ azure_conf_dir }}"
  - name: populate /etc/azure/azure.conf
    copy:
      dest: "{{ azure_conf }}"
      content: |
        aadClientID: {{ g_aadClientId }}
        aadClientSecret: {{ g_aadClientSecret }}
        subscriptionID: {{ g_subscriptionId }}
        tenantId: {{ g_tenantId }}
        aadtenantId: {{ g_tenantId }}
        resourceGroup: {{ g_resourceGroup }}
        location: {{ g_location }}
  - name: insert the azure disk config into the master
    modify_yaml:
      dest: "{{ master_conf }}"
      yaml_key: "{{ item.key }}"
      yaml_value: "{{ item.value }}"
    with_items:
    - key: kubernetesMasterConfig.apiServerArguments.cloud-config
      value:
      - "{{ azure_conf }}"
    - key: kubernetesMasterConfig.apiServerArguments.cloud-provider
      value:
      - "azure"
    - key: kubernetesMasterConfig.controllerArguments.cloud-config
      value:
      - "{{ azure_conf }}"
    - key: kubernetesMasterConfig.controllerArguments.cloud-provider
      value:
      - "azure"
    notify:
    - restart atomic-openshift-master-api
    - restart atomic-openshift-master-controllers
- hosts: nodes
  gather_facts: no
  vars_files:
  - vars.yml
  become: yes
  vars:
    azure_conf_dir: /etc/azure
    azure_conf: "{{ azure_conf_dir }}/azure.conf"
    node_conf: /etc/origin/node/node-config.yaml
  handlers:
  - name: restart atomic-openshift-node
    systemd:
      state: restarted
      name: atomic-openshift-node
  post_tasks:
  - name: make sure /etc/azure exists
    file:
      state: directory
      path: "{{ azure_conf_dir }}"
  - name: populate /etc/azure/azure.conf
    copy:
      dest: "{{ azure_conf }}"
      content: |
        aadClientID: {{ g_aadClientId }}
        aadClientSecret: {{ g_aadClientSecret }}
        subscriptionID: {{ g_subscriptionId }}
        tenantId: {{ g_tenantId }}
        aadtenantId: {{ g_tenantId }}
        resourceGroup: {{ g_resourceGroup }}
        location: {{ g_location }}
  - name: insert the azure disk config into the node
    modify_yaml:
      dest: "{{ node_conf }}"
      yaml_key: "{{ item.key }}"
      yaml_value: "{{ item.value }}"
    with_items:
    - key: kubeletArguments.cloud-config
      value:
      - "{{ azure_conf }}"
    - key: kubeletArguments.cloud-provider
      value:
      - "azure"
    notify:
    - restart atomic-openshift-node
EOF

# Create Ansible Hosts File
echo $(date) " - Create Ansible Hosts file"

if [ $MASTERCOUNT -eq 1 ]
then

cat > /etc/ansible/hosts <<EOF
# Create an OSEv3 group that contains the masters and nodes groups
[OSEv3:children]
masters
etcd
nodes

# Set variables common for all OSEv3 hosts
[OSEv3:vars]
ansible_ssh_user=$SUDOUSER
ansible_become=yes
openshift_install_examples=true
deployment_type=openshift-enterprise
docker_udev_workaround=true
openshift_use_dnsmasq=true
# Weird error when installing single master cluster fails on docker version, even though correct
openshift_disable_check=disk_availability,package_version,package_update,memory_availability,disk_availability,docker_storage,docker_storage_driver
openshift_master_default_subdomain=$ROUTING
openshift_set_hostname=true
osm_use_cockpit=true
os_sdn_network_plugin_name='redhat/openshift-ovs-multitenant'

# Enable CRI-O
openshift_use_crio=true
openshift_crio_enable_docker_gc=true

# Deploy Prometheus
openshift_hosted_prometheus_deploy=false
openshift_prometheus_namespace=openshift-metrics
openshift_prometheus_node_selector={"region":"infra"}
openshift_prometheus_storage_kind=dynamic
openshift_prometheus_storage_volume_name=prometheus
openshift_prometheus_storage_volume_size=8Gi
openshift_prometheus_storage_type='pvc'
openshift_prometheus_alertmanager_storage_kind=dynamic
openshift_prometheus_alertmanager_storage_volume_name=prometheus-alertmanager
openshift_prometheus_alertmanager_storage_volume_size=1Gi
openshift_prometheus_alertmanager_storage_type='pvc'
openshift_prometheus_alertbuffer_storage_kind=dynamic
openshift_prometheus_alertbuffer_storage_volume_name=prometheus-alertbuffer
openshift_prometheus_alertbuffer_storage_volume_size=1Gi
openshift_prometheus_alertbuffer_storage_type='pvc'

# apply updated node defaults
openshift_node_kubelet_args={'pods-per-core': ['10'], 'max-pods': ['250'], 'image-gc-high-threshold': ['90'], 'image-gc-low-threshold': ['80']}

# enable ntp on masters to ensure proper failover
openshift_clock_enabled=true

# Configure master API and console ports.
openshift_master_api_port=443
openshift_master_console_port=443

openshift_master_cluster_hostname=$MASTERPUBLICIPHOSTNAME
openshift_master_cluster_public_hostname=$MASTERPUBLICIPHOSTNAME
#openshift_master_cluster_public_vip=$MASTERPUBLICIPADDRESS

# Enable HTPasswdPasswordIdentityProvider
openshift_master_identity_providers=[{'name': 'htpasswd_auth', 'login': 'true', 'challenge': 'true', 'kind': 'HTPasswdPasswordIdentityProvider', 'filename': '/etc/origin/master/htpasswd'}]

# Setup Default Storage Class
openshift_storageclass_name=azure
openshift_storageclass_default=true
openshift_storageclass_parameters='kubernetes.io/azure-disk'
openshift_storageclass_provisioner='storageaccounttype: Standard_LRS\nkind: Shared'

# Setup metrics
openshift_master_metrics_public_url=https://hawkular-metrics.$ROUTING/hawkular/metrics
openshift_metrics_install_metrics=false
openshift_metrics_hawkular_hostname=hawkular-metrics.$ROUTING
openshift_metrics_hawkular_nodeselector={"region":"infra"}
openshift_metrics_cassandra_nodeselector={"region":"infra"}
openshift_metrics_heapster_nodeselector={"region":"infra"}
openshift_metrics_cassandra_pvc_size=10Gi
openshift_metrics_cassandra_storage_type=dynamic

# Setup logging
openshift_master_logging_public_url=https://kibana.$ROUTING
openshift_logging_master_public_url=https://$MASTERPUBLICIPHOSTNAME
openshift_logging_use_ops=false
openshift_logging_namespace=logging
openshift_logging_install_logging=false
openshift_logging_kibana_hostname=kibana.$ROUTING
openshift_logging_es_nodeselector={"region":"infra"}
openshift_logging_curator_nodeselector={"region":"infra"}
openshift_logging_kibana_nodeselector={"region":"infra"}
openshift_logging_fluentd_nodeselector={"zone":"default"}
openshift_logging_es_pvc_size=10Gi
openshift_logging_es_pvc_dynamic=true

# Setup service catalog and brokers
openshift_enable_service_catalog=false
ansible_service_broker_install=false
template_service_broker_install=false
dynamic_volumes_check=false
openshift_service_catalog_image_version=latest
ansible_service_broker_image_prefix=registry.access.redhat.com/openshift3/ose-
ansible_service_broker_registry_url="registry.access.redhat.com"
openshift_service_catalog_image_prefix=registry.access.redhat.com/openshift3/ose-
template_service_broker_selector={"region":"infra"}
openshift_template_service_broker_namespaces=['openshift']
openshift_hosted_etcd_storage_kind=dynamic
openshift_hosted_etcd_storage_volume_name=etcd-vol
openshift_hosted_etcd_storage_access_modes=["ReadWriteOnce"]
openshift_hosted_etcd_storage_volume_size=1Gi
openshift_hosted_etcd_storage_labels={'storage': 'etcd'}

# host group for masters
[masters]
$MASTER-0

[etcd]
$MASTER-0

# host group for nodes
[nodes]
$MASTER-0 openshift_hostname=$MASTER-0 openshift_node_labels="{'region': 'master', 'zone': 'default'}"
# runtime: cri-o is a fix for https://bugzilla.redhat.com/show_bug.cgi?id=1553452
$INFRA-0 openshift_hostname=$INFRA-0 openshift_node_labels="{'region': 'infra', 'zone': 'default', 'runtime': 'cri-o'}"
EOF
for node in $NODE-{0..30}; do
	echo $(ping -c 1 $node 2>/dev/null|grep $NODE|grep PING|awk '{ print $2 }'|cut -d"." -f1) openshift_hostname=$(ping -c 1 $node 2>/dev/null|grep ocp|grep PING|awk '{ print $2 }'|cut -d"." -f1) openshift_node_labels=\"{\'region\': \'nodes\', \'zone\': \'default\', \'runtime\': \'cri-o\'}\"
done|grep $NODE >>/etc/ansible/hosts

else

cat > /etc/ansible/hosts <<EOF
# Create an OSEv3 group that contains the masters and nodes groups
[OSEv3:children]
masters
nodes
etcd
lb

# Set variables common for all OSEv3 hosts
[OSEv3:vars]
ansible_ssh_user=$SUDOUSER
ansible_become=yes
openshift_install_examples=true
deployment_type=openshift-enterprise
docker_udev_workaround=true
openshift_use_dnsmasq=true
openshift_disable_check=disk_availability,package_version,package_update,memory_availability,disk_availability,docker_storage,docker_storage_driver
openshift_master_default_subdomain=$ROUTING
openshift_set_hostname=true
osm_use_cockpit=true
os_sdn_network_plugin_name='redhat/openshift-ovs-multitenant'

# Enable CRI-O
openshift_use_crio=true
openshift_crio_enable_docker_gc=true

# Deploy Prometheus
openshift_hosted_prometheus_deploy=false
openshift_prometheus_namespace=openshift-metrics
openshift_prometheus_node_selector={"region":"infra"}
openshift_prometheus_storage_kind=dynamic
openshift_prometheus_storage_volume_name=prometheus
openshift_prometheus_storage_volume_size=8Gi
openshift_prometheus_storage_type='pvc'
openshift_prometheus_alertmanager_storage_kind=dynamic
openshift_prometheus_alertmanager_storage_volume_name=prometheus-alertmanager
openshift_prometheus_alertmanager_storage_volume_size=1Gi
openshift_prometheus_alertmanager_storage_type='pvc'
openshift_prometheus_alertbuffer_storage_kind=dynamic
openshift_prometheus_alertbuffer_storage_volume_name=prometheus-alertbuffer
openshift_prometheus_alertbuffer_storage_volume_size=1Gi
openshift_prometheus_alertbuffer_storage_type='pvc'

# apply updated node defaults
openshift_node_kubelet_args={'pods-per-core': ['10'], 'max-pods': ['250'], 'image-gc-high-threshold': ['90'], 'image-gc-low-threshold': ['80']}

# enable ntp on masters to ensure proper failover
openshift_clock_enabled=true

# Configure master API and console ports.
openshift_master_api_port=443
openshift_master_console_port=443

openshift_master_cluster_method=native
openshift_master_cluster_hostname=$BASTION
openshift_master_cluster_public_hostname=$MASTERPUBLICIPHOSTNAME
#openshift_master_cluster_public_vip=$MASTERPUBLICIPADDRESS

# Enable HTPasswdPasswordIdentityProvider
openshift_master_identity_providers=[{'name': 'htpasswd_auth', 'login': 'true', 'challenge': 'true', 'kind': 'HTPasswdPasswordIdentityProvider', 'filename': '/etc/origin/master/htpasswd'}]

# Setup Default Storage Class
openshift_storageclass_name=azure
openshift_storageclass_default=true
openshift_storageclass_parameters='kubernetes.io/azure-disk'
openshift_storageclass_provisioner='storageaccounttype: Standard_LRS\nkind: Shared'

# Setup metrics
openshift_master_metrics_public_url=https://hawkular-metrics.$ROUTING/hawkular/metrics
openshift_metrics_install_metrics=false
openshift_metrics_hawkular_hostname=hawkular-metrics.$ROUTING
openshift_metrics_hawkular_nodeselector={"region":"infra"}
openshift_metrics_cassandra_nodeselector={"region":"infra"}
openshift_metrics_heapster_nodeselector={"region":"infra"}
openshift_metrics_cassandra_pvc_size=10Gi
openshift_metrics_cassandra_storage_type=dynamic

# Setup logging
openshift_master_logging_public_url=https://kibana.$ROUTING
openshift_logging_master_public_url=https://$MASTERPUBLICIPHOSTNAME
openshift_logging_use_ops=false
openshift_logging_namespace=logging
openshift_logging_install_logging=false
openshift_logging_kibana_hostname=kibana.$ROUTING
openshift_logging_es_nodeselector={"region":"infra"}
openshift_logging_curator_nodeselector={"region":"infra"}
openshift_logging_kibana_nodeselector={"region":"infra"}
openshift_logging_fluentd_nodeselector={"zone":"default"}
openshift_logging_es_pvc_size=10Gi
openshift_logging_es_pvc_dynamic=true

# Setup service catalog and brokers
openshift_enable_service_catalog=false
ansible_service_broker_install=false
template_service_broker_install=false
dynamic_volumes_check=false
openshift_service_catalog_image_version=latest
ansible_service_broker_image_prefix=registry.access.redhat.com/openshift3/ose-
ansible_service_broker_registry_url="registry.access.redhat.com"
openshift_service_catalog_image_prefix=registry.access.redhat.com/openshift3/ose-
template_service_broker_selector={"region":"infra"}
openshift_template_service_broker_namespaces=['openshift']
openshift_hosted_etcd_storage_kind=dynamic
openshift_hosted_etcd_storage_volume_name=etcd-vol
openshift_hosted_etcd_storage_access_modes=["ReadWriteOnce"]
openshift_hosted_etcd_storage_volume_size=1Gi
openshift_hosted_etcd_storage_labels={'storage': 'etcd'}

# host group for masters
[masters]
EOF
for node in $MASTER-{0..3}; do
	ping -c 1 $node 2>/dev/null|grep $MASTER|grep PING|awk '{ print $2 }'
done|grep $MASTER >>/etc/ansible/hosts

cat >> /etc/ansible/hosts <<EOF
# host group for etcd
[etcd]
EOF
for node in $MASTER-{0..3}; do
	ping -c 1 $node 2>/dev/null|grep $MASTER|grep PING|awk '{ print $2 }'
done|grep $MASTER >>/etc/ansible/hosts

cat >> /etc/ansible/hosts <<EOF
[firstmaster]
$MASTER-0

[lb]
$BASTION

# host group for nodes
[nodes]
EOF
for node in $MASTER-{0..3}; do
	echo $(ping -c 1 $node 2>/dev/null|grep $MASTER|grep PING|awk '{ print $2 }'|cut -d"." -f1) openshift_hostname=$(ping -c 1 $node 2>/dev/null|grep $MASTER|grep PING|awk '{ print $2 }'|cut -d"." -f1) openshift_node_labels=\"{\'region\': \'master\', \'zone\': \'default\'}\"
done|grep $MASTER >>/etc/ansible/hosts
# runtime: cri-o is a fix for https://bugzilla.redhat.com/show_bug.cgi?id=1553452
for node in $INFRA-{0..30}; do
        echo $(ping -c 1 $node 2>/dev/null|grep $INFRA|grep PING|awk '{ print $2 }'|cut -d"." -f1) openshift_hostname=$(ping -c 1 $node 2>/dev/null|grep $INFRA|grep PING|awk '{ print $2 }'|cut -d"." -f1) openshift_node_labels=\"{\'region\': \'infra\', \'zone\': \'default\', \'runtime\': \'cri-o\'}\"
done|grep $INFRA >>/etc/ansible/hosts
for node in $NODE-{0..30}; do
        echo $(ping -c 1 $node 2>/dev/null|grep $NODE|grep PING|awk '{ print $2 }'|cut -d"." -f1) openshift_hostname=$(ping -c 1 $node 2>/dev/null|grep $NODE|grep PING|awk '{ print $2 }'|cut -d"." -f1) openshift_node_labels=\"{\'region\': \'nodes\', \'zone\': \'default\', \'runtime\': \'cri-o\'}\"
done|grep $NODE >>/etc/ansible/hosts
fi

echo $(date) " - Running preinstall tasks"

# Create and distribute hosts file to all nodes, this is due to us having to use
(
echo "127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4"
echo "::1         localhost localhost.localdomain localhost6 localhost6.localdomain6"
for node in $MASTER-0 $MASTER-1 $MASTER-2; do
	ping -c 1 $node 2>/dev/null|grep $MASTER|grep PING|awk '{ print $3 " " $2  }'|sed -e 's/(//' -e 's/)//'i -e "s/.net/.net $node/"
done

for node in $INFRA-{0..5}; do
	ping -c 1 $node 2>/dev/null|grep $INFRA|grep PING|awk '{ print $3 " " $2  }'|sed -e 's/(//' -e 's/)//' -e "s/.net/.net $node/"
done

for node in $NODE-{0..30}; do
	ping -c 1 $node 2>/dev/null|grep $NODE|grep PING|awk '{ print $3 " " $2  }'|sed -e 's/(//' -e 's/)//' -e "s/.net/.net $node/"
done
) >/tmp/hosts

chmod a+r /tmp/hosts

# Create correct hosts file on all servers
runuser -l $SUDOUSER -c "ansible-playbook ~/preinstall.yml"

# Prometheus bugfix: https://bugzilla.redhat.com/show_bug.cgi?id=1563494
# ...Locally
sed -i 's/v0.15.2/v3.9.27-1/g' /usr/share/ansible/openshift-ansible/roles/openshift_prometheus/vars/openshift-enterprise.yml

# ...On the masters
if [ $MASTERCOUNT -ne 1 ]
then
        for item in $MASTER-0 $MASTER-1 $MASTER-2; do
  	      # Prometheus bugfix: https://bugzilla.redhat.com/show_bug.cgi?id=1563494
              runuser -l $SUDOUSER -c "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $item 'sudo sed -i \"s/v0.15.2/v3.9.25-1/g\" /usr/share/ansible/openshift-ansible/roles/openshift_prometheus/vars/openshift-enterprise.yml'"
        done
else
        # Prometheus bugfix: https://bugzilla.redhat.com/show_bug.cgi?id=1563494
        runuser -l $SUDOUSER -c "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $MASTER-0 'sudo sed -i \"s/v0.15.2/v3.9.25-1/g\" /usr/share/ansible/openshift-ansible/roles/openshift_prometheus/vars/openshift-enterprise.yml'"
fi

# Initiating installation of OpenShift Container Platform using Ansible Playbook
echo $(date) " - Installing OpenShift Container Platform via Ansible Playbook"

echo $(date) " - Running prereq playbook"
runuser -l $SUDOUSER -c "ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/prerequisites.yml"

echo $(date) " - Running install playbook"
runuser -l $SUDOUSER -c "ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/deploy_cluster.yml"

# Execute setup-azure-config playbook to configure Azure Cloud Provider
echo $(date) "- Configuring OpenShift Cloud Provider to be Azure"

if [ $MASTERCOUNT -eq 1 ]
then
   runuser -l $SUDOUSER -c "ansible-playbook ~/setup-azure-config-single-master.yml"
else
   runuser -l $SUDOUSER -c "ansible-playbook ~/setup-azure-config-multiple-master.yml"
fi

# Wait until nodes are up and running again
oc login $MASTERPUBLICIPHOSTNAME

# Deploy metrics in case it's selected
if [ $INSTALLMETRICS = "true" ]
then
  echo $(date) "- Deploying metrics"
  sed -i -e "s/openshift_metrics_install_metrics=false/openshift_metrics_install_metrics=true/" /etc/ansible/hosts
  runuser -l $SUDOUSER -c "ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/openshift-metrics/config.yml"
fi

# Deploy logging in case it's selected
if [ $INSTALLLOGGING = "true" ]
then
  echo $(date) "- Deploying logging"
  sed -i -e "s/openshift_logging_install_logging=false/openshift_logging_install_logging=true/" /etc/ansible/hosts
  runuser -l $SUDOUSER -c "ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/openshift-logging/config.yml"
fi

# Deploy prometheus in case it's selected
if [ $INSTALLPROMETHEUS = "true" ]
then
  echo $(date) "- Deploying prometheus"
  sed -i -e "s/openshift_hosted_prometheus_deploy=false/openshift_hosted_prometheus_deploy=true/" /etc/ansible/hosts
  runuser -l $SUDOUSER -c "ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/openshift-prometheus/config.yml"
fi

# Deploy service brokers in case it's selected
if [ $INSTALLSERVICEBROKERS = "true" ]
then
  echo $(date) "- Deploying service brokers"
  sed -i -e "s/openshift_enable_service_catalog=false/openshift_enable_service_catalog=true/" /etc/ansible/hosts
  sed -i -e "s/ansible_service_broker_install=false/ansible_service_broker_install=true/" /etc/ansible/hosts
  sed -i -e "s/template_service_broker_install=false/template_service_broker_install=true/" /etc/ansible/hosts
  runuser -l $SUDOUSER -c "ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/openshift-service-catalog/config.yml"
fi

# Modify sudoers
echo $(date) " - Modifying sudoers"

sed -i -e "s/Defaults    requiretty/# Defaults    requiretty/" /etc/sudoers
sed -i -e '/Defaults    env_keep += "LC_TIME LC_ALL LANGUAGE LINGUAS _XKB_CHARSET XAUTHORITY"/aDefaults    env_keep += "PATH"' /etc/sudoers

# Deploying Registry
echo $(date) "- Registry deployed to infra node"

# Deploying Router
echo $(date) "- Router deployed to infra nodes"

echo $(date) "- Re-enabling requiretty"

sed -i -e "s/# Defaults    requiretty/Defaults    requiretty/" /etc/sudoers

# Adding user to OpenShift authentication file
echo $(date) "- Adding OpenShift user"

runuser -l $SUDOUSER -c "ansible-playbook ~/postinstall.yml"

# Assigning cluster admin rights to OpenShift user
echo $(date) "- Assigning cluster admin rights to user"

runuser -l $SUDOUSER -c "ansible-playbook ~/postinstall2.yml"

# Setting password for Cockpit
echo $(date) "- Assigning password for root, which is used to login to Cockpit"

runuser -l $SUDOUSER -c "ansible-playbook ~/postinstall3.yml"

# Unset of OPENSHIFT_DEFAULT_REGISTRY. Just the easiest way out.

cat > /tmp/atomic-openshift-master <<EOF
OPTIONS=--loglevel=2
CONFIG_FILE=/etc/origin/master/master-config.yaml
#OPENSHIFT_DEFAULT_REGISTRY=docker-registry.default.svc:5000


# Proxy configuration
# See https://docs.openshift.com/enterprise/latest/install_config/install/advanced_install.html#configuring-global-proxy
# Origin uses standard HTTP_PROXY environment variables. Be sure to set
# NO_PROXY for your master
#NO_PROXY=master.example.com
#HTTP_PROXY=http://USER:PASSWORD@IPADDR:PORT
#HTTPS_PROXY=https://USER:PASSWORD@IPADDR:PORT
EOF

chmod a+r /tmp/atomic-openshift-master

runuser -l $SUDOUSER -c "ansible-playbook ~/postinstall4.yml"

# OPENSHIFT_DEFAULT_REGISTRY UNSET MAGIC
if [ $MASTERCOUNT -ne 1 ]
then
	for item in $MASTER-0 $MASTER-1 $MASTER-2; do
		runuser -l $SUDOUSER -c "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $item 'sudo sed -i \"s/OPENSHIFT_DEFAULT_REGISTRY/#OPENSHIFT_DEFAULT_REGISTRY/g\" /etc/sysconfig/atomic-openshift-master-api'"
		runuser -l $SUDOUSER -c "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $item 'sudo sed -i \"s/OPENSHIFT_DEFAULT_REGISTRY/#OPENSHIFT_DEFAULT_REGISTRY/g\" /etc/sysconfig/atomic-openshift-master-controllers'"
		runuser -l $SUDOUSER -c "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $item 'sudo systemctl restart atomic-openshift-master-api'"
		runuser -l $SUDOUSER -c "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $item 'sudo systemctl restart atomic-openshift-master-controllers'"
	done
else
	runuser -l $SUDOUSER -c "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $MASTER-0 'sudo sed -i \"s/OPENSHIFT_DEFAULT_REGISTRY/#OPENSHIFT_DEFAULT_REGISTRY/g\" /etc/sysconfig/atomic-openshift-master-api'"
	runuser -l $SUDOUSER -c "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $MASTER-0 'sudo sed -i \"s/OPENSHIFT_DEFAULT_REGISTRY/#OPENSHIFT_DEFAULT_REGISTRY/g\" /etc/sysconfig/atomic-openshift-master-controllers'"
	runuser -l $SUDOUSER -c "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $MASTER-0 'sudo systemctl restart atomic-openshift-master-api'"
	runuser -l $SUDOUSER -c "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $MASTER-0 'sudo systemctl restart atomic-openshift-master-controllers'"
fi

echo $(date) " - Script complete"
