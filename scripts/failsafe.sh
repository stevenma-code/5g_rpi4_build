#!/bin/sh

#
# *Script info*
# Ping destination at a given interval. On first failure, disable modem.
# ModemWatcher sees modem is disabled and will restart it. 
# If connectivity is not restored after modem resetart, failover to secondary carrier if present.
#
# *Assumptions*
# Script to be used for a single ModemManager modem defined as $LIFACE in uci.
# This script should exist under '/scripts/'.
# 'pservice' daemon w/ modemwatcher.sh should be running.
# At first run this script will add this script to 'pservice' config.
#
# *Required Inputs*
# $PINGDST, $LIFACE - Domains to ping, logical (uci) name of the modem interface.
#
# *Dependencies*
# This script requires 'modemmanager' and 'modemwatcher.sh' to be installed and active.
#
# Copyright 2022 hazarjast (and aliases) - hazarjast at protonmail dot com
#
MMCLI="/usr/bin/mmcli"
MINDEX="$($MMCLI -L -K | egrep -o '/org/freedesktop/.*' | tr -d "'")"
INFO="/usr/bin/logger -t FAILSAFE"
DISABLED=0
PIDFILE=/var/run/failsafe.pid
LOOPPID=/var/run/failsafe_loop.pid
FRESET=0
PINGDST="google.com cloudflare.com"
LIFACE="WWAN"
INTERVAL=60

# Preliminary logic to ensure this only runs one instance at a time
[ -f $PIDFILE ] && PFEXST="true" || PFEXST="false"
case "$PFEXST" in
  "true") PID=$(cat $PIDFILE)
         $(ps | awk '{print $1}' | grep -q $PID) && \
         $($ERROR "Already running. Exiting." && exit 1) || \
         $(echo $$ > $PIDFILE || $ERROR "Could not create PID file. Exiting." && exit 1)
  ;;
  "false") $(echo $$ > $PIDFILE) || $($ERROR "Could not create PID file. Exiting." && exit 1)
  ;;
esac

# Setup this script as a 'pservice' daemon if it's not already
PSCONF=/etc/config/pservice
if ! $(grep -q 'failsafe' $PSCONF) 
then
  [ -f /etc/config/pservice ] && cp -p $PSCONF $PSCONF.bak
cat << EOF >> $PSCONF
config pservice
        option name 'failsafe'
        option respawn_maxfail 0
        option command /bin/sh
        list args -c
        list args 'exec /scripts/failsafe.sh'
EOF

  echo "Setup 'failsafe' as a pservice daemon."
  echo "Execute '/etc/init.d/pservice [re]start' or reboot OpenWRT to start it."
  $INFO "Pservice daemon configured. Notified user to manually start it or reboot."
  exit 0
else
  continue
fi

# Wrapper for 'ping' which tests internet connectivity
# Ping instructed to use the $PIFACE gateway
pinger () {
CONNECTED=0
for DEST in $PINGDST
do
  if [ $CONNECTED -eq 0 ]
  then
    $INFO "Checking internet connectivity by pinging $DEST."
    while [ -z $PIFACE ]
    do
      ubus -v call network.interface.$LIFACE status >/dev/null 2>/dev/null && \
      PIFACE=$(ubus -v call network.interface.$LIFACE status | egrep -o 'l3_device.*' | tr -d "l3_device: \|\"\,")
      sleep 1
    done
    ping -I $PIFACE -c1 $DEST >/dev/null 2>/dev/null
    [ $? -eq 0 ] && CONNECTED=1
  fi
done
}

# Checks for connectivity with 'pinger' and exits early if found
check() {
pinger
if [ $CONNECTED -eq 1 ] && [ $FRESET -eq 0 ]
then
  $INFO "Modem is connected to the internet."
elif [ $FRESET -eq 1 ]
then
  $INFO "$LIFACE was restarted. Cycling modem."
  FRESET=0
  mcycle
  pinger
    if [ $CONNECTED -eq 1 ]
    then
      $INFO "Modem is connected to the internet."
    else
      $INFO "Still cannot reach Internet. Send help."
    fi
else
  $INFO "Cannot reach internet. Cycling modem."
  mcycle
  pinger
    if [ $CONNECTED -eq 1 ]
    then
      $INFO "Modem is connected to the internet."
    else
      $INFO "Still cannot reach Internet. Send help."
    fi
fi
}

# Function to cleanup processes and pidfiles when script is terminated
terminate() {
  LOOP=$(cat $LOOPPID)
  rm -f $LOOPPID $PIDFILE
  $INFO "Failsafe killed!"
  kill $LOOP
  exit 0
}

trap terminate SIGHUP SIGINT SIGQUIT SIGTERM

$INFO "Failsafe initialized!"

# Main failsafe logic
while true
do
  check
  sleep $INTERVAL
done & echo $! > $LOOPPID

wait
