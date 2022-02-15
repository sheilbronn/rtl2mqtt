# rtl2mqtt

This script enhances the data from an SDR stick and its receiving software [rtl_433](https://github.com/merbanan/rtl_433) to well defined MQTT messages.
It also cleans the data, reduces mostly unnecessary fields and messages duplicates, while providing additional additional information as well as *Home Assistant MQTT autodiscovery* announcements! It is intended to run as a daemon, starting automatically after a device boot, or on the command line. 
Several logging facilities ease the debugging of your local 433/866 MHz radio environment.

The following sample MQTT output is from a typical suburb neighbourhood with different weather stations (inside and outside), movement sensors, smoke sensors, blind switches etc...

```log
12:01 rtl/433/Prologue-TH/107 {"battery_ok":1,"temperature":24","humidity":14}
12:06 rtl/433/inFactory-TH/12 {"battery_ok":0,"temperature":10.5","humidity":56}
12:06 rtl/433/bridge/log {"note":"sensor added","latest_model":"inFactory-TH","latest_id":12,"latest_channel":1,"sensors":["temperature","pressure_kPa","battery"]}
12:06 rtl/433/bridge/state {"sensors":2,"announceds":0,"mqttlines":2,"receiveds":2,"lastfreq":433}
12:24 rtl/433/Nexus-TH/35 {"battery_ok":0,"temperature":9.5,"humidity":39}
12:25 rtl/433/Bresser-3CH/164 {"battery_ok":0,"temperature":9,"humidity":79}
12:25 rtl/433/bridge/log {"note":"sensor added","latest_model":"Bresser-3CH","latest_id":164,"latest_channel":1,"sensors":["temperature","pressure_kPa","battery"]}
12:25 rtl/433/bridge/state {"sensors":4,"announceds":0,"mqttlines":4,"receiveds":9,"lastfreq":433}
12:36 rtl/433/Prologue-TH/107 {"battery_ok":1,"temperature":24.5,"humidity":14,"NOTE":"changed"}
13:14 rtl/433/inFactory-TH/12 {"battery_ok":0,"temperature":10.5,"humidity":56}
13:21 rtl/433/Bresser-3CH/164 {"battery_ok":0,"temperature":9.5,"humidity":79,"NOTE":"changed"}
13:27 rtl/433/Generic-Remote/61825 {"cmd":62,"tristate":"110ZX00Z011X"}
...
```

The features are reimplemented and heavily extended compared to most other *Rtl2MQTT* scripts, e.g. from https://github.com/roflmao/rtl2mqtt and https://github.com/IT-Berater/rtl2mqtt (which inspired a lot! Thanks!) as well as the 
Python script [rtl_433_mqtt_hass.py](https://github.com/merbanan/rtl_433/blob/master/examples/rtl_433_mqtt_hass.py) from the rtl_433 examples.

So the main areas of extended features are:

* Suppression of repeated (duplicate) messages. This is a configurable, very helpful feature! -- Options: -r -r
* Support for Home Assistant MQTT auto-discovery announcements for new sensors (it works well together with the sometimes picky [OpenHab MQTT Binding](https://www.openhab.org/addons/bindings/mqtt.homeassistant), too!) -- Options: -h -p -t
* Temperature output is transformed to SI units (=Celsius) and rounded to 0.5°C (configurable) for less flicker.
* Streamlined/removed mostly unnecessary content in the original JSON messages, e.g. no time stamp or checksum code.
* Frequent unchanged MQTT messages from temperature or humidity sensors within a certain time (few messages) frame are suppressed. -- Options: -c -T
* Enhanced logging into a device-specific subdirectory structure, easing later source device analysis. -- Options: -v -x
* A MQTT state and a log channel for the bridge is provided giving regular statistics and on certain events of the bridge itself.
* Many command line options allowing for flexibility in the configuration (See source code for usage)
* Sending an INT signal to the daemon will emit a status message to MQTT.
* Sending an USR1 signal to the daemon will toggle the verbosity for debugging to syslog and MQTT.
* Sending an USR2 signal to the daemon will log the gathered sensor data to syslog and MQTT.

NB: The Dockerfile is provided untouched and not checked since I don't run Docker. It might work or not.

## Installation

rtl2mqtt.sh should run fine on all Linux versions that support rtl_433, e.g. Raspbian Buster.
The only prerequisites are bash, jq, and mosquitto_pub (from mosquitto).

A very simple technique to make it run after each reboot is adding something like the following line to the crontab file:

```crontab
@reboot /usr/local/bin/rtl2mqtt.sh -l /tmp -f localhost -r -r -q
```

However, a better way for daemonizing rtl2mqtt, especially on Raspbian, is to copy this supplied [systemd service file](https://www.raspberrypi.org/documentation/linux/usage/systemd.md) "rtl2mqtt.service" to /etc/systemd/system/multi-user.target.wants, e.g. with these contents:

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

I'm using a [CSL DVB-T USB Stick](https://www.amazon.de/CSL-Realtek-Chip-Fernbedienung-Antenne-Windows/dp/B00CIQKFAO) plugged into a Raspberry Pi to receive the 433MhZ signals. They may be bought on Ebay for a few Euros only. Other sticks might work, too. Just let me know, e.g. open an issue, and I'll put it in the README.
