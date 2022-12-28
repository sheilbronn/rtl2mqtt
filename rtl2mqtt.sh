#!/bin/bash

# rtl2mqtt reads events from a RTL433 SDR and forwards them to a MQTT broker as enhanced JSON messages 

# Adapted and enhanced for conciseness, verboseness and flexibility by "sheilbronn"
# (inspired by work from "IT-Berater" and M. Verleun)

# set -o noglob     # file name globbing is neither needed nor wanted (for security reasons)
set -o noclobber  # disable for security reasons
sName="${0##*/}" && sName="${sName%.sh}"
sMID="$( basename "${sName// /}" .sh )"
sID="$sMID"
rtl2mqtt_optfile="$( [ -r "${XDG_CONFIG_HOME:=$HOME/.config}/$sName" ] && echo "$XDG_CONFIG_HOME/$sName" || echo "$HOME/.$sName" )" # ~/.config/rtl2mqtt or ~/.rtl2mqtt

commandArgs="$*"
dLog="/var/log/$sMID" # /var/log is default, but will be changed to /tmp if not useable
sManufacturer="RTL"
sHassPrefix="homeassistant/sensor"
sRtlPrefix="rtl"
sStartDate="$(date "+%Y-%m-%dT%H:%M:%S")" # format needed for OpenHab DateTime MQTT items - for others OK, too? - as opposed to ISO8601
basetopic=""                  # default MQTT topic prefix
rtl433_command="rtl_433"
rtl433_command=$( command -v $rtl433_command ) || { echo "$sName: $rtl433_command not found..." 1>&2 ; exit 1 ; }
rtl433_version="$( $rtl433_command -V 2>&1 | awk -- '$2 ~ /version/ { print $3 ; exit }' )" || exit 1
declare -a rtl433_opts=( -M protocol -M noise:300 -M level -C si )  # generic options in all settings, e.g. -M level 
# rtl433_opts+=( $( [ -r "$HOME/.$sName" ] && tr -c -d '[:alnum:]_. -' < "$HOME/.$sName" ) ) # FIXME: protect from expansion!
declare -a rtl433_opts_more=( -R -31 -R -53 -R -86 ) # My specific personal excludes
sSuppressAttrs="mic" # attributes that will be always eliminated from JSON msg
sSensorMatch=".*" # any sensor name will have to match this regex
sRoundTo=0.5 # temperatures will be rounded to this x and humidity to 4*x (see below)

# xx=( one "*.log" ) && xx=( "${xx[@]}" ten )  ; for x in "${xx[@]}"  ; do echo "$x" ; done  ;         exit 0

declare -i nHopSecs
declare -i nStatsSec=900
declare -r sSuggSampleRate=1024k
declare -i nLogMinutesPeriod=60 # once per hour
declare -i nLogMessagesPeriod=1000
declare -i nLastStatusSeconds=90
declare -i nMinSecondsOther=10 # only at least every 10 seconds
declare -i nMinSecondsTempSensor=260 # only at least every 240+20 seconds
declare -i nTimeStamp
declare -i nPidDelta
declare -i nHour=0
declare -i nMinute=0
declare -i nSecond=0
declare -i nMqttLines=0     
declare -i nReceivedCount=0
declare -i nAnnouncedCount=0
declare -i nMinOccurences=3
declare -i nPrevMax=1       # start with 1 for non-triviality
declare -i nReadings=0
declare -i nRC
declare -l bAnnounceHass=1 # default is yes for now
declare -i bRetained="" # make the value publishing retained or not (-r flag passed to mosquitto_pub)
declare -A aLastReadings
declare -A aSecondLastReadings
declare -Ai aCounts
declare -A aProtocols
declare -A aPrevTempVals
declare -A aLastSents
declare -A aAnnounced

export LANG=C
PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin" # increases security

# alias _nx="local - && set +x" # alias to stop local verbosity (within function, not allowed in bash)
cDate() { printf "%($*)T" ; } # avoid invocating a separate process to get the date
# cPid()  { set -x ; printf $BASHPID ; } # get a current PID, support debugging/counting/optimizing number of processes started in within the loop
cPidDelta() { local - && set +x ; _n=$(printf %s $BASHPID) ; _n=$(( _n - ${_beginPid:=$_n} )) ; dbg PIDDELTA "$1: $_n ($_beginPid) "  ":$data:" ; _beginPid=$(( _beginPid + 1 )) ; nPidDelta=$_n ; }
cPidDelta() { : ; }
cMultiplyTen() { local - && set +x ; [[ $1 =~ ^([+-]?)([0-9]*)\.([0-9])([0-9]*) ]] && { echo "${BASH_REMATCH[1]}${BASH_REMATCH[2]#0}${BASH_REMATCH[3]}" ; } || echo $(( ${1/#./0.} * 10 )) ; }
# set -x ; cMultiplyTen -1.16 ; cMultiplyTen -0.800 ; cMultiplyTen +1.234 ; cMultiplyTen -3.234 ; cMultiplyTen 66 ; cMultiplyTen .900 ;  exit
cDiv10() { local - && set +x ; [[ $1.0 =~ ^([+-]?)([0-9]*)([0-9])(\.[0-9]+)? ]] && { v="${BASH_REMATCH[1]}${BASH_REMATCH[2]:-0}.${BASH_REMATCH[3]}" ; echo "${v%.0}" ; } || echo 0 ; }
# set -x ; cDiv10 -1.234 ; cDiv10 12.34 ; cDiv10 -32.34 ; cDiv10 -66 ; cDiv10 66 ; cDiv10 .900 ;  exit

log() {
    local - && set +x
    if [[ $sDoLog == "dir" ]] ; then
        cRotateLogdirSometimes "$dLog"
        logfile="$dLog/$(cDate %H)"
        echo "$(cDate %d %T)" "$*" >> "$logfile"
        [[ $bVerbose && $* =~ ^\{ ]] && { printf "%s" "$*" ; echo "" ; } >> "$logfile.JSON"
    elif [[ $sDoLog ]] ; then
        echo "$(cDate)" "$@" >> "$dLog.log"
    fi    
  }

cLogMore() { # log to syslog logging facility, too.
    local - && set +x
    [[ $sDoLog ]] || return
    echo "$sName:" "$@" 1>&2
    logger -p daemon.info -t "$sID" -- "$*"
    log "$@"
  }

dbg() { # output its args to stderr if option -v was set
	local - && set +x
    (( bVerbose )) && { [[ $2 ]] && echo "$1:" "${@:2:$#}" 1>&2 || echo "DEBUG: $1" ; } 1>&2
	}
# set -x ; dbg ONE TWO || echo ok to fail... ; exit
# set -x ; bVerbose=1 ; dbg MANY MORE OF IT ; dbg "ALL TOGETHER" ; exit

cMapFreqToBand() {
    local - && set +x
    [[ $1 =~ ^43 ]] && echo 433 && return
    [[ $1 =~ ^86 ]] && echo 868 && return
    [[ $1 =~ ^91 ]] && echo 915 && return
    [[ $1 =~ ^149 || $1 =~ ^150 ]] && echo 150 && return
    # FIXME: for further bands
}
# set -x ; cMapFreqToBand 868300000 ; exit

cCheckExit() { # beautify $data and output it, then exit for debugging purposes
    json_pp <<< "$data" # "${@:-$data}"
    exit 0
  }
# set -x ; data='{"one":1}' ; cCheckExit # '{"two":1}' 

cExpandStarredString() {
    _esc="quote_star_quote" ; _str="$1"
    _str="${_str//\"\*\"/$_esc}"  &&  _str="${_str//\"/\'}"  &&  _str="${_str//\*/\"}"  &&  _str="${_str//$esc/\"*\"}"  && echo "$_str"
  }

cRotateLogdirSometimes() {           # check for logfile rotation only with probability of 1/60
    if (( nMinute + nSecond == 67 )) ; then 
        cd "$1" && _files="$( find . -xdev -maxdepth 2 -type f -size +500k "!" -name "*.old" -exec mv '{}' '{}'.old ";" -print0 | xargs -0 )"
        nSecond+=1
        [[ $_files ]] && cLogMore "Rotated files: $_files"
    fi
  }

cMqttStarred() {		# options: ( [expandableTopic ,] starred_message, moreMosquittoOptions)
    local - && set +x
    if (( $# == 1 )) ; then
        _topic="/bridge/state"
        _msg="$1"
    else
        _topic="$1"
        [[ $1 =~ / ]] || _topic="$sRtlPrefix/bridge/$1" # add bridge prefix if no slash contained
        _msg="$2"
    fi
    _topic="${_topic/#\//$basetopic/}"
    mosquitto_pub ${mqtthost:+-h $mqtthost} ${sMID:+-i $sMID} -t "$_topic" -m "$( cExpandStarredString "$_msg" )" "${@:3:$#}" # ... append further arguments
    return $?
  }

cMqttState() {	# log the state of the rtl bridge
    _statistics="*sensors*:$nReadings,*announceds*:$nAnnouncedCount,*mqttlines*:$nMqttLines,*receiveds*:$nReceivedCount,*lastfreq*:$sBand,*startdate*:*$sStartDate*,*currtime*:*$(cDate)*"
    cMqttStarred state "{$_statistics${1:+,$1}}"
}

# Parameters for cHassAnnounce:
# $1: MQTT "base topic" for states of all the device(s), e.g. "rtl/433" or "ffmuc"
# $2: Generic device model, e.g. a certain temperature sensor model 
# $3: MQTT "subtopic" for the specific device instance,  e.g. ${model}/${ident}. ("..../set" indicates writeability)
# $4: Text for specific device instance and sensor type info, e.g. "(${ident}) Temp"
# $5: JSON attribute carrying the state
# $6: device "class" (of sensor, e.g. none, temperature, humidity, battery), 
#     used in the announcement topic, in the unique id, in the (channel) name, and FOR the icon and the device class 
# Examples:
# cHassAnnounce "$basetopic" "Rtl433 Bridge" "bridge/state"  "(0) SensorCount"   "value_json.sensorcount"   "none"
# cHassAnnounce "$basetopic" "Rtl433 Bridge" "bridge/state"  "(0) MqttLineCount" "value_json.mqttlinecount" "none"
# cHassAnnounce "$basetopic" "${model}" "${model}/${ident}" "(${ident}) Battery" "value_json.battery_ok" "battery"
# cHassAnnounce "$basetopic" "${model}" "${model}/${ident}" "(${ident}) Temp"  "value_json.temperature_C" "temperature"
# cHassAnnounce "$basetopic" "${model}" "${model}/${ident}" "(${ident}) Humid"  "value_json.humidity"       "humidity" 
# cHassAnnounce "ffmuc" "$ad_devname"  "$node/publi../localcl.." "Readable Name"  "value_json.count"   "$icontype"

cHassAnnounce() {
	local -
    local _topicpart="${3%/set}" # if $3 ends in /set it is settable, but remove /set from state topic
 	local _devid="${_topicpart##*/}" # "$( basename "$_topicpart" )"
	local _command_topic_str="$( [[ $3 != "$_topicpart" ]] && echo ",*cmd_t*:*~/set*" )"  # determined by suffix ".../set"

    local _dev_class="${6#none}" # dont wont "none" as string for dev_class
	local _state_class
    local _jsonpath="${5#value_json.}" # && _jsonpath="${_jsonpath//[ \/-]/}"
    local _jsonpath_red="$( echo "$_jsonpath" | tr -d "][ /_-" )" # "${_jsonpath//[ \/_-]/}" # cleaned and reduced, needed in unique id's
    local _configtopicpart="$( echo "$3" | tr -d "][ /-" | tr "[:upper:]" "[:lower:]" )"
    local _topic="${sHassPrefix}/${1///}${_configtopicpart}$_jsonpath_red/${6:-none}/config"  # e.g. homeassistant/sensor/rtl433bresser3ch109/{temperature,humidity}/config
          _configtopicpart="${_configtopicpart^[a-z]*}" # uppercase first letter for readability
    local _devname="$2 ${_devid^}"
    local _icon_str  # mdi icons: https://pictogrammers.github.io/@mdi/font/6.5.95/

    if [[ $_dev_class ]] ; then
        local _channelname="$_devname ${_dev_class^}"
    else
        local _channelname="$_devname $4" # take something meaningfull
    fi
    local _sensortopic="${1:+$1/}$_topicpart"
	# local *friendly_name*:*${2:+$2 }$4*,
    local _unit_str="" # the presence of some "unit_of_measurement" makes it a Number in OpenHab

    # From https://www.home-assistant.io/docs/configuration/templating :
    local _value_template_str="${5:+,*value_template*:*{{ $5 \}\}*}" #   generated something like: ... "value_template":"{{ value_json.battery_ok }}" ...
    # other syntax for non-JSON is: local _value_template_str="${5:+,*value_template*:*{{ value|float|round(1) \}\}*}"

    case "$6" in
        temperature*) _icon_str="thermometer"   ; _unit_str=",*unit_of_measurement*:*\u00b0C*" ; _state_class="measurement" ;;
        setpoint_C)	_icon_str="thermometer"     ; _unit_str=",*unit_of_measurement*:*%*"	; _state_class="measurement" ;;
        humidity)	_icon_str="water-percent"   ; _unit_str=",*unit_of_measurement*:*%*"	; _state_class="measurement" ;;
        pressure_kPa) _icon_str="airballoon-outline" ; _unit_str=",*unit_of_measurement*:*kPa*"	; _state_class="measurement" ;;
        ppm)	    _icon_str="smoke"           ; _unit_str=",*unit_of_measurement*:*ppm*"	; _state_class="measurement" ;;
        density*)	_icon_str="smoke"           ; _unit_str=",*unit_of_measurement*:*ug_m3*"	; _state_class="measurement" ;;
        counter)	_icon_str="counter"         ; _unit_str=",*unit_of_measurement*:*#*"	; _state_class="total_increasing" ;;
		clock)	    _icon_str="clock-outline"   ;;
		signal)	    _icon_str="signal"          ; _unit_str=",*unit_of_measurement*:*%*"	; _state_class="measurement" ;;
        switch)     _icon_str="toggle-switch*"  ;;
        motion)     _icon_str="motion-sensor"   ;;
        button)     _icon_str="gesture-tap-button" ;;
        dipswitch)  _icon_str="dip-switch" ;;
        code)   _icon_str="lock" ;;
        newbattery) _icon_str="battery-check" ; _unit_str=",*unit_of_measurement*:*#*"  ;;
       # battery*)     _unit_str=",*unit_of_measurement*:*B*" ;;  # 1 for "OK" and 0 for "LOW".
        zone)       _icon_str="vector-intersection" ; _unit_str=",*unit_of_measurement*:*#*" ; _state_class="measurement" ;;
        unit)       _icon_str="group"               ; _unit_str=",*unit_of_measurement*:*#*" ; _state_class="measurement" ;;
        learn)      _icon_str="plus"               ; _unit_str=",*unit_of_measurement*:*#*" ; _state_class="total_increasing" ;;
        channel)    _icon_str="format-list-numbered" ; _unit_str=",*unit_of_measurement*:*#*" ; _state_class="measurement" ;;
        battery_ok) _icon_str="" ; _unit_str=",*unit_of_measurement*:*#*" ; _state_class="measurement" ;;
		none)		_icon_str="" ;; 
    esac

    _icon_str="${_icon_str:+,*icon*:*mdi:$_icon_str*}"
    local  _device="*device*:{*name*:*$_devname*,*manufacturer*:*$sManufacturer*,*model*:*$2 ${protocol:+(${aNames[$protocol]}) ($protocol) }with id $_devid*,*identifiers*:[*${sID}${_configtopicpart}*],*sw_version*:*rtl_433 $rtl433_version*}"
    local  _msg="*name*:*$_channelname*,*~*:*$_sensortopic*,*state_topic*:*~*,$_device,*device_class*:*${6:-none}*,*unique_id*:*${sID}${_configtopicpart}${_jsonpath_red^[a-z]*}*${_unit_str}${_value_template_str}${_command_topic_str}$_icon_str${_state_class:+,*state_class*:*$_state_class*}"
           # _msg="$_msg,*availability*:[{*topic*:*$basetopic/bridge/state*}]" # STILL TO DEBUG
           # _msg="$_msg,*json_attributes_topic*:*~*" # STILL TO DEBUG

   	cMqttStarred "$_topic" "{$_msg}" "-r"
    return $?
  }

