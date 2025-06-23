#!/bin/bash

# --- Color Definitions ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Starting sensor configuration script...${NC}"

INSTALL_REQUIRED=false
HWDB_UPDATE_REQUIRED=false
KWIN_CONFIG_REMOVED=false # New flag for KWin config removal
CONSOLE_ROTATION_APPLIED=false # New flag for console rotation

# --- Update Pacman mirrorlist ---
echo -e "${BLUE}Updating Pacman mirrorlist and synchronizing databases...${NC}"
sudo pacman -Syyu --noconfirm
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Pacman mirrorlist updated and databases synchronized successfully.${NC}"
else
    echo -e "${RED}Failed to update Pacman mirrorlist or synchronize databases. Please check your internet connection and pacman configuration.${NC}"
    exit 1
fi

# --- 1. Install iio-sensor-proxy ---
echo -e "${BLUE}\nChecking for iio-sensor-proxy package...${NC}"
if ! pacman -Qs iio-sensor-proxy > /dev/null 2>&1; then
    echo -e "${YELLOW}iio-sensor-proxy not found. Installing...${NC}"
    # Use sudo for pacman to install packages
    sudo pacman -S iio-sensor-proxy --noconfirm
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}iio-sensor-proxy installed successfully.${NC}"
        INSTALL_REQUIRED=true
    else
        echo -e "${RED}Failed to install iio-sensor-proxy. Exiting.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}iio-sensor-proxy is already installed.${NC}"
fi

# --- 2. Create/Update /etc/udev/hwdb.d/61-sensor-local.hwdb ---
HWDB_FILE="/etc/udev/hwdb.d/61-sensor-local.hwdb"

read -r -d '' HWDB_BLOCK << 'EOF_BLOCK'
sensor:modalias:acpi:MXC6655*:dmi:*:svnGPD:pnG1628-04:*
  ACCEL_MOUNT_MATRIX=-1, 0, 0; 0, 1, 0; 0, 0, 1
EOF_BLOCK

echo -e "${BLUE}\nChecking/creating ${HWDB_FILE}...${NC}"

# Check if the file exists and if the block is already present.
# We need to use sudo to read the file if it exists, especially if it was created by root.
# Using 'grep -qF -- "$(head -n 1 <<< "$HWDB_BLOCK")" "$HWDB_FILE"' checks only the first line
# of the block, which is usually sufficient for a unique identifier.
if [ -f "$HWDB_FILE" ] && sudo grep -qF -- "$(head -n 1 <<< "$HWDB_BLOCK")" "$HWDB_FILE"; then
    echo -e "${GREEN}${HWDB_FILE} already exists and contains the required sensor configuration.${NC}"
else
    echo -e "${YELLOW}Adding/updating sensor configuration in ${HWDB_FILE}...${NC}"
    # Use 'sudo tee -a' to write to a system file with root privileges.
    # tee -a appends to the file.
    echo -e "$HWDB_BLOCK" | sudo tee -a "$HWDB_FILE" > /dev/null
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Sensor configuration written to ${HWDB_FILE} successfully.${NC}"
        HWDB_UPDATE_REQUIRED=true
    else
        echo -e "${RED}Failed to write sensor configuration to ${HWDB_FILE}. Exiting.${NC}"
        exit 1
    fi
fi

# --- 3. Remove KWin output configuration ---
KWIN_DEST_FILE="/var/lib/sddm/.config/kwinoutputconfig.json"

echo -e "${BLUE}\nChecking for and removing KWin output configuration file...${NC}"

# Use sudo when checking for file existence in /var/lib/sddm as well
if sudo [ -f "$KWIN_DEST_FILE" ]; then
    echo -e "${YELLOW}KWin config file found at ${KWIN_DEST_FILE}. Removing...${NC}"
    sudo rm -f "$KWIN_DEST_FILE"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}KWin config file removed successfully.${NC}"
        KWIN_CONFIG_REMOVED=true
    else
        echo -e "${RED}Failed to remove KWin config file at ${KWIN_DEST_FILE}. Check permissions.${NC}"
    fi
else
    echo -e "${GREEN}KWin config file not found at ${KWIN_DEST_FILE}. No action needed.${NC}"
fi

# --- 4. Update systemd-hwdb ---
echo -e "${BLUE}\nUpdating systemd hwdb database...${NC}"
sudo systemd-hwdb update
if [ $? -eq 0 ]; then
    echo -e "${GREEN}hwdb database updated.${NC}"
else
    echo -e "${RED}Failed to update hwdb database. Check systemd logs.${NC}"
fi

# --- 5. Trigger udev rules ---
# Trigger only if installation, hwdb update, or KWin config removal occurred
if $INSTALL_REQUIRED || $HWDB_UPDATE_REQUIRED || $KWIN_CONFIG_REMOVED; then
    echo -e "${BLUE}\nTriggering udev rules for /dev/iio:device0...${NC}"
    sudo udevadm trigger -v -p DEVNAME=/dev/iio:device0
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}udev rules triggered successfully.${NC}"
    else
        echo -e "${RED}Failed to trigger udev rules. Check udev logs.${NC}"
    fi
