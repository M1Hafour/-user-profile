// Mock the User model before requiring app, so app.js never touches a real DB.
jest.mock('../models/User');

const request = require('supertest');
const User = require('../models/User');
const app = require('../app');

describe('GET /api/users', () => {
  afterEach(() => jest.clearAllMocks());

  it('returns a list of users', async () => {
    const fakeUsers = [
      { _id: '1', name: 'Alice', email: 'alice@example.com', city: 'Cairo' },
      { _id: '2', name: 'Bob', email: 'bob@example.com', city: 'Giza' },
    ];
    User.find.mockReturnValue({ sort: jest.fn().mockResolvedValue(fakeUsers) });

    const res = await request(app).get('/api/users');

    expect(res.status).toBe(200);
    expect(res.body).toEqual(fakeUsers);
  });

  it('returns 500 if the database call fails', async () => {
    User.find.mockReturnValue({ sort: jest.fn().mockRejectedValue(new Error('db down')) });

    const res = await request(app).get('/api/users');

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: 'Failed to fetch users' });
  });
});

describe('POST /api/users', () => {
  afterEach(() => jest.clearAllMocks());

  it('creates a user when name and email are provided', async () => {
    const newUser = { _id: '3', name: 'Carol', email: 'carol@example.com', city: 'Alexandria' };
    User.create.mockResolvedValue(newUser);

    const res = await request(app)
      .post('/api/users')
      .send({ name: 'Carol', email: 'carol@example.com', city: 'Alexandria' });

    expect(res.status).toBe(201);
    expect(res.body).toEqual(newUser);
    expect(User.create).toHaveBeenCalledWith({
      name: 'Carol',
      email: 'carol@example.com',
      city: 'Alexandria',
    });
  });

  it('rejects with 400 when name is missing', async () => {
    const res = await request(app).post('/api/users').send({ email: 'no-name@example.com' });

    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: 'name and email are required' });
    expect(User.create).not.toHaveBeenCalled();
  });

  it('rejects with 400 when email is missing', async () => {
    const res = await request(app).post('/api/users').send({ name: 'No Email' });

    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: 'name and email are required' });
    expect(User.create).not.toHaveBeenCalled();
  });

  it('returns 500 if creation fails', async () => {
    User.create.mockRejectedValue(new Error('db down'));

    const res = await request(app)
      .post('/api/users')
      .send({ name: 'Dave', email: 'dave@example.com' });

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: 'Failed to create user' });
  });
});

describe('DELETE /api/users/:id', () => {
  afterEach(() => jest.clearAllMocks());

  it('deletes a user and returns 204', async () => {
    User.findByIdAndDelete.mockResolvedValue({ _id: '1' });

    const res = await request(app).delete('/api/users/1');

    expect(res.status).toBe(204);
    expect(User.findByIdAndDelete).toHaveBeenCalledWith('1');
  });

  it('returns 500 if deletion fails', async () => {
    User.findByIdAndDelete.mockRejectedValue(new Error('db down'));

    const res = await request(app).delete('/api/users/1');

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: 'Failed to delete user' });
  });
});

describe('GET /health', () => {
  it('returns status ok with a mongo connection state', async () => {
    const res = await request(app).get('/health');

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('status', 'ok');
    expect(res.body).toHaveProperty('mongo');
    expect(res.body).toHaveProperty('uptime');
  });
});
