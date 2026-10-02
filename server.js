const mongoose = require('mongoose');
const app = require('./app');

const PORT = process.env.PORT || 3000;

// Build the Mongo connection string from either a single MONGO_URI
// or individual MONGO_* pieces (handy for docker-compose service names).
const MONGO_URI =
  process.env.MONGO_URI ||
  `mongodb://${process.env.MONGO_USERNAME}:${process.env.MONGO_PASSWORD}@${
    process.env.MONGO_HOSTNAME || 'localhost'
  }:${process.env.MONGO_PORT || 27017}/${
    process.env.MONGO_DB || 'my-db'
  }?authSource=admin`;

// --- Connect to MongoDB, then start the server ---
mongoose
  .connect(MONGO_URI)
  .then(() => {
    console.log('Connected to MongoDB');
    app.listen(PORT, () => {
      console.log(`Server running at http://localhost:${PORT}`);
    });
  })
  .catch((err) => {
    console.error('Failed to connect to MongoDB:', err.message);
    process.exit(1);
  });
