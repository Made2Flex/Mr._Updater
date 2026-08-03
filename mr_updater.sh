#!/usr/bin/env bash

SCRIPT_VERSION="1.4.1-4"
AUTHOR="TWFkZTJGbGV4"

set -uo pipefail

## // Configurations // ##

GREEN='\033[1;32m'
ORANGE='\033[1;33m'
BROWN='\033[0;33m'
RED='\033[1;31m'
BLUE='\033[0;34m'
MAGENTA='\033[1;35m'
LIGHT_BLUE='\033[1;36m'
NC='\033[0m'

# flags
AUR_PACKAGES=""
BTRFS_CHECKED=false
BTRFS_SNAPSHOTS_SETUP=false
STATE_FILE="$HOME/.config/mr_updater/btrfs_snapshot_state.conf"
spinner_running=false


## // FUNCTIONS // ##

run_command() {
    local command="$1"
    local output

    if [[ "$command" == sudo* ]]; then

        if ! kill -0 "${SUDO_KEEPER_PID:-}" 2>/dev/null; then
            echo -e "${RED}!! Sudo keepalive process has stopped.${NC}" >&2
            echo -e "${ORANGE}Please restart the updater.${NC}" >&2
            return 1
        fi

        if ! sudo -n -v >/dev/null 2>&1; then
            echo -e "${RED}!! Sudo credentials have expired.${NC}" >&2
            return 1
        fi

        output=$(eval "$command" 2>&1 | tee /dev/tty)

    else
        output=$(eval "$command" 2>&1 | tee /dev/tty)
    fi

    local exit_code="${PIPESTATUS[0]}"

    local _timestamped_log
    _timestamped_log=$(log_errors "$command" "$output" "$exit_code")

    check_pacman_error "$output"

    if [[ "$exit_code" -ne 0 ]]; then
        echo -e "${RED}Command failed with exit code $exit_code:${NC}"
        echo "$output"
        return 1
    fi

    return 0
}

authenticate_sudo() {
    local attempts=0
    local max_attempts=3

    while (( attempts < max_attempts )); do
        if sudo -v; then
            return 0
        else
            attempts=$((attempts + 1))
            echo -e "${RED}Incorrect sudo password or failed authentication. Please try again.${NC}" >&2
        fi
    done

    echo -e "${RED}Maximum sudo password attempts reached. Exiting.${NC}" >&2
    exit 1
}

keep_sudo_alive() {
    local interval=60

    while true; do
        sleep "$interval"

        if sudo -n -v >/dev/null 2>&1; then
            continue
        fi

        echo -e "${RED}!! Failed to refresh sudo credentials.${NC}" >&2
        echo -e "${ORANGE}   >> Sudo authentication expired.${NC}" >&2

        log_errors \
            "sudo keepalive" \
            "Failed to refresh cached sudo credentials." \
            1 \
            "error" \
            "false"

        return 1
    done
}

clean_sudo() {
    if [[ -n "${SUDO_KEEPER_PID:-}" ]]; then
    kill "$SUDO_KEEPER_PID" 2>/dev/null
    wait "$SUDO_KEEPER_PID" 2>/dev/null
    fi

    sudo -k >/dev/null 2>&1
    unset SUDO_KEEPER_PID
}

trap 'clean_sudo' EXIT INT TERM HUP QUIT ABRT PIPE ALRM USR1 USR2 TSTP TTIN TTOU

