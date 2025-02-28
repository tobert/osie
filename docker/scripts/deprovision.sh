#!/bin/bash

# shellcheck disable=SC1091
source functions.sh && init
set -o nounset

# defaults
# shellcheck disable=SC2207
disks=($(lsblk -dno name -e1,7,11 | sed 's|^|/dev/|' | sort))

USAGE="Usage: $0 -M /metadata
Required Arguments:
	-M metadata  File containing instance metadata

Options:

Description: This script installs the specified OS from an image file on to one or more block devices and handles the kernel and initrd for the
underlying hardware.
"

while getopts "M:b:u:hv" OPTION; do
	echo "OPTION=$OPTION"
	case $OPTION in
	M) metadata=$OPTARG ;;
	b) BASEURL=$OPTARG ;;
	u) ;;
	h) echo "$USAGE" && exit 0 ;;
	v) set -x ;;
	*) echo "$USAGE" && exit 1 ;;
	esac
done

arch=$(uname -m)

check_required_arg "$metadata" 'metadata file' '-M'
assert_all_args_consumed "$OPTIND" "$@"

declare facility && set_from_metadata facility 'facility' <"$metadata"
declare class && set_from_metadata class 'class' <"$metadata"
declare reserved && set_from_metadata reserved 'reserved' true <"$metadata"
declare tinkerbell && set_from_metadata tinkerbell 'phone_home_url' <"$metadata"
declare id && set_from_metadata id 'id' <"$metadata"
declare hw_id && set_from_metadata hw_id 'hardware_id' 'notfound' <"$metadata"
declare preserve_data && set_from_metadata preserve_data 'preserve_data' false <"$metadata"
declare deprovision_fast && set_from_metadata deprovision_fast 'deprovision_fast' false <"$metadata"
declare efi_status && set_from_metadata efi_status 'specs.features.uefi' null <"$metadata"

# Debug code for troubleshooting missing hardware_id metdatata
if [[ ${hw_id} == "notfound" ]]; then
	echo "Warning: hardware_id is missing from metadata for instance ${id} in facility ${facility}"
else
	echo "Notice: found hardware_id ${hw_id} for instance ${id} in facility ${facility}"
fi

# shellcheck disable=SC2001
tinkerbell=$(echo "$tinkerbell" | sed 's|\(http://[^/]\+\).*|\1|')

