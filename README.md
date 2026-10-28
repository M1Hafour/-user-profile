# User Profile App — Node.js + Express + MongoDB + Mongo Express

A simple user-profile app: a plain HTML/CSS/JS frontend talking to an
Express REST API, backed by MongoDB. **Mongo Express** is included as a
web-based admin UI for the database — same setup style as
[nanuchi/developing-with-docker](https://gitlab.com/nanuchi/developing-with-docker).

## Stack

- **Frontend** — plain `index.html` + `script.js` + `style.css` in `frontend/public/` (no framework, no build step), served by **nginx** from its own image
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

3. **Open the app**: http://localhost (served by nginx; set `NGINX_PORT` in
   `.env` to use another port than 80).
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
   docker run -d -p 80:80 \
     --net mongo-network --name frontend user-profile-frontend:1.0
   ```

7. Visit http://localhost for the app and http://localhost:8081 for Mongo Express.

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

## Deploy on AWS

`deploy/` contains everything for a two-server setup: nginx as load balancer and
reverse proxy in front of two copies of the API, with MongoDB and backups. Follow
[deploy/AWS-GUIDE.md](deploy/AWS-GUIDE.md) step by step.

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
├── frontend/                # Static frontend, served by nginx
│   ├── Dockerfile             # nginx image: static files + config baked in
│   ├── nginx.conf             # serves the UI, proxies /api + /health to the backend
│   └── public/
│       ├── index.html
│       ├── style.css
│       └── script.js
├── Dockerfile               # Multi-stage build for the backend (API) image
├── docker-compose.yaml      # nginx (frontend) + app (API) + mongodb + mongo-express
├── deploy/                  # AWS: 2 servers, nginx load balancer (see AWS-GUIDE.md)
├── .dockerignore
├── .env.example
└── package.json
```
