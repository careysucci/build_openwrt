#!/bin/sh
# =============================================================
# Module: 40-cleanup.sh
# Scope:  Service hardening, permission fixes, cache cleanup
# Runs:   First boot via zzz-default-settings orchestrator
# =============================================================

# Disable services that ship enabled but are rarely needed
for _svc in \
    php7-fastcgi php7-fpm php8-fastcgi php8-fpm \
    softethervpnbridge softethervpnserver softethervpnclient \
    haproxy kcptun
do
    /etc/init.d/$_svc disable 2>/dev/null || true
done

# Fix permissions on all init.d scripts
chmod 0755 /etc/init.d/*

# Ensure network optimization script starts on boot
# (S99netopt symlink is baked in at build time; this is a safety fallback)
/etc/init.d/netopt enable 2>/dev/null || true

# Fix smpackage feed URL if present
sed -i.bak '/_smpackage/s#https://[^ ]*/packages/x86_64/smpackage#https://op.dllkids.xyz/packages/x86_64/#g' \
    /etc/opkg/distfeeds.conf 2>/dev/null || true

# Clear LuCI caches (force UI rebuild on next access)
rm -rf /tmp/luci-*cache

# Ensure crontab file exists (required by some packages)
touch /etc/crontabs/root

