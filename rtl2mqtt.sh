#!/bin/bash

# rtl2mqtt receives events from a RTL433 SDR and forwards them to a MQTT broker

# Adapted and enhanced for flexibility by "sheilbronn"
# (inspired by work from "IT-Berater" and M.  Verleun)

set -o noglob     # file name globbing is neither needed nor wanted (for security reasons)
set -o noclobber  # disable for security reasons
set -o pipefail
sName="${0##*/}" && sName="${sName%.sh}"
sID="$( basename "${sName// /}" .sh )" # sID="${sID}433"
sMID="$sID"

commandArgs="$*"
logbase="/var/log/$( basename "${sName// /}" .sh )" # /var/log is preferred, but will default to /tmp if not useable
manufacturer="RTL"
hassbasetopic="homeassistant/sensor/$manufacturer"
basetopic="rtl/433"                  # default MQTT topic prefix
rtl433_command="rtl_433"
rtl433_command=$( command -v $rtl433_command ) || { echo "$sName: $rtl433_command not found..." 1>&2 ; exit 1 ; }
rtl433_opts="-R -162 -R -86 -R -31 -R -37" # My specific personal excludes: 129: Eurochron gives neg. temp's
rtl433_opts="-G 4 -M protocol -C si $rtl433_opts" 
rtl433version="$( $rtl433_command -V 2>&1 | awk -- '$2 ~ /version/ { print $3 ; exit }' )" || exit 1

declare -i nLogMinutesPeriod=10
declare -i nLogMessagesPeriod=50
declare -i nLastStatusSeconds=$(( $(date +%s) - nLogMinutesPeriod*60 + 30 ))
declare -i nMqttLines=0     
declare -i nReceivedCount=0 
declare -i nPrevMax=1       # start with 1 for non-triviality
declare -A aReadings
declare -A aCounts

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

rotate_logdir_sometimes () {           # check for log file rotation and maybe do it sometimes
    if (( msgMinute + msgSecond == 67 )) ; then  # rotate log file only with probalility of 1/60
        cd "$1" && _files="$( find . -maxdepth 2 -type f -size +200k "!" -name "*.old" -exec mv '{}' '{}'.old ";" -print0 )"
        msgSecond=$(( msgSecond + 1 ))
        [[ $_files ]] && log_error "Rotated files: $_files"
    fi
  }

publish_to_mqtt_starred () {		# publish_to_mqtt_starred( [expandableTopic ,] starred_message, moreMosquittoOptions)
    if (( $# == 1 )) ; then
        _topic="/bridge/state"
        _msg="$1"
    else
        _topic="$1"
        _msg="$2"
    fi
    _topic="${_topic/#\//$basetopic/}"
    mosquitto_pub ${mqtthost:+-h $mqtthost} ${sMID:+-i $sMID} -t "$_topic" -m "$( expand_starred_string "$_msg" )" $3 $4 $5 # ...  
  }

normalize_config_topic_part() {
    printf "%s" "${1//[ \/-]/}" | tr "[:upper:]" "[:lower:]"
  }

#                    hass_announce "" "$basetopic" "${model}/${id}" "(${id}) Temp" "Rtl433 ${model}" "value_json.temperature_C" "temperature"
hass_announce() { # $sitecode "$nodename" "publicwifi/localclients" "Readable name" 5:"$ad_devname" 6:"value_json.count" "$icontype"
	local -
    local _topicpart="${3%/set}"
	local _devid="$( basename "$_topicpart" )"
	local _command_topic_str="$( [ "$3" != "$_topicpart" ] && echo ",*cmd_t*:*~/set*" ) "  # determined by suffix ".../set"
    local _name="${5:+$5-}$4" && _name="${_name// /-}" && _name="${_name//[)()]/}"   #   echo ${5:+$5-}$4 | tr ' ' '-' | tr -d 'x'
    local _configtopicpart="$( normalize_config_topic_part "$3" )"
    local _topic="${hassbasetopic}$_configtopicpart/$7/config"  # example : homeassistant/sensor/0x00158d0003a401e2/{temperature,humidity}/config

    local _devname="$5 $_devid"
    local _channelname="$_devname ${7^}"
    local _sensortopic="${1:+$1/}$2/$_topicpart"
    local _value_template_str="${6:+,*value_template*:*{{ $6 \}\}*}"
    local _icon_str="${7:+,*icon*:*mdi:mdi-$7*}"  # mdi icons: https://cdn.materialdesignicons.com/5.4.55/
	# local *friendly_name*:*${5:+$5 }$4*,
    local _unit=""

    case "${6#value_json.}" in
        temperature*) _unit="°C" ;;
        humidity)     _unit="%" ;;
    esac
                        : --  *device*:{*name*:*$_devname*,*mdl*:*$5 sender*,*ids*:[*RTL433_$_configtopicpart*],*sw*:*$rtl433version* }
                        : --  *device*:{*identifiers*:[*${sID}_${_configtopicpart}*],*manufacturer*:*RTL*,*model*:*A $5 sensor on channel $_devid*,*name*:*$_devname*,*sw_version*:*RTL2MQTT V1*}
    local  _hassdevicestring="*device*:{*identifiers*:[*${sID}_${_configtopicpart}*],*manufacturer*:*$manufacturer*,*model*:*$5 sensor on channel $_devid*,*name*:*$_devname*,*sw_version*:*rtl_433 $rtl433version*}"
    local  _msg="{*availability*:[{*topic*:*$basetopic/bridge/state*}],$_hassdevicestring,*device_class*:*$7*,*json_attributes_topic*:*$_sensortopic*,*name*:*$_channelname*,*state_topic*:*$_sensortopic*,*unique_id*:*${sID}_${_configtopicpart}${7}*,*unit_of_measurement*:*$_unit*${_value_template_str}${_command_topic_str}$_icon_str}"

    # : {"availability":[{"topic":"zigbee2mqtt/bridge/state"}],"device":{"identifiers":["zigbee2mqtt_0x00158d0003a401e2"],"manufacturer":"Xiaomi","model":"MiJia temperature & humidity sensor (WSDCGQ01LM)","name":"Aqara-Sensor","sw_version":"Zigbee2MQTT 1.16.2"},"device_class":"temperature","json_attributes_topic":"zigbee2mqtt/Aqara-Sensor","name":"Aqara-Sensor_temperature","state_topic":"zigbee2mqtt/Aqara-Sensor","unique_id":"0x00158d0003a401e2_temperature_zigbee2mqtt","unit_of_measurement":"C","value_template":"{{ value_json.temperature }}"}
    # : {*availability*:[{*topic*:*$basetopic/bridge/state*}],*device*:{*identifiers*:[*${sID}_${_configtopicpart}*],*manufacturer*:*RTL*,*model*:*A $5 sensor*,*name*:*$_devname*,*sw_version*:*RTL2MQTT V1*},*device_class*:*$7*,*json_attributes_topic*:*zigbee2mqtt/Aqar-Sensor*,*name*:*Aqar-Sensor_humidity*,*state_topic*:*zigbee2mqtt/Aqar-Sensor*,*unique_id*:*0x00158d0003a401e2x_humidity_zigbee2mqtt*,*unit_of_measurement*:*%*,*value_template*:*{{ value_json.humidity }}*}
    # : {"availability":[{"topic":"zigbee2mqtt/bridge/state"}],"device":{"identifiers":["zigbee2mqtt_0x00158d0003a401e2"],"manufacturer":"Xiaomi","model":"MiJia temperature & humidity sensor (WSDCGQ01LM)","name":"Aqara-Sensor","sw_version":"Zigbee2MQTT 1.16.2"},"device_class":"humidity","json_attributes_topic":"zigbee2mqtt/Aqara-Sensor","name":"Aqara-Sensor_humidity","state_topic":"zigbee2mqtt/Aqara-Sensor","unique_id":"0x00158d0003a401e2_humidity_zigbee2mqtt","unit_of_measurement":"%","value_template":"{{ value_json.humidity }}"}

   	publish_to_mqtt_starred "$_topic" "$_msg" "-r"
  }

hass_remove_announce() {
    _topic="$hassbasetopic/#" 
    _topic="$( dirname $hassbasetopic )/#" # deletes eveything below "homeassistant/sensor/..." !
    [[ $bVerbose ]] && echo "$sName: removing all announcements below $_topic..."
    mosquitto_sub ${mqtthost:+-h $mqtthost} ${sMID:+-i $sMID} -W 1  -t "$_topic" --remove-retained --retained-only
    publish_to_mqtt_starred "{ *event*:*cleaned*,note:*removed all announcements starting with $_topic* }"
}

del_json_attribute () {
    jq -c "del($1)" <<< "$2"
}

while getopts "?qh:pt:drl:f:F:C:T:ae2vx" opt      
do
    case "$opt" in
    \?) echo "Usage: $sName -h brokerhost -t basetopic -p -r -r -d -l -a -e [-F freq] [-f file] -q -v -x" 1>&2
        exit 1
        ;;
    q)  bQuiet="yes"
        ;;
    h)  # configure the broker host here or in $HOME/.config/mosquitto_sub
        case "$OPTARG" in     #  http://www.steves-internet-guide.com/mqtt-hosting-brokers-and-servers/
		test)    mqtthost="test.mosquitto.org" ;; # abbreviation
		eclipse) mqtthost="mqtt.eclipse.org"   ;; # abbreviation
        hivemq)  mqtthost="broker.hivemq.com"   ;;
		*)       mqtthost="$( echo "$OPTARG" | tr -c -d '0-9a-z_.' )" ;; # clean up for sec purposes
		esac
        ;;
    p)  bAnnouceHass="yes"
        ;;
    t)  basetopic="$OPTARG" # other base topic for MQTT
        ;;
    d)  bRemoveAnnouncements="yes" # delete (remove) all retained auto-discovery announcements (before starting), needs newer mosquitto_sub
        ;;
    r)  # rewrite and simplify output
        if [[ $bRewrite ]] ; then
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
            rtl433_opts="$rtl433_opts -f 868428000 -s 1024k" # frequency
        else
            rtl433_opts="$rtl433_opts -f $OPTARG"
        fi
        ;;
    C)  maxcount="$OPTARG" # currently unused
        ;;
    T)  nMaxSeconds="$OPTARG"
        ;;
    e)  bEliminateDups="yes" # eliminate duplicate receptions (=same ones immediately following each other from the same sensor)
        ;;
    a)  bAlways="yes" 
        ;;
    2)  bTryAlternate="yes" # ease experiments (not used in production)
        ;;
    v)  [ "$bVerbose" = "yes" ] && bMoreVerbose="yes"
        bVerbose="yes" # more output for debugging purposes
        ;;
    x)  set -x # turn on shell debugging from here on
        ;;
    esac
