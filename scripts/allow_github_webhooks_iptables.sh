# Delete chain if exist
iptables -F GitHubWebHooks

# Create a chain named GitHubWebHooks
iptables -N GitHubWebHooks

iptables -I INPUT -s 0/0 -p tcp --dport 80 -j GitHubWebHooks
iptables -I INPUT -s 0/0 -p tcp --dport 443 -j GitHubWebHooks

# Github hooks IP address from https://api.github.com/meta
iptables -I GitHubWebHooks -s 192.30.252.0/22 -j ACCEPT
iptables -I GitHubWebHooks -s 185.199.108.0/22 -j ACCEPT
iptables -I GitHubWebHooks -s 140.82.112.0/20 -j ACCEPT

# Allow nm servers from exceleron network
iptables -I GitHubWebHooks -s 38.140.184.196 -j ACCEPT
iptables -I GitHubWebHooks -s 38.140.184.194 -j ACCEPT

#Dinesh public IP for testing
iptables -I GitHubWebHooks -s 38.140.184.194 -j ACCEPT