# Other examples created by 
# homeassistant/sensor/Smoke-GS558-25612/Smoke-GS558-25612-noise/config :
#  {"unit_of_measurement": "dB", "state_class": "measurement", "entity_category": "diagnostic", "name": "Smoke-GS558-25612-noise", "value_template": "{{ value|float|round(2) }}", "device":{"model": "Smoke-GS558", "identifiers": "Smoke-GS558-25612", "name": "Smoke-GS558-25612", "manufacturer": "rtl_433"}, "device_class": "signal_strength", "state_topic": "rtl_433/openhabian/devices/Smoke-GS558/25612/noise", "unique_id": "Smoke-GS558-25612-noise"}
# homeassistant/sensor/Smoke-GS558-25612/Smoke-GS558-25612-snr/config :
#  {"unit_of_measurement": "dB", "state_class": "measurement", "entity_category": "diagnostic", "name": "Smoke-GS558-25612-snr", "value_template": "{{ value|float|round(2) }}", "device":{"model": "Smoke-GS558", "identifiers": "Smoke-GS558-25612", "name": "Smoke-GS558-25612", "manufacturer": "rtl_433"}, "device_class": "signal_strength", "state_topic": "rtl_433/openhabian/devices/Smoke-GS558/25612/snr", "unique_id": "Smoke-GS558-25612-snr"}
# homeassistant/sensor/Smoke-GS558-25612/Smoke-GS558-25612-rssi/config :
#  {"unit_of_measurement": "dB", "state_class": "measurement", "entity_category": "diagnostic", "name": "Smoke-GS558-25612-rssi", 
#   "value_template": "{{ value|float|round(2) }}", 
#   "device":{"model": "Smoke-GS558", "identifiers": "Smoke-GS558-25612", "name": "Smoke-GS558-25612", "manufacturer": "rtl_433"}, 
#   "device_class": "signal_strength", "state_topic": "rtl_433/openhabian/devices/Smoke-GS558/25612/rssi", "unique_id": "Smoke-GS558-25612-rssi"}

