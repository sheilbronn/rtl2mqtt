#!/bin/bash

# rtl2mqtt reads events from a RTL433 SDR and forwards them to a MQTT broker as enhanced JSON messages 

# Adapted and enhanced for conciseness, verboseness and flexibility by "sheilbronn"
# (inspired by work from "IT-Berater" and M. Verleun)

# set -o noglob     # file name globbing is neither needed nor wanted (for security reasons)
set -o noclobber  # disable for security reasons
sName="${0##*/}" && sName="${sName%.sh}"
sMID="$( basename "${sName// /}" .sh )"
sID="$sMID"
rtl2mqtt_optfile="$( [ -r "${XDG_CONFIG_HOME:=$HOME/.config}/.$sName" ] && echo "$XDG_CONFIG_HOME/$sName" || echo "$HOME/.$sName" )" # ~/.config/rtl2mqtt or ~/.rtl2mqtt

commandArgs="$*"
dLog="/var/log/$sMID" # /var/log is default, but will be changed to /tmp if not useable
sManufacturer="RTL"
sHassPrefix="homeassistant/sensor"
sRtlPrefix="rtl"
sStartDate="$(date "+%Y-%m-%dT%H:%M:%s")" # format needed for OpenHab DateTime MQTT items - for others OK, too? - as opposed to ISO8601
basetopic=""                  # default MQTT topic prefix
rtl433_command="rtl_433"
rtl433_command=$( command -v $rtl433_command ) || { echo "$sName: $rtl433_command not found..." 1>&2 ; exit 1 ; }
rtl433_version="$( $rtl433_command -V 2>&1 | awk -- '$2 ~ /version/ { print $3 ; exit }' )" || exit 1
rtl433_opts=( -M protocol -M noise:300 -M level -C si )  # generic options for everybody, e.g. -M level 
# rtl433_opts=( "${rtl433_opts[@]}" $( [ -r "$HOME/.$sName" ] && tr -c -d '[:alnum:]_. -' < "$HOME/.$sName" ) ) # FIXME: protect from expansion!
rtl433_opts_more="-R -31 -R 53 -R -86" # My specific personal excludes
sSuppressAttrs="mic" # attributes that will be always eliminated from JSON msg
sSensorMatch=".*" # any sensor name will have to match this regex
sRoundTo=0.5 # temperatures will be rounded to this x and humidity to 1+2*x (see below)

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

alias _nx="local - && set +x" # alias to stop local verbosity (within function)
cDate() { printf "%($*)T" ; } # avoid invocating a seperate process
cPid()  { sh -c 'echo $$' ; }

log() {
    local - && set +x
    [ "$sDoLog" ] || return
    if [ "$sDoLog" = "dir" ] ; then
        cRotateLogdirSometimes "$dLog"
        logfile="$dLog/$(cDate %H)"
        echo "$(cDate %d %T)" "$*" >> "$logfile"
        [[ $bVerbose && ${*#{} != "$*" ]] && { printf "%s" "$*" ; echo "" ; } >> "$logfile.JSON"
    else
        echo "$(cDate)" "$@" >> "$dLog.log"
    fi    
  }

cLogMore() {
    local - && set +x
    [ "$sDoLog" ] || return
    echo "$sName:" "$@" 1>&2
    logger -p daemon.info -t "$sID" -- "$*"
    log "$@"
  }

dbg() { # output its args to stderr if option -v was set
	local - && set +x
    [ "$bVerbose" ] || return 1 
    echo "DEBUG: " "$@" 1>&2
    return 0 
	}

cExpandStarredString() {
    _esc="quote_star_quote" ; _str="$1"
    _str="${_str//\"\*\"/$_esc}"  &&  _str="${_str//\"/\'}"  &&  _str="${_str//\*/\"}"  &&  _str="${_str//$esc/\"*\"}"  && echo "$_str"
  }

cRotateLogdirSometimes() {           # check for logfile rotation
    if (( msgMinute + msgSecond == 67 )) ; then  # try logfile rotation only with probability of 1/60
        cd "$1" && _files="$( find . -maxdepth 2 -type f -size +300k "!" -name "*.old" -exec mv '{}' '{}'.old ";" -print0 | xargs -0 )"
        msgSecond=$(( msgSecond + 1 ))
        [[ $_files ]] && cLogMore "Rotated files: $_files"
    fi
  }

cMqttStarred() {		# options: ( [expandableTopic ,] starred_message, moreMosquittoOptions)
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
    mosquitto_pub ${mqtthost:+-h $mqtthost} ${sMID:+-i $sMID} -t "$_topic" -m "$( cExpandStarredString "$_msg" )" $3 $4 $5 # ...  
  }

cMqttState() {	
    _statistics="*sensors*:${nReadings:-0},*announceds*:$nAnnouncedCount,*mqttlines*:$nMqttLines,*receiveds*:$nReceivedCount,*lastfreq*:$sBand,*startdate*:*$sStartDate*,*currtime*:*$(cDate)*"
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
	# local *friendly_name*:*${2:+$2 }$4*,
    local _unit_str="" # the presence of some "unit_of_measurement" makes it a Number in OpenHab

    # From https://www.home-assistant.io/docs/configuration/templating :
    local _value_template_str="${5:+,*value_template*:*{{ $5 \}\}*}" #   generated something like: ... "value_template":"{{ value_json.battery_ok }}" ...
    # other syntax for non-JSON is: local _value_template_str="${5:+,*value_template*:*{{ value|float|round(1) \}\}*}"

    case "$6" in
        temperature*)   _icon_str="thermometer" ; _unit_str=",*unit_of_measurement*:*\u00b0C*" ; _state_class="measurement" ;;
        humidity)	_icon_str="water-percent"   ; _unit_str=",*unit_of_measurement*:*%*"	; _state_class="measurement" ;;
        counter)	_icon_str="counter"         ; _unit_str=",*unit_of_measurement*:*#*"	; _state_class="total_increasing" ;;
		clock)	    _icon_str="clock-outline" ;;
        switch)     _icon_str="toggle-switch*" ;;
        motion)     _icon_str="motion-sensor" ;;
        button)     _icon_str="gesture-tap-button" ;;
        dipswitch)     _icon_str="dip-switch" ;;
        newbattery)     _icon_str="battery-check" ;;
       # battery*)     _unit_str=",*unit_of_measurement*:*B*" ;;  # 1 for "OK" and 0 for "LOW".
        zone)   _icon_str="vector-intersection" ; _unit_str=",*unit_of_measurement*:*#*" ; _state_class="measurement" ;;
        channel)   _icon_str="format-list-numbered" ; _unit_str=",*unit_of_measurement*:*#*" ; _state_class="measurement" ;;
        battery_ok)   _icon_str="" ; _unit_str=",*unit_of_measurement*:*#*" ; _state_class="measurement" ;;
       # mcheck)   _icon_str="" ; _unit_str=",*unit_of_measurement*:*#*"  ;; # FIXME: remove
		none)		  _icon_str="" ;; 
    esac

    _icon_str="${_icon_str:+,*icon*:*mdi:$_icon_str*}"
    local  _device="*device*:{*name*:*$_devname*,*manufacturer*:*$sManufacturer*,*model*:*$2 ${protocol:+(${aNames[$protocol]}) ($protocol) }with id $_devid*,*identifiers*:[*${sID}${_configtopicpart}*],*sw_version*:*rtl_433 $rtl433_version*}"
    local  _msg="*name*:*$_channelname*,*~*:*$_sensortopic*,*state_topic*:*~*,$_device,*device_class*:*${6:-none}*,*unique_id*:*${sID}${_configtopicpart}${_jsonpath_red^[a-z]*}*${_unit_str}${_value_template_str}${_command_topic_str}$_icon_str${_state_class:+,*state_class*:*$_state_class*}"
           # _msg="$_msg,*availability*:[{*topic*:*$basetopic/bridge/state*}]" # STILL TO DEBUG
           # _msg="$_msg,*json_attributes_topic*:*~*" # STILL TO DEBUG

   	cMqttStarred "$_topic" "{$_msg}" "-r"
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

