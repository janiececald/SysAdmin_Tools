#!/usr/bin/env bash
# User Offboarding Script
# Janiece Caldwell
# Notes: 
# This script uses GAM (Google Apps Manager CLI) to connect with G Suite. Please ensure you have this installed before using this script.
#    * visit https://github.com/jay0lee/GAM/wiki for documentation on GAM 

# Initialize the full path of GAM
GAM=~/bin/gam/gam
GYB=~/bin/gyb/gyb

# Get Command line arguments for Employee Email and Term Type
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
    -e | --email)
        EMPLOYEE="$2"
        shift # past argument
        shift # past value
        ;;
    -t | --termtype)
        TERMTYPE="$2"
        shift # past argument
        shift # past value
        ;;
    *) # unknown option
        POSITIONAL+=("$1") # save it in an array for later
        shift              # past argument
        ;;
    esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

# Verify user exists in Google Suite
email_verification() {
    if ${GAM} info user "${EMPLOYEE}" >/dev/null 2>&1; then
        return
    else
        echo "$EMPLOYEE does not exist in Google Suite."
    fi
    printf %s\\n "Please enter a valid email address."
    exit 1
}

# Verify Termination Type
term_type() {
    case "$TERMTYPE" in
    [Bb] | [Bb]8taTester)
        TERMTYPE=b8taTester
        ;;
    [Cc] | [Cc]orporate)
        TERMTYPE=Corporate
        ;;
    *)
        printf %s\\n "Please enter 'B' or 'C' for Term Type"
        exit 1
        ;;
    esac
}

# Create log file and record user information
start_logger() {
    exec &> >(tee offboard.log)
    echo "$(whoami) conducting $TERMTYPE offboarding for $EMPLOYEE on $(date)"
}

# Get the username and lmeast name of employee
get_name() {
    USER_NAME="${EMPLOYEE//@company.com/}"
    LAST_NAME=$(echo "$USER_NAME" | cut -f2 -d'.')
}

# Add Patrick as manager 
get_manager() {
    MANAGER="patrick@ops-assist.com"
    echo "Manager set to: $MANAGER"
}
#     MANAGER=$(${GAM} info user "${EMPLOYEE}" | grep "manager" -A1 -B1 | grep "value" |
#         cut -f3 -f4 -d' ' | tr " " .)
#         if "${MANAGER}" >/dev/null 2>&1; then
#             ${GAM} user "${EMPLOYEE}" update user relation manager patrick@ops-assist.com
#            echo "Adding Patrick Conroy as Manager"
#         fi
# }

# Reset Employee's account password to a randomly generated password
# This will also reset sign-in cookies
# Forcing change password on next sign-in and then disabling immediately.
# Speculation that this will sign user out within 5 minutes and not allow
# user to send messages without reauthentication
reset_password() {
    echo "Resetting GSuite password"
    PASSWORD=$(openssl rand -base64 12)
    ${GAM} update user "${EMPLOYEE}" password "${PASSWORD}"
    ${GAM} update user "${EMPLOYEE}" changepassword on
    sleep 2
    ${GAM} update user "${EMPLOYEE}" changepassword off
    ${GAM} update user "${EMPLOYEE}" recoveryemail ""
    ${GAM} update user "${EMPLOYEE}" recoveryphone ""
}

# Remove all App-Specific account passwords, delete MFA Recovery Codes,
# Delete all OAuth tokens
# Generating new set of MFA recovery codes for the user
reset_token() {
    echo "Resetting GSuite tokens"
    ${GAM} user "${EMPLOYEE}" deprovision
    ${GAM} user "${EMPLOYEE}" update backupcodes
}

# Remove all email delegation
remove_delegates() {
    if [ "$TERMTYPE" = 'Corporate' ]; then
        echo "Removing email delegates"
        DELEGATES=$(${GAM} user "${EMPLOYEE}" print delegates)
    for DELEGATE in "${DELEGATES[@]}"; do
        ${GAM} user "${EMPLOYEE}" delete delegate "${DELEGATE}"
    done
    fi
}

# Wipe device profile and remove Google accounts from all mobile devices
wipe_devices() {
    echo "  > Wiping all associated mobile devices"
    $GAM print mobile query "email:$EMPLOYEE" >>/tmp/tmp.mobile-data.csv
    $GAM csv /tmp/tmp.mobile-data.csv gam update mobile ~resourceId action account_wipe
}

# Remove all forwarding addresses
# Disable IMAP
# Disable POP
# Hide user from directory
disable_user() {
    echo "  > Disabling Email and hiding from Directory"
    $GAM user "${EMPLOYEE}" forward off
    $GAM user "${EMPLOYEE}" imap off
    $GAM user "${EMPLOYEE}" pop off
    $GAM update user "${EMPLOYEE}" gal off
}