cHassRemoveAnnounce() { # removes ALL previous Home Assistant announcements  
    _topic="$( dirname $sHassPrefix )/#" # deletes eveything below "homeassistant/..." !
    cLogMore "removing all announcements below $_topic..."
    mosquitto_sub ${mqtthost:+-h $mqtthost} ${sMID:+-i $sMID} -W 1 -t "$_topic" --remove-retained --retained-only
    _rc=$?
    sleep 1
    cMqttStarred log "{*event*:*debug*,*note*:*removed all announcements starting with $_topic returned $_rc.* }"
    return $?
}

cAppendJsonKeyVal() {  # cAppendJsonKeyVal "key" "val" "jsondata" (use $data if $3 is empty, no quotes around numbers)
    local - && set +x
    _val="$2" ; _d="${3:-$data}"
    # [ -z "$_val" ] && echo "$_d" # don't append the pair if val is empty !
    [[ $_val =~ ^[+-]?(0|[1-9][0-9]*)(\.[0-9]+)?$ ]] || _val="\"$_val\"" # surround _val by double quotes only if not-a-number
    _val="${_d/%\}/,\"$1\":$_val\}}"
    [[ $3 ]] && echo "$_val" || data="$_val"
}
# set -x ; data='{"one":1}' ; cAppendJsonKeyVal "x" "2x" ; echo $data ; cAppendJsonKeyVal "n" "2.3" "$data" ; cAppendJsonKeyVal "m" "-" "$data" ; exit  # returns: '{one:1,"x":"2"}'
# set -x ; cAppendJsonKeyVal "donot"  ""  '{"one":1}'  ;    exit  # returns: '{"one":1,"donot":""}' 
# set -x ; cAppendJsonKeyVal "floati" "5.5" '{"one":1}' ;    exit  # returns: '{"one":1,"floati":5.5}'

