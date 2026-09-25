# Restore and Recovery

Writing the restore document following the 3 am rule. If I can't follow it at 3 am after being shocked awake by a phone call asking me to fix something it's too complicated.

Every procedure assumes you have a browser, a terminal, and access to your password manager.


**Conventions in this document**

- Commands that need a secret pasted in show an `echo` prompt first, so it is
  obvious the terminal is waiting for *you*, not hung.
- `read -rs` means the value will not echo to screen and will not enter shell
  history. That is deliberate. Paste, press Enter, carry on.
- Proxmox token IDs contain `!`. In an interactive shell `!` triggers history
  expansion **inside double quotes**, so token IDs always go in single quotes
  or in their own variable.

---

## 1. Secret inventory

What exists, what it protects, and how badly losing it hurts.

| Secret | Protects | Copies | If lost |
|---|---|---|---|
| `age.agekey` | Every SOPS-encrypted file in `homelab-fleet` | Mac `~/rookery-ca/`, thumb drive, Dropbox (passphrase-encrypted) | **Permanent.** Fleet repo becomes unreadable forever. |
| `rookery-ca.key` | The internal CA that signs every lab certificate | Mac `~/rookery-ca/`, thumb drive, Dropbox (passphrase-encrypted) | **Permanent.** Every device trusts a CA you can no longer issue from. |
| Dropbox backup passphrase | The two keys above, in cloud storage | Password manager | Both offsite copies become inert. Mac copy still works. |
| `TF_VAR_state_passphrase` | OpenTofu state encryption | Password manager, `~/.config/homelab/env` | State unreadable. Recoverable by rebuilding state via import, painful. |
| Proxmox API token | VM create/destroy on all three nodes | Password manager | Rotate it. See section 4. |
| SeaweedFS `tofu` / `rke2` keys | S3 buckets on the NAS | Password manager, `s3.json` on the NAS | Rotate them. See section 5. |

Top two rows are the only genuinely unrecoverable items. Everything else is
an inconvenience.

---

## 2. Recover the age key

Needed when: the Mac is gone, `~/rookery-ca` was deleted, or you are
rebuilding on new hardware and need to decrypt `homelab-fleet`.

```bash
brew install age sops
mkdir -p ~/rookery-ca && cd ~/rookery-ca
```

Download `age.agekey.age` from Dropbox (folder `rookery-backups`), then:

```bash
age -d ~/Downloads/age.agekey.age > age.agekey    # prompts for the passphrase
chmod 600 age.agekey
```

**Verify you recovered the correct key**, not merely a valid one:

```bash
age-keygen -y age.agekey
```

That public key must match the `age:` line in `homelab-fleet/.sops.yaml`.
If it does not, you restored the wrong file.

Then prove it end to end:

```bash
git clone git@github.com:georgepoe2/homelab-fleet.git
cd homelab-fleet
SOPS_AGE_KEY_FILE=~/rookery-ca/age.agekey sops --decrypt <any-file>.sops.yaml
```

---

## 3. Recover the CA key

Same procedure, different file: `rookery-ca.key.age` from the same Dropbox
folder. Once recovered, reissuing a leaf certificate is:

```bash
cd ~/rookery-ca
./issue.sh pve-1 192.168.1.215
```

Then install per the procedure in Phase 2 §2.6 of the runbook. Note the root
certificate itself (`rookery-ca.crt`) is public — it is installed in trust
stores across the house and can be regenerated from the private key.

---

## 4. Rotate the Proxmox API token

Needed when: the token leaked, or on a schedule. Overlap pattern — the new
credential is proven before the old one dies, so there is never a gap.

Run on any node; `/etc/pve` is cluster-wide.

```bash
pveum user token list tofu@pve --output-format json
pveum acl list | grep -i tofu
```

Current configuration: role `tofuProvisioner` is granted to the **user**
`tofu@pve`, and tokens run at `privsep 0`, meaning a token inherits the
user's permissions and needs no ACL of its own. Keep that arrangement and
there is nothing extra to grant.

