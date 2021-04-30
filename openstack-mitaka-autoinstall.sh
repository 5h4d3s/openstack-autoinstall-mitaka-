#!/bin/bash
#网卡名称需要配置为eth0 ip最好配置为10.0.0.1
virtual=`egrep -c '(vmx|svm)' /proc/cpuinfo`
if [ $virtual -eq 0 ];then
   echo "请先开启虚拟化!"/Users/shadow/Desktop/openstack-mitaka-autoinstall.sh
   exit 9
fi

if [ ! -f cirros-0.3.4-x86_64-disk.img ];then
   echo "the cirros-0.3.4-x86_64-disk.img is not exist"
   exit 6
fi

if [ ! -f local_settings ];then
   echo "the local_settings is not exist"
   exit 8
fi

mount /dev/cdrom /mnt &>/dev/null
if [ $? -ne 0 ];then
   umount /mnt &>/dev/null
   mount /dev/cdrom /mnt &>/dev/null
   if [ $? -ne 0 ];then
      echo "mount: no medium found on /dev/sr0"
      exit 7
   fi
fi
CUR_PATH=$(cd $(dirname $0); pwd)
host_ip=`ifconfig eth0|awk 'NR==2{print $2}'`
CIDR=`echo $host_ip|sed -r 's#\.[0-9]{1,3}$##'`
gateway=`ip r|awk 'NR==1{print$3}'`
tar xf openstack_rpm.tar.gz -C /opt
#主机名
hostname controller
hostnamectl set-hostname controller
export HOSTNAME=controller
echo '10.0.0.11 controller' >>/etc/hosts

setenforce 0
systemctl stop firewalld.service
systemctl disable firewalld

#yum源
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

yum clean all
yum makecache
yum install wget -y
#时间同步
yum install -y chrony.x86_64 
sed -i '/^server/d' /etc/chrony.conf
sed -i '2a server ntp2.aliyun.com iburst\nallow 10/8' /etc/chrony.conf
systemctl start chronyd.service
systemctl enable chronyd.service
sleep 10
date

#yum install centos-release-openstack-mitaka -y
yum install python-openstackclient -y

#数据库
yum install mariadb mariadb-server python2-PyMySQL -y
echo '[mysqld]
bind-address = 10.0.0.11
default-storage-engine = innodb
innodb_file_per_table
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8' >/etc/my.cnf.d/openstack.cnf
systemctl enable mariadb.service
systemctl start mariadb.service
mysql -e "DELETE FROM mysql.user WHERE User='';"
mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -e "DROP DATABASE IF EXISTS test;"
mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'"
mysql -e "FLUSH PRIVILEGES;"
mysql -e "create database keystone;"
mysql -e "grant all on keystone.* to 'keystone'@'localhost' identified by 'KEYSTONE_DBPASS';"
mysql -e "grant all on keystone.* to 'keystone'@'%' identified by 'KEYSTONE_DBPASS';"
mysql -e "create database glance;"
mysql -e "grant all on glance.* to 'glance'@'localhost' identified by 'GLANCE_DBPASS';"
mysql -e "grant all on glance.* to 'glance'@'%' identified by 'GLANCE_DBPASS';"
mysql -e "create database nova;"
mysql -e "grant all on nova.* to 'nova'@'localhost' identified by 'NOVA_DBPASS';"
mysql -e "grant all on nova.* to 'nova'@'%' identified by 'NOVA_DBPASS';"
mysql -e "create database nova_api;"
mysql -e "grant all on nova_api.* to 'nova'@'localhost' identified by 'NOVA_DBPASS';"
mysql -e "grant all on nova_api.* to 'nova'@'%' identified by 'NOVA_DBPASS';"
mysql -e "create database neutron;"
mysql -e "grant all on neutron.* to 'neutron'@'localhost' identified by 'NEUTRON_DBPASS';"
mysql -e "grant all on neutron.* to 'neutron'@'%' identified by 'NEUTRON_DBPASS';"
mysql -e "select user,host from mysql.user;"

#消息队列
yum install rabbitmq-server -y
systemctl start rabbitmq-server.service
systemctl enable rabbitmq-server.service
rabbitmqctl add_user openstack RABBIT_PASS
rabbitmqctl set_permissions openstack ".*" ".*" ".*"