# if $BASEURL is not empty then the user specifically passed in the artifacts
# location, we should not trample it
BASEURL=${BASEURL:-http://install.$facility.packet.net/misc}

# On errors, run autofail() before exiting
set_autofail_stage "OSIE deprov startup"
function autofail() {
	# Passthrough for when the main script exits normally
	# shellcheck disable=SC2181
	(($? == 0)) && exit

	puttink "${tinkerbell}" phone-home '{"type":"failure", "reason":"'"Error during ${autofail_stage:-unknown}"'"}'
	print_error_summary "${autofail_stage:-unknown}"
}
trap autofail EXIT

# Check BIOS config and update if drift is detected
if [[ $arch == "x86_64" ]] && [[ $reserved != "true" ]]; then
	set_autofail_stage "detecting BIOS information"
	bios_vendor=$(detect_bios_vendor)
	bios_version=$(detect_bios_version "${bios_vendor}")
	echo "BIOS detected: ${bios_vendor} ${bios_version}"
fi

assert_block_or_loop_devs "${disks[@]}"
assert_same_type_devs "${disks[@]}"

# UEFI mismatch check - ensure desired boot mode
set_autofail_stage "verifying expected UEFI mode"
[ -d /sys/firmware/efi ] && boot_mode=UEFI || boot_mode=BIOS

if [[ $efi_status == null ]]; then
	echo "WARNING: Skipping EFI check since no status was provided in spec features!"
elif [[ $efi_status == true && $boot_mode == UEFI ]]; then
	echo "EFI status is reported as TRUE and matches boot mode UEFI: OK"
elif [[ $efi_status == false && $boot_mode == BIOS ]]; then
	echo "EFI status is reported as FALSE and matches boot mode BIOS: OK"
else
	echo "ERROR: EFI status [$efi_status] does not match active boot mode [$boot_mode]"
	echo "OSIE-1001 - Check BIOS configuration for boot mode and/or the UEFI attributes set on the hardware device."
	: problem "$tinkerbell" '{"problem":"uefi_mismatch"}'
	exit 1
fi

stimer=$(date +%s)

if [[ $preserve_data == false ]]; then
	echo "Not preserving data."

	# Look for active MD arrays
	set_autofail_stage "checking for RAID arrays"
	# shellcheck disable=SC2207
	mdarrays=($(awk '/md/ {print $4}' /proc/partitions))
	if ((${#mdarrays[*]} != 0)); then
		for mdarray in "${mdarrays[@]}"; do
			echo "MD array: $mdarray"
			mdadm --stop "/dev/$mdarray"
			# sometimes --remove fails, according to manpages seems we
			# don't need it / are doing it wrong
			mdadm --remove "/dev/$mdarray" || :
		done
	else
		echo "No MD arrays found. Skipping RAID md shutdown"
	fi

	# Reset nvme namespaces
	set_autofail_stage "resetting NVMe namespaces"
	# shellcheck disable=SC2207
	nvme_drives=($(find /dev -regex ".*/nvme[0-9]+" | sort -h))
	echo "Found ${#nvme_drives[@]} nvme drives"
	nvme list

	# Check for Ampere CPU manufacturer and echo not found is required because script fails if ampere not found.
	proc_mft=$(dmidecode --string processor-manufacturer | head -n 1 | grep "Ampere") || echo "processor manufacturer not found"
	# Check for system version and echo not found is required because script fails if system version not found.
	system_version=$(dmidecode --string system-version) || echo "system version not found"
	# Deleting nvme namespaces fails on Ampere(EVT2) servers, so skip namespace management on these servers.
	if [[ -n $proc_mft ]] && [[ $system_version == "DVT" || $system_version == "EVT2" || $system_version == "100" || $system_version == "0100" ]]; then
		echo "Skipping NVMe namespace management for $system_version system version"
	elif ((${#nvme_drives[@]} > 0)); then
		for drive in "${nvme_drives[@]}"; do
			nvme id-ctrl "$drive"
			caps=$(nvme id-ctrl "$drive" -o json | jq -r '.oacs')
			if (((caps & 0x8) == 0)); then
				echo "Nvme drive $drive has no management capabilities, skipping..."
				continue
			fi

			max_bytes=$(nvme id-ctrl "$drive" -o json | jq -r '.tnvmcap')
			# shellcheck disable=SC2207
			namespaces=($(nvme list-ns "$drive" -a | cut -d : -f 2))
			echo "Found ${#namespaces[@]} namespaces on $drive"
			if ((${#namespaces[@]} > 0)); then
				for ns in "${namespaces[@]}"; do
					echo "Deleting namespace $ns from $drive"
					nvme delete-ns "$drive" -n "$ns"
				done
			fi
			flbas=0
			nvmemodel=$(nvme id-ctrl "$drive" -o json | jq -r '.mn' | sed -e 's/[[:space:]]*$//')
			if [[ $nvmemodel == "INTEL SSDPE2KX040T8" ]]; then
				# Set specific block size depending on physical BD
				sectors=$((max_bytes / 4097))
				flbas=1
			else
				# default flbas 0 uses 512 byte sector sizes
				sectors=$((max_bytes / 512))
			fi

			echo "Creating a single namespace with $sectors sectors on $drive"
			nsid=$(nvme create-ns "$drive" --nsze=$sectors --ncap=$sectors --flbas $flbas --dps=0 | cut -d : -f 3)
			ctrl=$(nvme id-ctrl "$drive" -o json | jq '.cntlid')

			echo "Attaching namespace $nsid to ctrl $ctrl on $drive"
			nvme attach-ns "$drive" -n "$nsid" -c "$ctrl"
			sleep 2

			echo "Resetting controller $drive"
			nvme reset "$drive"
			sleep 2

			echo "Rescanning namespaces on $drive"
			nvme ns-rescan "$drive"
		done
		sleep 2
		nvme list
		# Resetting namespaces could've removed some previously detected disks
		# defaults
		# shellcheck disable=SC2207
		disks=($(lsblk -dno name -e1,7,11 | sed 's|^|/dev/|' | sort))
	fi

	# LSI MegaRAID and Dell PERC series 9
	set_autofail_stage "checking/resetting MegaRAID/PERC RAID controllers"
	# do not do grep -q, it doesn't play well with pipefail when lots of pci devices exist
	if [[ $arch == "x86_64" ]] && lspci -nn | grep -v 'SAS3008' | grep LSI >/dev/null; then
		if perccli64 show | grep -E 'PERCH710PMini|PERCH730P|PERCH740PMini|PERCH745' >/dev/null; then
			perc_reset "${disks[@]}"
		else
			megaraid_reset "${disks[@]}"
			# in case there were any disks not present at the beginning of the
			# script due to foreign config or being in raid mode
			# shellcheck disable=SC2207
			[[ -z ${DISKS:-} ]] && disks=($(lsblk -dno name -e1,7,11 | sed 's|^|/dev/|' | sort))
		fi
	fi

	# Marvell (Dell) BOSS-S1
	set_autofail_stage "checking/resetting Marvell RAID controllers"
	if [[ $arch == "x86_64" ]] && lspci -nn | grep '88SE9230' | grep Marvell >/dev/null; then
		if [[ $class == "n2.xlarge.x86" ]]; then
			echo "Skipping RAID destroy for this $class hardware..."
		else
			marvell_reset
			# in case there were any disks not present at the beginning of the
			# script due to foreign config or being in raid mode
			# shellcheck disable=SC2207
			[[ -z ${DISKS:-} ]] && disks=($(lsblk -dno name -e1,7,11 | sed 's|^|/dev/|' | sort))
		fi
	fi

	# Adaptec Smart Storage (HPE)
	set_autofail_stage "checking/resetting Adaptec Smart Storage RAID logical drives"
	if [[ $arch == "x86_64" ]] && lspci -nn | grep 'Adaptec Smart Storage PQI' >/dev/null; then
		smartarray_reset
	fi
else
	echo "Skipped array reset due to preserve_data: true"
fi

if [[ $deprovision_fast == false ]] && [[ $preserve_data == false ]]; then
	set_autofail_stage "wiping disks"
	echo "Wiping disks"
	# Wipe the filesystem and clear block on each block device
	for bd in "${disks[@]}"; do
		(
			wipe "$bd"
			# seen some 2As with backup gpt partition still available
			sgdisk -Z "$bd"
		) &
	done

	for bd in "${disks[@]}"; do
		wait -n
	done

	echo "Disk wipe finished."
	phone_home "${tinkerbell}" '{"type":"deprovisioning.306.01","body":"Disks wiped","private":true}'
else
	echo "Disk wipe skipped."
	phone_home "${tinkerbell}" '{"type":"deprovisioning.306.01","body":"Disk wipe skipped","private":true}'
fi

if [[ -d /sys/firmware/efi ]]; then
	for bootnum in $(efibootmgr | sed -n '/^Boot[0-9A-F]/ s|Boot\([0-9A-F]\{4\}\).*|\1|p'); do
		efibootmgr -Bb "$bootnum"
	done
fi

# Call firmware script to update components and firmware
case "$class" in
baremetal_2a2 | baremetal_2a4 | baremetal_hua)
	echo "skipping hardware update for oddball aarch64s"
	;;
*)
	set_autofail_stage "running packet-hardware inventory"
	packet-hardware inventory --verbose --tinkerbell "${tinkerbell}/hardware-components"

	# Catalog various BIOS feature states (not yet supported on aarch64)
	set_autofail_stage "running bios_inventory"
	if [[ $arch == "x86_64" ]]; then
		bios_inventory "${HARDWARE_ID}" "${class}" "${facility}"
	fi
	;;
esac

# Run eclypsium
if [[ -n ${ECLYPSIUM_TOKEN:-} ]]; then
	if [[ $arch == "x86_64" ]]; then
		set_autofail_stage "running eclypsium"
		https_proxy="http://eclypsium-proxy-${facility}.packet.net:8888/" /usr/bin/EclypsiumApp \
			-s1 prod-0918.eclypsium.net "${ECLYPSIUM_TOKEN}" \
			-disable-progress-bar \
			-medium \
			-log stderr \
			-request-timeout 30 \
			-custom-id "${id}" || echo 'EclypsiumApp Failed!'
	fi
fi

phone_home "${tinkerbell}" '{"type":"deprovisioning.306.02","body":"Deprovision finished, rebooting server","private":true}'
phone_home "${tinkerbell}" '{"instance_id": "'"$id"'"}'

## End installation
etimer=$(date +%s)
echo -e "${BYELLOW}Clean time: $((etimer - stimer))${NC}"

set_autofail_stage "generating cleanup.sh script"
cat >/statedir/cleanup.sh <<EOF
#!/bin/sh
poweroff
EOF
chmod +x /statedir/cleanup.sh
set_autofail_stage "completed"
