#!/bin/bash
source  /root/admin-openrc
PWD=`date +%s |sha256sum |base64 |head -c 10`
echo $PWD
openstack project create --domain default  $1
openstack user create --domain default  --password $PWD $1
openstack role add --project $1 --user $1 user
context="您的openstack账号已开通,账号为$1,初始密码为$PWD,请妥善保管你的密码,遇到任何问题都可以随时联系我,祝您使用愉快!
openstack平台访问地址http://192.168.0.249/dashboard"
echo $context|mail  -s "账号开通" $2
