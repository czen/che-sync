#!/bin/bash

export CHE_SYNC_VERSION=2.1.0

host_domain="host.docker.internal"
ping -q -c1 $host_domain &>/dev/null
if [ $? -ne 0 ]; then
    host_domain=$(/sbin/ip route|awk '/default/ { print $3 }')
fi

ssh_args="-o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
unison_args="-batch -auto -silent -terse -prefer=newer -retry 10 -sshargs '-C ${ssh_args}'"

if [ -t 0 ]; then
    TERM=xterm-256color
    fgRed=$(tput setaf 1)
    fgGreen=$(tput setaf 2)
    fgNormal=$(tput sgr0)
    fgBold=$(tput bold)
else
    echo "ERROR: No TTY found, docker must be run with -it"
    exit 1
fi

echo -e "${fgBold}${fgGreen}                           ";
echo -e "      | |                                     ";
echo -e "   ___| |__   ___       ___ _   _ _ __   ___  ";
echo -e "  / __| '_ \ / _ \_____/ __| | | | '_ \ / __| ";
echo -e " | (__| | | |  __/_____\__ \ |_| | | | | (__  ";
echo -e "  \___|_| |_|\___|     |___/\__, |_| |_|\___| ";
echo -e "                             __/ |            ";
echo -e "                            |___/             ";
echo -e " VERSION: ${CHE_SYNC_VERSION}    ${fgNormal}\n";

OPTIND=1
while getopts h:u:n:p:s:t:r: OPT
do
    case "${OPT}"
    in
    h) CHE_HOST=http://${OPTARG};;
    u) CHE_USER=${OPTARG};;
    n) CHE_NAMESPACE=${OPTARG};;
    p) CHE_PASS=${OPTARG};;
    s) SSH_USER=${OPTARG};;
    t) CHE_TOTP=${OPTARG};;
    r) UNISON_REPEAT=${OPTARG};;
    esac
done
shift $((OPTIND - 1))

if [[ "$1" == "ssh" && -z "$2" ]]; then
    ssh_only=true
else
    CHE_WORKSPACE=${1:-$CHE_WORKSPACE}
fi

CHE_WORKSPACE=${CHE_NAMESPACE:+$CHE_NAMESPACE/}${CHE_WORKSPACE}
CHE_PROJECT=${2:-$CHE_PROJECT}

if [[ -z $CHE_HOST || -z $CHE_USER || -z $CHE_PASS || -z $CHE_WORKSPACE ]]; then
  echo "${fgRed}ERROR: You must specify at least a host, username, password and workspace to continue${fgNormal}"
  exit 1
fi

# Authenticate with keycloak and grab tokeb
auth_token_response=$(curl --fail -s -X POST "${CHE_HOST}:5050/auth/realms/che/protocol/openid-connect/token" \
 -H "Content-Type: application/x-www-form-urlencoded" \
 -d "username=${CHE_USER}" \
 -d "password=${CHE_PASS}" \
 -d "totp=${CHE_TOTP}" \
 -d 'grant_type=password' \
 -d 'client_id=che-public') || {
    echo "${fgRed}ERROR: Unable to authenticate with server!${fgNormal}";
    exit 1;
}
auth_token=$(echo $auth_token_response | jq -re '.access_token | select(.!=null)') || {
    echo "${fgRed}ERROR: Unable to authenticate with Che! $(echo $auth_token_response | jq -r '.error_description | select(.!=null)')${fgNormal}";
    exit 1;
}

# Get ssh url from che api
che_ssh=$(curl -s "${CHE_HOST}/api/workspace/${CHE_WORKSPACE}?token=${auth_token}" | jq -re 'first(..|.["dev-machine"]?.servers?.ssh?.url? | select(.!=null))' 2>/dev/null) || {
    echo "${fgRed}ERROR: Unable to connect to the Che API for ${CHE_WORKSPACE}, is the workspace running and the SSH agent enabled?${fgNormal}";
    exit 1;
}

# Get ssh key from che api
che_key=$(curl -s "${CHE_HOST}/api/ssh/machine?token=${auth_token}" | jq -re 'first(..|.privateKey? | select(.!=null))' 2>/dev/null) || {
    echo "${fgRed}ERROR: Unable to obtain SSH key for ${CHE_WORKSPACE}, do you have a machine key generated?${fgNormal}";
    exit 1;
}

# Store private key
echo "${che_key}" > $HOME/.ssh/id_rsa
chmod 600 $HOME/.ssh/id_rsa

if [ "$ssh_only" != true ] ; then
    export UNISONLOCALHOSTNAME=$UNISON_NAME

    echo "Starting file sync process..."

    # Shut down background jobs on exit
    trap 'if [ "$(jobs -p)" ]; then echo "Shutting down sync process..." && kill $(jobs -p) 2> /dev/null; fi; exit' EXIT ERR

    # Test connection to remote server and sync .unison folder
    unison_remote="${che_ssh:0:6}$SSH_USER@${che_ssh:6}//projects/$CHE_PROJECT"
    eval "unison /mount ${unison_remote} ${unison_args} -force ${unison_remote} -path .unison -ignore='Name ?*' -ignorenot='Name *.prf'"

    # Run unison sync in the background
    if [ ! -z "$UNISON_PROFILE" ]; then
        echo "Using sync profile ${fgGreen}${fgBold}$UNISON_PROFILE${fgNormal}"
    fi
    eval "unison ${UNISON_PROFILE} /mount ${unison_remote} ${unison_args} -repeat=${UNISON_REPEAT} \
    -ignore='Path .che' \
    -ignore='Path .idea' \
    -ignore='Path .composer' \
    -ignore='Path .npm' \
    -ignore='Path .config' \
    -ignore='Path docker-compose.yml' \
    -ignore='Path var' \
    -ignore='Path media' \
    -ignore='Path pub/media' \
    -ignore='Name .git' \
    -ignore='Name *.orig' \
    -ignore='Name .DS_Store' \
    -ignore='Name node_modules' \
    " > unison.log &
fi

# Drop user into workspace via ssh
echo "Connecting to Che workspace ${fgBold}${fgGreen}$CHE_WORKSPACE${fgNormal} with SSH..."
ssh_connect=${che_ssh:6}
ssh_connect=${ssh_connect/:/ -p}
ssh -R "*:$FORWARD_PORT:$host_domain:$FORWARD_PORT" $ssh_ports $ssh_args $SSH_USER@$ssh_connect -t "cd /projects/${CHE_PROJECT}; exec \$SHELL --login"