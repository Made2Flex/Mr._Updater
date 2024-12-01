#!/usr/bin/env bash

# Color definitions
GREEN='\033[1;32m'
ORANGE='\033[1;33m'
RED='\033[1;31m'
BLUE='\033[0;34m'
MAGENTA='\033[1;35m'
LIGHT_BLUE='\033[1;36m'
WHITE='\033[0;37m'
NC='\033[0m' # No color

# ASCII Art Header
ascii_art_header() {
    cat << 'EOF'
$$\   $$\                 $$\             $$\                         $$\
$$ |  $$ |                $$ |            $$ |                        $$ |
$$ |  $$ | $$$$$$\   $$$$$$$ | $$$$$$\  $$$$$$\    $$$$$$\   $$$$$$\  $$ |
$$ |  $$ |$$  __$$\ $$  __$$ | \____$$\ \_$$  _|  $$  __$$\ $$  __$$\ $$ |
$$ |  $$ |$$ /  $$ |$$ /  $$ | $$$$$$$ |  $$ |    $$$$$$$$ |$$ |  \__|\__|
$$ |  $$ |$$ |  $$ |$$ |  $$ |$$  __$$ |  $$ |$$\ $$   ____|$$ |
\$$$$$$  |$$$$$$$  |\$$$$$$$ |\$$$$$$$ |  \$$$$  |\$$$$$$$\ $$ |      $$\
 \______/ $$  ____/  \_______| \_______|   \____/  \_______|\__|      \__|
          $$ |
          $$ |
          \__|
EOF
}

# Function to check for Pacman database errors and offer to run Ppm_db_fixer
check_pacman_db_error() {
    local error_message="$1"
    
    # Only proceed if the error message matches specific database-related patterns
    if [[ "$error_message" =~ (database|keyring|sync|lock|gnupg) ]]; then
        echo -e "${YELLOW}==>> Potential Pacman database issue detected.${NC}"
        echo -e "${YELLOW}==>> Checking Pacman database integrity...${NC}"
        if ! sudo pacman -Dk; then
            echo -e "${RED}!! Database issue detected: $error_message${NC}"
        fi
        
        read -rp "$(echo -e "${MAGENTA}Would you like to run the Pacman database repair script? (y/N)${NC} ")" repair_choice
        
        # Convert input to lowercase
        repair_choice=$(echo "$repair_choice" | tr '[:upper:]' '[:lower:]')
        
        if [[ "$repair_choice" == "y" || "$repair_choice" == "yes" ]]; then
            # Check if Ppm_db_fixer.sh exists in the same directory
            local script_dir
            script_dir=$(dirname "$(readlink -f "$0")")
            local db_fixer_script="${script_dir}/Ppm_db_fixer.sh"
            
            if [[ ! -f "$db_fixer_script" ]]; then
                echo -e "${YELLOW}Ppm_db_fixer.sh not found. Attempting to download...${NC}"
                
                # Check if git is installed
                if ! command -v git &> /dev/null; then
                    echo -e "${ORANGE}Git is not installed. Attempting to install...${NC}"
                    sudo pacman -S --noconfirm git
                fi
                
                # Clone the repository
                echo -e "${LIGHT_BLUE}==>> Cloning Ppm_db_fixer from GitHub...${NC}"
                if git clone https://github.com/Made2Flex/Ppm_db_fixer.git "$script_dir/Ppm_db_fixer"; then
                    db_fixer_script="$script_dir/Ppm_db_fixer/Ppm_db_fixer.sh"
                    
                    # Make the script executable
                    echo -e "${BLUE}  >> Making Ppm_db_fixer.sh executable...${NC}"
                    chmod +x -v "$db_fixer_script"
                    
                    echo -e "${GREEN}Successfully downloaded Ppm_db_fixer.sh${NC}"
                else
                    echo -e "${RED}!! Failed to download Ppm_db_fixer script.${NC}"
                    echo -e "${YELLOW}Please download manually from: https://github.com/Made2Flex/Ppm_db_fixer${NC}"
                    return 1
                fi
            fi
            
            # Run the database repair script
            if [[ -f "$db_fixer_script" ]]; then
                echo -e "${LIGHT_BLUE}==>> Running Pacman database repair script...${NC}"
                sudo bash "$db_fixer_script"
                return $?  # Return the exit status of the repair script
            else
                echo -e "${RED}!! Pacman database repair script not found.${NC}"
                echo -e "${YELLOW}Please download Ppm_db_fixer.sh and run it manually.${NC}"
                return 1
            fi
        else
            echo -e "${ORANGE}Skipping Pacman database repair.${NC}"
            return 1
        fi
    fi
    
    # If no database-related error was detected
    return 0
}

