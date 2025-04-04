#!/bin/bash

# Configuration file path
CONFIG_FILE="$HOME/.login_monitor_config"
DAILY_LOG_FILE="/tmp/login_monitor_daily.log"
HOSTNAME=$(hostname)

# --- Setup Function ---
setup_monitor() {
    echo "--- Login Monitor Setup ---"
    read -p "Enter the email address for notifications: " NOTIFY_EMAIL
    if [[ -z "$NOTIFY_EMAIL" ]]; then
        echo "Error: Email address cannot be empty."
        exit 1
    fi
    echo "NOTIFY_EMAIL=$NOTIFY_EMAIL" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" # Restrict permissions
    echo "Configuration saved to $CONFIG_FILE"
    # Create the daily log file if it doesn't exist
    touch "$DAILY_LOG_FILE"
    chmod 600 "$DAILY_LOG_FILE"
    echo "Setup complete. Please start the script again without the --setup flag."
    exit 0
}

# --- Check for Setup Argument ---
if [[ "$1" == "--setup" ]]; then
    setup_monitor
fi

# --- Load Configuration ---
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Configuration file not found. Please run with --setup first:"
    echo "$0 --setup"
    exit 1
fi

source "$CONFIG_FILE"

if [[ -z "$NOTIFY_EMAIL" ]]; then
    echo "Error: NOTIFY_EMAIL not set in $CONFIG_FILE. Please run with --setup again."
    exit 1
fi

echo "Starting login monitor for $HOSTNAME. Sending alerts to $NOTIFY_EMAIL."
echo "Monitoring log file: /var/log/auth.log"
echo "Press Ctrl+C to stop."

# --- Log Monitoring Loop ---
# Use tail -f to follow the log file. Need sudo/root privileges to read auth.log
# Use stdbuf to disable buffering for grep to ensure immediate output
sudo tail -n 0 -F /var/log/auth.log | stdbuf -oL grep --line-buffered -E 'sshd.*(Accepted|Failed|failure)|login.*session opened|su.*session opened' | while IFS= read -r line
do
    TIMESTAMP=$(echo "$line" | awk '{print $1, $2, $3}')
    EVENT_DETAILS=""
    LOG_ENTRY=""

    # --- Parse Different Log Line Formats ---

    # SSH Successful Login (Password/Key)
    if echo "$line" | grep -q "sshd.*Accepted"; then
        USER=$(echo "$line" | grep -oP 'for \K\S+')
        IP=$(echo "$line" | grep -oP 'from \K\S+')
        PORT=$(echo "$line" | grep -oP 'port \K\S+')
        EVENT_DETAILS="Successful SSH login for user '$USER' from IP '$IP' on port '$PORT'"
        LOG_ENTRY="$TIMESTAMP SUCCESS SSH User: $USER IP: $IP Port: $PORT"

    # SSH Failed Login
    elif echo "$line" | grep -q "sshd.*Failed password"; then
        USER=$(echo "$line" | grep -oP 'for (invalid user )?\K\S+')
        IP=$(echo "$line" | grep -oP 'from \K\S+')
        PORT=$(echo "$line" | grep -oP 'port \K\S+')
        EVENT_DETAILS="Failed SSH login attempt for user '$USER' from IP '$IP' on port '$PORT'"
        LOG_ENTRY="$TIMESTAMP FAILED SSH User: $USER IP: $IP Port: $PORT"

    # SSH Authentication Failure (More generic)
    elif echo "$line" | grep -q "sshd.*authentication failure"; then
        IP=$(echo "$line" | grep -oP 'rhost=\K\S+' || echo "N/A") # May not always have rhost
        USER=$(echo "$line" | grep -oP 'user=\K\S+' || echo "N/A") # May not always have user
        EVENT_DETAILS="SSH authentication failure. User: '$USER', Source IP: '$IP'"
        LOG_ENTRY="$TIMESTAMP FAILED SSH_AUTH_FAIL User: $USER IP: $IP"

    # Local Login Session Opened (e.g., tty)
    elif echo "$line" | grep -q "login.*session opened"; then
        USER=$(echo "$line" | grep -oP 'for user \K\S+')
        TTY=$(echo "$line" | grep -oP 'by \K\S+' | tr -d '()') # Get process/user initiating
        EVENT_DETAILS="Local login session opened for user '$USER' (Initiated by '$TTY')"
        LOG_ENTRY="$TIMESTAMP SUCCESS LOCAL_LOGIN User: $USER Initiator: $TTY"

    # SU Session Opened
    elif echo "$line" | grep -q "su.*session opened"; then
        TARGET_USER=$(echo "$line" | grep -oP 'for user \K\S+')
        ORIG_USER=$(echo "$line" | grep -oP 'by \K\S+' | tr -d '()')
        EVENT_DETAILS="Session opened for user '$TARGET_USER' by user '$ORIG_USER' (su)"
        LOG_ENTRY="$TIMESTAMP SUCCESS SU TargetUser: $TARGET_USER OrigUser: $ORIG_USER"

    fi

    # --- Send Email and Log if Event Detected ---
    if [[ -n "$EVENT_DETAILS" ]]; then
        SUBJECT="Login Alert on $HOSTNAME: $EVENT_DETAILS"
        BODY="Host: $HOSTNAME\nTimestamp: $TIMESTAMP\nEvent: $EVENT_DETAILS\n\nRaw Log Line:\n$line"

        # Send email
        echo -e "$BODY" | mail -s "$SUBJECT" "$NOTIFY_EMAIL"
        echo "Alert sent: $SUBJECT"

        # Append to daily log file (ensure file exists and has correct permissions)
        if [[ -n "$LOG_ENTRY" ]]; then
           echo "$LOG_ENTRY" >> "$DAILY_LOG_FILE"
        fi
    fi
done

echo "Login monitor stopped."
