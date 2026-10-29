# Host the app on AWS in a VPC: public nginx + two private app servers

Commands below are for **Amazon Linux 2023** (login `ec2-user`).

**nginx is installed directly on its EC2 instance (no Docker there).** Only the two
private servers use Docker, for the backend and MongoDB.

## What you will build

```
                                Internet
                                   │ port 80
                           ┌───────▼────────┐
                           │ Internet       │
                           │ Gateway        │
┌──────────────────────────┴───────┬────────┴─────────────────────────────────┐
│ VPC 10.0.0.0/16                  │                                          │
│                                  │                                          │
│  PUBLIC SUBNET                   │                                          │
│  ┌──────────────────────┐        │     ┌──────────────┐                     │
│  │ EC2 "nginx"          │        │     │ NAT Gateway  │◄── lets the private │
│  │ Elastic IP, port 80  │        │     └──────▲───────┘    servers download │
│  │ nginx installed on   │        │            │            Docker images    │
│  │ the server (no       │        │            │            (outbound only)  │
│  │ Docker): frontend,   │        │            │                             │
│  │ load balancer, proxy │        │            │                             │
│  └───────┬──────┬───────┘                     │                             │
│          │ 3000 │ 3000                        │                             │
│  ────────┼──────┼─────────────────────────────┼───────────────────────────  │
│  PRIVATE SUBNET (no public IPs)               │                             │
│  ┌───────▼──────┴───────┐   ┌─────────────────┴────┐                        │
│  │ EC2 "private1"       │   │ EC2 "private2"       │                        │
│  │ app copy #1          │   │ app copy #2          │                        │
│  │ MongoDB ◄────────────┼───┼── port 27017         │                        │
│  └──────────────────────┘   └──────────────────────┘                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

- The **only** server reachable from the internet is `nginx`, in the public subnet. It
  serves the frontend and load-balances `/api` and `/health` between the two private
  servers, taking turns. If one is down it uses the other.
- `private1` and `private2` each run a copy of the backend. They have **no public IP**, so
  nobody on the internet can reach them or the database.
- MongoDB runs on `private1` (two independent databases would hold different data, so
  there is exactly one). Both backends use it.
- The **NAT Gateway** is a one-way door: the private servers can download things
  (Docker images, packages), but nothing can connect in through it.
- To log in to the private servers you jump through `nginx` (Part C).

**Know the limits:** the backend is redundant, but nginx and MongoDB are single
instances, and everything is in one availability zone. If `nginx` or `private1` goes
down, the site is down.

**Cost warning:** the NAT Gateway is billed per hour (roughly 30+ USD a month) plus data,
and is **not** covered by the free tier. The three servers, the Elastic IP and the disks
add to that. Do "Clean up" at the end when you stop using it.

---

## Part A: prepare (on your own computer)

Skip what you already did.

1. Make your repo match this delivery. Copy the project files over, then remove the
   files AWS does not use. They are still in git until you remove them:
   ```bash
   git rm -q --ignore-unmatch docker-compose.yaml .env.example frontend/Dockerfile frontend/nginx.conf junit.xml
   git rm -r -q --ignore-unmatch coverage deploy/node1 deploy/node2
   ```
   The `deploy/` folder must be the one from this delivery. `deploy/nginx` is an install
   script, not Docker. There must be no `eslint.config.mjs`, `tls.crt` or `tls.key` in the repo.
2. `git rm --cached .env` (if `.env` is still tracked), then commit and push to `dev`.
3. Run the Jenkins pipeline once so the backend image is on Docker Hub:
   `mohamedhafour/user-profile-app:latest`. Only the backend is an image now: nginx on
   the public server serves the files in `frontend/public` straight from the repo.
   If the repository is private, also run `docker login` on both private servers in Part C.
4. **If you created the earlier two-server test** (servers `server1`/`server2`, the
   `sg-profile` group, an Elastic IP), delete it so you stop paying for it: terminate
   the instances, release the Elastic IP, delete the security group.

## Part B: build the network and servers in the AWS console

**B1. Region.** Sign in at https://console.aws.amazon.com and use the same region for
everything (top-right corner), e.g. Europe (Frankfurt).

**B2. Create the VPC (one wizard does the networking).**
Open the **VPC** service → **Create VPC** → choose **VPC and more**. Set:

| Setting | Value |
|---|---|
| Name tag prefix | `profile` |
| IPv4 CIDR block | `10.0.0.0/16` |
| Number of Availability Zones | **1** |
| Number of public subnets | **1** |
| Number of private subnets | **1** |
| NAT gateways | **In 1 AZ** |
| VPC endpoints | None |
| DNS options | leave both enabled |

Click **Create VPC** and wait until every step shows done (the NAT gateway takes a few
minutes). The wizard creates for you: the VPC, a public and a private subnet, an Internet
Gateway, the NAT Gateway (with its Elastic IP), and the two route tables (public →
Internet Gateway, private → NAT Gateway).

Open **Subnets** and note the **IPv4 CIDR** of the public and private subnet (the private
one looks like `10.0.128.0/20`). Your servers' private IPs will come from these ranges.

**B3. Security groups (firewalls).** EC2 → Security Groups → Create. **Choose the new
VPC (`profile-vpc`)**, not the default one. Make two:

`sg-nginx`

| Type | Port | Source |
|---|---|---|
| HTTP | 80 | Anywhere-IPv4 |
| SSH | 22 | My IP |

`sg-private`

| Type | Port | Source |
|---|---|---|
| Custom TCP | 3000 | `sg-nginx` (type `sg-` and pick it) |
| SSH | 22 | `sg-nginx` |

Then open `sg-private` again → **Edit inbound rules** → **Add rule**:
Custom TCP, port **27017**, source **`sg-private`** (itself; the group must exist
first). Save.

What this enforces: the internet reaches only port 80 on `nginx`; only `nginx` reaches
the apps (3000); only the private servers reach the database (27017).

**B4. SSH key.** EC2 → Key Pairs. Reuse `profile-key` if you already have it, or create it
(RSA, `.pem`; it downloads once) and run `chmod 400 ~/Downloads/profile-key.pem`.

**B5. Launch the three servers.** EC2 → Instances → Launch instances. For each:
Amazon Linux 2023 AMI · key pair `profile-key` · Network settings → **Edit**.

| Name | Type | VPC / Subnet | Auto-assign public IP | Security group | Disk |
|---|---|---|---|---|---|
| `nginx` | t3.micro | profile-vpc / **public** subnet | **Enable** | `sg-nginx` | 8 GiB |
| `private1` | t3.small | profile-vpc / **private** subnet | **Disable** | `sg-private` | 20 GiB |
| `private2` | t3.micro | profile-vpc / **private** subnet | **Disable** | `sg-private` | 8 GiB |

(The subnet dropdown shows names like `profile-subnet-public1-…` and
`profile-subnet-private1-…`. For *Select existing security group* pick the one you made
for that server.)

**B6. Permanent address for nginx.** EC2 → Elastic IPs → Allocate Elastic IP address →
Allocate. Select it → Actions → Associate Elastic IP address → instance `nginx`.
This is the address of your site.

**B7. Write down the private IPs** (Instances → click one → Details → Private IPv4 address):

```
nginx    Elastic IP (your site) : ____________
private1 private IP (PRIVATE1_IP): ____________
private2 private IP (PRIVATE2_IP): ____________
```

## Part C: set up the servers

### C1. How to log in to the private servers (jump through nginx)

The private servers have no public address, so you reach them through `nginx`. On your
computer:

```bash
ssh-add ~/Downloads/profile-key.pem        # loads the key once per session
ssh -A ec2-user@<nginx Elastic IP>         # nginx server (fine for the first checks)

