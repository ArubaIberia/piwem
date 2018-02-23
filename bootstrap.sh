#!/usr/bin/env bash
#
# Script to turn a raspberry pi (3) in a poor man's WAN emulator.
#
# Adds VLAN interfaces to the raspberry, which can be used to add delays
# or packet loss using "tc" commands.
#
# You can tune your VLANs numbers, adresses, bitmasks and scopes here.
# You can even add more VLANs if you like, up to 8.

VLAN[0]=4094
IPADDR[0]=10.224.255.1
BITMASK[0]=25
NETWORK[0]=10.224.255.0
DHCP_START[0]=10.224.255.50
DHCP_END[0]=10.224.255.100
DHCP_LEASE[0]=4h

VLAN[1]=4093
IPADDR[1]=10.224.255.129
BITMASK[1]=25
NETWORK[1]=10.224.255.128
DHCP_START[1]=10.224.255.150
DHCP_END[1]=10.224.255.200
DHCP_LEASE[1]=4h

OSPF_AREA=0.0.0.1

# No need to change anything below this line
# ------------------------------------------

NETMASK_HASH[0]=0.0.0.0
NETMASK_HASH[1]=128.0.0.0
NETMASK_HASH[2]=192.0.0.0
NETMASK_HASH[3]=224.0.0.0
NETMASK_HASH[4]=240.0.0.0
NETMASK_HASH[5]=248.0.0.0
NETMASK_HASH[6]=252.0.0.0
NETMASK_HASH[7]=254.0.0.0
NETMASK_HASH[8]=255.0.0.0
NETMASK_HASH[9]=255.128.0.0
NETMASK_HASH[10]=255.192.0.0
NETMASK_HASH[11]=255.224.0.0
NETMASK_HASH[12]=255.240.0.0
NETMASK_HASH[13]=255.248.0.0
NETMASK_HASH[14]=255.252.0.0
NETMASK_HASH[15]=255.254.0.0
NETMASK_HASH[16]=255.255.0.0
NETMASK_HASH[17]=255.255.128.0
NETMASK_HASH[18]=255.255.192.0
NETMASK_HASH[19]=255.255.224.0
NETMASK_HASH[20]=255.255.240.0
NETMASK_HASH[21]=255.255.248.0
NETMASK_HASH[22]=255.255.252.0
NETMASK_HASH[23]=255.255.254.0
NETMASK_HASH[24]=255.255.255.0
NETMASK_HASH[25]=255.255.255.128
NETMASK_HASH[26]=255.255.255.192
NETMASK_HASH[27]=255.255.255.224
NETMASK_HASH[28]=255.255.255.240
NETMASK_HASH[29]=255.255.255.248
NETMASK_HASH[30]=255.255.255.252
NETMASK_HASH[31]=255.255.255.254
NETMASK_HASH[32]=255.255.255.255

# Functions used somewhere else
# -----------------------------

export IPBOT_SERVICE=ipbot
export IPBOT_SERVICE_FILE=/etc/systemd/system/${IPBOT_SERVICE}.service

export GOPATH=/opt
export PATH=$PATH:/usr/local/go/bin

function upgrade_ipbot() {
  echo
  echo Downloading ipbot application...
  mkdir -p /opt/src/github.com/ArubaIberia
  cd /opt/src/github.com/ArubaIberia
  if ! git clone https://github.com/ArubaIberia/ipbot.git; then
    cd ipbot
    git pull
  fi
  echo OK

  echo
  echo Compiling ipbot...
  go get
  go install
  echo OK

  echo
  echo Checking Capabilities...
  if [ -f ${IPBOT_SERVICE_FILE} ]; then
    if ! grep -q AmbientCapabilities "${IPBOT_SERVICE_FILE}"; then
      sed -i '/\[Service\]/a AmbientCapabilities = CAP_NET_ADMIN' \
        "${IPBOT_SERVICE_FILE}"
      systemctl daemon-reload
      systemctl stop  "${IPBOT_SERVICE}"
      systemctl start "${IPBOT_SERVICE}"
    fi
  fi
  echo OK
}

