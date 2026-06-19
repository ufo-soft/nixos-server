{ config, pkgs, lib, ... }:

let
  # Add DNS records here that should track the server's public IP.
  # Each entry needs the full record name and the Cloudflare zone (domain).
  dnsRecords = [
    { name = "server.timothymarias.com"; zone = "timothymarias.com"; }
    { name = "lupin-api-production.timothymarias.com"; zone = "timothymarias.com"; }
    { name = "lupin-api-staging.timothymarias.com"; zone = "timothymarias.com"; }
  ];

  ddnsScript = pkgs.writeShellScript "cloudflare-ddns" ''
    set -euo pipefail

    CF_API_TOKEN=$(cat ${config.sops.secrets."cloudflare-api-token".path})
    CURRENT_IP=$(${pkgs.curl}/bin/curl -s https://ifconfig.me)

    if [ -z "$CURRENT_IP" ]; then
      echo "Failed to get public IP"
      exit 1
    fi

    echo "Current public IP: $CURRENT_IP"

    update_record() {
      local RECORD_NAME="$1"
      local ZONE_NAME="$2"

      # Get zone ID
      local ZONE_ID=$(${pkgs.curl}/bin/curl -s \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME" \
        | ${pkgs.jq}/bin/jq -r '.result[0].id')

      if [ "$ZONE_ID" = "null" ] || [ -z "$ZONE_ID" ]; then
        echo "Failed to get zone ID for $ZONE_NAME"
        return 1
      fi

      # Get existing record
      local RECORD_DATA=$(${pkgs.curl}/bin/curl -s \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$RECORD_NAME&type=A")

      local RECORD_ID=$(echo "$RECORD_DATA" | ${pkgs.jq}/bin/jq -r '.result[0].id')
      local OLD_IP=$(echo "$RECORD_DATA" | ${pkgs.jq}/bin/jq -r '.result[0].content')

      if [ "$OLD_IP" = "$CURRENT_IP" ]; then
        echo "$RECORD_NAME already points to $CURRENT_IP, no update needed"
        return 0
      fi

      if [ "$RECORD_ID" = "null" ] || [ -z "$RECORD_ID" ]; then
        echo "No existing A record found for $RECORD_NAME, creating..."
        ${pkgs.curl}/bin/curl -s -X POST \
          -H "Authorization: Bearer $CF_API_TOKEN" \
          -H "Content-Type: application/json" \
          --data "{\"type\":\"A\",\"name\":\"$RECORD_NAME\",\"content\":\"$CURRENT_IP\",\"ttl\":300,\"proxied\":false}" \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
          | ${pkgs.jq}/bin/jq '.success'
      else
        echo "Updating $RECORD_NAME from $OLD_IP to $CURRENT_IP"
        ${pkgs.curl}/bin/curl -s -X PUT \
          -H "Authorization: Bearer $CF_API_TOKEN" \
          -H "Content-Type: application/json" \
          --data "{\"type\":\"A\",\"name\":\"$RECORD_NAME\",\"content\":\"$CURRENT_IP\",\"ttl\":300,\"proxied\":false}" \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
          | ${pkgs.jq}/bin/jq '.success'
      fi
    }

    ${lib.concatMapStringsSep "\n" (r: ''update_record "${r.name}" "${r.zone}"'') dnsRecords}
  '';
in
{
  systemd.services.cloudflare-ddns = {
    description = "Update Cloudflare DNS records with current public IP";
    after = [ "network-online.target" "sops-nix.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = ddnsScript;
    };
  };

  systemd.timers.cloudflare-ddns = {
    description = "Cloudflare DDNS update timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
      Persistent = true;
    };
  };
}
