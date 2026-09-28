const express = require('express');
const mongoose = require('mongoose');
const path = require('path');
const User = require('./models/User');

const app = express();
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

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// --- REST API ---

// List all users
app.get('/api/users', async (req, res) => {
  try {
    const users = await User.find().sort({ createdAt: -1 });
    res.json(users);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to fetch users' });
  }
});

// Create a user
app.post('/api/users', async (req, res) => {
  try {
    const { name, email, city } = req.body;
    if (!name || !email) {
      return res.status(400).json({ error: 'name and email are required' });
    }
    const user = await User.create({ name, email, city });
    res.status(201).json(user);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to create user' });
  }
});

// Delete a user
app.delete('/api/users/:id', async (req, res) => {
  try {
    await User.findByIdAndDelete(req.params.id);
    res.status(204).end();
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to delete user' });
  }
});

// Simple health check, useful for docker healthchecks / load balancers
app.get('/health', (req, res) => {
  const mongoStatus = mongoose.connection.readyState === 1 ? 'connected' : 'disconnected';
  res.json({ status: 'ok', mongo: mongoStatus, uptime: process.uptime() });
});

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