# Process command line flags
# --------------------------

for i in "$@"
do
case $i in
  -u|--upgrade)
    upgrade_ipbot
    systemctl stop  "${IPBOT_SERVICE}"
    systemctl start "${IPBOT_SERVICE}"
    echo UPGRADE DONE!
    exit 0
  ;;
  *)
    # unknown option
  ;;
esac
done

# Disable swap - not required, but helps avoiding
# storage corruption in case the raspi is suddenly powered off
# ---------------------------------------------------------

echo
echo Disabling swap...

sync
swapoff -a
update-rc.d dphys-swapfile disable
systemctl disable dphys-swapfile
systemctl stop dphys-swapfile
echo OK

# Installing required software packages
# ---------------------------------------------------------

echo
echo Installing software packages...

DEBIAN_FRONTEND=noninteractive apt-get install -y \
  vlan netfilter-persistent iptables-persistent lldpd dnsmasq quagga \
  busybox-syslogd git
echo OK

DEBIAN_FRONTEND=noninteractive dpkg --purge rsyslog

echo
echo "************************************************************"
echo "rsyslog has been replaced by busybox-syslogd. To check system"
echo "logs from now on, use ** logread ** !!!"
echo "************************************************************"
echo

# Installing docker
# ---------------------------------------------------------

echo
echo Installing docker...

which docker || (curl -sSL get.docker.com | sh)
echo OK

echo
echo "************************************************************"
echo "Docker installed. Remember to prefix image names with armhf/"
echo "(e.g.: docker pull armhf/golang)"
echo "************************************************************"
echo

# Enabling routing
# ---------------------------------------------------------

SYSCTL_FILE=/etc/sysctl.conf

echo
echo -n Enabling net.ipv4.ip_forward in ${SYSCTL_FILE}...

if ! grep -q net\.ipv4\.ip_forward ${SYSCTL_FILE}; then
  echo "net.ipv4.ip_forward=1" >> ${SYSCTL_FILE}
else
  sed -i 's/^.*net\.ipv4\.ip_forward.*$/net.ipv4.ip_forward=1/' \
    ${SYSCTL_FILE}
fi
sysctl net.ipv4.ip_forward=1 >/dev/null
echo " OK"

echo
echo -n Disabling IPv6 - IPv6 may cause checksum errors in network driver...

for i in net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6; do
  if ! grep -q "$i" ${SYSCTL_FILE}; then
    echo "${i}=1" >> ${SYSCTL_FILE}
  else
    sed -i "s/^.*${i}.*\$/${i}=1/" ${SYSCTL_FILE}
  fi
  sysctl "${i}=1" >/dev/null
done
echo " OK"

# Masquerading eth0 interface
# ---------------------------------------------------------

echo
echo Configuring NAT in eth0 interface...

iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
# This is a fix for some problem detected in particular versions of
# raspbian and docker, the FORWARDING chain gets a DROP policy
iptables -P FORWARD ACCEPT
# netfilter-persistent doesn't seem to save things properly...
# netfilter-persistent save
iptables-save > /etc/iptables/rules.v4
echo OK

# Kernel modules
# ---------------------------------------------------------

echo
echo -n Enabling 8021q kernel module...
if ! grep -q 8021q /etc/modules; then
  echo 8021q >> /etc/modules
fi
modprobe 8021q
echo " OK"

echo
echo -n Enabling ifb kernel module...
if ! grep -q ifb /etc/modules; then
  echo ifb >> /etc/modules
fi
modprobe ifb
echo " OK"

# Secondary network interfaces (one per VLAN):
# ---------------------------------------------------------
#
export IF_FILE=/etc/network/interfaces
export IF_DIR=/etc/network/interfaces.d