dynamic() {
    local message="$1"
    local colors=("\033[1;31m" "\033[1;33m" "\033[1;36m" "\033[1;35m" "\033[0;32m" "\033[0;34m")
    local NC="\033[0m"
    local delay=0.1
    local iterations=${2:-5}

    {
        for ((i=1; i<=iterations; i++)); do
            color=${colors[$((i % ${#colors[@]}))]}

            printf "\r${color}                                            ${message}${NC}"

            sleep "$delay"
        done

        printf "\r\033[K"
    } >&2
}

dynamic_line() {
    local message="$1"
    local colors=("\033[1;31m" "\033[1;33m" "\033[1;32m" "\033[1;36m" "\033[1;35m" "\033[1;34m")
    local NC="\033[0m"
    local delay=0.1
    local iterations=${2:-30}

    {
        for ((i=1; i<=iterations; i++)); do
            color=${colors[$((i % ${#colors[@]}))]}

            printf "\r${color}==>> ${message}${NC}"

            sleep "$delay"
        done

        printf "\n"
    } >&2
}

check_pacman_processes() {
    if pgrep -x "pacman" > /dev/null; then
        echo -e "${RED}==>> Pacman process is running. Waiting for it to complete..${NC}"
        while pgrep -x "pacman" > /dev/null; do
            sleep 2
        done
        echo -e "${GREEN}==>> Pacman process completed${NC}"
    fi
}

check_db_lock() {
    if [ -f /var/lib/pacman/db.lck ]; then
        echo -e "${RED}==>> Pacman database is locked.${NC}"
        echo -e "${LIGHT_BLUE}  >> Removing pacman db lock...${NC}"

        if sudo rm -fv /var/lib/pacman/db.lck; then
            echo -e "${GREEN}==>> ✓ Pacman database lock removed successfully${NC}"
            sleep 1
        else
            echo -e "${RED}  !! Failed to remove pacman database lock${NC}"
            dynamic_line "Manual intervention is required"
            echo -e "${MAGENTA}Please, run: sudo rm -fv /var/lib/pacman/db.lck${NC}"
            exit 1
        fi
    fi
}

# merge .pacnew files
merge_pacnew_file() {

    if ! command -v pacdiff &> /dev/null; then
        dynamic_line "Manual intervention is required"
        echo -e "${RED}  !! pacdiff not found.${NC}"
        return 1
    fi
    if ! command -v meld &> /dev/null; then
        dynamic_line "Manual intervention is required"
        echo -e "${RED}  !! meld not found. Please install meld package.${NC}"
        return 1
    fi

    if [[ -z "${DISPLAY:-}" ]]; then
        echo -e "${RED}  !! DISPLAY environment variable not set. Meld requires a graphical environment.${NC}"
        return 1
    fi

    echo -e "${LIGHT_BLUE}  >> Launching pacdiff with meld ...${NC}"
    echo -e "${LIGHT_BLUE}     - Use the meld GUI to resolve/merge configuration files as needed.${NC}"
    echo -e "${LIGHT_BLUE}     - Save changes and when done, exit meld and pacdiff will proceed.${NC}"

    sudo -H DIFFPROG=meld pacdiff

    # check if meld window opened.
    local meld_found
    pgrep -fa meld | grep -q "meld"
    meld_found=$?

    local status=$?
    if [[ $meld_found -eq 0 ]]; then
        # Meld launched successfully
        :
    else
        echo -e "${RED}  !! Could not detect that meld was launched. Something may have gone wrong.${NC}"
        echo -e "${ORANGE}  >> If meld did not open, try running:${NC} ${MAGENTA}sudo DIFFPROG=meld pacdiff${NC} ${ORANGE}manually.${NC}"

        # Log
        log_errors "pacdiff/merge" "meld did not launch as expected during pacdiff merge" "$status" "error" "false"
    fi
    

    if [[ $status -eq 0 && $meld_found -eq 0 ]]; then
        echo -e "${GREEN}    ✓ pacdiff completed.${NC}"
    else
        echo -e "${ORANGE}!!    pacdiff exited with status $status. Please verify that meld opened and merges were completed.${NC}"
        log_errors "The bed has been shited" "pacdiff/meld exit with:$status" "error" "false"
    fi
    return $status
}

# parse .pacnew files
parse_pacman_.pacnew() {
    local output="$1"
    local warnings_found=false

    if echo "$output" | grep -q "installed as.*\.pacnew"; then
        echo -e "${ORANGE}==>> Detected new configuration files:${NC}"
        warnings_found=true

        local pacnew_warnings=()
        while IFS= read -r line; do
            pacnew_warnings+=("$line")
        done < <(echo "$output" | grep "installed as.*\.pacnew")

        if [[ ${#pacnew_warnings[@]} -gt 0 ]]; then
            echo -e "${LIGHT_BLUE}  >> Found ${#pacnew_warnings[@]} .pacnew file(s)${NC}"
            for pacnew_line in "${pacnew_warnings[@]}"; do
                pacnew_file=$(echo "$pacnew_line" | sed -E 's/.*installed as (.*\.pacnew).*/\1/')
                orig_file=$(echo "$pacnew_line" | sed -E 's/(.*) installed as .*/\1/')
                echo -e "${BLUE}    >> ${NC}${MAGENTA}$orig_file${NC} ${ORANGE}→${NC} ${LIGHT_BLUE}$pacnew_file${NC}"
            done
   
            # Log the warning
            local warning_msg="Detected ${#pacnew_warnings[@]} .pacnew configuration file(s) that need merging"
            local _timestamped_log
            _timestamped_log=$(log_errors "pacman update" "$(printf '%s\n' "${pacnew_warnings[@]}")" "0" "warning" "false")
            echo

            read -rp "$(echo -e "${MAGENTA}Would you like to merge files now? (y/N)${NC} ")" merge_now </dev/tty
            merge_now=$(echo "$merge_now" | tr '[:upper:]' '[:lower:]')
            if [[ "$merge_now" == "y" || "$merge_now" == "yes" ]]; then
                if merge_pacnew_file; then
                    echo -e "${GREEN}    ✓ Completed merge. Review .pacnew files as needed.${NC}"
                else
                    echo -e "${ORANGE}  >> Merge did not complete normally. Review .pacnew/state manually.${NC}"
                fi
            else
                echo -e "${ORANGE}==>> Skipping merge. Please review and merge .pacnew files manually.${NC}"
                echo -e "${LIGHT_BLUE}  >> Command for merging manually:${NC} ${MAGENTA}sudo DIFFPROG=meld pacdiff${NC}"
                echo
            fi
        fi
    fi
}

# check for errors
check_pacman_error() {
    local error_message="$1"

    # Debugging: Log error message
    #echo -e "${LIGHT_BLUE}==>> DEBUG: Error message: $error_message${NC}"

    # check for .pacnew warnings
    parse_pacman_.pacnew "$error_message"

    # try to word bound
    if [[ "$error_message" =~ \b(database\s+error|corrupt|invalid|broken|keyring\s+error|sync\s+error|gnupg\s+error)\b ]]; then
        echo -e "${ORANGE}==>> Potential Pacman database issue detected.${NC}"
        echo -e "${ORANGE}==>> Detected error type: ${NC}"

        local error_type=""
        if [[ "$error_message" =~ \bkeyring\s+error\b ]]; then
            echo -e "${RED}  >> Keyring error detected${NC}"
            error_type="Keyring error"
        elif [[ "$error_message" =~ \bsync\s+error\b ]]; then
            echo -e "${RED}  >> Sync database error detected${NC}"
            error_type="Sync database error"
        elif [[ "$error_message" =~ \bgnupg\s+error\b ]]; then
            echo -e "${RED}  >> GnuPG error detected${NC}"
            error_type="GnuPG error"
        else
            echo -e "${RED}  >> General database error detected${NC}"
            error_type="General database error"
        fi

        local _timestamped_log
        _timestamped_log=$(log_errors "pacman database check" "$error_type: $error_message" "1" "error" "false")

        read -rp "$(echo -e "${MAGENTA}Would you like to run the Pacman database repair script? (y/N)${NC} ")" repair_choice

        repair_choice=$(echo "$repair_choice" | tr '[:upper:]' '[:lower:]')

        if [[ "$repair_choice" == "y" || "$repair_choice" == "yes" ]]; then
            # Check if Ppm_db_fixer.sh exists in the same directory
            local script_dir
            script_dir=$(dirname "$(readlink -f "$0")")
            local db_fixer_script="${script_dir}/Ppm_db_fixer.sh"

            if [[ ! -f "$db_fixer_script" ]]; then
                echo -e "${ORANGE}==>> Ppm_db_fixer.sh not found. Attempting to download...${NC}"

                if ! command -v git &> /dev/null; then
                    echo -e "${ORANGE}==>> Git was not found, but is needed. Attempting to install...${NC}"
                    sudo pacman -S --noconfirm git
                fi

                # Clone the repository
                echo -e "${LIGHT_BLUE}==>> Cloning Ppm_db_fixer from GitHub...${NC}"
                if git clone https://github.com/Made2Flex/Ppm_db_fixer.git "$script_dir/Ppm_db_fixer"; then
                    db_fixer_script="$script_dir/Ppm_db_fixer/Ppm_db_fixer.sh"

                    # Make the script executable
                    echo -e "${BLUE}  >> Making Ppm_db_fixer.sh executable...${NC}"
                    chmod -Rfv +x "$db_fixer_script"

                    echo -e "${GREEN}==>> ✓Successfully downloaded Ppm_db_fixer.sh${NC}"
                else
                    echo -e "${RED}!! Failed to download Ppm_db_fixer script.${NC}"
                    echo -e "${ORANGE}==>> Please download manually from: https://github.com/Made2Flex/Ppm_db_fixer${NC}"
                    return 1
                fi
            fi

            # Run the database repair script
            if [[ -f "$db_fixer_script" ]]; then
                echo -e "${LIGHT_BLUE}==>> Running Pacman database repair script...${NC}"
                sudo bash "$db_fixer_script"
                return $?
            else
                echo -e "${RED}!! Pacman database repair script not found.${NC}"
                echo -e "${ORANGE}Please download Ppm_db_fixer.sh from: https://github.com/Made2Flex/Ppm_db_fixer and run it manually.${NC}"
                return 1
            fi
        else
            echo -e "${ORANGE}Skipping Pacman database repair.${NC}"
            return 1
        fi
    elif [[ "$error_message" =~ "WARNING: 'grub-mkconfig' needs to run at least once to generate the snapshots (sub)menu entry in grub the main menu" ]]; then
        echo -e "${ORANGE}==>> Detected GRUB configuration warning.${NC}"
        echo -e "${ORANGE}==>> GRUB needs to be reconfigured to generate snapshot entries.${NC}"

        # Log the warning
        local _timestamped_log
        _timestamped_log=$(log_errors "grub-mkconfig" "$error_message" "0" "warning" "false")

        read -rp "$(echo -e "${MAGENTA}Would you like to run 'grub-mkconfig' now? (y/N)${NC} ")" grub_choice
        grub_choice=$(echo "$grub_choice" | tr '[:upper:]' '[:lower:]')

        if [[ "$grub_choice" == "y" || "$grub_choice" == "yes" ]]; then
            echo -e "${LIGHT_BLUE}==>> Running 'grub-mkconfig' to generate configuration data...${NC}"
            output=$(sudo grub-mkconfig 2>&1)
            echo "$output"
            if echo "$output" | grep -q "WARNING: 'grub-mkconfig' needs to run at least once to generate the snapshots (sub)menu entry in grub the main menu"; then
                echo -e "${ORANGE}==>> Detected GRUB warning. Rerunning 'grub-mkconfig'...${NC}"
                output=$(sudo grub-mkconfig -o /boot/grub/grub.cfg 2>&1)
                echo "$output"
                if echo "$output" | grep -q "WARNING: 'grub-mkconfig' needs to run at least once to generate the snapshots (sub)menu entry in grub the main menu"; then
                    echo -e "${RED}!! GRUB warning persists after second attempt.${NC}"
                    echo -e "${ORANGE}==>> Manually run${NC} ${MAGENTA}sudo grub-mkconfig${NC} ${ORANGE}and${NC} ${MAGENTA}sudo grub-mkconfig -o /boot/grub/grub.cfg${NC} ${ORANGE}.${NC} ${ORANGE}Then reboot the system.${NC}"
                    echo -e "${ORANGE}==>> Would you like to run it at script exit? (y/N)${NC}"S
                    read -rp "" exit_choice
                    exit_choice=$(echo "$exit_choice" | tr '[:upper:]' '[:lower:]')
                    if [[ "$exit_choice" == "y" || "$exit_choice" == "yes" ]]; then
                        echo -e "${LIGHT_BLUE}'==>> Running grub-mkconfig at script exit...${NC}"
                        trap '
                            if ! sudo grub-mkconfig; then
                                echo "!! Error running grub-mkconfig (exit code: $?)."
                                exit 1
                            fi

                            if ! sudo grub-mkconfig -o /boot/grub/grub.cfg; then
                                echo "!! Error running grub-mkconfig -o /boot/grub/grub.cfg (exit code: $?)."
                            else
                                echo "==>> grub-mkconfig ran successfully at script exit."
                            fi
                        ' EXIT
                    fi

                else
                    echo -e "${GREEN}==>> GRUB configuration updated successfully after second attempt!${NC}"
                    echo -e "${ORANGE}==>> You may want to check the FileSystem for Possible corruption. Check drive health.${NC}"
                fi
            else
                echo -e "${GREEN}==>> GRUB configuration updated successfully!${NC}"
            fi
        else
            echo -e "${ORANGE}==>>${NC} ${RED}!!! WARNING:${NC} ${ORANGE}You${NC} ${RED}MUST${NC} ${ORANGE}manually run ${MAGENTA}sudo grub-mkconfig${NC} ${ORANGE}and${NC} ${MAGENTA}sudo grub-mkconfig -o /boot/grub/grub.cfg${NC} ${RED}BEFORE${NC} ${ORANGE}rebooting the system!.${NC}"
            echo -e "${ORANGE}==>> Skipping GRUB configuration update.${NC}"
        fi
    fi

    return 0
}

# Show recent Pacman operations
show_pacman_log() {
    local pac_log="/var/log/pacman.log"
    local temp_log
    local OPERATION_LINES=200
    local indicators="installed|upgraded|removed|transaction|error|failed|warning"

    if [[ ! -f $pac_log ]]; then
        echo -e "${RED}Pacman.log not found: $pac_log${NC}"
        return 1
    fi

    if [[ ! -s $pac_log ]]; then
        echo -e "${LIGHT_BLUE}Pacman.log appears to be empty. There is nothing to display.${NC}"
        return 0
    fi

    # Look for possible errors
    temp_log=$(mktemp)
    grep -E "$indicators" "$pac_log" | tail -n $OPERATION_LINES > "$temp_log"

    if grep -E "error|failed|warning" "$temp_log" >/dev/null; then
        echo -e "${RED}!!! Recent pacman operations contain errors/failures/warnings:${NC}"
        grep -Ei "error|failed|warning" "$temp_log" | tail -n 10
        echo -e "${ORANGE}-- Displaying last operations..${NC}"
        sleep 1.5
    fi

    # Use bat if available, else fallback to grep and cat
    if command -v bat >/dev/null 2>&1; then
        bat --style=auto --paging=auto "$temp_log"
    elif command -v cat >/dev/null 2>&1; then
        grep -E "$indicators" "$temp_log" | cat
    else
        grep -E "$indicators" "$temp_log"
    fi

    rm -f "$temp_log"
}

# strip log from colors and special characters
strip_log() {
    local input="$1"
    input=$(echo "$input" | sed -r "s/\x1B\[([0-9]{1,3}(;[09]{1,2})?)?[mGK]//g")
    input=$(echo "$input" | tr -cd '\11\12\15\40-\176')
    echo "$input"
}

# get log file path based on distribution
log_file_path() {
    local distro_id="${DISTRO_ID:-}"

    # If DISTRO_ID is not set, try to detect it
    if [[ -z "$distro_id" && -f /etc/os-release ]]; then
        distro_id=$(source /etc/os-release 2>/dev/null && echo "$ID" | tr '[:upper:]' '[:lower:]')
    fi

    case "${distro_id:-}" in
        "arch"|"manjaro"|"endeavouros"|"garuda")
            echo "$HOME/bk/arch/update-error.log"
            ;;
        "debian"|"ubuntu"|"linuxmint")
            echo "$HOME/bk/debian/update-error.log"
            ;;
        *)
            echo ""
            ;;
    esac
}

# log errors and warnings
log_errors() {
    local command="$1"
    local output="$2"
    local exit_code="${3:-0}"
    local log_type="${4:-error}"  # 'error', 'warning' ect
    local create_timestamped="${5:-false}"
    local log_file
    local timestamped_log_file=""

    log_file=$(log_file_path)

    if [[ -z "$log_file" ]]; then
        return 0
    fi

    # Create backup directory if it doesn't exist
    local backup_dir=$(dirname "$log_file")
    mkdir -p "$backup_dir" 2>/dev/null

    # Check log file, create it if it doesn't
    if [[ ! -f "$log_file" ]]; then
        touch "$log_file" 2>/dev/null || {
                echo -e "${RED}Failed to create log file: $log_file${NC}"
            return 0
        }
    fi

    local timestamp=$(date +"%Y-%m-%d %I:%M:%S %p")
    local stripped_output=$(strip_log "$output")

    # Log
    if [[ $exit_code -ne 0 || "$log_type" == "warning" ]]; then
        {
            if [[ "$log_type" == "warning" ]]; then
                echo "[$timestamp] WARNING: $command"
            else
                echo "[$timestamp] Command failed with exit code $exit_code: $command"
            fi
            echo "[$timestamp] Output:"
            echo "$stripped_output"
            echo "------------------------------------------------------------------------"
        } >> "$log_file"

        # Create timestamped copy if true
        if [[ "$create_timestamped" == "true" && -f "$log_file" ]]; then
            local filename=$(basename "$log_file")
            timestamped_log_file="${backup_dir}/${timestamp}_${filename}"
            cp "$log_file" "$timestamped_log_file" 2>/dev/null
        fi
    fi

    echo "$timestamped_log_file"
}

get_script_path() {
    readlink -f "$0"
}

check_terminal() {
    # Check if stdin is a terminal
    if [ ! -t 0 ]; then
        # Silence GTK warnings
        local zenity_command="zenity --question --title='Terminal Required' --text='This program must be run in a terminal. Do you want to open a terminal now?' 2>/dev/null"

        if eval "$zenity_command"; then
            local script_path
            script_path=$(get_script_path)

            local terminal_commands=(
                "xdg-terminal \"$script_path\""
                "gnome-terminal -- \"$script_path\""
                "konsole -e \"$script_path\""
                "xfce4-terminal --command=\"$script_path\""
                "mate-terminal -e \"$script_path\""
                #"xterm -e \"$script_path\""
            )

            local success=false
            for cmd in "${terminal_commands[@]}"; do
                if command -v "$(echo "$cmd" | cut -d' ' -f1)" &> /dev/null; then
                    if run_command "$cmd"; then
                        success=true
                        break
                    fi
                fi
            done

            if [ "$success" = false ]; then
                echo -e "${RED}No known terminal emulator found. Please open a terminal manually and run the program.${NC}" >&2
                exit 1
            fi
        else
            # User cancelled dialog
            exit 0
        fi
        exit 1
    fi
}

header() {
    cat << 'EOF'
$$\   $$\                 $$\             $$\
$$ |  $$ |                $$ |            $$ |
$$ |  $$ | $$$$$$\   $$$$$$$ | $$$$$$\  $$$$$$\    $$$$$$\   $$$$$$\
$$ |  $$ |$$  __$$\ $$  __$$ | \____$$\ \_$$  _|  $$  __$$\ $$  __$$\
$$ |  $$ |$$ /  $$ |$$ /  $$ | $$$$$$$ |  $$ |    $$$$$$$$ |$$ |  \__|
$$ |  $$ |$$ |  $$ |$$ |  $$ |$$  __$$ |  $$ |$$\ $$   ____|$$ |
\$$$$$$  |$$$$$$$  |\$$$$$$$ |\$$$$$$$ |  \$$$$  |\$$$$$$$\ $$ |
 \______/ $$  ____/  \_______| \_______|   \____/  \_______|\__|
          $$ |
          $$ |
          \__|
EOF
}

show_header() {
    echo -e "${BLUE}"
    header
    dynamic "Qnk6IE1hZGUyRmxleA=="
    echo -e "${NC}"
}

# Localization function
get_system_language() {
    # Get system's default language
    local lang=${LANG:-en_US.UTF-8}

    # Extract language code
    local language_code=$(echo "$lang" | cut -d'_' -f1)

    # Define translations
    case "$language_code" in
        "es")
            # Spanish translations
            GREET_MESSAGE="¡Hola, %s"
            UPDATE_PROMPT="¿Quieres actualizar el systema ahora? (Sí/No): "
            ;;
        "fr")
            # French translations
            GREET_MESSAGE="Bonjour, %s"
            UPDATE_PROMPT="Voulez-vous mettre à jour maintenant ? (Oui/Non) : "
            ;;
        "de")
            # German translations
            GREET_MESSAGE="Hallo, %s"
            UPDATE_PROMPT="Möchten Sie jetzt aktualisieren? (Ja/Nein): "
            ;;
        "ja")
            # Japanese translations
            GREET_MESSAGE="%s、こんにちは"
            UPDATE_PROMPT="今すぐ更新しますか？ (はい/いいえ): "
            ;;
        *)
            # Default to English
            GREET_MESSAGE="Hello, %s"
            UPDATE_PROMPT="Do you want to update Now? (Yes/No): "
            ;;
    esac
}

# greetings
greet_user() {
    local username
    username=$(whoami)

    # Get language translations
    get_system_language

    # Greet appropriately
    printf "${GREEN}$GREET_MESSAGE${NC}\n" "$username"
}

detect_distribution() {
    DISTRO=""
    DISTRO_ID=""
    PACKAGE_MANAGER=""
    MIRROR_REFRESH_CMD=""

    # Check for distribution
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release

        DISTRO_ID=$(echo "$ID" | tr '[:upper:]' '[:lower:]')

        case "$DISTRO_ID" in
            "arch")
                DISTRO="Arch Linux"
                PACKAGE_MANAGER="pacman"
                MIRROR_REFRESH_CMD="reflector --verbose -c US --protocol https --sort rate --latest 20 --download-timeout 5 --save /etc/pacman.d/mirrorlist"
                ;;
             "garuda")
                DISTRO="Garuda Linux"
                PACKAGE_MANAGER="pacman"
                MIRROR_REFRESH_CMD="sudo reflector --verbose -c US --protocol https --sort rate --latest 20 --download-timeout 5 --save /etc/pacman.d/mirrorlist"
                ;;
            "manjaro")
                DISTRO="Manjaro Linux"
                PACKAGE_MANAGER="pacman"
                MIRROR_REFRESH_CMD="sudo pacman-mirrors --fasttrack 10" # Picks the fastest 10 mirrors. Use --continent to use geolocation
                ;;
            "endeavouros")
                DISTRO="EndeavourOS"
                PACKAGE_MANAGER="pacman"
                MIRROR_REFRESH_CMD1="eos-rankmirrors"
                MIRROR_REFRESH_CMD2="reflector --verbose -c US --protocol https --sort rate --latest 20 --download-timeout 5 --save /etc/pacman.d/mirrorlist"
                ;;
            "debian"|"ubuntu"|"linuxmint")
                DISTRO="Debian-based"
                PACKAGE_MANAGER="apt"
                MIRROR_REFRESH_CMD="sudo nala fetch --auto --fetches 10 --country US" # change 'US' to your actual country. check nala --help
                ;;
            *)
                echo -e "${RED}!!! Unsupported distribution: $DISTRO_ID${NC}"
                echo -e "${MAGENTA}==>> Please report this to the developer. Or kindly add support for your distro yourself!${NC}"
                sleep 1
                exit 1
                ;;
        esac
    else
        echo -e "${RED}Unable to detect distribution${NC}"
        exit 1
    fi
}

