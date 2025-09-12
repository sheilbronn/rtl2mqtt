#!/bin/bash
# shellcheck shell=bash

# rtl2mqtt reads events from a RTL433 SDR and forwards them to a MQTT broker as enhanced JSON messages 

# Adapted and enhanced for conciseness, verboseness and flexibility by "sheilbronn"
# (inspired originally by work from "IT-Berater" and M. Verleun)

set -o noglob     # file name globbing is neither needed nor wanted (for security reasons)
set -o noclobber  # also disable for security reasons
# shopt -s lastpipe  # Enable lastpipe
shopt -s assoc_expand_once # might lessen injection risks in bash 5.2+, FIXME: to be verified on bash 5.2
shopt -s expand_aliases # expand aliases in non-interactice shells, too
busybox awk '{}' 1</dev/null 2>/dev/null && alias awk="busybox awk" # busybox awk is more efficient than other awk's (if available)
e1()  { echo 1 ; }

# When extending this script: keep in mind possible attacks from the RF enviroment, e.g. a denial of service :
# a) DoS: Many signals per second > should fail graciously by not beeing able to process them all
# b) DoS: Many (fake) sensors introduced (protocols * possible IDs) > arrays will become huge || inboxes for HASS announcements overflows
#    Simple fix: After 9999 HASS announcements recall all HASS announcements (FIXME), reset all arrays (FIXME'd for all arrays)
# c) exploits for possible rtl_433 decoding errors, transmit out of band values: test all read values for boundary conditions and syntax (e.g. number)

# exit codes: 1,2=installation/configuration errors; 3=.. ; 127=install errors; ; 99=DoS attack from radio environment or rtl_433 bug

alias cX="local - && set +x" # stop any verbosity locally
[[ $1 == "-x" ]] && alias cX='local - && set +x && echo == ${1:+1=$1}${2:+ 2=$2} === 1>&2' # used when debugging
alias sX="set -x"
alias GREPC="grep -E --color=auto"
alias ifVerbose="(( bVerbose ))"
sName=${0##*/} && sName=${sName%.sh}
sMID=$(basename "${sName// }" .sh )
sID=$sMID
rtl2mqtt_optfile="$([ -r "${XDG_CONFIG_HOME:=$HOME/.config}/$sName" ] && echo "$XDG_CONFIG_HOME/$sName" || echo "$HOME/.$sName" )" # ~/.config/rtl2mqtt or ~/.rtl2mqtt
cDate() { cX ; a=$1 ; shift ; printf "%($a)T" "$@"; } # avoid a separate process to get the date

commandArgs=$*
dLog="/var/log/$sMID" # /var/log/rtl2mqtt is default, but will be changed to /tmp if not useable
aSignalsOther=( URG XCPU XFSZ PROF WINCH PWR SYS USR1 ) # signals that will be logged, but ignored or treated
sManufacturer="RTL"
sHassPrefix="homeassistant"
sRtlPrefix="rtl"                        # base topic
sDateFormat="%Y-%m-%d %H:%M:%S" # format needed for OpenHab 3 Date_Time MQTT items - for others OK, too? - as opposed to ISO8601
sDateFormat="%Y-%m-%dT%H:%M:%S" # FIXME: test with T for OpenHAB 4
sStartDate=$(cDate "$sDateFormat") # start date of the script
sHostname=$(hostname)
basetopic=""                  # default MQTT topic prefix
rtl433_command="rtl_433"
rtl433_command=$(command -v $rtl433_command) || { echo "$sName: $rtl433_command not found..." 1>&2 ; exit 126 ; }
rtl433_version=$($rtl433_command -V 2>&1 | awk -- '$2 ~ /version/ { print $3 ; exit }' ) || exit 126
declare -a rtl433_opts=( -M protocol -M noise:900 -M level -C si )  # generic options in all settings, e.g. -M level 
# rtl433_opts+=( $([ -r "$HOME/.$sName" ] && tr -c -d '[:alnum:]_. -' < "$HOME/.$sName" ) ) # FIXME: protect from expansion!
sSuppressAttrs="mic" # attributes that will be always eliminated from JSON msg
sSensorMatch=".*" # any sensor name to be considered will have to match this regex (to be used during debugging)
sRoundTo=0.5 # temperatures will be rounded to this x and humidity to 4*x (but see option -w below)
sWuBaseUrl="https://weatherstation.wunderground.com/weatherstation/updateweatherstation.php" # This is stable for years
sWhatsappBaseUrl="https://api.callmebot.com/whatsapp.php" # This is stable for years
sJsonNumPattern='^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$' # regex pattern for a JSON number

# xx=( one "*.log" ) && xx=( "${printf "%($*)T"nlaxx[@]}" ten )  ; for x in "${xx[@]}"  ; do echo "$x" ; done  ;  exit 2

# color definitions derived from from https://askubuntu.com/questions/1042234/modifying-the-color-of-grep :
grey="mt=01;30"; red="mt=01;31"; green="mt=01;32"; yellow="mt=01;33"; iyellow="mt=01;93" ; 
blue="mt=01;34" ; purple="mt=01;35" ; cyan="mt=01;36" ; white="mt=01;37"

declare -i nHopSecs
declare -i nStatsSec=900
declare    sSuggSampleRate=250k # default for rtl_433 is 250k
# declare    sSuggSampleRate=1000k # default for rtl_433 is 250k, FIXME: check 1000k seems to be necessary for 868 MHz....
# declare    sSuggSampleRate=1500k # default for rtl_433 is 250k, FIXME: check 1000k seems to be necessary for 868 MHz....
declare    sSuggSampleModel=auto # -Y auto|classic|minmax
declare -i nLogMinutesPeriod=20 # about every NN minutes (after an reception): log the current status
declare -i nLogMessagesPeriod=1000
declare -i nLastStatusSeconds=90
# if no radio event has been received for more than x hours (x*3600 seconds), then restart
declare -i nSecondsBeforeRestart=$(( 2 * 3600 ))
declare -i nMinSecondsOther=5 # only at least every nn seconds, reducing flicker such as from motion sensors....
declare -i nMinSecondsWeather=$(( 90 + 4 * 60  )) # only at least every 50+n*60 seconds for unchanged weather data (temperature, humidity)
declare -i nTimeStamp=$(cDate %s)-$nLogMessagesPeriod # initialize it with a large, sensible assumption....
declare -i nTimeStampPrev
declare -i nTimeMinDelta=300
declare -i nPidDelta
declare -i nHour=0
declare -i nMinute=0
declare -i nSecond=0
declare -i nMqttLines=0     
declare -i nReceivedCount=0
declare -i nSuppressedCount=0
declare -i nAnnouncedCount=0
declare -i nLastUnannouncedCheck=$(cDate %s) # time stamp of last unannounced check
declare    bPlannedTermination=""
declare    sLastAnnounced
declare -i nMinOccurences=3
declare -i nTemperature10=999
declare -i nHumidity=999
declare -i nPrevMax=1       # start with 1 for non-triviality
declare -i nReadings=0
declare -i nUploads=0 # number of uploads to Wunderground
declare -i nRC
declare -i nLoops=0
declare -l bAnnounceHass=1 # default is yes for now
declare -i bRetained="" # make the value publishing retained or not (-r flag passed to mosquitto_pub)
declare -i bLogTempHumidity=0 # 1=log the values 
declare -i _n # helper integer var
declare -A aWuUrls
declare -Ai aWuLastUploadTime
# declare -A aWhUrls
declare -A aWuPos
declare -A aMatchIDs # sensor ID that has to match before upload considered
declare -A aDewpointsCalc
declare -a hMqtt
declare -a aExcludes

declare -A  aPrevReadings # approx. 11 arrays
declare -A  aSecondPrevReadings 
declare -Ai aCounts
declare -Ai aBands
declare -Ai aAnnounced
declare -A  aEarlierTemperVals10 
declare -Ai aEarlierTemperTime 
declare -Ai aEarlierHumidVals 
declare -Ai aEarlierHumidTime
declare -Ai aLastPub
declare -Ai aLastReceivedTime # time stamp of last reception
declare -Ai aPrevReceivedTime # time stamp of second last reception
declare -A  aPrevId # distinguish between different sensors with different IDs on the same channel
declare -Ai aSensorToAddIds # add a sensor to the list of sensors where ids are to be added to the MQTT topics
declare -Ai aSensorWithoutIdToo # 

cEmptyArrays() { # reset the 11 arrays from above
    aPrevReadings=()
    aSecondPrevReadings=()
    aCounts=()
    aBands=()
    aAnnounced=()
    nAnnouncedCount=0
    aEarlierTemperVals10=()
    aEarlierTemperTime=()
    aEarlierHumidVals=()
    aEarlierHumidTime=()
    aLastPub=()
    aLastReceivedTime=()
    aPrevReceivedTime=()
    aPrevId=()
    aWuLastUploadTime=()
    }

export LANG=C
PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin" # increases security

cJoin() { # join all arguments with a space, but remove any double spaces and any newlines
    cX
    local _r _val
    for _val in "$@" ; do
        _r="${_r//  / }${_r:+ }${_val//
/ }"
    done
    echo "${_r//  / }"
  }
    
  # sX ; cJoin "1 
  # 3" " a" ; exit 1