#memcached
yum install memcached python-memcached -y
sed -i "s#127.0.0.1#0.0.0.0#g" /etc/sysconfig/memcached
systemctl start memcached
systemctl enable memcached

#安装
yum install openstack-utils -y
yum install openstack-keystone httpd mod_wsgi -y
yum install openstack-glance -y
yum install openstack-nova-api openstack-nova-conductor openstack-nova-console openstack-nova-novncproxy openstack-nova-scheduler  -y
yum install openstack-nova-compute -y
yum install openstack-neutron openstack-neutron-ml2 openstack-neutron-linuxbridge ebtables ipset -y
yum install openstack-dashboard -y

#keystone
#cat keystone.conf >/etc/keystone/keystone.conf
openstack-config --set /etc/keystone/keystone.conf DEFAULT admin_token  ADMIN_TOKEN
openstack-config --set /etc/keystone/keystone.conf database connection  mysql+pymysql://keystone:KEYSTONE_DBPASS@controller/keystone
openstack-config --set /etc/keystone/keystone.conf token provider  fernet
su -s /bin/sh -c "keystone-manage db_sync" keystone
mysql -h 10.0.0.11 -ukeystone -p'KEYSTONE_DBPASS' -e "use keystone;show tables;"
keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone

sed -i "95a ServerName controller" /etc/httpd/conf/httpd.conf
#\mv wsgi-keystone.conf /etc/httpd/conf.d/
echo 'Listen 5000
Listen 35357

<VirtualHost *:5000>
    WSGIDaemonProcess keystone-public processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-public
    WSGIScriptAlias / /usr/bin/keystone-wsgi-public
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    ErrorLogFormat "%{cu}t %M"
    ErrorLog /var/log/httpd/keystone-error.log
    CustomLog /var/log/httpd/keystone-access.log combined

    <Directory /usr/bin>
        Require all granted
    </Directory>
</VirtualHost>

<VirtualHost *:35357>
    WSGIDaemonProcess keystone-admin processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-admin
    WSGIScriptAlias / /usr/bin/keystone-wsgi-admin
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    ErrorLogFormat "%{cu}t %M"
    ErrorLog /var/log/httpd/keystone-error.log
    CustomLog /var/log/httpd/keystone-access.log combined

    <Directory /usr/bin>
        Require all granted
    </Directory>
</VirtualHost>' >/etc/httpd/conf.d/wsgi-keystone.conf
systemctl start httpd.service
systemctl enable httpd.service
sleep 60

export OS_TOKEN=ADMIN_TOKEN
export OS_URL=http://controller:35357/v3
export OS_IDENTITY_API_VERSION=3

openstack domain create --description "Default Domain" default
openstack project create --domain default --description "Admin Project" admin
openstack user create --domain default   --password ADMIN_PASS admin
openstack role create admin
openstack role add --project admin --user admin admin
openstack project create --domain default   --description "Demo Project" demo
openstack user create --domain default   --password DEMO_PASS demo
openstack role create user
openstack role add --project demo --user demo user
openstack project create --domain default --description "Service Project" service
openstack user create --domain default --password GLANCE_PASS glance
openstack role add --project service --user glance admin
openstack user create --domain default --password NOVA_PASS nova
openstack role add --project service --user nova admin
openstack user create --domain default --password NEUTRON_PASS neutron
openstack role add --project service --user neutron admin

openstack service create --name keystone --description "OpenStack Identity" identity
openstack endpoint create --region RegionOne  identity public http://controller:5000/v3
openstack endpoint create --region RegionOne  identity internal http://controller:5000/v3
openstack endpoint create --region RegionOne  identity admin http://controller:35357/v3
unset OS_TOKEN OS_URL
export OS_PROJECT_DOMAIN_NAME=default
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=ADMIN_PASS
export OS_AUTH_URL=http://controller:35357/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2

echo 'export OS_PROJECT_DOMAIN_NAME=default
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=ADMIN_PASS
export OS_AUTH_URL=http://controller:35357/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2' >/root/admin-openrc

