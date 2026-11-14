# Phase 1: Foundation

Goal: four Ubuntu VMs on an isolated network, reachable by SSH, ready for Ansible and k3s.

## Progress
- [x] Isolated host-only network (VMnet2, `192.168.100.0/24`, DHCP off)
- [x] Template VM: Ubuntu Server 26.04.1 LTS, updated, root disk extended, snapshot
- [x] 4 full clones, each with a unique hostname, machine-id, SSH host keys and static IP
- [x] `labcheck.py` confirms 4/4 nodes reachable (ping + SSH)
- [x] SSH key login, password login disabled
- [x] Ansible inventory, run from `obs` as the management host ([evidence](images/ansible-ping.png))
- [x] k3s installed, `kubectl get nodes` shows 3 nodes `Ready` (**Phase 1 complete, 2026-11-14**)

## Decisions
| Decision | Why |
|---|---|
| Ubuntu **Server** (not minimized, not desktop) | No GUI wasting RAM; minimized drops tools needed while learning |
| One template, then **full clones** | Faster than 4 installs, every node starts identical; full clones don't depend on the template |
| Two NICs per VM: NAT + host-only | NAT only for updates; cluster traffic stays on the isolated network |
| Static IPs, DHCP off on the lab network | Ansible and Kubernetes need fixed, predictable addresses |
| No disk encryption (LUKS) | Would need a passphrase typed at every boot and all clones would share the key. In a real cloud this is the provider's KMS |
| k3s before kubeadm | Lighter and quicker to get running; kubeadm rebuild is a stretch goal |

## Per-clone setup
A clone is an exact copy, so it starts with the template's identity. On each node:
```bash
sudo hostnamectl set-hostname <name>                     # new hostname
sudo sed -i 's/k8s-template/<name>/g' /etc/hosts         # fix local name lookup
sudo rm /etc/machine-id
sudo systemd-machine-id-setup                            # new machine-id
sudo rm /etc/ssh/ssh_host_*
sudo dpkg-reconfigure openssh-server                     # new SSH host keys
sudo sed -i '/match:/d;/macaddress:/d;/set-name:/d' /etc/netplan/00-installer-config.yaml
# then create /etc/netplan/60-lab.yaml (see configs/netplan/), chmod 600, netplan apply
```

## SSH: key-only access
1. Dedicated ed25519 key for the lab (`~/.ssh/k8s-lab`, passphrase-protected, loaded with `ssh-agent`), kept separate from my GitHub key so one leak doesn't expose both.
2. Public key copied to `~/.ssh/authorized_keys` on each node (permissions 700/600; SSH ignores keys in files others can read).
3. Host aliases in `~/.ssh/config` so `ssh k8s-cp` just works: see [configs/ssh/client-config.example](../configs/ssh/client-config.example).
4. Password and root login switched off with [configs/ssh/10-hardening.conf](../configs/ssh/10-hardening.conf), checked with `sshd -t` before reloading.

**Evidence: each node has its own host key** (the regenerated keys from the per-clone setup):

![Four different ED25519 fingerprints on first connection](images/ssh-unique-host-keys.png)

**Evidence: password login is refused, key login works:**

![Password attempt denied with "Permission denied (publickey)", key login prints the hostname](images/ssh-password-denied.png)

Gotcha: Ubuntu's installer writes `/etc/ssh/sshd_config.d/50-cloud-init.conf` with `PasswordAuthentication yes`. sshd keeps the **first** value it reads, in alphabetical file order, so the hardening file is named `10-` to win. Putting `no` in a later file would leave passwords silently enabled.

## Ansible: one place to manage the lab
- Ansible runs on **obs**, the management host. Windows can't run Ansible, and this keeps the Windows host unchanged.
- **Agent forwarding** to obs only: obs signs logins to the other nodes using the key held by my PC's ssh-agent, so the private key is never copied to obs. Trade-off: while I'm connected, root on obs could use the forwarded agent, so forwarding is enabled for that one host and nowhere else.
- obs learned the nodes' host keys with `ssh-keyscan`, then I **compared the fingerprints** with the ones my PC saw on first connection before trusting them (trust-on-first-use, checked).
- `host_key_checking = True` in [ansible.cfg](../ansible/ansible.cfg): Ansible refuses a node whose identity changes.
- Workflow: edit on the PC → `git push` → `git pull` on obs → run. obs never holds GitHub credentials.

![ansible all -m ping: all four hosts reply pong](images/ansible-ping.png)

## k3s: the cluster
Installed by [ansible/k3s.yml](../ansible/k3s.yml): server on `k8s-cp`, agents on `k8s-w1` and `k8s-w2`, k3s **v1.37.2+k3s1** (pinned in [group_vars/all.yml](../ansible/group_vars/all.yml) so a rebuild gives the same cluster).

| Choice | Why |
|---|---|
| `--node-ip` + `--flannel-iface ens37` | Each VM has two NICs. Without these, k3s would pick the NAT adapter and send cluster traffic over it. These keep it on the isolated lab network |
| Installer downloaded to a file, not `curl \| sh` | The script can be inspected before it runs |
| Join token read with `no_log: true`, held in memory only | The token lets any machine join the cluster, so it never appears in output or in the repo (`.gitignore` also blocks `node-token`) |
| `--write-kubeconfig-mode 0600` | The cluster-admin credentials file is root-only |
| `creates:` on install tasks | Idempotent: running the playbook again skips work already done |

![PLAY RECAP: failed=0 on all three nodes](images/k3s-play-recap.png)

![kubectl get nodes -o wide: 3 nodes Ready, internal IPs on 192.168.100.0/24](images/k3s-get-nodes.png)

All three nodes are `Ready`, and the **INTERNAL-IP** column shows `192.168.100.x`, which proves cluster traffic uses the lab network and not NAT.

## Problems and fixes
| Problem | Cause | Fix |
|---|---|---|
| Root filesystem only 14 GB on a 30 GB disk | Ubuntu's default LVM layout leaves half the volume group unused | `lvextend -l +100%FREE` on the logical volume, then `resize2fs` to grow ext4 live |
| `netplan apply`: "Cannot find unique matching interface for ens33" | Installer pinned the NAT adapter to the template's MAC address; clones get new MACs | Delete the `match` / `macaddress` / `set-name` lines so the adapter is matched by name |
| `netplan apply`: "Invalid YAML: inconsistent indentation" | A half-run `sed` left an orphan `macaddress:` line | Delete the leftover line |
| One worker unreachable from the host | Typo put it on `192.168.11.12` (wrong subnet) | Found with `ip -br a`; `arp -a` on the host showed the others had distinct MACs (no duplicate IPs); fixed the address |
| NAT adapter briefly had no IPv4 after `netplan apply` | DHCP lease not yet renewed | Reboot (or wait) |
| Ansible: "Timeout (12s) waiting for privilege escalation prompt" | Ubuntu 25.10+ ships **sudo-rs** as `sudo`; Ansible's become doesn't recognise its password prompt | `become_exe = sudo.ws` in [ansible.cfg](../ansible/ansible.cfg) (classic sudo, still installed); tested with `ansible k8s_cluster -b -K -a whoami` → `root` before re-running the playbook |
