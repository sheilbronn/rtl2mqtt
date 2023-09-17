#!/bin/bash

# rtl2mqtt reads events from a RTL433 SDR and forwards them to a MQTT broker as enhanced JSON messages 

# Adapted and enhanced for conciseness, verboseness and flexibility by "sheilbronn"
# (inspired by work from "IT-Berater" and M. Verleun)

set -o noglob     # file name globbing is neither needed nor wanted (for security reasons)
set -o noclobber  # also disable for security reasons
# shopt -s lastpipe  # Enable lastpipe
shopt -s assoc_expand_once # might lessen injection risks in bash 5.2+, FIXME: to be verified on bash 5.2

# When extending this script: keep in mind possible attacks from the RF enviroment, e.g. a denial of service :
# a) DoS: Many signals per second > should fail graciously by not beeing able to process them all
# b) DoS: Many (fake) sensors introduced (protocols * possible IDs) > arrays will become huge || inboxes for HASS announcements overflows
#    Simple fix: After 9999 HASS announcements recall all HASS announcements (FIXME), reset all arrays (FIXME'd for all arrays)
# c) exploits for possible rtl_433 decoding errors, transmit out of band values: test all read values for boundary conditions and syntax (e.g. number)

# exit codes: 1,2=installation/configuration errors; 3=.. ; 127=install errors; ; 99=DoS attack from radio environment or rtl_433 bug

sName="${0##*/}" && sName="${sName%.sh}"
sMID="$( basename "${sName// }" .sh )"
sID="$sMID"
rtl2mqtt_optfile="$( [ -r "${XDG_CONFIG_HOME:=$HOME/.config}/$sName" ] && echo "$XDG_CONFIG_HOME/$sName" || echo "$HOME/.$sName" )" # ~/.config/rtl2mqtt or ~/.rtl2mqtt
cDate() { local - ; set +x ; a="$1" ; shift ; printf "%($a)T" "$@"; } # avoid separate process to get the date

commandArgs="$*"
dLog="/var/log/$sMID" # /var/log/rtl2mqtt is default, but will be changed to /tmp if not useable
sSignalsOther="URG XCPU XFSZ PROF WINCH PWR SYS TRAP" # signals that will be ignored
sManufacturer="RTL"
sHassPrefix="homeassistant"
sRtlPrefix="rtl"                        # base topic
sDateFormat="%Y-%m-%d %H:%M:%S" # format needed for OpenHab 3 Date_Time MQTT items - for others OK, too? - as opposed to ISO8601
sDateFormat="%Y-%m-%dT%H:%M:%S" # FIXME: test with T for OpenHAB 4
sStartDate="$(cDate "$sDateFormat")" 
sHostname="$(hostname)"
basetopic=""                  # default MQTT topic prefix
rtl433_command="rtl_433"
rtl433_command=$( command -v $rtl433_command ) || { echo "$sName: $rtl433_command not found..." 1>&2 ; exit 126 ; }
rtl433_version="$( $rtl433_command -V 2>&1 | awk -- '$2 ~ /version/ { print $3 ; exit }' )" || exit 126
declare -a rtl433_opts=( -M protocol -M noise:300 -M level -C si )  # generic options in all settings, e.g. -M level 
# rtl433_opts+=( $( [ -r "$HOME/.$sName" ] && tr -c -d '[:alnum:]_. -' < "$HOME/.$sName" ) ) # FIXME: protect from expansion!
sSuppressAttrs="mic" # attributes that will be always eliminated from JSON msg
sSensorMatch=".*" # any device name to be considered will have to match this regex (to be used during debugging)
sRoundTo=0.5 # temperatures will be rounded to this x and humidity to 4*x (see option -w below)
sWuBaseUrl="https://weatherstation.wunderground.com/weatherstation/updateweatherstation.php" # This is stable for years

# xx=( one "*.log" ) && xx=( "${printf "%($*)T"nlaxx[@]}" ten )  ; for x in "${xx[@]}"  ; do echo "$x" ; done  ;  exit 2

declare -i nHopSecs
declare -i nStatsSec=900
declare    sSuggSampleRate=250k # default fpr rtl_433 is 250k, FIXME: check 1000k seems to be necessary for 868 MHz....
declare    sSuggSampleRate=1000k # default fpr rtl_433 is 250k, FIXME: check 1000k seems to be necessary for 868 MHz....
declare    sSuggSampleModel=auto # -Y auto|classic|minmax
declare -i nLogMinutesPeriod=60 # once per hour
declare -i nLogMessagesPeriod=1000
declare -i nLastStatusSeconds=90
declare -i nMinSecondsOther=5 # only at least every nn seconds
declare -i nMinSecondsWeather=310 # only at least every n*60+10 seconds for unchanged environment data (temperature, humidity)
declare -i nTimeStamp=$(cDate %s)-$nLogMessagesPeriod # initiate with a large sensible assumption....
declare -i nTimeStampPrev
declare -i nTimeMinDelta=300
declare -i nPidDelta
declare -i nHour=0
declare -i nMinute=0
declare -i nSecond=0
declare -i nMqttLines=0     
declare -i nReceivedCount=0
declare -i nAnnouncedCount=0
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
declare -i bLogTempHumidity=1 # 1=log the values (default for now)
declare -i _n # helper integer var
declare -A aWuUrls
declare -A aWuPos
declare -A aDewpointsCalc
declare -a hMqtt

declare -A aPrevReadings # 11 arrays
declare -A aSecondPrevReadings 
declare -Ai aCounts
declare -Ai aAnnounced
declare -A aTemperReadingsTimes
declare -A aTemperReadings
declare -A aEarlierTemperVals10 
declare -Ai aEarlierTemperTime 
declare -Ai aEarlierHumidVals 
declare -Ai aEarlierHumidTime
declare -Ai aLastPub

cEmptyArrays() { # reset the 11 arrays from above
    aPrevReadings=()
    aSecondPrevReadings=()
    aCounts=()
    aAnnounced=()
    aTemperReadingsTimes=()
    aTemperReadings=()
    aEarlierTemperVals10=()
    aEarlierTemperTime=()
    aEarlierHumidVals=()
    aEarlierHumidTime=()
    aLastPub=()
 }

export LANG=C
PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin" # increases security

cJoin() { # join all arguments with a space, but remove any double spaces and any newlines
    local - && set +x
    local _r _val
    for _val in "$@" ; do
        _r="${_r//  / }${_r:+ }${_val//
/ }"
    done
    echo "${_r//  / }"
  }
    
  # set -x ; cJoin "1 
  # 3" " a" ; exit 1

