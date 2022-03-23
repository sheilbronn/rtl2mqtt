#!/bin/bash

# rtl2mqtt receives events from a RTL433 SDR and forwards them to a MQTT broker

# Adapted and enhanced for flexibility by "sheilbronn"
# (inspired by work from "IT-Berater" and M.  Verleun)

# set -o noglob     # file name globbing is neither needed nor wanted (for security reasons)
set -o noclobber  # disable for security reasons
# set -o pipefail
sName="${0##*/}" && sName="${sName%.sh}"
sMID="$( basename "${sName// /}" .sh )"
sID="${sMID}"
rtl2mqtt_optfile="$HOME/.$sName"

commandArgs="$*"
logbase="/var/log/$( basename "${sName// /}" .sh )" # /var/log is preferred, but will default to /tmp if not useable
sManufacturer="RTL"
sHassPrefix="homeassistant/sensor"
sRtlPrefix="rtl"
basetopic=""                  # default MQTT topic prefix
rtl433_command="rtl_433"
rtl433_command=$( command -v $rtl433_command ) || { echo "$sName: $rtl433_command not found..." 1>&2 ; exit 1 ; }
rtl433_version="$( $rtl433_command -V 2>&1 | awk -- '$2 ~ /version/ { print $3 ; exit }' )" || exit 1
rtl433_opts=( -G 4 -M protocol -M noise:300 -C si )  # generic options for everybody, e.g. -M level 
# rtl433_opts=( "${rtl433_opts[@]}" $( [ -r "$HOME/.$sName" ] && tr -c -d '[:alnum:]_. -' < "$HOME/.$sName" ) ) # FIXME: protect from expansion!
rtl433_opts_more="-R -162 -R -86 -R -31 -R -37 -R -129 -R 10 -R 53" # My specific personal excludes: 129: Eurochron-TH gives neg. temp's
rtl433_opts_more="$rtl433_opts_more -R -10 -R -53 -R 198" # Additional specific personal excludes
sSuppressAttrs="mic" # attributes that will be always eliminated from JSON msg
sSensorMatch=".*" # any sensor name will have to match this regex
sRoundTo=0.5 # temperatures will be rounded to this x and humidity to 1+2*x (see below)

# xx=( one "*.log" ) && xx=( "${xx[@]}" ten )  ; for x in "${xx[@]}"  ; do echo "$x" ; done  ;         exit 0

declare -i nHopSecs
declare -i nStatsSec=900
declare -i nLogMinutesPeriod=60
declare -i nLogMessagesPeriod=1000
declare -i nLastStatusSeconds=90
declare -i nMinSecondsOther=10 # only at least every 10 seconds
declare -i nMinSecondsTempSensor=260 # only at least every 240+20 seconds
declare -i nTimeStamp
declare -i msgMinute=0
declare -i msgSecond=0
declare -i nMqttLines=0     
declare -i nReceivedCount=0
declare -i nAnnouncedCount=0
declare -i nMinOccurences=3
declare -i nPrevMax=1       # start with 1 for non-triviality
declare -l bAnnounceHass="1" # default is yes for now
declare -A aLastReadings
declare -A aSecondLastReadings
declare -A aCounts
declare -A aProtocols
declare -A aPrevTempVals
declare -A aLastSents
declare -A aAnnounced

export LANG=C
PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin" # increases security

alias _nx="local - && set +x" # stop local verbosity after this command
_date() { printf "%($1)T" ; } # avoid invocating a seperate process
cPid()  { sh -c 'echo $$' ; }

log() {
    local - && set +x
    [ "$sDoLog" ] || return
    if [ "$sDoLog" = "dir" ] ; then
        rotate_logdir_sometimes "$logbase"
        logfile="$logbase/$(_date %H)"
        echo "$(_date)" "$@" >> "$logfile"
    else
        echo "$(_date)" "$@" >> "$logbase.log"
    fi    
  }

log_more() {
    local - && set +x
    [ "$sDoLog" ] || return
    echo "$sName:" "$@" 1>&2
    logger -p daemon.info -t "$sID" "$*"
    log "$@"
  }

dbg() { # output its args to stderr if option -v was set
	local - && set +x
    [ "$bVerbose" ] || return 1 
    echo "DEBUG: " "$*" 1>&2
    return 0 
	}

expand_starred_string() {   
    _string="${1//\"/\'}"  &&  echo "${_string//\*/\"}" 
  }

rotate_logdir_sometimes() {           # check for logfile rotation
    if (( msgMinute + msgSecond == 67 )) ; then  # try logfile rotation only with probalility of 1/60
        cd "$1" && _files="$( find . -maxdepth 2 -type f -size +300k "!" -name "*.old" -exec mv '{}' '{}'.old ";" -print0 | xargs -0 )"
        msgSecond=$(( msgSecond + 1 ))
        [[ $_files ]] && log_more "Rotated files: $_files"
    fi
  }

publish_to_mqtt_starred() {		# options: ( [expandableTopic ,] starred_message, moreMosquittoOptions)
    local - && set +x
    if [[ $# -eq 1 ]] ; then
        _topic="/bridge/state"
        _msg="$1"
    else
        if [[ $1 = "state" || $1 = "log" || $1 = "stats" ]] ; then
            _topic="$sRtlPrefix/bridge/$1"
        else
            _topic="$1"
        fi
        _msg="$2"
    fi
    _topic="${_topic/#\//$basetopic/}"
    mosquitto_pub ${mqtthost:+-h $mqtthost} ${sMID:+-i $sMID} -t "$_topic" -m "$( expand_starred_string "$_msg" )" $3 $4 $5 # ...  
  }

publish_to_mqtt_state() {	
    _statistics="*sensors*:${nReadings:-0},*announceds*:$nAnnouncedCount,*mqttlines*:$nMqttLines,*receiveds*:$nReceivedCount,*lastfreq*:$sFreq,*currtime*:*$(_date)*"
    publish_to_mqtt_starred state "{$_statistics${1:+,$1}}"
}

# Parameters for hass_announce:
# $1: MQTT "base topic" for states of all the device(s), e.g. "rtl/433" or "ffmuc"
# $2: Generic device model, e.g. a certain temperature sensor model 
# $3: MQTT "subtopic" for the specific device instance,  e.g. ${model}/${ident}. ("..../set" indicates writeability)
# $4: Text for specific device instance and sensor type info, e.g. "(${ident}) Temp"
# $5: JSON attribute carrying the state
# $6: device "class" (of sensor, e.g. none, temperature, humidity, battery), 
#     used in the announcement topic, in the unique id, in the (channel) name, and FOR the icon and the device class 
# Examples:
# hass_announce "$basetopic" "Rtl433 Bridge" "bridge/state"  "(0) SensorCount"   "value_json.sensorcount"   "none"
# hass_announce "$basetopic" "Rtl433 Bridge" "bridge/state"  "(0) MqttLineCount" "value_json.mqttlinecount" "none"
# hass_announce "$basetopic" "${model}" "${model}/${ident}" "(${ident}) Battery" "value_json.battery_ok" "battery"
# hass_announce "$basetopic" "${model}" "${model}/${ident}" "(${ident}) Temp"  "value_json.temperature_C" "temperature"
# hass_announce "$basetopic" "${model}" "${model}/${ident}" "(${ident}) Humid"  "value_json.humidity"       "humidity" 
# hass_announce "ffmuc" "$ad_devname"  "$node/publi../localcl.." "Readable Name"  "value_json.count"   "$icontype"

hass_announce() {
	local -
    local _topicpart="${3%/set}" # if $3 ends in /set it is settable, but remove /set from state topic
 	local _devid="$( basename "$_topicpart" )"
	local _command_topic_str="$( [ "$3" != "$_topicpart" ] && echo ",*cmd_t*:*~/set*" )"  # determined by suffix ".../set"

    local _dev_class="${6#none}" # dont wont "none" as string for dev_class
	local _state_class
    local _jsonpath="${5#value_json.}" # && _jsonpath="${_jsonpath//[ \/-]/}"
    local _jsonpath_red="$( echo "$_jsonpath" | tr -d "][ /-_" )" # "${_jsonpath//[ \/_-]/}" # cleaned and reduced, needed in unique id's
    local _configtopicpart="$( echo "$3" | tr -d "][ /-" | tr "[:upper:]" "[:lower:]" )"
    local _topic="${sHassPrefix}/${1///}${_configtopicpart}$_jsonpath_red/${6:-none}/config"  # e.g. homeassistant/sensor/rtl433bresser3ch109/{temperature,humidity}/config
          _configtopicpart="${_configtopicpart^[a-z]*}" # uppercase first letter for readability
    local _devname="$2 ${_devid^}"
    local _icon_str  # mdi icons: https://pictogrammers.github.io/@mdi/font/6.5.95/

    if [ "$_dev_class" ] ; then
        local _channelname="$_devname ${_dev_class^}"
    else
        local _channelname="$_devname $4" # take something meaningfull
    fi
    local _sensortopic="${1:+$1/}$_topicpart"
    local _value_template_str="${5:+,*value_template*:*{{ $5 \}\}*}"
	# local *friendly_name*:*${2:+$2 }$4*,
    local _unit_str=""

    case "$6" in
        temperature*)   _icon_str="thermometer" ; _unit_str=",*unit_of_measurement*:*°C*"	; _state_class="measurement" ;;
        humidity)	_icon_str="water-percent"   ; _unit_str=",*unit_of_measurement*:*%*"	; _state_class="measurement" ;;
        counter)	_icon_str="counter"         ; _unit_str=",*unit_of_measurement*:*#*"	; _state_class="total" ;;
		clock)	    _icon_str="clock-outline" ;;
        switch)     _icon_str="toggle-switch*" ;;
        motion)     _icon_str="motion-sensor" ;;
        # battery*)     _unit_str=",*unit_of_measurement*:*B*" ;;  # 1 for "OK" and 0 for "LOW".
		none)		  _icon_str="" ;; 
    esac

    _icon_str="${_icon_str:+,*icon*:*mdi:$_icon_str*}"
    local  _device_string="*device*:{*identifiers*:[*${sID}${_configtopicpart}*],*manufacturer*:*$sManufacturer*,*model*:*$2 with ident $_devid*,*name*:*$_devname*,*sw_version*:*rtl_433 $rtl433_version*}"
    local  _msg="*name*:*$_channelname*,*~*:*$_sensortopic*,*state_topic*:*~*,$_device_string,*device_class*:*${6:-none}*,*unique_id*:*${sID}${_configtopicpart}${_jsonpath_red^[a-z]*}*${_unit_str}${_value_template_str}${_command_topic_str}$_icon_str${_state_class:+,*state_class*:*$_state_class*}"
           # _msg="$_msg,*availability*:[{*topic*:*$basetopic/bridge/state*}]" # STILL TO DEBUG
           # _msg="$_msg,*json_attributes_topic*:*~*" # STILL TO DEBUG

   	publish_to_mqtt_starred "$_topic" "{$_msg}" "-r"
  }