# Run_command function
run_command() {
    local command="$1"
    local output
    
    # Capture both stdout and stderr
    output=$(eval "$command" 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        echo -e "${RED}Command failed with exit code $exit_code:${NC}"
        echo "$output"
        
        # Pass the error output to check_pacman_db_error
        check_pacman_db_error "$output"
        
        return 1
    fi
    
    return 0
}

# Function to check if running in a terminal and offer to open one if not
get_script_path() {
    # Resolve the full path of the current script
    readlink -f "$0"
}

run_command() {
    local command="$1"
    if ! eval "$command" 2>/dev/null; then
        return 1
    fi
}

check_terminal() {
    # Check if stdin is a terminal
    if [ ! -t 0 ]; then
        # Silence GTK warnings by redirecting stderr to 2>/dev/null
        local zenity_command="zenity --question --title='Terminal Required' --text='This program must be run in a terminal. Do you want to open a terminal now?' 2>/dev/null"
        
        if eval "$zenity_command"; then
            local script_path
            script_path=$(get_script_path)

            # Try various terminal emulators
            local terminal_commands=(
                "xdg-terminal \"$script_path\""
                "gnome-terminal -- \"$script_path\""
                "konsole -e \"$script_path\""
                "xfce4-terminal --command=\"$script_path\""
                "mate-terminal -e \"$script_path\""
                "xterm -e \"$script_path\""
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
            # User cancelled the dialog
            exit 1
        fi
        exit 1
    fi
}

# Function to show ascii art header
show_ascii_header() {
    echo -e "${BLUE}"
    ascii_art_header
    echo -e "${NC}"
    sleep 1
}

# Localization function
get_system_language() {
    # Get the system's default language
    local lang=${LANG:-en_US.UTF-8}

    # Extract language code
    local language_code=$(echo "$lang" | cut -d'_' -f1)

    # Define translations
    case "$language_code" in
        "es")
            # Spanish translations
            GREET_MESSAGE="¡Hola, %s-sama!"
            UPDATE_PROMPT="¿Quieres actualizar ahora? (Sí/No): "
            ;;
        "fr")
            # French translations
            GREET_MESSAGE="Bonjour, %s-sama!"
            UPDATE_PROMPT="Voulez-vous mettre à jour maintenant ? (Oui/Non) : "
            ;;
        "de")
            # German translations
            GREET_MESSAGE="Hallo, %s-sama!"
            UPDATE_PROMPT="Möchten Sie jetzt aktualisieren? (Ja/Nein): "
            ;;
        "ja")
            # Japanese translations
            GREET_MESSAGE="%s-sama、こんにちは！"
            UPDATE_PROMPT="今すぐ更新しますか？ (はい/いいえ): "
            ;;
        *)
            # Default to English
            GREET_MESSAGE="Hello, %s-sama!"
            UPDATE_PROMPT="Do you want to update Now? (Yes/No): "
            ;;
    esac
}

# Modify greet_user function
greet_user() {
    local username
    username=$(whoami)

    # Get system language translations
    get_system_language

    # Use the appropriate greeting
    printf "${GREEN}$GREET_MESSAGE${NC}\n" "$username"
}

# New function to detect distribution
detect_distribution() {
    # Default values
    DISTRO=""
    DISTRO_ID=""
    PACKAGE_MANAGER=""
    MIRROR_REFRESH_CMD=""

    # Check for distribution
    if [ -f /etc/os-release ]; then
        # Source the os-release file to get distribution information
        source /etc/os-release

        # Normalize ID to lowercase
        DISTRO_ID=$(echo "$ID" | tr '[:upper:]' '[:lower:]')

        case "$DISTRO_ID" in
            "arch")
                DISTRO="Arch Linux"
                PACKAGE_MANAGER="pacman"
                MIRROR_REFRESH_CMD="reflector --verbose -c US --protocol https --sort rate --latest 20 --download-timeout 5 --save /etc/pacman.d/mirrorlist"
                ;;
            "manjaro")
                DISTRO="Manjaro Linux"
                PACKAGE_MANAGER="pacman"
                MIRROR_REFRESH_CMD="sudo pacman-mirrors --geoip"
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
                MIRROR_REFRESH_CMD="sudo nala fetch --auto --fetches 10 --country US" # change US to your actual country.
                ;;
            *)
                echo -e "${RED}!!! Unsupported distribution: $DISTRO_ID${NC}"
                sleep 1
                echo -e "${MAGENTA}==>> Please report this to the developer. Or kindly add support for your distro yourself!${NC}"
                exit 1
                ;;
        esac
    else
        echo -e "${RED}Unable to detect distribution${NC}"
        exit 1
    fi
}

