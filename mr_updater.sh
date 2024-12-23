#!/usr/bin/env bash

set -uo pipefail  # Improved error handling
# -e: exit on error
# -u: treat unset variables as an error
# -o pipefail: ensure pipeline errors are captured

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

# Utility function for dynamic color-changing a line
dynamic_color_line() {
    local message="$1"
    #local colors=("red" "yellow" "green" "cyan" "magenta" "blue")
    local colors=("\033[1;31m" "\033[1;33m" "\033[1;32m" "\033[1;36m" "\033[1;35m" "\033[1;34m")
    local NC="\033[0m"
    local delay=0.1
    local iterations=${2:-30}  # Default 30 iterations, but allow customization

    {
        for ((i=1; i<=iterations; i++)); do
            # Cycle through colors
            color=${colors[$((i % ${#colors[@]}))]}

            # Use \r to return to start of line, update with new color
            printf "\r${color}==>> ${message}${NC}"

            sleep "$delay"
        done

        # Final clear line
        #printf "\r\033[K"
        # Add a newline to move to the next line
        printf "\n"
    } >&2
}

# Function to check if pacman db is locked
check_db_lock() {
    if [[ -f /var/lib/pacman/db.lck ]]; then
        echo -e "${RED}!!! Pacman database is locked.${NC}"
        return 1 # Return failure instead of exiting
    fi
    return 0 # Return success if no lock is found
}

# Function to remove pacman db lock
remove_db_lock() {
    echo -e "${LIGHT_BLUE}==>> Removing pacman db lock...${NC}"
    sudo rm -fv /var/lib/pacman/db.lck
}

# Function to check for Pacman database errors and offer to run Ppm_db_fixer
check_pacman_db_error() {
    local error_message="$1"
    
    # Only proceed if the error message matches specific database-related patterns
    if [[ "$error_message" =~ (databases|lock|locked) ]]; then
        # Remove db lock if it exists
        echo -e "${LIGHT_BLUE}==>> Checking for pacman db lock...${NC}"
        if ! check_db_lock; then
            remove_db_lock
            update_system
        else
            echo -e "${GREEN}>> Pacman db lock not found.${NC}"
        fi
    elif [[ "$error_message" =~ (database|keyring|sync|gnupg) ]]; then
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
                echo -e "${YELLOW}==>> Ppm_db_fixer.sh not found. Attempting to download...${NC}"
                
                # Check if git is installed
                if ! command -v git &> /dev/null; then
                    echo -e "${ORANGE}==>> Git is not installed. Attempting to install...${NC}"
                    sudo pacman -S --noconfirm git
                fi
                
                # Clone the repository
                echo -e "${LIGHT_BLUE}==>> Cloning Ppm_db_fixer from GitHub...${NC}"
                if git clone https://github.com/Made2Flex/Ppm_db_fixer.git "$script_dir/Ppm_db_fixer"; then
                    db_fixer_script="$script_dir/Ppm_db_fixer/Ppm_db_fixer.sh"
                    
                    # Make the script executable
                    echo -e "${BLUE}  >> Making Ppm_db_fixer.sh executable...${NC}"
                    chmod +x -v "$db_fixer_script"
                    
                    echo -e "${GREEN}==>> ✓ Successfully downloaded Ppm_db_fixer.sh${NC}"
                else
                    echo -e "${RED}!! Failed to download Ppm_db_fixer script.${NC}"
                    echo -e "${YELLOW}==>> Please download manually from: https://github.com/Made2Flex/Ppm_db_fixer${NC}"
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

# Function to run command, check for errors and pass it to check_pacman_db_error
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

# Function to greet user
greet_user() {
    local username
    username=$(whoami)

    # Get system language translations
    get_system_language

    # Use the appropriate greeting
    printf "${GREEN}$GREET_MESSAGE${NC}\n" "$username"
}

# Function to detect distribution
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

# Function to warn user about manual installation
warn_manual_install() {
    echo -e "${RED}!!! Unable to automatically install dependencies.${NC}"
    echo -e "${ORANGE}==>> Please install dependencies manually:${NC}"
    echo -e "  1. Download the dep_package from the internet"
    echo -e "  2. Use: sudo dpkg -i dep_package.deb"
    dynamic_color_line "Manual intervention required to install deps."
    sleep 1
    echo -e "${ORANGE} ==>> Now exiting...${NC}"
    exit 1
}

# Function to check_dependencies
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
                            echo -e "${GREEN}  >> ✓Successfully installed yay from repo${NC}"
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
                        else
                            echo -e "${ORANGE}==>> Continuing without removing git...${NC}"
                        fi
                    fi
                    ;;
                "debian"|"ubuntu"|"linuxmint")
                    # Check if apt is available
                        if command -v apt &> /dev/null; then
                            for dep in "${missing_deps[@]}"; do
                                echo -e "${LIGHT_BLUE}  >> Installing $dep...${NC}"
                                sudo apt install -y "$dep"
                            done
                        fi
                    ;;
                *)
                    echo -e "${RED}!! Unsupported distribution for dependency installation.${NC}"
                    warn_manual_install
                    exit 1
                    ;;
            esac

            echo -e "${GREEN}==>> Dependencies installed ✓successfully!${NC}"
        else
            echo -e "${RED}!!! Missing dependencies. Cannot proceed.${NC}"
            dynamic_color_line "Try to install them manually, then run the script again."
            sleep 1
            echo -e "${ORANGE} ==>> Now exiting."
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

# Function to create pkglist with timestamped logging
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

# Function to create aur-pkglist with timestamped logging
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
                    echo -e "${BLUE}  >> Copy has been placed in $aur_pkg_list_file${NC}"
                    return 0
                else
                    echo -e "${LIGHT_BLUE}  >> No AUR packages found.${NC}"
                    return 0
                fi
            else
                # Create timestamped log file for the error
                local timestamped_log=$(create_timestamped_log "$log_file")
                echo "$error_output" > "$timestamped_log"
                echo -e "${RED}!! Error getting AUR package list. See $timestamped_log for details.${NC}"
                return 0
            fi
            ;;
        *)
            echo -e "${LIGHT_BLUE}  >> Skipping AUR package list (not an Arch-based distribution)${NC}"
            return 0
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
                                echo -e "${GREEN}  >> eos-rankmirrors completed ✓successfully${NC}"
                            else
                                echo -e "${RED}!! eos-rankmirrors failed${NC}"
                            fi
                        fi

                        if command -v reflector &> /dev/null; then
                            echo -e "${LIGHT_BLUE}  >> Running reflector...${NC}"
                            if sudo reflector --verbose -c US --protocol https --sort rate --latest 20 --download-timeout 5 --save /etc/pacman.d/mirrorlist; then
                                echo -e "${GREEN}  >> reflector completed ✓successfully${NC}"
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
                    echo -e "${GREEN}  >> Mirror source is fresh. moving on!${NC}"
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
                            for dir in "${yay_cache_dirs[@]}"; do
                                printf "${WHITE}  - %s\n${NC}" "$(basename "$dir")"  # Use basename for each directory
                                # Remove the directories
                                rm -rf "$dir"
                            done
                        fi
                    fi
                else
                    echo -e "${RED}!!! yay cache directory not found: $HOME/.cache/yay${NC}"
                fi
                echo -e "${ORANGE}==>> Checking 'aur' packages to update...${NC}"
                yay -Sua --norebuild --noredownload --removemake --answerclean A --noanswerdiff --noansweredit --noconfirm --cleanafter
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
                return 1
            else
                echo -e "${ORANGE}==>> No packages to update.${NC}"
                return 0
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
        read -rp "$(echo -e "${MAGENTA}$UPDATE_PROMPT")" answer
        answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')

        if [[ -z "$answer" || "$answer" == "yes" || "$answer" == "y" ]]; then
            update_system
            break
        elif [[ "$answer" == "no" || "$answer" == "n" ]]; then
            echo -e "${ORANGE}<< You have chosen not to upgrade.${NC}"
            echo -e "${ORANGE}<< There is nothing to do...${NC}"
            echo -e "${ORANGE}>> Meow Out!${NC}"
            break
        else
            echo -e "${RED}Invalid Input. Please Enter 'yes' or 'no'.${NC}"
        fi
    done
}

# Global variables to store BTRFS flags
BTRFS_CHECKED=false
BTRFS_SNAPSHOTS_SETUP=false

# Path to the STATE_FILE
# It stores the value of the above flags
STATE_FILE="$HOME/.config/mr_updater/btrfs_snapshot_state.txt"

# Function to load the state from the STATE_FILE
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
    else
        # Create the directory if it doesn't exist
        mkdir -p "$(dirname "$STATE_FILE")"
        
        BTRFS_CHECKED=false
        BTRFS_SNAPSHOTS_SETUP=false
        
        # Create the state file with default values if it doesn't exist
        echo "BTRFS_CHECKED=$BTRFS_CHECKED" > "$STATE_FILE"
        echo "BTRFS_SNAPSHOTS_SETUP=$BTRFS_SNAPSHOTS_SETUP" >> "$STATE_FILE"
    fi
}

# Function to save the state to the STATE_FILE
save_state() {
    echo "BTRFS_CHECKED=$BTRFS_CHECKED" > "$STATE_FILE"
    echo "BTRFS_SNAPSHOTS_SETUP=$BTRFS_SNAPSHOTS_SETUP" >> "$STATE_FILE"
}

# Function to check if the filesystem is BTRFS and if snapshots are set up
check_btrfs_snapshots() {
    # Load the state from the STATE_FILE
    load_state

    # Check if the filesystem is BTRFS and if it hasn't been checked yet
    if [[ "$BTRFS_CHECKED" == false && "$(lsblk -f | grep -E 'btrfs')" ]]; then
        echo -e "${GREEN}==>> Detected BTRFS filesystem.${NC}"
        BTRFS_CHECKED=true

        # Check if BTRFS snapshots are set up
        if [[ "$BTRFS_SNAPSHOTS_SETUP" == false ]]; then
            echo -e "${ORANGE}==>> Checking if BTRFS snapshots are set up...${NC}"

            # Use btrfs command to check for existing snapshots
            if sudo btrfs subvolume list / | grep -q "snapshot"; then
                echo -e "${GREEN}  >> BTRFS snapshots are already set up.${NC}"
                BTRFS_SNAPSHOTS_SETUP=true
            else
                echo -e "${RED}==>> BTRFS snapshots are not set up.${NC}"
                read -rp "$(echo -e "${MAGENTA}Would you like to set up BTRFS snapshots? (y/N)${NC} ")" setup_choice
                setup_choice=$(echo "$setup_choice" | tr '[:upper:]' '[:lower:]')

                if [[ "$setup_choice" == "y" || "$setup_choice" == "yes" || -z "$setup_choice" ]]; then
                    # Check if git is installed
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
                            echo -e "${GREEN}==>> BTRFS snapshots have been set up ✓ successfully!${NC}"
                            BTRFS_SNAPSHOTS_SETUP=true
                        else
                            echo -e "${RED}==>> Failed to set up BTRFS snapshots.${NC}"
                        fi

                        # Clean up
                        echo -e "${ORANGE}==>> Removing previously created directory..."
                        rm -rfv "$script_dir/setupsnapshots"

                        # Prompt to remove git
                        if command -v git &> /dev/null; then
                            read -rp "$(echo -e "${MAGENTA}Would you like to remove previously installed git? (y/N)${NC} ")" git_remove_choice
                            git_remove_choice=$(echo "$git_remove_choice" | tr '[:upper:]' '[:lower:]')

                            if [[ "$git_remove_choice" == "y" || "$git_remove_choice" == "yes" || -z "$git_remove_choice" ]]; then
                                sudo pacman -Rns --noconfirm git
                            fi    
                        fi
                    else
                        echo -e "${RED}!! setupsnapshots.sh not found after cloning.${NC}"
                    fi
                else
                    echo -e "${ORANGE}==>> To run the BTRFS snapshot setup again, set BTRFS_CHECKED=false and BTRFS_SNAPSHOTS_SETUP=false in /tmp/btrfs_snapshot_state.txt or remove the file.${NC}"
                    echo -e "${ORANGE}==>> Skipping BTRFS snapshot setup.${NC}"
                    BTRFS_CHECKED=true  # Set flag to avoid asking again
                fi
            fi
        fi
    elif [[ "$BTRFS_CHECKED" == true ]]; then
        return 0
    else
        echo -e "${RED}!! Not a BTRFS filesystem. Skipping snapshot setup.${NC}"
    fi

    # Save the state to STATE_FILE
    save_state
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
    check_btrfs_snapshots
    prompt_update
}

# BoomShackalaka!!
main
