#!/usr/bin/env bash
# CLUB ACCOUNT SERVER - STEP 1 OF THE SERVER BUILD
# Run on a brand-new Ubuntu Server 24.04 virtual machine (nothing else on it):
#     sudo bash club-server-setup.sh
# It turns the machine into the club's account server (a Windows-style "domain controller"
# made with Samba): the place student accounts live. It is safe to run again - it skips
# anything already done. It does NOT touch any laptop.
set -euo pipefail

REALM="${CLUB_REALM:-CYBERCLUB.LAN}"
NETBIOS="${CLUB_NETBIOS:-CYBERCLUB}"
HOSTNAME_SHORT="${CLUB_HOSTNAME:-dc1}"
UPSTREAM_DNS="${CLUB_UPSTREAM_DNS:-}"
SECRETS=/root/club-server-secrets.txt
REALM_LC="$(echo "$REALM" | tr '[:upper:]' '[:lower:]')"
BASE_DN="DC=$(echo "$REALM_LC" | sed 's/\./,DC=/g')"

say()  { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32mOK\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS + 1)); }
die()  { printf '\n\033[1;31mSTOPPED: %s\033[0m\n' "$*"; exit 1; }
ask()  { local a; read -r -p "$1 " a </dev/tty; echo "$a"; }
FAILS=0

[ "$(id -u)" = "0" ] || die "Run it with sudo:  sudo bash club-server-setup.sh"
# A Proxmox container (LXC) works too, as long as it is a PRIVILEGED container. That is checked in step 2.
LXC=0
[ "$(systemd-detect-virt 2>/dev/null || true)" = "lxc" ] && LXC=1
. /etc/os-release
case "${ID:-}-${VERSION_ID:-}" in
  ubuntu-24.04|debian-13) ;;
  *) echo "This was written for Ubuntu Server 24.04. This machine is ${PRETTY_NAME:-unknown}."
     [ "$(ask 'Type YES to try anyway:')" = "YES" ] || exit 1 ;;
esac

# ---------- 1. Work out this machine's network ----------
say "1 of 7  Looking at the network"
DEV="$(ip -4 route show default | awk '{print $5; exit}')"
GATEWAY="$(ip -4 route show default | awk '{print $3; exit}')"
[ -n "$DEV" ] || die "This machine has no network connection yet. Fix that first."
CIDR_ADDR="$(ip -o -4 addr show dev "$DEV" scope global | awk '{print $4; exit}')"
IP="${CIDR_ADDR%/*}"
PREFIX="${CIDR_ADDR#*/}"
NETWORK="$(python3 -c "import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)" "$CIDR_ADDR")"
ALLOW_FROM="${CLUB_ALLOW_FROM:-$NETWORK}"
if [ -z "$UPSTREAM_DNS" ]; then
  UPSTREAM_DNS="$(resolvectl dns "$DEV" 2>/dev/null | awk '{for (i = 4; i <= NF; i++) if ($i !~ /^127\./ && $i !~ /:/) { print $i; exit }}')" || true
fi
[ -n "$UPSTREAM_DNS" ] || UPSTREAM_DNS="$(awk '/^nameserver/ && $2 !~ /^127\./ {print $2; exit}' /etc/resolv.conf)" || true
[ -n "$UPSTREAM_DNS" ] || UPSTREAM_DNS="1.1.1.1"

echo "  Network card:        $DEV"
echo "  This server:         $IP  (network $NETWORK, gateway $GATEWAY)"
echo "  Laptops allowed from: $ALLOW_FROM"
echo "  Internet names from: $UPSTREAM_DNS"
echo "  Domain:              $REALM  (short name $NETBIOS), server name $HOSTNAME_SHORT"

ALREADY=0
[ -f /var/lib/samba/private/sam.ldb ] && ALREADY=1

if [ "$ALREADY" = "0" ]; then
  echo
  echo "  IMPORTANT: the address $IP gets baked into the server. It must be an address on the"
  echo "  SCHOOL network (the same kind the laptops have), and it must never change."
  [ "$(ask '  Is that the right address for the server? Type YES to continue:')" = "YES" ] || die "Nothing was changed. Put the server on the right network and run this again."