echo 'export OS_PROJECT_DOMAIN_NAME=default
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_NAME=demo
export OS_USERNAME=demo
export OS_PASSWORD=DEMO_PASS
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2' >/root/demo-openrc

openstack token issue

#glance
#yum install openstack-glance -y
#cat glance-api.conf >/etc/glance/glance-api.conf 
openstack-config --set /etc/glance/glance-api.conf  database  connection  mysql+pymysql://glance:GLANCE_DBPASS@controller/glance
openstack-config --set /etc/glance/glance-api.conf  glance_store stores  file,http
openstack-config --set /etc/glance/glance-api.conf  glance_store default_store  file
openstack-config --set /etc/glance/glance-api.conf  glance_store filesystem_store_datadir  /var/lib/glance/images/
openstack-config --set /etc/glance/glance-api.conf  keystone_authtoken auth_uri  http://controller:5000
openstack-config --set /etc/glance/glance-api.conf  keystone_authtoken auth_url  http://controller:35357
openstack-config --set /etc/glance/glance-api.conf  keystone_authtoken memcached_servers  controller:11211
openstack-config --set /etc/glance/glance-api.conf  keystone_authtoken auth_type  password
openstack-config --set /etc/glance/glance-api.conf  keystone_authtoken project_domain_name  default
openstack-config --set /etc/glance/glance-api.conf  keystone_authtoken user_domain_name  default
openstack-config --set /etc/glance/glance-api.conf  keystone_authtoken project_name  service
openstack-config --set /etc/glance/glance-api.conf  keystone_authtoken username  glance
openstack-config --set /etc/glance/glance-api.conf  keystone_authtoken password  GLANCE_PASS
openstack-config --set /etc/glance/glance-api.conf  paste_deploy flavor  keystone
#cat glance-registry.conf >/etc/glance/glance-registry.conf 
openstack-config --set /etc/glance/glance-registry.conf  database  connection  mysql+pymysql://glance:GLANCE_DBPASS@controller/glance
openstack-config --set /etc/glance/glance-registry.conf  keystone_authtoken auth_uri  http://controller:5000
openstack-config --set /etc/glance/glance-registry.conf  keystone_authtoken auth_url  http://controller:35357
openstack-config --set /etc/glance/glance-registry.conf  keystone_authtoken memcached_servers  controller:11211
openstack-config --set /etc/glance/glance-registry.conf  keystone_authtoken auth_type  password
openstack-config --set /etc/glance/glance-registry.conf  keystone_authtoken project_domain_name  default
openstack-config --set /etc/glance/glance-registry.conf  keystone_authtoken user_domain_name  default
openstack-config --set /etc/glance/glance-registry.conf  keystone_authtoken project_name  service
openstack-config --set /etc/glance/glance-registry.conf  keystone_authtoken username  glance
openstack-config --set /etc/glance/glance-registry.conf  keystone_authtoken password  GLANCE_PASS
openstack-config --set /etc/glance/glance-registry.conf  paste_deploy flavor  keystone

su -s /bin/sh -c "glance-manage db_sync" glance
mysql -h 10.0.0.11 -uglance -p'GLANCE_DBPASS' -e "use glance;show tables;"

systemctl start openstack-glance-api.service openstack-glance-registry.service
systemctl enable openstack-glance-api.service openstack-glance-registry.service
openstack service create --name glance   --description "OpenStack Image" image
openstack endpoint create --region RegionOne   image public http://controller:9292
openstack endpoint create --region RegionOne   image internal http://controller:9292
openstack endpoint create --region RegionOne   image admin http://controller:9292

#wget http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img
#wget http://10.0.0.1/cirros-0.3.4-x86_64-disk.img
openstack image create "cirros" --file cirros-0.3.4-x86_64-disk.img --disk-format qcow2 \
--container-format bare --public
openstack image list

#nova
#yum install openstack-nova-api openstack-nova-conductor openstack-nova-console openstack-nova-novncproxy openstack-nova-scheduler  -y
#yum install openstack-nova-compute -y
openstack service create --name nova   --description "OpenStack Compute" compute
openstack endpoint create --region RegionOne   compute public http://controller:8774/v2.1/%\(tenant_id\)s
openstack endpoint create --region RegionOne   compute internal http://controller:8774/v2.1/%\(tenant_id\)s
openstack endpoint create --region RegionOne   compute admin http://controller:8774/v2.1/%\(tenant_id\)s