# warn users about manual installations
warn_manual_install() {
    dynamic_line "Manual intervention required to install dependencies."
    echo -e "${RED}!!! Unable to automatically install dependencies.${NC}"
    echo -e "${ORANGE}==>> Please install dependencies manually:${NC}"
    echo -e "   . Download the package from the internet"
    echo -e "   . Use: sudo dpkg -i package.deb for debian based systems"
    echo -e "   . Use: sudo pacman -U package.pkg.tar.zst for Arch based systems"
    echo -e "   . Note: You may retry your distro's package manager manually"
    echo -e "${ORANGE} ==>> Now exiting...${NC}"
    exit 1
}

# check dependencies
check_dependencies() {
    detect_distribution

    local missing_deps=()
    local deps=()

    # dependencies based on distribution
    case "$DISTRO_ID" in
        "arch")
            deps=("sudo" "pacman" "reflector" "pacman-contrib" "meld" "yay" "informant")
            ;;
        "garuda")
            deps=("sudo" "pacman" "reflector" "pacman-contrib" "meld" "yay" "informant")
            ;;
        "manjaro")
            deps=("sudo" "pacman" "pacman-mirrors" "yay" "pacman-contrib" "meld" "informant")
            ;;
        "endeavouros")
            deps=("sudo" "pacman" "eos-rankmirrors" "reflector" "yay" "pacman-contrib" "meld" "informant")
            ;;
        "debian"|"ubuntu"|"linuxmint")
            deps=("sudo" "apt" "nala" "meld")
            ;;
        *)
            echo -e "${RED}!! Unsupported distribution.${NC}"
            exit 1
            ;;
    esac

    for cmd in "${deps[@]}"; do
        case "$cmd" in
            "pacman-contrib")
                if ! pacman -Q pacman-contrib &>/dev/null; then
                    missing_deps+=("$cmd")
                fi
                ;;
            "yay")
                if ! command -v yay &>/dev/null; then
                    missing_deps+=("$cmd")
                fi
                ;;
            "informant")
                if ! command -v informant &>/dev/null; then
                    missing_deps+=("$cmd")
                fi
                ;;
            *)
                if ! command -v "$cmd" &>/dev/null; then
                    missing_deps+=("$cmd")
                fi
                ;;
        esac
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${RED}!! The following dependencies are missing:${NC}"
        for dep in "${missing_deps[@]}"; do
            echo -e "  ~> ${MAGENTA}$dep${NC}"
        done

        # Prompt user to install
        read -rp "$(echo -e "${LIGHT_BLUE}Do you want to install the missing dependencies? (Yes/No): ${NC}")" response
        response=$(echo "$response" | tr '[:upper:]' '[:lower:]')

        if [[ -z "$response" || "$response" == "yes" || "$response" == "y" ]]; then
            # Distribution-specific dependency installation
            case "$DISTRO_ID" in
                "arch"|"garuda"|"manjaro"|"endeavouros")
                    # Arch-based installations
                    if [[ " ${missing_deps[@]} " =~ " sudo " ]]; then
                        echo -e "${ORANGE}  >> Installing sudo...${NC}"
                        su -c "pacman -S --noconfirm sudo"
                    fi

                    for dep in "${missing_deps[@]}"; do
                        case "$dep" in
                            "pacman-contrib")
                                echo -e "${ORANGE}  >> Installing pacman-contrib...${NC}"
                                sudo pacman -S --noconfirm --needed pacman-contrib
                                if pacman -Q pacman-contrib &>/dev/null; then
                                    echo -e "${GREEN}  >> Done Installing pacman-contrib${NC}"
                                else
                                    local timestamped_log
                                    timestamped_log=$(log_errors "pacman -S --noconfirm --needed pacman-contrib" "$install_output" "$exit_code" "error" "true")
                                    echo -e "${RED}!! Failed to install pacman-contrib from repo.${NC}"
                                    echo -e "${ORANGE}  >> Output:${NC}"
                                    echo "$install_output"
                                    dynamic_line  ">> Manual intervention Required. Please use pacman -S to install it"
                                fi
                                ;;
                            "yay")
                                echo -e "${ORANGE}  >> Attempting to install yay...${NC}"
                                if sudo pacman -S --noconfirm yay 2>/dev/null; then
                                    echo -e "${GREEN}  >> ✓Successfully installed yay from repo${NC}"
                                else
                                    echo -e "${RED}!! Failed to install yay from repo.${NC}"
                                    echo -e "${ORANGE}  >> Installing git and building yay from AUR...${NC}"
                                    sudo pacman -S --noconfirm base-devel git
                                    git clone https://aur.archlinux.org/yay.git
                                    cd yay || exit 1
                                    makepkg -si --noconfirm
                                    cd .. || exit
                                    echo -e "${ORANGE}  >> Cleaning up yay build directory...${NC}"
                                    rm -rfv yay
                                fi
                                # Prompt to remove git
                                if command -v git &>/dev/null; then
                                    read -rp "$(echo -e "${LIGHT_BLUE}Do you want to remove previously installed git? (Yes/No): ${NC}")" git_remove
                                    git_remove=$(echo "$git_remove" | tr '[:upper:]' '[:lower:]')
                                    if [[ -z "$git_remove" || "$git_remove" == "yes" || "$git_remove" == "y" ]]; then
                                        sudo pacman -Rnsu --noconfirm git
                                    else
                                        echo -e "${ORANGE}==>> Continuing without removing git...${NC}"
                                    fi
                                fi
                                ;;
                            "informant")
                                echo -e "${ORANGE}  >> Installing informant from AUR...${NC}"
                                if command -v yay &>/dev/null; then
                                    yay -S --noconfirm informant
                                    if command -v informant &>/dev/null; then
                                        echo -e "${GREEN}  >> ✓Successfully installed informant${NC}"
                                    else
                                        echo -e "${RED}!! Failed to install informant from AUR.${NC}"
                                        warn_manual_install
                                    fi
                                else
                                    echo -e "${RED}!! yay is required to install informant from AUR. Please install yay first.${NC}"
                                    warn_manual_install
                                fi
                                ;;
                            *)
                                echo -e "${ORANGE}  >> Installing $dep...${NC}"
                                sudo pacman -S --noconfirm --needed "$dep"
                                if command -v "$dep" &>/dev/null; then
                                    echo -e "${GREEN}  >> ✓Successfully installed $dep${NC}"
                                else
                                    echo -e "${RED}!! Failed to install $dep.${NC}"
                                    warn_manual_install
                                fi
                                ;;
                        esac
                    done
                    ;;
                "debian"|"ubuntu"|"linuxmint")
                    if command -v apt &> /dev/null; then
                        for dep in "${missing_deps[@]}"; do
                            echo -e "${ORANGE}  >> Installing $dep...${NC}"
                            sudo apt install -y "$dep"
                        done
                    fi
                    ;;
                *)
                    echo -e "${RED}!! Unsupported distribution.${NC}"
                    warn_manual_install
                    exit 1
                    ;;
            esac

            echo -e "${GREEN}==>> Dependencies installed ✓successfully!${NC}"
        else
            echo -e "${RED}!!! Missing dependencies. Cannot proceed.${NC}"
            dynamic_line "Try to install them manually, then run the script again."
            echo -e "${ORANGE}==>> Now exiting.${NC}"
            exit 1
        fi
    fi
}