done

shift "$((OPTIND-1))"   # Discard options processed by getopts, any remaining options will be passed to mosquitto_sub further down on

rtl433_opts="$rtl433_opts${nMaxSeconds:+ -T $nMaxSeconds}"

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
sdr_tuner="$( echo "$startup" | grep '^Found '   | sed -e 's/Found //' -e 's/ tuner//' )"
sdr_freq="$( echo "$startup" | grep '^Tuned to ' | sed -e 's/^Tuned to //' -e 's/\.$//' )"

trap_exit() {   # stuff to do when exiting
    log "$sName exiting at $( date )"
    [ "$bRemoveAnnouncements" ] && hass_remove_announce
    [ "$rtlcoproc_PID" ] && kill "$rtlcoproc_PID" && [ $bVerbose ] && echo "$sName: Killed coproc PID $_cppid" 1>&2
    sleep 1
    nReadings=${#aReadings[@]}
    publish_to_mqtt_starred "{ *event*:*stopping*,receivedcount:*$nReceivedCount*,mqttlinecount:*$nMqttLines*,rtl433pid:*${rtlcoproc_PID:-ENDED} (was $_cppid)*,*sensorcount:*${nReadings:-0}*,collected_sensors:*${!aReadings[*]}* }"
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

echo_if_not_duplicate() {
    if [[ $1 != "$gPrevData" ]] ; then
        [[ $bWasDuplicate ]] && echo "" # newline after some dots
        echo "$1"
        gPrevData="$1" # save the previous data
        bWasDuplicate=""
    else
        printf ". "
        bWasDuplicate="yes"
    fi
 }

_statistics="*tuner*:*$sdr_tuner*,*freq*:*$sdr_freq*,*additional_rtl433_opts*:*$rtl433_opts*,*logto*:*$logbase ($sDoLog)*,*rewrite*:*${bRewrite:-no}${bRewriteMore}*"
if [ -t 1 ] ; then # probably on a terminal
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
[[ $bVerbose || -t 1 ]] && log_error "options for rtl_433 are: $rtl433_opts"
if [[ $replayfile ]] ; then
    coproc rtlcoproc ( cat "$replayfile" )
else
    coproc rtlcoproc ( $rtl433_command  $rtl433_opts -F json )   # options are not double-quoted on purpose
    renice -n 10 "${rtlcoproc_PID}"
fi 

_cppid="$rtlcoproc_PID" # save it as an permanent variable

[[ $rtlcoproc_PID ]] && hass_announce "" "$basetopic" "bridge/state" "(0) Count"  "Rtl433 Bridge" "value_json.sensorcount" "sensorcount"  && sleep 1

while read -r data <&"${rtlcoproc[0]}"         # ... and enter an (almost) endless loop
do
    # [[ $bQuiet ]] && [[ $data  =~ ^rtl_433:\ warning: ]] && continue
    nReceivedCount=$(( nReceivedCount + 1 ))
    data="$( del_json_attribute ".mic" "$data" )"   # .mic is useless
    log "$data"
    msgTime="${data[*]/\",*/}"
    msgHour="${msgTime:(-8):2}"   && msgHour="${msgHour#0}" 
    msgMinute="${msgTime:(-5):2}" && msgMinute="${msgMinute#0}" 
    msgSecond="${msgTime:(-2):2}" && msgSecond="${msgSecond#0}" # no subprocess needed...
    data="$( del_json_attribute ".time" "$data"  )" # .time is redundant

    if [[ $bRewrite ]] ; then                  # Rewrite and clean the line from less interesting information....
        [[ $bVerbose ]] && echo_if_not_duplicate "RCVD: $data"
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
        data="$( sed -e 's/"temperature_C":\([0-9.-]*\)/"temperature":"\1"/' -e 's/"humidity":\([0-9.]*\)/"humidity":"\1"/' <<< "$data" )" # hack to cut off "_C" and to add double-quotes not using jq

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
        [[ $bVerbose && ! $bRewrite ]] && echo_if_not_duplicate "RCVD: $data" # Raw message to MQTT
        nMqttLines=$(( nMqttLines + 1 ))
        prev_data="$data"
        prevval="${aReadings[${model}_${id}]}"
        aReadings[${model}_${id}]="$data"
        aCounts[${model}_${id}]="$(( aCounts[${model}_${id}] + 1 ))"
        if [[ $bMoreVerbose ]] ; then
            _prefix="SAME:  "  &&  [[ ${aReadings[${model}_${id}]} != "$prevval" ]] && _prefix="CHANGE(${#aReadings[@]}):"
            grep -E --color=auto '^[^/]*|/' <<< "$_prefix ${model}_${id} /${aReadings[${model}_${id}]}/$prevval/"
        fi
        if [[ $bEliminateDups != "yes" || ${aReadings[${model}_${id}]} != "$prevval"  ]] ; then # rcvd data should be different from previous reading!

            # for now, only  only temperature and humidity sensors are announced for auto-discovery:

            # $sitecode "$nodename" "publicwifi/localclients" "Readable name" "$ad_devname" "value_json.count" "$icontype"           
            [[ -z $prevval && $_bHasTemperature ]] && hass_announce "" "$basetopic" "${model}/${id}" "(${id}) Temp"  "${model}" "value_json.temperature" "temperature"  && sleep 1

            # $sitecode "$nodename" "publicwifi/localclients" "Readable name" "$ad_devname" "value_json.count" "$icontype"
            [[ -z $prevval && $_bHasHumidity    ]] && hass_announce "" "$basetopic" "${model}/${id}" "(${id}) Humid" "${model}" "value_json.humidity" "humidity" && sleep 1
        
            publish_to_mqtt_starred "$basetopic${model:+/}$model${id:+/}$id" "${data//\"/*}" # ... publish it!
        else
            [[ $bVerbose ]] && echo "Duplicate suppressed." 
        fi
    fi
    nReadings=${#aReadings[@]} # && nReadings=${nReadings#0} # remove any leading 0
    _statistics="*sensorcount*:*${nReadings:-0}*,*mqttlinecount*:*$nMqttLines*,*receivedcount*:*$nReceivedCount*,*readingscount*:*$nReadings*"

    if (( nReadings > nPrevMax )) ; then                 # a new max means we have a new sensor
        nPrevMax=nReadings
        publish_to_mqtt_starred "{*event*:*status*,note:*sensor added*,$_statistics,latest_model:*${model}*,latest_id:*${id}*}"
    elif (( $(date +%s) > nLastStatusSeconds+nLogMinutesPeriod*60 || (nMqttLines % nLogMessagesPeriod)==0 )) ; then   # log once in a while, good heuristic in a generalized neighbourhood
        _collection="*sensorreadings*: [ $(  _comma=""
            for KEY in "${!aReadings[@]}"; do
                _reading="${aReadings[$KEY]}" && _reading="${_reading/{/}" && _reading="${_reading/\}/}"
                echo -n "$_comma { *model_id*:*$KEY*, ${_reading//\"/*} }"
                _comma=","
            done
        ) ]"
        log "$( expand_starred_string "$_collection" )" 
        publish_to_mqtt_starred "{*event*:*status*,*note*:*regular log*,$_statistics,*collected_model_ids*:*${!aReadings[*]}*, $_collection }"
        nLastStatusSeconds="$( date +%s )"
    elif (( nReadings > (msgSecond*msgSecond+2)*(msgMinute+1)*(msgHour+1) || nMqttLines%5000==0 || nReceivedCount % 10000 == 0 )) ; then # reset whole array to empty once in a while = starting over
        publish_to_mqtt_starred "{*event*:*status*,*note*:*resetting saved values*,$_statistics,*collected_sensors*:*${!aReadings[*]}*}"
        unset aReadings && declare -A aReadings # reset the whole collection array
        unset aCounts   && declare -A aCounts
        nPrevMax=$(( nPrevMax / 3 ))            # reduce it (but not back to 0) to reduce future log messages
        [[ $bRemoveAnnouncements ]] && hass_remove_announce
    fi
done

_msg="$sName: while-loop ended at $( date ), rtlprocid=:${rtlcoproc_PID}:"
log "$_msg" 
publish_to_mqtt_starred "{ *event*:*endloop*, *note*:*$_msg* }"

# now the exit trap function will be processed...