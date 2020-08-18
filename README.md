# rtl2mqtt

This is an enhanced version of rtl2mqtt script from https://github.com/roflmao/rtl2mqtt.

Modifications/enhancements are:
 * Introduced command line options allowing for more flexibility
 * Temperature output is transformed to SI units, e.g. Celsius.
 * Streamline some contect for MQTT msg, e.g. no time stamp or checksum code.
 * Suppress duplicate messages
 * Enhance logging into a subdirectory structure to ease later analysis.

PS: The Dockerfile is untouched and not checked since I don't run Docker. It might work or not.