create_pkg_list() {
    local log_file=""
    local pkg_list_file=""
    local backup_dir=""

    # Detect distribution-specific paths
    case "$DISTRO_ID" in
        "arch"|"garuda"|"manjaro"|"endeavouros")
            backup_dir="$HOME/bk/arch"
            log_file="$backup_dir/update-error.log"
            pkg_list_file="$backup_dir/arch-pkglst.txt"
            ;;
        "debian"|"ubuntu"|"linuxmint")
            backup_dir="$HOME/bk/debian"
            log_file="$backup_dir/update-error.log"
            pkg_list_file="$backup_dir/debian-pkglist.txt"
            ;;
        *)
            echo -e "${RED}!!! Unsupported distribution for package list creation.${NC}"
            return 1
            ;;
    esac

    # Check if backup directory is writable
    if [ ! -w "$backup_dir" ]; then
        echo -e "${RED}!!! Backup directory does not exit: $backup_dir${NC}"
        echo -e "${ORANGE}  >> Creating one now...${NC}"
        mkdir -pv "$backup_dir" 2>/dev/null
        if [ $? -ne 0 ]; then
            echo -e "${RED}!! Cannot create backup directory. Check permissions and or create one manually.${NC}"
            return 1
        fi
    fi

    case "$DISTRO_ID" in
        "arch"|"garuda"|"manjaro"|"endeavouros")
            # Capture package list, excluding AUR packages
            local error_output
            if ! error_output=$(pacman -Qeq --native > "$pkg_list_file" 2>&1); then
                local exit_code=$?
                local timestamped_log
                timestamped_log=$(log_errors "pacman -Qeq --native > $pkg_list_file" "$error_output" "$exit_code" "error" "true")
                echo -e "${RED}!!! Error creating package list. See ${timestamped_log:-$log_file} for details.${NC}"
                return 1
            else
                local pkg_count=$(pacman -Q --native | wc -l)
                echo -e "${ORANGE}==>> Total Installed Packages (excluding AUR): ${BROWN}$pkg_count${NC}"
                echo -e "${BLUE}  >> Package list saved to $pkg_list_file${NC}"
            fi
            ;;
        "debian"|"ubuntu"|"linuxmint")
            # get package list
            local error_output
            if ! error_output=$(sudo dpkg-query -f '${binary:Package}\n' -W > "$pkg_list_file" 2>&1); then
                local exit_code=$?
                local timestamped_log
                timestamped_log=$(log_errors "dpkg-query -f '${binary:Package}\n' -W > $pkg_list_file" "$error_output" "$exit_code" "error" "true")
                echo -e "${RED}!! Error creating package list. See ${timestamped_log:-$log_file} for details.${NC}"
                return 1
            else
                local pkg_count=$(dpkg-query -f '${binary:Package}\n' -W | wc -l)
                echo -e "${ORANGE}==>> Total Installed Packages: $pkg_count${NC}"
                echo -e "${BLUE}  >> Package list saved to $pkg_list_file${NC}"

                # Create explicit package list with Nala if available
                if command -v nala &> /dev/null; then
                    local explicit_pkg_file="$backup_dir/debian-explicit-pkgs.txt"
                    sudo nala history --installed > "$explicit_pkg_file"
                    echo -e "${BLUE}  >> Explicit package list created at $explicit_pkg_file${NC}"
                fi
            fi
            ;;
    esac
}

