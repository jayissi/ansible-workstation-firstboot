#!/bin/bash

# Function to check if Chrome is installed
function check_chrome_installed() {
	if ! command -v google-chrome &>/dev/null && ! command -v google-chrome-stable &>/dev/null; then
		logger "Error: Google Chrome is not installed"
		exit 1
	fi
}

# Function to determine the correct Chrome executable
function get_chrome_command() {
	local chrome_cmd="google-chrome"
	if command -v "${chrome_cmd}" &>/dev/null; then
		chrome_cmd="google-chrome"
	else
		logger "${chrome_cmd} command not found"
		echo "${chrome_cmd} command not found"
		exit 2
	fi
	echo "${chrome_cmd}"
}

# Function to check if Chrome is running
function is_chrome_running() {
	local chrome_cmd="${1}"
	# First check for the exact command
	if pgrep -x "$(basename "${chrome_cmd}")" >/dev/null; then
		return 0
	# Then check for chrome processes with full path
	elif pgrep -f "${chrome_cmd}" >/dev/null; then
		return 0
	fi
	return 3
}

# Function to start Chrome
function start_chrome() {
	local chrome_cmd="${1}"
	logger "Starting Google Chrome..."
	setsid -fw "${chrome_cmd}" >/dev/null 2>&1 &
	logger "Google Chrome started with PID $!"
}

# Main function
function main() {
	local chrome_cmd

	check_chrome_installed
	chrome_cmd=$(get_chrome_command)

	if is_chrome_running "${chrome_cmd}"; then
		logger "Google Chrome is already running"
	else
		start_chrome "${chrome_cmd}"
	fi
}

# Execute main function
if [[ "$TERM_PROGRAM" == "vscode" ]]; then
	main
fi
