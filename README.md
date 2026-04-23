# Docker container to proxy openfortivpn
runs openfortivpn for ssh connections

# Usage
1. fill in .env.example, rename it to .env
2. docker compose up -d
3. go to <your-vpn-provider-ip>:<port>/remote/saml/start?redirect=1 in your browser 
4. fill in saml and complete sso. browser will redirect to '127.0.0.1:8020?id=...''
5. copy '?id=...' string to curl 'http://SERVER_IP:8020/<paste?id=... here>'
6. check logs for connection