cHasJsonKey() { # simplified check to check whether the JSON ${2:-$data} has key $1 (e.g. "temperat.*e")  (. is for [a-zA-Z0-9])
    local - && set +x
    local _k=""
    [[ ${2:-$data} =~ [{,][[:space:]]*\"(${1//\./[a-zA-Z0-9]})\"[[:space:]]*: ]] 
    _k="${BASH_REMATCH[1]}"
    [[ $_k && "$1" =~ \*|\[   ]] && echo "$_k" # output the first found key only if multiple fits potentially possible
    [[ $_k ]] # non-empty if found
}
# set -x ; j='{"action":"null","battery" :100}' ; cHasJsonKey act.*n "$j" && echo yes ; cHasJsonKey batter[y] "$j" && echo yes ; cHasJsonKey batt*i "$j" || echo no ; exit
# set -x ; j='{"dipswitch" :"++---o--+","rbutton":"11R"}' ; cHasJsonKey dipswitch "$j" && echo yes ; cHasJsonKey jessy "$j" || echo no ; exit

cRemoveQuotesFromNumbers() { # removes double quotes from JSON numbers in $1 or $data
    local - && set +x
    _d="${1:-$data}"
    while [[ $_d =~ ([,{][[:space:]]*)\"([^\"]*)\"[[:space:]]*:[[:space:]]*\"([+-]?(0|[1-9][0-9]*)(\.[0-9]+)?)\" ]] ; do # 
        # echo "${BASH_REMATCH[0]}  //   ${BASH_REMATCH[1]} //   ${BASH_REMATCH[2]} // ${BASH_REMATCH[3]}"
        _d="${_d/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]}\"${BASH_REMATCH[2]}\":${BASH_REMATCH[3]}"}"
    done
    # _d="$( sed -e 's/: *"\([0-9.-]*\)" *\([,}]\)/:\1\2/g' <<< "${1:-$data}" )" # remove double-quotes around numbers
    [[ $1 ]] && echo "$_d" || data="$_d"
}
# set -x ; x='"AA":"+1.1.1","BB":"-2","CC":"+3.55","DD":"-0.44"' ; data="{$x}" ; cRemoveQuotesFromNumbers ; : exit ; echo $data ; cRemoveQuotesFromNumbers "{$x, \"EE\":\"-0.5\"}" ; exit 0

perfCheck() {
    for (( i=0; i<3; i++))
    do
        _start=$(date +"%s%3N")
        r=100
        j=0 ; while (( j < r )) ; do x='"one":"1a","two": "-2","three":"3.5"' ; cRemoveQuotesFromNumbers "{$x}"; (( j++ )) ; done # > /dev/null 
        _middle=$(date +"%s%3N") ; _one=$(( _one + _middle - _start ))
        j=0 ; while (( j < r )) ; do x='"one":"1a","two" :"-2","three":"3.5"' ; cRemoveQuotesFromNumbers2 "{$x}" ; (( j++ )) ; done # > /dev/null
        _end=$(date +"%s%3N") ; _two=$(( _two + _end - _middle ))
    done ; echo $_one : $_two 
} 
# perfCheck ; exit 

cDeleteSimpleJsonKey() { # cDeleteSimpleJsonKey "key" "jsondata" (assume $data if jsondata empty)
    local - && set +x
    # shopt -s extglob
    local _d="${2:-$data}"
    local k
    k="$( cHasJsonKey "$1" "$2" )" && [ -z "$k" ] && k="$1" 
    : debug3 "$k"
    if [[ $k ]] ; then  #       replacing:  jq -r ".$1 // empty" <<< "$_d" :
        if      [[ $_d =~ ([,{])([[:space:]]*\"$k\"[[:space:]]*:[[:space:]]*[0-9.+-]+[[:space:]]*)([,}])     ]] || # number: ^[+-]?(0|[1-9][0-9]*)(\.[0-9]+)?$
                [[ $_d =~ ([,{])([[:space:]]*\"$k\"[[:space:]]*:[[:space:]]*\"[^\"]*\"[[:space:]]*)([,}])   ]] ||  # string
                [[ $_d =~ ([,{])([[:space:]]*\"$k\"[[:space:]]*:[[:space:]]*\[[^\]]*\][[:space:]]*)([,}])   ]] ||  # array
                [[ $_d =~ ([,{])([[:space:]]*\"$k\"[[:space:]]*:[[:space:]]*\{[^\}]*\}[[:space:]]*)([,}])   ]] ; then # curly braces, FIXME: max one level for now
            if [[ ${BASH_REMATCH[3]} == "}" ]] ; then
                _f="${BASH_REMATCH[1]/\{}${BASH_REMATCH[2]}" ; true
            else
                _f="${BASH_REMATCH[2]}${BASH_REMATCH[3]}" ; false
            fi
            _f=${_f/]/\\]} # escaping a closing square bracket in the found match
            _d="${_d/$_f/}"
        else :
        fi        
    fi
    # cHasJsonKey "$@" && echo "$_d"
    [[ $2 ]] && echo "$_d" || data="$_d"
} 
# set -x ; cDeleteSimpleJsonKey "freq" '{"protocol":73,"id":11,"channel": 1,"battery_ok": 1,"freq":433.903,"temperature": 8,"BAND":433,"NOTE2":"=2nd (#3,_bR=1,260s)"}' ; exit 1
# set -x ; data='{"one":"a","beta":22.1}' ; cDeleteSimpleJsonKey "one" ; cDeleteSimpleJsonKey beta ; cDeleteSimpleJsonKey two '{"alpha":"a","two":"xx"}' ; exit 1
# set -x ; cDeleteSimpleJsonKey three '{ "three":"xxx" }' ; exit 1
# set -x ; data='{"one" : 1,"beta":22}' ; cDeleteSimpleJsonKey one "$data" ; cDeleteSimpleJsonKey two '{"two":-2,"beta":22}' ; cDeleteSimpleJsonKey three '{"three":3.3,"beta":2}' ; exit 1
# set -x ; data='{"id":2,"channel":2,"battery_ok":0,"temperature_C":-12.5,"freq":433.902,"rssi":-11.295}' ; cDeleteSimpleJsonKey temperature_C ; cDeleteSimpleJsonKey freq ; exit
# set -x ; data='{"event":"debug","message":{"center_frequency":433910000, "other":"zzzzz"}}' ; cDeleteSimpleJsonKey message ; cCheckExit
# set -x ; data='{"event":"debug","message":{"center_frequency":433910000, "frequencies":[433910000, 868300000, 433910000, 868300000, 433910000, 915000000], "hop_times":[61]}}' ; cDeleteSimpleJsonKey hop_times ; cDeleteSimpleJsonKey frequencies ; cCheckExit

cDeleteJsonKeys() { # cDeleteJsonKeys "key1" "key2" ... "jsondata" (jsondata must be provided)
    local - && set +x   
    local _d="" ; local _r="${*:$#}"
    # dbg "cDeleteJsonKeys $*"
    for k in "${@:1:($#-1)}" ; do
        # k="${k//[^a-zA-Z0-9_ ]}" # only allow alnum chars for attr names for sec reasons
        # _d+=",  .${k// /, .}"  # options with a space are considered multiple options
        for k2 in $k ; do
            _r="$( cDeleteSimpleJsonKey $k2 "$_r" )"
        done
    done
    # _r="$(jq -c "del (${_d#,  })" <<< "${@:$#}")"   # expands to: "del(.xxx, .yyy, ...)"
    echo "$_r"
}
# set -x ; cDeleteJsonKeys 'time mic' '{"time" : "2022-10-18 16:57:47", "protocol" : 19, "model" : "Nexus-TH", "id" : 240, "channel" : 1, "battery_ok" : 1, "temperature_C" : 21.600, "humidity" : 20}' ; exit 1
# set -x ; cDeleteJsonKeys "one" "two" ".four five six" "*_special*" '{"one":"1", "two":2  ,"three":3,"four":"4", "five":5, "_special":"*?+","_special2":"aa*?+bb"}'  ;  exit 1
# results in: {"three":3,"_special2":"aa*?+bb"}

cComplexExtractJsonVal() {
    local - && : set -x
    cHasJsonKey "$1" && jq -r ".$1 // empty" <<< "${2:-$data}"
}
# set -x ; data='{"action":"good","battery":100}' ; cComplexExtractJsonVal action && echo yes ; cComplexExtractJsonVal notthere || echo no ; exit

cExtractJsonVal() {
    local - && set +x # replacement for:  jq -r ".$1 // empty" <<< "${2:-$data}" , avoid spawning jq for performance reasons
    [[ ${2:-$data} ]] || return 1
    if [[ ${2:-$data} ]] && cHasJsonKey "$1" ; then 
        if [[ ${2:-$data} =~ [,{][[:space:]]*(\"$1\")[[:space:]]*:[[:space:]]*\"([^\"]*)\"[[:space:]]*[,}] ]] ||  # string
                [[ ${2:-$data} =~ [,{][[:space:]]*(\"$1\")[[:space:]]*:[[:space:]]*([+-]?(0|[1-9][0-9]*)(\.[0-9]+)?)[[:space:]]*[,}] ]] ; then # number 
            echo "${BASH_REMATCH[2]}"
        fi        
    else false ; fi # return false if not found
}
# set -x ; data='{ "action":"good" , "battery":99.5}' ; cPidDelta 000 && cPidDelta 111 ; cExtractJsonVal action ; cPidDelta 222 ; cExtractJsonVal battery && echo yes ; cExtractJsonVal notthere || echo no ; exit

cAssureJsonVal() {
    cHasJsonKey "$1" &&  jq -er "if (.$1 ${2:+and .$1 $2} ) then 1 else empty end" <<< "${3:-$data}"
}
# set -x ; data='{"action":"null","battery":100}' ; cAssureJsonVal battery ">999" ; cAssureJsonVal battery ">9" ;  exit

cEqualJson() {   # cEqualJson "json1" "json2" "attributes to be ignored" '{"action":"null","battery":100}'
    local - && set +x
    _s1="$1" ; _s2="$2"
    if [[ $3 != "" ]] ; then
        _s1="$( cDeleteJsonKeys "$3" "$_s1" )"
        _s2="$( cDeleteJsonKeys "$3" "$_s2" )"
    fi
    [[ $_s1 == "$_s2" ]] # return code is comparison value
}
# set -x ; data1='{"act":"one","batt":100}' ; data2='{"act":"two","batt":100}' ; cEqualJson "$data1" "$data1" && echo AAA; cEqualJson "$data1" "$data2" || echo BBB; cEqualJson "$data1" "$data1" "act other" && echo CCC; exit

[ -r "$rtl2mqtt_optfile" ] && _moreopts="$( sed -e 's/#.*//'  < "$rtl2mqtt_optfile" | tr -c -d '[:space:][:alnum:]_. -' )" && dbg "Read _moreopts from $rtl2mqtt_optfile"
[[ $* =~ -F\ [0-9]*  ]] && _moreopts="${_moreopts//-F [0-9][0-9][0-9]}" && _moreopts="${_moreopts//-F [0-9][0-9]}" # -F on command line overules any other -F options
cLogMore "Gathered options: $_moreopts $*"

while getopts "?qh:pPt:S:drl:f:F:M:H:AR:Y:iw:c:as:t:T:2vx" opt $_moreopts "$@"
do
    case "$opt" in
    \?) echo "Usage: $sName -h brokerhost -t basetopic -p -r -r -d -l -a -e [-F freq] [-f file] -q -v -x" 1>&2
        exit 1
        ;;
    q)  bQuiet=1
        ;;
    h)  # configure the broker host here or in $HOME/.config/mosquitto_sub
        case "$OPTARG" in     #  http://www.steves-internet-guide.com/mqtt-hosting-brokers-and-servers/
		test)    mqtthost="test.mosquitto.org" ;; # abbreviation
		eclipse) mqtthost="mqtt.eclipseprojects.io"   ;; # abbreviation
        hivemq)  mqtthost="broker.hivemq.com"   ;;
		*)       mqtthost="$( echo "$OPTARG" | tr -c -d '0-9a-z_.' )" ;; # clean up for sec purposes
		esac
   		hMqtt="${hMqtt:+$hMqtt }$mqtthost" # gather them
        ;;
    p)  bAnnounceHass=1
        ;;
    P)  bRetained=1
        ;;
    t)  basetopic="$OPTARG" # other base topic for MQTT
        ;;
    S)  rtl433_opts+=( -S "$OPTARG" ) # pass signal autosave option to rtl_433
        # sSensorMatch="${OPTARG}.*"   # this was the previous meaning of -k
        ;;
    d)  bRemoveAnnouncements=1 # delete (remove) all retained MQTT auto-discovery announcements (before starting), needs a newer mosquitto_sub
        ;;
    r)  # rewrite and simplify output
        (( bRewrite )) && bRewriteMore=1 && dbg "Rewriting even more ..."
        bRewrite=1  # rewrite and simplify output
        ;;
    l)  dLog="$OPTARG" 
        ;;
    f)  fReplayfile="$OPTARG" # file to replay (e.g. for debugging), instead of rtl_433 output
        nMinSecondsOther=0
        nMinOccurences=1
        ;;
    w)  sRoundTo="$OPTARG" # round temperature to this value and humidity to 5-times this value
        ;;
    F)  if   [[ $OPTARG == "868" ]] ; then
            rtl433_opts+=( -f 868.3M -s "$sSuggSampleRate" -Y minmax ) # last tried: -Y minmax, also -Y autolevel -Y squelch   ,  frequency 868... MhZ - -s 1024k
        elif [[ $OPTARG == "915" ]] ; then
            rtl433_opts+=( -f 915M -s "$sSuggSampleRate" -Y minmax ) # minmax
        elif [[ $OPTARG == "27" ]] ; then
            rtl433_opts+=( -f 27.161M -s "$sSuggSampleRate" -Y minmax )  # minmax
        elif [[ $OPTARG == "150" ]] ; then
            rtl433_opts+=( -f 150.0M ) 
        elif [[ $OPTARG == "433" ]] ; then
            rtl433_opts+=( -f 433.91M ) #  -s 256k -f 433.92M for frequency 433... MhZ
        else
            rtl433_opts+=( -f "$OPTARG" )
        fi
        basetopic="$sRtlPrefix/$OPTARG"
        nHopSecs=${nHopSecs:-61} # ${nHopSecs:-61} # (60/2)+11 or 60+1 or 60+21 or 7, i.e. should be a coprime to 60sec
        nStatsSec="5*(nHopSecs-1)"
        ;;
    M)  rtl433_opts+=( -M "$OPTARG" )
        ;;
    H)  nHopSecs=$OPTARG 
        ;;
    A)  rtl433_opts+=( -A )
        ;;
    R)  rtl433_opts+=( -R "$OPTARG" )
        ;;
    Y)  rtl433_opts+=( -Y "$OPTARG" )
        ;;
    i)  bAddIdToTopic=1 
        ;;
    c)  nMinOccurences=$OPTARG # MQTT announcements only after at least $nMinOccurences occurences...
        ;;
    T)  nMinSecondsOther=$OPTARG # seconds before repeating the same reading
        ;;
    a)  bAlways=1
        rtl433_opts+=( "${rtl433_opts_more[@]}" )
        nMinOccurences=1
        ;;
    s)  sSuppressAttrs="$sSuppressAttrs ${OPTARG//[^a-zA-Z0-9_]}" # sensor attributes that will be always eliminated
        ;;
    2)  bTryAlternate=1 # ease coding experiments (not to be used in production)
        ;;
    v)  (( bVerbose )) && bMoreVerbose=1 && rtl433_opts=( "-M noise:60" "${rtl433_opts[@]}" -v )
        bVerbose=1 # more output for debugging purposes
        ;;
    x)  set -x # turn on shell debugging from here on
        ;;
    esac
