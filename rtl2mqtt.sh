#!/bin/bash

# A shell script that receives events from a RTL433 SDR and forwards them to a MQTT broker

# Original Author: Marco Verleun <marco@marcoach.nl>
# Fork of version from "IT-Berater"
# Adapted and enhanced for flexibility by "sheilbronn"

set -o noglob     # file name globbing is neither needed or nor wanted for security reasons
set -o noclobber  # disable for security reasons
set -o pipefail
sName="${0##*/}"

# Set Host
commandArgs="$*"
logbase="/var/log/$( basename "${sName// /}" .sh )" # /var/log is preferred, but will default to /tmp if not useable
mqtthost="test.mosquitto.org"        # default MQTT broker, unsecure ok.
basetopic="Rtl/433"                  # default MQTT topic prefix
hassbasetopic="homeassistant/sensor/RTL433"
rtl433_command=$( command -v rtl_433 ) || { echo "$sName: rtl_433 not found..." 1>&2 ; exit 1 ; }
rt433_opts="-G 4 -M protocol -C si -R -162 -R -86 -R -31 -R -37"
rtl433version="$( $rtl433_command -V 2>&1 | awk -- '$2 ~ /version/ { print $3 ; exit }' )" || exit 1

declare -i nLogMinutesPeriod=10
declare -i nLogMessagesPeriod=50
declare -i nLastStatusSeconds=$(( $(date +%s) - nLogMinutesPeriod*60 + 30 ))
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
    echo "$sName:" "$@" 1>&2
    logger "$sName:" "$@"
    log "$@"
  }

expand_starred_string () {   
    _string="${1//\"/\'}"  &&  echo "${_string//\*/\"}" 
  }

rotate_logdir_sometimes () {           # check for log file rotation and maybe do it (sometimes)
    if (( msgMinute + msgSecond == 67 )) ; then  # rotate log file only with probalility of 1/60
        cd "$1" && _files="$( find . -maxdepth 2 -type f -size +200k "!" -name "*.old" -exec mv '{}' '{}'.old ";" -print0 )"
        msgSecond=$(( msgSecond + 1 ))
        [[ $_files ]] && log_error "Rotated files: $_files"
    fi
  }

publish_to_mqtt_starred () {		# publish_to_mqtt_starred( [expandableTopic ,] starred_message, moreMosquittoOptions)
    if (( $# == 1 )) ; then
        _topic="/bridge"
        _msg="$1"

    else
        _topic="$1"
        _msg="$2"
    fi
    _topic="${_topic/#\//$basetopic/}"
    mosquitto_pub -h "$mqtthost" -i RTL_433 -t "$_topic" -m "$( expand_starred_string "$_msg" )" $3 $4 $5 # ...  
  }

normalize_config_topic_part() {
    printf "%s" "${1//[ \/-]/}" | tr "[:upper:]" "[:lower:]"
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
    local _configtopicpart="$( normalize_config_topic_part "$3" )"
#	local _hassdevicestring="*device*:{*name*:*$5*, *mdl*:*RTL433 receiver*, *mf*:*RTL433*, *ids*: [*${sName}${1:+_$1}_RTL433*]}"
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
    publish_to_mqtt_starred "{ *event*:*cleaned*,note:*removed all announcements starting with $hassbasetopic* }"
}

del_json_attribute () {
    jq -c "del($1)" <<< "$2"
}

while getopts "?qh:pt:drl:f:F:C:aevx" opt      
do
    case "$opt" in
    \?) echo "Usage: $sName -m host -t basetopic -r -l -a -v" 1>&2
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
            bRewriteMore="yes" && [[ $bVerbose ]] && echo "$sName: rewriting even more ..."
        else
            bRewrite="yes"  # rewrite and simplify output
        fi
        ;;
    l)  logbase="$OPTARG" 
        ;;
    f)  replayfile="$OPTARG" # file to replay (e.g. for debugging), instead of rtl_433 output
        ;;
    F)  if [ "$OPTARG" = "868" ] ; then
            rt433_opts="$rt433_opts -f 868428000 -s 1024k" # frequency
        else
            rt433_opts="$rt433_opts -f $OPTARG" # 
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
    sDoLog="dir"
    if mkdir -p "$logbase/model" && [ -w "$logbase" ] ; then
        :
    else
        logbase="/tmp/${sName// /}" && log_error "defaulting to logbase $logbase"
        mkdir -p "$logbase/model" || { log_error "can't mkdir $logbase/model" ; exit 1 ; }
    fi
    cd "$logbase" || { log_error "can't cd to $logbase" ; exit 1 ; }
