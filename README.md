# rtl2mqtt

This script filters and enhances the data received by an SDR stick and processed by [rtl_433](https://github.com/merbanan/rtl_433) to well defined MQTT messages.
It cleans the data, reduces most unnecessary fields and messages duplicates. 
It provides additional information (e.g. dewpoint calculation) as well as *Home Assistant MQTT autodiscovery* announcements. 
Data from weathers sensors can be uploaded to a personal Weather Underground account.
rtl2mqtt is intended to run as a daemon, starting automatically after a device boot, or on the command line.
Additonally, some logging facilities ease the debugging of your local 433/866 MHz RF radio environment.

The following sample MQTT output is from a typical suburb neighbourhood with different weather stations (inside and outside), movement sensors, smoke sensors, blind switches etc...

```log
12:01 rtl/433/Prologue-TH/1 {"battery_ok":1,"temperature":24,"humidity":14,"dewpoint":-5.1}
12:06 rtl/433/inFactory-TH/3 {"battery_ok":0,"temperature":10.5,"humidity":56,"dewpoint":2.1}
12:06 rtl/433/bridge/log {"note":"sensor added","model":"inFactory-TH","id":12,"channel":1,"sensors":["temperature","humidity","battery"]}
12:06 rtl/433/bridge/state {"sensors":2,"announceds":0,"mqttlines":2,"receiveds":2,"lastfreq":433}
12:25 rtl/433/Bresser-3CH/1 { "protocol":52, "battery_ok":0,"temperature":9,"humidity":79,"dewpoint":5.6}
12:25 rtl/433/bridge/log {"note":"sensor added","model":"Bresser-3CH","id":164,"channel":1,"sensors":["temperature","humidity","battery"]}
12:25 rtl/433/bridge/state {"sensors":4,"announceds":0,"mqttlines":4,"receiveds":9,"lastfreq":433}
12:36 rtl/433/Prologue-TH/1 {"battery_ok":1,"temperature":24.5,"humidity":14,"NOTE":"changed"}
13:14 rtl/433/inFactory-TH/3 {"battery_ok":0,"temperature":10.5,"humidity":56,"dewpoint":2.1}
13:21 rtl/433/Bresser-3CH/1 {"battery_ok":0,"temperature":9.5,"humidity":79,"dewpoint":6.0,"NOTE":"changed"}
13:27 rtl/433/Generic-Remote/61825 { "protocol":30, "cmd":62,"tristate":"110ZX00Z011X"}
...
```

A lot of features are reimplemented and heavily extended compared to many similar *Rtl2MQTT* scripts, e.g. from https://github.com/roflmao/rtl2mqtt and https://github.com/IT-Berater/rtl2mqtt (which inspired at the beginning! Thanks!) as well as the 
Python script [rtl_433_mqtt_hass.py](https://github.com/merbanan/rtl_433/blob/master/examples/rtl_433_mqtt_hass.py) from the rtl_433 examples.

So the main areas of extended features are:

* Suppression of repeated (duplicate) messages. This is a configurable, very helpful feature! -- Options: `-r` `-r` (multiple)
* Support for Home Assistant MQTT auto-discovery announcements for new sensors (also works with the sometimes picky [OpenHab MQTT Binding](https://www.openhab.org/addons/bindings/mqtt.homeassistant)) -- Options: `-h` `-p` `-t`
* Temperature output is transformed to SI units (=Celsius) and rounded to 0.5°C (configurable) for less flicker. -- Option: `-w`
* Dewpoint calculation if sensor doesn't provide it itself. -- Option:  `-L`
* Temperature and humidity of the last 24 hours can be logged to the log directory.
* Streamlined/removed mostly unnecessary content in the original JSON messages, e.g. no time stamp or checksum code.
* Frequent unchanged MQTT messages from temperature or humidity sensors within a certain time (few messages) frame are suppressed. -- Options: `-T`
* MQTT topic contains channel and - configurably - the sensor's id. -- Option: `-i`
* New sensors are not immediately auto-announced but only after several receptions -- Option: `-c`
* Configurable upload of weather sensor data to [Weather Underground (WU)](https://www.wunderground.com) using the [PWS Upload Protocol](https://support.weather.com/s/article/PWS-Upload-Protocol).  -- Option: `-W id,key,sensor`, e.g. `-W IMUNIC999,abcDEF8,Bresser-3CH_1`
* Enhanced logging and debugging into a device-specific subdirectory structure, easing later source device analysis. -- Options: `-v` `-v`
* A MQTT state and a log channel for the bridge is provided giving regular statistics and on certain events of the bridge itself.
* Many command line options allowing for flexibility in the configuration (See source code for usage)
* Command line options to be used in every invocation can be put into `~/.config/rtl2mqtt` (Start comments there with an `#`)
* Log files may be replayed for debugging in your home automation environment -- Option: `-f`
* Signalling INT to rtl2mqtt will emit a state message to MQTT and log all previeous sensor readings.
* Signalling TRAP to rtl2mqtt will toggle the verbosity for debugging to syslog and MQTT. (This was USR1 before)
* Signalling VTALRM to rtl2mqtt will log all dewpoint calculations and last sensor readings .
* Signalling USR2 to rtl2mqtt will clear the sensor homeassistant announcements. (be carefull)

NB: The Dockerfile is provided untouched and not checked for years since I don't run Docker. It might work or not.

## Installation

rtl2mqtt.sh should run fine on all Linux versions that support rtl_433, e.g. Raspbian Buster and beyond.
The only prerequisites are mosquitto_pub/mosquitto_sub (from mosquitto). The need for jq has been removed, calculations are done in bash for performance.

A very simple technique to make it run after each reboot is adding something like the following line to the crontab file:

```crontab
@reboot /usr/local/bin/rtl2mqtt.sh -l /tmp -h localhost -r -r -q
```

However, a better way for daemonizing rtl2mqtt, especially on Raspbian, is to copy this supplied [systemd service file](https://www.raspberrypi.org/documentation/linux/usage/systemd.md) "rtl2mqtt.service" to /etc/systemd/system/multi-user.target.wants, e.g. with these contents (pls modify yourself):

```YAML
[Unit]
Description=Rtl2MQTT service
After=network.target
After=syslog.target
Wants=mosquitto.service
Documentation=https://github.com/sheilbronn/rtl2mqtt

[Service]
Type=simple
Environment="LOGBASE=/var/log/rtl2mqtt"
Environment="USER=openhabian"
Environment="MQTTBROKER=localhost"
ExecStartPre=+/bin/sh -c "/bin/mkdir -p $LOGBASE && chown $USER $LOGBASE && logger $LOGBASE in place."
ExecStart=/usr/local/bin/rtl2mqtt.sh -l $LOGBASE -h $MQTTBROKER -r -r -q
User=openhabian
WorkingDirectory=$LOGBASE
StandardOutput=inherit
StandardError=inherit
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
```

Don't forget to adapt the variables to your local installation. Run ```systemctl status rtl2mqtt.service´´´ to see debugging output.

## Hardware

I'm using a [CSL DVB-T USB Stick](https://www.amazon.de/CSL-Realtek-Chip-Fernbedienung-Antenne-Windows/dp/B00CIQKFAO) plugged into a Raspberry Pi to receive the 433MHz and 868 Mhz signals. They may be bought on Ebay for a few Euros only. Other sticks might work, too. Just let me know, e.g. open an issue, and I'll put it in the README.

## Comparison

This is how the original MQTT output from ```rtl_433 -M mqtt ...''' looks like - it is split across multiple, redudant MQTT messages (which still might be ok for most folks)
```log
132122 rtl_433/openhabian/events {"time":"2022-04-19 13:21:22","protocol":52,"model":"Bresser-3CH","id":20,"channel": 1,"battery_ok": 1,"temperature_C":16.61111,"humidity":39,"mic":"CHECKSUM","mod":"ASK","freq":433.9824,"rssi":-0.965191,"snr":26.70743,"noise":-27.6726}
132122 rtl_433/openhabian/devices/Bresser-3CH/1/20/time 2022-04-19 13:21:22
132122 rtl_433/openhabian/devices/Bresser-3CH/1/20/protocol 52
132122 rtl_433/openhabian/devices/Bresser-3CH/1/20/id 20
132122 rtl_433/openhabian/devices/Bresser-3CH/1/20/channel 1
132122 rtl_433/openhabian/devices/Bresser-3CH/1/20/battery_ok 1
132122 rtl_433/openhabian/devices/Bresser-3CH/1/20/temperature_C 16.61111
132122 rtl_433/openhabian/devices/Bresser-3CH/1/20/humidity 39
132122 rtl_433/openhabian/devices/Bresser-3CH/1/20/mic CHECKSUM
132122 rtl_433/openhabian/devices/Bresser-3CH/1/20/mod ASK
132122 rtl_433/openhabian/devices/Bresser-3CH/1/20/freq 433.9824
132122 rtl_433/openhabian/devices/Bresser-3CH/1/20/rssi -0.965191
132122 rtl_433/openhabian/devices/Bresser-3CH/1/20/snr 26.70743
132122 rtl_433/openhabian/devices/Bresser-3CH/1/20/noise -27.6726
132123 rtl_433/openhabian/events {"time":"2022-04-19 13:21:22","protocol":52,"model":"Bresser-3CH","id":20,"channel": 1,"battery_ok": 1,"temperature_C":16.61111,"humidity":39,"mic":"CHECKSUM","mod":"ASK","freq":434.01501,"rssi":-0.496212,"snr":26.87678,"noise":-27.373}
132123 rtl_433/openhabian/devices/Bresser-3CH/1/20/time 2022-04-19 13:21:22
132123 rtl_433/openhabian/devices/Bresser-3CH/1/20/protocol 52
132123 rtl_433/openhabian/devices/Bresser-3CH/1/20/id 20
132123 rtl_433/openhabian/devices/Bresser-3CH/1/20/channel 1
132123 rtl_433/openhabian/devices/Bresser-3CH/1/20/battery_ok 1
132123 rtl_433/openhabian/devices/Bresser-3CH/1/20/temperature_C 16.61111
132123 rtl_433/openhabian/devices/Bresser-3CH/1/20/humidity 39
132123 rtl_433/openhabian/devices/Bresser-3CH/1/20/mic CHECKSUM
132123 rtl_433/openhabian/devices/Bresser-3CH/1/20/mod ASK
132123 rtl_433/openhabian/devices/Bresser-3CH/1/20/freq 434.01501
132123 rtl_433/openhabian/devices/Bresser-3CH/1/20/rssi -0.496212
132123 rtl_433/openhabian/devices/Bresser-3CH/1/20/snr 26.87678
132123 rtl_433/openhabian/devices/Bresser-3CH/1/20/noise -27.373
...
```