echo
echo -n Overwriting ${IF_FILE} with template config...

cat <<EOF >${IF_FILE}
auto lo
iface lo inet loopback

allow-hotplug eth0
auto eth0
iface eth0 inet dhcp

allow-hotplug wlan0
iface wlan0 inet manual
#    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF
echo " OK"

echo
echo Disabling DHCPCD service...
update-rc.d dhcpcd disable

for index in ${!VLAN[@]}; do

  # Definition of eth0.$vlan subinterface.
  # For more details on the internal ifb$index interface, see
  # https://wiki.linuxfoundation.org/networking/netem
  echo
  echo Adding VLAN ${VLAN[$index]} to ${IF_FILE}...
  echo Interfaces eth0.${VLAN[$index]} and ifb${index} will be created

  cat <<EOF >> ${IF_FILE}

iface eth0.${VLAN[$index]} inet static
  address ${IPADDR[$index]}
  netmask ${NETMASK_HASH[${BITMASK[$index]}]}
  post-up ip link set dev ifb${index} up
  post-up tc qdisc add dev eth0.${VLAN[$index]} ingress
  post-up tc filter add dev eth0.${VLAN[$index]} parent ffff: protocol ip u32 match u32 0 0 flowid 1:1 action mirred egress redirect dev ifb${index}
EOF
  echo " OK"

  # Set the eth0.VLAN interface to get up after eth0
  echo -n Adding one-shot service to start eth0.${VLAN[$index]}...
  cat <<EOF >> "/etc/systemd/system/vlan-${VLAN[$index]}.service"
[Unit]
Description = Service to start up VLAN ${VLAN[$index]}
After = network.target
[Service]
Type = oneshot
ExecStart = /sbin/ifup eth0.${VLAN[$index]}
RemainAfterExit = true
StandardOutput = journal
[Install]
WantedBy = multi-user.target
EOF
  echo " OK"
  systemctl daemon-reload
  systemctl enable vlan-${VLAN[$index]}

done

# DHCP service in VLAN interfaces
# ---------------------------------------------------------

DNS_FILE=/etc/dnsmasq.conf
DNS_DIR=/etc/dnsmasq.d

if ! grep -q '^conf-dir=' $DNS_FILE; then
  echo 'conf-dir=/etc/dnsmasq.d/,*.conf' >> $DNS_FILE
  mkdir -p /etc/dnsmasq.d
fi

for index in ${!VLAN[@]}; do

  # Allow dnsmasq in VLAN interface
  echo
  echo -n Enabling DHCP in ${DNS_DIR}/eth0-${VLAN[$index]}.conf...
  cat <<EOF > ${DNS_DIR}/eth0-${VLAN[$index]}.conf
interface=eth0.${VLAN[$index]}
dhcp-range=eth0.${VLAN[$index]},${DHCP_START[$index]},${DHCP_END[$index]},${DHCP_LEASE[$index]}
EOF
  echo " OK"

done

# admin user
# ---------------------------------------------------------

echo
read -p "Do you want to create a new admin user? [y/N] " -n 1 -r
echo    # (optional) move to a new line
if [[ $REPLY =~ ^[YysS]$ ]]
then
  useradd -m admin
  usermod -a -G sudo,quagga,quaggavty,docker,adm admin
  echo "Please, type the new password for privileged user 'admin': "
  passwd admin

#  ADMIN_UID=`id -u admin`
#  ADMIN_GID=`id -g admin`
#  if ! grep -q '^admin:' /etc/subuid; then
#    echo "admin:${ADMIN_UID}:1" >> /etc/subuid
#  fi
#  if ! grep -q '^admin:' /etc/subgid; then
#    echo "admin:${ADMIN_GID}:1" >> /etc/subgid
#  fi

else
  echo "*****************************************************************************"
  echo "OK, but make sure you add your user to groups adm, quagga, quaggavty, docker!"
  echo "******************************************************************************"
fi