#cat nova.conf >/etc/nova/nova.conf 
openstack-config --set /etc/nova/nova.conf  DEFAULT enabled_apis  osapi_compute,metadata
openstack-config --set /etc/nova/nova.conf  DEFAULT rpc_backend  rabbit
openstack-config --set /etc/nova/nova.conf  DEFAULT auth_strategy  keystone
openstack-config --set /etc/nova/nova.conf  DEFAULT my_ip  10.0.0.11
openstack-config --set /etc/nova/nova.conf  DEFAULT use_neutron  True
openstack-config --set /etc/nova/nova.conf  DEFAULT firewall_driver  nova.virt.firewall.NoopFirewallDriver
openstack-config --set /etc/nova/nova.conf  api_database connection  mysql+pymysql://nova:NOVA_DBPASS@controller/nova_api
openstack-config --set /etc/nova/nova.conf  database  connection  mysql+pymysql://nova:NOVA_DBPASS@controller/nova
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
openstack-config --set /etc/nova/nova.conf  libvirt  virt_type  qemu
openstack-config --set /etc/nova/nova.conf  libvirt  cpu_mode  none
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
openstack-config --set /etc/nova/nova.conf  neutron service_metadata_proxy  True
openstack-config --set /etc/nova/nova.conf  neutron metadata_proxy_shared_secret  METADATA_SECRET

su -s /bin/sh -c "nova-manage api_db sync" nova
su -s /bin/sh -c "nova-manage db sync" nova
mysql -h 10.0.0.11 -unova -p'NOVA_DBPASS' -e "use nova;show tables;"
mysql -h 10.0.0.11 -unova -p'NOVA_DBPASS' -e "use nova_api;show tables;"
systemctl restart openstack-nova-api.service openstack-nova-consoleauth.service openstack-nova-scheduler.service \
openstack-nova-conductor.service openstack-nova-novncproxy.service
systemctl enable openstack-nova-api.service openstack-nova-consoleauth.service openstack-nova-scheduler.service \
openstack-nova-conductor.service openstack-nova-novncproxy.service
sleep 60
systemctl restart libvirtd
systemctl enable libvirtd
systemctl restart openstack-nova-compute
systemctl enable openstack-nova-compute
nova service-list