fi

[ "$( command -v jq )" ] || { log_error "$sName: jq must be available!" ; exit 1 ; }

startup="$( $rtl433_command -T 1 2>&1 )"
sdr_tuner="$( echo "$startup" | grep '^Found ' | sed -e 's/Found //' -e 's/ tuner//' )"
sdr_freq="$( echo "$startup" | grep '^Tuned to ' | sed -e 's/^Tuned to //' -e 's/\.$//' )"

trap_exit() {   # stuff to do when exiting
    log "$sName exiting at $( date )"
    [ "$bRemoveAnnouncements" ] && hass_remove_announce
    [ "$rtlcoproc_PID" ] && kill "$rtlcoproc_PID" && [ $bVerbose ] && echo "$sName: Killed coproc PID $_cppid" 1>&2
    sleep 1
    publish_to_mqtt_starred "{ *event*:*stopping*,receivedcount:*$nReceivedCount*,mqttlinecount:*$nMqttLines*,rtl433pid:*${rtlcoproc_PID:-ENDED} (was $_cppid)*,*sensorcount:*${#aReadings[@]}*,collected_sensors:*${!aReadings[*]}* }"
 }
trap 'trap_exit' EXIT # previously also: INT QUIT TERM 

trap_usr1() {    # log state to MQTT
    log "$sName received signal USR1: logging to MQTT"
    publish_to_mqtt_starred "{*event*:*status*,note:*rcvd signal USR1*,*sensorcount*:*${#aReadings[@]}*,*mqttlinecount*:*$nMqttLines*,*receivedcount*:*$nReceivedCount*,
        *collected_sensors*:*${!aReadings[*]}* }"
    nLastStatusSecondsSeconds="$( date +%s )"
 }
trap 'trap_usr1' USR1 

trap_usr2() {    # remove all home assistant announcements 
    log "$sName received signal USR1: removing all home assistant announcements"
    hass_remove_announce
  }
trap 'trap_usr2' USR2 

echo_potentially_duplicate_data() {
    if [[ $1 != "$gPrevData" ]] ; then
        [[ $bWasDuplicate ]] && echo "" # newline after some dots
        echo "$data"
        gPrevData="$1" # save the previous data
        bWasDuplicate=""
    else
        printf ". "
        bWasDuplicate="yes"
    fi
 }

_statistics="*tuner*:*$sdr_tuner*,*freq*:*$sdr_freq*,*additional_rt433_opts*:*$rt433_opts*,*logto*:*$logbase ($sDoLog)*,*rewrite*:*${bRewrite:-no}*"
if [ -t 1 ] ; then # probably terminal
    log "$sName starting at $( date )"
    publish_to_mqtt_starred "{*event*:*starting*,$_statistics }"
else               # probably non-terminal
    delayedStartSecs=3
    log "$sName starting in $delayedStartSecs secs from $( date )"
    sleep "$delayedStartSecs"
    publish_to_mqtt_starred "{*event*:*starting*,$_statistics,note:*delayed by $delayedStartSecs secs*,*user*:*$( id -nu )*,*cmdargs*:*$commandArgs*}"
fi

# Optionally remove any matching retained announcements
[[ $bRemoveAnnouncements ]] && hass_remove_announce