# Retrieve the employee's manager information from Google Suite
# Transfer Google Drive and Documents ownership to Employee's Manager
transfer_drive() {
    if [ "$TERMTYPE" = 'Corporate' ]; then
        echo "  > Transfering Google Drive and documents to Manager"
        ${GAM} create datatransfer "${EMPLOYEE}" gdrive "${MANAGER}"
    fi

}

# Get a list of all groups the employee belongs to
# Remove the employee from all groups
remove_groups() {
    echo "  > Removing user from all groups"
    ${GAM} info user "${EMPLOYEE}" | grep -A 10000 "Groups:" | awk 'BEGIN { FS = ">|<" } ; { print $2 }' >/tmp/"${EMPLOYEE}".txt
    while read -r GROUP; do
        [ -z "$GROUP" ] && continue
        ${GAM} update group "${GROUP}" remove member "${EMPLOYEE}"
    done </tmp/"${EMPLOYEE}".txt
}
# Give manager ownership of calendar
# Show calendar in manager's calendar view
delegate_calendar() {
    if [ "$TERMTYPE" = 'Corporate' ]; then
        echo "  > Delagating Calendar to Manager"
        ${GAM} calendar "${EMPLOYEE}" add owner "${MANAGER}"
        ${GAM} user "${MANAGER}" add calendar "${EMPLOYEE}" selected true
    else
        echo "  > Wiping Calendar"
        ${GAM} calendar "${EMPLOYEE}" wipe
    fi
}
# Delegate email access to manager if termination is Corporate
# Suspend user to kick off all logged in sessions
# Unsuspend Corporate termination user for email delgation
# Verify that user was moved to correct Organizational Unit
suspend_user() {
    if [ "$TERMTYPE" = 'Corporate' ]; then
        echo "  > Granting delegate access to employee manager and moving to Terminations OU"
        ${GAM} user "${EMPLOYEE}" delegate to "${MANAGER}"
        ${GAM} update org 'Terminated' add users "${EMPLOYEE}"
    else
        echo "Suspending user and moving to Terminations OU"
        ${GAM} update user "${EMPLOYEE}" suspended on
        ${GAM} update org 'Terminated' add users "${EMPLOYEE}"
    fi
    ORG_UNIT=$(${GAM} info user "${EMPLOYEE}" | grep "Google Org")
    echo "$EMPLOYEE moved to $ORG_UNIT"
}
unsuspend_user() {
    ${GAM} update user "${EMPLOYEE}" suspended off
    echo "Unsuspending $EMPLOYEE"

}
# Slack deprovisioning
#deprovision_slack() {
#    echo "Deprovisioning in Slack"
#    python3 Slack_API.py --email "$EMPLOYEE"
#}

# Update Jamf device info
#update_jamf() {
#    echo "Updating Device information in JAMF"
#    python3 Update_Jamf_Device.py --l "$LAST_NAME" -s 'TERMED'
#}

# using got your back service to backup email, creates a folder of emails where script is ran
gyb_backup() {
    echo "  > Backing Up Email"
    ${GYB} --email "${EMPLOYEE}" --search "is:important" --service-account 
}

# Permanently deltes user from database
delete_user() {
    ${GAM} delete user "${EMPLOYEE}"
    echo "  > Deleting $EMPLOYEE"
}

# creates a group email with the email address of the termed user
create_group() {
    ${GAM} create group "${EMPLOYEE}" name TERMED_"${EMPLOYEE}" description gam__offboarding_created_group showingroupdirectory false whocanadd ALL_MANAGERS_CAN_ADD whocanjoin invited_can_join whocanleavegroup ALL_MEMBERS_CAN_LEAVE whocanviewgroup all_managers_can_view whocanviewmembership all_managers_can_view whocanpostmessage ANYONE_CAN_POST
    echo "  > Creating Group: $EMPLOYEE"
}

# adds manager as owner to the termed employee group
add_manager_group() {
    ${GAM} update group "${EMPLOYEE}" add owner "$MANAGER"
    echo "  > Adding $MANAGER to group: $EMPLOYEE"
}

# gam create group janiecetestgroup@b8ta.com name Janiece Test Group description testing a description gal false showingroupdirectory false whocanadd none_can_add whocanjoin invited_can_join whocanleavegroup all_members_can_leave whocanviewgroup all_managers_can_view whocanviewmembership all_managers_can_view whocanpostmessage anynone_can_post



# Main
start_logger
email_verification
term_type
unsuspend_user
get_name
get_manager
reset_password
reset_token
delegate_calendar
gyb_backup
remove_delegates
# wipe_devices
disable_user
transfer_drive
remove_groups
# suspend_user
#deprovision_slack
#update_jamf
delete_user
create_group
add_manager_group