done

shift $((OPTIND-1))   # Discard options processed by getopts, any remaining options will be passed to mosquitto_sub further down on

# fixed in rtl_433 8e343ed: the real hop secs seam to be 1 higher than the value passed to -H...
rtl433_opts+=( ${nHopSecs:+-H $nHopSecs} ${nStatsSec:+-M stats:1:$nStatsSec} )
sRoundTo="$( cMultiplyTen "$sRoundTo" )"

if [ -f "${dLog}.log" ] ; then  # one logfile only
    sDoLog="file"
else
    sDoLog="dir"
    if mkdir -p "$dLog/model" && [ -w "$dLog" ] ; then
        :
    else
        dLog="/tmp/${sName// /}" && cLogMore "Defaulting to dLog $dLog"
        mkdir -p "$dLog/model" || { log "Can't mkdir $dLog/model" ; exit 1 ; }
    fi
    cd "$dLog" || { log "Can't cd to $dLog" ; exit 1 ; }
fi

command -v jq > /dev/null || { _msg="$sName: jq might be necessary!" ; log "$_msg" ; echo "$_msg" 1>&2 ; }

if [[ $fReplayfile ]]; then
    sBand=999
else
    _startup="$( $rtl433_command "${rtl433_opts[@]}" -T 1 2>&1 )"
    # echo "$_startup" ; exit
    sdr_tuner="$(  awk -- '/^Found /   { print gensub("Found ", "",1, gensub(" tuner$", "",1,$0)) ; exit }' <<< "$_startup" )" # matches "Found Fitipower FC0013 tuner"
    sdr_freq="$(   awk -- '/^Tuned to/ { print gensub("MHz.", "",1,$3)                            ; exit }' <<< "$_startup" )" # matches "Tuned to 433.900MHz."
    conf_files="$( awk -F \" -- '/^Trying conf/ { print $2 }' <<< "$_startup" | xargs ls -1 2>/dev/null )" # try to find an existing config file
    sBand="$( cMapFreqToBand "$(cExtractJsonVal sdr_freq)" )"
fi
basetopic="$sRtlPrefix/$sBand" # derive intial setting for basetopic

# Enumerate the supported protocols and their names, put them into an array
_protos="$( $rtl433_command -R 99999 2>&1 | awk '$1 ~ /\[[0-9]+\]/ { p=$1 ; printf "%d" , gensub("[\\]\\[\\*]","","g",$1)  ; $1="" ; print $0}' )" # ; exit
declare -A aNames ; while read -r p name ; do aNames["$p"]="$name" ; done <<< "$_protos"

cEchoIfNotDuplicate() {
    local - && set +x
    if [[ "$1..$2" != "$gPrevData" ]] ; then
        # (( bWasDuplicate )) && echo -e "\n" # echo a newline after some dots
        echo -e "$1${2:+\n$2}"
        gPrevData="$1..$2" # save the previous data
        bWasDuplicate=""
    else
        printf "."
        bWasDuplicate=1
    fi
 }

_info="*tuner*:*$sdr_tuner*,*freq*:$sdr_freq,*additional_rtl433_opts*:*${rtl433_opts[*]}*,*logto*:*$dLog ($sDoLog)*,*rewrite*:*${bRewrite:-no}${bRewriteMore:-no}*,*nMinOccurences*:$nMinOccurences,*nMinSecondsTempSensor*:$nMinSecondsTempSensor,*nMinSecondsOther*:$nMinSecondsOther,*sRoundTo*:$sRoundTo"
if [ -t 1 ] ; then # probably running on a terminal
    log "$sName starting at $(cDate)"
    cMqttStarred log "{*event*:*starting*,$_info}"
else               # probably non-terminal
    delayedStartSecs=3
    log "$sName starting in $delayedStartSecs secs from $(cDate)"
    sleep "$delayedStartSecs"
    cMqttStarred log "{*event*:*starting*,$_info,*note*:*delayed by $delayedStartSecs secs*,*sw_version*=*$rtl433_version*,*user*:*$( id -nu )*,*cmdargs*:*$commandArgs*}"
fi

# Optionally remove any matching retained announcements
(( bRemoveAnnouncements )) && cHassRemoveAnnounce