# Removing default users
# ---------------------------------------------------------

echo
read -p "Do you want to remove the predefined user 'pi'? [y/N] " -n 1 -r
echo    # (optional) move to a new line
if [[ $REPLY =~ ^[YysS]$ ]]
then
  userdel pi
else
  echo "***************************************************************"
  echo "OK, user 'pi' not removed, but remember to change its password!"
  echo "***************************************************************"
fi

# Configuring routing
# ---------------------------------------------------------

DAEMON_FILE=/etc/quagga/daemons
VTYSH_FILE=/etc/quagga/vtysh.conf
ZEBRA_FILE=/etc/quagga/zebra.conf
OSPFD_FILE=/etc/quagga/ospfd.conf

echo
echo Adding static and OSPF routing to DAEMON_FILE...

sed -i 's/^zebra=.*$/zebra=yes/;s/^ospfd=.*$/ospfd=yes/' $DAEMON_FILE
echo " OK"

echo
echo Adding ${VTYSH_FILE} template...

cat <<EOF > ${VTYSH_FILE}
! Sample configuration file for vtysh.
!
!service integrated-vtysh-config
hostname RPi-router
username root nopassword
EOF
echo " OK"

echo
echo Adding ${ZEBRA_FILE} template...

cat <<EOF > ${ZEBRA_FILE}
hostname RPi-zebra
!
password zebra
enable password enable
EOF
echo " OK"

echo
echo Adding ${OSPFD_FILE} template...

cat <<EOF > ${OSPFD_FILE}
!
hostname RPi-ospfd
password ospfd
enable password enable
!
interface eth0
!
interface lo
!
interface lo0
!
router ospf
 passive-interface eth0
 passive-interface lo0
 network 127.0.0.0/8 area 0.0.0.0
!
EOF
echo " OK"

for index in ${!VLAN[@]}; do

  echo
  echo Adding vlan ${VLAN[$index]} to ${OSPFD_FILE}...
  sed -i "/^interface eth0\$/a interface eth0.${VLAN[$index]}" $OSPFD_FILE
  sed -i "/^ network 127.0.0.0/a\
    network ${NETWORK[$index]}/${BITMASK[$index]} area ${OSPF_AREA}" \
    $OSPFD_FILE
  echo " OK"

done

# golang development environment
# ---------------------------------------------------------

echo
echo Downloading golang development environment...

cd /usr/local
if [ ! -d go ]; then
  rm -f go1.9.linux-armv6l.tar.gz
  wget https://storage.googleapis.com/golang/go1.9.linux-armv6l.tar.gz
  tar -xzvf go1.9.linux-armv6l.tar.gz
fi

echo OK

# IPBot application
# ---------------------------------------------------------

echo
echo -n Creating ipbot user...

if ! id ipbot; then
  useradd -s /bin/false ipbot
fi
echo " OK"

upgrade_ipbot

echo
read -p "If you have a telegram API key, please type it: " -r
echo    # (optional) move to a new line
if [[ ! -z "${REPLY// }" ]]; then

echo
echo Creating IPBot service...

cat <<EOF > ${IPBOT_SERVICE_FILE}
[Unit]
Description = IPbot telegram bot for raspi management
After = network.target
[Service]
AmbientCapabilities = CAP_NET_ADMIN
User = ipbot
ExecStart = /opt/bin/ipbot -token "${REPLY}"
[Install]
WantedBy = multi-user.target
EOF

systemctl daemon-reload
systemctl enable ${IPBOT_SERVICE}
systemctl start  ${IPBOT_SERVICE}
echo OK

fi

# Enabling services
# ---------------------------------------------------------

echo
echo Enabling boot services...

sudo systemctl enable lldpd
sudo systemctl enable netfilter-persistent
sudo systemctl enable quagga
sudo systemctl enable busybox-syslogd
sudo systemctl enable docker
sudo systemctl enable ssh
echo OK
