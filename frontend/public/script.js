const form = document.getElementById('user-form');
const usersBody = document.getElementById('users-body');
const messageEl = document.getElementById('message');

function showMessage(text, type) {
  messageEl.textContent = text;
  messageEl.className = type;
  setTimeout(() => {
    messageEl.textContent = '';
    messageEl.className = '';
  }, 3000);
}

function renderUsers(users) {
  usersBody.innerHTML = '';

  if (!users.length) {
    usersBody.innerHTML = '<tr class="empty-row"><td colspan="4">No users yet — add one above.</td></tr>';
    return;
  }

  users.forEach((user) => {
    const row = document.createElement('tr');
    row.innerHTML = `
      <td>${escapeHtml(user.name)}</td>
      <td>${escapeHtml(user.email)}</td>
      <td>${escapeHtml(user.city || '')}</td>
      <td><button class="delete-btn" data-id="${user._id}">Delete</button></td>
    `;
    usersBody.appendChild(row);
  });
}

function escapeHtml(str) {
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

async function loadUsers() {
  try {
    const res = await fetch('/api/users');
    if (!res.ok) throw new Error('Failed to load users');
    const users = await res.json();
    renderUsers(users);
  } catch (err) {
    showMessage(err.message, 'error');
  }
}

form.addEventListener('submit', async (e) => {
  e.preventDefault();

  const name = document.getElementById('name').value.trim();
  const email = document.getElementById('email').value.trim();
  const city = document.getElementById('city').value.trim();

  try {
    const res = await fetch('/api/users', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, email, city }),
    });

    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      throw new Error(data.error || 'Failed to add user');
    }

    form.reset();
    showMessage('User added.', 'success');
    loadUsers();
  } catch (err) {
    showMessage(err.message, 'error');
  }
});

usersBody.addEventListener('click', async (e) => {
  if (!e.target.classList.contains('delete-btn')) return;

  const id = e.target.dataset.id;
  try {
    const res = await fetch(`/api/users/${id}`, { method: 'DELETE' });
    if (!res.ok) throw new Error('Failed to delete user');
    loadUsers();
  } catch (err) {
    showMessage(err.message, 'error');
  }
});

loadUsers();
