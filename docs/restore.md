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
echo "Paste the Dropbox backup passphrase, then press Enter:"
read -rs PASSPHRASE
echo

printf '%s' "$PASSPHRASE" | age -d -i - ~/Downloads/age.agekey.age > age.agekey 2>/dev/null \
  || age -d ~/Downloads/age.agekey.age > age.agekey   # falls back to an interactive prompt

chmod 600 age.agekey
unset PASSPHRASE
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

*To be written in Phase 8, after the first successful restore drill. Do not
write it from the documentation — write it from what you actually did.*

---

## 7. Full rebuild from nothing

*To be written in Phase 8, after the destroy-and-rebuild exercise, with the
wall-clock time it actually took.*
