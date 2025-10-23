# Docker Deployment Automation

A comprehensive Bash script that automates the deployment of Dockerized applications to remote servers with Nginx reverse proxy configuration.

## Features

- **Automated Git Repository Cloning** - Securely clones your repository using Personal Access Token (PAT)
- **Docker Container Deployment** - Supports both Dockerfile and docker-compose.yml configurations
- **Nginx Reverse Proxy Setup** - Automatically configures Nginx to proxy requests to your application
- **SSH-based Remote Deployment** - Securely deploys to remote servers via SSH
- **Idempotent Operations** - Safe to run multiple times without side effects
- **Comprehensive Logging** - Tracks all deployment activities with timestamped logs
- **Validation & Health Checks** - Verifies deployment success at each stage
- **Cleanup Mode** - Built-in cleanup functionality for easy rollback

## Prerequisites

### Local Machine Requirements
- Bash shell (Linux/macOS/WSL)
- SSH client
- Git 

### Remote Server Requirements
- Ubuntu/Debian-based Linux distribution
- SSH access with key-based authentication
- Sudo privileges for the deployment user
- At least 1GB of available RAM
- Open port 80 (HTTP) in security groups/firewall

### Required Credentials
- Git repository URL (HTTPS)
- GitHub/GitLab Personal Access Token with repo access
- SSH private key for remote server access
- Remote server IP address and username

## Installation

1. **Clone this repository** (or download the script):
```bash
git clone https://github.com/yourusername/docker-deploy-automation.git
cd docker-deploy-automation
```

2. **Make the script executable**:
```bash
chmod +x deploy.sh
```

3. **Ensure your SSH key has proper permissions**:
```bash
chmod 600 ~/.ssh/your_private_key
```

## Usage

### Basic Deployment

Run the script and follow the interactive prompts:

```bash
./deploy.sh
```

### Input Parameters

The script will prompt you for the following information:

1. **Git Repository URL**: Your repository's HTTPS URL
   ```
   Example: https://github.com/username/my-app.git
   ```

2. **Personal Access Token (PAT)**: GitHub/GitLab token for authentication
   - GitHub: Settings → Developer settings → Personal access tokens → Tokens (classic)
   - GitLab: Preferences → Access Tokens
   - Required scopes: `repo` (for private repos)

3. **Branch Name**: The branch to deploy (default: `main`)
   ```
   Examples: main, master, develop, production
   ```

4. **Remote Server Details**:
   - Username: SSH username on the remote server
   - Server IP: The public IP address of your server
   - SSH Key Path: Path to your private key (e.g., `~/.ssh/id_rsa`)
   - Application Port: The internal port your app runs on (e.g., `3000`, `8080`)

### Cleanup Mode

To remove the deployed application and cleanup resources:

```bash
./deploy.sh --cleanup
```

This will:
- Stop and remove Docker containers
- Remove Nginx configuration
- Prune unused Docker networks
- Reload Nginx

## How It Works

The deployment process consists of 10 stages:

### Stage 1: Input Collection
- Collects and validates all required parameters from user
- Ensures no empty values before proceeding

### Stage 2: Repository Cloning
- Clones the Git repository locally using PAT authentication
- If repository exists, pulls latest changes
- Checks out the specified branch

### Stage 3: Docker File Verification
- Validates presence of `Dockerfile` or `docker-compose.yml`
- Exits if neither file is found

### Stage 4: SSH Connection Test
- Performs a dry-run SSH connection to verify credentials
- Ensures connectivity before proceeding with deployment

### Stage 5: Remote Environment Preparation
- Updates package lists on remote server
- Installs Docker, Docker Compose, and Nginx
- Adds user to Docker group
- Enables and starts required services

### Stage 6: Application Deployment
- Transfers application files to remote server
- Builds Docker image or runs docker-compose
- Starts the containerized application
- Displays container logs for verification

### Stage 7: Nginx Configuration
- Removes conflicting configurations
- Creates new Nginx reverse proxy configuration
- Configures proxy headers
- Tests and reloads Nginx

### Stage 8: Deployment Validation
- Verifies Docker service is running
- Confirms container is active
- Tests HTTP endpoint accessibility

### Stage 9: Logging Setup
- Initializes remote logging
- Sets up error traps for better debugging

### Stage 10: Idempotency & Cleanup
- Ensures script can be run multiple times safely
- Provides cleanup option for removing deployment

```

## Configuration 

### Nginx Configuration

The script creates an Nginx configuration at `/etc/nginx/conf.d/myapp.conf`:

```nginx
server {
    listen 80;
    server_name YOUR_SERVER_IP;

    location / {
        proxy_pass http://127.0.0.1:YOUR_APP_PORT;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Docker Deployment

**For Dockerfile projects:**
```bash
docker build -t myapp .
docker run -d --name myapp -p YOUR_PORT:YOUR_PORT myapp
```

**For docker-compose projects:**
```bash
docker-compose up -d
```

## Logging

Deployment logs are stored with timestamps:

- **Local logs**: `deploy_YYYYMMDD.log` (in the repository directory)
- **Remote logs**: `~/deploy_YYYYMMDD.log` (on the remote server)

View logs:
```bash
# Local
cat deploy_$(date '+%Y%m%d').log

# Remote
ssh user@server 'cat ~/deploy_$(date '+%Y%m%d').log'
```

## Troubleshooting

### Common Issues and Solutions

#### 1. SSH Connection Failed
```
Error: SSH connection failed. Exiting...
```
**Solutions:**
- Verify SSH key path is correct
- Ensure key has proper permissions: `chmod 600 ~/.ssh/key`
- Check server IP address and username
- Verify server's SSH port is open (default: 22)

#### 2. Docker Build Failed
```
ERROR: Docker build failed!
```
**Solutions:**
- Check Dockerfile syntax
- Ensure all required files are in the repository
- Verify base image is accessible
- Check remote server has enough disk space: `df -h`

#### 3. Port Already in Use
```
Error: bind: address already in use
```
**Solutions:**
- Run cleanup mode: `./deploy.sh --cleanup`
- Manually stop conflicting containers: `docker stop $(docker ps -aq)`
- Choose a different port for your application

#### 4. Nginx Configuration Test Failed
```
nginx: configuration file /etc/nginx/nginx.conf test failed
```
**Solutions:**
- Check for syntax errors in generated config
- Remove conflicting configurations:
  ```bash
  sudo rm /etc/nginx/sites-enabled/default
  sudo nginx -t
  ```

#### 5. Application Not Reachable
```
curl: (56) Recv failure: Connection reset by peer
```
**Solutions:**
- Wait a few seconds for container to fully start
- Check container logs: `docker logs myapp`
- Verify application is listening on correct port
- Check security group/firewall rules allow port 80

## 🚦 Testing Your Deployment

After deployment completes, test your application:

### From Local Machine
```bash
# Simple test
curl http://YOUR_SERVER_IP

# Check headers
curl -I http://YOUR_SERVER_IP

# Detailed response
curl -v http://YOUR_SERVER_IP
```

### From Browser
Navigate to: `http://YOUR_SERVER_IP`

### From Remote Server
```bash
ssh user@server
curl http://localhost:80
docker ps
docker logs myapp
```
