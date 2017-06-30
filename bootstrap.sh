#!/usr/bin/env bash
#
# Script para transformar la raspberry pi (3) en un pequeño emulador WAN.
#
# Agrega interfaces VLAN a la raspberry, que se pueden utilizar para
# introducir retardos o perdidas de paquetes con "tc".
#

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

# A partir de aqui, no deberia ser necesario tocar
# ---------------------------------------------------------

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

# Desactivacion de swap
# ---------------------------------------------------------

echo
echo Desactivando swap...

sync
swapoff -a
update-rc.d dphys-swapfile disable
systemctl disable dphys-swapfile
systemctl stop dphys-swapfile
echo OK

# Instalacion de paquetes
# ---------------------------------------------------------

echo
echo Instalando paquetes de software...

DEBIAN_FRONTEND=noninteractive apt-get install -y \
  vlan netfilter-persistent iptables-persistent lldpd dnsmasq quagga \
  busybox-syslogd
echo OK

DEBIAN_FRONTEND=noninteractive dpkg --purge rsyslog

echo
echo "************************************************************"
echo "Reemplazado rsyslog por busybox-syslogd. Para ver los logs"
echo "del sistema, utiliza el comando ** logread ** !!!"
echo "************************************************************"
echo

# Instalación de docker
# ---------------------------------------------------------

echo
echo Instalando docker...

which docker || (curl -sSL get.docker.com | sh)
echo OK

echo
echo "************************************************************"
echo "Docker instalado. Recuerda prefijar las imagenes con armhf/"
echo "(por ejemplo: docker pull armhf/golang)"
echo "************************************************************"
echo

# Activacion de routing
# ---------------------------------------------------------

SYSCTL_FILE=/etc/sysctl.conf

echo
echo -n Activando net.ipv4.ip_forward en ${SYSCTL_FILE}...

if ! grep -q net\.ipv4\.ip_forward ${SYSCTL_FILE}; then
  echo "net.ipv4.ip_forward=1" >> ${SYSCTL_FILE}
else
  sed -i 's/^.*net\.ipv4\.ip_forward.*$/net.ipv4.ip_forward=1/' \
    ${SYSCTL_FILE}
fi
sysctl net.ipv4.ip_forward=1 >/dev/null
echo " OK"

# Masquerading de la interfaz eth0
# ---------------------------------------------------------

echo
echo Configurando NAT en interfaz eth0...

iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
netfilter-persistent save
echo OK

# Instalacion de modulos
# ---------------------------------------------------------

echo
echo -n Activando el modulo 8021q...
if ! grep -q 8021q /etc/modules; then
  echo 8021q >> /etc/modules
fi
modprobe 8021q
echo " OK"

# Configuracion de las interfaces de red secundarias:
# una interfaz por cada VLAN declarada.
# ---------------------------------------------------------

export IF_FILE=/etc/network/interfaces
export IF_DIR=/etc/network/interfaces.d

echo
echo -n Sobrescribiendo ${IF_FILE} con plantilla...

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

for index in ${!VLAN[@]}; do

  # Defino la interfaz eth0.$vlan
  echo
  echo -n Agregando VLAN ${VLAN[$index]} a ${IF_FILE}...

  cat <<EOF >> ${IF_FILE}

iface eth0.${VLAN[$index]} inet static
  address ${IPADDR[$index]}
  netmask ${NETMASK_HASH[${BITMASK[$index]}]}
EOF
  echo " OK"

  # Hago que se levante despues de eth0
  echo -n Agregando "post-up ifup eth0.${VLAN[$index]}" a eth0...

  sed -i "/^iface eth0 inet dhcp/a post-up ifup eth0.${VLAN[$index]}" $IF_FILE
  echo " OK"

done

# Servidores DHCP en interfaces VLAN
# ---------------------------------------------------------

DNS_FILE=/etc/dnsmasq.conf
DNS_DIR=/etc/dnsmasq.d

if ! grep -q '^conf-dir=' $DNS_FILE; then
  echo 'conf-dir=/etc/dnsmasq.d/,*.conf' >> $DNS_FILE
  mkdir -p /etc/dnsmasq.d
fi

for index in ${!VLAN[@]}; do

  # Permito dnsmasq en la interfaz VLAN
  echo
  echo -n Configurando DHCP en ${DNS_DIR}/eth0-${VLAN[$index]}.conf...
  cat <<EOF > ${DNS_DIR}/eth0-${VLAN[$index]}.conf
interface=eth0.${VLAN[$index]}
dhcp-range=eth0.${VLAN[$index]},${DHCP_START[$index]},${DHCP_END[$index]},${DHCP_LEASE[$index]}
EOF
  echo " OK"

done

# Creacion de usuario admin
# ---------------------------------------------------------

echo
read -p "Quieres crear un nuevo usuario admin? [y/N] " -n 1 -r
echo    # (optional) move to a new line
if [[ $REPLY =~ ^[YysS]$ ]]
then
  useradd -m admin
  usermod -a -G sudo,quagga,quaggavty,docker admin
  echo Por favor, introduzca la nueva password del usuario.
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
  echo "********************************************************************"
  echo "OK, pero mete a tu usuario en los grupos quagga, quaggavty, docker! "
  echo "********************************************************************"
fi

# Eliminacion de usuario por defecto
# ---------------------------------------------------------

echo
read -p "Quieres borrar el usuario predefinido pi? [y/N] " -n 1 -r
echo    # (optional) move to a new line
if [[ $REPLY =~ ^[YysS]$ ]]
then
  userdel pi
else
  echo "**************************************************************"
  echo "OK, se deja el usuario, pero cambiale el password por defecto!"
  echo "**************************************************************"
fi

# Configurando el routing
# ---------------------------------------------------------

DAEMON_FILE=/etc/quagga/daemons
VTYSH_FILE=/etc/quagga/vtysh.conf
ZEBRA_FILE=/etc/quagga/zebra.conf
OSPFD_FILE=/etc/quagga/ospfd.conf

echo
echo Activando routing estatico y OSPF en DAEMON_FILE...

sed -i 's/^zebra=.*$/zebra=yes/;s/^ospfd=.*$/ospfd=yes/' $DAEMON_FILE
echo " OK"

echo
echo Instalando plantilla de ${VTYSH_FILE}...

cat <<EOF > ${VTYSH_FILE}
! Sample configuration file for vtysh.
!
!service integrated-vtysh-config
hostname RPi-router
username root nopassword
EOF
echo " OK"

echo
echo Instalando plantilla de ${ZEBRA_FILE}...

cat <<EOF > ${ZEBRA_FILE}
hostname RPi-zebra
!
password zebra
enable password enable
EOF
echo " OK"

echo
echo Instalando plantilla de ${OSPFD_FILE}...

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
  echo Agregando vlan ${VLAN[$index]} a ${OSPFD_FILE}...
  sed -i "/^interface eth0\$/a interface eth0.${VLAN[$index]}" $OSPFD_FILE
  sed -i "/^ network 127.0.0.0/a\
    network ${NETWORK[$index]}/${BITMASK[$index]} area ${OSPF_AREA}" \
    $OSPFD_FILE
  echo " OK"

done

# Activacion de servicios
# ---------------------------------------------------------

echo
echo Activando servicios para el arranque...

sudo systemctl enable lldpd
sudo systemctl enable netfilter-persistent
sudo systemctl enable quagga
sudo systemctl enable busybox-syslogd
sudo systemctl enable docker
echo OK