trap_exit() {   # stuff to do when exiting
    local - && set +x
    log "$sName exit trapped at $(cDate): removeAnnouncements=$bRemoveAnnouncements. Will then log state."
    (( bRemoveAnnouncements )) && cHassRemoveAnnounce
    (( rtlcoproc_PID )) && _cppid="$rtlcoproc_PID" && kill "$rtlcoproc_PID" && dbg "Killed coproc PID $_cppid"    # avoid race condition after killing coproc
    nReadings=${#aLastReadings[@]}
    cMqttState "*collected_sensors*:*${!aLastReadings[*]}*"
    cMqttStarred log "{*event*:*warning*,*note*:*Exiting.*}"
    # rm -f "$conf_file" # remove a created pseudo-conf file if any
 }
trap 'trap_exit' EXIT # previously also: INT QUIT TERM 

trap_int() {    # log all collected sensors to MQTT
    trap '' INT 
    log "$sName received signal INT: logging state to MQTT"
    cMqttStarred log "{*event*:*debug*,*note*:*received signal INT*,$_info}"
    cMqttStarred log "{*event*:*debug*,*note*:*received signal INT, will publish collected sensors* }"
    cMqttState "*collected_sensors*:*${!aLastReadings[*]}* }"
    nLastStatusSeconds=$(cDate %s)
    trap 'trap_int' INT 
 }
trap 'trap_int' INT 

trap_usr1() {    # toggle verbosity 
    (( bVerbose )) && bVerbose="" || bVerbose=1 # switch bVerbose
    _msg="received signal USR1: toggled verbosity to ${bVerbose:-no}, nHopSecs=$nHopSecs, current sBand=$sBand"
    log "$sName $_msg"
    cMqttStarred log "{*event*:*debug*,*note*:*$_msg*}"
  }
trap 'trap_usr1' USR1

trap_usr2() {    # remove all home assistant announcements 
    cHassRemoveAnnounce
    _msg="received signal USR2: resetting all home assistant announcements"
    log "$sName $_msg"
    cMqttStarred log "{*event*:*debug*,*note*:*$_msg*}"
  }
trap 'trap_usr2' USR2 

trap_vtalrm() { # re-emit all recorded sensor readings (e.g. for debugging purposes)
    cMqttState
    for KEY in "${!aLastReadings[@]}"; do
        _reading="${aLastReadings[$KEY]}" && _reading="${_reading/{/}" && _reading="${_reading/\}/}"
        _msg="{*model_ident*:*$KEY*,${_reading//\"/*}}"
        dbg READING "$KEY  $_msg"
        cMqttStarred reading "$_msg"
    done
    _msg="received signal VTALRM: logging state"
    log "$sName $_msg"
    cMqttStarred log "{*event*:*debug*,*note*:*$_msg*}"
  }
trap 'trap_vtalrm' VTALRM

trap_other() {
    _msg="received other signal ..."
    log "$sName $_msg"
    cMqttStarred log "{*event*:*debug*,*note*:*$_msg*}"
  }
trap 'trap_other' URG XCPU XFSZ PROF WINCH PWR SYS # VTALRM

if [[ $fReplayfile ]] ; then
    nMinSecondsOther=0
    # set -x
#    head -0 "$fReplayfile" | while read -r line ; do 
#        # https://www.golinuxcloud.com/bash-split-string-into-array-linux
#        IFS=' ' read -r -a aArray <<< "${line%%[{[]*}"
#        echo "${aArray[-1]}"  # this is the topic if a time stamp is in front
#        m="${line##*([!{])}"
#    done
    # exit 99
     
    # coproc rtlcoproc ( shopt -s extglob ; export IFS=' ' ; while read -r line ; do read -r -a aArray <<< "${line%%{*(.)}" ; t= "${aArray[-1]}"; echo "${line##*([!{])}"; sleep 1 ; done < "$fReplayfile" ; sleep 5 ) # remove anything from the replay file before an opening curly brace
    coproc rtlcoproc ( shopt -s extglob ; export IFS=' ' ; while read -r line ; do 
            : "line $line" 1>&2
            : "FRONT ${line%%{+(?)}" 1>&2
            data="${line##*([!{])}"
            read -r -a aArray <<< "${line%%{+(?)}" 
            : topic="${aArray[-1]}"  # ; echo "t $topic" 1>&2
            IFS='/' read -r -a aTopic <<< "${aArray[-1]}" # topic might be preceded by timestamps to be removed
            : model="${aTopic[3]}"
            [[ ${aTopic[0]} == "rtl" &&  ${#aTopic} == 3 ]] && ! cHasJsonKey model && cAppendJsonKeyVal model "${aTopic[2]}"
            echo "$data" ; sleep 1
            set +x
        done < "$fReplayfile" ; sleep 5
    ) # remove anything from the replay file before an opening curly brace
    # set +x
else
    if [[ $bVerbose || -t 1 ]] ; then
        cLogMore "rtl_433 ${rtl433_opts[*]}"
        (( nMinOccurences > 1 )) && cLogMore "Will do MQTT announcements only after at least $nMinOccurences occurences..."
    fi 
    # Start the RTL433 listener as a bash coprocess .... # https://unix.stackexchange.com/questions/459367/using-shell-variables-for-command-options
    coproc rtlcoproc ( $rtl433_command ${conf_file:+-c "$conf_file"} "${rtl433_opts[@]}" -F json  2>&1 ; sleep 3 )
    # -F "mqtt://$mqtthost:1883,events,devices"

    if (( bAnnounceHass )) && sleep 1 && (( rtlcoproc_PID  )) ; then
        # _statistics="*sensorcount*:*$nReadings*,*announcedcount*:*$nAnnouncedCount*,*mqttlinecount*:*$nMqttLines*,*receivedcount*:*$nReceivedCount*,*readingscount*:*$nReadings*"
        ## cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "TestVal" "value_json.mcheck" "mcheck"
        cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "AnnouncedCount"   "value_json.announceds" "counter" &&
        cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "SensorCount"      "value_json.sensors"  "counter"   &&
        cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "MqttLineCount"    "value_json.mqttlines" "counter"  &&
        cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "ReadingsCount"    "value_json.receiveds" "counter"  &&
        cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "Start date"       "value_json.startdate" "clock"    &&
        cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/log   "LogMessage"       ""           "none"                 
        nRC=$?
        (( nRC != 0 )) && echo "ERROR: HASS Announcements failed with rc=$nRC" 1>&2
        sleep 1
    fi
    (( rtlcoproc_PID )) && renice -n 17 "${rtlcoproc_PID}" > /dev/null
fi 

while read -r data <&"${rtlcoproc[0]}" ; _rc=$? ; (( _rc==0  || _rc==27 ))      # ... and go through the loop
do
    _beginPid="" # support debugging/counting/optimizing number of processes started in within the loop

    if [[ $data =~ ^SDR:.Tuned.to.([0-9]*\.[0-9]*)MHz ]] ; then # SDR: Tuned to 868.300MHz.
        # convert  msg type "SDR: Tuned to 868.300MHz." to "{"center_frequency":868300000}" (JSON) to be processed further down
        data="{\"center_frequency\":${BASH_REMATCH[1]}${BASH_REMATCH[2]}000,\"BAND\":$(cMapFreqToBand "${BASH_REMATCH[1]}")}"
    elif [[ $data =~ ^rtlsdr_set_center_freq.([0-9\.]*) ]] ; then 
        # convert older msg type "rtlsdr_set_center_freq 868300000 = 0" to "{"center_frequency":868300000}" (JSON) to be processed further down
        data="{\"center_frequency\":${BASH_REMATCH[1]},\"BAND\":$(cMapFreqToBand "${BASH_REMATCH[1]}")}"
    elif [[ $data =~ ^[^{] ]] ; then # transform any any non-JSON line (= JSON line starting with "{"), e.g. from rtl_433 debugging/error output
        data=${data#\*\*\* } # Remove any leading stars "*** "
        if [[ $bMoreVerbose && $data =~ ^"Allocating " ]] ; then # "Allocating 15 zero-copy buffers"
            cMqttStarred log "{*event*:*debug*,*note*:*${data//\*/+}*}" # convert it to a simple JSON msg
        elif [[ $data =~ ^"Please increase your allowed usbfs buffer size"|^"usb" ]] ; then
            dbg WARNING "$data"
            cMqttStarred log "{*event*:*error*,*note*:*${data//\*/+}*}" # log a simple JSON msg
        fi
        log "Non-JSON: $data"
        continue
    elif [ -z "$data" ] ; then
        continue # skip empty lines immediately
    fi
    # cPidDelta 0ED
    if [[ $data =~ "center_frequency" ]] && _freq="$(cExtractJsonVal center_frequency)" ; then
        data="${data//\" : /\":}" # beautify a bit, i.e. removing extra spaces
        sBand="$(cMapFreqToBand "$_freq")" # formerly: sBand="$( jq -r '.center_frequency / 1000000 | floor  // empty' <<< "$data" )"
        basetopic="$sRtlPrefix/${sBand:-999}"
        (( bVerbose )) && cEchoIfNotDuplicate "CENTER: $data"
        _freqs="$(cExtractJsonVal frequencies)" && cDeleteSimpleJsonKey "frequencies" && : "${_freqs}"
        (( bVerbose )) && cMqttStarred log "{*event*:*debug*,*message*:${data//\"/*}}"
        nLastCenterMessage="$(cDate %s)" # prepare for avoiding race condition after freq hop (FIXME: not implemented yet)
        continue
    fi
    (( bVerbose )) && echo "================================="
    dbg RAW ":$data:"
    data="${data//\" : /\":}" # remove superflous space around the colons
    nReceivedCount=+1

    # cPidDelta 1ST

    _time="$(cExtractJsonVal time)"  # ;  _time="2021-11-01 03:05:07"
    declare +i _str # avoid octal interpretation of any leading zeroes
    # cPidDelta AAA
    _str="${_time:(-8):2}" && nHour=${_str#0} 
    _str="${_time:(-5):2}" && nMinute=${_str#0} 
    _str="${_time:(-2):2}" && nSecond=${_str#0}
    _delkeys="time $sSuppressAttrs"
    (( bMoreVerbose )) && cEchoIfNotDuplicate "PREPROCESSED: $data"
    # cPidDelta BBB
    protocol="$(cExtractJsonVal protocol)"
    channel="$( cExtractJsonVal channel)"
    model="$(   cExtractJsonVal model)"    
    id="$(      cExtractJsonVal id)"
    rssi="$(    cExtractJsonVal rssi)"
    temperature="$( cExtractJsonVal temperature_C || cExtractJsonVal temperature)" 
    setpoint="$( cExtractJsonVal setpoint_C) || $( cExtractJsonVal setpoint_F)"
    cHasJsonKey freq && sBand="$( cMapFreqToBand "$(cExtractJsonVal freq)" )" && basetopic="$sRtlPrefix/$sBand"
    log "$(cAppendJsonKeyVal BAND "${model:+$sBand}" "$data" )" # only append band when model is given, i.e. not for non-sensor messages.
    
    # cPidDelta DDD
    [[ $model && ! $id ]] && id="$(cExtractJsonVal address)" # address might be an unique alternative to id under some circumstances, still to TEST ! (FIXME)
    ident="${channel:-$id}" # prefer channel (if present) over id as the unique identifier.
    model_ident="${model}${ident:+_$ident}"
    
    [[ ! $bVerbose && ! $model_ident =~ $sSensorMatch ]] && : skip early && continue # skip unwanted readings (regexp) early (if not verbose)

    # cPidDelta 2ND

    if [[ $model_ident && ! $bRewrite ]] ; then                  # Clean the line from less interesting information....
        : no rewriting
        data="$( cDeleteJsonKeys "$_delkeys" "$data" )"
    elif [[ $model_ident && $bRewrite ]] ; then                  
        : Rewrite and clean the line from less interesting information....
        # sample: {"id":20,"channel": 1,"battery_ok": 1,"temperature":18,"humidity":55,"mod":"ASK","freq":433.931,"rssi":-0.261,"snr":24.03,"noise":-24.291}
        _delkeys="$_delkeys model mod snr noise mic rssi" && [ -z "$bVerbose" ] && _delkeys="$_delkeys freq freq1 freq2" # other stuff: subtype channel
        [[ ${aLastReadings[$model_ident]} && ${temperature/.*} -lt 50 ]] && _delkeys="$_delkeys protocol" # remove protocol after first sight  and when not unusual
        data="$( cDeleteJsonKeys "$_delkeys" "$data" )" 
        cRemoveQuotesFromNumbers
        if [[ $temperature ]] ; then
            temperature="$(( ( $(cMultiplyTen "$temperature") + sRoundTo/2 ) / sRoundTo * sRoundTo ))" && temperature="$(cDiv10 $temperature)"  # round to 0.x °C
            cDeleteSimpleJsonKey temperature_C
            cAppendJsonKeyVal temperature "$temperature"
            [[ ${aPrevTempVals[$model_ident]} ]] || aPrevTempVals[$model_ident]=0
        else 
            : temperature==""
        fi

        humidity="$( cExtractJsonVal humidity )"
        if [[ $humidity ]] ; then
            _hmult=4
            # humidity="$( awk "BEGIN { printf \"%d\n\" , int( $humidity * $sRoundTo / 4) + 0.5) * 4 / $sRoundTo }" < /dev/null )" # round to 0.x*4 %
            humidity="$(( ( $(cMultiplyTen "$humidity") + sRoundTo*_hmult/2 ) / (sRoundTo*_hmult) * (sRoundTo*_hmult) ))" && humidity="$(cDiv10 $humidity)"  # round to hmult * 0.x
            cDeleteSimpleJsonKey humidity
            cAppendJsonKeyVal humidity "$humidity"
        fi
        
        _bHasParts25="$( [[ $(cExtractJsonVal pm2_5_ug_m3     ) =~ ^[0-9.]+$ ]] && echo 1 )" # e.g. "pm2_5_ug_m3":0, "estimated_pm10_0_ug_m3":0
        _bHasParts10="$( [[ $(cExtractJsonVal estimated_pm10_0_ug_m3 ) =~ ^[0-9.]+$ ]] && echo 1 )" # e.g. "pm2_5_ug_m3":0, "estimated_pm10_0_ug_m3":0
        _bHasRain="$(     [[ $(cExtractJsonVal rain_mm   ) =~ ^[0-9.]+$ ]] && echo 1 )" # formerly: cAssureJsonVal rain_mm ">0"
        _bHasBatteryOK="$(  [[ $(cExtractJsonVal battery_ok) =~ ^[0-9.]+$ ]] && echo 1 )" # 0,1,2 or some float ; formerly: cAssureJsonVal battery_ok "<= 2"
        _bHasPressureKPa="$([[ $(cExtractJsonVal pressure_kPa) =~ ^[0-9.]+$ ]] && echo 1)" # cAssureJsonVal pressure_kPa "<= 9999", at least match a number
        _bHasZone="$(cHasJsonKey zon[e] )" #        {"id":256,"control":"Limit (0)","channel":0,"zone":1,"freq":434.024}
        _bHasUnit="$(cHasJsonKey uni[t] )" #        {"id":25612,"unit":15,"learn":0,"code":"7c818f","freq":433.942}
        _bHasLearn="$(cHasJsonKey lear[n] )" #        {"id":25612,"unit":15,"learn":0,"code":"7c818f","freq":433.942}
        _bHasChannel="$(cHasJsonKey channe[l] )" #        {"id":256,"control":"Limit (0)","channel":0,"zone":1,"freq":434.024}
        _bHasControl="$(cHasJsonKey contro[l] )" #        {"id":256,"control":"Limit (0)","channel":0,"zone":1,"freq":434.024}
        _bHasCmd="$(cHasJsonKey cm[d] )"
        _bHasData="$(cHasJsonKey dat[a] )"
        _bHasCounter="$(cHasJsonKey counte[r] )" #                  {"counter":432661,"code":"800210003e915ce000000000000000000000000000069a150fa0d0dd"}
        _bHasCode="$(   cHasJsonKey cod[e] )" #                  {"counter":432661,"code":"800210003e915ce000000000000000000000000000069a150fa0d0dd"}
        _bHasButtonR="$(cHasJsonKey rbutto[n] )" #  rtl/433/Cardin-S466/00 {"dipswitch":"++---o--+","rbutton":"11R"}
        _bHasDipSwitch="$(cHasJsonKey dipswitc[h] )" #  rtl/433/Cardin-S466/00 {"dipswitch":"++---o--+","rbutton":"11R"}
        _bHasNewBattery="$( cHasJsonKey newbatter[y] )" #  {"id":13,"battery_ok":1,"newbattery":0,"temperature_C":24,"humidity":42}
        _bHasRssi="$(cHasJsonKey rss[i] )"

        if (( bRewriteMore )) ; then
            data="$( cDeleteJsonKeys "transmit test" "$data" )"
            # data="$( cHasJsonKey button &&  jq -c 'if .button == 0 then del(.button) else . end' <<< "$data" || echo "$data" )"
            # .battery_ok==1 means "OK".
            # data="$( cHasJsonKey battery_ok  &&   jq -c 'if .battery_ok == 1 then del(.battery_ok) else . end' <<< "$data" || echo "$data" )"
            # data="$( cHasJsonKey unknown1 &&   jq -c 'if .unknown1 == 0 then del(.unknown1)   else . end' <<< "$data" || echo "$data" )"
            _k="$( cHasJsonKey "unknown.*" )" && [[ $(cExtractJsonVal "$_k")  == 0 ]] && cDeleteSimpleJsonKey "$_k" # delete first key "unknown* == 0"

            # bSkipLine="$( [[ $temperature || $humidity ]] && jq -er 'if (.humidity and .humidity>100) or (.temperature_C and .temperature_C<-50) or (.temperature and .temperature<-50) then "yes" else empty end' <<<"$data"  )"
            temperature=${temperature/.[0-9]*} ; humidity=${humidity/.[0-9]*} 
            bSkipLine=$(( humidity > 100 || temperature < -50 )) # sanitize
        fi
        cAppendJsonKeyVal BAND "$sBand"
        (( bRetained )) && cAppendJsonKeyVal HOUR "$nHour" # Append HOUR explicitly if readings are sent retained
        [[ $sDoLog == "dir" ]] && echo "$(cDate %d %H:%M:%S) $data" >> "$dLog/model/$model_ident"
        # cHasJsonKey freq  &&  data="$( jq -cer '.freq=(.freq + 0.5 | floor)' <<< "$data" )" # the frequency always changes a little, will distort elimination of duplicates, and is contained in MQTT topic anyway.
    fi
    # cPidDelta 3RD

    nTimeStamp=$(cDate %s)
    # Send message to MQTT or skip it ...
    if (( bSkipLine )) ; then
        dbg SKIPPING "$data"
        bSkipLine=0
        continue
    elif [ -z "$model_ident" ] ; then # probably a stats message
        dbg "model_ident is empty"
        (( bVerbose )) && data="${data//\" : /\":}" && cEchoIfNotDuplicate "STATS: $data" && cMqttStarred stats "${data//\"/*}" # ... publish stats values (from "-M stats" option)

    elif [[ $bAlways || ${data/"freq":434/} != "${prev_data/"freq":434/}" || $nTimeStamp -gt $((prev_time+nMinSecondsOther)) ]] ; then
        : ignoring frequency changes within the 433/434 range when comparing for a change....
        if (( bVerbose )) ; then
            (( bRewrite )) && cEchoIfNotDuplicate "CLEANED: $model_ident = $data" # resulting message for MQTT
            [[ ! $model_ident =~ $sSensorMatch ]] && continue # skip if no match
        fi
        prev_data="$data"
        prev_time="$nTimeStamp"
        prevval="${aLastReadings[$model_ident]}"
        prevvals="${aSecondLastReadings[$model_ident]}"
        aLastReadings[$model_ident]="$data"
        aCounts[$model_ident]+=1
        # aProtocols[${protocol}]="$model"
        if (( bMoreVerbose && ! bQuiet )) ; then
            _prefix="SAME:  "  &&  [[ ${aLastReadings[$model_ident]} != "$prevval" ]] && _prefix="CHANGE(${#aLastReadings[@]}):"
            grep -E --color=auto '^[^/]*|/' <<< "$_prefix $model_ident /${aLastReadings[$model_ident]}/$prevval/"
        fi
        nTimeDiff=$(( ( ${#temperature} || ${#humidity} ) && (nMinSecondsTempSensor>nMinSecondsOther)  ?  nMinSecondsTempSensor : nMinSecondsOther  ))
        _issame=$( cEqualJson "$data" "$prevval" "freq freq1 freq2 rssi id" && echo 1 )
        [[ $_issame && ! $bMoreVerbose ]] && nTimeDiff=$(( nTimeDiff * 2 )) # delay outputting further if values are the same as last time
        _bAnnounceReady=$(( bAnnounceHass && aAnnounced[$model_ident] != 1 && aCounts[$model_ident] >= nMinOccurences ))

        if (( bVerbose )) ; then
            echo "nTimeDiff=$nTimeDiff, announceReady=$_bAnnounceReady, temperature=$temperature, humidity=$humidity, hasCmd=$_bHasCmd, hasButtonR=$_bHasButtonR, hasDipSwitch=$_bHasDipSwitch, hasNewBattery=$_bHasNewBattery, hasControl=$_bHasControl"
            # (( nTimeStamp > nLastStatusSeconds+nLogMinutesPeriod*60 || (nMqttLines % nLogMessagesPeriod)==0 ))
            echo "model_ident=$model_ident, Readings=${aLastReadings[$model_ident]}, Counts=${aCounts[$model_ident]}, Prev=$prevval, Prev2=$prevvals, Time=$nTimeStamp-${aLastSents[$model_ident]}=$(( nTimeStamp - aLastSents[$model_ident] ))"
        fi
        
        if (( _bAnnounceReady )) ; then
            : Checking each announcement types - For now, only the following certain types of sensors are announced:
            if (( ${#temperature} || _bHasPressureKPa || _bHasCmd || _bHasData ||_bHasCode || _bHasButtonR || _bHasDipSwitch 
                    || _bHasCounter || _bHasControl || _bHasParts25 || _bHasParts10 )) ; then
                [[ $protocol    ]] && _name="${aNames["$protocol"]:-$model}" || _name="$model" # fallback
                # if the sensor has one of the above attributes, announce all the attributes it has ...:
                # see https://github.com/merbanan/rtl_433/blob/master/docs/DATA_FORMAT.md
                [[ $temperature ]]      && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Temp"      "value_json.temperature"   temperature
                [[ $humidity    ]]      && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Humid"     "value_json.humidity"  humidity
                cHasJsonKey setpoint_C  && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }TempTarget"      "value_json.setpoint_C"   setpoint
                (( _bHasPressureKPa )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }PressureKPa"  "value_json.pressure_kPa" pressure_kPa
                (( _bHasBatteryOK  )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Battery"   "value_json.battery_ok"    battery_ok
                (( _bHasCmd        )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Cmd"       "value_json.cmd"   motion
                (( _bHasData       )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Data"       "value_json.data"   data
                if (( _bHasRssi && bMoreVerbose )) ; then
                    cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }RSSI"       "value_json.rssi"   signal # FIXME: simplify
                fi
                (( _bHasCounter    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Counter"   "value_json.counter"   counter
                (( _bHasParts25    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Fine Parts"  "value_json.pm2_5_ug_m3" density25
                (( _bHasParts10    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Estim Course Parts"  "value_json.estimated_pm10_0_ug_m3" density10
                (( _bHasCode       )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Code"       "value_json.code"     code
                (( _bHasButtonR    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }ButtonR"    "value_json.buttonr"  button
                (( _bHasDipSwitch  )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }DipSwitch"  "value_json.dipswitch" dipswitch
                (( _bHasNewBattery )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }NewBatttery"  "value_json.newbattery" newbattery
                (( _bHasZone       )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Zone"       "value_json.zone"     zone
                (( _bHasUnit       )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Unit"       "value_json.unit"     unit
                (( _bHasLearn      )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Learn"       "value_json.learn"     learn
                (( _bHasChannel    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Channel"    "value_json.channel"  channel
                (( _bHasControl    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Control"    "value_json.control"  control
                #   [[ $sBand ]]  && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Freq"     "value_json.FREQ" frequency
                if  cMqttStarred log "{*event*:*debug*,*note*:*announced MQTT discovery: $model_ident ($_name)*}" ; then
                    nAnnouncedCount+=1
                    cMqttState
                    sleep 1 # give the MQTT readers an extra second to digest the announcement
                    aAnnounced[$model_ident]=1 # 1=took place=dont reconsider for announcement
                else
                    : announcement had failed, will be retried next time
                fi
            else
                cMqttStarred log "{*event*:*debug*,*note*:*not announced for MQTT discovery (no sensible sensor): $model_ident*}"
                aAnnounced[$model_ident]=1 # 1 = took place (= dont reconsider for announcement)
            fi
        fi
        # cPidDelta 4TH

        if [[ ! $_issame || $nTimeStamp -gt $(( aLastSents[$model_ident] + nTimeDiff )) || $_bAnnounceReady == 1 || $fReplayfile ]] ; then # rcvd data should be different from previous reading(s) but not if coming from replayfile
            : now final rewrite and publish readings
            aLastReadings[$model_ident]="$data"
            if (( bRewrite )) ; then
                # [[ $rssi ]] && cAppendJsonKeyVal rssi "$rssi" # put rssi back in
                if [[ ! $_issame ]] ; then
                    cAppendJsonKeyVal NOTE "CHANGE"
                elif ! cEqualJson "$data" "$prevvals" "freq freq1 freq2 rssi id" ; then
                    (( bVerbose )) && cAppendJsonKeyVal NOTE2 "=2ND (#${aCounts[$model_ident]},_bR=$_bAnnounceReady,${nTimeDiff}s)"
                fi
                aSecondLastReadings[$model_ident]="$prevval"
            fi
            if cMqttStarred "$basetopic/$model${channel:+/$channel}$( [[ $bAddIdToTopic ]] && echo "${id:+/$id}" )" "${data//\"/*}" ${bRetained:+ -r} ; then # ... try to publish the values!
                nMqttLines+=1
                aLastSents[$model_ident]="$nTimeStamp"
            else
                : sending had failed
            fi
        else
            dbg "Suppressed a duplicate..." 
        fi
    fi
    nReadings=${#aLastReadings[@]}

    if (( nReadings > nPrevMax )) ; then   # a new max implies we have a new sensor
        nPrevMax=nReadings
        _sensors="${temperature:+*temperature*,}${humidity:+*humidity*,}${_bHasPressureKPa:+*pressure_kPa*,}${_bHasBatteryOK:+*battery*,}${_bHasRain:+*rain*,}"
        cMqttStarred log "{*event*:*sensor added*,*model*:*$model*,*id*:$id,*channel*:*$channel*,*desc*:*${protocol:+${aNames[$protocol]}}*,*protocol*:*$protocol*, *sensors*:[${_sensors%,}]}"
        cMqttState
    elif (( nTimeStamp > nLastStatusSeconds+nLogMinutesPeriod*60 || (nMqttLines % nLogMessagesPeriod)==0 )) ; then   
        # log the status once in a while, good heuristic in a generalized neighbourhood
        _collection="*sensorreadings*:[$(  _comma=""
            for KEY in "${!aLastReadings[@]}"; do
                _reading="${aLastReadings[$KEY]}" && _reading="${_reading/{/}" && _reading="${_reading/\}/}"
                echo -n "$_comma {*model_ident*:*$KEY*,${_reading//\"/*}}"
                _comma=","
            done
        )] "
        log "$( cExpandStarredString "$_collection")" 
        cMqttState "*note*:*regular log*,*collected_model_ids*:*${!aLastReadings[*]}*, $_collection"
        nLastStatusSeconds=nTimeStamp
    elif (( nReadings > (nSecond*nSecond+2)*(nMinute+1)*(nHour+1) || nMqttLines%5000==0 || nReceivedCount % 10000 == 0 )) ; then # reset whole array to empty once in a while = starting over
        cMqttState
        cMqttStarred log "{*event*:*debug*,*note*:*will reset saved values (nReadings=$nReadings,nMqttLines=$nMqttLines,nReceivedCount=$nReceivedCount)*}"
        unset aLastReadings && declare -A aLastReadings # reset the whole collection (array)
        unset aCounts   && declare -A aCounts
        unset aAnnounced && declare -A aAnnounced
        nPrevMax=nPrevMax/3            # reduce it quite a bit (but not back to 0) to reduce future log message
        (( bRemoveAnnouncements )) && cHassRemoveAnnounce
    fi
done

s=1 && [ ! -t 1 ] && s=30 # sleep a little longer if not running on a terminal
_msg="$sName: read returned rc=$_rc from $( basename "${fReplayfile:-$rtl433_command}" ) ; loop ended $(cDate): rtlprocid=:${rtlcoproc_PID:; last data=$data;} sleep=${s}s"
log "$_msg" 
cMqttStarred log "{*event*:*endloop*,*note*:*$_msg*}"
dbg END "$_msg"
[[ $fReplayfile ]] || { sleep $s ; exit 1 ; } # return 1 only for premature end of rtl_433 command
# now the exit trap function will be processed...