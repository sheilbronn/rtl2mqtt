# rtl2mqtt

This is an heavily modified and enhanced version of the *Rtl2MQTT* script originally derived from https://github.com/roflmao/rtl2mqtt.

It transforms the data from a SDR receiving software (rtl_433) to MQTT messages.
It cleans the data, reduces unnecessary field and duplicates.
Logging eases search for problems.

Main areas of modifications and enhancements are:
 * Introduced command line options allowing for more flexibility (See source code for usage)
 * Temperature output is transformed to SI units, e.g. Celsius.
 * Streamline some contect for MQTT msg, e.g. no time stamp or checksum code.
 * Suppress duplicate messages
 * Enhance logging into a subdirectory structure to ease later analysis.

PS: The Dockerfile is untouched and not checked since I don't run Docker. It might work or not.

A technique to make it after each reboot is adding the following line to the crontab file 
(The IP adress is the MQTT broker)
<code>
@reboot /usr/local/bin/rtl2mqtt.sh -h 192.168.178.72 -r -r
</code>