# cPid()  { set -x ; printf $BASHPID ; } # get a current PID, support debugging/counting/optimizing number of processes started in within the loop
cPidDelta() { cX ; _n=$(printf %s "$BASHPID" ) ; _n=$(( _n - ${_beginPid:=$_n} )) ; dbg PIDDELTA "$1: $_n ($_beginPid) "  ":$data:" ; _beginPid=$(( _beginPid + 1 )) ; nPidDelta=$_n ; }
cPidDelta() { : ; }
cIfJSONNumber() { cX ; [[ $1 =~ $sJsonNumPattern ]] && echo "$1" ; } # FIXME: superflous ?
# sX ; cIfJSONNumber 99 && echo ok ; cIfJSONNumber 10.4 && echo ok ; echo "${BASH_REMATCH[0]}"" ; cIfJSONNumber 10.4x && echo nok ; echo ${BASH_REMATCH[0]} ; exit
cMult10() { cX ; local v=${1/#-./-0.} ; v=${v/#./0.} ; [[ ${v/#./0.} =~ ^([-]?)(0|[1-9][0-9]*)\.([0-9])([0-9]*)$ ]] && { echo "${BASH_REMATCH[1]}${BASH_REMATCH[2]#0}${BASH_REMATCH[3]}" ; } || echo $(( "$1" * 10 )) || return 1 ; true ; }
# sX ; cMult10 -1.16 ; cMult10 -0.800 ; cMult10 1.234 || echo nok ; cMult10 -3.234 ; cMult10 66 ; cMult10 .900 ; cMult10 -.3 ; echo $(( "$(cMult10 "$(cMult10 "$(cMult10 1012.55)" )" )" / 3386 )) ; exit 1
# cMult100() { cX ; [[ $1 =~ ^([-]?)(0|[1-9][0-9]*)\.([0-9]{0,1})([0-9]{0,1})([0-9]*)$ ]] && { echo "${BASH_REMATCH[1]}${BASH_REMATCH[2]:-0}${BASH_REMATCH[3]:-0}${BASH_REMATCH[4]:-0}" ; } || echo $(( ${1/#./0.} * 100 )) || return 1 ; true ; }
# sX ; cMult100 ${1:-1.2} ; cMult100 -1.16 ; cMult100 -0.800 ; cMult100 1.234 || echo nok ; cMult100 -3.234 ; cMult100 66 ; cMult100 .900 ; echo $(( "$(cMult100 "$(cMult100 "$(cMult100 1012.55)" )" )" / 3386 )) ; exit

cDiv10() { cX ; [[ $1.0 =~ ^([+-]?)([0-9]*)([0-9])(\.[0-9]+)?$ ]] && { v="${BASH_REMATCH[1]}${BASH_REMATCH[2]:-0}.${BASH_REMATCH[3]}" ; echo "${v%.0}" ; } || echo 0 ; }
# sX ; cDiv10 -1.234 ; cDiv10 12.34 ; cDiv10 -32.34 ; cDiv10 -66 ; cDiv10 66 ; cDiv10 .900 ;  exit
# cTestFalse() { echo aa ; false ; } ; x=$(cTestFalse) && echo 1$x || echo 2$x ; exit 1

log() {
    cX
    if [[ $sDoLog == dir ]] ; then
        cRotateLogdirSometimes "$dLog"
        logfile="$dLog/$(cDate %H)"
        echo "$(cDate "%d %T")" "$*" >> "$logfile"
        [[ $bVerbose && $* =~ ^\{ ]] && { printf "%s" "$*" ; echo "" ; } >> "$logfile.JSON"
        [ -t 2 ] && [[ $bMoreVerbose ]] && dbg LOG "$*"
    elif [[ $sDoLog ]] ; then
        echo "$(cDate)" "$@" >> "$dLog.log"
    fi
  }

urlencode() { # URL-encode a string $1
    cX
    local string=$1
    local result=""
    local length=${#string}
    for (( i = 0; i < length; i++)); do
        local char=${string:i:1}
        case "$char" in
            [a-zA-Z0-9.~_-])    result+=$char ;;
            *)                  result+="%$(printf '%02X' "'$char")" ;;
        esac
    done
    echo "$result"
  }
  # url="https://www.example.com/some path with spaces/" ; urlencode "$url" ; exit 2


cLogVal() { # log each value to a single file, args: device,sensor,$3=value
    cX
    [[ $sDoLog != dir ]] && return
    _v=$(cDiv10 "$(cMult10 "$3")") # round to 1 decimal digit
    dSensor="$dLog/$1/$2"
    [ -d "$dSensor" ] || mkdir -p "$dSensor"
    fDat="$dSensor/$(cDate %s)" 
    [ -f $fDat ] || echo "$_v" > $fDat
    # remove files older than 2 days when the seconds randomly end in some digit:
    [[ $fDat =~ [9-9]$ ]] && find $dLog -mindepth 3 -xdev -type f -mtime +2 -print0 | xargs -0 -r rm -v && 
        dbg INFO "Cleaned value log $dSensor."
    return 0
  }

cLogMore() { # log to syslog logging facility, too.
    cX
    [[ $sDoLog ]] || return
    _level=info
    (( $# > 1 )) && _level=$1 && shift
    [ -t 2 ] && echo "$sName: $*" 1>&2
    logger -p "daemon.$_level" -t "$sID" -- "$*"
    log "$@"
  }

dbg() { # output args to stderr, if bVerbose is set
	cX
     ifVerbose && { [[ $2 ]] && echo "$1:" "${@:2:$#}" 1>&2 || echo "DEBUG: $1" ; } 1>&2
	}
    # sX ; dbg ONE TWO || echo ok to fail... ; exit
    # sX ; bVerbose=1 ; dbg MANY MORE OF IT ; dbg "ALL TOGETHER" ; exit
dbg2() { cX ; (( bMoreVerbose )) && dbg "$@" ; }  # predefine it now to do nothing, but allow to redefine it later

cMapFreqToBand() {
    cX
    [[ $1 =~ ^43  ]] && echo 433 && return
    [[ $1 =~ ^86  ]] && echo 868 && return
    [[ $1 =~ ^91  ]] && echo 915 && return
    [[ $1 =~ ^149 || $1 =~ ^150 ]] && echo 150 && return
    # FIXME: extend for any further bands
    }
    # sX ; cMapFreqToBand 868300000 ; exit

cCheckExit() { # beautify $data and output it, then exit. For debugging purposes.
    json_pp <<< "$data" # "${@:-$data}"
    exit 0
  }
    # sX ; data='{"one":1}' ; cCheckExit # '{"two":1}' 

cExpandStarredString() {
    _esc="quote_star_quote" ; _str=$1
    _str=${_str//\"\*\"/$_esc}  &&  _str=${_str//\"/\'}  &&  _str=${_str//\*/\"}  &&  _str=${_str//$esc/\"*\"}  && echo "$_str"
  }
  # sX ; cExpandStarredString "${1:+*temperature*,}${1:+ *xhumidity\*,} ${3:+**xbattery**,} ${4:+*rain*,}" ; exit

cRotateLogdirSometimes() {           # check for logfile rotation only with probability of 1/60
    cX
    if (( nMinute + nSecond == 67 )) && cd "$1" ; then 
        _files="$(find . -xdev -maxdepth 2 -type f -size +1000k "!" -name "*.old" -exec mv '{}' '{}'.old ";" -exec gzip -f '{}'.old ";" -print0 | xargs -0 ;
                find . -xdev -maxdepth 2 -type f -size -270c -mtime +13 -exec rm '{}' ";" -print0 | xargs -0 )"
        nSecond+=1
        [[ $_files ]] && cLogMore "Rotated files: $_files"
    fi
  }

cMqttStarred() {		# options: ( [expandableTopic ,] starred_message, moreMosquittoOptions )
    cX
    if (( $# == 1 )) ; then
        _topic="/bridge/state"
        _msg=$1
    else
        _topic=$1
        [[ ! $1 =~ / || $1 =~ ^/ ]] &&  _topic="$sRtlPrefix/bridge/${1#/}" # add the bridge prefix, if no slash contained or no slash at beginning
        _msg=$2
        [[ $1 == log ]] && cLogMore "MQTTLOG: $1  $2"
    fi
    _topic=${_topic/#\//$basetopic} # add the base topic, if not already there (= if _topic starts with a slash)
    _arguments=( ${sMID:+-i $sMID} ${sUserName:+-u "$sUserName"} ${sUserPass:+-P "$sUserPass"} -t "$_topic" -m "$(cExpandStarredString "$_msg")" "${@:3:$#}" ) # ... append further arguments
    [[ ${#hMqtt[@]} == 0 ]] && mosquitto_pub "${_arguments[@]}"
    for host in "${hMqtt[@]}" ; do
        mosquitto_pub ${host:+-h $host} "${_arguments[@]}"
        _rc=$?
        (( _rc == 0 && ! bEveryBroker )) && return 0 # stop after first successful publishing
    done
    return $_rc
  }
  # sX ; sRtlPrefix="rtl" ; basetopic="rtl/433" ; cMqttStarred "state" "{*okki*:null}" ; cMqttStarred "log" "{*loggi*:null}" ; cMqttStarred "/devvi/sensi" "{*tempi*:null}" ; exit 99

cMqttLog() {		# send a log message to the MQTT broker
    cX
    cMqttStarred log "$@"
  }

cMqttState() {	# log the state of the rtl bridge
    _ssid=$(iwgetid -r) # iwgetid might have been aliased to ":" if not available
    _stats="*sensors*:$nReadings,*announceds*:$nAnnouncedCount,*lastannounced*:*$sLastAnnounced*,*mqttlines*:$nMqttLines,*receiveds*:$nReceivedCount,*suppressed*:$nSuppressedCount,*cacheddewpoints*:${#aDewpointsCalc[@]},${nUploads:+*wuuploads*:$nUploads,}*lastfreq*:$sBand,*host*:*$sHostname*,*ssid*:*$_ssid*,*startdate*:*$sStartDate*,*lastreception*:*$(date "+$sDateFormat" -d @$nTimeStamp)*,*currtime*:*$(cDate)*"
    log "$_stats"
    cMqttStarred state "{$_stats${1:+,$1}}"
    }

# Parameters for cHassAnnounce: (Home Assistant auto-discovery)
# OpenHab: https://www.openhab.org/addons/bindings/mqtt.homeassistant
# Home Assistant: https://www.home-assistant.io/docs/mqtt/discovery
# $1: MQTT "base topic" for states of all the sensors(s), e.g. "rtl/433" or "ffmuc"
# $2: Generic sensor model, e.g. a certain temperature sensor model 
# $3: MQTT "subtopic" for the specific sensor instance,  e.g. ${model}/${ident}. ("..../set" indicates writeability)
# $4: Text for specific sensor instance and sensor type info, e.g. "(${ident}) Temp"
# $5: JSON attribute carrying the state
# $6: sensor "class" (e.g. none, temperature, humidity, battery), 
#     used in the announcement topic, in the unique id, in the (channel) name, and FOR the icon and the sensor class 
# Examples:
# cHassAnnounce "$basetopic" "Rtl433 Bridge" "bridge/state"  "(0) SensorCount"   "value_json.sensorcount"   "none"
# cHassAnnounce "$basetopic" "Rtl433 Bridge" "bridge/state"  "(0) MqttLineCount" "value_json.mqttlinecount" "none"
# cHassAnnounce "$basetopic" "${model}" "${model}/${ident}" "(${ident}) Battery" "value_json.battery_ok" "battery"
# cHassAnnounce "$basetopic" "${model}" "${model}/${ident}" "(${ident}) Temp"  "value_json.temperature_C" "temperature"
# cHassAnnounce "$basetopic" "${model}" "${model}/${ident}" "(${ident}) Humid"  "value_json.humidity"       "humidity" 
# cHassAnnounce "ffmuc" "$ad_devname"  "$node/publi../localcl.." "Readable Name"  "value_json.count"   "$icontype"

cHassAnnounce() {
	local -
    local _topicpart=${3%/set} # if $3 ends in /set it is settable, but remove /set from state topic
 	local _devid=${_topicpart##*/} # "$( basename "$_topicpart" )"
	local _command_topic_str="$( [[ $3 != $_topicpart ]] && printf ",*cmd_t*:*~/set*" )"  # determined by suffix ".../set"

    local _dev_class=${6#none} # dont wont "none" as string for dev_class
	local _state_class="" # see https://developers.home-assistant.io/docs/core/entity/sensor/#available-state-classes
    local _component=sensor
    local _jsonpath=${5#value_json.} # && _jsonpath="${_jsonpath//[ \/-]/}"
    local _jsonpath_red=$(echo "$_jsonpath" | tr -d "|][ /_-") # "${_jsonpath//[ \/_-]/}" # cleaned and reduced, needed in unique id's
    local _devname="$2 ${_devid^}"
    local _icon_str  # mdi icons: https://pictogrammers.github.io/@mdi/font/6.5.95/

    if [[ $_dev_class ]] ; then
        local _channelname="$_devname ${_dev_class^}"
    else
        local _channelname="$_devname $4" # take something meaningfull
    fi
    local _sensortopic="${1:+$1/}$_topicpart"
	# local *friendly_name*:*${2:+$2 }$4*,
    local _unit="" # the presence of some "unit_of_measurement" makes it a Number in OpenHab

    # From https://www.home-assistant.io/docs/configuration/templating :
    local _value_template_str="${5:+,*value_template*:*{{ $5 \}\}*}" #   generated something like: ... "value_template":"{{ value_json.battery_ok }}" ...
    # other syntax for non-JSON is: local _value_template_str="${5:+,*value_template*:*{{ value|float|round(1) \}\}*}"

    _dev_class=$6 ; _payload_on="" ; _payload_off="" ;
    case "$_dev_class" in
        temperature*) _icon_str="thermometer"   ; _unit="°C"   ; _state_class="measurement" ; _dev_class="temperature" ;; # _unit="\u00b0C"
        dewpoint) _icon_str="thermometer"       ; _unit="\u00b0C"   ; _state_class="measurement" ; _dev_class="temperature" ;; 
        setpoint*)	_icon_str="thermometer"     ; _unit="%"	        ; _state_class="measurement" ;;
        humidity)	_icon_str="water-percent"   ; _unit="%"	        ; _state_class="measurement" ;;
        rain_mm)	_icon_str="weather-rainy"   ; _unit="mm"	    ; _state_class="total_increasing" ;;
        wind_avg_km_h) _icon_str="weather-windy" ; _unit="km_h"	    ; _state_class="measurement" ;;
        wind_avg_m_s) _icon_str="weather-windy" ; _unit="m_s"	    ; _state_class="measurement" ;;
        wind_max_m_s) _icon_str="weather-windy" ; _unit="m_s"	    ; _state_class="measurement" ;;
        wind_dir_deg) _icon_str="weather-windy" ; _unit="°"	        ; _state_class="measurement" ;;
        pressure_kPa) _icon_str="airballoon-outline" ; _unit="kPa"	; _state_class="measurement" ;;
        pressure_hPa) _icon_str="airballoon-outline" ; _unit="hPa"	; _state_class="measurement" ;;
        ppm)	    _icon_str="smoke"           ; _unit="ppm"	    ; _state_class="measurement" ;;
        density*)	_icon_str="smoke"           ; _unit="ug_m3"	    ; _state_class="measurement" ;;
        counter)	_icon_str="counter"         ; _unit="#"	        ; _state_class="total_increasing" ;;
		clock)	    _icon_str="clock-outline"   ;;
		signal_strength)	_icon_str="signal"  ; _unit="dB"	    ; _state_class="measurement" ;;
        switch)     _icon_str="toggle-switch*"  ; _component=binary_sensor ; _dev_class=switch ;;
        motion)     _icon_str="motion-sensor"   ; _component=binary_sensor ;;
        button01)   _icon_str="gesture-tap"     ; _component=binary_sensor ; _dev_class="button" ; _payload_on=1 ; _payload_off=0 ;;
        buttonN )   _icon_str="keyboard"        ; _component=sensor        ; _dev_class="" ; _unit="#"	;;
        button)     _icon_str="gesture-tap-button" ; _component=binary_sensor ;;
        dipswitch)  _icon_str="dip-switch" ;;
        code)       _icon_str="lock" ;;
        newbattery) _icon_str="battery-check"   ; _unit="#" ;;
       # battery*)     _unit="B*" ;;  # 1 for "OK" and 0 for "LOW".
        zone)       _icon_str="vector-intersection" ; _unit="#" ; _state_class="measurement" ;;
        unit)       _icon_str="group"           ; _unit="#"     ; _state_class="measurement" ;;
        learn)      _icon_str="plus"            ; _unit="#"     ; _state_class="total_increasing" ;;
        channel)    _icon_str="format-list-numbered" ; _unit="#" ; _state_class="measurement" ;;
        voltage)    _icon_str="FIXME"           ; _unit="V"     ; _state_class="measurement" ;;
        battery|batteryval)	_icon_str=""        ; _unit="#"	    ; _state_class="measurement" ;;
        battery_ok) _icon_str=""                ; _component=binary_sensor ; _dev_class=switch ; _payload_on=1 ; _payload_off=0 ;;
        cmd)        _icon_str="hammer"         ; _component=sensor        ; _dev_class="" ; _unit="#" ;; # e.g. cmd=62
    #   cmd)        _icon_str="command"         ; _state_class="measurement" ;; # e.g. cmd=62
		none)		_icon_str="" ; _unit="" ; _dev_class="" ;;
        *)          cLogMore "Notice: special icon and/or unit not defined for '$6'"
    esac
    _icon_str=${_icon_str:+,*icon*:*mdi:$_icon_str*}
    _unit=${_unit:+,*unit_of_measurement*:*$_unit*}
    _dev_class=${_dev_class:+,*device_class*:*$_dev_class*}

    local _configtopicpart=$(echo "$3" | tr -d "|][ /-" | tr "[:upper:]" "[:lower:]")
    local _topic="${sHassPrefix}/$_component/${1///}${_configtopicpart}$_jsonpath_red$_payload_off$_payload_on/config"  # e.g. homeassistant/sensor/rtl433bresser3ch109/{temperature,humidity}/config
          _configtopicpart="${_configtopicpart^[a-z]*}" # ... capitalize the first letter for readability
    local _device="*device*:{*name*:*$_devname*,*manufacturer*:*$sManufacturer*,*model*:*$2 ${protocol:+(${aProtocols[$protocol]}) ($protocol) }with id $_devid*,*identifiers*:[*${sID}${_configtopicpart}*],*sw_version*:*rtl_433 $rtl433_version*}"
    local _msg="*name*:*$_channelname*,*state_topic*:*$_sensortopic*,$_device$_dev_class${_payload_on:+,*payload_on*:*$_payload_on*}${_payload_off:+,*payload_off*:*$_payload_off*}"
            _msg="$_msg,*unique_id*:*${sID}${_configtopicpart}${_jsonpath_red^[a-z]*}*${_unit}${_value_template_str}${_command_topic_str}$_icon_str${_state_class:+,*state_class*:*$_state_class*}"
          # _msg="$_msg,*availability*:[{*topic*:*$basetopic/bridge/state*}]" # STILL TO DEBUG
          # _msg="$_msg,*json_attributes_topic*:*$_sensortopic*" # STILL TO DEBUG

   	[[ $bVerbose ]] && (
        export GREP_COLORS="mt=01;33;ms=01;33:mc=01;33:sl=:cx=:fn=35:ln=32:bn=32:se=36"
        # export GREP_COLOR="01;33" # FIXME: grep: warning: GREP_COLOR='01;33' is deprecated; use GREP_COLORS='mt=01;33'
        echo "$Yellow$_topic$Rst" "$_msg" | GREPC '^[^ ]*'  # |\{[^}]*}
    )
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
    # by esphome:
    # homeassistant/sensor/esp32-wroom-a/living_room_temperature/config 
    #   {dev_cla:"temperature",unit_of_meas:"C",stat_cla:"measurement",name:"Living Room Temperature",
    #    stat_t:"esp32-wroom-a/sensor/living_room_temperature/state",avty_t:"esp32-wroom-a/status",uniq_id:"ESPsensorliving_room_temperature",
    #    dev:{ids:"c8f09ef1bc94",name:"esp32-wroom-a",sw:"esphome v2023.2.4 Mar 11 2023, 16:55:12",mdl:"esp32dev",mf:"espressif"}}
    # homeassistant/sensor/esp32-wroom-a/atc_battery-level/config
    #   {dev_cla:"battery",unit_of_meas:"%",stat_cla:"measurement",name:"ATC Battery-Level",entity_category:"diagnostic",
    #    stat_t:"esp32-wroom-a/sensor/atc_battery-level/state",avty_t:"esp32-wroom-a/status",uniq_id:"ESPsensoratc_battery-level",
    #    dev:{ids:"c8f09ef1bc94",name:"esp32-wroom-a",sw:"esphome v2023.2.4 Mar 11 2023, 16:55:12",mdl:"esp32dev",mf:"espressif"}}
    #
    # homeassistant/sensor/Bresser-3CH-1-180/Bresser-3CH-1-180-UTC/config {device_class:"timestamp",name:"Timestamp",entity_category:"diagnostic",enabled_by_default:false,icon:"mdi:clock-in",state_topic:"rtl_433/nextcloudpi/devices/Bresser-3CH/1/180/time",unique_id:"Bresser-3CH-1-180-UTC",device:{identifiers:["Bresser-3CH-1-180"],name:"Bresser-3CH-1-180",model:"Bresser-3CH",manufacturer:"rtl_433"}}
    # homeassistant/device_automation/Bresser-3CH-1-180/Bresser-3CH-1-180-CH/config {automation_type:"trigger",type:"button_short_release",subtype:"button_1",topic:"rtl_433/nextcloudpi/devices/Bresser-3CH/1/180/channel",platform:"mqtt",device:{identifiers:["Bresser-3CH-1-180"],name:"Bresser-3CH-1-180",model:"Bresser-3CH",manufacturer:"rtl_433"}}
    # homeassistant/sensor/Bresser-3CH-1-180/Bresser-3CH-1-180-B/config  {device_class:"battery",name:"Battery",unit_of_measurement:"%",value_template:"{{ float(value) * 99 + 1 }}",state_class:"measurement",entity_category:"diagnostic",state_topic:"rtl_433/nextcloudpi/devices/Bresser-3CH/1/180/battery_ok",unique_id:"Bresser-3CH-1-180-B",device:{identifiers:["Bresser-3CH-1-180"],name:"Bresser-3CH-1-180",model:"Bresser-3CH",manufacturer:"rtl_433"}}
    # homeassistant/sensor/Bresser-3CH-1-180/Bresser-3CH-1-180-T/config  {
        # device_class:"temperature",name:"Temperature",unit_of_measurement:"\u00b0C",value_template:"{{ value|float|round(1) }}",
        # state_class:"measurement",state_topic:"rtl_433/nextcloudpi/devices/Bresser-3CH/1/180/temperature_C",unique_id:"Bresser-3CH-1-180-T",
        # device:{identifiers:["Bresser-3CH-1-180"],name:"Bresser-3CH-1-180",model:"Bresser-3CH",manufacturer:"rtl_433"}}
    # homeassistant/sensor/Bresser-3CH-1-180/Bresser-3CH-1-180-H/config  {device_class:"humidity",name:"Humidity",unit_of_measurement:"%",value_template:"{{ value|float }}",state_class:"measurement",state_topic:"rtl_433/nextcloudpi/devices/Bresser-3CH/1/180/humidity",unique_id:"Bresser-3CH-1-180-H",device:{identifiers:["Bresser-3CH-1-180"],name:"Bresser-3CH-1-180",model:"Bresser-3CH",manufacturer:"rtl_433"}}
    # homeassistant/sensor/Bresser-3CH-1-180/Bresser-3CH-1-180-rssi/config {device_class:"signal_strength",unit_of_measurement:"dB",value_template:"{{ value|float|round(2) }}",state_class:"measurement",entity_category:"diagnostic",state_topic:"rtl_433/nextcloudpi/devices/Bresser-3CH/1/180/rssi",unique_id:"Bresser-3CH-1-180-rssi",name:"rssi",device:{identifiers:["Bresser-3CH-1-180"],name:"Bresser-3CH-1-180",model:"Bresser-3CH",manufacturer:"rtl_433"}}
    # homeassistant/sensor/Bresser-3CH-1-180/Bresser-3CH-1-180-snr/config  {device_class:"signal_strength",unit_of_measurement:"dB",value_template:"{{ value|float|round(2) }}",state_class:"measurement",entity_category:"diagnostic",state_topic:"rtl_433/nextcloudpi/devices/Bresser-3CH/1/180/snr",unique_id:"Bresser-3CH-1-180-snr",name:"snr",device:{identifiers:["Bresser-3CH-1-180"],name:"Bresser-3CH-1-180",model:"Bresser-3CH",manufacturer:"rtl_433"}}
    # homeassistant/sensor/Bresser-3CH-1-180/Bresser-3CH-1-180-noise/config {device_class:"signal_strength",unit_of_measurement:"dB",value_template:"{{ value|float|round(2) }}",state_class:"measurement",entity_category:"diagnostic",state_topic:"rtl_433/nextcloudpi/devices/Bresser-3CH/1/180/noise",unique_id:"Bresser-3CH-1-180-noise",name:"noise",device:{identifiers:["Bresser-3CH-1-180"],name:"Bresser-3CH-1-180",model:"Bresser-3CH",manufacturer:"rtl_433"}}