fi

# ---------- 2. Install what is needed ----------
say "2 of 7  Installing the server software (a few minutes)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q samba winbind krb5-user smbclient ldb-tools dnsutils acl attr chrony ufw openssl >/dev/null
ok "software installed ($(samba --version))"

# Can this machine store Windows file permissions? The account server cannot work without it.
T="/var/lib/samba/.club-check.$$"
mkdir -p /var/lib/samba && : > "$T"
XOK=0; AOK=0
setfattr -n security.NTACL -v test "$T" 2>/dev/null && XOK=1
setfacl -m u:nobody:r "$T" 2>/dev/null && AOK=1
rm -f "$T"
if [ "$XOK" != "1" ] || [ "$AOK" != "1" ]; then
  echo
  printf '\033[1;31mSTOPPED: this machine cannot store Windows file permissions, so the account server would not work.\033[0m\n'
  if [ "$LXC" = "1" ]; then
    echo "This is a Proxmox container, and it has to be a PRIVILEGED one with ACLs switched on."
    echo "Nothing has been changed yet. To fix it, in Proxmox:"
    [ "$XOK" = "1" ] || echo "  1. Back this container up (Backup > Backup now), then Restore it with 'Unprivileged container' UNTICKED."
    [ "$XOK" = "1" ] || echo "     (Or delete it and create it again with 'Unprivileged container' unticked on the first screen.)"
    [ "$AOK" = "1" ] || echo "  2. Container > Resources > Root Disk > Edit > Advanced > set ACLs to 'Enabled', then restart the container."
    echo "Then run this file again."
  else
    echo "The disk this machine is on does not allow extended attributes or ACLs."
  fi
  exit 1
fi
ok "this machine can store Windows file permissions"
if [ "$LXC" = "1" ]; then
  # Stop Proxmox from rewriting these files each time the container starts.
  touch /etc/.pve-ignore.hosts /etc/.pve-ignore.resolv.conf /etc/.pve-ignore.hostname
  ok "running in a Proxmox container (privileged) - adjusted for that"
fi

# ---------- 3. Name and fixed address ----------
say "3 of 7  Giving the server its name and a fixed address"
hostnamectl set-hostname "$HOSTNAME_SHORT"
sed -i '/^127\.0\.1\.1/d' /etc/hosts
sed -i "/[[:space:]]$HOSTNAME_SHORT\.$REALM_LC/d" /etc/hosts
echo "$IP $HOSTNAME_SHORT.$REALM_LC $HOSTNAME_SHORT" >> /etc/hosts
ok "name is $HOSTNAME_SHORT.$REALM_LC"

# ---------- 4. Create the domain ----------
say "4 of 7  Creating the club domain"
if [ "$ALREADY" = "1" ]; then
  ok "the domain already exists - left alone"
else
  systemctl disable --now smbd nmbd winbind >/dev/null 2>&1 || true
  systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
  rm -f /etc/resolv.conf
  printf 'nameserver %s\n' "$UPSTREAM_DNS" > /etc/resolv.conf
  [ -f /etc/samba/smb.conf ] && mv /etc/samba/smb.conf "/etc/samba/smb.conf.before-club"
  ADMIN_PASS="$(openssl rand -base64 18)aA1"
  umask 077
  {
    echo "Club account server - made $(date '+%Y-%m-%d %H:%M')"
    echo "Domain: $REALM   Server: $HOSTNAME_SHORT.$REALM_LC   Address: $IP"
    echo "Domain administrator user: Administrator"
    echo "Domain administrator password: $ADMIN_PASS"
  } > "$SECRETS"
  chmod 600 "$SECRETS"
  samba-tool domain provision --use-rfc2307 --realm="$REALM" --domain="$NETBIOS" \
    --server-role=dc --dns-backend=SAMBA_INTERNAL --adminpass="$ADMIN_PASS" \
    --host-ip="$IP" \
    --option="dns forwarder = $UPSTREAM_DNS" \
    --option="interfaces = lo $DEV" --option="bind interfaces only = yes" >/var/log/club-provision.log 2>&1 \
    || die "Creating the domain failed. The details are in /var/log/club-provision.log"
  unset ADMIN_PASS
  cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
  printf 'search %s\nnameserver 127.0.0.1\n' "$REALM_LC" > /etc/resolv.conf
  ok "domain $REALM created"