cHassRemoveAnnounce() {
    _topic="$sHassPrefix/sensor/#" 
    _topic="$( dirname $sHassPrefix )/#" # deletes eveything below "homeassistant/sensor/..." !
    cLogMore "removing all announcements below $_topic..."
    mosquitto_sub ${mqtthost:+-h $mqtthost} ${sMID:+-i $sMID} -W 1 -t "$_topic" --remove-retained --retained-only
    _rc=$?
    sleep 1
    cMqttStarred log "{*note*:*removed all announcements starting with $_topic returned $_rc.* }"
}

cAppendJsonKeyVal() {  # cAppendJsonKeyVal "key" "val" "jsondata" (use $data if $3 empty, no quoting for numbers)
    local - && set +x
    shopt -s extglob
    _val="$2" ; _d="${3:-$data}"
    [ -z "$_val" ] && echo "$_d"
    [ -n "${_val//@(-[0-9.]*|[0-9][0-9.]*)/}" ] && _val="\"$_val\"" # surround by double quotes only if non-number
    echo "${_d/%\}/,\"$1\":$_val\}}"
}
# set -x ; data='{"one":1}' ; cAppendJsonKeyVal "x" "2x" ; cAppendJsonKeyVal "n" "2.3" ; cAppendJsonKeyVal "m" "-" ; exit  # returns: '{one:1,"x":"2"}'
# cAppendJsonKeyVal "donot" "" '{"one":1}' ;    exit  # returns: '{"one":1,"donot":""}'

cDeleteJsonKey() { # cDeleteJsonKey "key1" "key2" ... "jsondata" (jsondata must be provided)
    local - && set +x   
    local _d
    for k in "${@:1:($#-1)}" ; do
        k="${k//[^a-zA-Z0-9_ ]}" # only allow alnum chars for attr names for sec reasons
        _d="$_d,  .${k// /, .}"  # options with a space are considered multiple options
    done
    jq -c "del (${_d#,  })" <<< "${@:$#}"   # expands to: "del(.xxx, .yyy, ...)"
}
# set -x ; cDeleteJsonKey 'time' 'mic' '{"time" : "2022-10-18 16:57:47", "protocol" : 19, "model" : "Nexus-TH", "id" : 240, "channel" : 1, "battery_ok" : 1, "temperature_C" : 21.600, "humidity" : 20}' ; exit 1
# set -x ; cDeleteJsonKey "one" "two" ".four five six" "*_special*" '{"one":"1", "two":2  ,"three":3,"four":"4", "five":5, "_special":"*?+","_special2":"aa*?+bb"}'  ;  exit 1
# results in: {"three":3,"_special2":"aa*?+bb"}