else
    echo -e "${YELLOW}\nNo new installation, hwdb update, or KWin config removal. Skipping udev trigger.${NC}"
fi

# --- 6. Restart iio-sensor-proxy.service ---
# Restart only if installation, hwdb update, or KWin config removal occurred
if $INSTALL_REQUIRED || $HWDB_UPDATE_REQUIRED || $KWIN_CONFIG_REMOVED; then
    echo -e "${BLUE}\nRestarting iio-sensor-proxy.service...${NC}"
    sudo systemctl restart iio-sensor-proxy.service
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}iio-sensor-proxy.service restarted successfully.${NC}"
    else
        echo -e "${RED}Failed to restart iio-sensor-proxy.service. Check systemctl status.${NC}"
    fi
else
    echo -e "${YELLOW}\nNo changes detected that require restarting iio-sensor-proxy.service. Skipping.${NC}"
fi

# --- 7. Rotate Console Display ---
echo -e "${BLUE}\nConfiguring console display rotation...${NC}"

VideoOutput=""
KERNEL_CONF_FILE="/boot/loader/entries/linux-cachyos.conf"

# Try getting primary display output using xrandr (for Xorg sessions)
echo -e "${BLUE}Attempting to get primary video output using xrandr...${NC}"
# Use sudo -E env DISPLAY... for xrandr as well, just in case, but it's often more robust.
XRANDR_OUTPUT=$(sudo -E env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" xrandr --query 2>/dev/null | grep " connected primary" | awk '{print $1}' | head -n 1)

if [ -n "$XRANDR_OUTPUT" ]; then
    VideoOutput="$XRANDR_OUTPUT"
    echo -e "${GREEN}Primary video output (xrandr): ${VideoOutput}${NC}"
else
    echo -e "${YELLOW}xrandr did not find a primary output. Trying kscreen-doctor (for KDE Plasma/Wayland/fallback)...${NC}"
    # Fallback to kscreen-doctor with a timeout if xrandr fails
    # Temporarily removed 2>/dev/null to see potential kscreen-doctor errors
    KSCREEN_DOCTOR_OUTPUT=$(timeout 5s sudo -E env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" kscreen-doctor --outputs 2>/dev/null | grep "Output:" | awk '{print $3}' | head -n 1)
    KSCREEN_DOCTOR_EXIT_CODE=$?

    if [ "$KSCREEN_DOCTOR_EXIT_CODE" -eq 124 ]; then
        echo -e "${RED}Warning: kscreen-doctor timed out after 5 seconds. It might not be able to connect to the display or is unresponsive.${NC}"
    elif [ "$KSCREEN_DOCTOR_EXIT_CODE" -ne 0 ]; then
        echo -e "${RED}Warning: kscreen-doctor exited with error code $KSCREEN_DOCTOR_EXIT_CODE. This indicates a problem getting display information.${NC}"
    fi
    VideoOutput="$KSCREEN_DOCTOR_OUTPUT"
    if [ -n "$VideoOutput" ]; then
        echo -e "${GREEN}Primary video output (kscreen-doctor fallback): ${VideoOutput}${NC}"
    fi
fi

if [ -z "$VideoOutput" ]; then
    echo -e "${RED}Could not determine primary video output. Skipping console rotation configuration.${NC}"
    echo -e "${YELLOW}Possible reasons: Neither xrandr nor kscreen-doctor found an output, or they failed. Ensure you are running this script from a graphical session.${NC}"
else
    SEARCH_STRING="video=${VideoOutput}:panel_orientation=right_side_up"
    # Check if the line already contains the rotation configuration for this output
    # Need to use sudo to read the kernel configuration file
    if sudo grep -qF "fbcon=rotate:1 video=${VideoOutput}:panel_orientation=right_side_up" "$KERNEL_CONF_FILE"; then
        echo -e "${GREEN}Console rotation for ${VideoOutput} already configured in ${KERNEL_CONF_FILE}.${NC}"
    else
        echo -e "${YELLOW}Adding console rotation to ${KERNEL_CONF_FILE} for ${VideoOutput}...${NC}"
        # Use sed to add the rotation parameters, and sudo for sed to write to the file
        sudo sed -i "/^options/s/splash/splash fbcon=rotate:1 video=${VideoOutput}:panel_orientation=right_side_up/" "$KERNEL_CONF_FILE"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Console rotation configuration added successfully.${NC}"
            CONSOLE_ROTATION_APPLIED=true
        else
            echo -e "${RED}Failed to add console rotation configuration to ${KERNEL_CONF_FILE}. Check permissions or file content.${NC}"
        fi
    fi
fi

echo -e "${BLUE}\nScript finished.${NC}"
echo -e "${YELLOW}Note: A system reboot might be required for all changes to take full effect.${NC}"
