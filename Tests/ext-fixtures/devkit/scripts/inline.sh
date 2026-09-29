#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title Uptime
# @raycast.mode inline
# @raycast.refreshTime 5s
# @raycast.icon ⏱
# @raycast.packageName System

uptime | sed 's/.*up \([^,]*\),.*/\1/'
