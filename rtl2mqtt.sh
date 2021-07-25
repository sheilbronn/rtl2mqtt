#!/bin/bash

# rtl2mqtt receives events from a RTL433 SDR and forwards them to a MQTT broker

# Adapted and enhanced for flexibility by "sheilbronn"
# (inspired by work from "IT-Berater" and M.  Verleun)

set -o noglob     # file name globbing is neither needed nor wanted (for security reasons)
set -o noclobber  # disable for security reasons
set -o pipefail
sName="${0##*/}" && sName="${sName%.sh}"
sMID="$( basename "${sName// /}" .sh )"
sID="${sMID}"

commandArgs="$*"
logbase="/var/log/$( basename "${sName// /}" .sh )" # /var/log is preferred, but will default to /tmp if not useable
sManufacturer="RTL"
# hasstopicprefix="homeassistant/sensor/$sManufacturer"
hasstopicprefix="homeassistant/sensor" 
basetopic="rtl/433"                  # default MQTT topic prefix
rtl433_command="rtl_433"
rtl433_command=$( command -v $rtl433_command ) || { echo "$sName: $rtl433_command not found..." 1>&2 ; exit 1 ; }
rtl433_opts="-R -162 -R -86 -R -31 -R -37 -R -129 -R 10 -R 53" # My specific personal excludes: 129: Eurochron-TH gives neg. temp's
rtl433_opts="$rtl433_opts -R 10 -R 53" # Additional specific personal excludes
rtl433_opts="-G 4 -M protocol -C si $rtl433_opts"  # generic options for everybody
rtl433version="$( $rtl433_command -V 2>&1 | awk -- '$2 ~ /version/ { print $3 ; exit }' )" || exit 1
sSuppressAttrs="mic time" # attrs that will be always eliminated
sSensorMatch=".*" # sensor names will have to match this regex
sRoundTo="0.5"

declare -i nLogMinutesPeriod=60
declare -i nLogMessagesPeriod=1000
declare -i nLastStatusSeconds=90
declare -i nMinSecondsOther=10 # only at least every 10 seconds
declare -i nMinSecondsTempSensor=200 # only at least every 180+20 seconds
declare -i nTimeStamp
declare -i nMqttLines=0     
declare -i nReceivedCount=0
declare -i nAnnouncedCount=0
declare -i nMinOccurences=3
declare -i nPrevMax=1       # start with 1 for non-triviality
declare -l bAnnounceHass="1" # default is yes for now
declare -A aLastReadings
declare -A aCounts
declare -A aProtocols
declare -A aPrevTempVals
declare -A aLastSents
declare -A aAnnounced

export LANG=C
PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

# echo "${@:1: $#-1}" ; exit 

log() {
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

rotate_logdir_sometimes () {           # check for log file rotation
    if (( msgMinute + msgSecond == 67 )) ; then  # try log file rotation only with probalility of 1/60
        cd "$1" && _files="$( find . -maxdepth 2 -type f -size +200k "!" -name "*.old" -exec mv '{}' '{}'.old ";" -print0 )"
        msgSecond=$(( msgSecond + 1 ))
        [[ $_files ]] && log_error "Rotated files: $_files"
    fi
  }

publish_to_mqtt_starred () {		# options: ( [expandableTopic ,] starred_message, moreMosquittoOptions)
    local - ; set +x
    if [[ $# -eq 1 ]] ; then
        _topic="/bridge/state"
        _msg="$1"
    else
        if [[ $1 = "state" || $1 = "log" ]] ; then
            _topic="/bridge/$1"
        else
            _topic="$1"
        fi
        _msg="$2"
    fi
    _topic="${_topic/#\//$basetopic/}"
    mosquitto_pub ${mqtthost:+-h $mqtthost} ${sMID:+-i $sMID} -t "$_topic" -m "$( expand_starred_string "$_msg" )" $3 $4 $5 # ...  
  }

publish_to_mqtt_state() {	
    _statistics="*sensorcount*:${nReadings:-0},*announcedcount*:$nAnnouncedCount,*mqttlinecount*:$nMqttLines,*receivedcount*:$nReceivedCount,*readingscount*:$nReadings"
    publish_to_mqtt_starred "state" "{$_statistics${1:+,$1}}"
}

# Parameters for hass_announce:
# $1: MQTT "base topic" for states of all the device(s), e.g. "rtl/433" or "ffmuc"
# $2: Generic device model, e.g. a certain temperature sensor model 
# $3: MQTT "subtopic" for the specific device instance,  e.g. ${model}/${id}. ("..../set" indicates writeability)
# $4: Text for specific device instance and sensor type info, e.g. "(${id}) Temp"
# $5: JSON attribute carrying the state
# $6: device "class" (of sensor, e.g. none, temperature, humidity, battery), 
#     used in the announcement topic, in the unique id, in the (channel) name, 
#     and FOR the icon and the device class 
# Examples:
# hass_announce "$basetopic" "Rtl433 Bridge" "bridge/state"  "(0) SensorCount"   "value_json.sensorcount"   "none"
# hass_announce "$basetopic" "Rtl433 Bridge" "bridge/state"  "(0) MqttLineCount" "value_json.mqttlinecount" "none"
# hass_announce "$basetopic" "${model}" "${model}/${id}" "(${id}) Battery" "value_json.battery_ok" "battery"
# hass_announce "$basetopic" "${model}" "${model}/${id}" "(${id}) Temp"  "value_json.temperature_C" "temperature"
# hass_announce "$basetopic" "${model}" "${model}/${id}" "(${id}) Humid"  "value_json.humidity"       "humidity" 
# hass_announce "ffmuc" "$ad_devname"  "$node/publi../localcl.." "Readable Name"  "value_json.count"   "$icontype"

hass_announce() {
	local -
    local _topicpart="${3%/set}" # if $3 ends in /set it is settable, but remove /set from state topic
 	local _devid="$( basename "$_topicpart" )"
	local _command_topic_str="$( [ "$3" != "$_topicpart" ] && echo ",*cmd_t*:*~/set*" )"  # determined by suffix ".../set"

    local _dev_class="${6#none}" # dont wont "none" as string for dev_class
    local _jsonpath="${5#value_json.}" # && _jsonpath="${_jsonpath//[ \/-]/}"
    local _jsonpath_red="$( echo "$_jsonpath" | tr -d "][ /-_" )" # "${_jsonpath//[ \/_-]/}" # cleaned and reduced, needed in unique id's
    local _configtopicpart="$( echo "$3" | tr -d "][ /-" | tr "[:upper:]" "[:lower:]" )"
    local _topic="${hasstopicprefix}/${1///}${_configtopicpart}$_jsonpath_red/${6:-none}/config"  # e.g. homeassistant/sensor/rtl433bresser3ch109/{temperature,humidity}/config
          _configtopicpart="${_configtopicpart^[a-z]*}" # uppercase first letter for readability
    local _devname="$2 ${_devid^}"
    local _icon_str=""
    if [ "$_dev_class" ] ; then
        _icon_str=",*icon*:*mdi:mdi-$_dev_class*"  # mdi icons: https://cdn.materialdesignicons.com/5.4.55/
        local _channelname="$_devname ${_dev_class^}"
    else
        local _channelname="$_devname $4" # take something meaningfull
    fi
    local _sensortopic="${1:+$1/}$_topicpart"
    local _value_template_str="${5:+,*value_template*:*{{ $5 \}\}*}"
	# local *friendly_name*:*${2:+$2 }$4*,

    local _unit_str=""
    case "$6" in
		none)		  _icon_str="" ;; 
        temperature*) _unit_str=",*unit_of_measurement*:*°C*" ;;
        humidity)     _unit_str=",*unit_of_measurement*:*%*" ;;
		clock)			_icon_str=",*icon*:*mdi:clock-outline*" ;;
        switch)       _icon_str=",*icon*:*mdi:mdi-toggle-switch*" ;;
        motion)       _icon_str=",*icon*:*mdi:motion*" ;;
        # battery*)     _unit_str=",*unit_of_measurement*:*B*" ;;  # 1 for "OK" and 0 for "LOW".
    esac

    local  _device_string="*$device*:{*identifiers*:[*${sID}${_configtopicpart}*],*manufacturer*:*$sManufacturer*,*model*:*$2 on channel $_devid*,*name*:*$_devname*,*sw_version*:*rtl_433 $rtl433version*}"
    local  _msg="*name*:*$_channelname*,*~*:*$_sensortopic*,*state_topic*:*~*,$_device_string,*device_class*:*${6:-none}*,*unique_id*:*${sID}${_configtopicpart}${_jsonpath_red^[a-z]*}*${_unit_str}${_value_template_str}${_command_topic_str}$_icon_str"
           # _msg="$_msg,*availability*:[{*topic*:*$basetopic/bridge/state*}]" # STILL TO DEBUG
           # _msg="$_msg,*json_attributes_topic*:*~*" # STILL TO DEBUG

   	publish_to_mqtt_starred "$_topic" "{$_msg}" "-r"
  }

