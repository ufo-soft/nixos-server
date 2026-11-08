{ config, pkgs, lib, ... }:

let
  # Add DNS records here that should track the server's public IP.
  # Each entry needs the full record name and the Cloudflare zone (domain).
  # `proxied` only matters when the record is first created; updates patch
  # the IP alone and leave the proxy setting as it is in the dashboard.
  dnsRecords = [
    { name = "server.timothymarias.com"; zone = "timothymarias.com"; proxied = false; }
    { name = "lupin-api-production.timothymarias.com"; zone = "timothymarias.com"; proxied = false; }
    { name = "lupin-api-staging.timothymarias.com"; zone = "timothymarias.com"; proxied = false; }
    # Must be proxied: Traefik serves a Cloudflare Origin CA cert for this
    # host, which only Cloudflare's edge trusts.
    { name = "mariasfamilyarchive.com"; zone = "mariasfamilyarchive.com"; proxied = true; }
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
      local PROXIED="$3"

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
          --data "{\"type\":\"A\",\"name\":\"$RECORD_NAME\",\"content\":\"$CURRENT_IP\",\"ttl\":300,\"proxied\":$PROXIED}" \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
          | ${pkgs.jq}/bin/jq '.success'
      else
        echo "Updating $RECORD_NAME from $OLD_IP to $CURRENT_IP"
        # PATCH only the address: PUT would reset proxied/ttl on every IP change.
        ${pkgs.curl}/bin/curl -s -X PATCH \
          -H "Authorization: Bearer $CF_API_TOKEN" \
          -H "Content-Type: application/json" \
          --data "{\"content\":\"$CURRENT_IP\"}" \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
          | ${pkgs.jq}/bin/jq '.success'
      fi
    }

    ${lib.concatMapStringsSep "\n" (r: ''update_record "${r.name}" "${r.zone}" "${lib.boolToString r.proxied}"'') dnsRecords}
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