hass_remove_announce() {
    _topic="$sHassPrefix/sensor/#" 
    _topic="$( dirname $sHassPrefix )/#" # deletes eveything below "homeassistant/sensor/..." !
    log_more "removing all announcements below $_topic..."
    mosquitto_sub ${mqtthost:+-h $mqtthost} ${sMID:+-i $sMID} -W 1 -t "$_topic" --remove-retained --retained-only
    _rc=$?
    sleep 1
    publish_to_mqtt_starred log "{*note*:*removed all announcements starting with $_topic returned $_rc.* }"
}

# append_json_keyval "keyval" "jsondata"
# append_json_keyval "x:2" '{one:1}'  --> '{one:1,x:2}'
append_json_keyval() {
    local - && set +x
    echo "${3/%\}/,\"$1\":$2\}}"
}

del_json_attr() {
    local - && set +x  # del(.[] | .Country, .number, .Language)    OR   
    for s in "${@:1:($#-1)}" ; do
        s="${s//[^a-zA-Z0-9_ ]}" # only allow alnum chars for attr names for sec reasons
        _d="$_d,  .${s// /, .}" # options with a space are actually multiple options
    done
    jq -c "del (${_d#,  })" <<< "${@:$#}" #   # expands to: "del(.xxx, .yyy, ...)"
}
#  set -x ; del_json_attr "one" "two" ".four five six" "*_special*" '{"one":"1", "two":2  ,"three":3,"four":"4", "five":5, "_special":"*?+","_special2":"aa*?+bb"}'  ;  exit 1
# results in: {"three":3,"_special2":"aa*?+bb"}

