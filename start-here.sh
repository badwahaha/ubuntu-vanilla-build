#!/bin/bash

# Clear the terminal screen
clear

# Call the main build script with all arguments passed through
exec "$(dirname "$0")/scripts/build.sh" "$@"
