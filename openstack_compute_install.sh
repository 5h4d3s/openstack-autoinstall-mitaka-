#!/bin/bash

#修改主机名
hostnamectl set-hostname compute2
export HOSTNAME=compute2

#ip地址
IP=`ifconfig eth0|awk -F "[ ]+"  'NR==2{print $3}'`

#增加控制节点的host解析
echo '10.0.0.11 controller' >>/etc/hosts

#挂载光盘
mount /dev/cdrom /mnt &>/dev/null
if [ $? -ne 0 ];then
   umount /mnt &>/dev/null
   mount /dev/cdrom /mnt &>/dev/null
   if [ $? -ne 0 ];then
      echo "mount: no medium found on /dev/sr0"
      exit 7
   fi
fi

setenforce 0
systemctl stop firewalld.service
systemctl disable firewalld

#yum源配置
mkdir -p /etc/yum.repos.d/test
\mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/test
echo '[openstack]
name=openstack
baseurl=file:///opt/repo
gpgcheck=0

[local]
name=local
baseurl=file:///mnt
gpgcheck=0' >/etc/yum.repos.d/openstack.repo

#时间同步配置
sed -i '/^server/d' /etc/chrony.conf
sed -i '3i server 10.0.0.11 iburst' /etc/chrony.conf 
systemctl restart chronyd

#安装openstack客户端
yum install python-openstackclient.noarch  -y

#nova-compute
yum install openstack-nova-compute -y
yum install openstack-utils.noarch -y
\cp /etc/nova/nova.conf{,.bak}
grep -Ev '^$|#' /etc/nova/nova.conf.bak >/etc/nova/nova.conf
openstack-config --set /etc/nova/nova.conf  DEFAULT enabled_apis  osapi_compute,metadata
openstack-config --set /etc/nova/nova.conf  DEFAULT rpc_backend  rabbit
openstack-config --set /etc/nova/nova.conf  DEFAULT auth_strategy  keystone
openstack-config --set /etc/nova/nova.conf  DEFAULT my_ip  $IP
openstack-config --set /etc/nova/nova.conf  DEFAULT use_neutron  True
openstack-config --set /etc/nova/nova.conf  DEFAULT firewall_driver  nova.virt.firewall.NoopFirewallDriver
openstack-config --set /etc/nova/nova.conf  glance api_servers  http://controller:9292
openstack-config --set /etc/nova/nova.conf  keystone_authtoken  auth_uri  http://controller:5000
openstack-config --set /etc/nova/nova.conf  keystone_authtoken  auth_url  http://controller:35357
openstack-config --set /etc/nova/nova.conf  keystone_authtoken  memcached_servers  controller:11211
openstack-config --set /etc/nova/nova.conf  keystone_authtoken  auth_type  password
openstack-config --set /etc/nova/nova.conf  keystone_authtoken  project_domain_name  default
openstack-config --set /etc/nova/nova.conf  keystone_authtoken  user_domain_name  default
openstack-config --set /etc/nova/nova.conf  keystone_authtoken  project_name  service
openstack-config --set /etc/nova/nova.conf  keystone_authtoken  username  nova
openstack-config --set /etc/nova/nova.conf  keystone_authtoken  password  NOVA_PASS
openstack-config --set /etc/nova/nova.conf  oslo_concurrency lock_path  /var/lib/nova/tmp
openstack-config --set /etc/nova/nova.conf  oslo_messaging_rabbit   rabbit_host  controller
openstack-config --set /etc/nova/nova.conf  oslo_messaging_rabbit   rabbit_userid  openstack
openstack-config --set /etc/nova/nova.conf  oslo_messaging_rabbit   rabbit_password  RABBIT_PASS
openstack-config --set /etc/nova/nova.conf  libvirt  virt_type qemu
openstack-config --set /etc/nova/nova.conf  libvirt  cpu_mode none
openstack-config --set /etc/nova/nova.conf  vnc enabled  True
openstack-config --set /etc/nova/nova.conf  vnc vncserver_listen  0.0.0.0
openstack-config --set /etc/nova/nova.conf  vnc vncserver_proxyclient_address  '$my_ip'
openstack-config --set /etc/nova/nova.conf  vnc novncproxy_base_url  http://controller:6080/vnc_auto.html
openstack-config --set /etc/nova/nova.conf  neutron url  http://controller:9696
openstack-config --set /etc/nova/nova.conf  neutron auth_url  http://controller:35357
openstack-config --set /etc/nova/nova.conf  neutron auth_type  password
openstack-config --set /etc/nova/nova.conf  neutron project_domain_name  default
openstack-config --set /etc/nova/nova.conf  neutron user_domain_name  default
openstack-config --set /etc/nova/nova.conf  neutron region_name  RegionOne
openstack-config --set /etc/nova/nova.conf  neutron project_name  service
openstack-config --set /etc/nova/nova.conf  neutron username  neutron
openstack-config --set /etc/nova/nova.conf  neutron password  NEUTRON_PASS

#5：安装neutron-linuxbridge-agent
yum install openstack-neutron-linuxbridge ebtables ipset -y
\cp /etc/neutron/neutron.conf{,.bak}
grep -Ev '^$|#' /etc/neutron/neutron.conf.bak >/etc/neutron/neutron.conf
openstack-config --set /etc/neutron/neutron.conf  DEFAULT rpc_backend  rabbit
openstack-config --set /etc/neutron/neutron.conf  DEFAULT auth_strategy  keystone
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken auth_uri  http://controller:5000
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken auth_url  http://controller:35357
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken memcached_servers  controller:11211
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken auth_type  password
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken project_domain_name  default
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken user_domain_name  default
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken project_name  service
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken username  neutron
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken password  NEUTRON_PASS
openstack-config --set /etc/neutron/neutron.conf  oslo_concurrency lock_path  /var/lib/neutron/tmp
openstack-config --set /etc/neutron/neutron.conf  oslo_messaging_rabbit rabbit_host  controller
openstack-config --set /etc/neutron/neutron.conf  oslo_messaging_rabbit rabbit_userid  openstack
openstack-config --set /etc/neutron/neutron.conf  oslo_messaging_rabbit rabbit_password  RABBIT_PASS

\cp /etc/neutron/plugins/ml2/linuxbridge_agent.ini{,.bak}
grep '^[a-Z\[]' /etc/neutron/plugins/ml2/linuxbridge_agent.ini.bak >/etc/neutron/plugins/ml2/linuxbridge_agent.ini
openstack-config --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini  linux_bridge physical_interface_mappings  provider:eth0
openstack-config --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini  securitygroup enable_security_group  True
openstack-config --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini  securitygroup firewall_driver  neutron.agent.linux.iptables_firewall.IptablesFirewallDriver
openstack-config --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini  vxlan enable_vxlan  False

#启动服务
systemctl restart  libvirtd openstack-nova-compute neutron-linuxbridge-agent
systemctl enable  libvirtd openstack-nova-compute neutron-linuxbridge-agent