# Updated check_dependencies function
check_dependencies() {
    # Detect distribution first
    detect_distribution

    local missing_deps=()
    local deps=()

    # Define dependencies based on distribution
    case "$DISTRO_ID" in
        "arch")
            deps=("sudo" "pacman" "yay")
            ;;
        "manjaro")
            deps=("sudo" "pacman" "pacman-mirrors")
            ;;
        "endeavouros")
            deps=("sudo" "pacman" "eos-rankmirrors" "reflector")
            ;;
        "debian"|"ubuntu"|"linuxmint")
            deps=("sudo" "apt" "nala")
            ;;
        *)
            echo -e "${RED}!! Unsupported distribution for dependency check.${NC}"
            exit 1
            ;;
    esac

    # Check for missing dependencies
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    # If there are missing dependencies
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${RED}!! The following dependencies are missing:${NC}"
        for dep in "${missing_deps[@]}"; do
            echo -e "${WHITE}  - $dep${NC}"
        done

        # Prompt user to install
        read -rp "Do you want to install the missing dependencies? (Yes/No): " response
        response=$(echo "$response" | tr '[:upper:]' '[:lower:]')

        if [[ -z "$response" || "$response" == "yes" || "$response" == "y" ]]; then
            echo -e "${ORANGE}==>> Installing missing dependencies...${NC}"
            # Distribution-specific dependency installation
            case "$DISTRO_ID" in
                "arch"|"manjaro"|"endeavouros")
                    # Arch-based specific installations
                    if [[ " ${missing_deps[@]} " =~ " sudo " ]]; then
                        echo -e "${LIGHT_BLUE}  >> Installing sudo...${NC}"
                        su -c "pacman -S --noconfirm sudo"
                    fi

                    if [[ " ${missing_deps[@]} " =~ " yay " ]]; then
                        echo -e "${LIGHT_BLUE}  >> Attempting to install yay from repo...${NC}"
                        if sudo pacman -S --noconfirm yay 2>/dev/null; then
                            echo -e "${GREEN}Successfully installed yay from repo${NC}"
                        else
                            echo -e "${RED}!! Failed to install yay from repo.${NC}"
                            echo -e "${LIGHT_BLUE}  >> Installing git and building from AUR...${NC}"
                            sudo pacman -S --noconfirm base-devel git
                            echo -e "${LIGHT_BLUE}  >> Cloning and building yay from AUR...${NC}"
                            git clone https://aur.archlinux.org/yay.git
                            cd yay || exit
                            makepkg -si --noconfirm
                            cd .. || exit
                            echo -e "${LIGHT_BLUE}  >> Removing previously created yay source directory...${NC}"
                            rm -rfv yay
                        fi

                        # Prompt to remove git
                        read -rp "Do you want to remove previously installed git? (Yes/No): " git_remove
                        git_remove=$(echo "$git_remove" | tr '[:upper:]' '[:lower:]')
                        if [[ -z "$git_remove" || "$git_remove" == "yes" || "$git_remove" == "y" ]]; then
                            sudo pacman -Rns --noconfirm git
                        fi
                    fi
                    ;;
                "debian"|"ubuntu"|"linuxmint")
                    # Debian-based specific installations
                    if [[ " ${missing_deps[@]} " =~ " nala " ]]; then
                        echo -e "${BLUE}  >> Installing nala...${NC}"
                        sudo apt update
                        sudo apt install -y nala
                    fi
                    ;;
                *)
                    echo -e "${RED}!! Unsupported distribution for dependency installation.${NC}"
                    exit 1
                    ;;
            esac

            echo -e "${GREEN}==>> Dependencies installed successfully!${NC}"
        else
            echo -e "${RED}!!! Missing dependencies. Cannot proceed.${NC}"
            exit 1
        fi
    fi
}

