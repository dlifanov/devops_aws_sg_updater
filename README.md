# DevOps AWS SG Updater

Small helper to sync HTTP/SSH CIDRs in an AWS security group with a YAML template, then write the merged rules back to `template.yaml` and push them.

## What it does
- Detects your public IP via `checkip.amazonaws.com` and adds `/32`.
- Reads HTTP/SSH CIDRs from `template.yaml`.
- Pulls Cloudflare IPv4 ranges and merges/dedupes them with template + home IP for HTTP, and template only for SSH.
- Reconciles the target security group on the remote host (ingress 80/22) to match those lists.
- Rewrites `template.yaml` with the final HTTP/SSH lists.
- Commits and pushes `template.yaml` if it changed.

## Prerequisites
- Tools: `aws`, `jq`, `curl`, `base64`, `git`.
- AWS IAM permissions to describe/modify the target security group.
- GitHub access for `git@github.com:dlifanov/devops_aws_sg_updater.git`Цр

## Usage
```bash
# Optional: override defaults
export SSH_KEY="$HOME/.ssh/id_rsa_aws"
export GIT_REMOTE=origin
export GIT_BRANCH=main
export GIT_DIR="."

./sync.sh
```

On macOS, `mapfile` is not used locally; array reassembly is handled with `while read` and base64 to cross the SSH boundary.

## Git notes
- Origin should use SSH: `git remote set-url origin git@github.com:dlifanov/devops_aws_sg_updater.git`.
- The push uses `GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes"` to force the specified key.

## Template format
```yaml
name: security-group
rules:
  ssh:
    - 0.0.0.0/0
  http:
    - 1.1.1.1/24
    - 8.8.8.8/32
```
`sync.sh` rewrites both `rules.ssh` and `rules.http` with the resolved CIDRs after reconciliation.
