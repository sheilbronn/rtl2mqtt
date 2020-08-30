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
rtl_433_opts="-G 4 -M protocol -C si -R -162"
declare -i nMqttLines=0
declare -i nReceivedCount=0
declare -A aLastValues

export LANG=C
PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

# Log file base name, if it is an existing dir a file inside will be created
logbase="/tmp/rtl_433.log"

log () {
    local - ; set +x
    [ "$sDoLog" ] || return
    if [ "$sDoLog" = "dir" ] ; then
        find . -maxdepth 1 -regex '.*/[0-9][0-9]' -size +100k -exec mv '{}' '{}'.old ";" 
        logfile="$logbase/$( date "+%H" )"
        echo "$*" >> "$logfile"
    else
        echo "$*" >> "$logbase"
    fi
    
}

while getopts "?h:t:rlf:C:navx" opt      
do
    case "$opt" in
    \?) echo "Usage: $scriptname -m host -t topic -r -l -a -v" 1>&2
        exit 1
        ;;
    h)  mqtthost="$OPTARG" # configure broker host here or in $HOME/.config/mosquitto_sub
        [ "$mqtthost" = "test" ] && mqtthost="-h test.mosquitto.org" # abbreviation
        ;;
    t)  topic="$OPTARG" # base topic for MQTT
        ;;
    r)  # rewrite and simplify output
        if [ "$bRewrite" ] ; then
            bRewriteMore="yes" && [ "$bVerbose" ] && echo "... rewriting even more ..."
        else
            bRewrite="yes"  # rewrite and simplify output
        fi
        ;;
    l)  if [ -f $logbase ] ; then  # do logging
            sDoLog="file"
        else
            mkdir -p "$logbase/model" || exit 1
            sDoLog="dir"
        fi
        ;;
    f)  replayfile="$OPTARG" # file to replay (e.g. for debugging), instead of rtl_433 output
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

[ "$( command -v jq )" ] || { echo "$scriptname: jq is required!" 1>&2 ; exit 1 ; }

trap_function() { 
    log "$scriptname stopping at $( date )" 
    mosquitto_pub -h "$mqtthost" -i RTL_433 -t "$topic" -m "{ event:\"stopping\",receivedcount:\"$nReceivedCount\",mqttlinecount:\"$nMqttLines\" }"
 }

log "$scriptname starting at $( date )"
mosquitto_pub -h "$mqtthost" -i RTL_433 -t "$topic" -m "{ event:\"starting\",additional_rtl_433_opts:\"$rtl_433_opts\" }"
trap 'trap_function' EXIT # previously also: INT QUIT TERM 

# Start the listener and enter an endless loop
[ "$bVerbose" ] && echo "options for rtl_433 are: $rtl_433_opts"
{ [ "$replayfile" ] && cat "$replayfile" ; [ "$replayfile" ] || /usr/local/bin/rtl_433 $rtl_433_opts -F json ; } | while read -r line
do
    line="$( echo "$line" | jq -c "del(.mic)" )"
    log "$line"
    nReceivedCount+=1
    line="$( echo "$line" | jq -c "del(.time)" )"

    if [ "$bRewrite" ] ; then
        # Rewrite and clean the line from less interesting information....
        [ "$bVerbose" ] && echo "$line"
        model="$( echo "$line" | jq -r '.model // empty' )"    
        id="$(    echo "$line" | jq -r '.id    // empty'   )"

        temp="$(  echo "$line" | jq -e -r 'if .temperature_C then .temperature_C*10 + 0.5 | floor / 10 else empty end'  )"
        [ "$temp" ]  &&  line="$( echo "$line" | jq -cer ".temperature_C = $temp" )" 

        line="$(  echo "$line" | jq -c "del(.model) | del(.id) | del(.protocol) | del(.subtype) | del(.channel)" )"

        if [ "$bRewriteMore" ] ; then
            line="$( echo "$line" | jq -c "if .button == 0     then del(.button    ) else . end" )"
            line="$( echo "$line" | jq -c "if .battery_ok == 1 then del(.battery_ok) else . end" )"

            line="$(  echo "$line" | jq -c "del(.transmit)" )"        

            # humidity="$( echo "$line" | jq -e -r 'if .humidity then .humidity + 0.5 | floor else empty end'  )"
            bSkipLine="$( echo "$line" | jq -e -r 'if (.humidity and .humidity>100) or (.temperature_C and .temperature_C<-50)  then "yes" else empty end'  )"
            # [ "$humidity" ] && humidity=$( printf "%.*f\n" 0 "$humidity" )
            # tempint=$( printf "%.*f\n" 0 "$temp" )
            # (( humidity > 100 || tempint < -50)) && bSkipLine="yes"
        fi
set +x
        [ "$sDoLog" = "dir" -a "$model" ] && echo "$line" >> "$logbase/model/${model}_$id"
        { cd "$logbase/model" && find . -maxdepth 1 -type f -size +10k "!" -name "*.old" -exec mv '{}' '{}'.old ";"   ; }
    fi

    # Send message to MQTT or skip it ...
    if [ "$bSkipLine" ] ; then
        [ "$bVerbose" ] && echo "SKIPPING: $line"
        bSkipLine=""
    elif [ "$bAlways" -o "$line" != "$prevline" ] ; then
        [ "$bVerbose" ] && [ ! "$bRewrite" ] && echo "$line"
        # Raw message to MQTT
        mosquitto_pub -h "$mqtthost" -i RTL_433 -t "$topic${model:+/}$model${id:+/}$id" -m "$line"
        nMqttLines+=1
        prevline="$line"
        aLastValues[${model}_${id}]="$line"
        # echo test: ${aLastValues[${model}_${id}]}
    fi
done
