#!/bin/env bash

set -e
ubuntu_version=$(lsb_release -a 2>/dev/null | grep -v "No LSB modules are available." | grep "Description:" | awk -F "Description:\t" '{print $2}')

set -e
domain_name="dev.pulsehero.co"
mail_from="kevin@pulsehero.co"
email_address="kevin@pulsehero.co"
smtp_host="email-smtp.us-west-2.amazonaws.com"
smtp_port=465
smtp_secure_enabled=1
smtp_user="$(SMTP_USER)"
smtp_password="$(SMTP_PASSWORD)"

# Friendly welcome
echo "🧱 Welcome to the Formbricks single instance installer"
echo ""
echo "🛸 Fasten your seatbelts! We're setting up your Formbricks environment on your $ubuntu_version server."
echo ""

# Remove any old Docker installations, without stopping the script if they're not found
echo "🧹 Time to sweep away any old Docker installations."
sudo apt-get remove docker docker-engine docker.io containerd runc >/dev/null 2>&1 || true

# Update package list
echo "🔄 Updating your package list."
sudo apt-get update >/dev/null 2>&1

# Install dependencies
echo "📦 Installing the necessary dependencies."
sudo apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release >/dev/null 2>&1

# Set up Docker's official GPG key & stable repository
echo "🔑 Adding Docker's official GPG key and setting up the stable repository."
sudo mkdir -m 0755 -p /etc/apt/keyrings >/dev/null 2>&1
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg >/dev/null 2>&1
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null 2>&1

# Update package list again
echo "🔄 Updating your package list again."
sudo apt-get update >/dev/null 2>&1

# Install Docker
echo "🐳 Installing Docker."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1

# Test Docker installation
echo "🚀 Testing your Docker installation."
if docker --version >/dev/null 2>&1; then
  echo "🎉 Docker is installed!"
else
  echo "❌ Docker is not installed. Please install Docker before proceeding."
  exit 1
fi

# Adding your user to the Docker group
echo "🐳 Adding your user to the Docker group to avoid using sudo with docker commands."
sudo groupadd docker >/dev/null 2>&1 || true
sudo usermod -aG docker $USER >/dev/null 2>&1

echo "🎉 Hooray! Docker is all set and ready to go. You're now ready to run your Formbricks instance!"

# Installing Traefik
echo "🚗 Installing Traefik..."
mkdir -p formbricks && cd formbricks
echo "📁 Created Formbricks Quickstart directory at ./formbricks."


cat <<EOT >traefik.yaml
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: default
providers:
  docker:
    watch: true
    exposedByDefault: false
certificatesResolvers:
  default:
    acme:
      email: $email_address
      storage: acme.json
      caServer: "https://acme-v01.api.letsencrypt.org/directory"
      tlsChallenge: {}
EOT

echo "💡 Created traefik.yaml file with your provided email address."

touch acme.json
chmod 600 acme.json
echo "💡 Created acme.json file with correct permissions."

echo "📥 Downloading docker-compose.yml from PulseHero GitHub repository..."
curl -o docker-compose.yml https://raw.githubusercontent.com/kevinkong91/pulsehero/dev/docker/docker-compose.yml

echo "🚙 Updating docker-compose.yml with your custom inputs..."
sed -i "/WEBAPP_URL:/s|WEBAPP_URL:.*|WEBAPP_URL: \"https://$domain_name\"|" docker-compose.yml
sed -i "/NEXTAUTH_URL:/s|NEXTAUTH_URL:.*|NEXTAUTH_URL: \"https://$domain_name\"|" docker-compose.yml

nextauth_secret=$(openssl rand -hex 32) && sed -i "/NEXTAUTH_SECRET:$/s/NEXTAUTH_SECRET:.*/NEXTAUTH_SECRET: $nextauth_secret/" docker-compose.yml
echo "🚗 NEXTAUTH_SECRET updated successfully!"

encryption_key=$(openssl rand -hex 32) && sed -i "/ENCRYPTION_KEY:$/s/ENCRYPTION_KEY:.*/ENCRYPTION_KEY: $encryption_key/" docker-compose.yml
echo "🚗 ENCRYPTION_KEY updated successfully!"


sed -i "s|# MAIL_FROM:|MAIL_FROM: \"$mail_from\"|" docker-compose.yml
sed -i "s|# SMTP_HOST:|SMTP_HOST: \"$smtp_host\"|" docker-compose.yml
sed -i "s|# SMTP_PORT:|SMTP_PORT: \"$smtp_port\"|" docker-compose.yml
sed -i "s|# SMTP_SECURE_ENABLED:|SMTP_SECURE_ENABLED: $smtp_secure_enabled|" docker-compose.yml
sed -i "s|# SMTP_USER:|SMTP_USER: \"$smtp_user\"|" docker-compose.yml
sed -i "s|# SMTP_PASSWORD:|SMTP_PASSWORD: \"$smtp_password\"|" docker-compose.yml


awk -v domain_name="$domain_name" '
/formbricks:/,/^ *$/ {
    if ($0 ~ /depends_on:/) {
        inserting_labels=1
    }
    if (inserting_labels && ($0 ~ /ports:/)) {
        print "    labels:"
        print "      - \"traefik.enable=true\"  # Enable Traefik for this service"
        print "      - \"traefik.http.routers.formbricks.rule=Host(\`" domain_name "\`)\"  # Use your actual domain or IP"
        print "      - \"traefik.http.routers.formbricks.entrypoints=websecure\"  # Use the websecure entrypoint (port 443 with TLS)"
        print "      - \"traefik.http.services.formbricks.loadbalancer.server.port=3000\"  # Forward traffic to Formbricks on port 3000"
        inserting_labels=0
    }
    print
    next
}
/^volumes:/ {
    print "  traefik:"
    print "    image: \"traefik:v2.7\""
    print "    restart: always"
    print "    container_name: \"traefik\""
    print "    depends_on:"
    print "      - formbricks"
    print "    ports:"
    print "      - \"80:80\""
    print "      - \"443:443\""
    print "      - \"8080:8080\""
    print "    volumes:"
    print "      - ./traefik.yaml:/traefik.yaml"
    print "      - ./acme.json:/acme.json"
    print "      - /var/run/docker.sock:/var/run/docker.sock:ro"
    print ""
}
1
' docker-compose.yml >tmp.yml && mv tmp.yml docker-compose.yml

newgrp docker <<END

docker compose up

echo "🔗 To edit more variables and deeper config, go to the formbricks/docker-compose.yml, edit the file, and restart the container!"

echo "🚨 Make sure you have set up the DNS records as well as inbound rules for the domain name and IP address of this instance."
echo ""
echo "🎉 All done! Check the status of Formbricks & Traefik with 'cd formbricks && sudo docker compose ps.'"

END
