#!/bin/bash

# A shell script that receives events from a RTL433 SDR and forwards them to a MQTT broker

# Original Author: Marco Verleun <marco@marcoach.nl>
# Fork of version from "IT-Berater"
# Adapted and enhanced for flexibility by "sheilbronn"

set -o noglob     # file name globbing is neither needed or nor wanted for security reasons
set -o noclobber  # disable for security reasons
set -o pipefail
scriptname="${0##*/}"

# Set Host
logbase="/var/log/$( basename "${scriptname// /}" .sh )" # /var/log is preferred, but will default to /tmp if not useable
mqtthost="test.mosquitto.org"        # default MQTT broker, unsecure ok.
basetopic="Rtl/433"                  # default MQTT topic prefix
rtl_433_opts="-G 4 -M protocol -C si -R -162"
hassbasetopic="homeassistant/sensor/RTL433"
command -v rtl_433 >/dev/null || { echo "$scriptname: rtl_433 not found..." 1>&2 ; exit 1 ; }
rtl433version="$( rtl_433 -V 2>&1 | awk -- '$2 ~ /version/ { print $3 ; exit }' )" || exit 1

declare -i nMqttLines=0     
declare -i nReceivedCount=0 
declare -i nPrevMax=1       # start with 1 for non-triviality
declare -A aReadings

export LANG=C
PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

log () {
    local - ; set +x
    [ "$sDoLog" ] || return
    if [ "$sDoLog" = "dir" ] ; then
        rotate_logdir_sometimes "$logbase"
        logfile="$logbase/$( date "+%H" )"
        echo "$@" >> "$logfile"
    else
        echo "$@" >> "$logbase.log"
    fi    
  }

log_error () {
    echo "$scriptname:" "$@" 1>&2
    logger "$scriptname:" "$@"
    log "$@"
  }

expand_starred_string () {   
    _string="${1//\"/\'}"  &&  echo "${_string//\*/\"}" 
  }

rotate_logdir_sometimes () {           # check for log file rotation and maybe do it (sometimes)
    (( msgMinute + msgSecond != 67 )) && return 0 # rotate log file only with probalility of 1/60
    cd "$1" && _files="$( find . -maxdepth 2 -type f -size +200k "!" -name "*.old" -exec mv '{}' '{}'.old ";" -print0 )"
    msgSecond++
    [[ $_files ]] && log_error "Rotated files: $_files"
  }

publish_to_mqtt_starred () {		# publish_to_mqtt_starred(expandableTopic, starred_message, moreMosquittoOptions)
 	mosquitto_pub -h "$mqtthost" -i RTL_433 -t "$1" -m "$( expand_starred_string "$2" )" $3 # ...  replace double quotes by single quotes and stars by double quotes
  }

#                    hass_announce "" "$basetopic" "${model}/${id}" "(${id}) Temp" "Rtl433 ${model}" "value_json.temperature_C" "temperature"
hass_announce() { # $sitecode "$nodename" "publicwifi/localclients" "Readable name" 5:"$ad_devname" 6:"value_json.count" "$icontype"
	local _topicpart="${3%/set}"
	local _topicword="$( basename "$_topicpart" )"
	local _command_topic_string="$( [ "$3" != "$_topicpart" ] && echo ",*cmd_t*:*~/set*" ) "    # determined by suffix ".../set"
    local _unit=""

    case "${6#value_json.}" in
    temperature_C) _unit="°C" ;;
    humidity)      _unit="%" ;;
    esac

    local _name="${5:+$5-}$4" && _name="${_name// /-}" && _name="${_name//[)()]/}"   #   echo ${5:+$5-}$4 | tr ' ' '-' | tr -d 'x'