has_json_attr() {
    local -
    # set +x
    [ "${2//\"$1\":}" != "$2" -o "${2//\"$1\"[ ]*:}" != "$2" ]
}
# j='{"action":"null","battery":100}' ; has_json_attr action "$j" && echo yes ; has_json_attr jessy "$j" && echo no ; exit

extract_json_val() {
    local -
    set +x
    has_json_attr "$1" "$2" && jq -r ".$1 // empty" <<< "$2"
}
# j='{"action":"null","battery":100}' ; extract_json_val action "$j" ; exit

assure_json_val() { # assure_json_val("battery",">9",'{"action":"null","battery":100}'')
    has_json_attr "$1" "$3" &&  jq -e -r "if (.$1 ${2:+and .$1 $2} ) then "1" else empty end" <<< "$3"
}
# j='{"action":"null","battery":100}' ; assure_json_val battery ">999" "$j" ; assure_json_val battery ">9" "$j" ;  exit

_moreopts="$( [ -r "$rtl2mqtt_optfile" ] && grep -v '#' < "$rtl2mqtt_optfile" | tr -c -d '[:alnum:]_. -' )"
log_more "all options: $_moreopts $*"

while getopts "?qh:pt:S:drl:f:F:M:H:AR:Y:w:c:as:t:T:2vx" opt $_moreopts  "$@"
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
		eclipse) mqtthost="mqtt.eclipseprojects.io"   ;; # abbreviation
        hivemq)  mqtthost="broker.hivemq.com"   ;;
		*)       mqtthost="$( echo "$OPTARG" | tr -c -d '0-9a-z_.' )" ;; # clean up for sec purposes
		esac
        ;;
    p)  bAnnounceHass="1"
        ;;
    t)  basetopic="$OPTARG" # other base topic for MQTT
        ;;
    S)  sSensorMatch="${OPTARG}.*"
        ;;
    d)  bRemoveAnnouncements="yes" # delete (remove) all retained MQTT auto-discovery announcements (before starting), needs a newer mosquitto_sub
        ;;
    r)  # rewrite and simplify output
        if [ "$bRewrite" ] ; then
            bRewriteMore="yes" && dbg "Rewriting even more ..."
        fi
        bRewrite="yes"  # rewrite and simplify output
        ;;
    l)  logbase="$OPTARG" 
        ;;
    f)  replayfile="$OPTARG" # file to replay (e.g. for debugging), instead of rtl_433 output
        ;;
    w)  sRoundTo="${OPTARG}" # round temperature to this value and humidity to 5-times this value
        ;;
    F)  if [ "$OPTARG" = "868" ] ; then
            rtl433_opts=( "${rtl433_opts[@]}" -f 868.3M -s 256k -Y minmax ) # last tried: -Y minmax, also -Y autolevel -Y squelch   ,  frequency 868... MhZ - -s 1024k
        elif [ "$OPTARG" = "433" ] ; then
            rtl433_opts=( "${rtl433_opts[@]}" -f 433.9M ) #  -s 256k -f 433.92M for frequency 433... MhZ
        else
            rtl433_opts=( "${rtl433_opts[@]}" -f "$OPTARG" )
        fi
        basetopic="$sRtlPrefix/$OPTARG"
        nHopSecs=${nHopSecs:-61} # (60/2)+11 or 60+1 or 60+21
        nStatsSec=$(( nHopSecs - 1 ))
        ;;
    M)  rtl433_opts=( "${rtl433_opts[@]}" -M "$OPTARG" )
        ;;
    H)  nHopSecs="$OPTARG" 
        ;;
    A)  rtl433_opts=( "${rtl433_opts[@]}" -A )
        ;;
    R)  rtl433_opts=( "${rtl433_opts[@]}" -R "$OPTARG" )
        ;;
    Y)  rtl433_opts=( "${rtl433_opts[@]}" -Y "$OPTARG" )
        ;;
    c)  nMinOccurences="$OPTARG" # MQTT announcements only after at least $nMinOccurences occurences...
        ;;
    T)  nMinSecondsOther="$OPTARG" # seconds before repeating the same reading
        ;;
    a)  bAlways="yes"
        rtl433_opts=( "${rtl433_opts[@]}" $rtl433_opts_more ) # FIXME: prevent shell expansion
        nMinOccurences=1
        ;;
    s)  sSuppressAttrs="$sSuppressAttrs ${OPTARG//[^a-zA-Z0-9_]}" # sensor attributes that will be always eliminated
        ;;
    2)  bTryAlternate="yes" # ease experiments (not used in production)
        ;;
    v)  [ "$bVerbose" = "yes" ] && { bMoreVerbose="yes" ; rtl433_opts=( "-M noise:60" "${rtl433_opts[@]}" -v ) ; }
        bVerbose="yes" # more output for debugging purposes
        ;;
    x)  set -x # turn on shell debugging from here on
        ;;
    esac
