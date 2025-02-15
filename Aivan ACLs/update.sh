#!/bin/bash

# Vars
# Linode API token
TOKEN=""

# Get current timestamp
timestamp=$(date +"%Y-%m-%d %H:%M:%S")

# Ensure staticIPs.txt exists
touch staticIPs.txt

# Grab IPs
curl -s --request GET \
     --url 'https://api.linode.com/v4/linode/instances?page=1&page_size=100' \
     --header 'accept: application/json' \
     --header "authorization: Bearer $TOKEN" | \
jq -r '.data[] | select(.label | startswith("skynet")) | .ipv4[0], .ipv6 // empty' > IPs.txt

# Grab local data
allow_list=$(cat IPs.txt staticIPs.txt | jq -R . | jq -sc .)

# Make command
json_payload=$(jq -n --argjson list "$allow_list" '{allow_list: $list}')

# Actually do the things
response=$(curl -s --request PUT \
     --url "https://api.linode.com/v4/databases/mysql/instances/191253" \
     --header 'accept: application/json' \
     --header "authorization: Bearer $TOKEN" \
     --header 'content-type: application/json' \
     --data "$json_payload")

# Extract allowed IPs from the response and format output
allowed_ips=$(echo "$response" | jq -r '.allow_list[]')

# Print confirmation
echo -e "\n+-----------------------------------------------+"
echo -e "| Allowed IPs Updated | $timestamp |"
echo -e "+-----------------------------------------------+"

while IFS= read -r ip; do
    echo -e "| $ip"
done <<< "$allowed_ips"

echo -e "+-----------------------------------------------+\n"

# EDKH
# WHH