#   local _configtopicpart="${5//[ \/-]/}${4//[ ()]/}"
    local _configtopicpart="$( echo "${3//[ \/-]/}" | tr "A-Z" "a-z" )"
#	local _hassdevicestring="*device*:{*name*:*$5*, *mdl*:*RTL433 receiver*, *mf*:*RTL433*, *ids*: [*${scriptname}${1:+_$1}_RTL433*]}"
#	local _hassdevicestring="*device*:{*name*:*$5 $_topicword*, *mdl*:*RTL433 source* }" # "mf" and "ids" not understood by OpenHab ?
	local _hassdevicestring="*device*:{*name*:*$5 $4*,*mdl*:*$5 sender*,*ids*:[*RTL433_$_configtopicpart*],*sw*:*$rtl433version* }"
	local _msg=""
	# mdi icons: https://cdn.materialdesignicons.com/5.4.55/            # *friendly_name*:*${5:+$5 }$4*,

	[ "$bDeleteAnnouncement" != "yes" ] &&
	    _msg="{ *name*:*$_name*, *unique_id*:*$_configtopicpart$7*,
        ${_hassdevicestring:+$_hassdevicestring,} *json_attributes_topic*:*${1:+$1/}$2/$_topicpart*,${_unit:+*unit_of_meas*:*$_unit*,}         
	*state_topic*:*${1:+$1/}$2/$_topicpart* ${6:+,*value_template*:*{{ $6 \}\}*}$_command_topic_string${7:+,*icon*:*mdi:mdi-$7*} }"
	publish_to_mqtt_starred "$hassbasetopic/$_configtopicpart/config" "$_msg" "-r"
  }

hass_remove_announce() {
    mosquitto_sub -h "$mqtthost" -i RTL_433 -t "$hassbasetopic/#" --remove-retained --retained-only -W 1
    publish_to_mqtt_starred "$basetopic" "{ event:*cleaned*,note:*removed all announcements starting with $hassbasetopic* }"
}

del_json_attribute () {
    jq -c "del($1)" <<< "$2"
}

while getopts "?qh:pt:drl:f:F:C:aevx" opt      
do
    case "$opt" in
    \?) echo "Usage: $scriptname -m host -t basetopic -r -l -a -v" 1>&2
        exit 1
        ;;
    q)  bQuiet="yes"
        ;;
    h)  mqtthost="$OPTARG" # configure broker host here or in $HOME/.config/mosquitto_sub
        [ "$mqtthost" = "test" ] && mqtthost="-h test.mosquitto.org" # abbreviation
        ;;
    p)  bAnnouceHass="yes"
        ;;
    t)  basetopic="$OPTARG" # other base topic for MQTT
        ;;
    d)  bRemoveAnnouncements="yes" # delete (remove) all retained auto-discovery announcements (before starting), needs newer mosquitto_sub
        ;;
    r)  # rewrite and simplify output
        if [ "$bRewrite" ] ; then
            bRewriteMore="yes" && [ $bVerbose ] && echo "$scriptname: rewriting even more ..."
        else
            bRewrite="yes"  # rewrite and simplify output
        fi
        ;;
    l)  logbase="$OPTARG" 
        ;;
    f)  replayfile="$OPTARG" # file to replay (e.g. for debugging), instead of rtl_433 output
        ;;
    F)  if [ "$OPTARG" = "868" ] ; then
            rtl_433_opts="$rtl_433_opts -f 868428000 -s 1024k" # frequency
        else
            rtl_433_opts="$rtl_433_opts -f $OPTARG" # 
        fi
        ;;
    C)  maxcount="$OPTARG" # currently unused
        ;;
    e)  bEliminateDups="yes" # eliminate duplicate receptions (=same ones immediately following each other from the same sensor)
        ;;
    a)  bAlways="yes" 
        ;;
    v)  [ "$bVerbose" = "yes" ] && bMoreVerbose="yes"
        bVerbose="yes" # more output for debugging purposes
        ;;
    x)  set -x # turn on shell debugging from here on
        ;;
    esac
done

shift "$((OPTIND-1))"   # Discard options processed by getopts, any remaining options will be passed to mosquitto_sub further down on

if [ -f "${logbase}.log" ] ; then  # one log file only
    sDoLog="file"
else
    if mkdir -p "$logbase/model" && [ -w "$logbase" ] ; then
        :
    else
        logbase="/tmp/${scriptname// /}" && log_error "defaulting to logbase $logbase"
        mkdir -p "$logbase/model" || { log_error "can't mkdir $logbase/model" ; exit 1 ; }
    fi
    cd "$logbase" || { log_error "can't cd to $logbase" ; exit 1 ; }
    sDoLog="dir"
fi

[ "$( command -v jq )" ] || { log_error "$scriptname: jq is a prerequisite!" ; exit 1 ; }

