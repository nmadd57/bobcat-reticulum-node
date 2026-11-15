#!/usr/bin/env python3
"""Send one Reticulum announce through the local rnsd (shared instance).

Usage: announce_test.py [app-data text]

Used to check the SX1302 TX path end to end: the announce goes out over LoRa
with the RNode header byte, and another node should list the new destination.
"""

import sys
import time

import RNS

RNS.Reticulum(configdir=sys.argv[2] if len(sys.argv) > 2 else None)
identity = RNS.Identity()
destination = RNS.Destination(
    identity, RNS.Destination.IN, RNS.Destination.SINGLE, "bobcat", "g295", "test"
)
text = sys.argv[1] if len(sys.argv) > 1 else "bobcat-g295-test"
destination.announce(app_data=text.encode())
print("announced", RNS.prettyhexrep(destination.hash), "app_data:", text)
time.sleep(3)
