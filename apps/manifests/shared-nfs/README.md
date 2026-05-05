# shared-nfs

NFS server lives in the NAS LXC (`192.168.0.186`, CTID 101, Alpine 3.23). Exports `/mnt/storage/cloud-data` to the LAN + cluster pod CIDR.

Used by:
- **Nextcloud** — full RW mount at `/var/www/html/data` (data dir for all users)
- **Navidrome** — read-only mount at `/music` with `subPath: data/chifor/files/Music`

## One-time NFS server setup

```bash
# On the Proxmox host: load nfsd kernel module + relax LXC apparmor
ssh root@192.168.0.185 '
modprobe nfsd
echo nfsd > /etc/modules-load.d/nfsd.conf
grep -q "lxc.apparmor.profile: unconfined" /etc/pve/lxc/101.conf || \
  echo "lxc.apparmor.profile: unconfined" >> /etc/pve/lxc/101.conf
grep -q "lxc.cap.drop:" /etc/pve/lxc/101.conf || \
  echo "lxc.cap.drop:" >> /etc/pve/lxc/101.conf
pct stop 101 && pct start 101
'

# Inside the LXC: install + configure
ssh root@192.168.0.185 'pct exec 101 -- sh -c "
apk add --quiet nfs-utils
mkdir -p /mnt/storage/cloud-data
chown 33:33 /mnt/storage/cloud-data
chmod 0770 /mnt/storage/cloud-data

cat > /etc/exports <<EOF
/mnt/storage/cloud-data 192.168.0.0/16(rw,sync,no_subtree_check,no_root_squash) 10.42.0.0/16(rw,sync,no_subtree_check,no_root_squash)
EOF

rc-update add nfs default
rc-service nfs start
exportfs -rav
"'
```

## Apply the PVs

The PV/PVC manifest in this directory creates two PVs (one each for nextcloud + navidrome) that point at the SAME NFS export. K8s allows that — each PV has its own claimRef.

```bash
kubectl apply -f apps/manifests/shared-nfs/nextcloud-data.yaml
```

## Permission model

| | Nextcloud | Navidrome |
|---|---|---|
| Pod uid | 33 (www-data) | 1000 |
| Mount | `/var/www/html/data` (RW) | `/music` (RO) |
| subPath in NFS | `data` (chart default) | `data/chifor/files/Music` |
| Group access | uid 33 -> reads/writes its own files | gid 33 in `supplementalGroups` so its uid 1000 process can read group-33 files |

The directory tree is `chmod 0770` (owner+group full, others none) and Nextcloud's per-file umask creates new files mode 0640. Navidrome with `supplementalGroups: [33]` lands in group `www-data` and gets the read bit.

## Troubleshooting

**PV stuck "Released" after deleting a PVC:** the PV retains the dead PVC's UID in `claimRef`. Re-creating the PVC won't auto-rebind. Patch:

```bash
kubectl patch pv <pv-name> --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
kubectl apply -f apps/manifests/shared-nfs/nextcloud-data.yaml
```

**NFS export path exists but mount fails with "Operation not permitted":** likely the `lxc.apparmor.profile: unconfined` line is missing from `/etc/pve/lxc/101.conf`. Apparmor restricts nfsd in privileged LXCs without it. Re-run the host-side setup snippet.

**Sentinel test from the cluster:**

```bash
# Drop a file via NFS server-side ssh
ssh root@192.168.0.185 'pct exec 101 -- sh -c "
echo test > /mnt/storage/cloud-data/data/chifor/files/Music/sentinel.txt
chown 33:33 /mnt/storage/cloud-data/data/chifor/files/Music/sentinel.txt
chmod 0640 /mnt/storage/cloud-data/data/chifor/files/Music/sentinel.txt
"'

# Read it from Navidrome
kubectl -n navidrome exec deploy/navidrome -- cat /music/sentinel.txt
# Expected: test
```

If the read fails with "Permission denied", check the supplementary group [33] is in Navidrome's pod spec.