# Function to create timestamped log file
create_timestamped_log() {
    local original_log_file="$1"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_dir=$(dirname "$original_log_file")
    local filename=$(basename "$original_log_file")
    local timestamped_log_file="${log_dir}/${timestamp}_${filename}"

    # Copy the original log file with timestamp
    cp "$original_log_file" "$timestamped_log_file"

    echo "$timestamped_log_file"
}

# function to create pkglist with timestamped logging
create_pkg_list() {
    local log_file=""
    local pkg_list_file=""
    local backup_dir=""

    # Detect distribution-specific paths
    case "$DISTRO_ID" in
        "arch"|"manjaro"|"endeavouros")
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
        echo -e "${RED}!!! Backup directory is not writable: $backup_dir${NC}"
        mkdir -p "$backup_dir" 2>/dev/null
        if [ $? -ne 0 ]; then
            echo -e "${RED}!! Cannot create backup directory. Check permissions.${NC}"
            return 1
        fi
    fi

    case "$DISTRO_ID" in
        "arch"|"manjaro"|"endeavouros")
            # Capture package list with error handling
            if sudo pacman -Qeq > "$pkg_list_file" 2>"$log_file"; then
                local pkg_count=$(pacman -Q | wc -l)
                echo -e "${ORANGE}==>> Total Installed Packages: ${WHITE}$pkg_count${NC}"
                echo -e "${BLUE}  >> Package list saved to $pkg_list_file${NC}"
            else
                local timestamped_log=$(create_timestamped_log "$log_file")
                echo -e "${RED}!!! Error creating package list. See $timestamped_log for details.${NC}"
                return 1
            fi
            ;;
        "debian"|"ubuntu"|"linuxmint")
            # Capture package list with error handling
            if sudo dpkg-query -f '${binary:Package}\n' -W > "$pkg_list_file" 2>"$log_file"; then
                local pkg_count=$(dpkg-query -f '${binary:Package}\n' -W | wc -l)
                echo -e "${ORANGE}==>> Total Installed Packages: $pkg_count${NC}"
                echo -e "${BLUE}  >> Package list saved to $pkg_list_file${NC}"

                # Create explicit package list with Nala if available
                if command -v nala &> /dev/null; then
                    local explicit_pkg_file="$backup_dir/debian-explicit-pkgs.txt"
                    sudo nala history --installed > "$explicit_pkg_file"
                    echo -e "${BLUE}  >> Explicit package list created at $explicit_pkg_file${NC}"
                fi
            else
                local timestamped_log=$(create_timestamped_log "$log_file")
                echo -e "${RED}!! Error creating package list. See $timestamped_log for details.${NC}"
                return 1
            fi
            ;;
    esac
}

# Global variable to store AUR packages
AUR_PACKAGES=""

# function to create aur-pkglist with timestamped logging
create_aur_pkg_list() {
    # Only proceed for Arch-based distributions
    case "$DISTRO_ID" in
        "arch"|"manjaro"|"endeavouros")
            local log_file="$HOME/bk/arch/aur-pkglst.log"
            local aur_pkg_list_file="$HOME/bk/arch/aur-pkglst.txt"

            # Capture AUR packages and save to file
            error_output=$(sudo pacman -Qmq 2>&1)
            if [ $? -eq 0 ]; then
                AUR_PACKAGES="$error_output"
                echo "$AUR_PACKAGES" > "$aur_pkg_list_file"

                echo -e "${ORANGE}==>> Installed AUR Packages...${NC}"
                echo "$AUR_PACKAGES"

                if [ -n "$AUR_PACKAGES" ]; then
                    echo -e "${BLUE}  >> Copy Has Been Placed In $aur_pkg_list_file${NC}"
                    return 0  # Indicate AUR packages exist
                else
                    echo -e "${LIGHT_BLUE}  >> No AUR packages found.${NC}"
                    return 1  # Indicate no AUR packages
                fi
            else
                # Create timestamped log file for the error
                local timestamped_log=$(create_timestamped_log "$log_file")
                echo "$error_output" > "$timestamped_log"
                echo -e "${RED}!! Error getting AUR package list. See $timestamped_log for details.${NC}"
                return 1
            fi
            ;;
        *)
            echo -e "${LIGHT_BLUE}  >> Skipping AUR package list (not an Arch-based distribution)${NC}"
            return 1
            ;;
    esac
}