cHasJsonKey() {
    local - && set +x
    _d="${2:-$data}"
    [ "${_d//\"$1\":}" != "$_d" -o "${_d//\"$1\"[ ]*:}" != "$_d" ]
}
# j='{"action":"null","battery":100}' ; cHasJsonKey action "$j" && echo yes ; cHasJsonKey jessy "$j" && echo no ; exit
# j='{"dipswitch":"++---o--+","rbutton":"11R"}' ; cHasJsonKey dipswitch "$j" && echo yes ; cHasJsonKey jessy "$j" && echo no ; exit

cExtractJsonVal() {
    local - # && set +x
    cHasJsonKey "$1" && jq -r ".$1 // empty" <<< "${2:-$data}"
}
# j='{"action":"null","battery":100}' ; cExtractJsonVal action "$j" ; exit

cAssureJsonVal() {   # cAssureJsonVal "battery" ">9" '{"action":"null","battery":100}'
    cHasJsonKey "$1" &&  jq -e -r "if (.$1 ${2:+and .$1 $2} ) then "1" else empty end" <<< "${3:-$data}"
}
# data='{"action":"null","battery":100}' ; cAssureJsonVal battery ">999" ; cAssureJsonVal battery ">9" ;  exit

[ -r "$rtl2mqtt_optfile" ] && _moreopts="$( grep -v '#' < "$rtl2mqtt_optfile" | tr -c -d '[:alnum:]_. -' )" && dbg "Read _moreoptrs from $rtl2mqtt_optfile"
cLogMore "all options: $* $_moreopts"

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
    S)  rtl433_opts=( "${rtl433_opts[@]}" -S "$OPTARG" ) # pass signal autosave option to rtl_433
        # sSensorMatch="${OPTARG}.*"   # this was the previous meaning of -k
        ;;
    d)  bRemoveAnnouncements="yes" # delete (remove) all retained MQTT auto-discovery announcements (before starting), needs a newer mosquitto_sub
        ;;
    r)  # rewrite and simplify output
        if [ "$bRewrite" ] ; then
            bRewriteMore="yes" && dbg "Rewriting even more ..."
        fi
        bRewrite="yes"  # rewrite and simplify output
        ;;
    l)  dLog="$OPTARG" 
        ;;
    f)  fReplayfile="$OPTARG" # file to replay (e.g. for debugging), instead of rtl_433 output
        ;;
    w)  sRoundTo="${OPTARG}" # round temperature to this value and humidity to 5-times this value
        ;;
    F)  if [ "$OPTARG" = "868" ] ; then
            rtl433_opts=( "${rtl433_opts[@]}" -f 868.3M -s $sSuggSampleRate -Y minmax ) # last tried: -Y minmax, also -Y autolevel -Y squelch   ,  frequency 868... MhZ - -s 1024k
        elif [ "$OPTARG" = "915" ] ; then
            rtl433_opts=( "${rtl433_opts[@]}" -f 915M -s $sSuggSampleRate -Y minmax ) 
        elif [ "$OPTARG" = "27" ] ; then
            rtl433_opts=( "${rtl433_opts[@]}" -f 27.161M -s $sSuggSampleRate -Y minmax ) 
        elif [ "$OPTARG" = "433" ] ; then
            rtl433_opts=( "${rtl433_opts[@]}" -f 433.91M ) #  -s 256k -f 433.92M for frequency 433... MhZ
        else
            rtl433_opts=( "${rtl433_opts[@]}" -f "$OPTARG" )
        fi
        basetopic="$sRtlPrefix/$OPTARG"
        nHopSecs=${nHopSecs:-61} # ${nHopSecs:-61} # (60/2)+11 or 60+1 or 60+21 or 7, i.e. should be a coprime to 60sec
        nStatsSec=$(( 5 * (nHopSecs - 1) ))
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

# fixed in rtl_433 8e343ed: the real hop secs seam to be 1 higher than the value passed to -H...
rtl433_opts=( "${rtl433_opts[@]}" ${nHopSecs:+-H $nHopSecs} ${nStatsSec:+-M stats:1:$nStatsSec} )
# echo "${rtl433_opts[@]}" && exit 1

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

[ "$( command -v jq )" ] || { log "$sName: jq must be available!" ; exit 1 ; }

if [[ $fReplayfile ]]; then
    sBand=999
else
    _startup="$( $rtl433_command "${rtl433_opts[@]}" -T 1 2>&1 )"
    # echo "$_startup" ; exit
    sdr_tuner="$(  awk -- '/^Found /   { print gensub("Found ", "",1, gensub(" tuner$", "",1,$0)) ; exit }' <<< "$_startup" )" # matches "Found Fitipower FC0013 tuner"
    sdr_freq="$(   awk -- '/^Tuned to/ { print gensub("MHz.", "",1,$3)                            ; exit }' <<< "$_startup" )" # matches "Tuned to 433.900MHz."
    conf_files="$( awk -F \" -- '/^Trying conf/ { print $2 }' <<< "$_startup" | xargs ls -1 2>/dev/null )" # try to find an existing config file
    sBand="${sdr_freq/%.*/}" # reduces val to "433" ... 