# private servers, in a second terminal on your computer:
ssh -J ec2-user@<nginx Elastic IP> ec2-user@<PRIVATE1_IP>
ssh -J ec2-user@<nginx Elastic IP> ec2-user@<PRIVATE2_IP>
```

If `ssh-add` says it cannot connect to an agent, run `eval "$(ssh-agent -s)"` first.
The first connection to each server asks "Are you sure…?": answer `yes`.

### C2. On the two PRIVATE servers (`private1`, `private2`): install Docker and get the code

(The nginx server does not need Docker; it is set up in C5.)

```bash
sudo dnf install -y docker git
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user

# Docker Compose is not in Amazon Linux's repositories: install the plugin by hand
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
exit
```

Log in again (the group change needs a new login), then:

```bash
docker run --rm hello-world        # "Hello from Docker!"  (proves the server can download images)
docker compose version
git clone -b dev https://github.com/M1Hafour/-user-profile.git ~/app
# only if your Docker Hub repository is private:  docker login
```

These downloads work only through the NAT Gateway. If they hang or time out, see
Troubleshooting.

### C3. `private1`: database + app copy #1

```bash
cd ~/app/deploy/private1
cp .env.example .env
nano .env
```

Set `PRIVATE1_IP` and `PRIVATE2_IP` to the IPs from B7 and choose a **long random
`MONGO_PASSWORD`** (not `password`). Save: Ctrl+O, Enter, Ctrl+X. Then:

```bash
docker compose up -d
docker compose ps
```

After a minute `mongodb` and `app` should both say **healthy**.

### C4. `private2`: app copy #2

```bash
cd ~/app/deploy/private2
cp .env.example .env
nano .env          # EXACTLY the same five values as on private1
docker compose up -d
docker compose ps  # healthy after about a minute
```

### C5. `nginx`: install nginx directly on the public server

Log in to the nginx server (`ssh ec2-user@<nginx Elastic IP>`), then:

```bash
sudo dnf install -y git
git clone -b dev https://github.com/M1Hafour/-user-profile.git ~/app
cd ~/app/deploy/nginx
cp .env.example .env
nano .env          # PRIVATE1_IP and PRIVATE2_IP (the two private servers)
./install.sh
```

`install.sh` does everything: installs nginx with `dnf`, copies the frontend files to
`/var/www/user-profile`, writes `/etc/nginx/nginx.conf` with your two private IPs,
checks it with `nginx -t` (and puts the old file back if the check fails), then starts
nginx and makes it start automatically after a reboot. It asks for `sudo` by itself.
You can run it again at any time. Check it:

```bash
curl -s http://localhost/nginx-health      # prints: ok
sudo systemctl status nginx                # active (running)
```

## Part D: test it

1. Open **`http://<nginx Elastic IP>`** in your browser (use `http://`, there is no HTTPS
   yet). You should see the app. Add a user, reload: it is still there.
