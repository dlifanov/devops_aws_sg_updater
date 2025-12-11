#!/usr/bin/env bash
set -eo pipefail

SSH_KEY="$HOME/.ssh/id_rsa_aws"

SG_NAME=$(ssh -i $SSH_KEY user3@2bcloud.io "ec2-metadata | grep security-groups | cut -d ' ' -f2")
REGION=$(ssh -i $SSH_KEY user3@2bcloud.io "ec2-metadata | grep region | cut -d ' ' -f2")
HOME_IP=$(curl -fSs https://checkip.amazonaws.com | tr -d '[:space:]')
HOME_IP="${HOME_IP}/32"
printf "Detected home IP: $HOME_IP\n"

HTTP_TEMPLATE=()
while IFS= read -r cidr; do
  HTTP_TEMPLATE+=("$cidr")
done < <(
  awk '
    /^[[:space:]]*http:/ {http_block=1; next}
    /^[[:space:]]*[A-Za-z0-9_-]+:/ {http_block=0}
    http_block && /^[[:space:]]*-[[:space:]]*/ {sub(/^[[:space:]]*-[[:space:]]*/,""); print}
  ' template.yaml
)

SSH_TEMPLATE=()
while IFS= read -r cidr; do
  SSH_TEMPLATE+=("$cidr")
done < <(
  awk '
    /^[[:space:]]*ssh:/ {ssh_block=1; next}
    /^[[:space:]]*[A-Za-z0-9_-]+:/ {ssh_block=0}
    ssh_block && /^[[:space:]]*-[[:space:]]*/ {sub(/^[[:space:]]*-[[:space:]]*/,""); print}
  ' template.yaml
)

HTTP_TEMPLATE_B64=$(printf '%s\n' "${HTTP_TEMPLATE[@]}" | base64 | tr -d '\n')
SSH_TEMPLATE_B64=$(printf '%s\n' "${SSH_TEMPLATE[@]}" | base64 | tr -d '\n')

REMOTE_OUT=$(ssh -i "$SSH_KEY" user3@2bcloud.io SG_NAME="$SG_NAME" REGION="$REGION" HOME_IP="$HOME_IP" HTTP_TEMPLATE_B64="$HTTP_TEMPLATE_B64" SSH_TEMPLATE_B64="$SSH_TEMPLATE_B64" bash <<'EOF'
set -euo pipefail
mapfile -t HTTP_TEMPLATE < <(printf '%s' "$HTTP_TEMPLATE_B64" | base64 -d)
mapfile -t SSH_TEMPLATE  < <(printf '%s' "$SSH_TEMPLATE_B64" | base64 -d)

mapfile -t CF_ALLOWED < <(curl -fsSL https://www.cloudflare.com/ips-v4)

mapfile -t SG_HTTP < <(
  aws ec2 describe-security-groups --region "$REGION" \
  | jq -r --arg name "$SG_NAME" '
      .SecurityGroups[]
      | select(.GroupName==$name)
      | .IpPermissions[0].IpRanges[]?.CidrIp
    ' \
  | sed '/^$/d'
)
printf 'Cloudflare range: %s\n' "${CF_ALLOWED[@]}"
# printf 'HTTP_TEMPLATE: %s\n' "${HTTP_TEMPLATE[@]}"
# printf 'SSH_TEMPLATE: %s\n' "${SSH_TEMPLATE[@]}"
# printf 'SG_HTTP: %s\n' "${SG_HTTP[@]}"

ALLOWED=()
while IFS= read -r cidr; do
  [[ -n "$cidr" ]] && ALLOWED+=("$cidr")
done < <(
  printf '%s\n' "${CF_ALLOWED[@]}" "${HTTP_TEMPLATE[@]}" "$HOME_IP" |
    sed '/^$/d' | sort -u
)

# printf 'ALLOWED: %s\n' "${ALLOWED[@]}"

# Dedup both lists
mapfile -t SG_HTTP <<<"$(printf '%s\n' "${SG_HTTP[@]}" | sed '/^$/d' | sort -u)"
mapfile -t ALLOWED <<<"$(printf '%s\n' "${ALLOWED[@]}" | sed '/^$/d' | sort -u)"

declare -A allowed_map current_map
for cidr in "${ALLOWED[@]}"; do allowed_map["$cidr"]=1; done
for cidr in "${SG_HTTP[@]}"; do current_map["$cidr"]=1; done

TO_DELETE=()
for cidr in "${SG_HTTP[@]}"; do
  [[ -z ${allowed_map["$cidr"]+x} ]] && TO_DELETE+=("$cidr")
done

TO_ADD=()
for cidr in "${ALLOWED[@]}"; do
  [[ -z ${current_map["$cidr"]+x} ]] && TO_ADD+=("$cidr")
done

printf 'HTTP rules to delete (%d): %s\n' "${TO_DELETE[@]}"
printf 'HTTP rules to apply  (%d): %s\n' "${TO_ADD[@]}"
printf 'HTTP Changes to apply: %d\n' "$(( ${#TO_DELETE[@]} + ${#TO_ADD[@]} ))"
printf 'Final rules count after apply: %d\n' "$(( ${#SG_HTTP[@]} - ${#TO_DELETE[@]} + ${#TO_ADD[@]} ))"

for cidr in "${TO_ADD[@]}"; do
  [[ -z "$cidr" ]] && continue
  aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-name "$SG_NAME" \
    --protocol tcp \
    --port 80 \
    --cidr "$cidr"
done

for cidr in "${TO_DELETE[@]}"; do
  [[ -z "$cidr" ]] && continue
  aws ec2 revoke-security-group-ingress \
    --region "$REGION" \
    --group-name "$SG_NAME" \
    --protocol tcp \
    --port 80 \
    --cidr "$cidr"
done

# Current SSH rules on the SG (port 22)
mapfile -t SG_SSH < <(
  aws ec2 describe-security-groups --region "$REGION" \
  | jq -r --arg name "$SG_NAME" '
      .SecurityGroups[]
      | select(.GroupName==$name)
      | .IpPermissions[]?
      | select((.IpProtocol=="tcp" or .IpProtocol=="-1") and ((.FromPort//0)<=22 and (.ToPort//0)>=22))
      | .IpRanges[]?.CidrIp
    ' | sed '/^$/d'
)

# Allowed SSH rules come only from the template
mapfile -t ALLOWED_SSH <<<"$(printf '%s\n' "${SSH_TEMPLATE[@]}" | sed '/^$/d' | sort -u)"
mapfile -t SG_SSH    <<<"$(printf '%s\n' "${SG_SSH[@]}"    | sed '/^$/d' | sort -u)"

declare -A allowed_ssh current_ssh
for cidr in "${ALLOWED_SSH[@]}"; do allowed_ssh["$cidr"]=1; done
for cidr in "${SG_SSH[@]}";    do current_ssh["$cidr"]=1;  done

TO_DELETE_SSH=()
for cidr in "${SG_SSH[@]}"; do
  [[ -z ${allowed_ssh["$cidr"]+x} ]] && TO_DELETE_SSH+=("$cidr")
done

TO_ADD_SSH=()
for cidr in "${ALLOWED_SSH[@]}"; do
  [[ -z ${current_ssh["$cidr"]+x} ]] && TO_ADD_SSH+=("$cidr")
done

printf 'SSH rules to delete (%d): %s\n' "${#TO_DELETE_SSH[@]}" "${TO_DELETE_SSH[@]}"
printf 'SSH rules to apply    (%d): %s\n' "${#TO_ADD_SSH[@]}" "${TO_ADD_SSH[@]}"
printf 'SSH changes to apply: %d\n' "$(( ${#TO_DELETE_SSH[@]} + ${#TO_ADD_SSH[@]} ))"

for cidr in "${TO_ADD_SSH[@]}"; do
  [[ -z "$cidr" ]] && continue
  aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-name "$SG_NAME" \
    --protocol tcp \
    --port 22 \
    --cidr "$cidr"
done

# for cidr in "${TO_DELETE_SSH[@]}"; do
#   [[ -z "$cidr" ]] && continue
#   aws ec2 revoke-security-group-ingress \
#     --region "$REGION" \
#     --group-name "$SG_NAME" \
#     --protocol tcp \
#     --port 22 \
#     --cidr "$cidr"
# done

ALLOWED_HTTP_B64=$(printf '%s\n' "${ALLOWED[@]}"      | base64 | tr -d '\n')
ALLOWED_SSH_B64=$(printf '%s\n' "${ALLOWED_SSH[@]}"   | base64 | tr -d '\n')
echo "__ALLOWED_HTTP_B64__=$ALLOWED_HTTP_B64"
echo "__ALLOWED_SSH_B64__=$ALLOWED_SSH_B64"
EOF)

printf '%s\n' "$REMOTE_OUT" | sed '/^__ALLOWED_/d'
ALLOWED_HTTP_B64=$(printf '%s\n' "$REMOTE_OUT" | sed -n 's/^__ALLOWED_HTTP_B64__=//p' | tail -n1)
ALLOWED_SSH_B64=$(printf '%s\n' "$REMOTE_OUT" | sed -n 's/^__ALLOWED_SSH_B64__=//p' | tail -n1)
while IFS= read -r cidr; do [[ -n "$cidr" ]] && ALLOWED_HTTP+=("$cidr"); done <<<"$(printf '%s' "$ALLOWED_HTTP_B64" | base64 -d)"
ALLOWED_SSH=()
while IFS= read -r cidr; do [[ -n "$cidr" ]] && ALLOWED_SSH+=("$cidr"); done <<<"$(printf '%s' "$ALLOWED_SSH_B64" | base64 -d)"

printf 'ALLOWED_HTTP: %s\n' "${ALLOWED_HTTP[@]}"
printf 'ALLOWED_SSH: %s\n' "${ALLOWED_SSH[@]}"

 NAME=$(awk -F: '/^name:[[:space:]]*/{sub(/^name:[[:space:]]*/,"");print; exit}' template.yaml)
  : "${NAME:=security-group}"

  tmp=$(mktemp)
  {
    printf 'name: %s\n' "$NAME"
    printf 'rules:\n'
    printf '  ssh:\n'
    printf '  - %s\n' "${ALLOWED_SSH[@]}"
    printf '  http:\n'
    printf '  - %s\n' "${ALLOWED_HTTP[@]}"
  } > "$tmp" && mv "$tmp" template.yaml