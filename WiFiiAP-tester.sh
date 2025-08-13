#!/bin/bash

IFACE=$(nmcli device status | awk '$2=="wifi"{print $1; exit}')
TMP_LOG="/tmp/wifi_test.log"

# Step 1: Quick summary table
echo "=== Quick Wi-Fi Scan Summary ==="
nmcli -f SSID,BSSID,MODE,CHAN,FREQ,RATE,BANDWIDTH,SIGNAL,SECURITY dev wifi list ifname "$IFACE" | grep -v '^--'
echo "================================"
echo

# Step 2: Raw AP data for later
raw_aps=$(nmcli -t -f SSID,BSSID,MODE,CHAN,FREQ,RATE,BANDWIDTH,SIGNAL,SECURITY dev wifi list ifname "$IFACE")

# Parse AP info safely using a pipe separator
mapfile -t aps < <(echo "$raw_aps" | while IFS=: read -r ssid_part b1 b2 b3 b4 b5 b6 mode chan freq rate bw signal security_rest; do
    ssid=$(echo "$ssid_part" | sed 's/\\:/:/g')
    bssid="${b1}:${b2}:${b3}:${b4}:${b5}:${b6}"
    mode=${mode:-"Unknown"}
    chan=${chan:-0}
    freq=${freq:-"Unknown"}
    rate=${rate:-"Unknown"}
    bw=${bw:-"Unknown"}
    signal=${signal:-"Unknown"}
    security=${security_rest:-"<None>"}
    echo -e "${ssid}|${bssid}|${mode}|${chan}|${freq}|${rate}|${bw}|${signal}|${security}"
done)

mapfile -t saved_conns < <(nmcli -t -f NAME connection show)

declare -A vendor_cache

total=${#aps[@]}
echo "Fetching vendor info for $total BSSID(s), please wait..."

# Step 3: Pre-fetch all vendor info
for i in "${!aps[@]}"; do
    IFS='|' read -r ssid bssid mode channel freq rate bw signal security <<< "${aps[$i]}"
    clean_bssid=$(echo "$bssid" | sed 's/\\//g')

    progress=$((i+1))
    printf "\rFetching vendor %d/%d: %s" "$progress" "$total" "$clean_bssid"

    if [[ -z "${vendor_cache[$clean_bssid]}" ]]; then
        vendor_json=$(curl -s "https://api.macvendors.com/$clean_bssid" || echo "Unknown")
        if [[ "$vendor_json" =~ \{\"errors\"\:\{\"detail\" ]]; then
            vendor_cache[$clean_bssid]="Not Found"
        else
            vendor_cache[$clean_bssid]="$vendor_json"
        fi
        sleep 3
    fi
done
echo -e "\nVendor info fetch complete."
echo

# Step 4: Test only saved networks
for ap in "${aps[@]}"; do
    IFS='|' read -r ssid bssid mode channel freq rate bw signal security <<< "$ap"
    clean_bssid=$(echo "$bssid" | sed 's/\\//g')
    vendor=${vendor_cache[$clean_bssid]:-Unknown}

    if ! printf '%s\n' "${saved_conns[@]}" | grep -Fxq "$ssid"; then
        echo "⏭️ Skipping: SSID=\"$ssid\" | BSSID=$clean_bssid | Vendor=$vendor | Ch=$channel | Freq=$freq | Band=$([ "$channel" -ge 1 ] && [ "$channel" -le 14 ] && echo bg || echo a)"
        continue
    fi

    if [[ "$channel" -ge 1 && "$channel" -le 14 ]]; then
        band="bg"
    else
        band="a"
    fi

    echo "========================================"
    echo "SSID:      $ssid"
    echo "BSSID:     $clean_bssid"
    echo "Vendor:    ${vendor_cache[$clean_bssid]:-Unknown}"
    echo "Mode:      $mode"
    echo "Channel:   $channel"
    echo "Frequency: $freq MHz"
    echo "Rate:      $rate Mbps"
    echo "Bandwidth: $bw MHz"
    echo "Signal:    $signal %"
    echo "Security:  $security"
    echo "Band:      $band"
    echo "----------------------------------------"
    echo ">>> Testing band: $band"

    nmcli connection modify "$ssid" wifi.band "$band"
    nmcli connection modify "$ssid" wifi.bssid "$clean_bssid"

    START_TIME=$(date +"%Y-%m-%d %H:%M:%S")
    SECONDS=0

    if nmcli connection up "$ssid" >/dev/null 2>&1; then
        echo "✅ Connected OK on $band"
        nmcli device disconnect "$IFACE" >/dev/null 2>&1
    else
        echo "❌ Failed on $band"
        echo "Recent NetworkManager logs since $START_TIME:"
        journalctl -u NetworkManager --since "$START_TIME" | \
            grep -Ei "wpa|dhcp|auth|deauth|fail|error" | tail -n 10
    fi

    nmcli connection down "$ssid" >/dev/null 2>&1
    echo "⏱️ Test duration: $SECONDS seconds"
    echo
    sleep 3
done

echo "🔄 Restoring Wi-Fi state..."
nmcli radio wifi on
nmcli device set "$IFACE" managed yes
nmcli device connect "$IFACE"