create_aur_pkg_list() {
    case "$DISTRO_ID" in
        "arch"|"garuda"|"manjaro"|"endeavouros")
            local log_file="$HOME/bk/arch/aur-pkglst.log"
            local aur_pkg_list_file="$HOME/bk/arch/aur-pkglst.txt"

            # Capture AUR packages and save it
            error_output=$(pacman -Qmq 2>&1)
            if [ $? -eq 0 ]; then
                AUR_PACKAGES="$error_output"
                echo "$AUR_PACKAGES" > "$aur_pkg_list_file"

                echo -e "${ORANGE}==>> Installed AUR Packages:${NC}"
                echo -e "${BROWN}$AUR_PACKAGES${NC}"

                if [ -n "$AUR_PACKAGES" ]; then
                    echo -e "${BLUE}  >> Copy has been placed in $aur_pkg_list_file${NC}"
                    return 0
                else
                    echo -e "${LIGHT_BLUE}  >> No AUR packages found.${NC}"
                    return 0
                fi
            else
                # Log the error
                local exit_code=$?
                local timestamped_log
                timestamped_log=$(log_errors "pacman -Qmq" "$error_output" "$exit_code" "error" "true")
                echo -e "${RED}!! Error getting AUR package list. See ${timestamped_log:-$log_file} for details.${NC}"
                return 0
            fi
            ;;
        *)
            echo -e "${LIGHT_BLUE}   ~> Skipping AUR package list${NC}"
            return 0
            ;;
    esac
}

check_mirrors() {
    echo -e "${ORANGE}==>> Checking mirror-list...${NC}"

    case "$DISTRO_ID" in
        "arch"|"garuda"|"manjaro"|"endeavouros")
            local mirror_sources_file="/etc/pacman.d/mirrorlist"
            local mirror_sources_backup="/etc/pacman.d/mirrorlist.backup.$(date +"%Y%m%d_%H%M%S")"

            if [[ -f "$mirror_sources_file" ]]; then
                local last_modified=$(stat -c %Y "$mirror_sources_file")
                local now=$(date +%s)
                local week_seconds=$((7 * 24 * 3600))

                if (( (now - last_modified) > week_seconds )); then
                    echo -e "${MAGENTA}  >> Mirror list $mirror_sources_file hasn't been refreshed in over a week!${NC}"
                    echo -e "${ORANGE}  >> Backing up current mirrorlist...${NC}"

                    # Backup the current mirrorlist
                    sudo cp "$mirror_sources_file" "$mirror_sources_backup"
                    echo -e "${BLUE}  >> Mirrorlist backed up to $mirror_sources_backup${NC}"

                   # Keep the 3 most recent backups
                    local backup_dir="/etc/pacman.d"
                    local backup_pattern="mirrorlist.backup.*"

                    mapfile -t backups < <(find "$backup_dir" -maxdepth 1 -type f -name "$backup_pattern" -printf "%T@ %p\n" 2>/dev/null | sort -rn | cut -d' ' -f2-)

                    if (( ${#backups[@]} > 3 )); then
                        for file in "${backups[@]:3}"; do
                            if [[ -f "$file" ]]; then
                                echo -e "${LIGHT_BLUE}  >> Removing old backup: $file${NC}"
                                sudo rm -f "$file"
                            else
                                echo -e "${RED}!! Skipping invalid file: $file${NC}"
                            fi
                        done
                    fi

                    echo -e "${ORANGE}==>> Refreshing Mirrors...${NC}"

                    if [[ "$DISTRO_ID" == "endeavouros" ]]; then
                        if command -v eos-rankmirrors &> /dev/null; then
                            echo -e "${LIGHT_BLUE}  >> Running eos-rankmirrors...${NC}"
                            if eos-rankmirrors; then
                                echo -e "${GREEN}==>> eos-rankmirrors completed ✓successfully${NC}"
                            else
                                echo -e "${RED}!! eos-rankmirrors failed${NC}"
                            fi
                        fi

                        if command -v reflector &> /dev/null; then
                            echo -e "${LIGHT_BLUE}==>> Running reflector...${NC}"
                            if sudo reflector --verbose -c US --protocol https --sort rate --latest 20 --download-timeout 5 --save /etc/pacman.d/mirrorlist; then
                                echo -e "${GREEN}==>> reflector completed ✓successfully${NC}"
                            else
                                echo -e "${RED}!! reflector failed${NC}"
                            fi
                        fi
                    else
                        # For other distributions
                        $MIRROR_REFRESH_CMD
                    fi

                    echo -e "${ORANGE}==>> Mirrors have been refreshed.${NC}"
                else
                    echo -e "${GREEN}  >> Mirror list is fresh. moving on..${NC}"
                fi
            else
                echo -e "${RED}!!! Mirror-list file not found: $mirror_sources_file${NC}"
            fi
            ;;
        "debian"|"ubuntu"|"linuxmint")
            local nala_sources_file="/etc/apt/sources.list.d/nala-sources.list"
            local state_file="$HOME/.config/mr_updater/ignore_nala_fetch_warning"

            if [[ -f "$nala_sources_file" ]]; then
                local last_modified=$(stat -c %Y "$nala_sources_file")
                local now=$(date +%s)
                local week_seconds=$((7 * 24 * 3600))

                if (( (now - last_modified) > week_seconds )); then
                    echo -e "${MAGENTA}==>> Nala mirror-list hasn't been refreshed in over a week!${NC}"
                    echo -e "${ORANGE}==>> Refreshing Nala mirror-list...${NC}"

                    sudo $MIRROR_REFRESH_CMD

                    echo -e "${GREEN}==>> Nala mirror-list has been refreshed.${NC}"
                else
                    echo -e "${LIGHT_BLUE}==>> Mirror-list is fresh. Moving On!${NC}"
                fi
            else
                # Check if the user already chose to ignore this warning
                if [[ -f "$state_file" ]]; then
                    echo -e "${ORANGE}   ~> Skipping nala fetch warning as per user choice.${NC}"
                    return 0
                fi

                echo -e "${RED}!!! Nala mirror-list file not found: $nala_sources_file${NC}"
                echo -e "${ORANGE}Run: 'sudo nala fetch --auto --fetches 10 --country US' to create it. Replace '--country US' with your own.${NC}"

                while true; do
                    echo -ne "${MAGENTA}Would you like to skip this warning in the future? (y/N): ${NC}"
                    read -r skip_nala_warning
                    skip_nala_warning=$(echo "$skip_nala_warning" | tr '[:upper:]' '[:lower:]' | xargs)
                    if [[ "$skip_nala_warning" == "y" || "$skip_nala_warning" == "yes" ]]; then
                        touch "$state_file"
                        echo -e "${LIGHT_BLUE}You won't be warned about missing nala mirror-list again${NC} ${BLUE}(reset by removing $state_file).${NC}"
                        break
                    elif [[ -z "$skip_nala_warning" || "$skip_nala_warning" == "n" || "$skip_nala_warning" == "no" ]]; then
                        echo -e "${LIGHT_BLUE}You'll continue to be warned until nala fetch is run and creates the list.${NC}"
                        break
                    else
                        echo -e "${MAGENTA}Please answer y(es) or n(o).${NC}"
                    fi
                done
            fi
            ;;
        *)
            echo -e "${RED}!!! Unsupported distribution for mirror refresh.${NC}"
            exit 1
            ;;
    esac
}