# Function to check if mirror sources are refreshed
check_mirror_source_refreshed() {
    echo -e "${ORANGE}==>> Checking mirror sources...${NC}"

    case "$DISTRO_ID" in
        "arch"|"manjaro"|"endeavouros")
            local mirror_sources_file="/etc/pacman.d/mirrorlist"
            local mirror_sources_backup="/etc/pacman.d/mirrorlist.backup.$(date +"%Y%m%d_%H%M%S")"

            if [[ -f "$mirror_sources_file" ]]; then
                local last_modified=$(stat -c %Y "$mirror_sources_file")
                local now=$(date +%s)
                local week_seconds=$((7 * 24 * 3600))

                if (( (now - last_modified) > week_seconds )); then
                    echo -e "${MAGENTA}  >> Mirror source $mirror_sources_file hasn't been refreshed in over a week!${NC}"
                    echo -e "${ORANGE}  >> Backing up current mirrorlist...${NC}"

                    # Backup the current mirrorlist with a timestamped filename
                    sudo cp "$mirror_sources_file" "$mirror_sources_backup"
                    echo -e "${BLUE}  >> Mirrorlist backed up to $mirror_sources_backup${NC}"

                    echo -e "${ORANGE}==>> Refreshing Mirrors...${NC}"

                    # Handle multiple mirror refresh commands for EndeavourOS
                    if [[ "$DISTRO_ID" == "endeavouros" ]]; then
                        # Try both commands
                        if command -v eos-rankmirrors &> /dev/null; then
                            echo -e "${LIGHT_BLUE}  >> Running eos-rankmirrors...${NC}"
                            if eos-rankmirrors; then
                                echo -e "${GREEN}  >> eos-rankmirrors completed successfully${NC}"
                            else
                                echo -e "${RED}!! eos-rankmirrors failed${NC}"
                            fi
                        fi

                        if command -v reflector &> /dev/null; then
                            echo -e "${LIGHT_BLUE}  >> Running reflector...${NC}"
                            if sudo reflector --verbose -c US --protocol https --sort rate --latest 20 --download-timeout 5 --save /etc/pacman.d/mirrorlist; then
                                echo -e "${GREEN}  >> reflector completed successfully${NC}"
                            else
                                echo -e "${RED}!! reflector failed${NC}"
                            fi
                        fi
                    else
                        # For other distributions, use the single MIRROR_REFRESH_CMD
                        $MIRROR_REFRESH_CMD
                    fi

                    echo -e "${GREEN}  >> Mirrors have been refreshed!${NC}"
                else
                    echo -e "${GREEN}  >> Mirror source is fresh. Moving On!${NC}"
                fi
            else
                echo -e "${RED}!!! Mirror source file not found: $mirror_sources_file${NC}"
            fi
            ;;
        "debian"|"ubuntu"|"linuxmint")
            local nala_sources_file="/etc/apt/sources.list.d/nala-sources.list"

            if [[ -f "$nala_sources_file" ]]; then
                local last_modified=$(stat -c %Y "$nala_sources_file")
                local now=$(date +%s)
                local week_seconds=$((7 * 24 * 3600))

                if (( (now - last_modified) > week_seconds )); then
                    echo -e "${MAGENTA}==>> Nala sources haven't been refreshed in over a week!${NC}"
                    echo -e "${ORANGE}==>> Refreshing Nala sources...${NC}"

                    # Use the MIRROR_REFRESH_CMD
                    sudo $MIRROR_REFRESH_CMD

                    echo -e "${GREEN}==>> Nala sources have been refreshed.${NC}"
                else
                    echo -e "${LIGHT_BLUE}==>> Sources are fresh. Moving On!${NC}"
                fi
            else
                echo -e "${RED}!!! Nala sources file not found: $nala_sources_file${NC}"
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
    # Force output buffer to flush
    >&2 echo -n ""
}

# Global variable to control spinner
spinner_running=false

