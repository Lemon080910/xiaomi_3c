#!/bin/sh

pid=`pidof flash.sh`

# If system upgrade in progress, system will reboot after upgrade.
[ -z "$pid" ] || return

#no upgrade in progress
curr_time=`date +%k%M`

[ "$curr_time" -ge "0300" -a "$curr_time" -le "0510" ] && {
	#apply random delay (0-3600s) between 3:00AM to 5:10AM
	base=`head -n 10 /dev/urandom | md5sum | cut -c 1-4`
	delay=`echo $(($((0x$base))%3600))`
	sleep $delay
}

reboot
