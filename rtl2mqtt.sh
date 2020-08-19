#!/bin/bash

# A shell script that receives events from a RTL433 SDR and forwards them to a MQTT broker

# Original Author: Marco Verleun <marco@marcoach.nl>
# Fork of version from "IT-Berater"
# Adapted and enhanced for flexibility by "sheilbronn"

set -o noglob     # file name globbing is neither needed or nor wanted
set -o noclobber  # disable for security reasons
scriptname="${0##*/}"

# Set Host
mqtthost="test.mosquitto.org" # 
topic="Data/Rtl/433" # default topic (base)

export LANG=C
PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

# Log file base name, if it is an existing dir a file inside will be created
logbase="/tmp/rtl_433.log"

log () {
    local - ; set +x
    [ "$sDoLog" ] || return
    if [ "$sDoLog" = "dir" ] ; then
        logfile="$logbase/$( date "+%H" )"
        echo "$*" >> "$logfile"
    else
        echo "$*" >> "$logbase"
    fi
}

while getopts "?h:t:rlC:navx" opt      
do
    case "$opt" in
    \?) echo "Usage: $scriptname -m host -t topic -r -l -a -v" 1>&2
        exit 1
        ;;
    h)  mqtthost="$OPTARG" # configure broker host here or in $HOME/.config/mosquitto_sub
        if [ "$mqtthost" = "test" ] ; then
            mqtthost="-h test.mosquitto.org"
        fi
        ;;
    t)  topic="$OPTARG" # base topic for MQTT
        ;;
    r)  bRewrite="yes"  # rewrite and simplify output
        ;;
    l)  if [ -f $logbase ] ; then  # do logging
            sDoLog="file"
        else
            mkdir -p "$logbase"       || exit 1
            mkdir -p "$logbase/model" || exit 1
            sDoLog="dir"
        fi
        ;;
    C)  maxcount="$OPTARG" # currently unused
        ;;
    n)  bNoColor="yes" # currently unused
        ;;
    a)  bAlways="yes" # do not delete duplicate receptions
        ;;
    v)  bVerbose="yes" # more output for debugging purposes
        ;;
    x)  set -x # turn on shell debugging from here on
        ;;
    esac
done

shift "$((OPTIND-1))"   # Discard options processed by getopts, any remaining options will be passed to mosquitto_sub

[ "$( command -v jq )" ] || { echo "$scriptname: jq is required!" ; exit 1 ; }

log "$scriptname starting at $( date )"
mosquitto_pub -h "$mqtthost" -i RTL_433 -t "$topic" -m '{ event:starting }'
trap 'log "$scriptname stopping at $( date )" ; mosquitto_pub -h "$mqtthost" -i RTL_433 -t "$topic" -m "{ event:stopping }"' INT QUIT TERM EXIT  

# Start the listener and enter an endless loop
/usr/local/bin/rtl_433 -G 4 -M protocol -C si -F json | while read line
do
    log "$line"

    # line="$( echo "$line" | sed -e 's/" : /":/g'    -e 's/, "/,"/g'  )"
    # line="$( echo "$line" | jq -c . )"
    # line="$( echo "$line" | sed -e 's/{"time":[^,]*,/{/'  -e  's/,"mic":"CHECKSUM"//'  -e 's/,"channel":[0-9]*//'   )"
    line="$( echo "$line" | jq -c "del(.time) | del(.mic) | del(.channel)" )"

    if [ "$bRewrite" ] ; then
        [ "$bVerbose" ] && echo "$line"
        model="$( echo "$line" | jq -r .model )"    
        id="$(    echo "$line" | jq -r .id )"
        temp="$(  echo "$line" | jq -r .temperature_C | awk '{ printf "%.1f", $1 }' )"
        if [ "$temp" ] ; then
            line="$(  echo "$line" | sed -e "s/\(\"temperature_C\":\)[0-9]*.[0-9]*/\1$temp/" )"
        fi
        line="$(  echo "$line" | jq -c "del(.model) | del(.id)" )"

        [ "$sDoLog" = "dir" -a "$model" ] && echo "$line" >> "$logbase/model/${model}_$id"
        { cd "$logbase/model" && find . -type f -mtime +1 -exec mv '{}' '{}'.old \; ; }
    fi

    # Send message to MQTT
    if [ "$bAlways" -o "$line" != "$prevline" ] ; then
        [ "$bVerbose" ] && echo "$line"
        # Raw message to MQTT
        mosquitto_pub -h "$mqtthost" -i RTL_433 -t "$topic${model:+/}$model${id:+/}$id" -m "$line"
        prevline="$line"
    fi
done
