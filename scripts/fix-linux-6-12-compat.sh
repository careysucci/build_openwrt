#!/bin/bash

# Read the Linux version from the config file
LINUX_VERSION=$(grep -oP 'VERSION="\K[0-9]+\.[0-9]+" /path/to/config_file)

# Check for Linux version 6.12
if [[ "$LINUX_VERSION" == "6.12" ]]; then
    echo "Disabling kmod-nf-ipt modules for Linux 6.12 compatibility"
    # Commands to disable modules
    echo "modprobe -r kmod-nf-ipt" >> /etc/modprobe.d/blacklist.conf
    echo "modprobe -r kmod-nf-ipt6" >> /etc/modprobe.d/blacklist.conf
    echo "modprobe -r kmod-ipt-core" >> /etc/modprobe.d/blacklist.conf
else
    echo "Linux version is not 6.12. No changes made."
fi