# Dummy function to flush output
fflush() {
    >&2 echo -n ""
}

# create a spinner with colors
start_spinner() {
    local spinners=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local colors=("$GREEN" "$ORANGE" "$RED" "$BLUE" "$MAGENTA" "$LIGHT_BLUE")
    local delay=0.1

    # One spinner at a time
    if [ "$spinner_running" = true ]; then
        echo -e "${RED}Warning: Spinner is already running.${NC}" >&2
        return 1
    fi

    spinner_running=true

    # Start spinner
    (
        while $spinner_running; do
            for spinner in "${spinners[@]}"; do
                for color in "${colors[@]}"; do
                    if ! $spinner_running; then
                        exit 0  # exit the background process
                    fi
                    printf "\r${color}%s Processing...${NC}" "$spinner" >&2
                    fflush
                    sleep "$delay"
                done
            done
        done
    ) &
    spinner_pid=$!
}

# stop the spinner
stop_spinner() {
    spinner_running=false

    sleep 0.2

    # Kill the spinner process
    if [ -n "$spinner_pid" ]; then
         kill "$spinner_pid" 2>/dev/null
         wait "$spinner_pid" 2>/dev/null
        kill -0 "$spinner_pid" 2>/dev/null
    fi

    # Clear the line
    printf "\r%*s\r" $(tput cols) >&2

    # Reset variable
    spinner_pid=""
}

# disable informant's default pacman hook
disable_informant_hook() {
    local hook_names=("00-informant.hook")
    local dirs=("/etc/pacman.d/hooks" "/usr/share/libalpm/hooks")
    local disabled_any=0

    for dir in "${dirs[@]}"; do
        for hook in "${hook_names[@]}"; do
            local hook_path="$dir/$hook"
            if [ -e "$hook_path" ]; then
                local new_path="${hook_path%.hook}.inactive"
                echo -e "${ORANGE}==>> Disabling informant's hook at ${MAGENTA}$hook_path${NC}"
                if sudo mv "$hook_path" "$new_path" &>/dev/null; then
                    disabled_any=1
                    echo -e "${ORANGE}  >> Renamed${NC} ${MAGENTA}$hook_path${NC} to ${GREEN}$new_path${NC}"
                else
                    echo -e "${RED}  !! Failed to rename $hook_path to $new_path${NC}"
                fi
            fi
        done
    done

#     if [ $disabled_any -eq 0 ]; then
#         echo -e "${LIGHT_BLUE}==>> No informant hook found to disable.${NC}"
#     fi
    return 0
}

# rebuild informant after python's been updated
rebuild_informant() {
    # Check logs
    local last_python_pkg
    last_python_pkg=$(sudo grep -i --color=never 'upgraded python3' /var/log/pacman.log | tail -n 1 || true)

    # If not found, bail out
    if [[ -z "$last_python_pkg" ]]; then
        return 0
    fi

    # Check last Python upgrade
    local log_date
    log_date=$(echo "$last_python_pkg" | awk '{print $1}' || true)
    local today
    today=$(date +%Y-%m-%d)

    if [[ "$log_date" == "$today" ]]; then
        echo -e "${MAGENTA}==>> Python was just updated (${today}). Rebuilding informant...${NC}"
        if command -v yay &>/dev/null; then
            if yay -S --noconfirm informant; then
                echo -e "${GREEN}  >> Informant successfully rebuilt after python update.${NC}"
            else
                echo -e "${RED}  !! Failed to rebuild informant with yay.${NC}"
            fi
        else
            echo -e "${RED}  !! 'yay' not found. Cannot rebuild informant automatically.${NC}"
        fi
    fi

    # Disable informant's hook so it doesn't overlap with our customized function
    disable_informant_hook
}

# check Arch Linux news
check_arch_news() { 
    case "$DISTRO_ID" in
        "arch"|"garuda"|"manjaro"|"endeavouros")
            if ! command -v informant &> /dev/null; then
                echo -e "${LIGHT_BLUE}  >> Informant not found. Skipping Arch news check.${NC}"
                echo -e "${ORANGE}  >> Install with: ${MAGENTA}yay -S informant${NC} ${ORANGE}or${NC} ${MAGENTA}paru -S informant${NC}"
                return 0  # Return success to not block updates
            fi

            echo -e "${ORANGE}==>> Checking Arch Linux news...${NC}"

            if informant check &>/dev/null; then
                echo -e "${GREEN}  >> No unread Arch Linux news${NC}"
                return 0
            elif sudo informant check &>/dev/null; then
                echo -e "${GREEN}  >> No unread Arch Linux news${NC}"
                return 0
            fi

            echo -e "${BROWN}==>> Found unread news..${NC}"
            echo

            # List unread news items
            echo -e "${LIGHT_BLUE}  >> Unread news items:${NC}"
            local unread_output=""
            if ! unread_output=$(informant list --unread 2>/dev/null); then
                unread_output=$(sudo informant list --unread 2>/dev/null)
            fi

            if [[ -n "$unread_output" ]]; then
                echo "$unread_output"
            else
                echo -e "${RED}  !! Failed to list news items${NC}"
                # Print some debug info for troubleshooting
                echo -e "${RED}  !! Try running 'informant list --unread' manually to see any error output.${NC}"
                return 0  # Don't block updates if listing fails
            fi
            echo

            # Prompt to read news
            local read_news=""
            while :; do
                echo -ne "${MAGENTA}Would you like to read the news now? (y/N): ${NC}"
                read -r read_news
                read_news=$(echo "$read_news" | tr '[:upper:]' '[:lower:]' | xargs)
                if [[ "$read_news" == "n" || "$read_news" == "no" ]]; then
                    echo -e "${ORANGE}  >> Skipping news. Read it later with command: ${MAGENTA}$0 -l${NC}"
                    return 0
                elif [[ -z "$read_news" || "$read_news" == "y" || "$read_news" == "yes" ]]; then
                    break
                else
                    echo -e "${MAGENTA}Please answer y(es) or n(o).${NC}"
                fi
            done

            echo -e "${LIGHT_BLUE}  >> Opening news items...${NC}"
            if informant read; then
                echo -e "${GREEN}  >> News items marked as read${NC}"
            elif sudo -v &>/dev/null && sudo informant read; then
                echo -e "${GREEN}  >> News items marked as read (with sudo)${NC}"
            else
                echo -e "${RED}  !! Failed to read news items${NC}"
                return 0  # Don't block updates if reading fails
            fi

            ;;
        *)
            # skip news check
            return 0
            ;;
    esac

    return 0
}

