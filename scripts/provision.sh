#!/usr/bin/env bash
# Unit 4 - Cloud Computing and DevOps  -  OTHM K/650/7997
# Artefact P4.7   Assessment criteria: AC 2.5, 4.1, 4.2
# Linux VM provisioning, hardening and user/group administration
# 
# Vera Cree  |  Candidate 240301062  |  CIPS Centre DC2401845

# provision.sh - EC2 user data. Idempotent; safe to re-run.
set -Eeuo pipefail
exec > >(tee /var/log/provision.log) 2>&1

echo "=== [1/7] Base packages and updates ==="
dnf -y update
dnf -y install docker git jq amazon-cloudwatch-agent \
               chrony fail2ban aide htop sysstat

echo "=== [2/7] Groups and users (AC 4.2) ==="
# Groups first - a user cannot be added to a group that does not exist
for g in skyforge-devs skyforge-ops skyforge-audit; do
    getent group "$g" >/dev/null || groupadd "$g"
done

create_user() {                          # name, primary group, extra groups, key
    local user="$1" primary="$2" extra="$3" key="$4"
    if ! id "$user" &>/dev/null; then
        useradd --create-home --shell /bin/bash \
                --gid "$primary" --groups "$extra" "$user"
        echo "  created $user"
    fi
    install -d -m 700 -o "$user" -g "$primary" "/home/$user/.ssh"
    printf '%s\n' "$key" > "/home/$user/.ssh/authorized_keys"
    chown "$user:$primary" "/home/$user/.ssh/authorized_keys"
    chmod 600 "/home/$user/.ssh/authorized_keys"
    chage --maxdays 90 --warndays 14 "$user"      # password ageing policy
}

create_user vcree    skyforge-ops   skyforge-devs,docker "$(aws ssm get-parameter \
    --name /skyforge/keys/vcree --with-decryption --query Parameter.Value --output text)"
create_user deployer skyforge-ops   docker               "$(aws ssm get-parameter \
    --name /skyforge/keys/deployer --with-decryption --query Parameter.Value --output text)"

# Least-privilege sudo - specific commands, not blanket ALL
cat > /etc/sudoers.d/skyforge <<'SUDO'
%skyforge-ops   ALL=(ALL) NOPASSWD: /bin/systemctl restart skyforge-api, \
                                    /bin/systemctl status  skyforge-api, \
                                    /usr/bin/journalctl
%skyforge-devs  ALL=(ALL) NOPASSWD: /usr/bin/journalctl -u skyforge-api
%skyforge-audit ALL=(ALL) NOPASSWD: /usr/sbin/aide --check
Defaults        logfile=/var/log/sudo.log, log_input, log_output
SUDO
chmod 440 /etc/sudoers.d/skyforge
visudo -cf /etc/sudoers.d/skyforge        # validate before it can lock anyone out

echo "=== [3/7] Filesystem permissions ==="
install -d -m 2750 -o root -g skyforge-ops   /opt/skyforge      # setgid
install -d -m 2770 -o root -g skyforge-devs  /opt/skyforge/logs
setfacl -m g:skyforge-audit:rx /opt/skyforge/logs

echo "=== [4/7] SSH hardening ==="
cat > /etc/ssh/sshd_config.d/99-skyforge.conf <<'SSHD'
PermitRootLogin          no
PasswordAuthentication   no
PubkeyAuthentication     yes
AllowGroups              skyforge-ops skyforge-devs
MaxAuthTries             3
ClientAliveInterval      300
ClientAliveCountMax      2
X11Forwarding            no
SSHD
sshd -t && systemctl reload sshd

echo "=== [5/7] Host firewall ==="
systemctl enable --now firewalld
firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --remove-service=dhcpv6-client
firewall-cmd --reload

echo "=== [6/7] Services, time sync, intrusion detection ==="
systemctl enable --now docker chronyd fail2ban sysstat
usermod -aG docker deployer
aide --init && mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
echo "0 3 * * * root /usr/sbin/aide --check | mail -s 'AIDE report' ops@skyforge.io" \
     > /etc/cron.d/aide

echo "=== [7/7] Observability agent ==="
amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s \
    -c ssm:/skyforge/cloudwatch-agent-config

echo "=== Provisioning complete on $(hostname -f) at $(date -Is) ==="