cHassRemoveAnnounce() { # removes ALL previous Home Assistant announcements  
    declare -a _topics=( ".$sHassPrefix/sensor/+/config" ".$sHassPrefix/binary_sensor/+/config" )
    cLogMore "removing sensor announcements below each of ${_topics[*]/.} ..."
    declare -a _arguments=( ${sMID:+-i "$sMID"} -W 1 ${sUserName:+-u "$sUserName"} ${sUserPass:+-P "$sUserPass"} ${_topics[@]/./-t } --remove-retained --retained-only )
    [[ ${#hMqtt[@]} == 0 ]]  && mosquitto_sub "${_arguments[@]}"
    for host in "${hMqtt[@]}" ; do
        mosquitto_sub ${host:+-h $host} "${_arguments[@]}"
    done
    _rc=$?
    cMqttLog "{*event*:*debug*,*message*:*removed all announcements starting with $sHassPrefix returned $_rc.* }"
    return $?
 }

cAddJsonKeyVal() {  # cAddJsonKeyVal [ -b "beforekey" ] [ -n ] "key" "val" "jsondata" (use $data if $3 is empty, no quoting of JSON value numbers)
    cX
    local _bkey="" && [[ $1 == -b ]] && _bkey=$2 && shift 2
    local _nkey="" && [[ $1 == -n ]] && _nkey=1  && shift 1
    local _val=$2  _d=${3:-$data}
    if [[ ! $_nkey || $_val ]] ; then # don't append the pair if value empty and -n option given !
        [[ $_val =~ ^[+-]?(0|[1-9][0-9]*)(\.[0-9]+)?$ || $_val == null ]] || _val="\"$_val\"" # surround numeric _val by double quotes if not-a-number
        if [[ $_d =~ (.*[{,][[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*)(\"[^\"]*\"|[+-]?(0|[1-9][0-9]*)(\.[0-9]+)?)(.*)$ ]] ; then
            : replace val # FIXME: replacing a val not yet fully implemented amd tested
            _d="${BASH_REMATCH[1]}$_val${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
        elif [[ $_bkey == BEGINNING ]] ; then
            : insert at beginning
            _d="{\"$1\":$_val,${_d#\{}"
        elif [[ $_bkey ]] && [[ $_d =~ (.*[{,])([[:space:]]*\"$_bkey\"[[:space:]]*:.*)$ ]] ; then    #  cHasJsonKey $_bkey
            : insert before key
            _d="${BASH_REMATCH[1]}\"$1\":$_val,${BASH_REMATCH[2]}" # FIXME: assuming the JSON wasn't empty
        else
            : insert at end
            _d="${_d/%\}/,\"$1\":$_val\}}"
        fi
    fi
    [[ $3 ]] && echo "$_d" || data=$_d
 }
    # sX ; data='{"one":1}' ; cAddJsonKeyVal "x" "2x" ; echo $data ; cAddJsonKeyVal "n" "2.3" "$data" ; cAddJsonKeyVal "m" "-" "$data" ; exit 2 # returns: '{one:1,"x":"2"}'
    # sX ; cAddJsonKeyVal "donot"  ""  '{"one":1}'  ; cAddJsonKeyVal -b one "donot"  ""  '{"zero":0,"one":1}'  ;  exit 2 # returns: '{"one":1,"donot":""}' 
    # sX ; cAddJsonKeyVal "floati" "5.5" '{"one":1}' ;    exit 2 # returns: '{"one":1,"floati":5.5}'
    # sX ; cAddJsonKeyVal "one" "5.5" '{"one":1,"two":"xx"}' ; cAddJsonKeyVal "two" "nn" '{"one":1,"two":"xx"}' ;    exit 2 # returns: '{"one":1,"floati":5.5}'
    # sX ; cAddJsonKeyVal -n notempty "" '{"one":1,"two":"xx"}' ; cAddJsonKeyVal empty "" '{"one":1,"two":"xx"}' ; exit 2 # returns '{"one":1,"two":"xx"}'
    # sX ; cAddJsonKeyVal -b one "one" null  '{"zero":0,"one":"(none)","two":2}'  ;  exit 2 # returns: '{"zero":0,"one":null}'
    # sX ; cAddJsonKeyVal -b BEGINNING "SOME" null  '{"zero":0,"one":"(none)","two":2}'  ;  exit 2 # returns: {"SOME":null,"zero":0,"one":"(none)","two":2}
    # sX ; cAddJsonKeyVal -b BEGINNING "two" "3"  '{"zero":0,"one":"(none)","two":2}'  ;  exit 2 # returns: {"zero":0,"one":"(none)","two":3} 

cHasJsonKey() { # cHasJsonKey([-v] key [jsonstring]): simplified check to check whether the JSON ${2:-$data} has key $1 (e.g. "temperat.*e")  (. is for [a-zA-Z0-9]) #
    cX
    local _verbose && [[ $1 == -v ]] && _verbose=1 && shift 1
    [[ ${2:-$data} =~ [{,][[:space:]]*\"(${1//\./[a-zA-Z0-9]})\"[[:space:]]*: ]] || return 1 # return early if key not found
    local _k=${BASH_REMATCH[1]}
    [[ $1 =~ \*|\[   ]] && echo "$_k" && return 0  # output the first found key only if multiple fits potentially possible
    [[ $_verbose ]] && e1
    return 0
 }
    # sX ; j='{"dewpoint":"null","battery" :100}' ; cHasJsonKey "dewpoi.*" "$j" && echo yes ; cHasJsonKey batter[y] "$j" && echo yes ; cHasJsonKey batt*i "$j" || echo no ; exit
    # sX ; data='{"dipswitch" :"++---o--+","rbutton":"11R"}' ; cHasJsonKey dipswitch  && echo yes ; cHasJsonKey jessy "$data" || echo no ; exit
    # sX ; data='{"dipswitch" :"++---o--+","rbutton":"11R"}' ; cHasJsonKey -v dipswitch  && echo yes ; cHasJsonKey jessy "$data" || echo no ; exit

cRemoveQuotesFromNumbers() { # removes double quotes from JSON numbers in $1 or $data
    cX
    local _d=${1:-$data}
    while [[ $_d =~ ([,{][[:space:]]*)\"([^\"]*)\"[[:space:]]*:[[:space:]]*\"([+-]?(0|[1-9][0-9]*)(\.[0-9]+)?)\" ]] ; do # 
        # echo "${BASH_REMATCH[0]}  //   ${BASH_REMATCH[1]} //   ${BASH_REMATCH[2]} // ${BASH_REMATCH[3]}"
        _d="${_d/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]}\"${BASH_REMATCH[2]}\":${BASH_REMATCH[3]}"}"
    done
    # _d="$( sed -e 's/: *"\([0-9.-]*\)" *\([,}]\)/:\1\2/g' <<< "${1:-$data}" )" # remove double-quotes around numbers
    [[ $1 ]] && echo "$_d" || data=$_d
 }
    # sX ; x='"AA":"+1.1.1","BB":"-2","CC":"+3.55","DD":"-0.44"' ; data="{$x}" ; cRemoveQuotesFromNumbers ; : exit ; echo $data ; cRemoveQuotesFromNumbers "{$x, \"EE\":\"-0.5\"}" ; exit

perfCheck() {
    for (( i=0; i<3; i++)) ; do
        _start=$(cDate "%s%3N")
        r=100
        j=0 ; while (( j < r )) ; do x='"one":"1a","two": "-2","three":"3.5"' ; cRemoveQuotesFromNumbers "{$x}"; (( j++ )) ; done # > /dev/null 
        _middle=$(date +"%s%3N") ; _one=$(( _one + _middle - _start ))
        j=0 ; while (( j < r )) ; do x='"one":"1a","two" :"-2","three":"3.5"' ; cRemoveQuotesFromNumbers2 "{$x}" ; (( j++ )) ; done # > /dev/null
        _end=$(date +"%s%3N") ; _two=$(( _two + _end - _middle ))
    done ; echo "$_one : $_two"
 } 
    # perfCheck ; exit

cDeleteSimpleJsonKey() { # cDeleteSimpleJsonKey "key" "jsondata" (assume $data if jsondata empty)
    cX
    # shopt -s extglob
    local _d=${2:-$data}
    local k
    local _f
    k=$(cHasJsonKey "$1" "$2")  && ! [[ $k ]] && k=$1
    # : debug3 "$k"
    if [[ $k ]] ; then  #       replacing:  jq -r ".$1 // empty" <<< "$_d" :
        if    [[ $_d =~ ([,{])([[:space:]]*\"$k\"[[:space:]]*:[[:space:]]*[0-9.eE+-]+[[:space:]]*)([,}])([[:space:]]*) ]] ||  # number: ^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$
              [[ $_d =~ ([,{])([[:space:]]*\"$k\"[[:space:]]*:[[:space:]]*\"[^\"]*\"[[:space:]]*)([,}])([[:space:]]*)  ]] ||  # string
              [[ $_d =~ ([,{])([[:space:]]*\"$k\"[[:space:]]*:[[:space:]]*\[[^\]]*\][[:space:]]*)([,}])([[:space:]]*)  ]] ||  # array
              [[ $_d =~ ([,{])([[:space:]]*\"$k\"[[:space:]]*:[[:space:]]*\{[^\}]*\}[[:space:]]*)([,}])([[:space:]]*)  ]] ; then # curly braces, FIXME: max one level for now
            if [[ ${BASH_REMATCH[3]} == "}" ]] ; then   
                # key-value pair is alone or at end of string
                _f="${BASH_REMATCH[1]/\{}${BASH_REMATCH[2]}" 
            else
                _f="${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
            fi
            _f=${_f/]/\\]} # escape any closing "]" in the found match
            _d=${_d/$_f} # do the removal!
        fi        
    fi
    # cHasJsonKey "$@" && echo "$_d"
    [[ $2 ]] && echo "$_d" || data=$_d
 } 
    # sX ; cDeleteSimpleJsonKey "freq" '{"protocol":73,"id":11,"channel": 1,"battery_ok": 1,"freq":433.903,"temperature": 8,"BAND":433,"NOTE2":"=2nd (#3,_bR=1,260s)"}' ; exit 2
    # sX ; data='{"one":"a", "beta":22.1 }' ; cDeleteSimpleJsonKey "one" ; echo "$data" ; exit ; cDeleteSimpleJsonKey beta ; echo "$data" ; cDeleteSimpleJsonKey two '{"alpha":"a","two":"xx"}' ; exit 2
    # sX ; cDeleteSimpleJsonKey three '{ "three":"xxx" }' ; exit 2
    # sX ; data='{"one" : 1,"beta":22}' ; cDeleteSimpleJsonKey one "$data" ; cDeleteSimpleJsonKey two '{"two":-2,"beta":22}' ; cDeleteSimpleJsonKey three '{"three":3.3,"beta":2}' ; exit 2
    # sX ; data='{"id":2,"channel":2,"battery_ok":0,"temperature_C":-12.5,"freq":433.902,"rssi":-11.295}' ; cDeleteSimpleJsonKey temperature_C ; cDeleteSimpleJsonKey freq ; exit
    # sX ; data='{"event":"debug","message":{"center_frequency":433910000, "other":"zzzzz"}}' ; cDeleteSimpleJsonKey message ; cCheckExit
    # sX ; data='{"event":"debug","message":{"center_frequency":433910000, "frequencies":[433910000, 868300000, 433910000, 868300000, 433910000, 915000000], "hop_times":[61]}}' ; cDeleteSimpleJsonKey hop_times ; cDeleteSimpleJsonKey frequencies ; cCheckExit

cDeleteJsonKeys() { # cDeleteJsonKeys "key1 key2" ... "jsondata" (jsondata or $data, if empty)
    cX   
    local _r=${2:-$data}  #    _r="${*:$#}"
    # dbg "cDeleteJsonKeys $*"
    for k in $1 ; do   #   "${@:1:($#-1)}" ; do
        # k="${k//[^a-zA-Z0-9_ ]}" # only allow alnum chars for attr names for sec reasons
        # _d+=",  .${k// /, .}"  # options with a space are considered multiple options
        for k2 in $k ; do
            _r=$(cDeleteSimpleJsonKey "$k2" "$_r")
        done
    done
    # _r="$(jq -c "del (${_d#,  })" <<< "${@:$#}")"   # expands to: "del(.xxx, .yyy, ...)"
    [[ $2 ]] && echo "$_r" || data=$_r
 }
    # sX ; cDeleteJsonKeys 'time mic' '{"time" : "2022-10-18 16:57:47", "protocol" : 19, "model" : "Nexus-TH", "id" : 240, "channel" : 1, "battery_ok" : 1, "temperature_C" : 21.600, "humidity" : 20}' ; exit 1
    # sX ; cDeleteJsonKeys "one" "two" ".four five six" "*_special*" '{"one":"1", "two":2  ,"three":3,"four":"4", "five":5, "_special":"*?+","_special2":"aa*?+bb"}'  ;  exit 1
    # results in: {"three":3,"_special2":"aa*?+bb"}

cComplexExtractJsonVal() {
    local - && : set -x
    cHasJsonKey "$1" && jq -r ".$1 // empty" <<< "${2:-$data}"
 }
    # sX ; data='{"action":"good","battery":100}' ; cComplexExtractJsonVal action && echo yes ; cComplexExtractJsonVal notthere || echo no ; exit

cExtractJsonVal() { # replacement for:  jq -r ".$1 // empty" <<< "${2:-$data}" , avoid spawning jq for performance reasons
    # $1 = -n => JSON value must be numeric
    cX 
    [[ $1 == -n ]] && shift 1 && _bNum=y
    [[ ${2:-$data} ]] || return 1
    if [[ ${2:-$data} ]] && cHasJsonKey "$1" ; then 
        if [[ ${2:-$data} =~ [,{][[:space:]]*(\"$1\")[[:space:]]*:[[:space:]]*\"([^\"]*)\"[[:space:]]*[,}] ]] ||  # string ...
                [[ ${2:-$data} =~ [,{][[:space:]]*(\"$1\")[[:space:]]*:[[:space:]]*([+-]?(0|[1-9][0-9]*)(\.[0-9]+)?)[[:space:]]*[,}] ]] ; then # ... or number 
            _v=${BASH_REMATCH[2]}
            if [[ $_v =~ $sJsonNumPattern || ! $_bNum ]] ; then
                echo "$_v"
            fi
        fi        
    else false ; fi # return error, e.g. if key not found
  }
  # sX ; data='{ "action":"good" , "battery":99.5}' ; cPidDelta 000 && cPidDelta 111 ; cExtractJsonVal action ; cPidDelta 222 ; cExtractJsonVal battery && echo YES ; cExtractJsonVal notthere || echo no ; exit # sX ; data='{ "a":"k", "n":-99.5}' ; cExtractJsonVal a ; cExtractJsonVal n && echo YES ; cExtractJsonVal a && echo YES ; cExtractJsonVal -n n && echo YES ; cExtractJsonVal -n a || echo NO ; exit
  # sX ; data='{ "a":"k", "n":"-0.22", "s":"33.0C" }' ; cExtractJsonVal -n n && echo YES ; cExtractJsonVal -n s ; echo $? ; exit

cAssureJsonVal() {
    cHasJsonKey "$1" && jq -er "if (.$1 ${2:+and .$1 $2} ) then 1 else empty end" <<< "${3:-$data}"
  }
  # sX ; data='{"action":"null","battery":100}' ; cAssureJsonVal battery ">999" ; cAssureJsonVal battery ">9" ;  exit

longest_common_prefix() { # variant of https://stackoverflow.com/a/6974992/18155847
  [[ $1 == -s ]] && shift 1 && set -- "${1// }" "${2// }" # remove all spaces before comparing
  local prefix=""  n=0
  ((${#1}>${#2})) &&  set -- "${1:0:${#2}}" "$2"  ||   set -- "$1" "${2:0:${#1}}" ## Truncate the two strings to the minimum of their lengths
  orig1=$1 ; orig2=$2

  ## Binary search for the first differing character, accumulating the common prefix
  while (( ${#1} > 1 )) ; do
    n=$(( (${#1}+1)/2 ))
    if [[ ${1:0:$n} == ${2:0:$n} ]]; then
      prefix=$prefix${1:0:$n}
      set -- "${1:$n}" "${2:$n}"
    else
      set -- "${1:0:$n}" "${2:0:$n}"
    fi
  done
  ## Add the one remaining character, if common
  if [[ $1 == $2 ]]; then prefix=$prefix$1; fi
  # echo "$prefix"
  cMqttLog "{*event*:*compare*,*prefix*:*$prefix*,*one*:*$orig1*,*two*:*$orig2*}"

  [[ -z $prefix ]] && echo 0 && return 255
  (( ${#prefix} == ${#orig1} )) && echo 999 && return 0
  echo "${#prefix}" && return "${#prefix}"
 }
    # sX ; longest_common_prefix abc4567 abc123 && echo yes ; echo ===== ; longest_common_prefix def def && echo jaa ; exit 1

cEqualJson() {   # cEqualJson "json1" "json2" "attributes to be ignored" '{"action":"null","battery":100}'
    cX
    local _s1=$1 _s2=$2
    if [[ $3 ]] ; then
        _s1=$(cDeleteJsonKeys "$3" "$_s1")
        _s2=$(cDeleteJsonKeys "$3" "$_s2")
    fi
    [[ $_s1 == $_s2 ]] # return code is comparison value
 }
    # sX ; data1='{"act":"one","batt":100}' ; data2='{"act":"two","batt":100}' ; cEqualJson "$data1" "$data1" && echo AAA; cEqualJson "$data1" "$data2" || echo BBB; cEqualJson "$data1" "$data1" "act other" && echo CCC; exit
    # sX ; data1='{ "id":35, "channel":3, "battery_ok":1, "freq":433.918,"temperature":22,"humidity":60,"dewpoint":13.9,"BAND":433}' ; data2='{ "id":35, "channel":3, "battery_ok":1, "freq":433.918,"temperature":22,"humidity":60,"BAND":433}' ; cEqualJson "$data1" "$data2" && echo AAA; cEqualJson "$data1" "$data2" || echo BBB; cEqualJson "$data1" "$data2" "freq" && echo CCC; exit
    # sX ; data1='{ "temperature":22,"humidity":60,"BAND":433}' ; data2='{ "temperature":22,"humidity":60,"BAND":433}' ; cEqualJson "$data1" "$data2" && echo AAA; cEqualJson "$data1" "$data2" || echo BBB; cEqualJson "$data1" "$data2" "freq" && echo CCC; exit

cDewpoint() { # calculate a dewpoint from temp/humid/pressure and cache the result; side effect: set vDewptc, vDewptf, vDewSimple
    local _temperature=$(cDiv10 $(cMult10 "$1") ) _rh=${2/.[0-9]*} - _rc=0 && set +x 
    
    if [[ ${aDewpointsCalc[$_temperature;$_rh]} ]] ; then # check for precalculated, cached values
        IFS=";" read -r vDewptc vDewptf _n _rest <<< "${aDewpointsCalc[$_temperature;$_rh]}"
        (( bVerbose     )) && aDewpointsCalc[$_temperature;$_rh]="$vDewptc;$vDewptf;$(( _n+1 )); $_rest"
        dbg2 DEWPOINT "CACHED: aDewpointsCalc[$_temperature;$_rh]=${aDewpointsCalc[$_temperature;$_rh]} (${#aDewpointsCalc[@]})"
    else
        : "calculate dewpoint values for ($_temperature,$_rh)" # ignoring any barometric pressure for now
        _ad=0 ; limh=${limh:-52} ; div=${div:-5} ; (( _rh < limh )) && _ad=$(( 10 * (limh - _rh) / div  )) # reduce by 12 at 16% (50-16=34)
        vDewSimple=$( cDiv10 $(( $(cMult10 "$_temperature") - 200 + 10 * _rh / 5 - _ad )) )   #  temp - ((100-hum)/5), when humid>50 and 0°<temp<30°C
        _dewpointcalc="$( gawk -v temp="$_temperature" -v hum="$_rh" -v vDewSimple="$vDewSimple" '
            BEGIN {  a=17.27 ; b=237.7 ;
                # Aragonite / 2005 article by Mark G. Lawrence in the Bulletin of the American Meteorological Society
                # https://journals.ametsoc.org/view/journals/bams/86/2/bams-86-2-225.xml
                TAR = temp - ((100-hum) / 5)

                # Magnus approximation:
                alpha = ((a*temp) / (b+temp)) + log(hum/100)
                TM = (b*alpha) / (a-alpha)

                # August-Roche-Magnus approximation:
                TARM = 243.04 * (log(RH/100) + ((17.625 * T) / (243.04 + T))) / (17.625 - log(RH/100) - ((17.625 * T) / (243.04 + T)))
                
                #  Magnus-Tetens formula and a four-term approximation by Buck (1981).
                # alpha2 = ((a*temp) / (b+temp)) + atan(0.067 * hum + 0.0025) + ((a * temp) / (b + temp)) * atan(0.067 * hum + 0.0025) - atan(0.067 * hum + 0.0025)**3 + ((a * temp) / (b + temp))**3
                # TMT= (b*alpha2) / (a-alpha2)

                # Alduchov and Eskridge
                a = 17.625 ; b = 243.04 
                alphaAE = log(hum/100) + (a*temp) / (b+temp)
                TAE = b*alpha3 / (a-alphaAE)

                # Arden-Buck approximation (simplified without pressure, not OK for <0° ?!)
                B = 17.67 ; C = 243.5
                V = log(hum/100) + (B*temp) / (C+temp)
                TAB = C*V / (B-V)

                # Antoine approximation:
                es = 6.112 * exp((17.67 * temp) / (temp + 243.5))
                ea = hum/100 * es
                gamma = log(ea/6.112)
                TA = (243.5 * gamma) / (17.67 - gamma)

                printf( "%.1f %.1f %.1f %.2f %.2f %.2f %.2f %.2f %.2f",  TA, (TA*1.8)+32, TA-vDewSimple, TMT, TA, TAB, TM, TAR, TAE)
                if (hum<0 || TA!=TA || TM!=TM || TMT!=TMT ) exit(1) # best practice to check for a NaN value
            }' ; )"
        _rc=$?
        read -r vDewptc vDewptf vDeltaSimple _rest <<< "$_dewpointcalc" 
        : "vDewptc=$vDewptc, vDewptf=$vDewptf"
        [[ $vDewptc ]] && {
            aDewpointsCalc[$_temperature;$_rh]="$vDewptc;$vDewptf;1;$vDewSimple;delta=$vDeltaSimple;${bVerbose:+,$_dewpointcalc}" # cache the calculations (and maybe the rest for debugging)
        }
        dbg2 DEWPOINT "calculations: $_dewpointcalc, #aDewpointsCalc=${#aDewpointsCalc[@]}"
        if (( ${#aDewpointsCalc[@]} > 4999 )) ; then # maybe an out-of-memory DoS attack from the RF environment
            declare -p aDewpointsCalc | xargs -n1 | tail +3 > "/tmp/$sID.dewpoints.$USER.txt" # FIXME: for debugging
            aDewpointsCalc=() && log "DEWPOINT: RESTARTED dewpoint caching."
        fi
    fi
    echo "$vDewptc" "$vDewptf" 
    (( _rc != 0 )) && return $_rc
    [[ $bRewrite && $vDewptc != 0 ]] && vDewptc=$( cRound "$(cMult10 "$vDewptc")" ) #  reduce flicker in dewpoint as in temperature reading
    [[ $vDewptc && $vDewptf && $vDewptc != +nan && $vDewptf != +nan ]]  # determine any other return value of the function
    }
    # sX ; bVerbose=1 ; cDewpoint 11.2 100 ; echo "rc is $? ($vDewSimple,$_dewpointcalc)" ; cDewpoint 18.4 50 ; echo "rc is $? ($vDewSimple,$_dewpointcalc)" ; cDewpoint 18.4 20 ; echo "rc is $? ($_dewpointcalc)" ; cDewpoint 11 -2 ; echo "rc is $? ($_dewpointcalc)"; exit 1
    # sX ; bVerbose=1 ; cDewpoint 25 30 ; echo "$vDewSimple , $_dewpointcalc)" ; cDewpoint 20 40 ; echo "$vDewSimple , $_dewpointcalc)" ; cDewpoint 14 45 ; echo "$vDewSimple , $_dewpointcalc)" ; exit 1
    # sX ; bVerbose=1 ; for h in $(seq 70 -5 20) ; do cDewpoint 30 $h ; echo "$vDewSimple , $_dewpointcalc ========" ; done ; exit 1

cDewpointTable() {
    declare -An aDewpointsDeltas
    # 52 5 are best for -10..45°C and 10..70% humidity (emphasizing: 20-45° and 40-70%), when compared to the Antoine formula
    for limh in {51..54..1} ; do # {51..54..1}
        for div in  {3..6..1} ; do # {3..6..1} 
            unset aDewpointsCalc && declare -A aDewpointsCalc
            for temp in {-10..45..4} {20..45..6} ; do # {-10..45..4} {20..45..6}
                for hum in {20..70..5} {40..70..10} ; do # {20..70..5} {40..70..10}
                    cDewpoint "$temp" "$hum" > /dev/null
                    nDeltaAbs=$(cMult10 $vDeltaSimple) ; nDeltaAbs=${nDeltaAbs#-}
                    sum=$(( sum + nDeltaAbs * nDeltaAbs))
                    # printf "%3s %3s %5s %5s %4s %5s\n" $temp $hum $vDewptc $vDewSimple $vDeltaSimple $sum
                done
            done
            echo "$limh $div $sum"
            aDewpointsDeltas[$limh,$div]=$sum
            sum=0
            # echo ====================================================================================
        done
    done
 }
 # cDewpointTable ; exit 2

cRound() {
    cX
    _val=$(( ( $1 + sRoundTo*${2:-1}/2 ) / (sRoundTo*${2:-1}) * (sRoundTo*${2:-1}) ))
    # echo "$( cDiv10 $_val )" # FIXME: not correct for negative numbers
    cDiv10 $_val # FIXME: not correct for negative numbers
    }
    # sX ; sRoundTo=5 ; cRound -7 ; cRound 7 ; cRound 14 ; echo "should have been 0.5 and 1.5" ; exit 1

[ -r "$rtl2mqtt_optfile" ] && _moreopts="$(sed -e 's/#.*//'  < "$rtl2mqtt_optfile" | tr -c -d '[:space:][:alnum:]_., -' | uniq )" && dbg "Read _moreopts from $rtl2mqtt_optfile"

[[ " $*" =~ \ -F\ [0-9]* ]] && _moreopts=${_moreopts//-F [0-9][0-9][0-9]}  && _moreopts=${_moreopts//-F [0-9][0-9]} # one or more -F on the command line invalidate any other -F options from the config file
[[ " $*" =~ " -R ++"     ]] && _moreopts=${_moreopts//-R -[0-9][0-9][0-9]} && _moreopts=${_moreopts//-R -[0-9][0-9]} # -R ++ on command line removes any protocol excludes
[[ " $*" =~ " -v"      ]] && _moreopts=${_moreopts//-v} # -v on command line restarts gathering -v options
cLogMore "Gathered options: $_moreopts $*"
[[ " $*" =~ " -?" ]] && _moreopts="" # any -? on the command line invalidates any other options from the config file"

while getopts "?qh:pPt:S:drLl:f:F:M:H:AR:Y:Oij:JI:N:B:w:c:as:W:T:E:29vx" opt $_moreopts "$@"
do
    case "$opt" in
    \?) { echo "Usage: $sName -h brokerhost -t basetopic -p -r -r -d -l -a -e [-F freq] [-f file] -q -v -x [-w n.m] [-W station,key,device]"
        echo "Special signals:"
        grep "trap_[a-z12]*(.*:" "$0" | sed 's/.*# //' ; } 1>&2 # e.g. VTALRM: re-emit all dewpoint calcs and recorded sensor readings (e.g. for debugging purposes)
        exit 1
        ;;
    q)  bQuiet=1
        ;;
    h)  # configure the broker host here or in $HOME/.config/mosquitto_sub
        # syntax: -h USERNAME:PASSWORD@brokerhost:port or -h brokerhost:port or -h brokerhost
        sUserName=${OPTARG%%@*} ; sUserPass=${sUserName#*:}
        [[ $sUserPass == $sUserName ]] && sUserPass=""
        sUserName="${sUserName%:*}"
        sBrokerHost=${OPTARG#*@} ; sBrokerPort=${sBrokerHost#*:} ; sBrokerHost=${sBrokerHost%:*}
        case "$sBrokerHost" in     #  http://www.steves-internet-guide.com/mqtt-hosting-brokers-and-servers/
		test|mosquitto) mqtthost="test.mosquitto.org" ;; # abbreviation
		eclipse)        mqtthost="mqtt.eclipseprojects.io"   ;; # abbreviation
        hivemq)         mqtthost="broker.hivemq.com"   ;;
		*)              mqtthost=$(echo "$sBrokerHost" | tr -c -d '0-9a-z_.' ) ;; # clean up for sec purposes
		esac
   		hMqtt+=( "$([[ ! "${hMqtt[*]}" == *"$mqtthost"*  ]] && echo "$mqtthost")" ) # gather them, but no duplicates
        # echo "${hMqtt[*]}"
        ;;
    P)  bRetained=1
        ;;
    t)  basetopic=$OPTARG # choose another base topic for MQTT
        ;;
    S)  rtl433_opts+=( -S "$OPTARG" ) # pass signal autosave option to rtl_433
        ;;
    d)  bRemoveAnnouncements=1 # delete (remove) all retained MQTT auto-discovery announcements (before starting), needs a newer mosquitto_sub
        ;;
    r)  (( bRewrite )) && bRewriteMore=1 && dbg "Rewriting even more ..."
        bRewrite=1  # rewrite and simplify output
        ;;
    L)  bLogTempHumidity=1  # 
        ;;
    l)  dLog=$OPTARG 
        ;;
    f)  if [[ $OPTARG == "-" || $OPTARG == /dev/stdin ]] ; then
            echo "ERROR: reading stdin currently not supported" 1>&2
            exit 1
        elif [[ $OPTARG == MQTT || $OPTARG =~ MQTT: ]] ; then # syntax: -f MQTT:brokerhost:topicprefixforlistening
            fReplayfile=MQTT:
            OPTARG=${OPTARG#MQTT:} && OPTARG=${OPTARG#MQTT}
            hMqttSource=${OPTARG//:*}
            if [[ $hMqttSource == "-" ]] ; then
                hMqttSource=localhost
            elif [[ $hMqttSource ]] ; then
                hMqttSource=test.mosquitto.org
            fi            
            sMqttTopic=${OPTARG##"${hMqtt[0]}"}
            sMqttTopic=${sMqttTopic#*:}

            # nMinSecondsOther=1
            # nMinOccurences=2
        else
            fReplayfile=$(readlink -f "$OPTARG") # file to replay (e.g. for debugging), instead of rtl_433 output
            nMinSecondsOther=0
            nMinOccurences=1
        fi
        dbg INFO "fReplayfile: $fReplayfile"
        ;;
    w)  sRoundTo=$OPTARG # round temperature to this value and relative humidity to 4-times this value (_hMult)
        ;;
    F)  if   [[ $OPTARG == 868 ]] ; then
            rtl433_opts+=( -f 868.3M ${sSuggSampleRate:+-s $sSuggSampleRate} -Y "$sSuggSampleModel" ) # last tried: -Y minmax, also -Y autolevel -Y squelch   ,  frequency 868... MhZ - -s 1024k
        elif [[ $OPTARG == 915 ]] ; then
            rtl433_opts+=( -f 915M ${sSuggSampleRate:+-s $sSuggSampleRate} -Y "$sSuggSampleModel" ) 
        elif [[ $OPTARG == 27  ]] ; then
            rtl433_opts+=( -f 27.161M ${sSuggSampleRate:+-s $sSuggSampleRate} -Y "$sSuggSampleModel" )  
        elif [[ $OPTARG == 150 ]] ; then
            rtl433_opts+=( -f 150.0M ) 
        elif [[ $OPTARG == 433 ]] ; then
            rtl433_opts+=( -f 433.91M ) #  -s 256k -f 433.92M for frequency 433... MhZ
        elif [[ $OPTARG =~ ^[1-9] ]] ; then # if the option start with a number, assume it's a frequency
            rtl433_opts+=( -f "$OPTARG" )
        else                             # interpret it as a -F option to rtl_433 otherwise
            rtl433_opts+=( -F "$OPTARG" )
        fi
        basetopic="$sRtlPrefix/$OPTARG"
        nHopSecs=${nHopSecs:-61} # (60/2)+11 or 60+1 or 60+21 or 7, i.e. should be a proper coprime to 60sec
        nStatsSec="10*(nHopSecs-1)"
        ;;
    M)  rtl433_opts+=( -M "$OPTARG" )
        ;;
    H)  nHopSecs=$OPTARG
        ;;
    A)  rtl433_opts+=( -A )
        ;;
    R)  [[ $OPTARG == "++" ]] && { dbg "INFO" "Ignoring any protocol excludes from config file" ; continue ; }
        rtl433_opts+=( -R "$OPTARG" )
        if [[ $OPTARG =~ ^[0-9-] ]] ; then
            [[ ${OPTARG:0:1} != "-" ]] && dbg "WARNING" "Are you sure you didn't want to exclude protocol $OPTARG?!"
        else
            aExcludes+=( "$OPTARG" )
        fi
        ;;
    Y)  rtl433_opts+=( -Y "$OPTARG" )
        sSuggSampleModel=$OPTARG
        ;;
    O)  bPreferIdOverChannel=1
        ;;
    i)  bAddIdToTopicAlways=1
        ;;
    J)  bAddIdToTopicIfNecessary=1
        ;;
    j)  # add id to topic for certain model_idents, e.g. if two sensors share a channel
        aSensorToAddIds["$OPTARG"]=1
        dbg "INFO" "Will always add id to MQTT topic for model_ident $OPTARG: aSensorToAddIds["$OPTARG"]=1"
        ;;
    I)  sSuppressAttrs+=" $OPTARG" # suppress attribute from the output
        ;;
    N)  fNameMappings=$OPTARG # file with name mappings for sensor names (model_ident)
        [ -r "$fNameMappings" ] || { echo "ERROR: Can't read $fNameMappings" 1>&2 ; exit 2 ; }
        ;;
    B)  sRtlPrefix=$OPTARG
        ;;
    p)  bAnnounceHass=1
        ;;
    c)  nMinOccurences=$OPTARG # MQTT announcements only after at least $nMinOccurences occurences... (-1 for none)
        (( nMinOccurences <= 0 )) && bAnnounceHass=0
        ;;
    E)  nMinSecondsOther=$OPTARG # seconds before repeating any same (=unchanged equal) reading
        ;;    
    T)  rtl433_opts+=( -T "$OPTARG" ) # ask rtl_433 to exit after given time (e.g. seconds)
        ;;
    a)  bAlways=1
        nMinOccurences=1
        ;;
    s)  sSuggSampleRate=$(tr -c -d '[:alnum:]' <<< "$OPTARG")
        ;;
    W)  command -v curl > /dev/null || { echo "$sName: curl not installed, but needed for uploading data ..." 1>&2 ; exit 126 ; }
        IFS=',' read -r _company _id _key _sensor _indoor _sensorid <<< "$OPTARG"  # Syntax e.g.: -W <Station-ID>,<-Station-KEY>,Bresser-3CH_1m,{indoor|outdoor}
        (( bVerbose)) && echo WUNDERGROUD "_company=$_company, _id=$_id, _key=$_key, _sensor=$_sensor, _indoor=$_indoor, _sensorid=$_sensorid" 1>&2
        [[ $_indoor ]] || { echo "$sName: -W $OPTARG doesn't have at least three comma-separated values..." 1>&2 ; exit 2 ; }
        _company="${_company,,}" # lowercase the value
        aMatchIDs[$_company.$_sensor.$_sensorid]="$_sensor.$_sensorid" # content doesn't matter, just any value

        if [[ $_company == wunderground ]] ; then
            (( bVerbose)) && echo WUNDERGROUD "Will upload data for device $_sensor as station ID $_id to Weather Underground..." 1>&2
            aWuUrls[$_sensor]="$sWuBaseUrl?ID=$_id&PASSWORD=$_key&action=updateraw&dateutc=now"
            dbg "aWuUrls[$_sensor]=${aWuUrls[$_sensor]}"
            [[ $_indoor == indoor ]] && aWuPos[$_sensor]="indoor" # add this prefix to temperature key id
            _key=""
            ((bVerbose)) && echo "Upload data for $_sensor as station $_id ..."
        elif [[ $_company == whatsapp ]] ; then
            ## https://api.callmebot.com/whatsapp.php?phone=4917....&text=This+is+a+test&apikey=1234567
            ## _id=Whatsapp phone number, _key=apikey, _sensor=rtl-sensor, _indoor=ignored
            # dbg "Will call WhatsApp bot on phone $_id for device $_sensor ..."
            # aWhUrls[$_sensor]="phone=$_id&apikey=$_key"
            # ((bVerbose)) && echo "WhatsApp data for $_sensor for phone $_id ..."
            ((bVerbose)) && echo "NO MORE SUPPORT FOR: WhatsApp data for $_sensor for phone $_id ..."
        else
            echo "$sName: -W $OPTARG has invalid company name $_company (WU)..." 1>&2 ; exit 2
        fi
     ;;
    2)  bTryAlternate=1 # ease coding experiments (not to be used in production)
        ;;
    9)  bEveryBroker=1 # send to every mentioned broker
        ;;
    v)  if  ifVerbose ; then
            bMoreVerbose=1 && rtl433_opts=( "-M noise:60" "${rtl433_opts[@]}" -v )
            dbg2() { cX ; (( bMoreVerbose)) && dbg "$@" ; }
        else
            bVerbose=1
            nTimeMinDelta=$(( nTimeMinDelta / 2 ))
            # shopt -s lastpipe  # FIXME: test lastpipe thoroughly
        fi
        ;;
    x)  sX # turn on shell command tracing from here on
        ;;
    esac
done

shift $((OPTIND-1))  # Discard all the options previously processed by getopts, any remaining options will be passed to mosquitto_pub further down on

rtl433_opts+=( ${nHopSecs:+-H $nHopSecs -v} ${nStatsSec:+-M stats:1:$nStatsSec} )
sRoundTo=$( cMult10 "$sRoundTo" )
(( bMoreVerbose )) && for KEY in "${!aMatchIDs[@]}"; do dbg2 WUPLOAD "aMatchIDs[$KEY] = ${aMatchIDs[$KEY]}" ; done

if [ -f "${dLog}.log" ] ; then  # want one logfile only
    sDoLog="file"
else
    sDoLog="dir"
    dModel="$dLog/model.dir"
    if mkdir -p "$dModel" && [ -w "$dLog" ] ; then
        :
    else
        dLog="/tmp/${sName// }" && cLogMore "Defaulting to dLog $dLog"
        mkdir -p "$dModel" || { log "Can't mkdir $dModel" ; exit 1 ; }
    fi
    cd "$dLog" || { log "Can't cd to $dLog" ; exit 1 ; }
fi
# sX ; cLogMore info "test test" ; exit 2
# sX ; log "test" ; exit 2

# trap and ignore signals to avoid any interruption until the real traps are defined further down
trap '' INT TRAP USR2 VTALRM

# command -v jq > /dev/null || { _msg="$sName: jq might be necessary!" ; log "$_msg" ; echo "$_msg" 1>&2 ; }
command -v iwgetid > /dev/null || { _msg="$sName: iwgetid not found" ; log "$_msg" ; echo "$_msg" 1>&2 ; alias iwgetid : ; }

if [[ $fReplayfile ]]; then # for both file as well as MQTT...
    sBand="999"
    _band=${fReplayfile##*/} ; _band=${_band%%_*} # if a numeric sBand is the first part of the filename, e.g. 433 in 433_BresserCH1_...
    [[ $_band =~ ^[0-9]+$ ]] && sBand=$_band
    # build grep expression to exlude all protocols in aExcludes
    for p in "${aExcludes[@]}" ; do sProtExcludes+="|$p" ; done
    sProtExcludes=${sProtExcludes#|} # remove leading pipe char
    dbg2 EXCLUDES "${sProtExcludes//|/,}"
else
    _output=$( $rtl433_command "${rtl433_opts[@]}" -T 1 2>&1 )
    # echo "$_output" ; exit
    sdr_tuner=$(awk '/^Found / { gsub(/^Found /, ""); gsub(/ tuner$/, ""); print; exit }' <<< "$_output")  # matches "Found Fitipower FC0013 tuner"
    sdr_freq=$(awk '/^.*Tuned to / { gsub(/.*Tuned to /, ""); gsub(/MHz\.$/, ""); print; exit }' <<< "$_output") # matches "Tuned to 433.900MHz."
    conf_files=$( awk -F \" -- '/^Trying conf/ { print $2 }' <<< "$_output" | xargs ls -1 2>/dev/null ) # try to find an existing config file
    sBand=$( cMapFreqToBand $(cExtractJsonVal sdr_freq) )
fi
basetopic="$sRtlPrefix/$sBand" # intial setting for basetopic

# Enumerate the supported protocols and their names, put them into array aProtocols, e.g. ....
# ...
# [215]  Altronics X7064 temperature and humidity device
# [216]* ANT and ANT+ devices
declare -A aProtocols
while read -r num name ; do 
    [[ $num =~ ^\[([0-9]+)\]\*?$ ]] && aProtocols+=( [${BASH_REMATCH[1]}]="$name" )
done < <( $rtl433_command -R 99999 2>&1 )

cEchoIfNotDuplicate() {
    cX
    if [ "$1..$2" != "$gPrevData" ] ; then
        # (( bWasDuplicate )) && echo -e "\n" # echo a newline after some dots
        echo -e "$1${2:+\n$2}"
        gPrevData="$1..$2" # save the previous data
        # bWasDuplicate=""
    else
        printf "."
        # bWasDuplicate=1
    fi
 }

if (( bAnnounceHass )) ; then
    cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/log  "LogMessage"  ""  none
    cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/unannounced  "Unannounced"  ""  none
fi

_info="*host*:*$sHostname*,*version*:*$rtl433_version*,*tuner*:*$sdr_tuner*,*freq*:$sdr_freq,*additional_rtl433_opts*:*${rtl433_opts[*]}*,*logto*:*$dLog ($sDoLog)*,*rewrite*:*${bRewrite:-no}${bRewriteMore:-no}*,*nMinOccurences*:$nMinOccurences,*nMinSecondsWeather*:$nMinSecondsWeather,*nMinSecondsOther*:$nMinSecondsOther,*sRoundTo*:$sRoundTo"
if [ -t 1 ] ; then # probably running on a terminal
    log "$sName starting at $(cDate)"
    cMqttLog "{*event*:*starting*,$_info}"
else               # probably non-terminal
    delayedStartSecs=3
    log "$sName starting in $delayedStartSecs secs from $(cDate)"
    sleep "$delayedStartSecs"
    _id=${INVOCATION_ID:+*$INVOCATION_ID*} # when used in systemd
    cMqttLog "{*event*:*starting*,$_info,*invocation_id*:${_id:-null},*message*:*delayed by $delayedStartSecs secs*,*sw_version*=*$rtl433_version*,*user*:*$( id -nu )*,*cmdargs*:*$commandArgs*}"
fi

# Optionally remove any matching retained announcements
(( bRemoveAnnouncements )) && cHassRemoveAnnounce && cMqttState "*note*:*removeAnnouncements*" && 
    mosquitto_sub ${sMID:+-i $sMID} ${sUserName:+-u "$sUserName"} ${sUserPass:+-P "$sUserPass"} -W 1 --retained-only --remove-retained -t "$sRtlPrefix/+" 

trap_exit() {   # stuff to do when exiting
    local exit_code=$? # must be first command in exit trap
    cX;
    cLogMore "$sName exit trap at $(cDate): removeAnnouncements=$bRemoveAnnouncements. Will also log state..."
    (( bRemoveAnnouncements )) && cHassRemoveAnnounce
    [[ $_pidrtl ]] && _pmsg=$( ps -f "$_pidrtl" | tail -1 )
    (( COPROC_PID )) && _cppid=$COPROC_PID && kill "$COPROC_PID" && { # avoid race condition for value of COPROC_PID after killing coproc
        wait "$_cppid" # Cleanup, may fail on purpose
        dbg "Killed coproc PID $_cppid and awaited rc=$?"
    }
    nReadings=${#aPrevReadings[@]}
    cMqttState "*note*:*trap exit*,*exit_code*:$exit_code, *collected_sensors*:*${!aPrevReadings[*]}*"
    cMqttLog "{*event*:*$( [[ $fReplayfile ]] && echo info || echo warning )*, *host*:*$sHostname*, *exit_code*:$exit_code, *message*:*Exiting${fReplayfile:+ after reading from $fReplayfile}...*}${_pidrtl:+ procinfo=$_pmsg}"
    # logger -p daemon.err -t "$sID" -- "Exiting trap_exit."
    # rm -f "$conf_file" # remove a created pseudo-conf file if any
 }
trap 'trap_exit' EXIT 

if [[ $fReplayfile =~ ^MQTT: ]] ; then
    echo "MQTT: $fReplayfile" 1>&2
    coproc COPROC (
        mosquitto_sub -h "$hMqttSource" ${sUserName:+-u "$sUserName"} ${sUserPass:+-P "$sUserPass"} -t "$sMqttTopic/#"
    )
elif [[ $fReplayfile == /dev/stdin ]] ; then
    exit 0 # doesn't work correctly, filtered out above at command line parsing
elif [[ $fReplayfile ]] ; then
    coproc COPROC ( 
        sleep 2
        shopt -s extglob ; export IFS=' '
        # sX ; : fReplayfile=$fReplayfile 
        while read -t 2 -r line ; _rc=$? ; [[ $_rc == 0 ]] ; do 
            : "line $line" #  e.g.   103256 rtl/433/Ambientweather-F007TH/1 { "protocol":20,"id":44,"channel":1,"freq":433.903,"temperature":19,"humidity":62,"BAND":433,"HOUR":16,"NOTE":"changed"}
            : "FRONT ${line%%{+(?)}" 1>&2
            data=${line##*([!{])} # data starts with first curly bracket...
            read -r -a aFront <<< "${line%%{+(?)}" # remove anything before an opening curly brace from the line read from the replay file
            if ! cHasJsonKey model && ! cHasJsonKey since ; then # ... then try to determine "model" either from an MQTT topic or from the file name, but not from JSON with key "since"
                : frontpart="${aFront[-1]}"
                IFS='/' read -r -a aTopic <<< "${aFront[-1]}" # MQTT topic might be preceded by timestamps that are to be removed
                [[ ${aTopic[0]} == rtl && ${#aTopic[@]} -gt 2 ]] && {
                    sBand=${aTopic[1]}  # extract freq band from topic if non given in message
                    sModel=${aTopic[2]} # extract model from topic if non given in message
                }
                if ! [[ $sModel ]] ; then # if still not found ...
                    IFS="_" read -r -a aTopic <<< "${fReplayfile##*/}" # .. try to determine from the filename, e.g. "433_IBIS-Beacon_5577"
                    sBand=${aTopic[0]}
                    sModel=${aTopic[1]}
                    sChannelOrId=${aTopic[2]}
                fi
                cAddJsonKeyVal model "${sModel:-UNKNOWN}"
                cAddJsonKeyVal BAND "${sBand:-null}" 
            else
                : ! cHasJsonKey BAND && cAddJsonKeyVal BAND "${sBand:-null}"
            fi
            echo "$data" # ; echo "EMITTING: $data" 1>&2
            sleep 2
        done < "$fReplayfile"
        dbg INFO "Replay file ended, last rc=$_rc."
        sleep 3 ; # echo "COPROC EXITING." 1>&2
    )  
    # Reconnect the coprocess's stdin to a new input file
    dbg "Replaying from $fReplayfile (${COPROC_PID}): ${COPROC[0]},${COPROC[1]},${COPROC[2]}"
    # exec ${COPROC[1]}<&0
    exec 0<&- # close my stdin
    # exec {COPROC[0]} </path/to/new/input/file

    sleep 2
else
    if [[ $bVerbose || -t 1 ]] ; then
        cLogMore "rtl_433 ${rtl433_opts[*]}"
        (( nMinOccurences > 1 )) && cLogMore "Will do MQTT announcements only after at least $nMinOccurences occurences..."
    fi 
    # Start the RTL433 listener as a bash coprocess ... # https://unix.stackexchange.com/questions/459367/using-shell-variables-for-command-options
    coproc COPROC ( trap '' SYS VTALRM TRAP "${aSignalsOther[@]}" ; $rtl433_command ${conf_file:+-c "$conf_file"} "${rtl433_opts[@]}" -F json,v=8 2>&1 ; rc=$? ; sleep 3 ; exit $rc )
    # -F "mqtt://$mqtthost:1883,events,devices"

    sleep 1 # wait for rtl_433 to start up...
    _pidrtl=$( pidof "$rtl433_command" ) # hack to find the process of the - hopefully single - rtl_433 command
    # _pgrp=$(ps -o pgrp= ${COPROC_PID})
    [[ $_pidrtl ]] && _ppid=$( ps -o ppid= "$_pidrtl" ) &&  _pgrp=$( ps -o pgrp= "$_pidrtl" )
    # renice -n 15 "${COPROC_PID}" > /dev/null
    # renice -n 17 -g "$_pgrp" # > /dev/null
    _msg="COPROC_PID=$COPROC_PID, pgrp=$_pgrp, ppid=$_ppid, pid=$_pidrtl"
    dbg2 PID "$_msg"
    if ! (( _ppid == COPROC_PID  )) ; then
        cLogMore "start of $rtl433_command failed: $_msg"
        cMqttLog "{*event*:*startfailed*,*host*:*$sHostname*,*message*:*$rtl433_command ended fast: $_msg*}"
    else
        renice -n 15 "$_pidrtl" > /dev/null 
        cMqttLog "{*event*:*debug*,*host*:*$sHostname*,*message*:*rtl_433 start: $_msg*}"

        if (( bAnnounceHass )) ; then
            ## cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "TestVal" "value_json.mcheck" "mcheck"
            cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "AnnouncedCount" "value_json.announceds" counter &&
            cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "Last Announced Sensor" "value_json.lastannounced" none &&
            cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "SensorCount"    "value_json.sensors"    counter   &&
            cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "MqttLineCount"  "value_json.mqttlines"  counter  &&
            cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "ReadingsCount"  "value_json.receiveds"  counter  &&
            cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "Start date"     "value_json.startdate"  clock    &&
            nRC=$?
            (( nRC != 0 )) && echo "ERROR: HASS Announcements failed with rc=$nRC" 1>&2
            sleep 1
        fi

    fi
fi 

# also install additional signal handlers

trap_int() {    # INT: log state and names of collected sensors to MQTT
    trap '' INT 
    log "$sName signal INT: logging state to MQTT"
    cMqttLog "{*event*:*debug*,*message*:*Signal INT, will emit state message* }"
    cMqttState "*note*:*trap INT*,*collected_sensors*:*${!aPrevReadings[*]}* }" # FIXME: does it still work
    nLastStatusSeconds=$(cDate %s) 
    [[ $fReplayfile && ! $fReplayfile =~ MQTT: ]] && exit 0 || trap 'trap_int' INT # FIXME: killing mosquitto_sub...
  }
trap 'trap_int' INT 

trap_trap() {    # TRAP: toggle verbosity 
    bVerbose=$( ((bVerbose)) || e1 ) # toggle verbosity
    cMqttState
    _msg="Signal TRAP: toggled verbosity to ${bVerbose:-none}${fReplayfile:+, nHopSecs=$nHopSecs}, sBand=$sBand"
    log "$sName $_msg"
    cMqttLog "{*event*:*debug*,*host*:*$sHostname*,*message*:*$_msg*}"
  }
trap 'trap_trap' TRAP

trap_usr2() {    # USR2: remove ALL home assistant announcements (CAREFUL!) with .../sensor
    cHassRemoveAnnounce
    _msg="Signal USR2: resetting ALL home assistant announcements"
    log "$sName $_msg"
    cMqttLog "{*event*:*debug*,*message*:*$_msg*}"
  }
trap 'trap_usr2' USR2 

trap_vtalrm() { # VTALRM: re-emit all dewpoint calcs and recorded sensor readings (e.g. for debugging purposes)
    for KEY in "${!aDewpointsCalc[@]}" ; do
        # _val=${aDewpointsCalc["$KEY"]}
        _msg="{*key*:*$KEY*,*values*:*${aDewpointsCalc["$KEY"]//\"/*}*}"
        dbg DEWPOINT "$KEY  $_msg"
        cMqttStarred dewpoint "$_msg"
    done

    # output all arrays, filter associative arrays starting with lowercase a
    _msg="$(declare -p | awk '$0~"^declare -A" && $3~"^a" { gsub("-A", "", $2); gsub("=.*", "", $3); printf("%s*%s(%s)*:%d" , sep, $3, $2, gsub("]=","") ) ; sep="," }' )"
    dbg ARRAYS "$_msg"
    cMqttStarred arrays "[$_msg]"

    declare -i nNowTime=$(cDate %s)

    for key in "${!aCounts[@]}"; do dbg KEY "${aCounts[$key]} $key" ; done
    # output ascending and sorted by count of readings, no security risk since keys had been cleaned from any suspicious characters
    for KEY in $(for key in "${!aCounts[@]}"; do echo "${aCounts[$key]} $key" ; done | sort -n | cut -d" " -f2-) ; do
        # alternative form for easier processing on server side (e.g. Home Assistant/OpenHab)
        _val=${aPrevReadings["$KEY"]/\{} && _val=${_val/\}} # remove the leading and trailing curly braces from the last reading
        _wuval=${aWuLastUploadTime["$KEY"]:+$((nNowTime-${aWuLastUploadTime[$KEY]}))} # time since last upload to Weather Underground
        _wuval=${_wuval:+,*LASTWU*:$_wuval}
        _msg="{*COUNT*:${aCounts["$KEY"]},*TIMEPASSED*:$((nNowTime-${aLastReceivedTime[$KEY]})),*TIMEPREV*:$((nNowTime-${aPrevReceivedTime[$KEY]})),*BAND*:${aBands["$KEY"]}$_wuval,${_val//\"/*}}"
        cMqttStarred /readings/$KEY "$_msg"
        dbg READING "$KEY  $_msg"
    done

    for KEY in "${!aPrevId[@]}" ; do
        # _val=${aPrevIds["$KEY"]}
        _msg="{*model_ident*=*$KEY*,*value*:*${aPrevId["$KEY"]}*}"
        cMqttStarred ids/$KEY "$_msg"
        dbg ID "$KEY  $_msg"
    done

    if ((bVerbose)) && false ; then
        for KEY in $( declare -p | awk '$0 ~ "^declare -A" && $3 ~ "^a" { gsub(/=.*/, "", $3); print $3 }' ) ; do
            _val=$(declare -p "$KEY" | cut -d= -f2- | tr -c -d "=" | wc -c )
            dbg ARRAY "$KEY($_val)"
            cMqttStarred array "$KEY($_val)"
        done
    fi

    _msg="Signal VTALRM: logged last MQTT messages from ${#aPrevReadings[@]} sensors and ${#aDewpointsCalc[@]} dewpoint calcs."
    log "$sName $_msg"
    cMqttLog "{*event*:*debug*,*message*:*$_msg*}"
    cMqttState
    declare -i _delta=nNowTime-nTimeStamp
    if (( _delta > nSecondsBeforeRestart )) ; then # no radio event has been received for more than x hours, will restart...
        cMqttLog "{*event*:*exiting*,*message*:*no radio event received for $((_delta/60)) minutes, assuming fail*}"
        exit 12 # possibly restart the whole script, if systemd allows it
    fi
  }
trap "trap_vtalrm" VTALRM

trap_other() {   # other signals: log appearance of other signals (see $aSignalsOther below)
    _msg="received other signal ..."
    log "$sName $_msg"
    cMqttLog "{*event*:*debug*,*message*:*$_msg*}"
  }
trap 'trap_other' "${aSignalsOther[@]}" || trap_other # STOP TSTP CONT HUP QUIT ABRT PIPE TERM

trap_usr1() {   # dont reduce the number of MQTT messages
    bEveryMessage=$( ((bEveryMessage)) || e1 ) # toggle chatter
    _msg="Signal USR1: toggled bEveryMessage to ${bEveryMessage:-no}"
    log "$sName $_msg"
    cMqttLog "{*event*:*debug*,*message*:*$_msg*}"
  }
trap 'trap_usr1' USR1 || trap_usr1 # USR1 signal

trap_term() {   # TERM: log appearance of TERM signal (esp. when being stopped by systemd)
    _msg="received SIGTERM (INVOCATION_ID=$INVOCATION_ID)..."
    log "$sName $_msg"
    [[ $NOTIFY_SOCKET ]] && systemd-notify --status="$_msg. Exiting." --pid=$$ --no-block # notify systemd about the shutdown
    cMqttLog "{*event*:*debug*,*message*:*$_msg*}"
    exit 0
  }
trap 'trap_term' "TERM" || trap_term # TERM signal

[[ $* =~ ^y ]] && trap_exit && trap_int && trap_trap && trap_usr2 && trap_vtalrm && trap_other # fake call of all trap functions to avoid shellcheck warnings about non-reachable code

while read -r data <&"${COPROC[0]}" ; _rc=$? ; (( _rc==0  || _rc==27 || ( bVerbose && _rc==1111 ) ))      # ... and go through the loop
do
    # FIXME: data should be cleaned from any suspicous characters sequences as early as possible for security reasons - an extra jq invocation might be worth this...

    # (( _rc==1 )) && cMqttLog "{*event*:*warn*,*message*:*read _rc=$_rc, data=$data*}" && sleep 2  # quick hack to slow down and debug fast loops
    # dbg ATBEGINLOOP "nReadings=$nReadings, nMqttLines=$nMqttLines, nReceivedCount=$nReceivedCount, nAnnouncedCount=$nAnnouncedCount, nUploads=$nUploads"

    _beginPid="" # support debugging/counting/optimizing number of processes started in within the loop

    nLoops+=1
    # dbg 000
    # convert  msg type "SDR: Tuned to 868.300MHz." to "{"center_frequency":868300000}" (JSON) to be processed further down
    if [[ $data =~ xxx.:.\"Tuned.to.([0-9]*\.[0-9]*)MHz\.\" ]] ; then 
        # matches:  {"time" : "2023-10-12 22:38:16", "src" : "SDR", "lvl" : 5, "msg" : "Tuned to 433.910MHz."}
        # data="{\"center_frequency\":${BASH_REMATCH[1]},\"BAND\":$(cMapFreqToBand "${BASH_REMATCH[1]}")}"
        data="{\"center_frequency\":${BASH_REMATCH[1]}}"
    elif [[ $data =~ ^SDR:.Tuned.to.([0-9]*\.[0-9]*)MHz ]] ; then 
        # SDR: Tuned to 868.300MHz.   # .... older, former variant of log message
        # convert  msg type "SDR: Tuned to 868.300MHz." to "{"center_frequency":868300000}" (JSON) to be processed further down
        # data="{\"center_frequency\":${BASH_REMATCH[1]}${BASH_REMATCH[2]}000,\"BAND\":$(cMapFreqToBand "${BASH_REMATCH[1]}")}"
        data="{\"center_frequency\":${BASH_REMATCH[1]}${BASH_REMATCH[2]}000}"
    elif [[ $data =~ ^rtlsdr_set_center_freq.([0-9\.]*) ]] ; then 
        # convert older, former msg type "rtlsdr_set_center_freq 868300000 = 0" to "{"center_frequency":868300000}" (JSON) to be processed further down
        # data="{\"center_frequency\":${BASH_REMATCH[1]},\"BAND\":$(cMapFreqToBand "${BASH_REMATCH[1]}")}"
        data="{\"center_frequency\":${BASH_REMATCH[1]}}"
    elif [[ $data =~ ^[^{] ]] ; then # transform any non-JSON line (= JSON line starting with "{"), e.g. from rtl_433 debugging/error output
        data=${data#\*\*\* } # Remove any leading stars "*** "
        if [[ $bMoreVerbose && $data =~ ^"Allocating " ]] ; then # "Allocating 15 zero-copy buffers"
            cMqttLog "{*event*:*debug*,*message*:*${data//\*/+}*}" # convert it to a simple JSON msg
        elif [[ $data =~ ^"Please increase your allowed usbfs buffer "|^"usb"|^"No supported devices " ]] ; then
            dbg WARNING "$data"
            cMqttLog "{*event*:*error*,*host*:*$sHostname*,*message*:*${data//\*/+}*}" # log a simple JSON msg
            [[ $bVerbose && $data =~ ^"usb_claim_interface error -6" ]] && [ -t 1 ] && dbg WARNING "Will killall $rtl433_command" && killall -vw "$rtl433_command"
        fi
        dbg NONJSON "$data"
        log "Non-JSON: $data"
        continue
    elif ! [[ $data ]] ; then
        dbg EMPTYLINE
        continue # skip empty lines quietly and early
    fi
    # cPidDelta 0ED
    if cHasJsonKey center_frequency || cHasJsonKey src ; then
        data=${data//\" : /\":}  # beautify a bit, i.e. removing extra spaces
        cHasJsonKey center_frequency && _freq=$(cExtractJsonVal center_frequency) && sBand=$(cMapFreqToBand "$_freq") # formerly: sBand="$( jq -r '.center_frequency / 1000000 | floor  // empty' <<< "$data" )"
        _msg=$(cExtractJsonVal msg)
        [[ $(cExtractJsonVal src) == SDR ]] && [[ $_msg =~ ^Tuned\ to\ ([0-9]*)\. ]] && sBand=${BASH_REMATCH[1]} #FIXME FIXME        
        basetopic="$sRtlPrefix/${sBand:-999}"
        # sLastTuneTime=$(cExtractJsonVal time)
        cDeleteJsonKeys time
        if [[ $_msg == "Time expired, exiting!" ]] ; then # rtl_433 was configured to exit regularly, e.g. with option -T nnnnn
            bPlannedTermination=y
            cMqttLog "{*event*:*debug*,*message*:*${_msg}*,*BAND*:${sBand:-null}}"
        elif ifVerbose ; then
            data=${data/#\{ \"/{} # remove leading space immediately after the opening curly brace in JSON
            cEchoIfNotDuplicate "INFOMSG: $data"
            if [[ $data == $sLastTuneMessage ]] && (( bRewrite && ! bEveryMessage )) ; then
                # if (( bRewrite )) && ! (( bEveryMessage )) 
                dbg DUPLICATETUNE "$data"
                continue # ignore a duplicate tune message
            fi
            sLastTuneMessage=$data
            _freqs=$(cExtractJsonVal frequencies) && cDeleteSimpleJsonKey "frequencies" && : "${_freqs}"
            cMqttLog "{*event*:*debug*,*message*:${data//\"/*},*BAND*:${sBand:-null}}"
        fi
        nLastTuneMessage=$(cDate %s) # introduce a delay from 0 to to 1 second for reducing race conditions after a freq hop
        continue
    fi
    ifVerbose && [[ $datacopy != $data ]] && echo "==========================================" && datacopy=$data
    ((bVerbose)) && GREP_COLORS=$yellow GREPC ':[^,}]*' <<< "${data// : /:}" # '"[a-zA-Z0-9_]*":'
    data=${data//\" : /\":} # remove any space around (hopefully JSON-like) colons
    nReceivedCount+=1

    # EXPERIMENTAL: skip a message also if it occurs in the same second as the previous tune message
    if [[ $nLastTuneMessage == $(cDate %s) ]] && ! cHasJsonKey frames ; then
        dbg TOOEARLY "$data"
        nSuppressedCount+=1
        continue
    fi

    # cPidDelta 1ST

    _time=(cExtractJsonVal time)  # ;  _time="2021-11-01 03:05:07"
    # declare +i n # avoid octal interpretation of any leading zeroes
    # cPidDelta AAA
    n=${_time:(-8):2} && nHour=${n#0} 
    n=${_time:(-5):2} && nMinute=${n#0} 
    n=${_time:(-2):2} && nSecond=${n#0}
    _delkeys="time $sSuppressAttrs"
    (( bMoreVerbose )) && cEchoIfNotDuplicate "PREPROCESSED: $data"
    # cPidDelta BBB
    channel=$( ! cExtractJsonVal channel && [[ $fReplayfile ]] && echo "$channel" ) # when replaying preserve the channel as long as there is no channel in the JSON
    protocol=$(cExtractJsonVal protocol) && protocol=${protocol//[^A-Za-z 0-9]} # Avoid arbitrary command execution vulnerability in indexes for arrays
    id=$( ! cExtractJsonVal id && [ "$fReplayfile" ] && echo "$id" ) # when replaying preserve the previous id as long as there is no id in the JSON
    model="" && { cHasJsonKey model || cHasJsonKey since ; } && model=$(cExtractJsonVal model)
    model_ident=""
    if [[ $model ]] ; then
        if [[ $sProtExcludes && $protocol =~ ^$sProtExcludes ]] ; then
            dbg EXCLUDING "$protocol"
            nSuppressedCount+=1
            continue
        fi
        [[ ! $id ]] && id=$(cExtractJsonVal address) # address might be an unique alternative to id under some circumstances, still to TEST ! (FIXME)
        id=${id//[^A-Za-z0-9_]} # remove any special (e.g. arithmetic) characters to prevent arbitrary command execution vulnerability in indexes for arrays
        channel=${channel//[^A-Za-z0-9_]} # sanitize too
        if (( bPreferIdOverChannel )) ; then
            ident=${id:-$channel} # prefer "id" (or "address") over "channel" as the identifier for the sensor instance.
            model_ident=${model}${ident:+_$ident}
        elif [[ $channel ]] ; then
            ident=${channel}
            model_ident=${model}${ident:+_$ident}
            
            if (( ${aSensorToAddIds[$model_ident]} )) ; then
                _bAddIdToTopic=1
                : dbg ADDID "Always adding $id to MQTT topic as in $model_ident_$id"
                model_ident=${model_ident}${id:+_$id}
            else
                if [[ ${aPrevId[$model_ident]} == "$id," ]] ; then # remove the id from the JSON only if it is the same as the previous ID for this model and no other id appeared yet
                    _delkeys+=" id" 
                else
                    if ! [[ ${aPrevId[$model_ident]} =~ "$id," ]] ; then # append current id separated by a comma if it is a really new different one not seen yet
                        # in an ideal radio environment the id should be unique for each sensor and channel, but in reality it might not be the case
                        # so keep the id in the JSON if this is discovered
                        # alternative: use option -j
                        dbg ADDID "Found new id $id for $model_ident"
                        [[ ${aPrevId[$model_ident]} ]] && cMqttLog "{*event*:*duplicateid*,*message*:* NEW=$id  previous=${aPrevId[$model_ident]}*}"
                        aPrevId[$model_ident]="${aPrevId[$model_ident]}$id,"
                    else
                        dbg ADDID "Might add $id to $model_ident to disambiguate: bAddIdToTopicIfNecessary=$bAddIdToTopicIfNecessary (prev=${aPrevId[$model_ident]})"
                        (( bAddIdToTopicIfNecessary )) && _bAddIdToTopic=1 # add the id to the topic, too.
                    fi
                fi
            fi
        else # no channel, fallback to id if any
            ident=${id}
            _delkeys+=" id" # but remove the id from the JSON
            model_ident=${model}${id:+_$id}
        fi
    fi
    rssi=$( cExtractJsonVal -n rssi )
    vTemperature="" && nTemperature10="" && nTemperature10Diff=""
    _val="$( cExtractJsonVal -n temperature_C || cExtractJsonVal -n temperature )" && vTemperature=$_val && _val=$(cMult10 "$_val") && 
        nTemperature10=${_val/.*} && 
        : echo 1 "model_ident=$model_ident" &&
        : echo 2 "${aEarlierTemperVals10[$model_ident]}" &&
        nTemperature10Diff=$(( nTemperature10 - ${aEarlierTemperVals10[$model_ident]:-0} )) # used later
    vHumidity=$( cExtractJsonVal -n humidity )
    # if vHumidity begins with a zero or a dot, multiply it by 100
    #    [[ $vHumidity ]] && vHumidity=1.0 # for debugging
    # if vhumidity begins with a dot, add a zero in front of it
    [[ $vHumidity =~ ^\.] ]] && vHumidity="0$vHumidity" 

    bHumidityScaled=""
    [[ $vHumidity =~ ^(0|0\.[0-9]*|1|1\.0*)$ ]] && vHumidity=$(cMult10 $(cMult10 "$vHumidity")) && 
            bHumidityScaled=1 && dbg HUMIDITY "$vHumidity was scaled to 0 to 100"
    nHumidity=${vHumidity/.[0-9]*}
    vSetPoint="$( cExtractJsonVal -n setpoint_C) || $( cExtractJsonVal -n setpoint_F)"
    type=$( cExtractJsonVal type ) # typically type=TPMS if present
    if cHasJsonKey freq ; then 
        sBand=$( cMapFreqToBand "$(cExtractJsonVal -n freq)" )
    else
        cHasJsonKey BAND && sBand=$(cExtractJsonVal BAND)
    fi
    aBands[${model_ident:-NONE}]=$sBand
    [[ $sBand ]] && basetopic="$sRtlPrefix/$sBand"
    log "$data"     

    [[ ! $bVerbose && ! $model_ident =~ $sSensorMatch ]] && : not verbose, skipping early && nSuppressedCount+=1 && continue # skip unwanted readings (regexp) early (if not verbose)
    # cPidDelta 2ND

    if [[ $model_ident ]] ; then
        if [[ ! $bRewrite ]] ; then
            : no rewriting, only removing unwanted keys...
            cDeleteJsonKeys "$_delkeys"
        else  # Clean the line from less interesting information...
            : Rewrite and clean the line from less interesting information...
            # sample: {"id":20,"channel":1,"battery_ok":1,"temperature":18,"humidity":55,"mod":"ASK","freq":433.931,"rssi":-0.261,"snr":24.03,"noise":-24.291}
            _delkeys+=" mod snr noise mic" && (( ! bVerbose || ! bQuiet  )) && _delkeys+=" freq freq1 freq2" # other stuff: subtype channel
            [[ ${aPrevReadings[$model_ident]} && ( -z $nTemperature10 || $nTemperature10 -lt 500 ) ]] && _delkeys+=" model protocol rssi${id:+ channel}" # remove protocol after first sight  and when not unusual
            dbg2 DELETEKEYS "$_delkeys"
            cDeleteJsonKeys "$_delkeys"
            cRemoveQuotesFromNumbers

            if [[ $vTemperature ]] ; then
                # Fahrenheit = Celsius * 9/5 + 32, Fahrenheit = Celsius * 9/5 + 32
                (( ${#aWuUrls[$model_ident]} > 0 )) && temperatureF=$(cDiv10 "$((nTemperature10 * 9 / 5 + 320))" ) # calculate Fahrenheits only if needed later
                if ((bRewrite)) ; then
                    # _val=$(( ( nTemperature10 + sRoundTo/2 ) / sRoundTo * sRoundTo )) && _val=$( cDiv10 $_val ) # round to 0.x °C
                    _val=$( cRound nTemperature10 ) # round to 0.x °C
                    cDeleteSimpleJsonKey temperature && cAddJsonKeyVal temperature "$_val"
                    cDeleteSimpleJsonKey temperature_C
                    _val=$(cMult10 "$_val")
                    nTemperature10=${_val/.*}
                fi
            fi
            if [[ $vHumidity ]] ; then # 
                if (( bRewrite )) ; then
                    nHumidity=${vHumidity/.[0-9]*}
                    if (( nHumidity < 98 )) ; then
                        _val=$( cRound "$(cMult10 "$vHumidity")" 4 ) # round to 4 * 0.x %
                        nHumidity=${_val/.[0-9]*}
                    fi
                    # FIXME: BREAKING change should have dedicated option when adding 0. in front of $nHumidity (i.e. divide by 100) - OpenHAB 4 likes a dimension-less percentage value to be in the range 0.0...1.0 :
                    if cDeleteSimpleJsonKey humidity ; then
                        if [[ $bHumidityScaled || $bRewriteMore ]] ; then
                            # FIXME: removed temporrarly cAddJsonKeyVal humidity "$( (( nHumidity == 100 )) && printf 1 || printf "0.%2.2d" "$nHumidity" )"
                            cAddJsonKeyVal humidity "$nHumidity"
                        else
                            cAddJsonKeyVal humidity "$nHumidity"
                        fi
                    fi
                fi
            fi

            if (( bRewriteMore )) ; then
                cDeleteJsonKeys "transmit test"
                _k=$( cHasJsonKey "unknown.*" ) && [[ $(cExtractJsonVal "$_k") == 0 ]] && cDeleteSimpleJsonKey "$_k" # delete first key "unknown* == 0"
                bSkipLine=$(( nHumidity>100 || nHumidity<0 || nTemperature10<-300 )) # sanitize=skip non-plausible readings
            fi
            (( bVerbose  )) && ! cHasJsonKey BAND && cAddJsonKeyVal BAND "$sBand"  # add BAND here to ensure it also goes into the logfile for all data lines
            (( bRetained )) && cAddJsonKeyVal HOUR $nHour # Append HOUR value explicitly if readings are to be sent retained
            [[ $sDoLog == dir ]] && echo "$(cDate "%d %H:%M:%S") $data" >> "$dModel/${sBand}_$model_ident"
        fi
        vPressure_kPa=$(cExtractJsonVal -n pressure_kPa)
        [[ $vPressure_kPa =~ ^[0-9.]+$ ]] || vPressure_kPa="" # cAssureJsonVal pressure_kPa "<= 9999", at least match a number
        _bHasParts25=$( [[ $(cExtractJsonVal -n pm2_5_ug_m3     ) =~ ^[0-9.]+$ ]] && e1 ) # e.g. "pm2_5_ug_m3":0, "estimated_pm10_0_ug_m3":0
        _bHasParts10=$( [[ $(cExtractJsonVal -n estimated_pm10_0_ug_m3 ) =~ ^[0-9.]+$ ]] && e1 ) # e.g. "pm2_5_ug_m3":0, "estimated_pm10_0_ug_m3":0
        _bHasRain=$(       [[ $(cExtractJsonVal -n rain_mm   ) =~ ^[1-9][0-9.]+$ ]] && e1 ) # formerly: cAssureJsonVal rain_mm ">0"
        _bHasWindAvgKmh=$( [[ $(cExtractJsonVal -n wind_avg_km_h ) =~ ^[0-9][0-9.]+$ ]] && e1 ) # not for value values starting with 0
        _bHasWindAvgMs=$(  [[ $(cExtractJsonVal -n wind_avg_m_s  ) =~ ^[0-9][0-9.]+$ ]] && e1 ) # not for value values starting with 0
        _bHasWindMaxMs=$(  [[ $(cExtractJsonVal -n wind_max_m_s  ) =~ ^[0-9][0-9.]+$ ]] && e1 ) # not for value values starting with 0
        _bHasWindDirDeg=$( [[ $(cExtractJsonVal -n wind_dir_deg  ) =~ ^[1-9][0-9.]+$ ]] && e1 ) # not for value values starting with 0
        _battok=$(cExtractJsonVal battery_ok)
        _bHasBatteryOK=$(  [[ $_battok =~ ^[01]$ ]] && e1 ) # 0=LOW;1=FULL from https://triq.org/rtl_433/DATA_FORMAT.html#common-device-data
        _bHasBatteryOKVal=$( [[ $_battok =~ ^[01].[0-9]+$ ]] && e1 ) # or some float in between
        _bHasBatteryV=$(   [[ $(cExtractJsonVal -n battery_V) =~ ^[0-9.]+$ ]] && e1 ) # voltage, also battery_mV
        _bHasZone=$(   cHasJsonKey -v zone)    #   {"id":256,"control":"Limit (0)","channel":0,"zone":1}
        _bHasUnit=$(   cHasJsonKey -v unit)    #   {"id":25612,"unit":15,"learn":0,"code":"7c818f"}
        _bHasLearn=$(  cHasJsonKey -v learn)   #   {"id":25612,"unit":15,"learn":0,"code":"7c818f"}
        _bHasChannel=$(cHasJsonKey -v channel) #   {"id":256,"control":"Limit (0)","channel":0,"zone":1}
        _bHasControl=$(cHasJsonKey -v control) #   {"id":256,"control":"Limit (0)","channel":0,"zone":1}
        _bHasCmd=$(    cHasJsonKey -v cmd)
        _bHasCommand=$(cHasJsonKey -v command)
        _bHasValue=$(  cHasJsonKey -v value)
        _bHasData=$(   cHasJsonKey -v data)
        _bHasCounter=$(cHasJsonKey -v counter ) #  {"counter":432661,"code":"800210003e915ce000000000000000000000000000069a150fa0d0dd"}
        _bHasCode=$(   cHasJsonKey -v code  ) #    {"counter":432661,"code":"800210003e915ce000000000000000000000000000069a150fa0d0dd"}
        _bHasRssi=$(   cHasJsonKey -v rssi)
        _bHasButton="" ; _bHasButton01="" ; _bHasButtonN=""
        _s="$(cExtractJsonVal button)"  # { "protocol":3, "model":"Prologue-TH", "subtype":9, "id":16, "channel":1, "battery_ok":0, "button":0, "rssi":-6.763,"temperature":18.5,"humidity":0.255}
        if [[ $_s =~ ^[01]$ ]] ; then
            _bHasButton01=1
        elif [[ $_s =~ ^[0-9]+$ ]] ; then
            dbg BUTTONN "$_s"
            _bHasButtonN=1
        elif [[ $_s ]] ; then
            _bHasButton=1
        fi
        _bHasButtonR=$(cHasJsonKey -v rbutton  ) #  rtl/433/Cardin-S466/00 {"dipswitch":"++---o--+","rbutton":"11R"}
        _bHasDipSwitch=$(cHasJsonKey -v dipswitch) #  rtl/433/Cardin-S466/00 {"dipswitch":"++---o--+","rbutton":"11R"}
        _bHasNewBattery=$(cHasJsonKey -v newbattery) #  {"id":13,"battery_ok":1,"newbattery":0,"temperature_C":24,"humidity":42}
    fi
    # cPidDelta 3RD

    nTimeStamp=$(cDate %s)
    aPrevReceivedTime[${model_ident:-OTHER}]="${aLastReceivedTime[${model_ident:-OTHER}]:-$nTimeStamp}" # remember time of previous reception, initialize if not yet set
    aLastReceivedTime[${model_ident:-OTHER}]=$nTimeStamp

    if (( bSkipLine )) ; then # skip line, e.g. if it is not plausible
        dbg SKIPPING "$data"
        bSkipLine=0
        nSuppressedCount+=1
        continue
    elif ! [[ $model_ident ]] ; then # probably a stats message
        dbg "model_ident is empty"
         ifVerbose && data=${data//\" : /\":} && cEchoIfNotDuplicate "STATS: $data" && cMqttStarred stats "${data//\"/*}" # ... publish stats values (from "-M stats" option)
    elif [[ $bAlways || $nTimeStamp -gt $((nTimeStampPrev+nMinSecondsOther)) ]] || ! cEqualJson "$data" "$sDataPrev" "freq rssi"; then
        : "relevant, not super-recent change to previous signal - ignore freq+rssi changes, sRoundTo=$sRoundTo"
        if  ifVerbose ; then
            (( bRewrite && bMoreVerbose && ! bQuiet )) && cEchoIfNotDuplicate "CLEANED: $model_ident=$( GREPC '.*' <<< "$data")" # resulting message for MQTT
            ! [[ $model_ident =~ $sSensorMatch ]] && continue # however, skip if no fit
        fi
        sDataPrev=$data
        nTimeStampPrev=$nTimeStamp # support ignoring any incoming duplicates within a few seconds
        sReadPrev=${aPrevReadings[$model_ident]}
        sReadPrevS=${aSecondPrevReadings[$model_ident]}
        aPrevReadings[$model_ident]=$data ; : "model_ident=$model_ident , now ${#aPrevReadings[@]} sensors"
        (( aCounts[$model_ident]++ )) # ... += ... doesn't work numerically in assignments for array elements

        sDelta=""
        if [[ $vTemperature ]] ; then
            _diff=$(( nTemperature10 - ${aEarlierTemperVals10[$model_ident]:-0} ))
            if [[ -z ${aEarlierTemperVals10[$model_ident]} ]] ; then
                sDelta=NEW
                aEarlierTemperTime[$model_ident]=$nTimeStamp
                aEarlierTemperVals10[$model_ident]=$nTemperature10
            elif (( nTimeStamp > ${aEarlierTemperTime[$model_ident]} + nTimeMinDelta && ( _diff > sRoundTo || _diff < -sRoundTo ) )) ; then
                sDelta="$( (( _diff > 0 )) && printf "INCR(" || printf "DESC(" ; cDiv10 $_diff )"")"
                aEarlierTemperTime[$model_ident]=$nTimeStamp
                aEarlierTemperVals10[$model_ident]=$nTemperature10
            else
                : "not enough value change: aEarlierTemperVals10[$model_ident]=${aEarlierTemperVals10[$model_ident]}, nTimeStamp=$nTimeStamp (vs ${aEarlierTemperTime[$model_ident]})"
                sDelta=0
            fi
            [[ $bLogTempHumidity ]] && cLogVal "$model_ident" temperature "$vTemperature"
        fi
        if [[ $vHumidity ]] ; then
            _diff=$(( nHumidity - ${aEarlierHumidVals[$model_ident]:-0} ))
            if ! (( ${aEarlierHumidTime[$model_ident]} )) ; then
                sDelta="${sDelta:+$sDelta:}NEW"
                aEarlierHumidTime[$model_ident]=$nTimeStamp && aEarlierHumidVals[$model_ident]=$nHumidity && : "aEarlierHumidVals[$model_ident] initialized"
            elif (( nTimeStamp > ${aEarlierHumidTime[$model_ident]} + nTimeMinDelta && ( _diff > (sRoundTo*4/10) || _diff < -(sRoundTo*4/10) ) )) ; then
                sDelta="${sDelta:+$sDelta:}$( (( _diff>0 )) && printf "INCR" || printf "DESC" )($_diff)"
                aEarlierHumidTime[$model_ident]=$nTimeStamp && aEarlierHumidVals[$model_ident]=$nHumidity && : "aEarlierHumidVals[$model_ident] changed"
            else
                : "not enough change, aEarlierHumidVals[$model_ident]=${aEarlierHumidVals[$model_ident]}, nTimeStamp=$nTimeStamp (vs ${aEarlierHumidTime[$model_ident]})"
                sDelta="${sDelta:+$sDelta:}0"
            fi
            [[ $bLogTempHumidity ]] && cLogVal "$model_ident" humidity "$vHumidity"
        fi
        dbg2 SDELTA "$sDelta"

        if (( bMoreVerbose && ! bQuiet )) ; then
            _prefix="SAME:  "  &&  ! cEqualJson "${aPrevReadings[$model_ident]}" "$sReadPrev" "freq freq1 freq2 rssi" && _prefix="CHANGE(${#aPrevReadings[@]}):"
            # grep expressen was: '^[^/]*|/'
            { echo "$_prefix $model_ident" ; echo "$sReadPrev" ; echo "${aPrevReadings[$model_ident]}" ; } | GREPC '[ {].*'
        fi
        nMinSeconds=$(( ( (bAlways || ${#vTemperature} || ${#vHumidity} ) && (nMinSecondsWeather>nMinSecondsOther) ) ? nMinSecondsWeather : nMinSecondsOther ))
        _ignore_keys="freq freq1 freq2 rssi snr noise" # keys to ignore when comparing two readings
        _IsDiff=$(  ! cEqualJson "$data" "$sReadPrev"  "$_ignore_keys" > /dev/null && e1 ) # determine whether any raw data has changed, ignoring non-important values
        _IsDiff2=$( ! cEqualJson "$data" "$sReadPrevS" "$_ignore_keys" > /dev/null && e1 ) # determine whether raw data has changed compared to second last readings
        _IsDiff3=$( (( _IsDiff && _IsDiff2 )) && 
                    ! cEqualJson "$sReadPrev" "$sReadPrevS" "$_i_ignore_keys" > /dev/null && e1 ) # FIXME: This could be optimized by caching values
        dbg ISDIFF "_IsDiff=$_IsDiff/$_IsDiff2/$_IsDiff2, PREV=$sReadPrev, DATA=$data"
        if (( _IsDiff || bMoreVerbose )) ; then
            if (( _IsDiff2 )) ; then
                if (( _IsDiff3 )) ; then
                    nMinSeconds=$(( nMinSeconds/6 + 1 )) && : different from last and second last time, and these both different, too.
                else
                    nMinSeconds=$(( nMinSeconds/4 + 1 )) && : different only from second last time
                fi
            else
                nMinSeconds=$(( nMinSeconds/2 + 1 )) && : different only from last time
            fi
        fi
        _bAnnounceReady=$(( bAnnounceHass && aAnnounced[$model_ident] != 1 && aCounts[$model_ident] >= nMinOccurences )) # sensor has already appeared several times

        _nSecDelta=$(( nTimeStamp - aLastPub[$model_ident] ))
        if  ifVerbose ; then
            echo "nMinSeconds=$nMinSeconds, announceReady=$_bAnnounceReady, nTemperature10=$nTemperature10, vHumidity=$vHumidity, nHumidity=$nHumidity, hasRain=$_bHasRain, hasCmd=$_bHasCmd, hasCommand=$_bHasCommand, hasValue=$_bHasValue, hasButton=$_bHasButton, hasButton01=$_bHasButton01, hasButtonR=$_bHasButtonR, hasDipSwitch=$_bHasDipSwitch, hasNewBattery=$_bHasNewBattery, hasControl=$_bHasControl, hasBatteryOK=$_bHasBatteryOK, hasBatteryOKVal=$_bHasBatteryOKVal, hasBatteryV=$_bHasBatteryV"
            echo "Counts=${aCounts[$model_ident]}, _nSecDelta=$_nSecDelta, #aDewpointsCalc=${#aDewpointsCalc[@]}"
            (( ! bMoreVerbose )) && 
                GREPC 'model_ident=[^, ]*|\{[^}]*}' <<< "model_ident=$model_ident  READ=${aPrevReadings[$model_ident]}  PREV=$sReadPrev  PREV2=$sReadPrevS"
        fi
        
        # construct the specific part of the MQTT topic:
        topicext="$model$([[ $type == TPMS ]] && echo "-$type" )${channel:+/$channel}$( [[ -z $channel || $bAddIdToTopicAlways || $_bAddIdToTopic ]] && echo "${id:+/$id}" )"

        if (( _bAnnounceReady )) ; then # deal with HASS annoucement need
            : Checking for announcement types - For now, only the following certain types of sensors are announced: "$vTemperature,$vHumidity,$_bHasRain,$vPressure_kPa,$_bHasCmd,$_bHasData,$_bHasCode,$_bHasButton,$_bHasButton01,$bHasButtonN,$_bHasButtonR,$_bHasDipSwitch,$_bHasCounter,$_bHasControl,$_bHasParts25,$_bHasParts10"
            if (( ${#vTemperature} || _bHasRain || _bHasWindMaxMs || _bHasWindAvgKmh || _bHasWindAvgMs || ${#vPressure_kPa} || 
                        _bHasCmd || _bHasCommand || _bHasValue || _bHasData ||_bHasCode || _bHasButton || _bHasButton01 || _bHasButtonN || _bHasButtonR || _bHasDipSwitch ||
                        _bHasCounter || _bHasControl || _bHasParts25 || _bHasParts10 )) ; then
                [[ $protocol    ]] && _name=${aProtocols["$protocol"]:-$model} || _name=$model # fallback
                # if the sensor has anyone of the above attributes, announce all the attributes it has ...:
                # see also https://github.com/merbanan/rtl_433/blob/master/docs/DATA_FORMAT.md
                [[ $vTemperature ]]  && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Temp"      "value_json.temperature"   temperature # "value_json.temperature|float|round(1)"
                [[ $vHumidity    ]]  && {
                    cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Humid"     "value_json.humidity"  humidity
                }
                if [[ $vTemperature  && $vHumidity && $bRewrite ]] || cHasJsonKey "dewpoint" ; then # announce (possibly calculated) dewpoint, too
                    cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Dewpoint"  "value_json.dewpoint"   dewpoint
                fi
                cHasJsonKey setpoint_C && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }TempTarget"      "value_json.setpoint_C"   setpoint
                (( _bHasRain       )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }RainMM"  "value_json.rain_mm" rain_mm
                (( _bHasWindAvgKmh )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }WindAvgKmh" "value_json.wind_avg_km_h" wind_avg_km_h
                (( _bHasWindAvgMs  )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }WindAvgMs"  "value_json.wind_avg_m_s"  wind_avg_m_s
                (( _bHasWindMaxMs  )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }WindMaxMs"  "value_json.wind_max_m_s"  wind_max_m_s
                (( _bHasWindDirDeg )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }WindDirDeg"  "value_json.wind_dir_deg" wind_dir_deg
                [[ $vPressure_kPa  ]] && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }PressureKPa"  "value_json.pressure_kPa" pressure_kPa
                (( _bHasBatteryOK  )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }BatteryOK"   "value_json.battery_ok"    battery_ok # https://triq.org/rtl_433/DATA_FORMAT.html#common-device-data
                (( _bHasBatteryOKVal )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Battery Percentage"   "value_json.battery_ok"    batteryval
                (( _bHasBatteryV   )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Battery Voltage"   "value_json.battery_V"    voltage
                (( _bHasCmd        )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Cmd"       "value_json.cmd"       cmd
                (( _bHasCommand    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Command"       "value_json.command"       command
                (( _bHasValue      )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Value"       "value_json.value"       value
                (( _bHasData       )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Data"       "value_json.data"     data
                (( _bHasRssi && bMoreVerbose )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }RSSI"       "value_json.rssi"   signal_strength # "value_json.rssi|float|round(2)"
                (( _bHasCounter    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Counter"   "value_json.counter"   counter
                (( _bHasParts25    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Fine Parts"  "value_json.pm2_5_ug_m3" density25
                (( _bHasParts10    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Estim Course Parts"  "value_json.estimated_pm10_0_ug_m3" density10
                (( _bHasCode       )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Code"       "value_json.code"     code
                (( _bHasButton     )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Button"     "value_json.button"   button
                (( _bHasButton01   )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Button01"   "value_json.button" button01
                (( _bHasButtonN    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }ButtonN"    "value_json.button | int" buttonN
                (( _bHasButtonR    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }ButtonR"    "value_json.buttonr"  button
                (( _bHasDipSwitch  )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }DipSwitch"  "value_json.dipswitch"    dipswitch
                (( _bHasNewBattery )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }NewBatttery"  "value_json.newbattery" newbattery
                (( _bHasZone       )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Zone"       "value_json.zone"     zone
                (( _bHasUnit       )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Unit"       "value_json.unit"     unit
                (( _bHasLearn      )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Learn"       "value_json.learn"   learn
                (( _bHasChannel    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Channel"    "value_json.channel"  channel
                (( _bHasControl    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Control"    "value_json.control"  control
                #   [[ $sBand ]]  && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Freq"     "value_json.FREQ" frequency
                if  cMqttLog "{*event*:*debug*,*message*:*announced MQTT discovery: $model_ident ($_name)*}" ; then
                    nAnnouncedCount+=1
                    sLastAnnounced=$model_ident
                    cMqttState
                    sleep 1 # give any MQTT readers an extra second to digest the announcement
                    aAnnounced[$model_ident]=1 # 1=took place, therefor dont reconsider for another announcement
                else
                    : announcement had failed, will be retried again next time
                fi
                if (( nAnnouncedCount > 1999 )) ; then # could be Denial of Service (DoS) attack or malfunction from RF environment 
                    cHassRemoveAnnounce
                    _msg="nAnnouncedCount=$nAnnouncedCount exploded, possibly DENIAL OF SERVICE attack!"
                    log "$_msg" 
                    cMqttLog "{*event*:*exiting*,*message*:*$_msg*}"
                    dbg ENDING "$_msg"
                    exit 11 # will restart the script if systemd configuration allows it (=default for exit code>0 ?)
                fi
            else # not a sensor we like, but something different, e.g. a ...
                cMqttLog "{*event*:*debug*,*message*:*not announced for MQTT discovery (not a sensible sensor): $model_ident*}"
                aAnnounced[$model_ident]=1 # 1 = dont reconsider for announcement
            fi
        fi
        # cPidDelta 4TH

        if (( bEveryMessage || _nSecDelta > nMinSeconds )) || [[ $_IsDiff || $_bAnnounceReady == 1 || ( $fReplayfile && ! $fReplayfile =~ MQTT: )  ]] ; then # rcvd data different from previous reading(s) or some time elapsed
            : "now final rewriting and then publish the reading"
            aPrevReadings[$model_ident]=$data

            if [[ $vTemperature && $nHumidity -gt 0 ]] &&  ! cHasJsonKey "dewpoint"  &&  [[ ${aWuUrls[$model_ident]} || $bRewrite ]] ; then # prepare dewpoint calc, e.g. for weather upload
                cDewpoint "$vTemperature" "$vHumidity" > /dev/null 
                : "vDewptc=$vDewptc, vDewptf=$vDewptf" # were set as side effects
            fi

            if (( bRewrite )) ; then # optimize (rewrite) JSON content
                # FIXME: [[ $_IsDiff || $bVerbose ]] && cAddJsonKeyVal COMPARE "s=$_nSecDelta,$_IsDiff($(longest_common_prefix -s "$sReadPrev" "$data"))"
                cAddJsonKeyVal -b BAND -n dewpoint "$vDewptc" # add dewpoint in front of the BAND key
            fi

            dbg2 "CHECK WUPLOAD" "aWuUrls[$model_ident]=${aWuUrls[$model_ident]} , aMatchIDs[wunderground.$model_ident.$id]=${aMatchIDs[wunderground.$model_ident.$id]} , aMatchIDs[wunderground.$model_ident.]=${aMatchIDs[wunderground.$model_ident.]}"
            # ifVerbose && for key in "${!aMatchIDs[@]}"; do dbg2 UPLOAD "aMatchIDs[$key] = ${aMatchIDs[$key]}" ; done
            # ifVerbose && for key in "${!aWuUrls[@]}"  ; do dbg2 UPLOAD   "aWuUrls[$key] = ${aWuUrls[$key]}"   ; done
            if [[ ${aWuUrls[$model_ident]} && ( ${aMatchIDs[wunderground.$model_ident.$id]} || ${aMatchIDs[wunderground.$model_ident.]} ) ]] ; then # perform any Weather Underground upload
                # wind_speed="10", # precipitation="0"
                [[ $baromin ]] && baromin=$(( $(cMult10 "$(cMult10 "$(cMult10 vPressure_kPa)" )" ) / 3386  )) # 3.3863886666667
                # https://blog.meteodrenthe.nl/2021/12/27/uploading-to-the-weather-underground-api/
                # https://support.weather.com/s/article/PWS-Upload-Protocol
                URL2="${aWuPos[$model_ident]}tempf=$temperatureF${vHumidity:+&${aWuPos[$model_ident]}&humidity=$vHumidity}${baromin:+&baromin=$baromin}${rainin:+&rainin=$rainin}${dailyrainin:+&dailyrainin=$dailyrainin}${vDewptf:+&${aWuPos[$model_ident]}dewptf=$vDewptf}"
                retcurl="$(curl --silent "${aWuUrls[$model_ident]}&$URL2" 2>&1)" && [[ $retcurl == success ]] && nUploads+=1 && aWuLastUploadTime[$model_ident]=$nTimeStamp

                log "WUNDERGROUND" "$URL2: $retcurl (nUploads=$nUploads, device=$model_ident)"
                (( bMoreVerbose )) && log "WUNDERGROUND2" "${aWuUrls[$model_ident]}&$URL2"
            else
                : "aWuUrls[$model_ident] or aMatchIDs[wunderground.$model_ident.$id] | aMatchIDs[wunderground.$model_ident.] are empty"
            fi

            # if [[ ${aWhUrls["OTHER"]} || ( ${aWhUrls[$model_ident]} && ( ${aMatchIDs[whatsapp.$model_ident.$id]} || ${aMatchIDs[whatsapp.$model_ident]} ) ) ]] && 
            #         [[ $bVerbose || ! $vTemperature || $(( ${aCounts[$model_ident]} % 10 )) == 1 ]]; then 
            #     # perform any Whatsapp upload. If with temperature: Only every 10th reading is uploaded, to avoid flooding the Whatsapp channel
            #     URL2="text=$(urlencode "$model_ident: $( cDeleteJsonKeys "id freq rssi" "$data" )")"
            #     [[ -z ${aWhUrls[$model_ident]} ]] && URL1="${aWhUrls["OTHER"]}" || URL1="${aWhUrls[$model_ident]}"
            #     retcurl="$( curl --silent "$sWhatsappBaseUrl?$URL1&$URL2" 2>&1 )"
            #     log "WHATSAPP" "$URL2: $retcurl (device=$model_ident,#${aCounts[${model_ident:-OTHER}]})"
            #     [[ $retcurl =~ You\ will\ receive ]] || log "WHATSAPP2" "$sWhatsappBaseUrl?$URL1&$URL2"
            #     # (( bMoreVerbose )) && log "WHATSAPP" "$URL1&$URL2"
            # else
            #     : "Skipped Whatsapp upload for $model_ident"
            # fi

            if (( bRewrite )) ; then # optimize (rewrite) the JSON content
                # cAddJsonKeyVal -n rssi "$rssi" # put rssi back in
                # FIXME: [[ $_IsDiff || $bVerbose ]] && cAddJsonKeyVal COMPARE "s=$_nSecDelta,$_IsDiff($(longest_common_prefix -s "$sReadPrev" "$data"))"
                ifVerbose && [[ $vDewptc ]] && cAddJsonKeyVal -n DELTADEW "$vDeltaSimple"
                ! [[ $_IsDiff2 ]] && dbg "2ND" "are same."
                ifVerbose && cAddJsonKeyVal -n ORIGTEMP "$vTemperature" && 
                    cAddJsonKeyVal -n NOTE "${_IsDiff:+1ST($_nSecDelta/$nMinSeconds) }${_IsDiff2:+2ND(c=${aCounts[$model_ident]},s=$_nSecDelta/$nMinSeconds,IsDiff3=$_IsDiff3)}" # accept extraneous space

                aSecondPrevReadings[$model_ident]=$sReadPrev
                ifVerbose && cAddJsonKeyVal -n SDELTA "$sDelta"
            fi

            if cMqttStarred "$basetopic/$topicext" "${data//\"/*}" ${bRetained:+ -r} ; then 
                # ... finally: publish the values to the MQTT broker
                nMqttLines+=1
                aLastPub[$model_ident]=$nTimeStamp
                # if not yet nannounced publish to .../unannounced, too
                if (( bAnnounceHass && ! aAnnounced[$model_ident] )) ; then
                    cAddJsonKeyVal -b BEGINNING "SENSOR" "$model_ident"
                    cMqttStarred unannounced "${data//\"/*}"
                    # rtl/bridge/unannounced { "battery_ok":0,"temperature":10.5,"humidity":0.58,"dewpoint":2.5,"BAND":433,
                    #    "DELTADEW":0.4,"ORIGTEMP":10.700,"NOTE":"1ST(79/52) 2ND(c=2,s=79/52,IsDiff3=1)","SDELTA":"0:0"}
                fi
            else
                : "sending had failed: $?"
            fi
        else
            nSuppressedCount+=1
            dbg DUPLICATE "Suppressed duplicate... (total: $nSuppressedCount)"
        fi
    else
        dbg2 DUPLICATE "Suppressed a duplicate.... (total: $nSuppressedCount)"
        nSuppressedCount+=1
    fi
    nReadings=${#aPrevReadings[@]}
    data="" # reset data to "" to cater for read return code <> 0 and an unchanged variable $data
    vDewptc="" ; vDewptf=""
    _bAddIdToTopic="" # reset the flag

    if (( nReadings > nPrevMax )) ; then   # a new max implies that we have a new sensor
        nPrevMax=nReadings
        _sensors="${vTemperature:+*temperature*,}${vHumidity:+*humidity*,}${vPressureKPa:+*pressure_kPa*,}${_bHasBatteryOK:+*battery_ok*,}${_bHasBatteryOKVal:+*battery_ok_VAL*,}${_bHasRain:+*rain*,}"
        cMqttLog "{*event*:*sensor added*,*model*:*$model*,*protocol*:*$protocol*,*id*:$id,*channel*:*$channel*,*description*:*${protocol:+${aProtocols[$protocol]}}*, *sensors*:[${_sensors%,}]}"
        cMqttState
    elif (( nTimeStamp > nLastStatusSeconds+nLogMinutesPeriod*60 || (nMqttLines % nLogMessagesPeriod)==0 )) ; then  # log the status once in a while, good heuristic in a generalized neighbourhood
        _collection="*sensorreadings*:[$(  _comma=""
            for KEY in "${!aPrevReadings[@]}"; do
                _reading=${aPrevReadings["$KEY"]/\{} && _reading=${_reading/\}} # remove leading and trailing braces
                echo -n "$_comma {*model_ident*:*$KEY*,${_reading//\"/*}}"
                _comma=","
            done
        )] "
        log "$(cExpandStarredString "$_collection")" 
        cMqttState "*note*:*regular log*,*collected_sensors*:*${!aPrevReadings[*]}*, $_collection, *cacheddewpoints*:${#aDewpointsCalc[@]}"
        nLastStatusSeconds=nTimeStamp
    elif (( ${#aPrevReadings[@]} > 1000 )) ; then # assume malfunction or a DoS attack from RF env when >1000 different readings have been received
        cMqttState
        cMqttLog "{*event*:*debug*,*message*:*will reset saved values (nReadings=$nReadings,nMqttLines=$nMqttLines,nReceivedCount=$nReceivedCount)*}"
        cEmptyArrays
        nPrevMax=nPrevMax/3            # reduce it quite a bit (but not back to 0) to reduce future log message
        (( bRemoveAnnouncements )) && cHassRemoveAnnounce
    fi
    # dbg ATENDOFLOOP "nReadings=$nReadings, nMqttLines=$nMqttLines, nReceivedCount=$nReceivedCount, nAnnouncedCount=$nAnnouncedCount, nUploads=$nUploads"
done

s=1 && ! [[ $bPlannedTermination ]] && ! [ -t 1 ] && s=30 && (( nLoops < 2 )) && s=180 # will sleep longer on failures or if not running on a terminal to reduce launch storms

_msg="${bPlannedTermination:+Planned termination! }Read rc=$_rc from $(basename "${fReplayfile:-$rtl433_command}") ; $nLoops loops at $(cDate) ; COPROC=:${COPROC_PID:+; last data=$data;}: ; sleep=${s}s"
log "$_msg" 
cMqttLog "{*event*:*endloop*,*host*:*$sHostname*,*message*:*$_msg*}"
dbg ENDING "$_msg"
[[ $fReplayfile ]] && exit 0 # replaying is finished or planned
[[ $bPlannedTermination ]] && sleep 1 && { [ -t 1 ] && exit 0 || exit 15 ; } # normal, planned termination of rtl_433
sleep $s
exit 14 # return 14 only for premature end of rtl_433 command 
# now the exit trap function will be processed...