hass_remove_announce() {
    _topic="$hasstopicprefix/#" 
    _topic="$( dirname $hasstopicprefix )/#" # deletes eveything below "homeassistant/sensor/..." !
    [[ $bVerbose ]] && echo "$sName: removing all announcements below $_topic..."
    mosquitto_sub ${mqtthost:+-h $mqtthost} ${sMID:+-i $sMID} -W 1 -t "$_topic" --remove-retained --retained-only
    _rc=$?
    publish_to_mqtt_starred "log" "{*note*:*removed all announcements starting with $_topic returned $_rc.* }"
}

del_json_attributes() {
    local - ; # set -x
    local d="xx"
    for s in ${@:1:($#-1)} ; do
        d="$d | del(.${s//[^a-zA-Z0-9_]})" # only allow certain chars for attr names for sec reasons
    done
    jq -c "${d#xx | }" <<< "${@:$#}" #     # syntax: "del(.xxx) | del(.yyy)"
}

# del_json_attributes "one" "two" "*_special*" '{"one":"1","two":2,"three":3,"four":"4","_special":"*?+","_special2":"aa*?+bb"}'  ;  exit 1

while getopts "?qh:pt:M:drl:f:F:H:w:c:as:t:T:2vx" opt      
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
    p)  bAnnounceHass="1"
        ;;
    t)  basetopic="$OPTARG" # other base topic for MQTT
        ;;
    M)  sSensorMatch="${OPTARG}.*"
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
    w)  sRoundTo="${OPTARG}" # file to replay (e.g. for debugging), instead of rtl_433 output
        ;;
    F)  if [ "$OPTARG" = "868" ] ; then
            rtl433_opts="$rtl433_opts -f 868428000 -s 1024k" # frequency
        else
            rtl433_opts="$rtl433_opts -f $OPTARG"
        fi
        ;;
    H)  nHopSecs="$OPTARG" # MQTT announcements only after at least $nMinOccurences occurences...
        rtl433_opts="$rtl433_opts -H $nHopSecs"
        ;;
    c)  nMinOccurences="$OPTARG" # MQTT announcements only after at least $nMinOccurences occurences...
        ;;
    T)  nMinSecondsOther="$OPTARG" # seconds before repeating the same reading
        ;;
    a)  bAlways="yes" 
        ;;
    s)  sSuppressAttrs="$sSuppressAttrs ${OPTARG//[^a-zA-Z0-9_]}" # sensor attributes that will be always eliminated
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

