#!/bin/bash

#Step 1: Collecting parameters from user input

read -p "Please enter your Git Repository URL: " repo

read -sp "Please enter your Personal Access Token (PAT):" PAT
echo #This is to ensure the next command move to a new line after the silent/hidden input

if [ -z "$PAT" ]; then
    echo "No PAT entered. Exiting..."
    exit 1
fi

read -p "Please enter your branch name: " branch
branch=${branch:-main}    #Sets the default to "main" if the user presses enter without typing
echo "Using branch: $branch"

echo -e "\n--- Remote Server SSH Details ---"

read -p "Please enter the username: " username
read -p "Please enter the server IP address: " IP
read -p "Please enter the path to your SSH key (e.g. ~/.ssh/id_rsa): " key
read -p "Please enter your application internal port: " port

#For Validation
if [[ -n "$repo" && -n "$PAT" && -n "$username" && -n "$IP" && -n "$key" && -n "$port" ]]; then
  echo -e "\nAll inputs collected successfully!"
  echo "Repository: $repo" 
  echo "Branch: $branch" 
  echo "Server: $username@$IP"
  echo "SSH Key: $key" 
  echo "App Port: $port"
else
  echo "Error! One or more required inputs are missing. Please run the script again."
  exit 1
fi

#Step 2: Cloning the repository

repo_dir=$(basename "$repo" .git) #basename pulls only the last part of the url which is the dir name while the .git here means remove .git if it exist in the url

if [ -d "$repo_dir" ]; then  
cd "$repo_dir" || exit  #This is to avoid the other git commands running in the wrong directory
git pull || { echo "Git pull failed"; exit 1; }
else
git clone "https://$PAT@${repo#https://}" || { echo "Git clone failed"; exit 1; } #this removes the leading https://
cd "$repo_dir" || exit
fi

git checkout "$branch" || { echo "Branch checkout failed"; exit 1; }

#Step 3: verifying if a docker file exist

log_file="deploy_$(date '+%Y%m%d').log"

if [[ -e Dockerfile || -e docker-compose.yml ]]; then
echo "Success! Dockerfile or docker-compose.yml file was found in the $(pwd) on $(date)" | tee -a "$log_file"
else
echo "oops! No file named Dockerfile or docker-compose.yml was found in the $(pwd) on $(date). Exitng..." | tee -a "$log_file"
exit 1
fi

#Stage 4 and 5: SSH into remote server and preparing the remote environment

if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i "$key" "$username@$IP" "echo 'SSH OK'" &> /dev/null; then  #SSH dry-run
    echo "SSH connection is successful."
else
    echo "SSH connection failed. Exiting..."
    exit 1
fi

ssh -o StrictHostKeyChecking=no -i "$key" "$username@$IP" "
echo 'Now running commands remotely...';
sudo apt-get update -y && sudo apt-get install -y docker.io docker-compose nginx;
sudo usermod -aG docker $username;
sudo systemctl enable docker nginx;
sudo systemctl start docker nginx;
docker --version;
docker-compose --version;
nginx -v;
"

#Stage 6: Deploying the dockerized application

cd ..

# Clean up any previous deployment directory on remote to avoid permission issues
ssh -i "$key" "$username@$IP" "rm -rf ~/deployments/$repo_dir && mkdir -p ~/deployments"
scp -i "$key" -r "$repo_dir" "$username@$IP":~/deployments/

ssh -o StrictHostKeyChecking=no -i "$key" "$username@$IP" bash -s <<EOF

docker stop myapp 2>/dev/null || true
docker rm myapp 2>/dev/null || true
set -e

cd ~/deployments/$repo_dir

if [[ -f Dockerfile ]]; then
    echo "Building Docker image..."
    docker build -t myapp . || {
        echo "ERROR: Docker build failed!"
        exit 1
    }
    docker run -d --name myapp -p $port:$port myapp || exit 1

elif [[ -f docker-compose.yml ]]; then
    docker-compose up -d || exit 1
else
    echo 'No Docker project file found' && exit 1
fi

if [[ -f Dockerfile ]]; then
docker ps
docker logs myapp --tail 20
elif [[ -f docker-compose.yml ]]; then
docker-compose logs --tail=20
fi

curl -I http://localhost:$port || echo " Your application may not be reachable yet."
EOF

# Stage 7: Configuring Nginx as the reverse proxy
echo "Configuring Nginx as the reverse proxy on remote server..."

ssh -i "$key" "$username@$IP" bash -s -- "$IP" "$port" <<'EOF'  #I passed $port and $IP explicitly into the remote environment
set -e
IP="$1"
port="$2"

# Ensure Nginx is installed
if ! command -v nginx &>/dev/null; then
  echo "Installing Nginx..."
  sudo apt-get update -y
  sudo apt-get install -y nginx
fi

# Remove any existing configurations to avoid conflicts
sudo rm -f /etc/nginx/sites-available/myapp.conf
sudo rm -f /etc/nginx/sites-enabled/myapp.conf
sudo rm -f /etc/nginx/sites-enabled/default
sudo rm -f /etc/nginx/conf.d/myapp.conf

# Create Nginx config directory if it doesn’t exist
sudo mkdir -p /etc/nginx/conf.d

# Create new configuration file
sudo bash -c "cat > /etc/nginx/conf.d/myapp.conf" <<NGINX_EOF
server {
    listen 80;
    server_name $IP;

    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX_EOF

# Test and reload Nginx
sudo nginx -t
sudo systemctl reload nginx

echo "Nginx configuration completed and reloaded successfully."
EOF

#Stage 8: Validating Deployment

ssh -i "$key" "$username@$IP" bash -s <<EOF
if ! systemctl is-active --quiet docker; then
    echo "Docker service is not running!"
    exit 1
fi

if ! docker ps --filter "name=myapp" --filter "status=running" | grep "myapp" > /dev/null; then
    echo "Container myapp is not running!"
    exit 1
fi

curl -f http://localhost:80 || echo "Warning: Endpoint not responding!"
EOF

echo "Validation completed" | tee -a "$log_file"

# Stage 9: Logging and error handling on remote
echo "Setting up logging and error handling on remote server..."

ssh -i "$key" "$username@$IP" bash -s <<EOF
set -e
log_file="deploy_$(date '+%Y%m%d').log"

# Error trap for the remote environment
trap 'echo "Error occurred at line \$LINENO. Exiting..." | tee -a "\$log_file"; exit 1' ERR

echo "Remote logging initialized at \$(date)" | tee -a "\$log_file"
EOF

#Stage 10: Idempotency and cleanup

if [[ "$1" == "--cleanup" ]]; then
    ssh -i "$key" "$username@$IP" bash -s <<EOF
    docker rm -f myapp 2>/dev/null || true
    docker network prune -f 2>/dev/null || true
    sudo rm -f /etc/nginx/sites-available/myapp.conf /etc/nginx/sites-enabled/myapp.conf
    sudo systemctl reload nginx
EOF
    echo "Cleanup completed." | tee -a "$log_file"
    exit 0
fi

echo "Deployment completed successfully!" | tee -a "$log_file"

