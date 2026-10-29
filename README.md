# User Profile App

A small user-profile app: a plain HTML/CSS/JavaScript page, an Express REST API and
MongoDB. It runs on AWS behind an nginx load balancer, and a Jenkins pipeline tests,
scans and deploys it.

## Stack

- **Frontend**: `frontend/public/` (`index.html`, `script.js`, `style.css`). No framework,
  no build step. nginx serves these files.
- **Backend**: Express REST API (`app.js`, `server.js`), packaged as a Docker image by Jenkins.
- **Database**: MongoDB via Mongoose.
- **Load balancer**: nginx, installed directly on a public EC2 instance. It serves the
  page and forwards `/api` and `/health` to two backend servers in a private subnet.

## Run the API locally

You need Node 20 and a MongoDB you can reach. For MongoDB:

```bash
docker run -d -p 27017:27017 -e MONGO_INITDB_ROOT_USERNAME=admin \
  -e MONGO_INITDB_ROOT_PASSWORD=password --name mongodb mongo:7
```

Then start the API:

```bash
npm ci
MONGO_USERNAME=admin MONGO_PASSWORD=password MONGO_HOSTNAME=localhost \
  MONGO_PORT=27017 MONGO_DB=my-db node server.js
```

The API listens on http://localhost:3000 (try http://localhost:3000/api/users).
The web page is served by nginx, so to see it locally put nginx in front of the API the
same way the AWS setup does (`deploy/nginx/nginx.conf.template`).

## Tests and checks

```bash
npm ci
npm test          # Jest + supertest, 10 tests
npx eslint .      # code check
```

## API

| Method | Route            | Description                                    |
|--------|------------------|------------------------------------------------|
| GET    | `/api/users`     | List all users                                 |
| POST   | `/api/users`     | Create a user (`name` and `email` required)    |
| DELETE | `/api/users/:id` | Delete a user by id                            |
| GET    | `/health`        | Health check; reports whether MongoDB is connected |

## Deploy on AWS

The Jenkins pipeline (`Jenkinsfile`) runs the tests, the lint check and the dependency
audit, builds the backend image, scans it with Trivy, pushes it to Docker Hub, and
deploys it over SSH to the AWS servers (rolling update, automatic rollback). It verifies
the public site at the end.

Setup, step by step: [deploy/AWS-GUIDE.md](deploy/AWS-GUIDE.md).

## Project structure

```
user-profile-app/
├── app.js                   # Express app and REST API
├── server.js                # connects to MongoDB and starts the app
├── models/User.js           # Mongoose schema
├── __tests__/users.test.js  # Jest + supertest tests
├── Dockerfile               # backend image (built by Jenkins)
├── Jenkinsfile              # CI/CD pipeline
├── frontend/public/         # the web page, served by nginx
├── deploy/
│   ├── AWS-GUIDE.md         # step-by-step AWS setup
│   ├── update-private.sh    # run on the private servers by the pipeline
│   ├── nginx/               # public server: install.sh and nginx config template
│   ├── private1/            # app + MongoDB (Docker Compose), backup.sh
│   └── private2/            # app (Docker Compose)
├── jest.config.js
├── eslint.config.js
├── package.json
└── package-lock.json
```