echo_if_not_duplicate() {
    if [[ "$1..$2" != "$gPrevData" ]] ; then
        [[ $bWasDuplicate ]] && echo "" # echo a newline after some dots
        echo -e "$1${2:+\n$2}"
        gPrevData="$1..$2" # save the previous data
        bWasDuplicate=""
    else
        printf "."
        bWasDuplicate="yes"
    fi
 }

_info="*tuner*:*$sdr_tuner*,*freq*:*$sdr_freq*,*additional_rtl433_opts*:*$rtl433_opts*,*logto*:*$logbase ($sDoLog)*,*rewrite*:*${bRewrite:-no}${bRewriteMore}*,*nMinOccurences*:$nMinOccurences,*nMinSecondsTempSensor*:$nMinSecondsTempSensor,*nMinSecondsOther*:$nMinSecondsOther"
if [ -t 1 ] ; then # probably on a terminal
    log "$sName starting at $( date )"
    publish_to_mqtt_starred "log" "{*event*:*starting*,$_info}"
else               # probably non-terminal
    delayedStartSecs=3
    log "$sName starting in $delayedStartSecs secs from $( date )"
    sleep "$delayedStartSecs"
    publish_to_mqtt_starred "log" "{*event*:*starting*,$_info,*note*:*delayed by $delayedStartSecs secs*,*user*:*$( id -nu )*,*cmdargs*:*$commandArgs*}"