2. See the balancing. On `nginx`:
   ```bash
   sudo tail -n 20 /var/log/nginx/access.log
   ```
   Reload the page a few times. Lines end with `upstream=<PRIVATE1_IP>:3000` or
   `upstream=<PRIVATE2_IP>:3000`: both appear.
3. Prove they are private: from your computer, `ssh ec2-user@<PRIVATE1_IP>` (without the
   jump) cannot connect, and neither can anything else on those IPs.
4. Prove the failover: on `private2` run `docker stop user-profile-app`. The site keeps
   working, served by `private1`. Start it again with `docker start user-profile-app`.
   Then do the same on `private1` (stop only the **app** container, not `mongodb`).

## Part E: day-to-day

**Nightly database backup** (on `private1`; keeps 7 days in `~/backups`):

```bash
sudo dnf install -y cronie && sudo systemctl enable --now crond
crontab -e         # add this line at the bottom:
0 2 * * * /home/ec2-user/app/deploy/private1/backup.sh >> /home/ec2-user/backup.log 2>&1
```
Test once: `~/app/deploy/private1/backup.sh` prints "Backup written: …". The backups are on
the same server, so also snapshot its disk: EC2 → Volumes → select the 20 GiB volume →
Actions → Create snapshot.

**Deploy a new version.** Normally you do nothing: push to GitHub and run the Jenkins
pipeline (Part F). By hand, one private server at a time so the site stays up (use a tag
Jenkins pushed, or `latest`):

```bash
# on private2, then on private1
cd ~/app && git pull && ./deploy/update-private.sh private2 <tag>     # private1 on the other server

# on the nginx server (frontend files, config template or private IPs changed)
cd ~/app && git pull && ./deploy/nginx/install.sh
```

