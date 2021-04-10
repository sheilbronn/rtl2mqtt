# rtl2mqtt

This script transforms the data from the SDR receiving software [rtl_433](https://github.com/merbanan/rtl_433) to MQTT messages.
It cleans the data, reduces unnecessary fields and duplicates. It is intended to run as a daemon, e.g. automatically after a device boot, or on the command line. Several logging facilities ease the debugging of your environment.

The following sample MQTT output is from a typical suburb neighbourhood with different weather stations (inside and outside), movement sensors, smoke sensors, blind switches etc...

```log
12:01 rtl/433/Prologue-TH/107 {"battery_ok":1,"temperature":"24","humidity":"14"}
12:06 rtl/433/inFactory-TH/12 {"battery_ok":0,"temperature":"10.4","humidity":"56"}
12:06 rtl/433/bridge/log {"note":"sensor added","latest_model":"inFactory-TH","latest_id":"12","latest_channel":"1","sensors":["temperature","pressure_kPa","battery",""]}
12:06 rtl/433/bridge/state {"sensorcount":"2","announcedcount":"0","mqttlinecount":"2","receivedcount":"2","readingscount":"2"}
12:24 rtl/433/Nexus-TH/35 {"battery_ok":0,"temperature":"9.6","humidity":"39"}
12:25 rtl/433/Bresser-3CH/164 {"battery_ok":0,"temperature":"9","humidity":"79"}
12:25 rtl/433/bridge/log {"note":"sensor added","latest_model":"Bresser-3CH","latest_id":"164","latest_channel":"1","sensors":["temperature","pressure_kPa","battery",""]}
12:25 rtl/433/bridge/state {"sensorcount":"4","announcedcount":"0","mqttlinecount":"4","receivedcount":"9","readingscount":"4"}
12:36 rtl/433/Prologue-TH/107 {"battery_ok":1,"temperature":"24","humidity":"14"}
13:14 rtl/433/inFactory-TH/12 {"battery_ok":0,"temperature":"10.2","humidity":"56"}
13:21 rtl/433/Bresser-3CH/164 {"battery_ok":0,"temperature":"9","humidity":"79"}
...
```

Features are reimplemented and extended compared to the other *Rtl2MQTT* scripts from https://github.com/roflmao/rtl2mqtt and https://github.com/IT-Berater/rtl2mqtt (which inspired me a lot! Thanks!) as well as the 
Python script [rtl_433_mqtt_hass.py](https://github.com/merbanan/rtl_433/blob/master/examples/rtl_433_mqtt_hass.py) from the rtl_433 examples.

Main areas of extended features are:

 * Suppression of repeated (duplicate) messages. This is a configurable, quite helpful feature!
 * Support Home Assistant auto-discovery announcements for new sensors (it works with the [OpenHab MQTT Binding](https://www.openhab.org/addons/bindings/mqtt.homeassistant), too!)
 * Temperature output is transformed to SI units (Celsius) and rounded to 0.2°C for less flicker.
 * Streamlined unnecessary content in the original JSON messages, e.g. no time stamp or checksum code.
 * Enhance logging into a subdirectory structure, easing later source device analysis.
 * The RTL2MQTT bridge provides a state and a log channel.
 * Many command line options allowing for flexibility in the configuration (See source code for usage)
 * Sending an USR1 signal to the daemon will emit a status message to MQTT.

NB: The Dockerfile is copied untouched and not checked since I don't run Docker. It might work or not.

## Installation

rtl2mqtt.sh should run fine on all Linux versions that support rtl_433.
Prerequisites are bash, jq, and mosquitto_pub (from mosquitto).

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
Documentation=https://github.com/sheilbronn/Manage-Gluon-MQTT

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

[Install]
WantedBy=multi-user.target
```

Don't forget to adapt the variables to your local installation. Run ```systemctl status rtl2mqtt.service´´´ to see debugging output.

## Hardware

I'm using a [CSL DVB-T USB Stick](https://www.amazon.de/CSL-Realtek-Chip-Fernbedienung-Antenne-Windows/dp/B00CIQKFAO) plugged into a Raspberry Pi to receive the 433MhZ signals. They may be bought on Ebay for a few Euros only. Other sticks might work, too. Just let me know, e.g. open an issue,  and I'll put it in the README.
