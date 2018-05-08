#!/bin/bash
echo $(date) " - Starting Script"

USER=$1
PASSWORD="$2"
POOL_ID=$3
AUTOPOOLED=$4
ORGSUBS=$5

# Verify that we have access to Red Hat Network
ITER=0
while true; do
	curl -kv https://access.redhat.com >/dev/null 2>&1
	if [ "$?" -eq 0 ]; then
		echo "We have a working network connection to Red Hat."
		break
	else
		ITER=$(expr $ITER + 1)
		echo "We do not yet have a working network connection to Red Hat. Try: $ITER"
	fi
	if [ "$ITER" -eq 10 ]; then
      		echo "Error: we are experiencing some network error to Red Hat."
		exit 1
	fi
	sleep 60
done

# Register Host with Cloud Access Subscription
echo $(date) " - Register host with Cloud Access Subscription"

if [ "${ORGSUBS}" = "true" ]; then
	subscription-manager register --org="$USER" --activationkey="$PASSWORD" --force
	if [ $? -eq 0 ]; then
		echo "Subscribed successfully"
	else
		sleep 5
		subscription-manager register --org="$USER" --activationkey="$PASSWORD" --force
		if [ "$?" -eq 0 ]; then
			echo "Subscribed successfully."
		else
			echo "Incorrect Username and / or Password specified"
			exit 3
		fi
	fi
else
	subscription-manager register --username="$USER" --password="$PASSWORD" --force
	if [ $? -eq 0 ]; then
		echo "Subscribed successfully"
	else
		sleep 5
		subscription-manager register --username="$USER" --password="$PASSWORD" --force
		if [ "$?" -eq 0 ]; then
			echo "Subscribed successfully."
		else
			echo "Incorrect Username and / or Password specified"
			exit 3
		fi
	fi
fi

if [ "${AUTOPOOLED}" = "true" ]; then
    echo "Subs autopooled. No need to attach pool id."
else 
    subscription-manager attach --pool=$POOL_ID
    if [ $? -eq 0 ]; then
        echo "Pool attached successfully"
    else
        sleep 5
        subscription-manager attach --pool=$POOL_ID
        if [ "$?" -eq 0 ]; then
            echo "Pool attached successfully"
        else
            echo "Incorrect Pool ID or no entitlements available"
              exit 4
        fi
    fi
fi

# Disable all repositories and enable only the required ones
echo $(date) " - Disabling all repositories and enabling only the required repos"

subscription-manager repos --disable="*" || subscription-manager repos --disable="*"

subscription-manager repos \
    --enable="rhel-7-server-rpms" \
    --enable="rhel-7-server-extras-rpms" \
    --enable="rhel-7-server-ose-3.9-rpms" \
    --enable="rhel-7-fast-datapath-rpms" \
    --enable="rhel-7-server-ansible-2.4-rpms"

if yum repolist|grep -q ose-3.9; then
	echo "Enabled repositories correctly."
else
	echo "Failed to enable repositories. Retrying."
	sleep 5
	subscription-manager repos \
    		--enable="rhel-7-server-rpms" \
    		--enable="rhel-7-server-extras-rpms" \
    		--enable="rhel-7-server-ose-3.9-rpms" \
    		--enable="rhel-7-fast-datapath-rpms" \
    		--enable="rhel-7-server-ansible-2.4-rpms"
	if yum repolist|grep -q ose-3.9; then
		echo "Enabled repositories correctly."
	else
		echo "Failed to enable repositories. Possible RHN or network issue."
		exit 4
	fi
fi

# Disable extras from Azure RHUI
yum-config-manager --disable rhui-rhel-7-server-rhui-extras-rpms

# Install base packages and update system to latest packages
echo $(date) " - Install base packages and update system to latest packages"

# Also, install CRI-O to run that instead of Docker
yum -y install wget git net-tools bind-utils iptables-services bridge-utils bash-completion kexec-tools sos psacct httpd-tools cri-o
yum -y update --exclude=WALinuxAgent

# Install OpenShift utilities
echo $(date) " - Installing OpenShift utilities"

yum -y install atomic-openshift-utils

echo $(date) " - Script Complete"