fi
basetopic="$sRtlPrefix/$sBand" # derives intial setting for basetopic

# Enumerate the supported protocols and their names, put them into an array
_protos="$( $rtl433_command -R 99999 2>&1 | awk '$1 ~ /\[[0-9]+\]/ { p=$1 ; printf "%d" , gensub("[\\]\\[\\*]","","g",$1)  ; $1="" ; print $0}' )" # ; exit
declare -A aNames ; while read -r p name ; do aNames["$p"]="$name" ; done <<< "$_protos"

cEchoIfNotDuplicate() {
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

_info="*tuner*:*$sdr_tuner*,*freq*:$sdr_freq,*additional_rtl433_opts*:*${rtl433_opts[@]}*,*logto*:*$dLog ($sDoLog)*,*rewrite*:*${bRewrite:-no}${bRewriteMore}*,*nMinOccurences*:$nMinOccurences,*nMinSecondsTempSensor*:$nMinSecondsTempSensor,*nMinSecondsOther*:$nMinSecondsOther,*sRoundTo*:$sRoundTo"
if [ -t 1 ] ; then # probably on a terminal
    log "$sName starting at $(cDate)"
    cMqttStarred log "{*event*:*starting*,$_info}"
else               # probably non-terminal
    delayedStartSecs=3
    log "$sName starting in $delayedStartSecs secs from $(cDate)"
    sleep "$delayedStartSecs"
    cMqttStarred log "{*event*:*starting*,$_info,*note*:*delayed by $delayedStartSecs secs*,*sw_version*=*$rtl433_version*,*user*:*$( id -nu )*,*cmdargs*:*$commandArgs*}"
fi

# Optionally remove any matching retained announcements
[[ $bRemoveAnnouncements ]] && cHassRemoveAnnounce

trap_exit() {   # stuff to do when exiting
    local - && set +x
    log "$sName exit trapped at $(cDate): removing announcements, then logging state."
    [ "$bRemoveAnnouncements" ] && cHassRemoveAnnounce
    _cppid="$rtlcoproc_PID" # avoid race condition after killing coproc
    [ "$rtlcoproc_PID" ] && kill "$rtlcoproc_PID" && dbg "Killed coproc PID $_cppid"
    # sleep 1
    nReadings=${#aLastReadings[@]}
    cMqttState "*collected_sensors*:*${!aLastReadings[*]}*"
    cMqttStarred log "{*event*:*exiting*,*note*:*exiting*}"
    # rm -f "$conf_file" # remove a created pseudo-conf file if any
 }
trap 'trap_exit' EXIT # previously also: INT QUIT TERM 

trap_int() {    # log all collected sensors to MQTT
    trap '' INT 
    log "$sName received signal INT: logging state to MQTT"
    cMqttStarred log "{*note*:*received signal INT*,$_info}"
    cMqttStarred log "{*note*:*received signal INT, will publish collected sensors* }"
    cMqttState "*collected_sensors*:*${!aLastReadings[*]}* }"
    nLastStatusSeconds="$(cDate %s)"
 }
trap 'trap_int' INT 

trap_usr1() {    # toggle verbosity 
    [ "$bVerbose" ] && bVerbose="" || bVerbose="yes"
    _msg="received signal USR1: toggled verbosity to ${bVerbose:-no}, nHopSecs=$nHopSecs, current sBand=$sBand"
    log "$sName $_msg"
    cMqttStarred log "{*note*:*$_msg*}"
  }
trap 'trap_usr1' USR1 

trap_usr2() {    # remove all home assistant announcements 
    log "$sName received signal USR2: removing all home assistant announcements"
    cHassRemoveAnnounce
  }
trap 'trap_usr2' USR2 

trap_other() {
    _msg="received other signal ..."
    log "$sName $_msg"
    cMqttStarred log "{*note*:*$_msg*}"
  }
trap 'trap_other' URG XCPU XFSZ VTALRM PROF WINCH PWR SYS

if [[ $fReplayfile ]] ; then
    coproc rtlcoproc ( while read -r l ; do echo "$l"; sleep 1 ; done < "$fReplayfile" ; sleep 1 )
else
    if [[ $bVerbose || -t 1 ]] ; then
        cLogMore "options for rtl_433 are: ${rtl433_opts[@]}"
        (( nMinOccurences > 1 )) && cLogMore "Will do MQTT announcements only after at least $nMinOccurences occurences..."
    fi 
    # Start the RTL433 listener as a bash coprocess .... # https://unix.stackexchange.com/questions/459367/using-shell-variables-for-command-options
    coproc rtlcoproc ( $rtl433_command ${conf_file:+-c $conf_file} "${rtl433_opts[@]}" -F json  2>&1  )   # options are not double-quoted on purpose 
    # -F "mqtt://$mqtthost:1883,events,devices"
    renice -n 17 "${rtlcoproc_PID}"

    if [[ $rtlcoproc_PID && $bAnnounceHass ]] ; then
        # _statistics="*sensorcount*:*${nReadings:-0}*,*announcedcount*:*$nAnnouncedCount*,*mqttlinecount*:*$nMqttLines*,*receivedcount*:*$nReceivedCount*,*readingscount*:*$nReadings*"
        ## cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "TestVal" "value_json.mcheck" "mcheck"
        cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "AnnouncedCount" "value_json.announceds" "counter"
        cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "SensorCount"   "value_json.sensors"  "counter"
        cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "MqttLineCount" "value_json.mqttlines" "counter"
        cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "ReadingsCount" "value_json.receiveds" "counter"  
        cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "Start date" "value_json.startdate" "clock"
        cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/log   "LogMessage"     ""           "none" && sleep 1
    fi
fi 

while read -r data <&"${rtlcoproc[0]}" ; _rc=$? && (( _rc==0  || _rc==27 ))      # ... and enter the loop
do
    _beginpid=$(cPid) # support counting/debugging/optimizing number of processes started in within the loop
    # dbg "diffpid=$(awk "BEGIN {print ( $(cPid) - $_beginpid - 3) }" )" 

    if [ "${data#rtlsdr_set_center_freq}" != "$data" ] ; then 
        # convert msg "rtlsdr_set_center_freq 868300000 = 0" to "{"center_frequency":868300000}" (JSON) and process further down
        data="$( awk '{ printf "{\"center_frequency\":%d,\"BAND\":%d}" , $2 , int(($2/1000000+1)/2)*2-1  }' <<< "$data" )"   #  printf "%.0f\n"
    elif [ "${data#{}" = "$data" ] ; then # possibly eliminating any non-JSON line (= JSON line starting with "{"), e.g. from rtl_433 debugging/error output
        data=${data#\*\*\* } # Remove any leading "*** "
        if [ "${data#Please increase your allowed usbfs buffer size}" != "$data" ] ; then # "Please increase your allowed usbfs buffer ...."
            cMqttStarred log "{*event*:*warning*,*note*:*${data//\*/+}*}" # convert to simple JSON msg
        elif [ "${data#Allocating }" = "$data" ] ; then # "Allocating 15 zero-copy buffers"
            [[ $bVerbose ]] && cMqttStarred log "{*note*:*${data//\*/+}*}" # convert it to a simple JSON msg
        fi
        log "Non-JSON: $data"
        # data='""'
        continue
    fi
    if [[ $data =~ "center_frequency" ]] ; then
        data="${data//\" : /\":}" # beautify a bit, removing space(s)
        sBand="$( jq -r '.center_frequency / 1000000 | floor  // empty' <<< "$data" )"
        basetopic="$sRtlPrefix/$sBand"
        [[ $bVerbose ]] && cEchoIfNotDuplicate "CENTER: $data" && cMqttStarred log "${data//\"/*}"
        nLastCenterMessage="$(cDate)" # prepare for avoiding race condition after freq hop (not implemented yet)
        continue
    fi
    dbg "RAW: $data"
    nReceivedCount=$(( nReceivedCount + 1 ))
    
    _time="$(cExtractJsonVal time)"  # ;  msgTime="2021-11-01 03:05:07"
    declare +i _str # to avoid octal interpretation from leading zeroes
    _str="${_time:(-8):2}" ; msgHour="${_str#0}" 
    _str="${_time:(-5):2}" ; msgMinute="${_str#0}" 
    _str="${_time:(-2):2}" ; msgSecond="${_str#0}"
    # data="$( cDeleteJsonKey "time $sSuppressAttrs" "$data"  )" # delete attributes and remove double-quotes around numbers
    # dbg ONE "$data"
    data="$( cDeleteJsonKey "time $sSuppressAttrs" "$data" | sed -e 's/:"\([0-9.-]*\)"/:\1/g'  )" # delete attributes and remove double-quotes around numbers
    [[ $bMoreVerbose ]] && cEchoIfNotDuplicate "READ: $data"
    protocol="$(cExtractJsonVal protocol)"
    channel="$( cExtractJsonVal channel)"
    model="$(   cExtractJsonVal model)"    
    id="$(      cExtractJsonVal id)"
    rssi="$(    cExtractJsonVal rssi)"
    [[ $model && ! $id ]] && id="$( cExtractJsonVal address)" # address might be unique alternative to id, still to TEST ! (FIXME)
    cHasJsonKey freq && sBand="$(cExtractJsonVal freq)" && sBand=${sBand%.[0-9]*} && sBand=${sBand/434/433} && basetopic="$sRtlPrefix/$sBand"
    ident="${channel:-$id}" # prefer the channel over the id as the unique identifier, if present
    model_ident="${model}${ident:+_$ident}"

    log "$(cAppendJsonKeyVal BAND "${model:+$sBand}")" # only append band when model is given, i.e. not for non-sensor messages.
    [[ $bVerbose ]] || expr "$model_ident" : "$sSensorMatch.*" > /dev/null || continue # skip unwanted readings (regexp) early (if not verbose)

    if [[ $model_ident && $bRewrite ]] ; then                  # Rewrite and clean the line from less interesting information....
        # sample: {"id":20,"channel": 1,"battery_ok": 1,"temperature":18,"humidity":55,"mod":"ASK","freq":433.931,"rssi":-0.261,"snr":24.03,"noise":-24.291}

        _temp="$( cHasJsonKey temperature_C && jq -e -r "if .temperature_C then .temperature_C / $sRoundTo + 0.5 | floor * $sRoundTo else empty end" <<< "$data" )" # round to 0.5° C
        if [[ $_temp ]] ; then
            _bHasTemperature=1
            data="$( jq -cer ".temperature_C = $_temp" <<< "$data" )" # set to rounded temperature
            [[ ${aPrevTempVals[$model_ident]} ]] || aPrevTempVals[$model_ident]=0
        else 
            _bHasTemperature=""
        fi
        _delkeys="model mod rssi snr noise"
        [[ -z $_temp || ${_temp/.*} -lt 50 ]] && _delkeys="$_delkeys protocol"
        data="$( cDeleteJsonKey "$_delkeys" "$data" )" # other stuff: id rssi subtype channel mod snr noise
        _temp="$( cHasJsonKey humidity && jq -e -r "if .humidity and .humidity<=100 then .humidity / ( $sRoundTo * 2 + 1 ) + 0.5 | floor * ( $sRoundTo * 2 + 1 ) | floor else empty end" <<< "$data" )" # round to 2,5%

        if [[ $_temp ]] ; then
            _bHasHumidity=1
            data="$( jq -cer ".humidity = $_temp" <<< "$data" )"
         else 
            _bHasHumidity=""
        fi
        # _bHasHumidity="$( cAssureJsonVal humidity "<=100")"
        _bHasRain="$( cAssureJsonVal rain_mm ">0")"
        _bHasBatteryOK="$( cAssureJsonVal battery_ok "<=2")"
        _bHasPressureKPa="$(cAssureJsonVal pressure_kPa "<=9999" )"
        _bHasZone="$(cHasJsonKey zone && echo 1 )" #        {"id":256,"control":"Limit (0)","channel":0,"zone":1,"freq":434.024}
        _bHasChannel="$(cHasJsonKey channel && echo 1 )" #        {"id":256,"control":"Limit (0)","channel":0,"zone":1,"freq":434.024}
        _bHasControl="$(cHasJsonKey control && echo 1 )" #        {"id":256,"control":"Limit (0)","channel":0,"zone":1,"freq":434.024}
        _bHasCmd="$(cHasJsonKey cmd && echo 1 )"
        _bHasCounter="$(cHasJsonKey counter && echo 1 )" #                  {"counter":432661,"code":"800210003e915ce000000000000000000000000000069a150fa0d0dd"}
        _bHasCode="$(   cHasJsonKey code && echo 1 )" #                  {"counter":432661,"code":"800210003e915ce000000000000000000000000000069a150fa0d0dd"}
        _bHasButtonR="$(cHasJsonKey rbutton && echo 1 )" #  rtl/433/Cardin-S466/00 {"dipswitch":"++---o--+","rbutton":"11R"}
        _bHasDipSwitch="$(cHasJsonKey dipswitch && echo 1 )" #  rtl/433/Cardin-S466/00 {"dipswitch":"++---o--+","rbutton":"11R"}
        _bHasNewBattery="$( cHasJsonKey newbattery && echo 1 )" #  {"id":13,"battery_ok":1,"newbattery":0,"temperature_C":24,"humidity":42}

        if [[ $bRewriteMore ]] ; then
            data="$( cDeleteJsonKey ".transmit test" "$data" )"
            data="$( cHasJsonKey button &&  jq -c 'if .button     == 0 then del(.button) else . end' <<< "$data" || echo "$data" )"
            # data="$( cHasJsonKey battery_ok "$data"  &&   jq -c 'if .battery_ok == 1 then del(.battery_ok) else . end' <<< "$data" || echo "$data" )"
            data="$( cHasJsonKey unknown1 &&   jq -c 'if .unknown1   == 0 then del(.unknown1)   else . end' <<< "$data" || echo "$data" )"

            bSkipLine="$( jq -e -r 'if (.humidity and .humidity>100) or (.temperature_C and .temperature_C<-50) or (.temperature and .temperature<-50) then "yes" else empty end' <<<"$data"  )"
        fi
        [[ $sDoLog == "dir" && $model ]] && echo "$(cDate %d %H:%M:%s) $data" >> "$dLog/model/$model_ident"
        data="$( sed -e 's/"temperature_C":/"temperature":/' -e 's/":([0-9.-]+)/":"\&"/g'  <<< "$data" )" # hack to cut off "_C" and to add double-quotes not using jq
        # data="$( cDeleteJsonKey "freq2" "$data" )" # the frequency always changes a little, will distort elimination of duplicates, and is contained in MQTT topic anyway.
        cHasJsonKey freq &&  data="$( jq -cer '.freq=(.freq|floor)' <<< "$data" )" # the frequency always changes a little, will distort elimination of duplicates, and is contained in MQTT topic anyway.
        _factor=1
        cHasJsonKey freq1 &&  data="$( jq -cer ".freq1=(.freq1 * $_factor + 0.5 | floor / $_factor)" <<< "$data" )" # round the frequency freq1
        cHasJsonKey freq2 &&  data="$( jq -cer ".freq2=(.freq2 * $_factor + 0.5 | floor / $_factor)" <<< "$data" )" # round the frequency freq2
        data="$(cAppendJsonKeyVal BAND "$sBand")"
    fi

    nTimeStamp="$(cDate %s)"
    # Send message to MQTT or skip it ...
    if [[ $bSkipLine ]] ; then
        dbg "SKIPPING: $data"
        bSkipLine=""
        continue

    elif [ -z "$model_ident" ] ; then # stats message
        dbg "DEBUG: model_ident is empty"
        [[ $bVerbose ]] && cEchoIfNotDuplicate "STATS: $data" && cMqttStarred stats "${data//\"/*}" # ... publish stats values (from "-M stats" option)

    elif [[ $bAlways || ${data/"freq":434/} != "${prev_data/"freq":434/}" || $nTimeStamp -gt $((prev_time+nMinSecondsOther)) ]] ; then
        # ignore freq changes within the 433/434 range when comparing for a change....
        if [[ $bVerbose ]] ; then
            [[ $bRewrite ]] && cEchoIfNotDuplicate "" "CLEANED: $model_ident = $data" # resulting message for MQTT
            expr match "$model_ident" "$sSensorMatch.*"  > /dev/null || continue # skip if match
        fi
        prev_data="$data"
        prev_time="$nTimeStamp"
        prevval="${aLastReadings[$model_ident]}"
        prevvals="${aSecondLastReadings[$model_ident]}"
        aLastReadings[$model_ident]="$data"
        aCounts[$model_ident]="$(( aCounts[$model_ident] + 1 ))"
        # aProtocols[${protocol}]="$model"
        if [[ $bMoreVerbose && ! $bQuiet ]] ; then
            _prefix="SAME:  "  &&  [[ ${aLastReadings[$model_ident]} != "$prevval" ]] && _prefix="CHANGE(${#aLastReadings[@]}):"
            grep -E --color=auto '^[^/]*|/' <<< "$_prefix $model_ident /${aLastReadings[$model_ident]}/$prevval/"
        fi
        _nTimeDiff=$(( (_bHasTemperature || _bHasHumidity) && (nMinSecondsTempSensor>nMinSecondsOther) ? nMinSecondsTempSensor : nMinSecondsOther  ))
        [[ $data == "$prevval" && ! $bMoreVerbose ]] && _nTimeDiff=$(( _nTimeDiff * 2 )) # delay outputting further if values are the same as last time
        _bAnnounceReady=$(( bAnnounceHass && aAnnounced[$model_ident]!=1 && aCounts[$model_ident] >= nMinOccurences ))

        if [[ $bVerbose ]] ; then
            echo "_nTimeDiff=$_nTimeDiff, _bAnnounceReady=$_bAnnounceReady, hasTemperature=$_bHasTemperature, hasHumidity=$_bHasHumidity, hasCmd=$_bHasCmd, hasButtonR=$_bHasButtonR, hasDipSwitch=$_bHasDipSwitch, hasNewBattery=$_bHasNewBattery, hasControl=$_bHasControl"
            # (( nTimeStamp > nLastStatusSeconds+nLogMinutesPeriod*60 || (nMqttLines % nLogMessagesPeriod)==0 ))
            echo "model_ident=$model_ident, Readings=${aLastReadings[$model_ident]}, Counts=${aCounts[$model_ident]}, Prev=$prevval, Prev2=$prevvals, Time=$nTimeStamp-${aLastSents[$model_ident]}=$(( nTimeStamp - aLastSents[$model_ident] ))"
        fi
        if (( _bAnnounceReady )) ; then
            # For now, only the following certain types of sensors are announced for auto-discovery:
            if (( _bHasTemperature || _bHasPressureKPa || _bHasCmd || _bHasButtonR || _bHasDipSwitch || _bHasCounter || _bHasControl )) ; then
                _name="${aNames[$protocol]}" 
                _name="${_name:-$model}" # fallback
                # if the sensor has one of the above attributes, announce all other attributes...:
                (( _bHasTemperature )) && cHassAnnounce "$basetopic" "$model ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Temp"      "value_json.temperature"   temperature
                (( _bHasHumidity    )) && cHassAnnounce "$basetopic" "$model ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Humid"     "value_json.humidity"  humidity
                (( _bHasPressureKPa )) && cHassAnnounce "$basetopic" "$model ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }PressureKPa"  "value_json.pressure_kPa" pressure_kPa
                (( _bHasBatteryOK   )) && cHassAnnounce "$basetopic" "$model ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Battery"   "value_json.battery_ok"    battery_ok
                (( _bHasCmd         )) && cHassAnnounce "$basetopic" "$model ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Cmd"       "value_json.cmd"   motion
                (( _bHasCounter     )) && cHassAnnounce "$basetopic" "$model ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Counter"   "value_json.counter"   counter
                (( _bHasCode        )) && cHassAnnounce "$basetopic" "$model ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Code"       "value_json.code"     lock
                (( _bHasButtonR     )) && cHassAnnounce "$basetopic" "$model ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }ButtonR"    "value_json.buttonr"  button
                (( _bHasDipSwitch   )) && cHassAnnounce "$basetopic" "$model ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }DipSwitch"  "value_json.dipswitch" dipswitch
                (( _bHasNewBattery  )) && cHassAnnounce "$basetopic" "$model ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }NewBatttery"  "value_json.newbattery" newbattery
                (( _bHasZone        )) && cHassAnnounce "$basetopic" "$model ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Zone"       "value_json.zone"     zone
                (( _bHasChannel     )) && cHassAnnounce "$basetopic" "$model ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Channel"    "value_json.channel"  channel
                (( _bHasControl     )) && cHassAnnounce "$basetopic" "$model ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Control"    "value_json.control"  control
                #   [ "$sBand"      ]  && cHassAnnounce "$basetopic" "$model ${sBand}Mhz" "${model:+$model/}${ident:-00}" "${ident:+($ident) }Freq"     "value_json.FREQ" frequency
                cMqttStarred log "{*note*:*announced MQTT discovery: $model_ident ($_name)*}"
                nAnnouncedCount=$(( nAnnouncedCount + 1 ))
                cMqttState
                sleep 1 # give readers a second to digest the announcement first
            else
                cMqttStarred log "{*note*:*not announced for MQTT discovery: $model_ident*}"
            fi
            aAnnounced[$model_ident]=1 # 1 = took place ()= dont reconsider for announcement)
        fi
        if [[ $data != "$prevval" || $nTimeStamp -gt $(( aLastSents[$model_ident] + _nTimeDiff )) || "$_bAnnounceReady" -eq 1 || $fReplayfile ]] ; then # rcvd data should be different from previous reading(s) but not if coming from replayfile
            aLastReadings[$model_ident]="$data"
            if [[ $bRewrite ]] ; then   #  && ( $_bHasTemperature || $_bHasHumidity ) 
                data="$(cAppendJsonKeyVal rssi "$rssi")" # put rssi back in
                if [[ $data != "$prevval" ]] ; then
                    data="$( jq -cer '.NOTE = "changed"' <<< "$data" )"
                elif [[ $data == "$prevvals" ]] ; then
                    [[ $bVerbose ]] && data="$( jq -cer ".NOTE2 = \"=2nd (#${aCounts[$model_ident]},_bR=$_bAnnounceReady,${_nTimeDiff}s)\"" <<< "$data" )"
                fi
                aSecondLastReadings[$model_ident]="$prevval"
            fi
            cMqttStarred "$basetopic/${model:+$model/}${ident:-00}" "${data//\"/*}" # ... publish the values!
            nMqttLines=$(( nMqttLines + 1 ))
            aLastSents[$model_ident]="$nTimeStamp"
        else
            dbg "Suppressed a duplicate." 
        fi
        set +x
    fi
    nReadings=${#aLastReadings[@]} # && nReadings=${nReadings#0} # remove any leading 0

    if (( nReadings > nPrevMax )) ; then   # a new max implies we have a new sensor
        nPrevMax=nReadings
        _sensors="${_bHasTemperature:+*temperature*,}${_bHasHumidity:+*humidity*,}${_bHasPressureKPa:+*pressure_kPa*,}${_bHasBatteryOK:+*battery*,}${_bHasRain:+*rain*,}"
        cMqttStarred log "{*note*:*sensor added*,*model*:*$model*,*id*:$id,*channel*:*$channel*,*desc*:*${aNames[$protocol]}*,*protocol*:*$protocol*, *sensors*:[${_sensors%,}]}"
        cMqttState
    elif (( nTimeStamp > nLastStatusSeconds+nLogMinutesPeriod*60 || (nMqttLines % nLogMessagesPeriod)==0 )) ; then   
        # log once in a while, good heuristic in a generalized neighbourhood
        _collection="*sensorreadings*:[$(  _comma=""
            for KEY in "${!aLastReadings[@]}"; do
                _reading="${aLastReadings[$KEY]}" && _reading="${_reading/{/}" && _reading="${_reading/\}/}"
                echo -n "$_comma {*model_ident*:*$KEY*,${_reading//\"/*}}"
                _comma=","
            done
        )] "
        log "$( cExpandStarredString "$_collection")" 
        cMqttState "*note*:*regular log*,*collected_model_ids*:*${!aLastReadings[*]}*, $_collection"
        nLastStatusSeconds=$nTimeStamp
    elif (( nReadings > (msgSecond*msgSecond+2)*(msgMinute+1)*(msgHour+1) || nMqttLines%5000==0 || nReceivedCount % 10000 == 0 )) ; then # reset whole array to empty once in a while = starting over
        cMqttState
        cMqttStarred log "{*note*:*will reset saved values (nReadings=$nReadings,nMqttLines=$nMqttLines,nReceivedCount=$nReceivedCount)*}"
        unset aLastReadings && declare -A aLastReadings # reset the whole collection (array)
        unset aCounts   && declare -A aCounts
        unset aAnnounced && declare -A aAnnounced
        nPrevMax=$(( nPrevMax / 3 ))            # reduce it quite a bit (but not back to 0) to reduce future log messages
        [[ $bRemoveAnnouncements ]] && cHassRemoveAnnounce
    fi
done

s=1 && [ ! -t 1 ] && s=30 # sleep a longer time if not on a terminal
_msg="$sName: read failed (rc=$_rc), while-loop ended $(printf "%()T"), rtlprocid now :${rtlcoproc_PID}:, last data=$data, sleep=${s}s"
log "$_msg" 
cMqttStarred log "{*event*:*endloop*,*note*:*$_msg*}"
sleep $s
exit 1
# now the exit trap function will be processed...