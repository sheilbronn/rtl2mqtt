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

A technique to make it after each reboot is adding the following line to the crontab file 
(The IP adress is the MQTT broker):

```
@reboot /usr/local/bin/rtl2mqtt.sh -h 192.168.178.72 -r -r
```

rtl2mqtt.sh should run fine on all Linux versions that support rtl_433.
However, prerequisites are bash, jq, and mosquitto_pub (from mosquitto). 

## Sample MQTT output

This output is from a typical suburb with different weather stations (inside or outside)
and movement sensors, smoke sensors, blind switches etc...

```
45:35 Data/Rtl/433 { event:"starting",additional_rtl_433_opts:"-G 4 -M protocol -C si -R -162" }
...
54:46 Data/Rtl/433/Smoke-GS558/25612 {"unit":15,"learn":0,"code":"7c818f"}
55:25 Data/Rtl/433/Generic-Remote/61825 {"cmd":62,"tristate":"110ZX00Z011X"}
55:59 Data/Rtl/433/Smoke-GS558/25612 {"unit":15,"learn":0,"code":"7c818f"}
56:44 Data/Rtl/433/Prologue-TH/107 {"temperature_C":24.2,"humidity":14}
57:05 Data/Rtl/433/Nexus-TH/35 {"temperature_C":15,"humidity":99}
58:36 Data/Rtl/433/inFactory-TH/12 {"temperature_C":15.3,"humidity":79}
59:04 Data/Rtl/433/Prologue-TH/107 {"temperature_C":24.2,"humidity":14}
...
```