show_all_news() {
    local all_news_output

    if ! all_news_output=$(sudo informant list 2>/dev/null); then
        if ! all_news_output=$(informant list 2>/dev/null); then
            echo -e "${RED}  !! Failed to list news items${NC}"
            return 1
        fi
    fi

    # Collect indices
    local news_indices=()
    local line

    while IFS= read -r line; do
        [[ $line =~ ^([0-9]+): ]] && news_indices+=("${BASH_REMATCH[1]}")
    done <<< "$all_news_output"

    if [[ ${#news_indices[@]} -eq 0 ]]; then
        echo -e "${GREEN}No news items found.${NC}"
        return 0
    fi

    local use_sudo=true
    if ! sudo -v &>/dev/null; then
        use_sudo=false
    fi

    for i in "${!news_indices[@]}"; do
        local idx="${news_indices[$i]}"
        local news_info

        if $use_sudo; then
            news_info=$(sudo informant read "$idx" 2>/dev/null)
            sudo informant mark-read "$idx" &>/dev/null
        fi

        if [[ -z "$news_info" ]]; then
            news_info=$(informant read "$idx" 2>/dev/null)
            informant mark-read "$idx" &>/dev/null
        fi

        if [[ -z "$news_info" ]]; then
            echo -e "${RED}  !! Failed to read news item #$idx${NC}"
            continue
        fi
        clear
        if [[ $i -eq 0 ]]; then
            echo -e "${ORANGE}Total news items:${NC} ${MAGENTA}${#news_indices[@]}${NC}"
            echo
        fi

        echo -e "${LIGHT_BLUE}======= News #${idx} =======${NC}"
        echo "$news_info"
        echo

        if [[ $i -lt $((${#news_indices[@]} - 1)) ]]; then
            while :; do
                echo -ne "${MAGENTA}Press Enter to read next news item, or type q to quit: ${NC}"
                read -r resp
                resp=$(tr '[:upper:]' '[:lower:]' <<< "$resp" | xargs)

                [[ -z "$resp" ]] && { clear; break; }
                [[ "$resp" == q || "$resp" == quit ]] && {
                    #echo -e "${ORANGE}Stopped reading news.${NC}"
                    return 0
                }
            done
        fi
    done

    echo -e "${GREEN}Done reading all news items.${NC}"
    return 0
}

update_system() {
    case "$DISTRO_ID" in
        "arch"|"garuda"|"manjaro"|"endeavouros")

            echo -e "${ORANGE}==>> Checking 'pacman' packages to update...${NC}"
            output=$(checkupdates -c 2>/dev/null)
            exit_code=$?

            if [[ -n "$output" ]]; then
                echo -e "${ORANGE}  >>${NC} ${GREEN}Updates found!${NC} ${ORANGE}Proceeding with system update${NC}"
                run_command "sudo pacman -Syu --noconfirm --needed"
            else
                echo -e "${GREEN}==>> Pacman packages are up-to-date.${NC}"
            fi

            # Prompt user to update AUR packages
            update_aur_packages=""
            while :; do
                echo -ne "${MAGENTA}Would you like to update AUR packages? (y/N): ${NC}"
                read -r update_aur_packages
                update_aur_packages=$(echo "$update_aur_packages" | tr '[:upper:]' '[:lower:]' | xargs)
                if [[ "$update_aur_packages" == "n" || "$update_aur_packages" == "no" ]]; then
                    update_aur_packages="no"
                    break
                elif [[ -z "$update_aur_packages" || "$update_aur_packages" == "y" || "$update_aur_packages" == "yes" ]]; then
                    update_aur_packages="yes"
                    break
                else
                    echo -e "${MAGENTA}Please answer y(es) or n(o).${NC}"
                fi
            done

            if [[ "$update_aur_packages" == "yes" ]]; then
                echo -e "${ORANGE}==>> Inspecting yay cache...${NC}"
                if [ -d "$HOME/.cache/yay" ]; then
                    if [[ -z "$(find "$HOME/.cache/yay" -mindepth 1 -maxdepth 1 -type d | grep -v "^$HOME/.cache/yay$")" ]]; then
                        echo -e "${GREEN}  >> Cache is clean${NC}"
                    else
                        mapfile -t yay_cache_dirs < <(find "$HOME/.cache/yay" -mindepth 1 -maxdepth 1 -type d | grep -v "^$HOME/.cache/yay$")
                        if [[ ${#yay_cache_dirs[@]} -gt 0 ]]; then
                            echo -e "${ORANGE}==>> Cleaning yay cache directories: ${NC}"
                            for dir in "${yay_cache_dirs[@]}"; do
                                printf "${BROWN}  - %s\n${NC}" "$(basename "$dir")"
                                rm -rf "$dir"
                            done
                        fi
                    fi
                else
                    echo -e "${RED}!!! yay cache directory not found: $HOME/.cache/yay${NC}"
                fi

                echo -e "${ORANGE}==> Checking if informant needs rebuilding after system update..${NC}"
                rebuild_informant

                echo -e "${ORANGE}==>> Checking 'aur' packages to update..${NC}"
                sleep 1
                yay -Sua --norebuild --noredownload --removemake --cleanafter --useask --noanswerupgrade --sudoloop && yay -Yc --noconfirm
            else
                # skip AUR update
                :
            fi

            if [[ "$update_aur_packages" == "yes" ]]; then
                aur_outdated=$(yay -Qua 2>/dev/null)
                if [[ -n "$aur_outdated" ]]; then
                    echo -e "${ORANGE}==>> Some AUR packages are still OUTDATED:${NC}"
                    echo -e "${MAGENTA}$aur_outdated${NC}"
                else
                    echo -e "${GREEN}==>> All Packages are up to date.${NC}"
                fi
            else
                echo -e "${GREEN}==>> Skipped AUR package update.${NC}"
            fi

            ;;
        "debian"|"ubuntu"|"linuxmint")
            echo -e "${ORANGE}==>> Checking packages to update.${NC}"

            start_spinner

            local update_output
            local exit_status
            update_output=$(sudo nala update)
            exit_status=$?

            stop_spinner

            # Check command output
            if [[ $exit_status -eq 0 ]] && echo "$update_output" | grep -Eq 'can be upgraded|upgradable'; then
                echo -e "${LIGHT_BLUE}==>> Updates have been found!${NC}"
                sudo nala upgrade --assume-yes --no-install-recommends --no-install-suggests --no-update --full
                echo -e "${GREEN}==>> System has been updated!${NC}"
            elif [[ $exit_status -eq 0 ]] && echo "$update_output" | grep -Eq 'dpkg was interrupted'; then
                sudo dpkg --configure -a
                echo -e "${GREEN}==>> Reconfigured lost lambs.${NC}"
            elif [ $exit_status -ne 0 ]; then
                echo -e "${RED}!!! Update check failed. See output below:${NC}"
                echo "$update_output"

                return 1
            else
                echo -e "${ORANGE}==>> No packages to update.${NC}"
                return 0
            fi
            ;;
        *)
            echo -e "${RED}!!! Unsupported distribution.${NC}"
            exit 1
            ;;
    esac
}

prompt_update() {
    while true; do
        # Use localized prompt
        get_system_language
        read -rp "$(echo -e "${MAGENTA}$UPDATE_PROMPT${NC}")" answer
        answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')

        if [[ -z "$answer" || "$answer" == "yes" || "$answer" == "y" ]]; then
            update_system
            break
        elif [[ "$answer" == "no" || "$answer" == "n" ]]; then
            echo -e "${ORANGE}<< There is nothing to do...${NC}"
            echo -e "${ORANGE}>> Meow Out!${NC}"
            break
        else
            echo -e "${RED}Invalid Input. Please Enter 'yes' or 'no'.${NC}"
        fi
    done
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        if ! source "$STATE_FILE"; then
            echo -e "${RED}!! Failed to load state from $STATE_FILE. Using default values.${NC}"
            # reset flags if loading fails
            BTRFS_CHECKED=false
            BTRFS_SNAPSHOTS_SETUP=false
        #else
            #echo -e "${BLUE}>>>> State loaded from $STATE_FILE.${NC}"
        fi
    else
        mkdir -p "$(dirname "$STATE_FILE")" || {
            echo -e "${RED}!! Failed to create directory for $STATE_FILE.${NC}"
            exit 1
        }

        # Initialize state
        echo -e "${ORANGE}==>> State file not found. Creating new state file with default values.${NC}"
        BTRFS_CHECKED=false
        BTRFS_SNAPSHOTS_SETUP=false

        # Create the state file with default values if it doesn't exist
        if ! echo "BTRFS_CHECKED=$BTRFS_CHECKED" > "$STATE_FILE" || ! echo "BTRFS_SNAPSHOTS_SETUP=$BTRFS_SNAPSHOTS_SETUP" >> "$STATE_FILE"; then
            echo -e "${RED}!! Failed to create the state file at $STATE_FILE.${NC}"
            exit 1
        fi
    fi
}

# save the state to the STATE_FILE
save_state() {
    if ! echo "BTRFS_CHECKED=$BTRFS_CHECKED" > "$STATE_FILE" || ! echo "BTRFS_SNAPSHOTS_SETUP=$BTRFS_SNAPSHOTS_SETUP" >> "$STATE_FILE"; then
        echo -e "${RED}!! Failed to save state to $STATE_FILE.${NC}"
        exit 1
    else
        echo -e "${BLUE}  >> State saved successfully to $STATE_FILE.${NC}"
    fi
}

# check if the filesystem is BTRFS and if snapshots are set up
check_btrfs_snapshots() {
    load_state

    # Check if the filesystem is BTRFS
    if [[ "$BTRFS_CHECKED" == false && "$(lsblk -f | grep -E 'btrfs')" ]]; then
        echo -e "${GREEN}==>> Detected BTRFS filesystem.${NC}"
        BTRFS_CHECKED=true

        # Check if BTRFS snapshots are set up
        if [[ "$BTRFS_SNAPSHOTS_SETUP" == false ]]; then
            echo -e "${ORANGE}==>> Checking if BTRFS snapshots are set up...${NC}"

            # Check for existing snapshots
            if sudo btrfs subvolume list / | grep -q "snapshot"; then
                sudo btrfs subvolume list /
                echo -e "${GREEN}  >> BTRFS snapshots are already set up.${NC}"
                BTRFS_SNAPSHOTS_SETUP=true
                sleep 2
            else
                echo -e "${RED}==>> BTRFS snapshots are not set up.${NC}"
                read -rp "$(echo -e "${MAGENTA}Would you like to set up BTRFS snapshots? (y/N)${NC} ")" setup_choice
                setup_choice=$(echo "$setup_choice" | tr '[:upper:]' '[:lower:]')

                if [[ "$setup_choice" == "y" || "$setup_choice" == "yes" || -z "$setup_choice" ]]; then
                    if ! command -v git &> /dev/null; then
                        echo -e "${ORANGE}==>> Git is not installed, but its needed. Attempting to install...${NC}"
                        sudo pacman -S --noconfirm git || {
                            echo -e "${RED}!! Failed to install git. Please install it manually.${NC}"
                            exit 1
                        }
                    fi

                    # Clone and run setupsnapshots.sh
                    local script_dir
                    script_dir=$(dirname "$(get_script_path)")
                    local setup_script="${script_dir}/setupsnapshots.sh"

                    if [[ ! -f "$setup_script" ]]; then
                        echo -e "${LIGHT_BLUE}==>> Cloning setupsnapshots script...${NC}"
                        git clone https://github.com/Made2Flex/setupsnapshots.git "$script_dir/setupsnapshots"
                        setup_script="$script_dir/setupsnapshots/setupsnapshots.sh"
                    fi

                    if [[ -f "$setup_script" ]]; then
                        echo -e "${LIGHT_BLUE}==>> Running the setupsnapshots script...${NC}"
                        bash "$setup_script"
                        if [[ $? -eq 0 ]]; then
                            echo -e "${GREEN}==>> BTRFS snapshots have been set up ✓successfully!${NC}"
                            BTRFS_SNAPSHOTS_SETUP=true
                        else
                            echo -e "${RED}==>> Failed to set up BTRFS snapshots.${NC}"
                        fi

                        # Clean up
                        echo -set indicatore "${ORANGE}==>> Removing previously created directory..."
                        rm -rfv "$script_dir/setupsnapshots"

                        # Prompt to remove git
                        if command -v git &> /dev/null; then
                            read -rp "$(echo -e "${MAGENTA}Would you like to remove previously installed git? (y/N)${NC} ")" git_remove_choice
                            git_remove_choice=$(echo "$git_remove_choice" | tr '[:upper:]' '[:lower:]')

                            if [[ "$git_remove_choice" == "y" || "$git_remove_choice" == "yes" || -z "$git_remove_choice" ]]; then
                                sudo pacman -Rnsu --noconfirm git
                            fi
                        fi
                    else
                        echo -e "${RED}!! setupsnapshots.sh not found.${NC}"
                    fi
                else
                    echo -e "${ORANGE}==>> To run the BTRFS snapshot setup again, set BTRFS_CHECKED=false and BTRFS_SNAPSHOTS_SETUP=false in /.config/mr_updater/btrfs_snapshot_state.conf or remove the file.${NC}"
                    echo -e "${ORANGE}==>> Skipping BTRFS snapshot setup.${NC}"
                    BTRFS_CHECKED=true
                fi
            fi
        fi
    elif [[ "$BTRFS_CHECKED" == true ]]; then
        return 0
    else
        echo -e "${RED}!! Not a BTRFS filesystem. Skipping snapshot setup.${NC}"
        BTRFS_CHECKED=true # Mark as checked to prevent repeated messages
    fi

    save_state
}

show_version() {
    echo -e "${GREEN}Version $SCRIPT_VERSION${NC}"
}

show_author() {
    local _timestamped_log

    if [[ -n "$AUTHOR" ]]; then
        local decoded_author
        decoded_author=$(echo "$AUTHOR" | base64 --decode 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo -e "${BROWN}${decoded_author}${NC}"
        else
            _timestamped_log=$(log_errors "AUTHOR" "Failed to decode AUTHOR (not valid base64?)" "1" "error" "false")
            echo -e "${RED}[ERROR]${NC} ${ORANGE}Failed to decode AUTHOR (not valid base64?)${NC}"
        fi
    else
        _timestamped_log=$(log_errors "AUTHOR" "AUTHOR variable is unset." "1" "error" "false")
        echo -e "${RED}[ERROR]${NC} ${ORANGE}AUTHOR variable is unset.${NC}"
    fi
}

show_help() {
    echo -e "${LIGHT_BLUE}This script is a system updater for Linux systems.${NC}"
    echo
    echo -e "${BLUE}Usage:${NC} ${GREEN}$0${NC} ${BLUE}[OPTIONS]${NC}"
    echo
    echo -e "${BLUE}Options:${NC}"
    echo "  -h, --help     Display this help message."
    echo "  -v, --version  Show version information."
    echo "  -l, --log      Show recent pacman transactions."
    echo "  -n, --news     Show linux arch news."
    echo "  -a, --author   Show script author."
    echo
    echo -e "${BLUE}This script will:${NC}"
    echo "  . Manage dependencies and their installations"
    echo "  . Handle BTRFS snapshot setup"
    echo "  . Create system backup via Package list"
    echo "  . Refresh mirrors every week"
    echo "  . Identifies database issues and attempts to fix them(Archlinux)"
    echo "  . Perform system updates"
    echo
    echo -e "${BLUE}Supports:${NC}"
    echo "   . Multiple Linux distributions"
    echo
    echo -e "${ORANGE}Note:${NC} This script requires root privilege for certain operations."
    echo -e "      It comes as is, with ${RED}NO GUARANTEE!${NC}"
}

# parse args
arg_parser() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            -h|-H|--help)
                show_help
                exit 0
                ;;
            -v|-V|--version)
                show_version
                exit 0
                ;;
            -l|-L|--log)
                show_pacman_log
                exit 0
                ;;
            -a|-A|--author)
                show_author
                exit 0
                ;;
            -n|-N|--news)
                show_all_news
                exit 0
                ;;
            *)
                echo -e "${RED}Error:${NC} ${ORANGE}Wrong argument. Please see bellow${NC}"
                echo
                show_help
                exit 1
                ;;
        esac
    fi
}

# Alchemist den
main() {
    arg_parser "$@"
    get_system_language
    check_terminal
    show_header
    greet_user
    authenticate_sudo
    keep_sudo_alive &
    SUDO_KEEPER_PID=$!
    check_dependencies
    disable_informant_hook
    create_pkg_list
    create_aur_pkg_list
    check_btrfs_snapshots
    check_mirrors
    check_pacman_processes
    check_db_lock
    check_arch_news
    prompt_update
}

# BoomShackalaka!!
main "$@"