done

shift "$((OPTIND-1))"   # Discard options processed by getopts, any remaining options will be passed to mosquitto_sub further down on

rtl433_opts=( "${rtl433_opts[@]}" ${nHopSecs:+-H $nHopSecs} ${nStatsSec:+-M stats:1:$nStatsSec} )
# echo "${rtl433_opts[@]}" && exit 1

if [ -f "${logbase}.log" ] ; then  # one logfile only
    sDoLog="file"
else
    sDoLog="dir"
    if mkdir -p "$logbase/model" && [ -w "$logbase" ] ; then
        :
    else
        logbase="/tmp/${sName// /}" && log_more "Defaulting to logbase $logbase"
        mkdir -p "$logbase/model" || { log "Can't mkdir $logbase/model" ; exit 1 ; }
    fi
    cd "$logbase" || { log "Can't cd to $logbase" ; exit 1 ; }
fi

[ "$( command -v jq )" ] || { log "$sName: jq must be available!" ; exit 1 ; }

_startup="$( $rtl433_command "${rtl433_opts[@]}" -T 1 2>&1 )"
sdr_tuner="$( awk -- '/^Found /   { print gensub("Found ", "",1, gensub(" tuner$", "",1,$0)) ; exit }' <<< "$_startup" )" # matches "Found Fitipower FC0013 tuner"
sdr_freq="$(  awk -- '/^Tuned to/ { print gensub("MHz.", "",1,$3)                            ; exit }' <<< "$_startup" )" # matches "Tuned to 433.900MHz."
sFreq="${sdr_freq/%.*/}" # reduces to "433"
basetopic="$sRtlPrefix/$sFreq" # derives first setting for basetopic