trap_function() { 
    log "$scriptname stopping at $( date )"
    [ "$bRemoveAnnouncements" ] && hass_remove_announce
    [ "$rtlcoproc_PID" ] && kill "$rtlcoproc_PID" && [ $bVerbose ] && echo "$scriptname: Killed coproc PID $_cppid" 1>&2
    sleep 1
    publish_to_mqtt_starred "$basetopic" "{ event:*stopping*, receivedcount:*$nReceivedCount*,mqttlinecount:*$nMqttLines*,rtl433pid:*${rtlcoproc_PID} ($_cppid)*,*sensorcount:*${#aReadings[@]}*,collected_sensors:*${!aReadings[*]}* }"
 }
trap 'trap_function' EXIT # previously also: INT QUIT TERM 

_string="*event*:*starting*, *additional_rtl_433_opts*:*$rtl_433_opts*, *user*:*$( id -nu )*, *logto*:*$logbase ($sDoLog)*"
if [ -t 1 ] ; then # probably terminal
    log "$scriptname starting at $( date )"
    publish_to_mqtt_starred "$basetopic" "{ $_string }"
else               # probably non-terminal
    delayedStartSecs=3
    log "$scriptname starting in $delayedStartSecs secs from $( date )"
    sleep "$delayedStartSecs"
    publish_to_mqtt_starred "$basetopic" "{ $_string, note:*delayed by $delayedStartSecs secs* }"
fi

# Optionally remove any matching, retained announcements
[[ $bRemoveAnnouncements ]] && hass_remove_announce

# Start the RTL433 listener ....
[[ $bVerbose || -t 1 ]] && log_error "options for rtl_433 are: $rtl_433_opts"
if [[ $replayfile ]] ; then
    coproc rtlcoproc ( cat "$replayfile" )
else
    coproc rtlcoproc ( /usr/local/bin/rtl_433 $rtl_433_opts -F json )   # options are not double-quoted on purpose
    renice -n 7 "${rtlcoproc_PID}"
fi 

_cppid="$rtlcoproc_PID"

