#!/bin/bash
# Look for a bash file named "crowdsec_helpers.sh" in the current directory

set -auo pipefail

if [ -f "./crowdsec_helpers.sh" ]; then
	# If found, source it to make its functions available
	. ./crowdsec_helpers.sh
else
	# If not found, print an error message and exit
	echo "Error: crowdsec_helpers.sh not found in the current directory."
	exit 1
fi

# Look for ~/.bashrc file in the $HOME directory

if [ -z "$HOME/.bashrc" ]; then
	# If not found, print an error message and exit
	echo "Error: ~/.bashrc not found in the $HOME directory."
	exit 1
fi

# Append 'crowdsec_helpers.sh' sourcing to ~/.bashrc
echo "source $HOME/crowdsec_helpers.sh" >> "$HOME/.bashrc"
# Check if the sourcing was successful

if grep -q "source $HOME/crowdsec_helpers.sh" "$HOME/.bashrc"; then
	echo "crowdsec_helpers.sh has been successfully sourced in ~/.bashrc."
else
	echo "Error: Failed to source crowdsec_helpers.sh in ~/.bashrc."
	exit 1
fi

# Source .bashrc to apply changes immediately

. "$HOME/.bashrc"


set +auo pipefail