echo_if_not_duplicate() {
    local - && set +x
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

_info="*tuner*:*$sdr_tuner*,*freq*:$sdr_freq,*additional_rtl433_opts*:*${rtl433_opts[@]}*,*logto*:*$logbase ($sDoLog)*,*rewrite*:*${bRewrite:-no}${bRewriteMore}*,*nMinOccurences*:$nMinOccurences,*nMinSecondsTempSensor*:$nMinSecondsTempSensor,*nMinSecondsOther*:$nMinSecondsOther,*sRoundTo*:$sRoundTo"
if [ -t 1 ] ; then # probably on a terminal
    log "$sName starting at $(_date)"
    publish_to_mqtt_starred log "{*event*:*starting*,$_info}"
else               # probably non-terminal
    delayedStartSecs=3
    log "$sName starting in $delayedStartSecs secs from $(_date)"
    sleep "$delayedStartSecs"
    publish_to_mqtt_starred log "{*event*:*starting*,$_info,*note*:*delayed by $delayedStartSecs secs*,*sw_version*=*$rtl433_version*,*user*:*$( id -nu )*,*cmdargs*:*$commandArgs*}"
fi

# Optionally remove any matching retained announcements
[[ $bRemoveAnnouncements ]] && hass_remove_announce

trap_exit() {   # stuff to do when exiting
    log "$sName exit trapped at $(_date): removing announcements, then logging state."
    [ "$bRemoveAnnouncements" ] && hass_remove_announce
    _cppid="$rtlcoproc_PID" # avoid race condition after killing coproc
    [ "$rtlcoproc_PID" ] && kill "$rtlcoproc_PID" && dbg "Killed coproc PID $_cppid"
    # sleep 1
    nReadings=${#aLastReadings[@]}
    publish_to_mqtt_state "*collected_sensors*:*${!aLastReadings[*]}*"
    publish_to_mqtt_starred log "{*note*:*exiting*}"
 }
trap 'trap_exit' EXIT # previously also: INT QUIT TERM 

trap_int() {    # log all collected sensors to MQTT
    log "$sName received signal INT: logging state to MQTT"
    publish_to_mqtt_starred log "{*note*:*received signal INT*,$_info}"
    publish_to_mqtt_starred log "{*note*:*received signal INT, will publish collected sensors* }"
    publish_to_mqtt_state "*collected_sensors*:*${!aLastReadings[*]}*"
    nLastStatusSeconds="$(_date %s)"
 }
trap 'trap_int' INT 

trap_usr1() {    # toggle verbosity 
    [ "$bVerbose" ] && bVerbose="" || bVerbose="yes"
    _msg="received signal USR1: toggled verbosity to ${bVerbose:-no}"
    log "$sName $_msg"
    publish_to_mqtt_starred log "{*note*:*$_msg*}"
  }
trap 'trap_usr1' USR1 

trap_usr2() {    # remove all home assistant announcements 
    log "$sName received signal USR2: removing all home assistant announcements"
    hass_remove_announce
  }
trap 'trap_usr2' USR2 

trap_other() {    # remove all home assistant announcements 
    _msg="received other signal ..."
    log "$sName $_msg"
    publish_to_mqtt_starred log "{*note*:*$_msg*}"
  }
trap 'trap_other' URG XCPU XFSZ VTALRM PROF WINCH PWR SYS  IO

if [[ $replayfile ]] ; then
    coproc rtlcoproc ( cat "$replayfile" )
else
    if [[ $bVerbose || -t 1 ]] ; then
        log_more "options for rtl_433 are: ${rtl433_opts[@]}"
        (( nMinOccurences > 1 )) && log_more "Will do MQTT announcements only after at least $nMinOccurences occurences..."
    fi 
    # Start the RTL433 listener as a bash coprocess .... # https://unix.stackexchange.com/questions/459367/using-shell-variables-for-command-options
    coproc rtlcoproc ( $rtl433_command "${rtl433_opts[@]}" -F json  2>&1  )   # options are not double-quoted on purpose 
    # -F "mqtt://$mqtthost:1883,events,devices"
    renice -n 17 "${rtlcoproc_PID}"
fi 

if [[ $rtlcoproc_PID && $bAnnounceHass ]] ; then
    # _statistics="*sensorcount*:*${nReadings:-0}*,*announcedcount*:*$nAnnouncedCount*,*mqttlinecount*:*$nMqttLines*,*receivedcount*:*$nReceivedCount*,*readingscount*:*$nReadings*"
    hass_announce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "AnnouncedCount" "value_json.announceds" "counter"
    hass_announce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "SensorCount"   "value_json.sensors"  "counter"
    hass_announce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "MqttLineCount" "value_json.mqttlines" "counter"
    hass_announce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "ReadingsCount" "value_json.receiveds" "counter"  && sleep 1
    hass_announce "$sRtlPrefix" "Rtl433 Bridge" bridge/log   "LogMessage"     ""           "none"
fi

# set -x
while read -r data <&"${rtlcoproc[0]}" ; _rc=$? && (( _rc==0  || _rc==27 ))      # ... and enter the loop
do
    _beginpid=$(cPid) # support debugging/optimizing number of processes started in within the loop
    # dbg "diffpid=$(awk "BEGIN {print ( $(cPid) - $_beginpid - 3) }" )" 

    if [ "${data#{}" = "$data" ] ; then # possibly eliminating any non-JSON line (= starting with "{"), e.g. from rtl_433 debugging/error output
        _garbage1="Allocating " # "Allocating 15 zero-copy buffers"
        if [ "${data#$_garbage1}" = "$data" ] ; then # unless verbose...
            log "Non-JSON: $data"
            [[ $bVerbose ]] && publish_to_mqtt_starred log "{*note*:*$sName: ${data//\*/+}*}"
        fi
        data='""'
        continue
    else 
        dbg "RAW: $data"
    fi
    if [[ $data  =~ "center_frequency" ]] ; then
        data="${data//\" : /\":}" # beautify a bit, removing space(s)
        sFreq="$( jq -r '.center_frequency / 1000000 | floor  // empty' <<< "$data" )"
        basetopic="$sRtlPrefix/$sFreq"
        [[ $bVerbose ]] && echo_if_not_duplicate "RAW: $data" && publish_to_mqtt_starred log "${data//\"/*}"
        continue
    fi
    nReceivedCount=$(( nReceivedCount + 1 ))
    
    _time="$( extract_json_val time "$data" )"  # ;  msgTime="2021-11-01 03:05:07"
    declare +i _str # to avoid octal interpretation
    _str="${_time:(-8):2}" ; msgHour="${_str#0}" 
    _str="${_time:(-5):2}" ; msgMinute="${_str#0}" 
    _str="${_time:(-2):2}" ; msgSecond="${_str#0}"

    data="$( del_json_attr "time $sSuppressAttrs" "$data" | sed -e 's/:"\([0-9.-]*\)"/:\1/g'  )" # delete attributes and remove double-quotes around numbers
    log "$data"
    [[ $bMoreVerbose ]] && echo_if_not_duplicate "READ: $data"
    channel="$(extract_json_val channel "$data" )"
    model="$(   extract_json_val model  "$data" )"    
    id="$(      extract_json_val id     "$data" )"
    ident="${channel:-$id}" # prefer the channel over the id as the unique identifier, if present
    # protocol="$( extract_json_val protocol protocol "$data" )"
    model_ident="${model}${ident:+_$ident}"
    [[ $bVerbose ]] || expr "$model_ident" : "$sSensorMatch.*" > /dev/null || continue # skip unwanted readings (regexp) early (if not verbose)
    [ "$sFreq" ]    && data="$( append_json_keyval FREQ "$sFreq" "$data" )"
    # exit

    if [ "$model_ident" = "_" ] ; then
        : # pass-through für "-M stats" messages
    elif [[ $bRewrite ]] ; then                  # Rewrite and clean the line from less interesting information....
        data="$( del_json_attr "model protocol" "$data" )" # other stuff: id rssi subtype channel mod snr noise

        _tmp="$( has_json_attr temperature_C "$data" && jq -e -r "if .temperature_C then .temperature_C / $sRoundTo + 0.5 | floor * $sRoundTo else empty end" <<< "$data" )" # round to 0.5° C
        if [[ $_tmp ]] ; then
            _bHasTemperature="1"
            data="$( jq -cer ".temperature_C = $_tmp" <<< "$data" )" # set to rounded temperature
            [[ ${aPrevTempVals[$model_ident]} ]] || aPrevTempVals[$model_ident]=0
        else 
            _bHasTemperature=""
        fi

        _tmp="$( has_json_attr humidity "$data" && jq -e -r "if .humidity and .humidity<=100 then .humidity / ( $sRoundTo * 2 + 1 ) + 0.5 | floor * ( $sRoundTo * 5 ) | floor else empty end" <<< "$data" )" # round to 2,5%
        if [[ $_tmp ]] ; then
            _bHasHumidity="1"
            data="$( jq -cer ".humidity = $_tmp" <<< "$data" )"
         else 
            _bHasHumidity=""
        fi

        # _bHasHumidity="$( assure_json_val humidity "<=100" "$data" )"
        _bHasRain="$( assure_json_val rain_mm ">0" "$data" )"
        _bHasBatteryOK="$( assure_json_val battery_ok "<=2" "$data" )"
        _bHasPressureKPa="$(assure_json_val pressure_kPa "<=9999" "$data" )"
        _bHasCmd="$(assure_json_val cmd "" "$data" )"

        if [[ $bRewriteMore ]] ; then
            data="$( del_json_attr ".transmit test" "$data" )"
            data="$( has_json_attr button "$data"  &&  jq -c 'if .button     == 0 then del(.button) else . end' <<< "$data" || echo "$data" )"
            # data="$( has_json_attr battery_ok "$data"  &&   jq -c 'if .battery_ok == 1 then del(.battery_ok) else . end' <<< "$data" || echo "$data" )"
            data="$( has_json_attr unknown1 "$data"  &&   jq -c 'if .unknown1   == 0 then del(.unknown1)   else . end' <<< "$data" || echo "$data" )"

            bSkipLine="$( jq -e -r 'if (.humidity and .humidity>100) or (.temperature_C and .temperature_C<-50) or (.temperature and .temperature<-50) then "yes" else empty end' <<<"$data"  )"
        fi
        [[ $sDoLog == "dir" && $model ]] && echo "$(_date %H:%M:%S) $data" >> "$logbase/model/$model_ident"
        data="$( sed -e 's/"temperature_C":/"temperature":/' -e 's/":([0-9.-]+)/":"\&"/g'  <<< "$data" )" # hack to cut off "_C" and to add double-quotes not using jq
    fi

    nTimeStamp="$(_date %s)"
    # Send message to MQTT or skip it ...
    if [[ $bSkipLine ]] ; then
        dbg "SKIPPING: $data"
        bSkipLine=""
        continue
    elif [ "$model_ident" = "_" ] ; then # stats message
        [[ $bVerbose ]] && echo_if_not_duplicate "STATS: $data" && publish_to_mqtt_starred stats "${data//\"/*}" # ... publish stats values (from "-M stats" option)
    elif [[ $bAlways || $data != "$prev_data" || $nTimeStamp -gt $((prev_time+nMinSecondsOther)) ]] ; then
        if [[ $bVerbose ]] ; then
            [[ $bRewrite ]] && echo_if_not_duplicate "" "CLEANED: $model_ident = $data" # resulting message for MQTT
            expr match "$model_ident" "$sSensorMatch.*"  > /dev/null || continue # skip if match
        fi
        prev_data="$data"
        prev_time="$nTimeStamp"
        prevval="${aLastReadings[$model_ident]}"
        prevvals="${aSecondLastReadings[$model_ident]}"
        aLastReadings[$model_ident]="$data"
        aCounts[$model_ident]="$(( aCounts[$model_ident] + 1 ))"
        # aProtocols[${protocol}]="$model"
        if [[ $bMoreVerbose ]] ; then
            _prefix="SAME:  "  &&  [[ ${aLastReadings[$model_ident]} != "$prevval" ]] && _prefix="CHANGE(${#aLastReadings[@]}):"
            grep -E --color=auto '^[^/]*|/' <<< "$_prefix $model_ident /${aLastReadings[$model_ident]}/$prevval/"
        fi
        _nTimeDiff=$(( (_bHasTemperature || _bHasHumidity) && (nMinSecondsTempSensor>nMinSecondsOther) ? nMinSecondsTempSensor : nMinSecondsOther  ))
        [[ $data == "$prevval"  ]] && _nTimeDiff=$(( _nTimeDiff * 2 ))
        _bReady=$(( bAnnounceHass && aAnnounced[$model_ident]!=1 && aCounts[$model_ident] >= nMinOccurences ))
        if [[ $bVerbose ]] ; then
            echo "_nTimeDiff=$_nTimeDiff, _bReady=$_bReady, _bHasTemperature=$_bHasTemperature, _bHasHumidity=$_bHasHumidity, _bHasCmd=$_bHasCmd"
            # (( nTimeStamp > nLastStatusSeconds+nLogMinutesPeriod*60 || (nMqttLines % nLogMessagesPeriod)==0 ))
            echo "model_ident=$model_ident, Readings=${aLastReadings[$model_ident]}, Counts=${aCounts[$model_ident]}, Prev=$prevval, Prev2=$prevvals, Time=$nTimeStamp-${aLastSents[$model_ident]}=$(( nTimeStamp - aLastSents[$model_ident] ))"
        fi
        if (( _bReady )) ; then
            # For now, only the following certain types of sensors are announced for auto-discovery:
            if (( _bHasTemperature || _bHasPressureKPa || _bHasCmd )) ; then
                (( _bHasTemperature )) && hass_announce "$basetopic" "$model ${sFreq}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Temp"   "value_json.temperature" temperature
                (( _bHasHumidity    )) && hass_announce "$basetopic" "$model ${sFreq}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Humid"  "value_json.humidity" humidity
                (( _bHasPressureKPa )) && hass_announce "$basetopic" "$model ${sFreq}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }PressureKPa"  "value_json.pressure_kPa" pressure_kPa
                (( _bHasBatteryOK   )) && hass_announce "$basetopic" "$model ${sFreq}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Battery" "value_json.battery_ok" battery_ok
                (( _bHasCmd         )) && hass_announce "$basetopic" "$model ${sFreq}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Cmd" "value_json.cmd" motion
            #   [ "$sFreq"          ]  && hass_announce "$basetopic" "$model ${sFreq}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Freq" "value_json.FREQ" frequency
                publish_to_mqtt_starred log "{*note*:*announced MQTT discovery: $model_ident*}"
                nAnnouncedCount=$(( nAnnouncedCount + 1 ))
                publish_to_mqtt_state
                sleep 1 # give readers a second to digest the announcement first
            else
                publish_to_mqtt_starred log "{*note*:*not announced for MQTT discovery: $model_ident*}"
            fi
            aAnnounced[$model_ident]=1 # 1=dont reconsider for announcement 
        fi
        if [[ $data != "$prevval" || $nTimeStamp -gt $(( aLastSents[$model_ident] + _nTimeDiff )) || "$_bReady" -eq 1 ]] ; then # rcvd data should be different from previous reading(s)!
            aLastReadings[$model_ident]="$data"
            if [[ $bRewrite && ( $_bHasTemperature || $_bHasHumidity ) ]] ; then
                if [[ $data != "$prevval" ]] ; then
                    data="$( jq -cer '.NOTE  = "changed"' <<< "$data" )"
                elif [[ $data == "$prevvals" ]] ; then
                    data="$( jq -cer ".NOTE2 = \"=2nd (#${aCounts[$model_ident]},_bR=$_bReady,${_nTimeDiff}s)\"" <<< "$data" )"
                fi
                aSecondLastReadings[$model_ident]="$prevval"
            fi
            publish_to_mqtt_starred "$basetopic/${model:+$model/}${ident:-00}" "${data//\"/*}" # ... publish the values!
            nMqttLines=$(( nMqttLines + 1 ))
            aLastSents[$model_ident]="$nTimeStamp"
        else
            dbg "Suppressed a duplicate." 
        fi
        set +x
    fi
    nReadings=${#aLastReadings[@]} # && nReadings=${nReadings#0} # remove any leading 0

    if (( nReadings > nPrevMax )) ; then   # a new max means we have a new sensor
        nPrevMax=nReadings
        _sensors="${_bHasTemperature:+*temperature*,}${_bHasHumidity:+*humidity*,}${_bHasPressureKPa:+*pressure_kPa*,}${_bHasBatteryOK:+*battery*,}${_bHasRain:+*rain*,}"
        publish_to_mqtt_starred log "{*note*:*sensor added*,*model*:*$model*,*id*:$id,*channel*:*$channel*,*sensors*:[${_sensors%,}]}"
        publish_to_mqtt_state
    elif (( nTimeStamp > nLastStatusSeconds+nLogMinutesPeriod*60 || (nMqttLines % nLogMessagesPeriod)==0 )) ; then   
        # log once in a while, good heuristic in a generalized neighbourhood
        _collection="*sensorreadings*:[$(  _comma=""
            for KEY in "${!aLastReadings[@]}"; do
                _reading="${aLastReadings[$KEY]}" && _reading="${_reading/{/}" && _reading="${_reading/\}/}"
                echo -n "$_comma {*model_ident*:*$KEY*,${_reading//\"/*}}"
                _comma=","
            done
        )] "
        log "$( expand_starred_string "$_collection" )" 
        publish_to_mqtt_state "*note*:*regular log*,*collected_model_ids*:*${!aLastReadings[*]}*, $_collection"
        nLastStatusSeconds=$nTimeStamp
    elif (( nReadings > (msgSecond*msgSecond+2)*(msgMinute+1)*(msgHour+1) || nMqttLines%5000==0 || nReceivedCount % 10000 == 0 )) ; then # reset whole array to empty once in a while = starting over
        publish_to_mqtt_state
        publish_to_mqtt_starred log "{*note*:*will reset saved values (nReadings=$nReadings,nMqttLines=$nMqttLines,nReceivedCount=$nReceivedCount)*}"
        unset aLastReadings && declare -A aLastReadings # reset the whole collection array
        unset aCounts   && declare -A aCounts
        unset aAnnounced && declare -A aAnnounced
        nPrevMax=$(( nPrevMax / 3 ))            # reduce it (but not back to 0) to reduce future log messages
        [[ $bRemoveAnnouncements ]] && hass_remove_announce
    fi
done

_msg="$sName: read failed (rc=$_rc), while-loop ended $(printf "%()T"), rtlprocid now :${rtlcoproc_PID}:"
log "$_msg" 
publish_to_mqtt_starred log "{*event*:*endloop*,*note*:*$_msg*}"

exit 1

# now the exit trap function will be processed...