```bash
pveum user token add tofu@pve provisioner-YYYYMMDD --privsep 0
```

The secret prints **once**. Put it in the password manager immediately.

Verify against all three nodes before revoking anything:

```bash
echo "Paste the new token secret (it will not echo), then press Enter:"
read -rs SECRET
echo

TOKENID='tofu@pve!provisioner-YYYYMMDD'

for h in 192.168.1.215 192.168.1.216 192.168.1.208; do
  echo -n "$h: "
  curl -sk -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: PVEAPIToken=$TOKENID=$SECRET" \
    "https://$h:8006/api2/json/version"
done
```

Three `200`s, then revoke the old one and update `~/.config/homelab/env`:

```bash
pveum user token remove tofu@pve <old-token-id>
pveum user token list tofu@pve
unset SECRET
```

---

## 5. Rotate the SeaweedFS S3 credentials

Both consumers read these: OpenTofu (`tofu` identity) and RKE2 etcd snapshots
(`rke2` identity).

```bash
ssh <nas>
cd /volume2/docker/seaweedfs/config
cp s3.json s3.json.bak
```

Edit `s3.json`, replace the `accessKey` / `secretKey` values, then in DSM:
**Container Manager → Project → seaweedfs → Action → Build**. Editing the
file alone changes nothing.

Then update both consumers:

- `~/.config/homelab/env` on the Mac — `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
- `/etc/rancher/rke2/config.yaml` on each server node — `etcd-s3-access-key` / `etcd-s3-secret-key`, then restart `rke2-server`

Verify auth is still enforced afterwards:

```bash
EP=http://nas.rookery.internal:8333
aws --endpoint-url $EP --no-sign-request s3 ls s3://tofu-state/
```

That must **fail**. A successful listing means `s3.json` is not being read and
the gateway is in allow-all mode.

---

## 6. Restore etcd from a snapshot

Before restoring, confirm etcd is actually the problem — most etcd
incidents are fixed by something cheaper than a restore.

    kubectl -n kube-system exec etcd-k8s-cp-1.rookery.internal -- etcdctl \
      --cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
      --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
      --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key \
      alarm list

    (same command, ending in:  endpoint status --cluster -w table)

Empty alarm list, three members, matching raft indexes = etcd is fine and
the problem is elsewhere.

If the API is down and you can't exec:
    sudo journalctl -u rke2-server --no-pager | grep -iE 'etcd|alarm|leader'

NOT a restore:
	etcdserver: request timed out / no leader     quorum lost; it recovers when
	                                              members return
	mvcc: database space exceeded / alarm:NOSPACE read-only; compact, defrag,
	                                              disarm the alarm
	apply entries took too long, leader flapping  disk latency, not data loss

IS a restore:
	alarm:CORRUPT / etcdserver: corrupt cluster
	wal: crc mismatch or bbolt panic on all three members
	Nothing is broken and something is simply gone — a deleted namespace, an
	over-eager prune. No alert fires for this one. It is the most likely reason
	you are reading this page.

/healthz returns 401, not ok. CIS profile disables anonymous auth. A monitor
that expects "ok" reports the cluster down when it's healthy, and keeps
reporting 401 when it genuinely is down.

Begin the restore:

make sure it's still possible to ssh as rocky to all three control planes.

in terminal (don't forget to double check the session has loaded all of the environment settings)
	set -a; source ~/.config/homelab/env; set +a
	ssh rocky@k8s-cp-1.rookery.internal
	ssh rocky@k8s-cp-2.rookery.internal
	ssh rocky@k8s-cp-3.rookery.internal

locate the snapshots. On workstation:

	set -a; source ~/.config/homelab/env; set +a
	aws --profile rookery-rke2 s3 ls s3://etcd-snapshots/

run through restore:
run commands on cp-2 then cp-3 and lastly cp-1 so that failovers end up where we expect
During testing attempted to stop the rke2 server with systemctl but found this didn't kill all the static pods. used /usr/bin/rke2-killall.sh instead to kill them fully. verify with ps -ef:

	sudo systemctl is-active rke2-server
	sudo /usr/bin/rke2-killall.sh
	sudo ps -ef | grep -E 'kube-apiserver|etcd ' | grep -v grep

I also hit an issue that killall orphans the VIP so double check the status of the VIP here:

On the workstation loop through the cp's to verify where the VIP is showing up.

	held=0
	for h in k8s-cp-1 k8s-cp-2 k8s-cp-3; do
	if ssh -n -o WarnWeakCrypto=no rocky@$h 'ip -4 -o addr show dev eth0' \
	| grep -q '192.168.1.201'; then
	echo "$h  VIP held"; held=$((held+1))
	else
	echo "$h  clear"
	fi
	done
	echo "holders: $held"

| When                                        | Expected                  | If it's wrong                                        |
|---------------------------------------------|---------------------------|------------------------------------------------------|
| After killall, before any server is started | **0**                     | Orphan. Delete it wherever it appears in "ip del" command |
| After cp-1 is up, before starting the peers | **1**, and it must be cp-1 | More than one is a split VIP. Stop and look.         |
| Normal running                              | **1**                     | 0 means kube-vip is not running anywhere.            |

Per above, if any are orphaned delete them:

	sudo ip addr del 192.168.1.201/32 dev eth0
	ip -4 -br addr show eth0

once they are down, kubectl should fail at this time from our workstation. via ssh go ahead with the restore on cp-1. remember to use tmux for this. a broken ssh session here would suck.

	tmux new -s restore

	sudo /usr/bin/rke2 server \
	--cluster-reset \
	--cluster-reset-restore-path=<snapshot filename only> \
	2>&1 | tee /tmp/restore.log

On cp-1:

	sudo systemctl start rke2-server
	sudo systemctl is-active rke2-server

	sudo /var/lib/rancher/rke2/bin/kubectl \
	--kubeconfig /etc/rancher/rke2/rke2.yaml get nodes
	sudo /var/lib/rancher/rke2/bin/kubectl \
	--kubeconfig /etc/rancher/rke2/rke2.yaml get ns restore-drill
	sudo /var/lib/rancher/rke2/bin/kubectl \
	--kubeconfig /etc/rancher/rke2/rke2.yaml -n restore-drill get cm drill -o yaml
	(this last command should be replaced with a search for something we knew was lost and went through this whole endeavor to recover. restore-drill is the place holder I used in the testing)

We want this to return cp-1 as ready and cp-2 and cp-3 as Not Ready. Due to the restore they will show their status from the snapshot for a minute or so. If all three show Ready here, give it a minute and check again to make sure it's a real issue and not just old data.

If everything is good we restart cp-2:

On cp-2 double check configuration is clean:
	ip -4 -o addr show dev eth0 | grep 192.168.1.201
	curl -sSk -o /dev/null -w 'cacerts %{http_code}\n' https://192.168.1.201:9345/cacerts

Expect no output from the first and cacerts 200 from the second. Otherwise the restart we are doing next will result in flapping. Go back up to the orphans checks and verify we didn't overlook anything and make our way back here. If the above looks good continue on to restarting cp-2..

	sudo mv /var/lib/rancher/rke2/server/db /var/lib/rancher/rke2/server/db-old
	sudo systemctl start rke2-server

Check health of cp-2 from cp-1:

	sudo /var/lib/rancher/rke2/bin/kubectl \
	--kubeconfig /etc/rancher/rke2/rke2.yaml get nodes

Once cp-2 is healthy repeat the restart checks and procedures on cp-3.

Once all three are back up test kubectl from workstation.

On Workstation:

	kubectl -n kube-system exec etcd-k8s-cp-1.rookery.internal -- etcdctl \
	  --cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
	  --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
	  --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key \
	  member list -w table

	kubectl get pods -A | grep -vE 'Running|Completed'
	flux get kustomizations

Validate everything looks good and we should be done.

---

## 7. Full rebuild from nothing

*To be written in Phase 8, after the destroy-and-rebuild exercise, with the
wall-clock time it actually took.*
