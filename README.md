# User Profile App — Node.js + Express + MongoDB + Mongo Express

A simple user-profile app: a plain HTML/CSS/JS frontend talking to an
Express REST API, backed by MongoDB. **Mongo Express** is included as a
web-based admin UI for the database — same setup style as
[nanuchi/developing-with-docker](https://gitlab.com/nanuchi/developing-with-docker).

## Stack

- **Frontend** — plain `index.html` + `script.js` + `style.css` in `frontend/public/` (no framework, no build step), served over HTTPS by **nginx** from its own image
- **Backend** — Express REST API only (`server.js` / `app.js`); nginx forwards `/api/*` and `/health` to it
- **Database** — MongoDB via Mongoose
- **Admin UI** — Mongo Express, a web GUI for browsing/editing the database

## Option A — Docker Compose (recommended)

Starts the app, MongoDB, and Mongo Express together.

1. **Configure environment variables**
   ```bash
   cp .env.example .env
   ```
   The defaults (`admin` / `password`) are fine for local development —
   change them if you like.

2. **Build the two app images, then start everything.** `docker-compose.yaml`
   runs prebuilt images (the Jenkins pipeline builds and pushes them), so
   locally build them under the same names first:
   ```bash
   docker build -t docker.io/mohamedhafour/user-profile-app:latest .
   docker build -t docker.io/mohamedhafour/user-profile-frontend:latest ./frontend
   docker compose up
   ```

3. **Open the app**: https://localhost (nginx; http://localhost redirects there).
   The default certificate is self-signed, so your browser will show a warning
   the first time — see [HTTPS](#https) below. Set `NGINX_PORT` /
   `NGINX_HTTPS_PORT` in `.env` to use other ports than 80 / 443.
   Add a user through the form — it's saved straight to MongoDB.

4. **Open Mongo Express** (DB admin UI): http://localhost:8081
   You'll see the `my-db` database and `users` collection appear once you've
   added at least one user from the app (Mongoose creates them on first
   insert — no manual setup needed, unlike the raw `docker run` workflow
   below).

5. **Stop it**
   ```bash
   docker compose down
   ```
   Add `-v` to also wipe the MongoDB data volume.

## Option B — Manual `docker run` (no Compose)

Useful for understanding what Compose is doing under the hood.

1. **Create a shared network** so the containers can find each other by name:
   ```bash
   docker network create mongo-network
   ```

2. **Start MongoDB:**
   ```bash
   docker run -d -p 27017:27017 \
     -e MONGO_INITDB_ROOT_USERNAME=admin \
     -e MONGO_INITDB_ROOT_PASSWORD=password \
     --name mongodb --net mongo-network mongo
   ```

3. **Start Mongo Express:**
   ```bash
   docker run -d -p 8081:8081 \
     -e ME_CONFIG_MONGODB_ADMINUSERNAME=admin \
     -e ME_CONFIG_MONGODB_ADMINPASSWORD=password \
     -e ME_CONFIG_MONGODB_SERVER=mongodb \
     --net mongo-network --name mongo-express mongo-express
   ```

4. **Build the app image:**
   ```bash
   docker build -t user-profile-app:1.0 .
   ```

5. **Run the app**, connected to the same network:
   ```bash
   docker run -d -p 3000:3000 \
     -e MONGO_USERNAME=admin \
     -e MONGO_PASSWORD=password \
     -e MONGO_HOSTNAME=mongodb \
     -e MONGO_PORT=27017 \
     -e MONGO_DB=my-db \
     --net mongo-network --network-alias app --name user-profile-app user-profile-app:1.0
   ```
   The `app` network alias is the hostname the frontend's nginx proxies to.
   The backend serves only the API (try http://localhost:3000/api/users).

6. **Build and run the frontend** (nginx serving the UI, proxying to `app`):
   ```bash
   docker build -t user-profile-frontend:1.0 ./frontend
   docker run -d -p 80:80 -p 443:443 -v nginx-certs:/etc/nginx/certs \
     --net mongo-network --name frontend user-profile-frontend:1.0
   ```

7. Visit https://localhost for the app (accept the self-signed certificate
   warning) and http://localhost:8081 for Mongo Express.

## Option C — Run the app locally, DB in Docker

1. Start just MongoDB and Mongo Express (steps 1–3 of Option B, or
   `docker compose up mongodb mongo-express`).
2. Install dependencies and run the app on your host machine:
   ```bash
   npm install
   MONGO_USERNAME=admin MONGO_PASSWORD=password MONGO_HOSTNAME=localhost \
   MONGO_PORT=27017 MONGO_DB=my-db node server.js
   ```
   This runs the API only (http://localhost:3000/api/users). The UI is served
   by nginx, so use Option A or B to see it.

## HTTPS

nginx terminates TLS: port 80 redirects to HTTPS (port 443).

- **Default: a self-signed certificate.** On first start the frontend container
  creates one for `localhost`, `127.0.0.1` and `::1` and keeps it in the
  `nginx-certs` volume (never in the image, so the private key is not pushed to
  Docker Hub). It survives redeploys and is renewed automatically within 30
  days of expiry. Browsers warn about self-signed certificates; that is expected.
  To trust it instead of clicking through, copy it out with
  `docker cp nginx:/etc/nginx/certs/tls.crt .` and import it into your OS or
  browser trust store.
- **Another name or IP** (e.g. opening the app from another machine at
  `https://192.168.1.20`): set `TLS_SAN` in `.env`, for example
  `TLS_SAN=DNS:myserver.local,IP:192.168.1.20`, then make a new certificate:
  ```bash
  docker compose exec nginx rm /etc/nginx/certs/tls.crt /etc/nginx/certs/tls.key
  docker compose up -d --force-recreate nginx
  ```
- **Your own certificate** (mkcert, a company CA, Let's Encrypt): put the full
  chain and the key into the volume and reload nginx. A certificate you add is
  never overwritten.
  ```bash
  docker cp fullchain.pem nginx:/etc/nginx/certs/tls.crt
  docker cp privkey.pem   nginx:/etc/nginx/certs/tls.key
  docker exec nginx nginx -s reload
  ```
  [mkcert](https://github.com/FiloSottile/mkcert) gives a locally trusted
  certificate with no browser warning.
- **Ports:** `NGINX_PORT` (default 80) and `NGINX_HTTPS_PORT` (default 443) in
  `.env`; the HTTP→HTTPS redirect follows the HTTPS port automatically.
- **HSTS is intentionally not enabled.** Browsers apply it to the whole
  hostname regardless of port, so on `localhost` it would force HTTPS on your
  other local services and make a self-signed certificate impossible to
  bypass. Enable it only on a real domain with a trusted certificate.

## API

| Method | Route             | Description          |
|--------|-------------------|-----------------------|
| GET    | `/api/users`      | List all users        |
| POST   | `/api/users`      | Create a user         |
| DELETE | `/api/users/:id`  | Delete a user by id    |
| GET    | `/health`         | Health check (used by container orchestration) |

## Project structure

```
user-profile-app/
├── app.js                 # Express app + REST API (no static files)
├── server.js              # Mongo connection + starts the app
├── models/
│   └── User.js              # Mongoose schema
├── frontend/                # Static frontend, served by nginx over HTTPS
│   ├── Dockerfile             # nginx image: static files + config baked in
│   ├── templates/
│   │   └── default.conf.template   # HTTP→HTTPS redirect, HTTPS site, /api + /health proxy
│   ├── docker-entrypoint.d/
│   │   └── 25-self-signed-cert.sh  # creates a self-signed certificate on first start
│   └── public/
│       ├── index.html
│       ├── style.css
│       └── script.js
├── Dockerfile               # Multi-stage build for the backend (API) image
├── docker-compose.yaml      # nginx (frontend) + app (API) + mongodb + mongo-express
├── .dockerignore
├── .env.example
└── package.json
```