`update-private.sh` pins the image tag in that server's `.env`, pulls it, restarts the
app and waits until it is healthy. If it is not healthy it puts the previous tag back
automatically and exits with an error. The frontend is served from the repo's
`frontend/public` (not from a Docker image), so refresh the browser with Ctrl+F5 after
a frontend change. If `git pull` complains about a detached HEAD or local changes, run
`git checkout dev && git reset --hard origin/dev` first (the pipeline moves the servers to
the exact commit it built).

**Roll back to an older version:** run `update-private.sh` with the older tag on each
private server, e.g. `~/app/deploy/update-private.sh private2 a1b2c3d`. The tags are the
7-character commit ids in the Jenkins log and on Docker Hub.

**Restore a backup** (on `private1`):
```bash
gunzip -c ~/backups/mongo-YYYY-MM-DD-HHMM.archive.gz | docker exec -i mongodb sh -c 'mongorestore -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --archive --drop'
```

## Part F: let Jenkins deploy it (on your own machine)

The pipeline (`Jenkinsfile`) builds, tests, scans and pushes as before. Its last two
stages now deploy to AWS: **Deploy to AWS** and **Verify Deployment**. Jenkins stays on
your machine. It connects over SSH to the nginx server and, through it, to the private
servers. The database password never goes through Jenkins: it only lives in the `.env`
files on the servers.

**What the deploy stage does, in order:**
1. Checks that it can log in to all three servers. If not, it stops before changing anything.
2. On each server, moves `~/app` to the exact commit Jenkins built (`git reset --hard`;
   your `.env` files are not in git, so they are kept).
3. `private2`: runs `update-private.sh` (new image, restart, wait until healthy, roll back
   by itself if unhealthy). Then `private1` the same way. While one restarts, nginx uses
   the other.
4. The nginx server: runs `install.sh` (new frontend files, config check, reload).
5. **Verify Deployment** opens `http://<Elastic IP>/` and `/health` from Jenkins and
   checks the page and the database connection. A failure fails the build (and Slack tells you).

**One-time setup:**

1. **SSH key in Jenkins.** Manage Jenkins → Credentials → (global) → Add Credentials:
   Kind **SSH Username with private key**, ID **`aws-ssh-key`**, Username **`ec2-user`**,
   Private Key → *Enter directly* → paste the whole content of `profile-key.pem`
   (from `-----BEGIN` to `-----END`). Save.
2. **Fill in the three addresses** at the top of the `Jenkinsfile` (they replace
   `CHANGE_ME`; these are addresses, not secrets) and push:
   ```groovy
   AWS_NGINX_HOST  = '<nginx Elastic IP>'
   AWS_PRIVATE1_IP = '<private1 private IP>'
   AWS_PRIVATE2_IP = '<private2 private IP>'
   ```
3. **Let your machine reach the nginx server.** `sg-nginx` allows SSH (22) only from "My
   IP". Jenkins runs on your machine, so that rule must contain your **current public IP**.
   If your home IP changes, builds fail at "Checking SSH access" with a timeout: edit the
   SSH rule again.
4. **The servers need the repo and their `.env` files** (Part C), cloned to `~/app` with
   `git clone -b dev …`. Run the first deploy of each server by hand (Part C) before using
   the pipeline. The pipeline only updates what already runs.
5. **Your Jenkins machine needs** an `ssh` client and `curl` (a normal Linux machine has both).
6. Optional clean-up in Jenkins: the credentials `mongo-creds` and `user-profile-app-env`
   are no longer used by the pipeline and can be deleted.

**Good to know:**
- The first connection to each server is trusted automatically and remembered in
  `aws_known_hosts` in `JENKINS_HOME`. If you rebuild a server (new host key), delete its
  line from that file, otherwise Jenkins refuses to connect (this protects against impostors).
- The pipeline deploys the commit it built, so your branch must be pushed to GitHub
  before you run it.
- The pipeline builds, scans and pushes only the **backend image**. There is no frontend
  image: nginx serves `frontend/public` from the repo.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Browser cannot connect | You used the **Elastic IP** and `http://`. `sg-nginx` allows HTTP 80 from Anywhere. The server is in the **public** subnet with a public IP. On it: `sudo systemctl status nginx` and `curl -s http://localhost/nginx-health`. |