while read -r data <&"${rtlcoproc[0]}"         # ... and enter an endless loop
do
    # [[ $bQuiet ]] && [[ $data  =~ ^rtl_433:\ warning: ]] && continue
    nReceivedCount=$(( nReceivedCount + 1 ))
    data="$( del_json_attribute ".mic" "$data" )"
    log "$data"
    msgSecond="${data[*]/\",*/}" && msgMinute="${msgSecond:(-5):2}" && msgSecond="${msgSecond:(-2):2}" # no subprocess needed...
    data="$( del_json_attribute ".time" "$data"  )"

    if [[ $bRewrite ]] ; then                  # Rewrite and clean the line from less interesting information....
        [[ $bVerbose ]] && echo "$data"
        model="$( jq -r '.model // empty' <<< "$data" )"    
        id="$(    jq -r '.id    // empty' <<< "$data" )"

        temp="$( jq -e -r 'if .temperature_C then .temperature_C*10 + 0.5 | floor / 10 else empty end' <<< "$data" )"
        if [[ $temp ]] ; then
            _bHasTemperature="yes"
            data="$( jq -cer ".temperature_C = $temp" <<< "$data" )"
        else 
            _bHasTemperature=""
        fi
        _bHasHumidity="$( jq -e -r 'if (.humidity and .humidity<101) then "yes" else empty end'  <<< "$data" )"
        _bHasRain="$(     jq -e -r 'if (.rain_mm  and .rain_mm >0  ) then "yes" else empty end'  <<< "$data" )"

        data="$( jq -c "del(.model) | del(.id) | del(.protocol) | del(.subtype) | del(.channel)" <<< "$data" )"

        if [[ $bRewriteMore ]] ; then
            data="$( del_json_attribute ".transmit" "$data"  )"        

            data="$( jq -c 'if .button     == 0 then del(.button    ) else . end' <<< "$data" )"
            data="$( jq -c 'if .battery_ok == 1 then del(.battery_ok) else . end' <<< "$data" )"
            data="$( jq -c 'if .unknown1   == 0 then del(.unknown1)   else . end' <<< "$data" )"

            bSkipLine="$( jq -e -r 'if (.humidity and .humidity>100) or (.temperature_C and .temperature_C<-50) or .rain_mm>0 then "yes" else empty end' <<<"$data"  )"
        fi
        [[ $sDoLog == "dir" && $model ]] && echo "$data" >> "$logbase/model/${model}_$id"
    fi

    # Send message to MQTT or skip it ...
    if [[ $bSkipLine ]] ; then
        [[ $bVerbose ]] && echo "SKIPPING: $data"
        bSkipLine=""
        continue
    elif [[ $bAlways || $data != "$prev_data" ]] ; then
        [[ $bVerbose && ! $bRewrite ]] && echo "$data" # Raw message to MQTT
        nMqttLines=$(( nMqttLines + 1 ))
        prev_data="$data"
        prevval="${aReadings[${model}_${id}]}"
        aReadings[${model}_${id}]="$data"
        if [[ $bMoreVerbose ]] ; then
            _prefix="SAME:  "  &&  [[ ${aReadings[${model}_${id}]} != "$prevval" ]] && _prefix="CHANGE(${#aReadings[@]}):"
            grep -E --color=auto '^[^/]*|/' <<< "$_prefix ${model}_${id} /${aReadings[${model}_${id}]}/$prevval/"
        fi
        if [[ -z $bEliminateDups || ${aReadings[${model}_${id}]} != "$prevval"  ]] ; then # rcvd data should be different from previous reading!

            # for now, only  only temperature and humidity sensors are announced for auto-discovery:
            [[ -z $prevval && $_bHasTemperature ]] && hass_announce "" "$basetopic" "${model}/${id}" "(${id}) Temp"  "Rtl433 ${model}" "value_json.temperature_C" "temperature" # $sitecode "$nodename" "publicwifi/localclients" "Readable name" "$ad_devname" "value_json.count" "$icontype"           
            [[ -z $prevval && $_bHasHumidity    ]] && hass_announce "" "$basetopic" "${model}/${id}" "(${id}) Humid" "Rtl433 ${model}" "value_json.humidity" "humidity" # $sitecode "$nodename" "publicwifi/localclients" "Readable name" "$ad_devname" "value_json.count" "$icontype"
        
            publish_to_mqtt_starred "$basetopic${model:+/}$model${id:+/}$id" "${data//\"/*}" # ... publish it!
        fi
    fi
    _string="*event*:*log*,*sensorcount*:*${#aReadings[@]}*,*mqttlinecount*:*$nMqttLines*,*receivedcount*:*$nReceivedCount*"
    if (( nPrevMax < ${#aReadings[@]} )) ; then                 # we have a new sensor
        nPrevMax=${#aReadings[@]}
        publish_to_mqtt_starred "$basetopic" "{$_string,note:*sensor added*, latest_model:*${model}*,latest_id:*${id}*}"
    elif (( nMqttLines % (${#aReadings[@]}*10) == 0 )) ; then   # log once in a while, good heuristic in a generalized neighbourhood
        _collection="*sensorreadings*: [ true $(  
            for KEY in "${!aReadings[@]}"; do
                _reading="${aReadings[$KEY]}" && _reading="${_reading/{/}" && _reading="${_reading/\}/}"
                echo ", { *model_id*:*$KEY*, ${_reading//\"/*} }"
            done
        ) ]"
        log "$( expand_starred_string "$_collection" )" 
        publish_to_mqtt_starred "$basetopic" "{$_string, *note*:*regular log*, *collected_model_ids*:*${!aReadings[*]}*, $_collection }"
    elif (( ${#aReadings[@]} > msgSecond % 99999 || (nReceivedCount % 9999 == 0) )) ; then # reset whole array to empty once in a while, starting over
        publish_to_mqtt_starred "$basetopic" "{$_string, *note*:*resetting saved values*, *collected_sensors*:*${!aReadings[*]}*}"
        unset aReadings && declare -A aReadings   # reset the whole collection array
        nPrevMax=$(( nPrevMax / 3 ))              # to quite a reduced number, but not back to 0, to reduce future log messages
        [[ $bRemoveAnnouncements ]] && hass_remove_announce
    fi
done

_msg="$scriptname: while-loop ended at $( date ), rtlprocid=:${rtlcoproc_PID}:"
log "$_msg" 
publish_to_mqtt_starred "$basetopic" "{ *event*:*endloop*, *note*:*$_msg* }"

# now the exit trap function will be processed...