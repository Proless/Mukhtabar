#! /usr/bin/env bash

set -e

echo "Updating Proxmox VE Sources..."

cat <<EOF >/etc/apt/sources.list
deb http://deb.debian.org/debian bookworm main contrib
deb http://deb.debian.org/debian bookworm-updates main contrib
deb http://security.debian.org/debian-security bookworm-security main contrib
EOF

echo 'APT::Get::Update::SourceListWarnings::NonFreeFirmware "false";' >/etc/apt/apt.conf.d/no-bookworm-firmware.conf

cat <<EOF >/etc/apt/sources.list.d/pve-enterprise.list
# deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise
EOF

cat <<EOF >/etc/apt/sources.list.d/pve-install-repo.list
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF

cat <<EOF >/etc/apt/sources.list.d/ceph.list
# deb https://enterprise.proxmox.com/debian/ceph-quincy bookworm enterprise
# deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription
# deb https://enterprise.proxmox.com/debian/ceph-reef bookworm enterprise
# deb http://download.proxmox.com/debian/ceph-reef bookworm no-subscription
EOF

cat <<EOF >/etc/apt/sources.list.d/pvetest-for-beta.list
# deb http://download.proxmox.com/debian/pve bookworm pvetest
EOF

echo "Removing Subscription Warning Message..."

mkdir -p /usr/local/bin
cat >/usr/local/bin/pve-remove-nag.sh <<'EOF'
#!/bin/sh
WEB_JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
if [ -s "$WEB_JS" ] && ! grep -q NoMoreNagging "$WEB_JS"; then
    echo "Patching Web UI nag..."
    sed -i -e "/data\.status/ s/!//" -e "/data\.status/ s/active/NoMoreNagging/" "$WEB_JS"
fi

MOBILE_TPL=/usr/share/pve-yew-mobile-gui/index.html.tpl
MARKER="<!-- MANAGED BLOCK FOR MOBILE NAG -->"
if [ -f "$MOBILE_TPL" ] && ! grep -q "$MARKER" "$MOBILE_TPL"; then
    echo "Patching Mobile UI nag..."
    printf "%s\n" \
      "$MARKER" \
      "<script>" \
      "  function removeSubscriptionElements() {" \
      "    // --- Remove subscription dialogs ---" \
      "    const dialogs = document.querySelectorAll('dialog.pwt-outer-dialog');" \
      "    dialogs.forEach(dialog => {" \
      "      const text = (dialog.textContent || '').toLowerCase();" \
      "      if (text.includes('subscription')) {" \
      "        dialog.remove();" \
      "        console.log('Removed subscription dialog');" \
      "      }" \
      "    });" \
      "" \
      "    // --- Remove subscription cards, but keep Reboot/Shutdown/Console ---" \
      "    const cards = document.querySelectorAll('.pwt-card.pwt-p-2.pwt-d-flex.pwt-interactive.pwt-justify-content-center');" \
      "    cards.forEach(card => {" \
      "      const text = (card.textContent || '').toLowerCase();" \
      "      const hasButton = card.querySelector('button');" \
      "      if (!hasButton && text.includes('subscription')) {" \
      "        card.remove();" \
      "        console.log('Removed subscription card');" \
      "      }" \
      "    });" \
      "  }" \
      "" \
      "  const observer = new MutationObserver(removeSubscriptionElements);" \
      "  observer.observe(document.body, { childList: true, subtree: true });" \
      "  removeSubscriptionElements();" \
      "  setInterval(removeSubscriptionElements, 300);" \
      "  setTimeout(() => {observer.disconnect();}, 10000);" \
      "</script>" \
      "" >> "$MOBILE_TPL"
fi
EOF

chmod 755 /usr/local/bin/pve-remove-nag.sh
cat >/etc/apt/apt.conf.d/no-nag-script <<'EOF'
DPkg::Post-Invoke { "/usr/local/bin/pve-remove-nag.sh"; };
EOF
chmod 644 /etc/apt/apt.conf.d/no-nag-script
apt --reinstall install proxmox-widget-toolkit

echo "Updating System..."
apt update
apt -y dist-upgrade
apt -y autoremove

echo "Reboot..."
sleep 2s

reboot