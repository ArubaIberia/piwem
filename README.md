# piwem

Welcome to the house of the **bootstrap.sh** script to turn your Raspberry Pi into a small WAN emulator!

The goal of this project is to have the Raspberry Pi turned into a small one-arm router that can be used to emulate WAN impairments like variable delay, jitter and packet loss, for SD-WAN demos.

The raspberry sits between the actual CPE router and the SD-WAN gateway, providing two links (VLAN 4094 and VLAN 4093) that can be managed independently, as shown below:

[[https://github.com/rafahpe/piwem/blob/master/img/topology.png|alt=topology]]

## Managing your emulator

To manage your emulator, you will need to create a [telegram chat bot](https://core.telegram.org/bots). The bot will allow you to send commands to your rpi, and receive responses.

The code of the bot is also [shared on github](https://github.com/rafahpe/ipbot). Please have a look there for a quick introduction to the commands the bot accepts.

## Quick Start

After you have created your [telegram chat bot](https://core.telegram.org/bots) (and got the API key for the bot), just download the script to your raspberry pi, and run it:

```
chmod 0755 bootstrap.sh
sudo ./bootstrap.sh
```

The script should work best in a freshly installed [Raspbian](https://www.raspberrypi.org/downloads/raspbian), either the lite or desktop version.
It will download the required packages and ask for the API key when required.