#neutron
#yum install openstack-neutron openstack-neutron-ml2  openstack-neutron-linuxbridge ebtables ipset -y
#cat neutron.conf >/etc/neutron/neutron.conf 
openstack-config --set /etc/neutron/neutron.conf  DEFAULT core_plugin  ml2
openstack-config --set /etc/neutron/neutron.conf  DEFAULT service_plugins
openstack-config --set /etc/neutron/neutron.conf  DEFAULT rpc_backend  rabbit
openstack-config --set /etc/neutron/neutron.conf  DEFAULT auth_strategy  keystone
openstack-config --set /etc/neutron/neutron.conf  DEFAULT notify_nova_on_port_status_changes  True
openstack-config --set /etc/neutron/neutron.conf  DEFAULT notify_nova_on_port_data_changes  True
openstack-config --set /etc/neutron/neutron.conf  database connection  mysql+pymysql://neutron:NEUTRON_DBPASS@controller/neutron
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken auth_uri  http://controller:5000
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken auth_url  http://controller:35357
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken memcached_servers  controller:11211
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken auth_type  password
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken project_domain_name  default
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken user_domain_name  default
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken project_name  service
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken username  neutron
openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken password  NEUTRON_PASS
openstack-config --set /etc/neutron/neutron.conf  nova auth_url  http://controller:35357
openstack-config --set /etc/neutron/neutron.conf  nova auth_type  password 
openstack-config --set /etc/neutron/neutron.conf  nova project_domain_name  default
openstack-config --set /etc/neutron/neutron.conf  nova user_domain_name  default
openstack-config --set /etc/neutron/neutron.conf  nova region_name  RegionOne
openstack-config --set /etc/neutron/neutron.conf  nova project_name  service
openstack-config --set /etc/neutron/neutron.conf  nova username  nova
openstack-config --set /etc/neutron/neutron.conf  nova password  NOVA_PASS
openstack-config --set /etc/neutron/neutron.conf  oslo_concurrency lock_path  /var/lib/neutron/tmp
openstack-config --set /etc/neutron/neutron.conf  oslo_messaging_rabbit rabbit_host  controller
openstack-config --set /etc/neutron/neutron.conf  oslo_messaging_rabbit rabbit_userid  openstack
openstack-config --set /etc/neutron/neutron.conf  oslo_messaging_rabbit rabbit_password  RABBIT_PASS
#cat ml2_conf.ini >/etc/neutron/plugins/ml2/ml2_conf.ini 
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini  ml2 type_drivers  flat,vlan
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini  ml2 tenant_network_types 
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini  ml2 mechanism_drivers  linuxbridge
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini  ml2 extension_drivers  port_security
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini  ml2_type_flat flat_networks  provider
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini  securitygroup enable_ipset  True
#cat linuxbridge_agent.ini >/etc/neutron/plugins/ml2/linuxbridge_agent.ini 
openstack-config --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini  linux_bridge physical_interface_mappings  provider:eth0
openstack-config --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini  securitygroup enable_security_group  True
openstack-config --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini  securitygroup firewall_driver  neutron.agent.linux.iptables_firewall.IptablesFirewallDriver
openstack-config --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini  vxlan enable_vxlan  False
#cat dhcp_agent.ini >/etc/neutron/dhcp_agent.ini 
openstack-config --set /etc/neutron/dhcp_agent.ini  DEFAULT interface_driver neutron.agent.linux.interface.BridgeInterfaceDriver
openstack-config --set /etc/neutron/dhcp_agent.ini  DEFAULT dhcp_driver neutron.agent.linux.dhcp.Dnsmasq
openstack-config --set /etc/neutron/dhcp_agent.ini  DEFAULT enable_isolated_metadata true
#cat metadata_agent.ini >/etc/neutron/metadata_agent.ini 
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT nova_metadata_ip  controller
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT metadata_proxy_shared_secret  METADATA_SECRET
ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file \
/etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron
mysql -h 10.0.0.11 -uneutron -p'NEUTRON_DBPASS' -e "use neutron;show tables;"

systemctl restart neutron-server.service neutron-linuxbridge-agent.service \
neutron-dhcp-agent.service   neutron-metadata-agent.service
systemctl enable neutron-server.service neutron-linuxbridge-agent.service \
neutron-dhcp-agent.service   neutron-metadata-agent.service

openstack service create --name neutron   --description "OpenStack Networking" network
openstack endpoint create --region RegionOne   network public http://controller:9696
openstack endpoint create --region RegionOne   network internal http://controller:9696
openstack endpoint create --region RegionOne   network admin http://controller:9696

sleep 60
neutron agent-list

#yum install openstack-dashboard -y
#wget http://10.0.0.1/local_settings
cat local_settings >/etc/openstack-dashboard/local_settings
neutron net-create --shared --provider:physical_network provider --provider:network_type flat WAN
neutron subnet-create --name subnet-wan --allocation-pool \
start=10.0.0.100,end=10.0.0.200 --dns-nameserver 223.5.5.5 \
--gateway 10.0.0.254 WAN 10.0.0.0/24

openstack flavor create --id 0 --vcpus 1 --ram 64 --disk 1 m1.nano
ssh-keygen -q -N "" -f ~/.ssh/id_rsa
openstack keypair create --public-key ~/.ssh/id_rsa.pub mykey
openstack security group rule create --proto icmp default
openstack security group rule create --proto tcp --dst-port 22 default
#sleep 30
#openstack server create --flavor m1.nano --image cirros \
#--nic net-id=$(openstack network list|awk '$4~/WAN/{print $2}') \
#--security-group default --key-name mykey provider-instance

#openstack server list
sed -i '3a WSGIApplicationGroup %{GLOBAL}' /etc/httpd/conf.d/openstack-dashboard.conf
systemctl restart httpd.service memcached
echo "安装完成，使用浏览器访问http://${host_ip}/dashboard"