fi

# Optionally remove any matching retained announcements
[[ $bRemoveAnnouncements ]] && hass_remove_announce

trap_exit() {   # stuff to do when exiting
    log "========= $sName exiting at $( date ) ========="
    [ "$bRemoveAnnouncements" ] && hass_remove_announce
    _cppid="$rtlcoproc_PID" # avoid race condition after killing
    [ "$rtlcoproc_PID" ] && kill "$rtlcoproc_PID" && [ $bVerbose ] && echo "$sName: Killed coproc PID $_cppid" 1>&2
    # sleep 1
    nReadings=${#aLastReadings[@]}
    publish_to_mqtt_state "*collected_sensors*:*${!aLastReadings[*]}* }"
    publish_to_mqtt_starred "log" "{ *note*:*exiting* }"
 }
trap 'trap_exit' EXIT # previously also: INT QUIT TERM 

trap_usr1() {    # log collected sensors to MQTT
    log "$sName received signal USR1: logging to MQTT"
    publish_to_mqtt_starred "log" "{*note*:*received signal USR1, will publish collected sensors* }"
    publish_to_mqtt_state "*collected_sensors*:*${!aLastReadings[*]}* }"
    nLastStatusSeconds="$( date +%s )"
 }
trap 'trap_usr1' USR1 

trap_usr2() {    # remove all home assistant announcements 
    log "$sName received signal USR1: removing all home assistant announcements"
    hass_remove_announce
  }
trap 'trap_usr2' USR2 

if [[ $replayfile ]] ; then
    coproc rtlcoproc ( cat "$replayfile" )
else
    if [[ $bVerbose || -t 1 ]] ; then
        log_error "options for rtl_433 are: $rtl433_opts"
        (( nMinOccurences > 1 )) && log_error "Will do MQTT announcements only after at least $nMinOccurences occurences..."
    fi 
    # Start the RTL433 listener as a coprocess ....
    coproc rtlcoproc ( $rtl433_command  $rtl433_opts -F json )   # options are not double-quoted on purpose
    # -F "mqtt://$mqtthost:1883,events,devices"
    renice -n 15 "${rtlcoproc_PID}"
fi 

if [[ $rtlcoproc_PID && $bAnnounceHass ]] ; then
    # _statistics="*sensorcount*:*${nReadings:-0}*,*announcedcount*:*$nAnnouncedCount*,*mqttlinecount*:*$nMqttLines*,*receivedcount*:*$nReceivedCount*,*readingscount*:*$nReadings*"
    hass_announce "$basetopic" "Rtl433 Bridge" "bridge/state" "AnnouncedCount" "value_json.announcedcount" "none"
    hass_announce "$basetopic" "Rtl433 Bridge" "bridge/state" "SensorCount"   "value_json.sensorcount"  "none"
    hass_announce "$basetopic" "Rtl433 Bridge" "bridge/state" "MqttLineCount" "value_json.mqttlinecount" "none"
    hass_announce "$basetopic" "Rtl433 Bridge" "bridge/state" "ReadingsCount" "value_json.readingscount" "none"  && sleep 1
    hass_announce "$basetopic" "Rtl433 Bridge" "bridge/log"   "LogMessage"     ""           "none"
fi

while read -r data <&"${rtlcoproc[0]}"         # ... and enter an (almost) infinite loop
do
    if [[ $data  =~ "center_frequency" ]] ; then
        [[ $bMoreVerbose ]] && echo_if_not_duplicate "RAW: $data" && publish_to_mqtt_starred "log" "$data"
        continue
    fi
    nReceivedCount=$(( nReceivedCount + 1 ))
    # [[ $bMoreVerbose ]] && echo_if_not_duplicate "RAW: $data"
    # set -x
    msgTime="${data[*]/\",*/}"
    msgHour="${msgTime:(-8):2}"   && msgHour="${msgHour#0}" 
    msgMinute="${msgTime:(-5):2}" && msgMinute="${msgMinute#0}" 
    msgSecond="${msgTime:(-2):2}" && msgSecond="${msgSecond#0}" # no subprocess needed...
    set +x
    data="$( del_json_attributes "$sSuppressAttrs" "$data" | sed -e 's/:"\([0-9.-]*\)"/:\1/g'  )" # remove double-quotes around numbers
    log "$data"
    [[ $bMoreVerbose ]] && echo_if_not_duplicate "READ: $data"
    model="$( jq -r '.model // empty' <<< "$data" )"    
    id="$(    jq -r '.id    // empty' <<< "$data" )"
    protocol="$(    jq -r '.protocol  // empty' <<< "$data" )"
    model_id="${model}_$id"
    [[ $bVerbose ]] || expr match "$model_id" "$sSensorMatch.*" > /dev/null || continue # skip early when not verbose

    if [[ $bRewrite ]] ; then                  # Rewrite and clean the line from less interesting information....
        data="$( del_json_attributes "model id protocol subtype channel" "$data" )"
        temp="$( jq -e -r "if .temperature_C then .temperature_C / $sRoundTo + 0.5 | floor * $sRoundTo else empty end" <<< "$data" )" # round to 0.2° C
        if [[ $temp ]] ; then
            _bHasTemperature="1"
            data="$( jq -cer ".temperature_C = $temp" <<< "$data" )"
            [[ ${aPrevTempVals[$model_id]} ]] || aPrevTempVals[$model_id]=0
        else 
            _bHasTemperature=""
        fi

        _bHasHumidity="$( jq -e -r 'if (.humidity and .humidity<=100) then "1" else empty end' <<< "$data" )"
        # _bHasRain="$(     jq -e -r 'if (.rain_mm  and .rain_mm  >0  ) then "1" else empty end' <<< "$data" )"
        _bHasBatteryOK="$( jq -e -r 'if (.battery_ok and .battery_ok<=2) then "1" else empty end' <<< "$data" )"
        _bHasPressureKPa="$( jq -e -r 'if (.pressure_kPa and .pressure_kPa<=9999) then "1" else empty end' <<< "$data" )"
        _bHasCmd="$( jq -e -r 'if (.cmd) then "1" else empty end' <<< "$data" )"

        if [[ $bRewriteMore ]] ; then
            data="$( del_json_attributes ".transmit" "$data"  )"
            data="$( jq -c 'if .button     == 0 then del(.button    ) else . end' <<< "$data" )"
            # data="$( jq -c 'if .battery_ok == 1 then del(.battery_ok) else . end' <<< "$data" )"
            data="$( jq -c 'if .unknown1   == 0 then del(.unknown1)   else . end' <<< "$data" )"

            bSkipLine="$( jq -e -r 'if (.humidity and .humidity>100) or (.temperature_C and .temperature_C<-50) or (.temperature and .temperature<-50) then "yes" else empty end' <<<"$data"  )"
        fi
        [[ $sDoLog == "dir" && $model ]] && echo "$data" >> "$logbase/model/$model_id"
        data="$( sed -e 's/"temperature_C":/"temperature":/' -e 's/":([0-9.-]+)/":"\&"/g'  <<< "$data" )" # hack to cut off "_C" and to add double-quotes not using jq
    fi

    nTimeStamp="$( date +%s )"
    # Send message to MQTT or skip it ...
    if [[ $bSkipLine ]] ; then
        [[ $bVerbose ]] && echo "SKIPPING: $data"
        bSkipLine=""
        continue
    elif [[ $bAlways || $data != "$prev_data" || $nTimeStamp -gt $((prev_time+nMinSecondsOther)) ]] ; then
        if [[ $bVerbose ]] ; then
            [[ $bRewrite ]] && echo_if_not_duplicate "" "CLEANED: $model_id = $data" # resulting message for MQTT
            expr match "$model_id" "$sSensorMatch.*"  > /dev/null || continue # skip if match
        fi
        prev_data="$data"
        prev_time="$nTimeStamp"
        prevval="${aLastReadings[$model_id]}" 
        aLastReadings[$model_id]="$data"
        aCounts[$model_id]="$(( aCounts[$model_id] + 1 ))"
        aProtocols[${protocol}]="$model"
        if [[ $bMoreVerbose ]] ; then
            _prefix="SAME:  "  &&  [[ ${aLastReadings[$model_id]} != "$prevval" ]] && _prefix="CHANGE(${#aLastReadings[@]}):"
            grep -E --color=auto '^[^/]*|/' <<< "$_prefix $model_id /${aLastReadings[$model_id]}/$prevval/"
        fi
        _mindiff=$(( (_bHasTemperature || _bHasHumidity) && (nMinSecondsTempSensor>nMinSecondsOther) ? nMinSecondsTempSensor : nMinSecondsOther  ))
        _bReady=$(( bAnnounceHass && aAnnounced[$model_id]!=1 && aCounts[$model_id] >= nMinOccurences ))
        if [[ $bVerbose ]] ; then
            echo "_mindiff=$_mindiff, _bReady=$_bReady, _bHasTemperature=$_bHasTemperature, _bHasHumidity=$_bHasHumidity, _bHasCmd=$_bHasCmd"
            echo "Model_ID=$model_id, Readings=${aLastReadings[$model_id]}, Counts=${aCounts[$model_id]}, Prev=$prevval, Time=$nTimeStamp (${aLastSents[$model_id]})"
        fi
        if (( _bReady )) ; then
            # For now, only some types of sensors are announced for auto-discovery:
            if (( _bHasTemperature || _bHasPressureKPa || _bHasCmd)) ; then
                (( _bHasTemperature )) && hass_announce "$basetopic" "${model}" "${model:+$model/}${id:-00}" "${id:+($id) }Temp"   "value_json.temperature" "temperature"
                (( _bHasHumidity    )) && hass_announce "$basetopic" "${model}" "${model:+$model/}${id:-00}" "${id:+($id) }Humid"  "value_json.humidity" "humidity"
                (( _bHasPressureKPa )) && hass_announce "$basetopic" "${model}" "${model:+$model/}${id:-00}" "${id:+($id) }PressureKPa"  "value_json.pressure_kPa" "pressure_kPa"
                (( _bHasBatteryOK   )) && hass_announce "$basetopic" "${model}" "${model:+$model/}${id:-00}" "${id:+($id) }Battery" "value_json.battery_ok" "battery"
                (( _bHasCmd         )) && hass_announce "$basetopic" "${model}" "${model:+$model/}${id:-00}" "${id:+($id) }Cmd" "value_json.cmd" "motion"
                nAnnouncedCount=$(( nAnnouncedCount + 1 ))
                publish_to_mqtt_starred "log" "{*note*:*announced MQTT discovery: $model_id*}"
                publish_to_mqtt_state
                sleep 1 # give readers a second to digest the announcement first
            else
                publish_to_mqtt_starred "log" "{*note*:*not announced for MQTT discovery: $model_id*}"
            fi
            aAnnounced[$model_id]=1 # dont reconsider for announcement 
        fi
        if [[ $data != "$prevval" || $nTimeStamp -gt $(( aLastSents[$model_id] + _mindiff )) || "$_bReady" -eq 1 ]] ; then # rcvd data should be different from previous reading!
            aLastReadings[$model_id]="$data"
            [[ $data != "$prevval" && $bRewrite ]] && data="$( jq -cer '.note = "changed"' <<< "$data" )"
            publish_to_mqtt_starred "$basetopic/${model:+$model/}${id:-00}" "${data//\"/*}" # ... publish values!
            nMqttLines=$(( nMqttLines + 1 ))
            aLastSents[$model_id]="$nTimeStamp"
        else
            [[ $bVerbose ]] && echo "Suppressed a duplicate." 
        fi
        set +x
    fi
    nReadings=${#aLastReadings[@]} # && nReadings=${nReadings#0} # remove any leading 0

    if (( nReadings > nPrevMax )) ; then                 # a new max means we have a new sensor
        nPrevMax=nReadings
        rtlChannel="$( jq -r '.channel  // empty' <<< "$data" )"
        _sensors="${_bHasTemperature:+*temperature*,}${_bHasHumidity:+*humidity*,}${_bHasPressureKPa:+*pressure_kPa*,}${_bHasBatteryOK:+*battery*,}"
        publish_to_mqtt_starred "log" "{*note*:*sensor added*,*model*:*$model*,*id*:$id,*channel*:*$rtlChannel*,*sensors*:[${_sensors%,}]}"
        publish_to_mqtt_state
    elif (( nTimeStamp > nLastStatusSeconds+nLogMinutesPeriod*60 || (nMqttLines % nLogMessagesPeriod)==0 )) ; then   # log once in a while, good heuristic in a generalized neighbourhood
        _collection="*sensorreadings*: [$(  _comma=""
            for KEY in "${!aLastReadings[@]}"; do
                _reading="${aLastReadings[$KEY]}" && _reading="${_reading/{/}" && _reading="${_reading/\}/}"
                echo -n "$_comma {*model_id*:*$KEY*,${_reading//\"/*}}"
                _comma=","
            done
        ) ]"
        log "$( expand_starred_string "$_collection" )" 
        publish_to_mqtt_state "*note*:*regular log*,*collected_model_ids*:*${!aLastReadings[*]}*, $_collection"
        nLastStatusSeconds=$nTimeStamp
    elif (( nReadings > (msgSecond*msgSecond+2)*(msgMinute+1)*(msgHour+1) || nMqttLines%5000==0 || nReceivedCount % 10000 == 0 )) ; then # reset whole array to empty once in a while = starting over
        publish_to_mqtt_state
        publish_to_mqtt_starred "log" "{*note*:*will reset saved values*}"
        unset aLastReadings && declare -A aLastReadings # reset the whole collection array
        unset aCounts   && declare -A aCounts
        unset aAnnounced && declare -A aAnnounced
        nPrevMax=$(( nPrevMax / 3 ))            # reduce it (but not back to 0) to reduce future log messages
        [[ $bRemoveAnnouncements ]] && hass_remove_announce
    fi
done

_msg="$sName: while-loop ended at $( date ), rtlprocid=:${rtlcoproc_PID}:"
log "$_msg" 
publish_to_mqtt_starred "log" "{*event*:*endloop*,*note*:*$_msg*}"

# now the exit trap function will be processed...