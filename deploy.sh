#!/bin/bash

# STAGE 1: Collecting User Input

read -p "Please enter your Git Repository URL: " repo

read -sp "Please enter your Personal Access Token (PAT): " PAT
echo

if [ -z "$PAT" ]; then
    echo "No PAT entered. Exiting..."
    exit 1
fi

read -p "Please enter your branch name: " branch
branch=${branch:-main}
echo "Using branch: $branch"

echo -e "\n--- Remote Server SSH Details ---"

read -p "Please enter the username: " username
read -p "Please enter the server IP address: " IP
read -p "Please enter the full path to your SSH key: " key
read -p "Please enter your application internal port: " port

# Validate inputs
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

# STAGE 2: Cloning Repository

repo_dir=$(basename "$repo" .git)

if [ -d "$repo_dir" ]; then  
    cd "$repo_dir" || exit
    git pull || { echo "Git pull failed"; exit 1; }
else
    git clone "https://$PAT@${repo#https://}" || { echo "Git clone failed"; exit 1; }
    cd "$repo_dir" || exit
fi

git checkout "$branch" || { echo "Branch checkout failed"; exit 1; }

# STAGE 3: Verifying the Existence of Dockerfile 

log_file="deploy_$(date '+%Y%m%d').log"

if [[ -e Dockerfile || -e docker-compose.yml ]]; then
    echo "Success! Dockerfile or docker-compose.yml file was found in $(pwd) on $(date)" | tee -a "$log_file"
else
    echo "Oops! No Dockerfile or docker-compose.yml found in $(pwd) on $(date). Exiting..." | tee -a "$log_file"
    exit 1
fi

# STAGE 4: Testing SSH Connection

if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i "$key" "$username@$IP" "echo 'SSH OK'" &> /dev/null; then
    echo "SSH connection is successful."
else
    echo "SSH connection failed. Exiting..."
    exit 1
fi

# STAGE 5: Preparing Remote Environment

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

# STAGE 6: Deploying Dockerized Application

cd ..

# Clean up previous deployment
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

    curl -I http://localhost:$port || echo "Your application may not be reachable yet."
EOF

# STAGE 7: Configuring Nginx Reverse Proxy

echo "Configuring Nginx as the reverse proxy on remote server..."

ssh -i "$key" "$username@$IP" bash -s -- "$IP" "$port" <<'EOF'
    set -e
    IP="$1"
    port="$2"

    # Ensure Nginx is installed
    if ! command -v nginx &>/dev/null; then
        echo "Installing Nginx..."
        sudo apt-get update -y
        sudo apt-get install -y nginx
    fi

    # Remove existing configurations
    sudo rm -f /etc/nginx/sites-available/myapp.conf
    sudo rm -f /etc/nginx/sites-enabled/myapp.conf
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo rm -f /etc/nginx/conf.d/myapp.conf

    # Create Nginx config directory
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

# STAGE 8: Validating Deployment

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

# STAGE 9: Setting up Remote Logging

echo "Setting up logging and error handling on remote server..."

ssh -i "$key" "$username@$IP" bash -s <<EOF
    set -e
    log_file="deploy_$(date '+%Y%m%d').log"

    # Error trap for remote environment
    trap 'echo "Error occurred at line \$LINENO. Exiting..." | tee -a "\$log_file"; exit 1' ERR

    echo "Remote logging initialized at \$(date)" | tee -a "\$log_file"
EOF

# STAGE 10: Cleanup

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