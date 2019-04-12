#!/bin/bash

# Flags
set -e
# Uncomment the following line to debug the script
# set -x

# Load configuration
# shellcheck source=/dev/null
source "$PWD/.devenv"

# Defaults
RETRIES=5
DEVENV_USER=${DEVENV_USER:-root}

# Create LXC config file
LXC_CONFIG="/tmp/$DISTRIBUTION.$NAME.conf"
echo "Creating config file: $LXC_CONFIG"
cat > "$LXC_CONFIG" <<EOL
# Network
lxc.net.0.type = veth
lxc.net.0.flags = up
lxc.net.0.link = lxcbr0

# Volumes
EOL

# TODO - We can extract all this conditions in functions and separate in files
if [ ! -v BASE_PATH ] ; then
  BASE_PATH="/opt"
fi

# Mount folder if PROJECT_PATH is defined
if [ -v PROJECT_PATH ] ; then
  mount_entry="lxc.mount.entry = $PROJECT_PATH /var/lib/lxc/$NAME/rootfs$BASE_PATH/$PROJECT_NAME none bind,create=dir 0.0"
  echo "$mount_entry" >> "$LXC_CONFIG"
fi

# Print configuration
echo "* CONFIGURATION:"
echo "  - Name: $NAME"
echo "  - Distribution: $DISTRIBUTION"
echo "  - Release: $RELEASE"
echo "  - LXC Configuration: $LXC_CONFIG"
echo "  - Host: $HOST"
echo "  - Project Name: $PROJECT_NAME"
echo "  - Project Directory: $PROJECT_PATH"
echo "  - Will mount on: $BASE_PATH/$PROJECT_NAME"
echo "  - User: $DEVENV_USER"
echo "  - Group: $DEVENV_GROUP"
echo

# Create container
exist_container="$(sudo lxc-ls --filter ^"$NAME"$)"
if [ -z "${exist_container}" ] ; then
  echo "Creating container $NAME"
  sudo lxc-create --name "$NAME" -f "$LXC_CONFIG" -t download -l INFO -- --dist "$DISTRIBUTION" --release "$RELEASE" --arch "$ARCH"
fi
echo "Container ready"

# Check if container is running, if not start it
count=1
while [ $count -lt $RETRIES ] && [ -z "$is_running" ]; do
  is_running=$(sudo lxc-ls --running --filter ^"$NAME"$)
  if [ -z "$is_running" ] ; then
    echo "Starting container"
    sudo lxc-start -n "$NAME" -d -l INFO
    ((count++))
  fi
done

# If container is not running stop execution
if [ -z "$is_running" ]; then
  echo "Container not started, something is wrong."
  echo "Please check log file /var/log/lxc/$NAME.log"
  exit 0
fi
echo "Container is running..."

# Wait to start container and check the IP
count=1
ip_container="$(sudo lxc-info -n "$NAME" -iH)"
while [ $count -lt $RETRIES ] && [ -z "$ip_container" ] ; do
  sleep 2
  echo "Waiting for container IP..."
  ip_container="$(sudo lxc-info -n "$NAME" -iH)"
  ((count++))
done
echo "Container IP: $ip_container"
echo

# Add container IP to /etc/hosts
echo "Removing old host $HOST from /etc/hosts"
sudo sed -i '/'"$HOST"'/d' /etc/hosts
host_entry="$ip_container       $HOST"
echo "Add '$host_entry' to /etc/hosts"
sudo -- sh -c "echo $host_entry >> /etc/hosts"
echo

# Remove host SSH key
echo "Removing old $HOST from ~/.ssh/know_hosts"
ssh-keygen -R "$HOST"

# Read user's SSH public key
ssh_path="$HOME/.ssh/id_rsa.pub"
echo "Reading SSH public key from ${ssh_path}"
read -r ssh_key < "$ssh_path"

# Add system user's SSH public key to `root` user
echo "Copying system user's SSH public key to 'root' user in container"
sudo lxc-attach -n "$NAME" -- /bin/bash -c "/bin/mkdir -p /root/.ssh && echo $ssh_key > /root/.ssh/authorized_keys"

# User management related with projects folder
if  [ -v PROJECT_PATH ] ; then
  # Find `uid` of project directory
  project_user=$(stat -c '%U' "$PROJECT_PATH")
  project_uid=$(id -u "$project_user")

  # Find `gid` of project directory
  project_group=$(stat -c '%G' "$PROJECT_PATH")
  project_gid=$(id -g "$project_group")
fi

# User management
if [ -v DEVENV_USER ] && [ -v DEVENV_GROUP ] && [ -v project_uid ] && [ -v project_gid ]; then
  # Delete existing user with same uid and gid of project directory
  existing_user=$(sudo lxc-attach -n "$NAME" -- id -nu "$project_uid" 2>&1)
  sudo lxc-attach -n "$NAME" -- /usr/sbin/userdel -r "$existing_user"

  # Create group with same `gid` of project directory
  sudo lxc-attach -n "$NAME" -- /usr/sbin/groupadd -f --gid "$project_gid" "$DEVENV_GROUP"

  # Create user with same `uid` and `gid` of project directory
  sudo lxc-attach -n "$NAME" -- /bin/sh -c "/usr/bin/id -u $DEVENV_USER || /usr/sbin/useradd --uid $project_uid --gid $project_gid --create-home --shell /bin/bash $DEVENV_USER"

  # Add system user's SSH public key to user
  echo "Copying system user's SSH public key to $DEVENV_USER user in container"
  sudo lxc-attach -n "$NAME" -- sudo -u "$DEVENV_USER" -- sh -c "/bin/mkdir -p /home/$DEVENV_USER/.ssh && echo $ssh_key > /home/$DEVENV_USER/.ssh/authorized_keys"
fi

# Debian Stretch Sudo install
sudo lxc-attach -n "$NAME" -- apt install sudo

# Install python interpreter in container
echo "Installing Python in container $NAME"
sudo lxc-attach -n "$NAME" -- sudo apt update
sudo lxc-attach -n "$NAME" -- sudo apt install -y "$PYTHON_INTERPRETER"

# Install SSH server in container
echo "Installing SSH server in container $NAME"
sudo lxc-attach -n "$NAME" -- sudo apt install -y openssh-server

# Ready to provision the container
echo
echo "Very well! LXC container $NAME has been created and configured"
echo
echo "You should be able to access using:"
echo "> ssh $DEVENV_USER@$HOST"
echo
echo "To install all the dependencies run:"
echo "> ansible-playbook playbooks/provision.yml --limit=dev"
echo