fi
systemctl unmask samba-ad-dc >/dev/null 2>&1 || true
systemctl enable --now samba-ad-dc >/dev/null 2>&1
for _ in $(seq 1 30); do
  if (exec 3<>/dev/tcp/127.0.0.1/389) 2>/dev/null; then break; fi
  sleep 1
done
(exec 3<>/dev/tcp/127.0.0.1/389) 2>/dev/null || die "The account service did not start. Run:  journalctl -u samba-ad-dc -n 50"
ok "account service is running"

# Keep the address fixed from now on (the laptops will look for the server at this address).
if [ "$LXC" = "1" ] || ! command -v netplan >/dev/null 2>&1 || [ ! -d /etc/netplan ]; then
  STATIC_NOTE="In Proxmox: this container > Network > eth0 > Edit > IPv4 'Static', address $IP/$PREFIX, gateway $GATEWAY. Do this now so the address can never change."
  echo "  NOTE: $STATIC_NOTE"
elif ! grep -qs "club-static" /etc/netplan/99-club-static.yaml 2>/dev/null; then
  cat > /etc/netplan/99-club-static.yaml <<EOF
# club-static: written by club-server-setup.sh
network:
  version: 2
  ethernets:
    $DEV:
      dhcp4: false
      addresses: [$IP/$PREFIX]
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [127.0.0.1]
        search: [$REALM_LC]
EOF
  chmod 600 /etc/netplan/99-club-static.yaml
  netplan generate >/dev/null 2>&1 && ok "address $IP is now fixed (applies fully at the next restart)" \
    || { rm -f /etc/netplan/99-club-static.yaml; echo "  (could not fix the address automatically - ask for a reserved address instead)"; }
fi

# ---------- 5. Structure: where accounts and laptops live ----------
say "5 of 7  Making the account folders and groups"
has_line() { grep -qix -- "$2" <<<"$1"; }
has_text() { grep -qi -- "$2" <<<"$1"; }
mk_ou()    { local l; l="$(samba-tool ou list 2>/dev/null || true)"; has_line "$l" "OU=$1" || samba-tool ou create "OU=$1,$BASE_DN" >/dev/null; }
mk_group() { local l; l="$(samba-tool group list 2>/dev/null || true)"; has_line "$l" "$1" || samba-tool group add "$1" --groupou="OU=$2" --description="$3" >/dev/null; }
mk_ou Students
mk_ou Laptops
mk_ou ClubAdmins
mk_ou ServiceAccounts
mk_group ClubStudents Students   "Every student account"
mk_group ClubAdmins   ClubAdmins "Mentors and officers with admin power"
samba-tool domain passwordsettings set --complexity=off --min-pwd-length=8 --min-pwd-age=0 --max-pwd-age=0 --history-length=0 >/dev/null
samba-tool domain passwordsettings set --account-lockout-threshold=10 --account-lockout-duration=15 --reset-account-lockout-after=15 >/dev/null
ok "Students, Laptops, ClubAdmins and ServiceAccounts are ready"

# ---------- 6. Clock ----------
say "6 of 7  Clock (Windows sign-in breaks if clocks disagree)"
install -d -o root -g _chrony -m 750 /var/lib/samba/ntp_signd 2>/dev/null || true
if ! grep -qs "club-server-setup" /etc/chrony/chrony.conf; then
  {
    echo ""
    echo "# club-server-setup: serve time to the laptops"
    echo "allow $ALLOW_FROM"
    echo "ntpsigndsocket /var/lib/samba/ntp_signd"
  } >> /etc/chrony/chrony.conf