# alias _nx="local - && set +x" # alias to stop local verbosity (within function, not allowed in bash)
# cPid()  { set -x ; printf $BASHPID ; } # get a current PID, support debugging/counting/optimizing number of processes started in within the loop
cPidDelta() { local - ; set +x ; _n=$(printf %s $BASHPID) ; _n=$(( _n - ${_beginPid:=$_n} )) ; dbg PIDDELTA "$1: $_n ($_beginPid) "  ":$data:" ; _beginPid=$(( _beginPid + 1 )) ; nPidDelta=$_n ; }
cPidDelta() { : ; }
cIfJSONNumber() { local - ; set +x ; [[ $1 =~ ^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]] && echo "$1" ; } # FIXME: for floating numbers
# set -x ; cIfJSONNumber 99 && echo ok ; cIfJSONNumber 10.4 && echo ok ; echo ${BASH_REMATCH[0]} ; cIfJSONNumber 10.4x && echo nok ; echo ${BASH_REMATCH[0]} ; exit
cMultiplyTen() { local - ; set +x ; [[ $1 =~ ^([-]?)(0|[1-9][0-9]*)\.([0-9])([0-9]*)$ ]] && { echo "${BASH_REMATCH[1]}${BASH_REMATCH[2]#0}${BASH_REMATCH[3]}" ; } || echo $(( ${1/#./0.} * 10 )) || return 1 ; true ; }
# set -x ; cMultiplyTen -1.16 ; cMultiplyTen -0.800 ; cMultiplyTen 1.234 || echo nok ; cMultiplyTen -3.234 ; cMultiplyTen 66 ; cMultiplyTen .900 ; echo $(( "$(cMultiplyTen "$(cMultiplyTen "$(cMultiplyTen 1012.55)" )" )" / 3386 )) ; exit
# exit
cDiv10() { local - ; set +x ; [[ $1.0 =~ ^([+-]?)([0-9]*)([0-9])(\.[0-9]+)?$ ]] && { v="${BASH_REMATCH[1]}${BASH_REMATCH[2]:-0}.${BASH_REMATCH[3]}" ; echo "${v%.0}" ; } || echo 0 ; }
# set -x ; cDiv10 -1.234 ; cDiv10 12.34 ; cDiv10 -32.34 ; cDiv10 -66 ; cDiv10 66 ; cDiv10 .900 ;  exit
# cTestFalse() { echo aa ; false ; } ; x=$(cTestFalse) && echo 1$x || echo 2$x ; exit 1

log() {
    local - && set +x
    if [[ $sDoLog == dir ]] ; then
        cRotateLogdirSometimes "$dLog"
        logfile="$dLog/$(cDate %H)"
        echo "$(cDate "%d %T")" "$*" >> "$logfile"
        [[ $bVerbose && $* =~ ^\{ ]] && { printf "%s" "$*" ; echo "" ; } >> "$logfile.JSON"
    elif [[ $sDoLog ]] ; then
        echo "$(cDate)" "$@" >> "$dLog.log"
    fi
  }

cLogVal() { # log each value to a single file, args: device,sensor,value
    local - && set +x
    [[ $sDoLog != dir ]] && return
    dSensor="$dLog/$1/$2"
    [ -d $dSensor ] || mkdir -p $dSensor
    fVal="$dSensor/$(cDate %s)" 
    [ -f $fVal ] || echo "$3" > $fVal
    # [ "$(find $dDevice -name .checked -mtime -1)" ] || { find "$dSensor" -xdev -type f -mtime +1 -exec rm '{}' ";" ; touch $dDevice/.checked ; }
    [[ $fVal =~ 7$ ]] && { find $dSensor -xdev -type f -mtime +2 -exec rm '{}' ";" ; } && dbg "INFO" cleaning value log # only remove files older than 1 day when the seconds end in 37...
    return 0
  }

cLogMore() { # log to syslog logging facility, too.
    local - && set +x
    [[ $sDoLog ]] || return
    _level=info
    (( $# > 1 )) && _level="$1" && shift
    echo "$sName: $*" 1>&2
    logger -p "daemon.$_level" -t "$sID" -- "$*"
    log "$@"
  }

dbg() { # output the args to stderr if option bVerbose is set
	local - && set +x
    (( bVerbose )) && { [[ $2 ]] && echo "$1:" "${@:2:$#}" 1>&2 || echo "DEBUG: $1" ; } 1>&2
	}
    # set -x ; dbg ONE TWO || echo ok to fail... ; exit
    # set -x ; bVerbose=1 ; dbg MANY MORE OF IT ; dbg "ALL TOGETHER" ; exit
dbg2() { : ; }  # predefine to do nothing, but allow to redefine it later

cMapFreqToBand() {
    local - && set +x
    [[ $1 =~ ^43  ]] && echo 433 && return
    [[ $1 =~ ^86  ]] && echo 868 && return
    [[ $1 =~ ^91  ]] && echo 915 && return
    [[ $1 =~ ^149 || $1 =~ ^150 ]] && echo 150 && return
    # FIXME: extend for further bands
    }
    # set -x ; cMapFreqToBand 868300000 ; exit

cCheckExit() { # beautify $data and output it, then exit. For debugging purposes.
    json_pp <<< "$data" # "${@:-$data}"
    exit 0
  }
    # set -x ; data='{"one":1}' ; cCheckExit # '{"two":1}' 

cExpandStarredString() {
    _esc="quote_star_quote" ; _str="$1"
    _str="${_str//\"\*\"/$_esc}"  &&  _str="${_str//\"/\'}"  &&  _str="${_str//\*/\"}"  &&  _str="${_str//$esc/\"*\"}"  && echo "$_str"
  }
  # set -x ; cExpandStarredString "${1:+*temperature*,}${1:+ *xhumidity\*,} ${3:+**xbattery**,} ${4:+*rain*,}" ; exit

cRotateLogdirSometimes() {           # check for logfile rotation only with probability of 1/60
    local - && set +x
    if (( nMinute + nSecond == 67 )) && cd "$1" ; then 
        _files="$( find . -xdev -maxdepth 2 -type f -size +500k "!" -name "*.old" -exec mv '{}' '{}'.old ";" -print0 | xargs -0 ;
                find . -xdev -maxdepth 2 -type f -size -250c -mtime +13 -exec rm '{}' ";" -print0 | xargs -0 )"
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
    _topic="${_topic/#\//$basetopic}"
    _arguments=( ${sMID:+-i $sMID} -t "$_topic" -m "$( cExpandStarredString "$_msg" )" "${@:3:$#}" ) # ... append further arguments
    [[ ${#hMqtt[@]} == 0 ]] && mosquitto_pub "${_arguments[@]}"
    for host in "${hMqtt[@]}" ; do
        mosquitto_pub ${host:+-h $host} "${_arguments[@]}"
        _rc=$?
        (( _rc == 0 && ! bEveryBroker )) && return 0 # stop after first successful publishing
    done
    return $_rc
  }

cMqttState() {	# log the state of the rtl bridge
    _ssid="$(iwgetid -r)" # iwgetid might have been aliased to ":" if not available
    _stats="*sensors*:$nReadings,*announceds*:$nAnnouncedCount,*mqttlines*:$nMqttLines,*receiveds*:$nReceivedCount,*cacheddewpoints*:${#aDewpointsCalc[@]},${nUploads:+*wuuploads*:$nUploads,}*lastfreq*:$sBand,*host*:*$sHostname*,*ssid*:*$_ssid*,*startdate*:*$sStartDate*,*lastreception*:*$(date "+$sDateFormat" -d @$nTimeStamp)*,*currtime*:*$(cDate)*"
    log "$_stats"
    cMqttStarred state "{$_stats${1:+,$1}}"
    }

# Parameters for cHassAnnounce: (Home Assistant auto-discovery)
# $1: MQTT "base topic" for states of all the device(s), e.g. "rtl/433" or "ffmuc"
# $2: Generic device model, e.g. a certain temperature device model 
# $3: MQTT "subtopic" for the specific device instance,  e.g. ${model}/${ident}. ("..../set" indicates writeability)
# $4: Text for specific device instance and sensor type info, e.g. "(${ident}) Temp"
# $5: JSON attribute carrying the state
# $6: sensor "class" (e.g. none, temperature, humidity, battery), 
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
	local _command_topic_str="$( [[ $3 != "$_topicpart" ]] && printf ",*cmd_t*:*~/set*" )"  # determined by suffix ".../set"

    local _dev_class="${6#none}" # dont wont "none" as string for dev_class
	local _state_class
    local _sensor=sensor
    local _jsonpath="${5#value_json.}" # && _jsonpath="${_jsonpath//[ \/-]/}"
    local _jsonpath_red="$( echo "$_jsonpath" | tr -d "][ /_-" )" # "${_jsonpath//[ \/_-]/}" # cleaned and reduced, needed in unique id's
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
        dewpoint) _icon_str="thermometer"   ; _unit_str=",*unit_of_measurement*:*\u00b0C*" ; _state_class="measurement" ;;
        setpoint*)	_icon_str="thermometer"     ; _unit_str=",*unit_of_measurement*:*%*"	; _state_class="measurement" ;;
        humidity)	_icon_str="water-percent"   ; _unit_str=",*unit_of_measurement*:*%*"	; _state_class="measurement" ;;
        rain_mm)	_icon_str="weather-rainy"   ; _unit_str=",*unit_of_measurement*:*mm*"	; _state_class="total_increasing" ;;
        pressure_kPa) _icon_str="airballoon-outline" ; _unit_str=",*unit_of_measurement*:*kPa*"	; _state_class="measurement" ;;
        ppm)	    _icon_str="smoke"           ; _unit_str=",*unit_of_measurement*:*ppm*"	; _state_class="measurement" ;;
        density*)	_icon_str="smoke"           ; _unit_str=",*unit_of_measurement*:*ug_m3*"	; _state_class="measurement" ;;
        counter)	_icon_str="counter"         ; _unit_str=",*unit_of_measurement*:*#*"	; _state_class="total_increasing" ;;
		clock)	    _icon_str="clock-outline"   ;;
		signal)	    _icon_str="signal"          ; _unit_str=",*unit_of_measurement*:*%*"	; _state_class="measurement" ;;
        switch)     _icon_str="toggle-switch*"  ; _sensor=switch ;;
        motion)     _icon_str="motion-sensor"   ;;
        button)     _icon_str="gesture-tap-button"  ; _sensor=switch ;;
        dipswitch)  _icon_str="dip-switch" ;;
        code)   _icon_str="lock" ;;
        newbattery) _icon_str="battery-check" ; _unit_str=",*unit_of_measurement*:*#*" ;;
       # battery*)     _unit_str=",*unit_of_measurement*:*B*" ;;  # 1 for "OK" and 0 for "LOW".
        zone)       _icon_str="vector-intersection" ; _unit_str=",*unit_of_measurement*:*#*" ; _state_class="measurement" ;;
        unit)       _icon_str="group"               ; _unit_str=",*unit_of_measurement*:*#*" ; _state_class="measurement" ;;
        learn)      _icon_str="plus"               ; _unit_str=",*unit_of_measurement*:*#*" ; _state_class="total_increasing" ;;
        channel)    _icon_str="format-list-numbered" ; _unit_str=",*unit_of_measurement*:*#*" ; _state_class="measurement" ;;
        voltage)    _icon_str="FIXME" ; _unit_str=",*unit_of_measurement*:*V*" ; _state_class="measurement" ;;
        battery_ok) _icon_str="" ; _unit_str=",*unit_of_measurement*:*#*" ; _state_class="measurement" ; _sensor=measurement ;;
		none)		_icon_str="" ;; 
        *)          cLogMore "Notice: special icon and/or unit not defined for '$6'"
    esac
    _icon_str="${_icon_str:+,*icon*:*mdi:$_icon_str*}"

    local _configtopicpart="$( echo "$3" | tr -d "][ /-" | tr "[:upper:]" "[:lower:]" )"
    local _topic="${sHassPrefix}/$_sensor/${1///}${_configtopicpart}$_jsonpath_red/${6:-none}/config"  # e.g. homeassistant/sensor/rtl433bresser3ch109/{temperature,humidity}/config
          _configtopicpart="${_configtopicpart^[a-z]*}" # uppercase the first letter for readability
    local _device="*device*:{*name*:*$_devname*,*manufacturer*:*$sManufacturer*,*model*:*$2 ${protocol:+(${aNames[$protocol]}) ($protocol) }with id $_devid*,*identifiers*:[*${sID}${_configtopicpart}*],*sw_version*:*rtl_433 $rtl433_version*}"
    local _msg="*name*:*$_channelname*,*~*:*$_sensortopic*,*state_topic*:*~*,$_device,*device_class*:*${6:-none}*,*unique_id*:*${sID}${_configtopicpart}${_jsonpath_red^[a-z]*}*${_unit_str}${_value_template_str}${_command_topic_str}$_icon_str${_state_class:+,*state_class*:*$_state_class*}"
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
    # by esphome:
    # homeassistant/sensor/esp32-wroom-a/living_room_temperature/config 
    #   {dev_cla:"temperature",unit_of_meas:"C",stat_cla:"measurement",name:"Living Room Temperature",
    #    stat_t:"esp32-wroom-a/sensor/living_room_temperature/state",avty_t:"esp32-wroom-a/status",uniq_id:"ESPsensorliving_room_temperature",
    #    dev:{ids:"c8f09ef1bc94",name:"esp32-wroom-a",sw:"esphome v2023.2.4 Mar 11 2023, 16:55:12",mdl:"esp32dev",mf:"espressif"}}
    # homeassistant/sensor/esp32-wroom-a/atc_battery-level/config
    #   {dev_cla:"battery",unit_of_meas:"%",stat_cla:"measurement",name:"ATC Battery-Level",entity_category:"diagnostic",
    #    stat_t:"esp32-wroom-a/sensor/atc_battery-level/state",avty_t:"esp32-wroom-a/status",uniq_id:"ESPsensoratc_battery-level",
    #    dev:{ids:"c8f09ef1bc94",name:"esp32-wroom-a",sw:"esphome v2023.2.4 Mar 11 2023, 16:55:12",mdl:"esp32dev",mf:"espressif"}}

cHassRemoveAnnounce() { # removes ALL previous Home Assistant announcements  
    declare -a _topics=( -t "$sHassPrefix/sensor/#" -t "$sHassPrefix/binary_sensor/#" )
    cLogMore "removing announcements below $sHassPrefix..."
    declare -a _arguments=( ${sMID:+-i "$sMID"} -W 1 "${_topics[@]}" --remove-retained --retained-only )
    [[ ${#hMqtt[@]} == 0 ]]  && mosquitto_sub "${_arguments[@]}"
    for host in "${hMqtt[@]}" ; do
        mosquitto_sub ${host:+-h $host} "${_arguments[@]}"
    done
    _rc=$?
    cMqttStarred log "{*event*:*debug*,*message*:*removed all announcements starting with $sHassPrefix returned $_rc.* }"
    return $?
 }

cAddJsonKeyVal() {  # cAddJsonKeyVal "key" "val" "jsondata" (use $data if $3 is empty, no quotes around numbers)
    local - && set +x
    local _bkey=""
    local _val=""
    [[ $1 == -b ]] && { _bkey="$2" ; shift 2 ; }
    _val="$2" ; _d="${3:-$data}"
    # [ -z "$_val" ] && echo "$_d" # don't append the pair if val is empty !
    # set -x
    [[ $_val =~ ^[+-]?(0|[1-9][0-9]*)(\.[0-9]+)?$ ]] && _valn="$_val" || _valn="\"$_val\"" # surround numeric _val by double quotes if not-a-number
    # if [[ $_d =~ (.*[{,][[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*)(\"[^\"]\"|[+-]?(0|[1-9][0-9]*)(\.[0-9]+)?)$ ]] ; then
    if [[ $_d =~ (.*[{,][[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*)(\"[^\"]*\"|[+-]?(0|[1-9][0-9]*)(\.[0-9]+)?)(.*)$ ]] ; then
        : replace val # FIXME: replacing a val not yet fully implemented amd tested
        _valn="${BASH_REMATCH[1]}$_valn${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
    elif [[ ! $_bkey ]] || ! [[ $_d =~ (.*[{,])([[:space:]]*\"$_bkey\"[[:space:]]*:.*)$ ]] ; then    #  cHasJsonKey $_bkey
        : insert at end
        _valn="${_d/%\}/,\"$1\":$_valn\}}"
    else
        : insert before key
        _valn="${BASH_REMATCH[1]}\"$1\":$_valn,${BASH_REMATCH[2]}" # FIXME: assuming the JSON wasn't empty
    fi
    [[ $3 ]] && echo "$_valn" || data="$_valn"
    # set +x
 }
    # set -x ; data='{"one":1}' ; cAddJsonKeyVal "x" "2x" ; echo $data ; cAddJsonKeyVal "n" "2.3" "$data" ; cAddJsonKeyVal "m" "-" "$data" ; exit 2 # returns: '{one:1,"x":"2"}'
    # set -x ; cAddJsonKeyVal "donot"  ""  '{"one":1}'  ; cAddJsonKeyVal -b one "donot"  ""  '{"zero":0,"one":1}'  ;  exit 2 # returns: '{"one":1,"donot":""}' 
    # set -x ; cAddJsonKeyVal "floati" "5.5" '{"one":1}' ;    exit 2 # returns: '{"one":1,"floati":5.5}'
    # set -x ; cAddJsonKeyVal "one" "5.5" '{"one":1,"two":"xx"}' ; cAddJsonKeyVal "two" "nn" '{"one":1,"two":"xx"}' ;    exit 2 # returns: '{"one":1,"floati":5.5}'

cHasJsonKey() { # simplified check to check whether the JSON ${2:-$data} has key $1 (e.g. "temperat.*e")  (. is for [a-zA-Z0-9])
    local - && set +x
    local _verbose
    [[ $1 == "-v" ]] && _verbose=1 && shift
    [[ ${2:-$data} =~ [{,][[:space:]]*\"(${1//\./[a-zA-Z0-9]})\"[[:space:]]*: ]] || return 1 # return early
    local _k="${BASH_REMATCH[1]}"
    [[  "$1" =~ \*|\[   ]] && echo "$_k" && return 0  # output the first found key only if multiple fits potentially possible
    [[ $_verbose ]] && echo 1
    return 0
 }
    # set -x ; j='{"dewpoint":"null","battery" :100}' ; cHasJsonKey "dewpoi.*" "$j" && echo yes ; cHasJsonKey batter[y] "$j" && echo yes ; cHasJsonKey batt*i "$j" || echo no ; exit
    # set -x ; data='{"dipswitch" :"++---o--+","rbutton":"11R"}' ; cHasJsonKey dipswitch  && echo yes ; cHasJsonKey jessy "$data" || echo no ; exit
    # set -x ; data='{"dipswitch" :"++---o--+","rbutton":"11R"}' ; cHasJsonKey -v dipswitch  && echo yes ; cHasJsonKey jessy "$data" || echo no ; exit

cRemoveQuotesFromNumbers() { # removes double quotes from JSON numbers in $1 or $data
    local - && set +x
    local _d="${1:-$data}"
    while [[ $_d =~ ([,{][[:space:]]*)\"([^\"]*)\"[[:space:]]*:[[:space:]]*\"([+-]?(0|[1-9][0-9]*)(\.[0-9]+)?)\" ]] ; do # 
        # echo "${BASH_REMATCH[0]}  //   ${BASH_REMATCH[1]} //   ${BASH_REMATCH[2]} // ${BASH_REMATCH[3]}"
        _d="${_d/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]}\"${BASH_REMATCH[2]}\":${BASH_REMATCH[3]}"}"
    done
    # _d="$( sed -e 's/: *"\([0-9.-]*\)" *\([,}]\)/:\1\2/g' <<< "${1:-$data}" )" # remove double-quotes around numbers
    [[ $1 ]] && echo "$_d" || data="$_d"
 }
    # set -x ; x='"AA":"+1.1.1","BB":"-2","CC":"+3.55","DD":"-0.44"' ; data="{$x}" ; cRemoveQuotesFromNumbers ; : exit ; echo $data ; cRemoveQuotesFromNumbers "{$x, \"EE\":\"-0.5\"}" ; exit

perfCheck() {
    for (( i=0; i<3; i++))
    do
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
    local - && set +x
    # shopt -s extglob
    local _d="${2:-$data}"
    local k
    local _f
    k="$( cHasJsonKey "$1" "$2" )" && ! [[ $k ]] && k="$1" 
    : debug3 "$k"
    if [[ $k ]] ; then  #       replacing:  jq -r ".$1 // empty" <<< "$_d" :
        if      [[ $_d =~ ([,{])([[:space:]]*\"$k\"[[:space:]]*:[[:space:]]*[0-9.eE+-]+[[:space:]]*)([,}])     ]] || # number: ^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$
                [[ $_d =~ ([,{])([[:space:]]*\"$k\"[[:space:]]*:[[:space:]]*\"[^\"]*\"[[:space:]]*)([,}])   ]] ||  # string
                [[ $_d =~ ([,{])([[:space:]]*\"$k\"[[:space:]]*:[[:space:]]*\[[^\]]*\][[:space:]]*)([,}])   ]] ||  # array
                [[ $_d =~ ([,{])([[:space:]]*\"$k\"[[:space:]]*:[[:space:]]*\{[^\}]*\}[[:space:]]*)([,}])   ]] ; then # curly braces, FIXME: max one level for now
            if [[ ${BASH_REMATCH[3]} == "}" ]] ; then
                _f="${BASH_REMATCH[1]/\{}${BASH_REMATCH[2]}" ; true
            else
                _f="${BASH_REMATCH[2]}${BASH_REMATCH[3]}" ; false
            fi
            _f=${_f/]/\\]} # escaping a closing square bracket in the found match
            _d="${_d/$_f}"
        else :
        fi        
    fi
    # cHasJsonKey "$@" && echo "$_d"
    [[ $2 ]] && echo "$_d" || data="$_d"
 } 
    # set -x ; cDeleteSimpleJsonKey "freq" '{"protocol":73,"id":11,"channel": 1,"battery_ok": 1,"freq":433.903,"temperature": 8,"BAND":433,"NOTE2":"=2nd (#3,_bR=1,260s)"}' ; exit 2
    # set -x ; data='{"one":"a","beta":22.1}' ; cDeleteSimpleJsonKey "one" ; cDeleteSimpleJsonKey beta ; cDeleteSimpleJsonKey two '{"alpha":"a","two":"xx"}' ; exit 2
    # set -x ; cDeleteSimpleJsonKey three '{ "three":"xxx" }' ; exit 2
    # set -x ; data='{"one" : 1,"beta":22}' ; cDeleteSimpleJsonKey one "$data" ; cDeleteSimpleJsonKey two '{"two":-2,"beta":22}' ; cDeleteSimpleJsonKey three '{"three":3.3,"beta":2}' ; exit 2
    # set -x ; data='{"id":2,"channel":2,"battery_ok":0,"temperature_C":-12.5,"freq":433.902,"rssi":-11.295}' ; cDeleteSimpleJsonKey temperature_C ; cDeleteSimpleJsonKey freq ; exit
    # set -x ; data='{"event":"debug","message":{"center_frequency":433910000, "other":"zzzzz"}}' ; cDeleteSimpleJsonKey message ; cCheckExit
    # set -x ; data='{"event":"debug","message":{"center_frequency":433910000, "frequencies":[433910000, 868300000, 433910000, 868300000, 433910000, 915000000], "hop_times":[61]}}' ; cDeleteSimpleJsonKey hop_times ; cDeleteSimpleJsonKey frequencies ; cCheckExit

cDeleteJsonKeys() { # cDeleteJsonKeys "key1 key2" ... "jsondata" (jsondata must be provided)
    local - && set +x   
    # local _d=""
    local _r="${2:-$data}"  #    _r="${*:$#}"
    # dbg "cDeleteJsonKeys $*"
    for k in $1 ; do   #   "${@:1:($#-1)}" ; do
        # k="${k//[^a-zA-Z0-9_ ]}" # only allow alnum chars for attr names for sec reasons
        # _d+=",  .${k// /, .}"  # options with a space are considered multiple options
        for k2 in $k ; do
            _r="$( cDeleteSimpleJsonKey $k2 "$_r" )"
        done
    done
    # _r="$(jq -c "del (${_d#,  })" <<< "${@:$#}")"   # expands to: "del(.xxx, .yyy, ...)"
    [[ $2 ]] && echo "$_r" || data="$_r"
 }
    # set -x ; cDeleteJsonKeys 'time mic' '{"time" : "2022-10-18 16:57:47", "protocol" : 19, "model" : "Nexus-TH", "id" : 240, "channel" : 1, "battery_ok" : 1, "temperature_C" : 21.600, "humidity" : 20}' ; exit 1
    # set -x ; cDeleteJsonKeys "one" "two" ".four five six" "*_special*" '{"one":"1", "two":2  ,"three":3,"four":"4", "five":5, "_special":"*?+","_special2":"aa*?+bb"}'  ;  exit 1
    # results in: {"three":3,"_special2":"aa*?+bb"}

cComplexExtractJsonVal() {
    local - && : set -x
    cHasJsonKey "$1" && jq -r ".$1 // empty" <<< "${2:-$data}"
 }
    # set -x ; data='{"action":"good","battery":100}' ; cComplexExtractJsonVal action && echo yes ; cComplexExtractJsonVal notthere || echo no ; exit

cExtractJsonVal() { # replacement for:  jq -r ".$1 // empty" <<< "${2:-$data}" , avoid spawning jq for performance reasons
    local - && set +x
    [[ ${2:-$data} ]] || return 1
    if [[ ${2:-$data} ]] && cHasJsonKey "$1" ; then 
        if [[ ${2:-$data} =~ [,{][[:space:]]*(\"$1\")[[:space:]]*:[[:space:]]*\"([^\"]*)\"[[:space:]]*[,}] ]] ||  # string
                [[ ${2:-$data} =~ [,{][[:space:]]*(\"$1\")[[:space:]]*:[[:space:]]*([+-]?(0|[1-9][0-9]*)(\.[0-9]+)?)[[:space:]]*[,}] ]] ; then # number 
            echo "${BASH_REMATCH[2]}"
        fi        
    else false ; fi # return error, e.g. if key not found
  }
  # set -x ; data='{ "action":"good" , "battery":99.5}' ; cPidDelta 000 && cPidDelta 111 ; cExtractJsonVal action ; cPidDelta 222 ; cExtractJsonVal battery && echo yes ; cExtractJsonVal notthere || echo no ; exit

cAssureJsonVal() {
    cHasJsonKey "$1" &&  jq -er "if (.$1 ${2:+and .$1 $2} ) then 1 else empty end" <<< "${3:-$data}"
 }
    # set -x ; data='{"action":"null","battery":100}' ; cAssureJsonVal battery ">999" ; cAssureJsonVal battery ">9" ;  exit

longest_common_prefix() { # variant of https://stackoverflow.com/a/6974992/18155847
  [[ $1 == "-s" ]] && shift && set -- "${1// }" "${2// }" # remove all spaces before comparing
  local prefix=""  n=0
  ((${#1}>${#2})) &&  set -- "${1:0:${#2}}" "$2"  ||   set -- "$1" "${2:0:${#1}}" ## Truncate the two strings to the minimum of their lengths
  orig1="$1" ; orig2="$2"

  ## Binary search for the first differing character, accumulating the common prefix
  while (( ${#1} > 1 )) ; do
    n=$(( (${#1}+1)/2 ))
    if [[ ${1:0:$n} == "${2:0:$n}" ]]; then
      prefix=$prefix${1:0:$n}
      set -- "${1:$n}" "${2:$n}"
    else
      set -- "${1:0:$n}" "${2:0:$n}"
    fi
  done
  ## Add the one remaining character, if common
  if [[ $1 = "$2" ]]; then prefix=$prefix$1; fi
  # echo "$prefix"
  cMqttStarred log "{*event*:*compare*,*prefix*:*$prefix*,*one*:*$orig1*,*two*:*$orig2*}"

  [[ -z $prefix ]] && echo 0 && return 255
  [[ ${#prefix} -eq ${#orig1} ]] && echo 999 && return 0
  echo ${#prefix} && return ${#prefix}
 }
    # set -x ; longest_common_prefix abc4567 abc123 && echo yes ; echo ===== ; longest_common_prefix def def && echo jaa ; exit 1

cEqualJson() {   # cEqualJson "json1" "json2" "attributes to be ignored" '{"action":"null","battery":100}'
    local - && set +x
    local _s1="$1" ; _s2="$2"
    if [[ $3 ]] ; then
        _s1="$( cDeleteJsonKeys "$3" "$_s1" )"
        _s2="$( cDeleteJsonKeys "$3" "$_s2" )"
    fi
    [[ $_s1 == "$_s2" ]] # return code is comparison value
 }
    # set -x ; data1='{"act":"one","batt":100}' ; data2='{"act":"two","batt":100}' ; cEqualJson "$data1" "$data1" && echo AAA; cEqualJson "$data1" "$data2" || echo BBB; cEqualJson "$data1" "$data1" "act other" && echo CCC; exit
    # set -x ; data1='{ "id":35, "channel":3, "battery_ok":1, "freq":433.918,"temperature":22,"humidity":60,"dewpoint":13.9,"BAND":433}' ; data2='{ "id":35, "channel":3, "battery_ok":1, "freq":433.918,"temperature":22,"humidity":60,"BAND":433}' ; cEqualJson "$data1" "$data2" && echo AAA; cEqualJson "$data1" "$data2" || echo BBB; cEqualJson "$data1" "$data2" "freq" && echo CCC; exit
    # set -x ; data1='{ "temperature":22,"humidity":60,"BAND":433}' ; data2='{ "temperature":22,"humidity":60,"BAND":433}' ; cEqualJson "$data1" "$data2" && echo AAA; cEqualJson "$data1" "$data2" || echo BBB; cEqualJson "$data1" "$data2" "freq" && echo CCC; exit

cDewpoint() { # calculate a dewpoint from temp/humid/pressure and cache the result; side effect: set vDewptc, vDewptf, vDewSimple
    local _temperature=$( cDiv10 $(cMultiplyTen $1) ) _rh=${2/.[0-9]*} - _rc=0 && set +x 
    
    if [[ ${aDewpointsCalc[$_temperature;$_rh]} ]] ; then # check for precalculated, cached values
        IFS=";" read -r vDewptc vDewptf _n _rest <<< "${aDewpointsCalc[$_temperature;$_rh]}"
        (( bVerbose     )) && aDewpointsCalc[$_temperature;$_rh]="$vDewptc;$vDewptf;$(( _n+1 )); $_rest"
        dbg2 DEWPOINT "CACHED: aDewpointsCalc[$_temperature;$_rh]=${aDewpointsCalc[$_temperature;$_rh]} (${#aDewpointsCalc[@]})"
    else
        : "calculate dewpoint values for ($_temperature,$_rh)" # ignoring any barometric pressure for now
        _ad=0 ; limh=${limh:-52} ; div=${div:-5} ; (( $_rh < $limh )) && _ad=$(( 10 * ($limh - $_rh) / $div  )) # reduce by 12 at 16% (50-16=34)
        vDewSimple=$( cDiv10 $(( $(cMultiplyTen $_temperature) - 200 + 10 * _rh / 5 - _ad )) )   #  temp - ((100-hum)/5), when humid>50 and 0°<temp<30°C
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
        if (( ${#aDewpointsCalc[@]} > 1999 )) ; then # maybe out-of-memory DoS attack from radio environment
            declare -p aDewpointsCalc | xargs -n1 | tail +3 > "/tmp/$sID.$USER.$( cDate %d )" # FIXME: for debugging
            aDewpointsCalc=() && log "DEWPOINT: RESTARTED dewpoint caching."
        fi
    fi
    echo "$vDewptc" "$vDewptf" 
    (( _rc != 0 )) && return $_rc
    [[ $bRewrite && $vDewptc != 0 ]] && vDewptc=$( cRound "$(cMultiplyTen $vDewptc)" ) #  reduce flicker in dewpoint as in temperature reading
    [[ $vDewptc && $vDewptf && $vDewptc != "+nan" && $vDewptf != "+nan" ]]  # determine any other return value of the function
    }
    # set -x ; bVerbose=1 ; cDewpoint 11.2 100 ; echo "rc is $? ($vDewSimple,$_dewpointcalc)" ; cDewpoint 18.4 50 ; echo "rc is $? ($vDewSimple,$_dewpointcalc)" ; cDewpoint 18.4 20 ; echo "rc is $? ($_dewpointcalc)" ; cDewpoint 11 -2 ; echo "rc is $? ($_dewpointcalc)"; exit 1
    # set -x ; bVerbose=1 ; cDewpoint 25 30 ; echo "$vDewSimple , $_dewpointcalc)" ; cDewpoint 20 40 ; echo "$vDewSimple , $_dewpointcalc)" ; cDewpoint 14 45 ; echo "$vDewSimple , $_dewpointcalc)" ; exit 1
    # set -x ; bVerbose=1 ; for h in $(seq 70 -5 20) ; do cDewpoint 30 $h ; echo "$vDewSimple , $_dewpointcalc ========" ; done ; exit 1

cDewpointTable() {
    declare -An aDewpointsDeltas
    # 52 5 are best for -10..45°C and 10..70% humidity (emphasizing: 20-45° and 40-70%), when compared to the Antoine formula
    for limh in {51..54..1} ; do # {51..54..1}
        for div in  {3..6..1} ; do # {3..6..1} 
            unset aDewpointsCalc && declare -A aDewpointsCalc
            for temp in {-10..45..4} {20..45..6} ; do # {-10..45..4} {20..45..6}
                for hum in {20..70..5} {40..70..10} ; do # {20..70..5} {40..70..10}
                    cDewpoint $temp $hum > /dev/null
                    nDeltaAbs=$(cMultiplyTen $vDeltaSimple) ; nDeltaAbs=${nDeltaAbs#-}
                    sum=$(( sum + nDeltaAbs * nDeltaAbs))
                    # printf "%3s %3s %5s %5s %4s %5s\n" $temp $hum $vDewptc $vDewSimple $vDeltaSimple $sum
                done
            done
            echo "$limh $div $sum"
            aDewpointsDeltas[$limh,$div]="$sum"
            sum=0
            # echo ====================================================================================
        done
    done
 }
 # cDewpointTable ; exit 2

cRound() {
    local - _val ; set +x # $1 has to be 10-times larger! 
    _val=$(( ( $1 + sRoundTo*${2:-1}/2 ) / (sRoundTo*${2:-1}) * (sRoundTo*${2:-1}) ))
    echo "$( cDiv10 $_val )" # FIXME: not correct for negative numbers
    }
    # set -x ; sRoundTo=5 ; cRound -7 ; cRound 7 ; cRound 14 ; echo "should have been 0.5 and 1.5" ; exit 1

[ -r "$rtl2mqtt_optfile" ] && _moreopts="$( sed -e 's/#.*//'  < "$rtl2mqtt_optfile" | tr -c -d '[:space:][:alnum:]_., -' | uniq )" && dbg "Read _moreopts from $rtl2mqtt_optfile"

[[ $* =~ -F\ [0-9]* ]] && _moreopts="${_moreopts//-F [0-9][0-9][0-9]}"  && _moreopts="${_moreopts//-F [0-9][0-9]}" # one or more -F on the command line invalidate any other -F options from the config file
[[ $* =~ '-R ++'    ]] && _moreopts="${_moreopts//-R -[0-9][0-9][0-9]}" && _moreopts="${_moreopts//-R -[0-9][0-9]}" # -R ++ on command line removes any protocol excludes
[[ $* =~ '-v'      ]] && _moreopts="${_moreopts//-v}" # -v on command line restarts gathering -v options
cLogMore "Gathered options: $_moreopts $*"

while getopts "?qh:pPt:S:drLl:f:F:M:H:AR:Y:iw:c:as:S:W:t:T:29vx" opt $_moreopts "$@"
do
    case "$opt" in
    \?) echo "Usage: $sName -h brokerhost -t basetopic -p -r -r -d -l -a -e [-F freq] [-f file] -q -v -x [-w n.m] [-W station,key,device] " 1>&2
        exit 1
        ;;
    q)  bQuiet=1
        ;;
    h)  # configure the broker host here or in $HOME/.config/mosquitto_sub
        case "$OPTARG" in     #  http://www.steves-internet-guide.com/mqtt-hosting-brokers-and-servers/
		test|mosquitto) mqtthost="test.mosquitto.org" ;; # abbreviation
		eclipse)        mqtthost="mqtt.eclipseprojects.io"   ;; # abbreviation
        hivemq)         mqtthost="broker.hivemq.com"   ;;
		*)              mqtthost="$( echo "$OPTARG" | tr -c -d '0-9a-z_.' )" ;; # clean up for sec purposes
		esac
   		hMqtt+=( "$([[ ! "${hMqtt[*]}" =~ "$mqtthost"  ]] && echo "$mqtthost")" ) # gather them, but no duplicates
        # echo "${hMqtt[*]}"
        ;;
    p)  bAnnounceHass=1
        ;;
    P)  bRetained=1
        ;;
    t)  basetopic="$OPTARG" # choose another base topic for MQTT
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
    l)  dLog="$OPTARG" 
        ;;
    f)  fReplayfile="$( [[ $OPTARG = "-" || $OPTARG = /dev/stdin ]] && echo /dev/stdin || readlink -f "$OPTARG" )" # file to replay (e.g. for debugging), instead of rtl_433 output
        dbg2 INFO "fReplayfile: $fReplayfile"
        nMinSecondsOther=0
        nMinOccurences=1
        ;;
    w)  sRoundTo="$OPTARG" # round temperature to this value and relative humidity to 4-times this value (_hMult)
        ;;
    F)  if   [[ $OPTARG == "868" ]] ; then
            rtl433_opts+=( -f 868.3M ${sSuggSampleRate:+-s $sSuggSampleRate} -Y $sSuggSampleModel ) # last tried: -Y minmax, also -Y autolevel -Y squelch   ,  frequency 868... MhZ - -s 1024k
        elif [[ $OPTARG == "915" ]] ; then
            rtl433_opts+=( -f 915M ${sSuggSampleRate:+-s $sSuggSampleRate} -Y $sSuggSampleModel ) 
        elif [[ $OPTARG == "27" ]] ; then
            rtl433_opts+=( -f 27.161M ${sSuggSampleRate:+-s $sSuggSampleRate} -Y $sSuggSampleModel )  
        elif [[ $OPTARG == "150" ]] ; then
            rtl433_opts+=( -f 150.0M ) 
        elif [[ $OPTARG == "433" ]] ; then
            rtl433_opts+=( -f 433.91M ) #  -s 256k -f 433.92M for frequency 433... MhZ
        elif [[ $OPTARG =~ "[1-9]" ]] ; then # if the option start with a number, assume it's a frequency
            rtl433_opts+=( -f "$OPTARG" )
        else                             # interpret it as a -F option to rtl_433 otherwise
            rtl433_opts+=( -F "$OPTARG" )
        fi
        basetopic="$sRtlPrefix/$OPTARG"
        nHopSecs=${nHopSecs:-61} # (60/2)+11 or 60+1 or 60+21 or 7, i.e. should be a proper coprime to 60sec
        nStatsSec="5*(nHopSecs-1)"
        ;;
    M)  rtl433_opts+=( -M "$OPTARG" )
        ;;
    H)  nHopSecs="$OPTARG"
        ;;
    A)  rtl433_opts+=( -A )
        ;;
    R)  [[ $OPTARG == "++" ]] && { dbg "INFO" "Ignoring any protocol excludes from config file" ; continue ; }
        rtl433_opts+=( -R "$OPTARG" )
        [[ ${OPTARG:0:1} != "-" ]] && dbg "WARNING" "Are you sure you didn't want to exclude protocol $OPTARG?!"
        ;;
    Y)  rtl433_opts+=( -Y "$OPTARG" )
        sSuggSampleModel="$OPTARG"
        ;;
    i)  bAddIdToTopic=1 
        ;;
    c)  nMinOccurences=$OPTARG # MQTT announcements only after at least $nMinOccurences occurences...
        ;;
    T)  nMinSecondsOther=$OPTARG # seconds before repeating the same (unchanged) reading
        ;;
    a)  bAlways=1
        nMinOccurences=1
        ;;
    s)  sSuggSampleRate="$( tr -c -d '[:alnum:]' <<< "$OPTARG" )"
        ;;
    W)  command -v curl > /dev/null || { echo "$sName: curl not installed, but needed for uploading Wunderground data ..." 1>&2 ; exit 126 ; }
        IFS=',' read -r _id _key _sensor _indoor <<< "$OPTARG"  # Syntax e.g.: -W <Station-ID>,<-Station-KEY>,Bresser-3CH_1m,{indoor|outdoor}
        [[ $_indoor ]] || { echo "$sName: -W $OPTARG doesn't have three comma-separated values..." 1>&2 ; exit 2 ; }
        aWuUrls[$_sensor]="$sWuBaseUrl?ID=$_id&PASSWORD=$_key&action=updateraw&dateutc=now"
        [[ $_indoor = indoor ]] && aWuPos[$_sensor]="indoor" # add this prefix to temperature key id
        _key=""
        dbg "Will upload data for device $_sensor as station ID $_id to Weather Underground..." 
        ((bVerbose)) && echo "Upload data for $_sensor as station $_id ..."
        ;;
    2)  bTryAlternate=1 # ease coding experiments (not to be used in production)
        ;;
    9)  bEveryBroker=1 # send to every mentioned broker
        ;;
    v)  if (( bVerbose )) ; then
            bMoreVerbose=1 && rtl433_opts=( "-M noise:60" "${rtl433_opts[@]}" -v )
            dbg2() { local - ; set +x ; (( bMoreVerbose)) && dbg "$@" ; }
        else
            bVerbose=1
            nTimeMinDelta=$(( nTimeMinDelta / 2 ))
            # shopt -s lastpipe  # FIXME: test lastpipe thoroughly
        fi
        ;;
    x)  set -x # turn on shell command tracing from here on
        ;;
    esac
done

shift $((OPTIND-1))   # Discard the options processed by getopts, any remaining options will be passed to mosquitto_pub further down on

rtl433_opts+=( ${nHopSecs:+-H $nHopSecs -v} ${nStatsSec:+-M stats:1:$nStatsSec} )
sRoundTo="$( cMultiplyTen "$sRoundTo" )"

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
# set -x ; cLogMore info "test test" ; exit 2

# command -v jq > /dev/null || { _msg="$sName: jq might be necessary!" ; log "$_msg" ; echo "$_msg" 1>&2 ; }
command -v iwgetid > /dev/null || { _msg="$sName: iwgetid not found" ; log "$_msg" ; echo "$_msg" 1>&2 ; alias iwgetid : ; }

if [[ $fReplayfile ]]; then
    sBand="${fReplayfile##*/}" ; sBand="${sBand%%_*}"
else
    _output="$( $rtl433_command "${rtl433_opts[@]}" -T 1 2>&1 )"
    # echo "$_output" ; exit
    sdr_tuner="$(  awk -- '/^Found /   { print gensub("Found ", "",1, gensub(" tuner$", "",1,$0)) ; exit}' <<< "$_output" )" # matches "Found Fitipower FC0013 tuner"
    sdr_freq="$(   awk -- '/^Tuned to/ { print gensub("MHz.", "",1,$3)                            ; exit}' <<< "$_output" )" # matches "Tuned to 433.900MHz."
    conf_files="$( awk -F \" -- '/^Trying conf/ { print $2 }' <<< "$_output" | xargs ls -1 2>/dev/null )" # try to find an existing config file
    sBand="$( cMapFreqToBand "$(cExtractJsonVal sdr_freq)" )"
fi
basetopic="$sRtlPrefix/$sBand" # intial setting for basetopic

# Enumerate the supported protocols and their names, put them into array aNames:
# Here a sample: 
# ...
# [215]  Altronics X7064 temperature and humidity device
# [216]* ANT and ANT+ devices
declare -A aNames
while read -r num name ; do 
    [[ $num =~ ^\[([0-9]+)\]\*?$ ]] && aNames+=( [${BASH_REMATCH[1]}]="$name" )
done < <( $rtl433_command -R 99999 2>&1 )

cEchoIfNotDuplicate() {
    local - && set +x
    if [ "$1..$2" != "$gPrevData" ] ; then
        # (( bWasDuplicate )) && echo -e "\n" # echo a newline after some dots
        echo -e "$1${2:+\n$2}"
        gPrevData="$1..$2" # save the previous data
        bWasDuplicate=""
    else
        printf "."
        bWasDuplicate=1
    fi
 }

(( bAnnounceHass )) && cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/log  "LogMessage"  ""  none
_info="*host*:*$sHostname*,*tuner*:*$sdr_tuner*,*freq*:$sdr_freq,*additional_rtl433_opts*:*${rtl433_opts[*]}*,*logto*:*$dLog ($sDoLog)*,*rewrite*:*${bRewrite:-no}${bRewriteMore:-no}*,*nMinOccurences*:$nMinOccurences,*nMinSecondsWeather*:$nMinSecondsWeather,*nMinSecondsOther*:$nMinSecondsOther,*sRoundTo*:$sRoundTo"
if [ -t 1 ] ; then # probably running on a terminal
    log "$sName starting at $(cDate)"
    cMqttStarred log "{*event*:*starting*,$_info}"
else               # probably non-terminal
    delayedStartSecs=3
    log "$sName starting in $delayedStartSecs secs from $(cDate)"
    sleep "$delayedStartSecs"
    cMqttStarred log "{*event*:*starting*,$_info,*message*:*delayed by $delayedStartSecs secs*,*sw_version*=*$rtl433_version*,*user*:*$( id -nu )*,*cmdargs*:*$commandArgs*}"
fi

# Optionally remove any matching retained announcements
(( bRemoveAnnouncements )) && cHassRemoveAnnounce

trap_exit() {   # stuff to do when exiting
    local exit_code=$? # must be first command in exit trap
    local - && set +x;
    cLogMore "$sName exit trap at $(cDate): removeAnnouncements=$bRemoveAnnouncements. Will also log state..."
    (( bRemoveAnnouncements )) && cHassRemoveAnnounce
    [[ $_pidrtl ]] && _pmsg="$( ps -f "$_pidrtl" | tail -1 )"
    (( COPROC_PID )) && _cppid="$COPROC_PID" && kill "$COPROC_PID" && { # avoid race condition after killing coproc
        wait "$_cppid" # Cleanup, may  fail on purpose
        dbg "Killed coproc PID $_cppid and awaited rc=$?"    
    }
    nReadings=${#aPrevReadings[@]}
    cMqttState "*note*:*trap exit*,*exit_code*:$exit_code, *collected_sensors*:*${!aPrevReadings[*]}*"
    cMqttStarred log "{*event*:*$( [[ $fReplayfile ]] && echo info || echo warning )*, *host*:*$sHostname*, *exit_code*:$exit_code, *message*:*Exiting${fReplayfile:+ after reading from $fReplayfile}...*}${_pidrtl:+ procinfo=$_pmsg}"
    # logger -p daemon.err -t "$sID" -- "Exiting trap_exit."
    # rm -f "$conf_file" # remove a created pseudo-conf file if any
 }
trap 'trap_exit' EXIT 

trap '' INT USR1 USR2 VTALRM

if [[ $fReplayfile ]] ; then
    coproc COPROC ( 
        shopt -s extglob ; export IFS=' '
        while read -r line ; do 
            : "line $line" #  e.g.   103256 rtl/433/Ambientweather-F007TH/1 { "protocol":20,"id":44,"channel":1,"freq":433.903,"temperature":19,"humidity":62,"BAND":433,"HOUR":16,"NOTE":"changed"}
            : "FRONT ${line%%{+(?)}" 1>&2
            data="${line##*([!{])}" # data starts with first curly bracket...
            read -r -a aFront <<< "${line%%{+(?)}" # remove anything before an opening curly brace from the line read from the replay file
            if ! cHasJsonKey model && ! cHasJsonKey since ; then # ... then try to determine "model" either from an MQTT topic or from the file name, but not from JSON with key "since"
                : frontpart="${aFront[-1]}"
                IFS='/' read -r -a aTopic <<< "${aFront[-1]}" # MQTT topic might be preceded by timestamps that are to be removed
                [[ ${aTopic[0]} == rtl && ${#aTopic[@]} -gt 2 ]] && {
                    sBand="${aTopic[1]}" # extract freq band from topic if non given in message
                    sModel="${aTopic[2]}" # extract model from topic if non given in message
                }
                if ! [[ $sModel ]] ; then # if still not found ...
                    IFS="_" read -r -a aTopic <<< "${fReplayfile##*/}" # .. try to determine from the filename, e.g. "433_IBIS-Beacon_5577"
                    sBand="${aTopic[0]}"
                    sModel="${aTopic[1]}"
                fi
                cAddJsonKeyVal model "${sModel:-UNKNOWN}"
                cAddJsonKeyVal BAND "${sBand:-null}" 
            fi
            echo "$data" # ; echo "EMITTING: $data" 1>&2
            sleep 1
        done < "$fReplayfile" ; sleep 5 ; # echo "COPROC EXITING." 1>&2
    )  
else
    if [[ $bVerbose || -t 1 ]] ; then
        cLogMore "rtl_433 ${rtl433_opts[*]}"
        (( nMinOccurences > 1 )) && cLogMore "Will do MQTT announcements only after at least $nMinOccurences occurences..."
    fi 
    # Start the RTL433 listener as a bash coprocess ... # https://unix.stackexchange.com/questions/459367/using-shell-variables-for-command-options
    coproc COPROC ( trap '' SYS VTALRM TRAP $sSignalsOther ; $rtl433_command ${conf_file:+-c "$conf_file"} "${rtl433_opts[@]}" -F json,v=8 2>&1 ; rc=$? ; sleep 3 ; exit $rc )
    # -F "mqtt://$mqtthost:1883,events,devices"

    sleep 1 # wait for rtl_433 to start up...
    _pidrtl="$( pidof "$rtl433_command" )" # hack to find the process of the rtl_433 command
    # _pgrp="$(ps -o pgrp= ${COPROC_PID})"
    [[ $_pidrtl ]] && _ppid="$( ps -o ppid= "$_pidrtl" )" &&  _pgrp="$( ps -o pgrp= "$_pidrtl" )"
    # renice -n 15 "${COPROC_PID}" > /dev/null
    # renice -n 17 -g "$_pgrp" # > /dev/null
    _msg="COPROC_PID=$COPROC_PID, pgrp=$_pgrp, ppid=$_ppid, pid=$_pidrtl"
    dbg2 PID "$_msg"
    if (( _ppid == COPROC_PID  )) ; then
        renice -n 12 "$_pidrtl" > /dev/null 
        cMqttStarred log "{*event*:*debug*,*host*:*$sHostname*,*message*:*rtl_433 start: $_msg*}"

        if (( bAnnounceHass )) ; then
            ## cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "TestVal" "value_json.mcheck" "mcheck"
            cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "AnnouncedCount" "value_json.announceds" "counter" &&
            cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "SensorCount"    "value_json.sensors"   "counter"   &&
            cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "MqttLineCount"  "value_json.mqttlines" "counter"  &&
            cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "ReadingsCount"  "value_json.receiveds" "counter"  &&
            cHassAnnounce "$sRtlPrefix" "Rtl433 Bridge" bridge/state "Start date"     "value_json.startdate" "clock"    &&
            nRC=$?
            (( nRC != 0 )) && echo "ERROR: HASS Announcements failed with rc=$nRC" 1>&2
            sleep 1
        fi
    else
        cLogMore "start of $rtl433_command failed: $_msg"
        cMqttStarred log "{*event*:*startfailed*,*host*:*$sHostname*,*message*:*$rtl433_command ended fast: $_msg*}"
    fi
fi 

# now install further signal handlers

trap_int() {    # log all collected sensors to MQTT
    trap '' INT 
    log "$sName signal INT: logging state to MQTT"
    cMqttStarred log "{*event*:*debug*,*message*:*Signal INT, will emit state message* }"
    cMqttState "*note*:*trap INT*,*collected_sensors*:*${!aPrevReadings[*]}* }" # FIXME: does it still work
    nLastStatusSeconds=$(cDate %s) 
    [[ $fReplayfile ]] && exit 0 || trap 'trap_int' INT 
 }
trap 'trap_int' INT 

trap_usr1() {    # toggle verbosity 
    # ORIG: (( bVerbose )) && bVerbose="" || bVerbose=1 # switch bVerbose
    bVerbose=$( ((bVerbose)) || echo 1 ) # toggle verbosity 
    _msg="Signal USR1: toggled verbosity to ${bVerbose:-none}, nHopSecs=$nHopSecs, sBand=$sBand"
    log "$sName $_msg"
    cMqttStarred log "{*event*:*debug*,*host*:*$sHostname*,*message*:*$_msg*}"
  }
trap 'trap_usr1' USR1

trap_usr2() {    # remove all home assistant announcements (CAREFUL!)
    cHassRemoveAnnounce
    _msg="Signal USR2: resetting all home assistant announcements"
    log "$sName $_msg"
    cMqttStarred log "{*event*:*debug*,*message*:*$_msg*}"
  }
trap 'trap_usr2' USR2 

trap_vtalrm() { # re-emit all recorded sensor readings (e.g. for debugging purposes)
    for KEY in "${!aDewpointsCalc[@]}" ; do
        _val="${aDewpointsCalc["$KEY"]}"
        _msg="{*key*:*$KEY*,*values*:*${_val//\"/*}*}"
        dbg DEWPOINT "$KEY  $_msg"
        cMqttStarred dewpoint "$_msg"
    done

   _msg="$( declare -p | awk '$0 ~ "^declare -A" && $3 ~ "^a" { printf(" %s*%s(%s)*:%d" , sep, gensub("=.*","",1,$3), gensub("-","",1,$2), gsub("]=","") ) ; sep="," }' )" # all arrays
    dbg ARRAYS "$_msg"
    cMqttStarred arrays "[$_msg]"

    for KEY in "${!aPrevReadings[@]}" ; do
        _val="${aPrevReadings["$KEY"]}" && _val="${_val/\{}" && _val="${_val/\}}"
        _msg="{*model_ident*:*$KEY*,${_val//\"/*} , *COUNT*:${aCounts["$KEY"]}}"
        dbg READING "$KEY  $_msg"
        cMqttStarred reading "$_msg"
    done

    if ((bVerbose)) && false ; then
        for KEY in $( declare -p | awk '$0 ~ "^declare -A" && $3 ~ "^a" { print gensub("=.*","",1,$3) }' ) ; do
            _val="$( declare -p "$KEY" | cut -d= -f2- | tr -c -d "=" | wc -c )"
            _msg="$msg, $KEY()"
            dbg ARRAY "$_msg"
            cMqttStarred array "$_msg"
        done
    fi

    _msg="Signal VTALRM: logged last MQTT messages from ${#aPrevReadings[@]} sensors and ${#aDewpointsCalc[@]} calculations."
    log "$sName $_msg"
    cMqttStarred log "{*event*:*debug*,*message*:*$_msg*}"
    cMqttState
    declare -i _delta=$(cDate %s)-nTimeStamp
    if (( _delta > 10800 )) ; then # no radio event has been received for more than 3 hours, will restart...
        cMqttStarred log "{*event*:*exiting*,*message*:*no radio event received for $((_delta/60)) minutes, assuming fail*}"
        exit 12 # possibly restart whole script, if systemd allows it
    fi
  }
trap "trap_vtalrm" VTALRM

trap_other() {
    _msg="received other signal ..."
    log "$sName $_msg"
    cMqttStarred log "{*event*:*debug*,*message*:*$_msg*}"
  }
trap 'trap_other' $sSignalsOther # STOP TSTP CONT HUP QUIT ABRT PIPE TERM

while read -r data <&"${COPROC[0]}" ; _rc=$? ; (( _rc==0  || _rc==27 || ( bVerbose && _rc==1111 ) ))      # ... and go through the loop
do
    # FIXME: data should be cleaned from any suspicous characters sequences as early as possible for security reasons - an extra jq invocation might be worth this...

    # (( _rc==1 )) && cMqttStarred log "{*event*:*warn*,*message*:*read _rc=$_rc, data=$data*}" && sleep 2  # quick hack to slow down and debug fast loops
    # dbg ATBEGINOFLOOP "nReadings=$nReadings, nMqttLines=$nMqttLines, nReceivedCount=$nReceivedCount, nAnnouncedCount=$nAnnouncedCount, nUploads=$nUploads"

    _beginPid="" # support debugging/counting/optimizing number of processes started in within the loop

    nLoops+=1
    # dbg 000
    if [[ $data =~ ^SDR:.Tuned.to.([0-9]*\.[0-9]*)MHz ]] ; then # SDR: Tuned to 868.300MHz.
        # convert  msg type "SDR: Tuned to 868.300MHz." to "{"center_frequency":868300000}" (JSON) to be processed further down
        data="{\"center_frequency\":${BASH_REMATCH[1]}${BASH_REMATCH[2]}000,\"BAND\":$(cMapFreqToBand "${BASH_REMATCH[1]}")}"
    elif [[ $data =~ ^rtlsdr_set_center_freq.([0-9\.]*) ]] ; then 
        # convert older msg type "rtlsdr_set_center_freq 868300000 = 0" to "{"center_frequency":868300000}" (JSON) to be processed further down
        data="{\"center_frequency\":${BASH_REMATCH[1]},\"BAND\":$(cMapFreqToBand "${BASH_REMATCH[1]}")}"
    elif [[ $data =~ ^[^{] ]] ; then # transform any any non-JSON line (= JSON line starting with "{"), e.g. from rtl_433 debugging/error output
        data=${data#\*\*\* } # Remove any leading stars "*** "
        if [[ $bMoreVerbose && $data =~ ^"Allocating " ]] ; then # "Allocating 15 zero-copy buffers"
            cMqttStarred log "{*event*:*debug*,*message*:*${data//\*/+}*}" # convert it to a simple JSON msg
        elif [[ $data =~ ^"Please increase your allowed usbfs buffer "|^"usb"|^"No supported devices " ]] ; then
            dbg WARNING "$data"
            cMqttStarred log "{*event*:*error*,*host*:*$sHostname*,*message*:*${data//\*/+}*}" # log a simple JSON msg
            [[ $bVerbose && $data =~ ^"usb_claim_interface error -6" ]] && [ -t 1 ] && dbg WARNING "Will killall $rtl433_command" && killall -vw $rtl433_command
        fi
        dbg NONJSON "$data"
        log "Non-JSON: $data"
        continue
    elif ! [[ $data ]] ; then
        dbg EMPTYLINE
        continue # skip empty lines quietly
    fi
    # cPidDelta 0ED
    if cHasJsonKey center_frequency || cHasJsonKey src ; then
        data="${data//\" : /\":}" # beautify a bit, i.e. removing extra spaces
        cHasJsonKey center_frequency && _freq="$(cExtractJsonVal center_frequency)" && sBand="$(cMapFreqToBand "$_freq")" # formerly: sBand="$( jq -r '.center_frequency / 1000000 | floor  // empty' <<< "$data" )"
        [[ "$(cExtractJsonVal src)" == SDR ]] && [[ "$(cExtractJsonVal msg)" =~ ^Tuned\ to\ ([0-9]*)\. ]] && sBand="${BASH_REMATCH[1]}" #FIXME FIXME        
        basetopic="$sRtlPrefix/${sBand:-999}"
        cDeleteJsonKeys time
        if (( bVerbose )) ; then
            data="${data/{ /{}" # remove first space after opening {
            cEchoIfNotDuplicate "INFOMSG: $data"
            _freqs="$(cExtractJsonVal frequencies)" && cDeleteSimpleJsonKey "frequencies" && : "${_freqs}"
            cMqttStarred log "{*event*:*debug*,*message*:${data//\"/*},*BAND*:${sBand:-null}}"
        fi
        nLastStatsMessage="$(cDate %s)" # prepare for introducing a delay for avoiding race condition after freq hop (FIXME: not implemented yet)
        continue
    fi
    (( bVerbose )) && [[ $datacopy != "$data" ]] && echo "==========================================" && datacopy="$data"
    dbg RAW "$data"
    data="${data//\" : /\":}" # remove any space around (hopefully JSON) colons
    nReceivedCount+=1

    # cPidDelta 1ST

    _time="$(cExtractJsonVal time)"  # ;  _time="2021-11-01 03:05:07"
    # declare +i n # avoid octal interpretation of any leading zeroes
    # cPidDelta AAA
    n="${_time:(-8):2}" && nHour=${n#0} 
    n="${_time:(-5):2}" && nMinute=${n#0} 
    n="${_time:(-2):2}" && nSecond=${n#0}
    _delkeys="time $sSuppressAttrs"
    (( bMoreVerbose )) && cEchoIfNotDuplicate "PREPROCESSED: $data"
    # cPidDelta BBB
    protocol="$(cExtractJsonVal protocol)" ; protocol="${protocol//[^0-9]}" # Avoid arbitrary command execution vulnerability in indexes for arrays
    channel="$( cExtractJsonVal channel)"
    id="$(      cExtractJsonVal id)"
    model="" && { cHasJsonKey model || cHasJsonKey since ; } && model="$(cExtractJsonVal model)"
    [[ $model && ! $id ]] && id="$(cExtractJsonVal address)" # address might be an unique alternative to id under some circumstances, still to TEST ! (FIXME)
    ident="${channel:-$id}" # prefer "channel" (if present) over "id" as the identifier for the sensor instance.
    model_ident="${model}${ident:+_$ident}"
    model_ident="${model_ident//[^A-Za-z0-9_]}" # remove arithmetic characters from  model_ident to prevent arbitrary command execution vulnerability in indexes for arrays
    rssi="$(    cExtractJsonVal rssi)"
    vTemperature="" && nTemperature10="" && nTemperature10Diff=""
    # set -x
    _val="$( cExtractJsonVal temperature_C || cExtractJsonVal temperature )" && _val="$(cIfJSONNumber "$_val")" && vTemperature="$_val" && _val="$(cMultiplyTen "$_val")" && 
        nTemperature10="${_val/.*}" && 
        : echo 1 model_ident=$model_ident &&
        : echo 2 "${aEarlierTemperVals10[$model_ident]}" &&
        nTemperature10Diff=$(( nTemperature10 - ${aEarlierTemperVals10[$model_ident]:-0} )) # used later
    # set +x
    vHumidity="$( cExtractJsonVal humidity )" && vHumidity="$( cIfJSONNumber "$vHumidity" )"
    nHumidity="${vHumidity/.[0-9]*}"
    vSetPoint="$( cExtractJsonVal setpoint_C) || $( cExtractJsonVal setpoint_F)" && vSetPoint="$(cIfJSONNumber "$vSetPoint")"
    type="$( cExtractJsonVal type )" # typically type=TPMS if present
    if cHasJsonKey freq ; then 
        sBand="$( cMapFreqToBand "$(cExtractJsonVal freq)" )"
    else
        cHasJsonKey BAND && sBand="$(cExtractJsonVal BAND)"
    fi
    [[ $sBand ]] && basetopic="$sRtlPrefix/$sBand"
    log "$data"     

    [[ ! $bVerbose && ! $model_ident =~ $sSensorMatch ]] && : not verbose, skip early && continue # skip unwanted readings (regexp) early (if not verbose)
    # cPidDelta 2ND

    if [[ $model_ident && ! $bRewrite ]] ; then
        : no rewriting, only removing wanted
        cDeleteJsonKeys "$_delkeys"
    elif [[ $model_ident && $bRewrite ]] ; then  # Clean the line from less interesting information...
        : Rewrite and clean the line from less interesting information...
        # sample: {"id":20,"channel":1,"battery_ok":1,"temperature":18,"humidity":55,"mod":"ASK","freq":433.931,"rssi":-0.261,"snr":24.03,"noise":-24.291}
        _delkeys="$_delkeys mod snr noise mic" && (( ! bVerbose || ! bQuiet  )) && _delkeys="$_delkeys freq freq1 freq2" # other stuff: subtype channel
        [[ ${aPrevReadings[$model_ident]} && ( -z $nTemperature10 || $nTemperature10 -lt 500 ) ]] && _delkeys="$_delkeys model protocol rssi${id:+ channel}" # remove protocol after first sight  and when not unusual
        dbg2 DELETEKEYS "$_delkeys"
        cDeleteJsonKeys "$_delkeys"
        cRemoveQuotesFromNumbers

        if [[ $vTemperature ]] ; then
            # Fahrenheit = Celsius * 9/5 + 32, Fahrenheit = Celsius * 9/5 + 32
            (( ${#aWuUrls[$model_ident]} > 0 )) && temperatureF="$(cDiv10 $(( nTemperature10 * 9 / 5 + 320 )))" # calculate Fahrenheits only if needed later
            if (( bRewrite )) ; then
                # _val=$(( ( nTemperature10 + sRoundTo/2 ) / sRoundTo * sRoundTo )) && _val=$( cDiv10 $_val ) # round to 0.x °C
                _val=$( cRound nTemperature10 ) # round to 0.x °C
                cDeleteSimpleJsonKey temperature && cAddJsonKeyVal temperature "$_val"
                cDeleteSimpleJsonKey temperature_C
                _val="$(cMultiplyTen "$_val")"
                nTemperature10="${_val/.*}"
            fi
        fi
        if [[ $vHumidity ]] ; then # 
            if (( bRewrite )) ; then
                # _val="$(( ( $(cMultiplyTen $vHumidity) + sRoundTo*_hmult/2 ) / (sRoundTo*_hmult) * (sRoundTo*_hmult) ))" && _val="$(cDiv10 "$_val")"  # round to hmult * 0.x         
                _val=$( cRound $(cMultiplyTen $vHumidity) 4 ) # round to 4 * 0.x %
                nHumidity=${_val/.[0-9]*}
                # FIXME: BREAKING change should have dedicated option when adding 0. in front of $nHumidity (i.e. divide by 100) - OpenHAB 4 likes a dimension-less percentage value to be in the range 0.0...1.0 :
                cDeleteSimpleJsonKey humidity && cAddJsonKeyVal humidity "$( (( nHumidity == 100 )) && printf 1 || printf "0.%2.2d" "$nHumidity" )"
            fi
        fi
        vPressure_kPa="$(cExtractJsonVal pressure_kPa)"
        [[ $vPressure_kPa =~ ^[0-9.]+$ ]] || vPressure_kPa="" # cAssureJsonVal pressure_kPa "<= 9999", at least match a number
        _bHasParts25="$( [[ $(cExtractJsonVal pm2_5_ug_m3     ) =~ ^[0-9.]+$ ]] && echo 1 )" # e.g. "pm2_5_ug_m3":0, "estimated_pm10_0_ug_m3":0
        _bHasParts10="$( [[ $(cExtractJsonVal estimated_pm10_0_ug_m3 ) =~ ^[0-9.]+$ ]] && echo 1 )" # e.g. "pm2_5_ug_m3":0, "estimated_pm10_0_ug_m3":0
        _bHasRain="$(     [[ $(cExtractJsonVal rain_mm   ) =~ ^[1-9][0-9.]+$ ]] && echo 1 )" # formerly: cAssureJsonVal rain_mm ">0"
        _bHasBatteryOK="$(  [[ $(cExtractJsonVal battery_ok) =~ ^[01][0-9.]*$ ]] && echo 1 )" # 0,1 or some float between (0=LOW;1=FULL)
        _bHasBatteryV="$(  [[ $(cExtractJsonVal battery_V) =~ ^[0-9.]+$ ]] && echo 1 )" # voltage, also battery_mV
        _bHasZone="$(   cHasJsonKey -v zone)" #        {"id":256,"control":"Limit (0)","channel":0,"zone":1}
        _bHasUnit="$(   cHasJsonKey -v unit)" #        {"id":25612,"unit":15,"learn":0,"code":"7c818f"}
        _bHasLearn="$(  cHasJsonKey -v learn)" #        {"id":25612,"unit":15,"learn":0,"code":"7c818f"}
        _bHasChannel="$(cHasJsonKey -v channel)" #        {"id":256,"control":"Limit (0)","channel":0,"zone":1}
        _bHasControl="$(cHasJsonKey -v control)" #        {"id":256,"control":"Limit (0)","channel":0,"zone":1}
        _bHasCmd="$(    cHasJsonKey -v cmd)"
        _bHasData="$(   cHasJsonKey -v data)"
        _bHasCounter="$(cHasJsonKey -v counter )" #       {"counter":432661,"code":"800210003e915ce000000000000000000000000000069a150fa0d0dd"}
        _bHasCode="$(   cHasJsonKey -v code  )" #         {"counter":432661,"code":"800210003e915ce000000000000000000000000000069a150fa0d0dd"}
        _bHasRssi="$(   cHasJsonKey -v rssi)"
        _bHasButtonR="$(cHasJsonKey -v rbutton  )" #  rtl/433/Cardin-S466/00 {"dipswitch":"++---o--+","rbutton":"11R"}
        _bHasDipSwitch="$(cHasJsonKey -v dipswitch)" #  rtl/433/Cardin-S466/00 {"dipswitch":"++---o--+","rbutton":"11R"}
        _bHasNewBattery="$(cHasJsonKey -v newbattery)" #  {"id":13,"battery_ok":1,"newbattery":0,"temperature_C":24,"humidity":42}

        if (( bRewriteMore )) ; then
            cDeleteJsonKeys "transmit test"
            _k="$( cHasJsonKey "unknown.*" )" && [[ $(cExtractJsonVal "$_k") == 0 ]] && cDeleteSimpleJsonKey "$_k" # delete first key "unknown* == 0"
            bSkipLine=$(( nHumidity>100 || nHumidity<0 || nTemperature10<-500 )) # sanitize=skip non-plausible readings
        fi
        (( bVerbose )) && ! cHasJsonKey BAND && cAddJsonKeyVal BAND "$sBand"  # add BAND here to ensure it also goes into the logfile for all data lines
        (( bRetained )) && cAddJsonKeyVal HOUR $nHour # Append HOUR value explicitly if readings are to be sent retained
        [[ $sDoLog == "dir" ]] && echo "$(cDate "%d %H:%M:%S") $data" >> "$dModel/${sBand}_$model_ident"
    fi
    # cPidDelta 3RD

    nTimeStamp=$(cDate %s)
    # Send message to MQTT or skip it ...
    if (( bSkipLine )) ; then
        dbg SKIPPING "$data"
        bSkipLine=0
        continue
    elif ! [[ $model_ident ]] ; then # probably a stats message
        dbg "model_ident is empty"
        (( bVerbose )) && data="${data//\" : /\":}" && cEchoIfNotDuplicate "STATS: $data" && cMqttStarred stats "${data//\"/*}" # ... publish stats values (from "-M stats" option)
    elif [[ $bAlways || $nTimeStamp -gt $((nTimeStampPrev+nMinSecondsOther)) ]] || ! cEqualJson "$data" "$prev_data" "freq rssi"; then
        : "relevant, not super-recent change to previous signal - ignore freq+rssi changes, sRoundTo=$sRoundTo"
        if (( bVerbose )) ; then
            (( bRewrite && bMoreVerbose && ! bQuiet )) && cEchoIfNotDuplicate "CLEANED: $model_ident=$( grep -E --color=yes '.*' <<< "$data")" # resulting message for MQTT
            [[ $model_ident =~ $sSensorMatch ]] || continue # however, skip if no fit
        fi
        prev_data="$data" ; nTimeStampPrev=$nTimeStamp # support ignoring any incoming duplicates within a few seconds
        prevval="${aPrevReadings[$model_ident]}"
        prevvals="${aSecondPrevReadings[$model_ident]}"
        aPrevReadings[$model_ident]="$data" ; : "model_ident=$model_ident , now ${#aPrevReadings[@]} sensors"
        aCounts[$model_ident]=$(( ${aCounts[$model_ident]} + 1 )) # ... += ... doesn't work numerically in assignments for array elements

        sDelta=""
        if [[ $vTemperature ]] ; then
            _diff=$(( nTemperature10 - ${aEarlierTemperVals10[$model_ident]:-0} ))
            if ! (( ${aEarlierTemperTime[$model_ident]} )) ; then
                sDelta=NEW
                aEarlierTemperTime[$model_ident]=$nTimeStamp && aEarlierTemperVals10[$model_ident]=$nTemperature10
            elif (( nTimeStamp > ${aEarlierTemperTime[$model_ident]} + nTimeMinDelta && ( _diff > sRoundTo || _diff < -sRoundTo ) )) ; then
                sDelta="$( (( _diff > 0 )) && printf "INCR(" || printf "DESC(" ; cDiv10 $_diff )"")"
                aEarlierTemperTime[$model_ident]=$nTimeStamp && aEarlierTemperVals10[$model_ident]=$nTemperature10
            else
                : "not enough change: aEarlierTemperVals10[$model_ident]=${aEarlierTemperVals10[$model_ident]}, nTimeStamp=$nTimeStamp (vs ${aEarlierTemperTime[$model_ident]})"
                sDelta=0
            fi
            [[ $bLogTempHumidity ]] && cLogVal "$model_ident" temperature "$vTemperature"
        fi
        if [[ $vHumidity ]] ; then
            _diff=$(( nHumidity - ${aEarlierHumidVals[$model_ident]:-0} ))
            if ! (( ${aEarlierHumidTime[$model_ident]} )) ; then
                sDelta="${sDelta:+$sDelta:}NEW"
                aEarlierHumidTime[$model_ident]=$nTimeStamp && aEarlierHumidVals[$model_ident]=$nHumidity && : aEarlierHumidVals[$model_ident] initialized
            elif (( nTimeStamp > ${aEarlierHumidTime[$model_ident]} + nTimeMinDelta && ( _diff > (sRoundTo*4/10) || _diff < -(sRoundTo*4/10) ) )) ; then
                sDelta="${sDelta:+$sDelta:}$( (( _diff>0 )) && printf "INCR" || printf "DESC" )($_diff)"
                aEarlierHumidTime[$model_ident]=$nTimeStamp && aEarlierHumidVals[$model_ident]=$nHumidity && : aEarlierHumidVals[$model_ident] changed
            else
                : "not enough change, aEarlierHumidVals[$model_ident]=${aEarlierHumidVals[$model_ident]}, nTimeStamp=$nTimeStamp (vs ${aEarlierHumidTime[$model_ident]})"
                sDelta="${sDelta:+$sDelta:}0"
            fi
            [[ $bLogTempHumidity ]] && cLogVal "$model_ident" humidity "$vHumidity"
        fi
        dbg2 SDELTA "$sDelta"

        if (( bMoreVerbose && ! bQuiet )) ; then
            _prefix="SAME:  "  &&  ! cEqualJson "${aPrevReadings[$model_ident]}" "$prevval" "freq freq1 freq2 rssi" && _prefix="CHANGE(${#aPrevReadings[@]}):"
            # grep expressen was: '^[^/]*|/'
            { echo "$_prefix $model_ident" ; echo "$prevval" ; echo "${aPrevReadings[$model_ident]}" ; } | grep -E --color=auto '[ {].*'
        fi
        nMinSeconds=$(( ( (bAlways||${#vTemperature}||${#vHumidity}) && (nMinSecondsWeather>nMinSecondsOther) ) ? nMinSecondsWeather : nMinSecondsOther ))
        _IsDiff=$(  ! cEqualJson "$data" "$prevval"  "freq freq1 freq2 rssi id snr noise" > /dev/null && echo 1 ) # determine whether any raw data has changed, ignoring non-important values
        _IsDiff2=$( ! cEqualJson "$data" "$prevvals" "freq freq1 freq2 rssi id snr noise" > /dev/null && echo 1 ) # determine whether raw data has changed compared to second last readings
        _IsDiff3=$( [[ $_IsDiff && $_IsDiff2 ]] && ! cEqualJson "$prevval" "$prevvals" "freq freq1 freq2 rssi id snr noise" > /dev/null && echo 1 ) # FIXME: This could be optimized by caching values
        dbg ISDIFF "_IsDiff=$_IsDiff/$_IsDiff2/$_IsDiff2, PREV=$prevval, DATA=$data"
        if [[ $_IsDiff || $bMoreVerbose ]] ; then
            if [[ $_IsDiff2 ]] ; then
                if [[ $_IsDiff3 ]] ; then
                    nMinSeconds=$(( nMinSeconds / 6 + 1 )) && : different from last and second last time, and these both diffrent, too.
                else
                    nMinSeconds=$(( nMinSeconds / 4 + 1 )) && : different only from second last time
                fi
            else
                nMinSeconds=$(( nMinSeconds / 2 + 1 )) && : different only from last time
            fi
        fi
        _bAnnounceReady=$(( bAnnounceHass && aAnnounced[$model_ident] != 1 && aCounts[$model_ident] >= nMinOccurences )) # sensor has appeared several times

        declare -i _nSecDelta=$(( nTimeStamp - aLastPub[$model_ident] ))
        if (( bVerbose )) ; then
            echo "nMinSeconds=$nMinSeconds, announceReady=$_bAnnounceReady, nTemperature10=$nTemperature10, vHumidity=$vHumidity, nHumidity=$nHumidity, hasRain=$_bHasRain, hasCmd=$_bHasCmd, hasButtonR=$_bHasButtonR, hasDipSwitch=$_bHasDipSwitch, hasNewBattery=$_bHasNewBattery, hasControl=$_bHasControl"
            echo "Counts=${aCounts[$model_ident]}, _nSecDelta=$_nSecDelta, #aDewpointsCalc=${#aDewpointsCalc[@]}"
            (( ! bMoreVerbose )) && 
                echo "model_ident=$model_ident, READINGS=${aPrevReadings[$model_ident]}, Prev=$prevval, Prev2=$prevvals" | grep -E --color=auto 'model_ident=[^,]*|\{[^}]*}'
        fi
        
        topicext="$model$( [[ "$type" == TPMS ]] && echo "-$type" )${channel:+/$channel}$( [[ $bAddIdToTopic || -z $channel ]] && echo "${id:+/$id}" )" # construct the variant part of the MQTT topic

        if (( _bAnnounceReady )) ; then # deal with HASS annoucement need
            : Checking for announcement types - For now, only the following certain types of sensors are announced: "$vTemperature,$vHumidity,$_bHasRain,$vPressure_kPa,$_bHasCmd,$_bHasData,$_bHasCode,$_bHasButtonR,$_bHasDipSwitch,$_bHasCounter,$_bHasControl,$_bHasParts25,$_bHasParts10"
            if (( ${#vTemperature} || _bHasRain || ${#vPressure_kPa} || _bHasCmd || _bHasData ||_bHasCode || _bHasButtonR || _bHasDipSwitch 
                        || _bHasCounter || _bHasControl || _bHasParts25 || _bHasParts10 )) ; then
                [[ $protocol    ]] && _name="${aNames["$protocol"]:-$model}" || _name="$model" # fallback
                # if the device has anyone of the above attributes, announce all the attributes it has ...:
                # see also https://github.com/merbanan/rtl_433/blob/master/docs/DATA_FORMAT.md
                [[ $vTemperature ]]  && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Temp"      "value_json.temperature"   temperature
                [[ $vHumidity    ]]  && {
                    cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Humid"     "value_json.humidity"  humidity
                }
                if [[ $vTemperature  && $vHumidity && $bRewrite ]] || cHasJsonKey "dewpoint" ; then # announce (possibly calculated) dewpoint, too
                    cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Dewpoint"  "value_json.dewpoint"   dewpoint
                fi
                cHasJsonKey setpoint_C && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }TempTarget"      "value_json.setpoint_C"   setpoint
                (( _bHasRain )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }RainMM"  "value_json.rain_mm" rain_mm
                [[ $vPressure_kPa  ]] && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }PressureKPa"  "value_json.pressure_kPa" pressure_kPa
                (( _bHasBatteryOK  )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Battery"   "value_json.battery_ok"    battery_ok
                (( _bHasBatteryV  )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Battery Voltage"   "value_json.battery_V"    voltage
                (( _bHasCmd        )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Cmd"       "value_json.cmd"       motion
                (( _bHasData       )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Data"       "value_json.data"     data
                (( _bHasRssi && bMoreVerbose )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }RSSI"       "value_json.rssi"   signal
                (( _bHasCounter    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Counter"   "value_json.counter"   counter
                (( _bHasParts25    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Fine Parts"  "value_json.pm2_5_ug_m3" density25
                (( _bHasParts10    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Estim Course Parts"  "value_json.estimated_pm10_0_ug_m3" density10
                (( _bHasCode       )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Code"       "value_json.code"     code
                (( _bHasButtonR    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }ButtonR"    "value_json.buttonr"  button
                (( _bHasDipSwitch  )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }DipSwitch"  "value_json.dipswitch"    dipswitch
                (( _bHasNewBattery )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }NewBatttery"  "value_json.newbattery" newbattery
                (( _bHasZone       )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Zone"       "value_json.zone"     zone
                (( _bHasUnit       )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Unit"       "value_json.unit"     unit
                (( _bHasLearn      )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Learn"       "value_json.learn"   learn
                (( _bHasChannel    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Channel"    "value_json.channel"  channel
                (( _bHasControl    )) && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Control"    "value_json.control"  control
                #   [[ $sBand ]]  && cHassAnnounce "$basetopic" "${model:-GenericDevice} ${sBand}Mhz" "$topicext" "${ident:+($ident) }Freq"     "value_json.FREQ" frequency
                if  cMqttStarred log "{*event*:*debug*,*message*:*announced MQTT discovery: $model_ident ($_name)*}" ; then
                    nAnnouncedCount+=1
                    cMqttState
                    sleep 1 # give the MQTT readers an extra second to digest the announcement
                    aAnnounced[$model_ident]=1 # 1=took place=dont reconsider for announcement
                else
                    : announcement had failed, will be retried again next time
                fi
                if (( nAnnouncedCount > 1999 )) ; then # DENIAL OF SERVICE attack or malfunction from RF environment assumed
                    cHassRemoveAnnounce
                    _msg="nAnnouncedCount=$nAnnouncedCount exploded, DENIAL OF SERVICE attack assumed, exiting!"
                    log "$_msg" 
                    cMqttStarred log "{*event*:*exiting*,*message*:*$_msg*}"
                    dbg ENDING "$_msg"
                    exit 11 # possibly restarting the whole script, if systemd configuration allows it (=default)
                fi
            else
                cMqttStarred log "{*event*:*debug*,*message*:*not announced for MQTT discovery (not a sensible sensor): $model_ident*}"
                aAnnounced[$model_ident]=1 # 1 = took place (= dont reconsider for announcement)
            fi
        fi
        # cPidDelta 4TH

        if (( _nSecDelta > nMinSeconds )) || [[ $_IsDiff || $_bAnnounceReady == 1 || $fReplayfile ]] ; then # rcvd data different from previous reading(s) or some time elapsed
            : "now final rewriting and then publish the reading"
            aPrevReadings[$model_ident]="$data"

            if [[ $vTemperature && $nHumidity -gt 0 ]]  &&  ! cHasJsonKey "dewpoint"  &&  [[ ${aWuUrls[$model_ident]} || $bRewrite ]] ; then # prepare dewpoint calc, e.g. for weather upload
                cDewpoint "$vTemperature" "$vHumidity" > /dev/null 
                : "vDewptc=$vDewptc, vDewptf=$vDewptf" # were set as side effects
            fi

            if [[ ${aWuUrls[$model_ident]} ]] ; then # perform Wunderground upload
                # wind_speed="10", # precipitation="0"
                [[ $baromin ]] && baromin="$(( $(cMultiplyTen $(cMultiplyTen $(cMultiplyTen vPressure_kPa) ) ) / 3386  ))" # 3.3863886666667
                # https://blog.meteodrenthe.nl/2021/12/27/uploading-to-the-weather-underground-api/
                # https://support.weather.com/s/article/PWS-Upload-Protocol
                URL2="${aWuPos[$model_ident]}tempf=$temperatureF${vHumidity:+&${aWuPos[$model_ident]}humidity=$vHumidity}${baromin:+&baromin=$baromin}${rainin:+&rainin=$rainin}${dailyrainin:+&dailyrainin=$dailyrainin}${vDewptf:+&${aWuPos[$model_ident]}dewptf=$vDewptf}"
                retcurl="$( curl --silent "${aWuUrls[$model_ident]}&$URL2" 2>&1 )" && [[ $retcurl == success ]] && nUploads+=1
                log "WUNDERGROUND" "$URL2: $retcurl (nUploads=$nUploads, device=$model_ident)"
                (( bMoreVerbose )) && log "WUNDERGROUND2" "${aWuUrls[$model_ident]}&$URL2"
            else
                : "aWuUrls[$model_ident] is empty"
            fi

            if (( bRewrite )) ; then # optimize (rewrite) JSON content
                # [[ $rssi ]] && cAddJsonKeyVal rssi "$rssi" # put rssi back in
                # FIXME: [[ $_IsDiff || $bVerbose ]] && cAddJsonKeyVal COMPARE "s=$_nSecDelta,$_IsDiff($(longest_common_prefix -s "$prevval" "$data"))"
                [[ $vDewptc ]] && {
                    cAddJsonKeyVal -b BAND dewpoint "$vDewptc" # add dewpoint before BAND key
                    (( bVerbose )) && [[ $vDeltaSimple ]]  && cAddJsonKeyVal DELTADEW "$vDeltaSimple"
                }
                [[ $_IsDiff ]] && (( bVerbose || ! bVerbose )) && cAddJsonKeyVal NOTE1 "1ST($_nSecDelta/$nMinSeconds)"                 
                if [[ $_IsDiff2 ]] ; then
                    # cAddJsonKeyVal NOTE2 "$( echo "!=2ND (c=${aCounts[$model_ident]},s=$_nSecDelta/$nMinSeconds, " ; echo "....data=$data" ;  echo ".prevval=$prevval" ;  echo "prevvals=$prevvals" ;  )" &&
                    #     dbg NOTE2 "$( echo "!=2ND (c=${aCounts[$model_ident]},s=$_nSecDelta/$nMinSeconds, " ; echo "....data=$data" ;  echo ".prevval=$prevval" ;  echo "prevvals=$prevvals" ; echo "" ; )"                
                    (( bVerbose || ! bVerbose )) && cAddJsonKeyVal NOTE2 "2ND (c=${aCounts[$model_ident]},s=$_nSecDelta/$nMinSeconds),IsDiff3=$_IsDiff3"                 
                else
                    dbg 2ND "are same."
                fi
                aSecondPrevReadings[$model_ident]="$prevval"
                (( bVerbose )) && [[ $sDelta ]]  && cAddJsonKeyVal SDELTA "$sDelta"
            fi

            if cMqttStarred "$basetopic/$topicext" "${data//\"/*}" ${bRetained:+ -r} ; then # ... finally: publish the values to broker
                nMqttLines+=1
                aLastPub[$model_ident]=$nTimeStamp
            else
                : "sending had failed: $?"
            fi
        else
            dbg DUPLICATE "Suppressed a duplicate..." 
        fi
    fi
    nReadings=${#aPrevReadings[@]}
    data="" # reset data to "" to cater for read return code <> 0 and an unchanged variable $data
    vDewptc="" ; vDewptf=""

    if (( nReadings > nPrevMax )) ; then   # a new max implies we have a new device
        nPrevMax=nReadings
        _sensors="${vTemperature:+*temperature*,}${vHumidity:+*humidity*,}${vPressureKPa:+*pressure_kPa*,}${_bHasBatteryOK:+*battery*,}${_bHasRain:+*rain*,}"
        cMqttStarred log "{*event*:*device added*,*model*:*$model*,*protocol*:*$protocol*,*id*:$id,*channel*:*$channel*,*description*:*${protocol:+${aNames[$protocol]}}*, *sensors*:[${_sensors%,}]}"
        cMqttState
    elif (( nTimeStamp > nLastStatusSeconds+nLogMinutesPeriod*60 || (nMqttLines % nLogMessagesPeriod)==0 )) ; then  # log the status once in a while, good heuristic in a generalized neighbourhood
        _collection="*sensorreadings*:[$(  _comma=""
            for KEY in "${!aPrevReadings[@]}"; do
                _reading="${aPrevReadings["$KEY"]}" && _reading="${_reading/\{}" && _reading="${_reading/\}}"
                echo -n "$_comma {*model_ident*:*$KEY*,${_reading//\"/*}}"
                _comma=","
            done
        )] "
        log "$( cExpandStarredString "$_collection")" 
        cMqttState "*note*:*regular log*,*collected_sensors*:*${!aPrevReadings[*]}*, $_collection, *aDewpointsCalcNumber*:${#aDewpointsCalc[@]}"
        nLastStatusSeconds=nTimeStamp
    elif (( ${#aPrevReadings[@]} > 1000 || nMqttLines%10000==0 || nReceivedCount % 20000 == 0 )) ; then # reset whole array to empty once in a while = starting over, assume DoS attack when >1000 readings
        cMqttState
        cMqttStarred log "{*event*:*debug*,*message*:*will reset saved values (nReadings=$nReadings,nMqttLines=$nMqttLines,nReceivedCount=$nReceivedCount)*}"
        cEmptyArrays
        nPrevMax=nPrevMax/3            # reduce it quite a bit (but not back to 0) to reduce future log message
        (( bRemoveAnnouncements )) && cHassRemoveAnnounce
    fi
    # dbg ATENDOFLOOP "nReadings=$nReadings, nMqttLines=$nMqttLines, nReceivedCount=$nReceivedCount, nAnnouncedCount=$nAnnouncedCount, nUploads=$nUploads"
done

s=1 && ! [ -t 1 ] && s=30 && (( nLoops < 2 )) && s=180 # will sleep longer on failures or if not running on a terminal to reduce launch storms
_msg="Read rc=$_rc from $(basename "${fReplayfile:-$rtl433_command}") ; $nLoops loop(s) at $(cDate) ; COPROC=:${COPROC_PID:; last data=$data;}: ; sleep=${s}s"
log "$_msg" 
cMqttStarred log "{*event*:*endloop*,*host*:*$sHostname*,*message*:*$_msg*}"
dbg ENDING "$_msg"
[[ $fReplayfile ]] && exit 0 # replaying finished
sleep $s
exit 14 # return 14 only for premature end of rtl_433 command 
# now the exit trap function will be processed...