| **502 Bad Gateway** | Both apps are unreachable. On each private server `docker compose ps`; on the nginx server `sudo tail /var/log/nginx/error.log` shows which upstream failed. Check the IPs in `deploy/nginx/.env` are the **private** IPs, run `./install.sh` again after fixing, and check `sg-private` allows 3000 from `sg-nginx`. |
| `./install.sh` stops with an ERROR | It prints the reason: a missing `.env`, an IP that is not a valid address, or an nginx syntax error (the previous config is restored automatically). |
| 502 and the error log says `Permission denied` for the upstream | SELinux is in enforcing mode. Allow nginx to connect out: `sudo setsebool -P httpd_can_network_connect 1`. (Amazon Linux 2023 normally ships with it permissive.) |
| Page shows nginx's default welcome page | The config was not installed. Run `./install.sh` and read its output; `sudo nginx -T \| head` shows what nginx actually loaded. |
| Private server: `docker pull` / `dnf` hangs or times out | No outbound route. VPC → Route tables: the **private** route table needs `0.0.0.0/0 → nat-…` and must be associated with the private subnet. VPC → NAT gateways: state must be **Available**. The NAT must sit in the **public** subnet. |
| `ssh -J …` says permission denied | `ssh-add -l` must list your key. The `sg-private` rule for SSH must have source `sg-nginx`. |
| App on `private2` never gets healthy | `docker logs user-profile-app`. Wrong password or `PRIVATE1_IP`, or the `sg-private` self-rule for 27017 is missing. MongoDB keeps the password from its **first** start; changing `.env` later does not change it. |
| Only one server ever answers | The IP of the other server in `deploy/nginx/.env` is wrong, or its app is not healthy, or `sg-private` lacks the 3000 rule. Fix, then run `./install.sh` again on the nginx server. |
| Build fails at "Set AWS_… at the top of the Jenkinsfile" | The three `CHANGE_ME` values were not replaced (Part F, step 2). |
| Build fails at "Checking SSH access" with *timed out* | Your public IP changed: update the SSH rule in `sg-nginx` (Part F, step 3). |
| Build fails with *Host key verification failed* or *REMOTE HOST IDENTIFICATION HAS CHANGED* | A server was rebuilt. Remove its line from `aws_known_hosts` in `JENKINS_HOME`. |
| Build fails with *Permission denied (publickey)* | The Jenkins credential `aws-ssh-key` has the wrong key or username (must be `ec2-user`). |
| `update-private.sh` says it rolled back | The new image did not become healthy. The log shows the app's last lines. The old version is running again; fix the problem and run the build again. |
| `git reset --hard` / `git fetch` fails on a server | The server cannot reach GitHub (check the NAT Gateway for the private ones), or the commit was never pushed. |
| SSH to `nginx` times out | Your home IP changed. Edit the SSH rule in `sg-nginx` and set "My IP" again. |

## Clean up (to stop paying)

Order matters:

1. EC2 → Instances → terminate `nginx`, `private1`, `private2`.
2. VPC → **NAT gateways** → delete the NAT gateway (wait until it is *Deleted*).
3. EC2 → **Elastic IPs** → release **both** addresses: the one on `nginx` and the NAT
   gateway's (an unattached one is still billed).
4. VPC → Your VPCs → select `profile-vpc` → Actions → **Delete VPC** (this also removes the
   subnets, route tables and Internet Gateway).
5. EC2 → Volumes and Snapshots: delete any left over.

If you only want to pause: deleting just the NAT gateway saves most of the cost, but then
the private servers cannot download images until you create a new one and point the
private route table's `0.0.0.0/0` at it.

## Security notes

- Only port 80 on `nginx` is open to the internet. The backends and the database have no
  public IP; the security groups allow only the traffic shown in the diagram.
- This setup is **HTTP only**: data between the browser and the site is not encrypted. A
  trusted HTTPS certificate needs a domain name (a free DuckDNS name plus Let's Encrypt
  works). Ask for it as the next step.
- Mongo Express is deliberately not deployed (it has no login).
- Not included: automatic deploys from Jenkins, off-server backups, monitoring. A billing
  alarm (Billing → Budgets) is a good first addition, especially with a NAT Gateway.