fi
if [ "$LXC" = "1" ]; then
  # A container cannot set the clock (the Proxmox host does that), but it can still hand the time to the laptops.
  mkdir -p /etc/systemd/system/chrony.service.d
  printf '[Unit]\nConditionCapability=\n' > /etc/systemd/system/chrony.service.d/club.conf
  if [ -f /etc/default/chrony ] && ! grep -q -- "-x" /etc/default/chrony; then
    sed -i 's/^DAEMON_OPTS="\(.*\)"/DAEMON_OPTS="\1 -x"/' /etc/default/chrony
  fi
  systemctl daemon-reload
fi
systemctl restart chrony >/dev/null 2>&1 || systemctl restart chronyd >/dev/null 2>&1 || true
if systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null; then ok "this server now gives the time to the laptops"
else echo "  NOTE: the time service did not start. Laptops will keep their own clocks; tell Claude if sign-ins start failing with clock errors."; fi

# ---------- 7. Firewall ----------
say "7 of 7  Firewall: only the laptop network can reach the account service"
if ( ufw --force reset >/dev/null 2>&1 && ufw default deny incoming >/dev/null 2>&1 && ufw default allow outgoing >/dev/null 2>&1 && ufw allow 22/tcp >/dev/null 2>&1 ); then
  for rule in 53/tcp 53/udp 88/tcp 88/udp 123/udp 135/tcp 137/udp 138/udp 139/tcp 389/tcp 389/udp 445/tcp 464/tcp 464/udp 636/tcp 3268/tcp 3269/tcp 49152:65535/tcp; do
    ufw allow from "$ALLOW_FROM" to any port "${rule%/*}" proto "${rule#*/}" >/dev/null 2>&1 || true
  done
  if ufw --force enable >/dev/null 2>&1; then ok "firewall is on"
  else echo "  NOTE: the firewall could not be switched on inside this machine. Use the Proxmox firewall for this container instead."; fi
else
  echo "  NOTE: the firewall could not be set up inside this machine. Use the Proxmox firewall for this container instead."
fi

# ---------- Checks ----------
say "CHECKING IT ALL WORKS"
systemctl is-active --quiet samba-ad-dc && ok "account service running" || bad "account service is not running"
host -t SRV "_ldap._tcp.$REALM_LC" 127.0.0.1 >/dev/null 2>&1 && ok "laptops can find the server by name" || bad "the name lookup for the domain does not work"
has_text "$(host -t A "$HOSTNAME_SHORT.$REALM_LC" 127.0.0.1 2>/dev/null || true)" "$IP" && ok "server name points at $IP" || bad "the server name does not point at $IP"
host -t A example.com 127.0.0.1 >/dev/null 2>&1 && ok "internet names still work through the server" || bad "internet names do not work through the server (check $UPSTREAM_DNS)"
if [ -r "$SECRETS" ]; then
  PW="$(awk -F': ' '/^Domain administrator password/ {print $2}' "$SECRETS")"
  if printf '%s\n' "$PW" | kinit "Administrator@$REALM" >/dev/null 2>&1; then ok "signing in to the domain works"; kdestroy >/dev/null 2>&1 || true; else bad "signing in to the domain did not work"; fi
  unset PW
fi
has_text "$(smbclient -L localhost -N 2>/dev/null || true)" "sysvol" && ok "file sharing answers" || bad "file sharing does not answer"
OU_LIST="$(samba-tool ou list 2>/dev/null || true)"
for want in Students Laptops ClubAdmins ServiceAccounts; do
  has_line "$OU_LIST" "OU=$want" && ok "folder $want exists" || bad "folder $want is missing"
done

echo
if [ "$FAILS" = "0" ]; then
  printf '\033[1;32mALL DONE. The club account server is up.\033[0m\n'
else
  printf '\033[1;31m%s check(s) failed - send a photo of this screen.\033[0m\n' "$FAILS"
fi
echo "  Server address:  $IP      Domain: $REALM"
echo "  The administrator password is saved ON THIS SERVER ONLY, in $SECRETS"
echo "  (see it with:  sudo cat $SECRETS ).  Put it in your password manager."
[ -n "${STATIC_NOTE:-}" ] && printf '\033[1;33m  DO THIS NOW: %s\033[0m\n' "$STATIC_NOTE"
echo "  Nothing on any laptop has changed yet. Next step: student file storage, sign-ups and the admin page."