# Function to create a spinner with colors
start_spinner_spinner() {
    local spinners=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local colors=("$GREEN" "$ORANGE" "$RED" "$BLUE" "$MAGENTA" "$LIGHT_BLUE")
    local delay=0.1

    # Ensure only one spinner runs at a time
    if [ "$spinner_running" = true ]; then
        echo -e "${RED}Warning: Spinner is already running.${NC}" >&2
        return 1
    fi

    spinner_running=true

    # Start spinner in background
    (
        while $spinner_running; do
            for spinner in "${spinners[@]}"; do
                for color in "${colors[@]}"; do
                    if ! $spinner_running; then
                        exit 0  # Explicitly exit the background process
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

# Function to stop the spinner
stop_spinner() {
    spinner_running=false

    # Wait a moment to ensure the spinner stops
    sleep 0.2

    # Kill the spinner process if it exists
    if [ -n "$spinner_pid" ]; then
        kill "$spinner_pid" 2>/dev/null
        wait "$spinner_pid" 2>/dev/null
    fi

    # Clear the line
    printf "\r%*s\r" $(tput cols) >&2

    # Reset global variables
    spinner_pid=""
}

# Function to update the system
update_system() {
    case "$DISTRO_ID" in
        "arch"|"manjaro"|"endeavouros")
            echo -e "${ORANGE}==>> Checking 'pacman' packages to update...${NC}"
            sudo pacman -Syyuu --noconfirm --needed --color=auto

            # Use the global AUR_PACKAGES variable to determine AUR updates
            if [ -n "$AUR_PACKAGES" ]; then
                echo -e "${ORANGE}==>> Inspecting yay cache...${NC}"
                # Check yay cache exists
                if [ -d "$HOME/.cache/yay" ]; then
                    # Check if yay cache is empty
                    if [ -z "$(find "$HOME/.cache/yay" -maxdepth 1 -type d | grep -v "^$HOME/.cache/yay$")" ]; then
                        echo -e "${GREEN}  >> yay cache is clean${NC}"
                    else
                        # Collect directories to be cleaned
                        mapfile -t yay_cache_dirs < <(find "$HOME/.cache/yay" -maxdepth 1 -type d | grep -v "^$HOME/.cache/yay$")
                        
                        if [ ${#yay_cache_dirs[@]} -gt 0 ]; then
                            echo -e "${ORANGE}==>> Cleaning yay cache directories: ${NC}"
                            printf "${WHITE}  - %s\n${NC}" "$(basename "${yay_cache_dirs[@]}")"
                        
                        # Remove the directories
                        for dir in "${yay_cache_dirs[@]}"; do
                                rm -rf "$dir"
                            done
                        fi
                    fi
                else
                    echo -e "${RED}!!! yay cache directory not found: $HOME/.cache/yay${NC}"
                fi
                echo -e "${ORANGE}==>> Checking 'aur' packages to update...${NC}"
                yay -Sua
            fi
            ;;
        "debian"|"ubuntu"|"linuxmint")
            echo -e "${ORANGE}==>> Checking for package updates.${NC}"

            # Start spinner in background
            start_spinner_spinner

            # Capture command output and exit status
            local update_output
            local exit_status
            update_output=$(sudo nala update)
            exit_status=$?

            # Stop spinner
            stop_spinner

            # Check command result
            if [ $exit_status -eq 0 ] && echo "$update_output" | grep -q 'packages can be upgraded'; then
                echo -e "${LIGHT_BLUE}==>> Updates have been found!${NC}"
                echo -e "${ORANGE}==>> Now Witness MEOW POWA!!!!!${NC}"
                sudo nala upgrade --assume-yes --no-install-recommends --no-install-suggests --no-update --full
                echo -e "${GREEN}==>> System has been updated!${NC}"
            elif [ $exit_status -ne 0 ]; then
                echo -e "${RED}!!! Update check failed. See output below:${NC}"
                echo "$update_output"
            else
                echo -e "${ORANGE}==>> No packages to update.${NC}"
            fi
            ;;
        *)
            echo -e "${RED}!!! Unsupported distribution for system update.${NC}"
            exit 1
            ;;
    esac
}

# Function to prompt user to update the system
prompt_update() {
    while true; do
        # Use localized prompt
        get_system_language
        read -rp "$UPDATE_PROMPT" answer
        answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')

        if [[ -z "$answer" || "$answer" == "yes" || "$answer" == "y" ]]; then
            update_system
            break
        elif [[ "$answer" == "no" || "$answer" == "n" ]]; then
            echo -e "${ORANGE}<< You have chosen not to upgrade.${NC}"
            echo -e "${ORANGE}<< There is nothing to do...${NC}"
            sleep 1
            echo -e "${ORANGE}>> Meow Out!${NC}"
            break
        else
            echo -e "${RED}Invalid Input. Please Enter 'yes' or 'no'.${NC}"
        fi
    done
}

# Alchemist den
main() {
    get_system_language  # call it early to set up translations
    check_terminal
    show_ascii_header
    greet_user
    check_dependencies
    create_pkg_list
    create_aur_pkg_list
    check_mirror_source_refreshed
    prompt_update
}

# BoomShackalaka!!
main
