#!/bin/bash

# A simple script that will receive events from a RTL433 SDR

# Author: Marco Verleun <marco@marcoach.nl>
# Version 2.0: Adapted for the new output format of rtl_433
# Adapted and enhanced for flexibility by sheilbronn 

set -o noglob     # file name globbing is neither needed or nor wanted
set -o noclobber  # disable for security reasons
scriptname="${0##*/}"

# Set Host
mqtthost="test.mosquitto.org"
# Set Topic
topic="Data/Rtl/433"

remove_unwanted_chars() {
     tr -d ':()"^%$ \r\000-\011\013-\037' "$@"
}

while getopts "?htrCnavx" opt      
do
    case "$opt" in
    \?) echo "Usage: $scriptname -m host -t topic" 1>&2
        exit 1
        ;;
    h)  mqtthost="$OPTARG" # configure broker host here or in $HOME/.config/mosquitto_sub
        if [ "$mqtthost" = "test" ] ; then
            mqtthost="-h test.mosquitto.org"
        fi
        ;;
    t)  topic="$( echo "$OPTARG" )"
        ;;
    a)  bAlways="yes"
        ;;
    r)  bReduce="yes"
        ;;
    C)  maxcount="-C $( echo "$OPTARG" | remove_unwanted_chars )" # clean up for sec purposes
        ;;
    n)  bNoColor="yes"
        ;;
    a)  bAlways="yes"
        ;;
    v)  bVerbose="yes"
        ;;
    x)  set -x # turn on shell debugging from here on
        ;;
    esac
done

shift "$((OPTIND-1))"   # Discard options processed by getopts, any remaining options will be passed to mosquitto_sub

export LANG=C
PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

# Start the listener and enter an endless loop
/usr/local/bin/rtl_433 -C si -F json | while read line
do
    # Log to file if file exists.
    # Create file with touch /tmp/rtl_433.log if logging is needed
    [ -w /tmp/rtl_433.log ] && echo $line >> rtl_433.log

    # line="$( echo "$line" | sed -e 's/ : /:/g' -e 's/{"time":[^,]*, /{/')"
    line="$( echo "$line" | jq -c . | sed -e 's/{"time":[^,]*,/{/' )"
    line="$( echo "$line" | jq -c . | sed -e 's/,"mic":"CHECKSUM"//' )"    

    # Raw message to MQTT
    if [ "$bAlways" -o "$line" != "$prevline" ] ; then
        [ "$bVerbose" ] && echo "$line"
        # Raw message to MQTT
        mosquitto_pub -h $mqtthost -i RTL_433 -t $topic -m "$line"
        prevline="$line"
    fi
done
