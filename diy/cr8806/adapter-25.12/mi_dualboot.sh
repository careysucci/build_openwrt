. /lib/functions.sh

mi_dualboot_check_image() {
	local ret=0

	local file_type="$( head -c 3 "$1" )"
	if [ "${file_type}" != UBI ]; then
		v "Unsupport file type: ${file_type}"
		v "Please use ubi file"
		ret=1
	fi

	local mtd="$( grep -oE 'ubi.mtd=[a-zA-Z0-9\-\_]*' /proc/cmdline | cut -d'=' -f2 )"
	if [[ "${mtd}" != "rootfs" ]] && [[ "${mtd}" != "rootfs_1" ]]; then
		v "Unable to determine UBIPART: ubi.mtd=${mtd}"
		ret=1
	fi

	if ! fw_printenv >/dev/null; then
		v "Fail to read U-Boot env"
		ret=1
	fi

	return ${ret}
}

mi_dualboot_do_upgrade() {
	mkdir -p /var/lock
	fw_printenv >/dev/null || return 1

	# Determine UBIPART
	local mtd="$( grep -oE 'ubi.mtd=[a-zA-Z0-9\-\_]*' /proc/cmdline | cut -d'=' -f2 )"
	case "${mtd}" in
		rootfs)
			CI_UBIPART="rootfs_1"
			local current=0
			;;
		rootfs_1)
			CI_UBIPART="rootfs"
			local current=1
			;;
		*)
			v "Unable to determine UBIPART: ubi.mtd=$mtd"
			return 1
			;;
	esac

	local mtdnum="$( find_mtd_index "${CI_UBIPART}" )"
	v "Flashing to ${CI_UBIPART}(mtd${mtdnum})"
	ubiformat "/dev/mtd${mtdnum}" -f "$1" -y || return 1
	sync

	ubiattach --mtdn "${mtdnum}"

	# Check to avoid the bug of the vendor U-Boot
	local ubidev="$( nand_find_ubi "${CI_UBIPART}" )"
	if [ -z "$( nand_find_volume "${ubidev}" "kernel" )" ]; then
		v "\"kernel\" volume doesn't exist, which causes a bug of the vendor U-Boot."
		v "When try to boot this system, U-Boot will always set flag_try_sys1_failed=0 even if this is the sysem 2"
		return 1
	fi

	# Restore configurations
	[ -f "${UPGRADE_BACKUP}" ] && CI_UBIPART="${CI_UBIPART}" nand_restore_config "${UPGRADE_BACKUP}"

	# Clean the failed flag. So we can boot to them.
	fw_setenv flag_try_sys1_failed 0 || return 1
	fw_setenv flag_try_sys2_failed 0 || return 1

	# Tell u-boot that the current is able to boot.
	fw_setenv flag_last_success ${current} || return 1

	# CR8806 vendor U-Boot (measured on-device 2026-09-29, cross-checked
	# with the CB0401 serial logs of cmd_bootmiwifi.c on the OpenWrt
	# forum): the boot partition is selected by flag_boot_rootfs, and
	# flag_boot_success must stay 1 — with it cleared (or 0) the
	# bootloader takes the conservative path and boots flag_last_success,
	# i.e. the OLD system, ignoring the upgrade entirely. The upstream
	# hzyitc flag dance (ota_reboot=1 + delete boot_success) therefore
	# leaves this box on the old slot after sysupgrade: the flash succeeds
	# but the new firmware never boots. Point the selector straight at the
	# newly written slot and keep the healthy-boot state instead. The
	# anti-brick rollback still works: before booting the target slot
	# U-Boot pre-arms its try_sysN_failed flag, and either the new
	# system's uboot_env init script re-confirms the boot or the
	# bootloader falls back to flag_last_success (the old slot).
	fw_setenv flag_boot_rootfs $((1 - current)) || return 1
	fw_setenv flag_boot_success 1 || return 1
	fw_setenv flag_ota_reboot 0 || return 1
}