# Start the RTL433 listener ....
[[ $bVerbose || -t 1 ]] && log_error "options for rtl_433 are: $rt433_opts"
if [[ $replayfile ]] ; then
    coproc rtlcoproc ( cat "$replayfile" )
else
    coproc rtlcoproc ( $rtl433_command  $rt433_opts -F json )   # options are not double-quoted on purpose
    renice -n 10 "${rtlcoproc_PID}"
fi 

_cppid="$rtlcoproc_PID" # save it as an permanent variable

while read -r data <&"${rtlcoproc[0]}"         # ... and enter an (almost) endless loop
do
    # [[ $bQuiet ]] && [[ $data  =~ ^rtl_433:\ warning: ]] && continue
    nReceivedCount=$(( nReceivedCount + 1 ))
    data="$( del_json_attribute ".mic" "$data" )"   # .mic is useless
    log "$data"
    msgSecond="${data[*]/\",*/}" && msgMinute="${msgSecond:(-5):2}" && msgMinute="${msgMinute#0}" && msgSecond="${msgSecond:(-2):2}" && msgSecond="${msgSecond#0}" # no subprocess needed...
    data="$( del_json_attribute ".time" "$data"  )" # .time is redundant

    if [[ $bRewrite ]] ; then                  # Rewrite and clean the line from less interesting information....
        [[ $bVerbose ]] && echo_potentially_duplicate_data "$data"
        model="$( jq -r '.model // empty' <<< "$data" )"    
        id="$(    jq -r '.id    // empty' <<< "$data" )"

        temp="$( jq -e -r 'if .temperature_C then .temperature_C*10 + 0.5 | floor / 10 else empty end' <<< "$data" )"
        if [[ $temp ]] ; then
            _bHasTemperature="yes"
            data="$( jq -cer ".temperature_C = $temp" <<< "$data" )"
        else 
            _bHasTemperature=""
        fi
        _bHasHumidity="$( jq -e -r 'if (.humidity and .humidity<=100) then "yes" else empty end' <<< "$data" )"
        _bHasRain="$(     jq -e -r 'if (.rain_mm  and .rain_mm  >0  ) then "yes" else empty end' <<< "$data" )"

        data="$( jq -c "del(.model) | del(.id) | del(.protocol) | del(.subtype) | del(.channel)" <<< "$data" )"
        data="$( sed -e 's/"temperature_C":\([0-9]*\)\(\.[0-9]*\)/"temperature":\1\2/' -e 's/"humidity":\([0-9.]*\)/"humidity":\1/' <<< "$data" )" # hack to cut off "_C" not using jq

        if [[ $bRewriteMore ]] ; then
            data="$( del_json_attribute ".transmit" "$data"  )"        

            data="$( jq -c 'if .button     == 0 then del(.button    ) else . end' <<< "$data" )"
            data="$( jq -c 'if .battery_ok == 1 then del(.battery_ok) else . end' <<< "$data" )"
            data="$( jq -c 'if .unknown1   == 0 then del(.unknown1)   else . end' <<< "$data" )"

            # bSkipLine="$( jq -e -r 'if (.humidity and .humidity>100) or (.temperature_C and .temperature_C<-50) or (.temperature and .temperature<-50) or .rain_mm>0 then "yes" else empty end' <<<"$data"  )"
        fi
        [[ $sDoLog == "dir" && $model ]] && echo "$data" >> "$logbase/model/${model}_$id"
    fi

    # Send message to MQTT or skip it ...
    if [[ $bSkipLine ]] ; then
        [[ $bVerbose ]] && echo "SKIPPING: $data"
        bSkipLine=""
        continue
    elif [[ $bAlways || $data != "$prev_data" ]] ; then
        [[ $bVerbose && ! $bRewrite ]] && echo_potentially_duplicate_data "$data" # Raw message to MQTT
        nMqttLines=$(( nMqttLines + 1 ))
        prev_data="$data"
        prevval="${aReadings[${model}_${id}]}"
        aReadings[${model}_${id}]="$data"
        if [[ $bMoreVerbose ]] ; then
            _prefix="SAME:  "  &&  [[ ${aReadings[${model}_${id}]} != "$prevval" ]] && _prefix="CHANGE(${#aReadings[@]}):"
            grep -E --color=auto '^[^/]*|/' <<< "$_prefix ${model}_${id} /${aReadings[${model}_${id}]}/$prevval/"
        fi
        if [[ $bEliminateDups != "yes" || ${aReadings[${model}_${id}]} != "$prevval"  ]] ; then # rcvd data should be different from previous reading!

            # for now, only  only temperature and humidity sensors are announced for auto-discovery:
            [[ -z $prevval && $_bHasTemperature ]] && hass_announce "" "$basetopic" "${model}/${id}" "(${id}) Temp"  "Rtl433 ${model}" "value_json.temperature_C" "temperature" # $sitecode "$nodename" "publicwifi/localclients" "Readable name" "$ad_devname" "value_json.count" "$icontype"           
            [[ -z $prevval && $_bHasHumidity    ]] && hass_announce "" "$basetopic" "${model}/${id}" "(${id}) Humid" "Rtl433 ${model}" "value_json.humidity" "humidity" # $sitecode "$nodename" "publicwifi/localclients" "Readable name" "$ad_devname" "value_json.count" "$icontype"
        
            publish_to_mqtt_starred "$basetopic${model:+/}$model${id:+/}$id" "${data//\"/*}" # ... publish it!
        else
            [[ $bVerbose ]] && echo "Duplicate suppressed." 
        fi
    fi
    nReadings=${#aReadings[@]} && nReadings=${nReadings#0} # remove any leading 0
    _statistics="*sensorcount*:*$nReadings*,*mqttlinecount*:*$nMqttLines*,*receivedcount*:*$nReceivedCount*,*readingscount*:*$nReadings*"

    if (( nReadings > nPrevMax )) ; then                 # a new max means we have a new sensor
        nPrevMax=nReadings
        publish_to_mqtt_starred "{*event*:*status*,note:*sensor added*,$_statistics,latest_model:*${model}*,latest_id:*${id}*}"
    elif (( $(date +%s) > nLastStatusSeconds+nLogMinutesPeriod*60 || (nMqttLines % nLogMessagesPeriod)==1 )) ; then   # log once in a while, good heuristic in a generalized neighbourhood
        _collection="*sensorreadings*: [
            $( _comma=""
            for KEY in "${!aReadings[@]}"; do
                _reading="${aReadings[$KEY]}" && _reading="${_reading/{/}" && _reading="${_reading/\}/}"
                echo "$_comma { *model_id*:*$KEY*, ${_reading//\"/*} }"
                _comma=","
            done
        ) ]"
        log "$( expand_starred_string "$_collection" )" 
        publish_to_mqtt_starred "{*event*:*status*,*note*:*regular log*,$_statistics,*collected_model_ids*:*${!aReadings[*]}*, $_collection }"
        nLastStatusSeconds="$( date +%s )"
    elif (( ( nReadings > msgSecond*msgSecond*(msgMinute+1) ) || ((nReceivedCount % 1000) == 0) )) ; then # reset whole array to empty once in a while = starting over
        publish_to_mqtt_starred "{*event*:*status*,*note*:*resetting saved values*,$_statistics,*collected_sensors*:*${!aReadings[*]}*}"
        unset aReadings && declare -A aReadings   # reset the whole collection array
        nPrevMax=$(( nPrevMax / 3 ))              # to quite a reduced number, but not back to 0, to reduce future log messages
        [[ $bRemoveAnnouncements ]] && hass_remove_announce
    fi
done

_msg="$sName: while-loop ended at $( date ), rtlprocid=:${rtlcoproc_PID}:"
log "$_msg" 
publish_to_mqtt_starred "{ *event*:*endloop*, *note*:*$_msg* }"

# now the exit trap function will be processed...