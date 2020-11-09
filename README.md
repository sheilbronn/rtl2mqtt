# rtl2mqtt

This is an heavily modified and enhanced version of the *Rtl2MQTT* script originally derived from https://github.com/roflmao/rtl2mqtt.

It transforms the data from a SDR receiving software ([rtl_433](https://github.com/merbanan/rtl_433)) to MQTT messages.
It cleans the data, reduces unnecessary field and duplicates. More logging facilities ease searching for problems.

Main areas of modifications and enhancements are:
 * Introduced command line options allowing for more flexibility (See source code for usage)
 * Temperature output is transformed to SI units, e.g. Celsius.
 * Streamline some contect for MQTT msg, e.g. no time stamp or checksum code.
 * Suppress duplicate messages
 * Enhance logging into a subdirectory structure to ease later analysis.

PS: The Dockerfile is untouched and not checked since I don't run Docker. It might work or not.

## Installation

rtl2mqtt.sh should run fine on all Linux versions that support rtl_433.
However, prerequisites are bash, jq, and mosquitto_pub (from mosquitto). 

A very simple technique to make it run after each reboot is adding the following line to the crontab file 
(The IP adress is the MQTT broker):

```crontab
@reboot /usr/local/bin/rtl2mqtt.sh -h 192.168.178.72 -r -r
```

Another good way, especially on Raspbian, is copying the systemd service file "rtl2mqtt.service" to
/etc/systemd/system/multi-user.target.wants:

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
ExecStartPre=+/bin/sh -c "/bin/mkdir -p $LOGBASE && chown $USER $LOGBASE && logger $LOGBASE in place"
ExecStart=/usr/local/bin/rtl2mqtt.sh -l $LOGBASE -h $MQTTBROKER -r -r -q
User=openhabian
WorkingDirectory=$LOGBASE
StandardOutput=inherit
StandardError=inherit

[Install]
WantedBy=multi-user.target
```

## Sample MQTT output

This output is from a typical suburb with different weather stations (inside or outside)
and movement sensors, smoke sensors, blind switches etc...

```
45:35 Rtl/433 { event:"starting",additional_rtl_433_opts:"-G 4 -M protocol -C si -R -162" }
...
54:46 Rtl/433/Smoke-GS558/25612 {"unit":15,"learn":0,"code":"7c818f"}
55:25 Rtl/433/Generic-Remote/61825 {"cmd":62,"tristate":"110ZX00Z011X"}
55:59 Rtl/433/Smoke-GS558/25612 {"unit":15,"learn":0,"code":"7c818f"}
56:44 Rtl/433/Prologue-TH/107 {"temperature_C":24.2,"humidity":14}
57:05 Rtl/433/Nexus-TH/35 {"temperature_C":15,"humidity":99}
58:36 Rtl/433/inFactory-TH/12 {"temperature_C":15.3,"humidity":79}
59:04 Rtl/433/Prologue-TH/107 {"temperature_C":24.2,"humidity":14}
...
```