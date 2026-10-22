const { env, apiUrl } = window.APP_CONFIG;

const badge = document.getElementById("env-badge");
badge.textContent = env.toUpperCase();
badge.dataset.env = env;

document.getElementById("form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const result = document.getElementById("result");
  const name = document.getElementById("name").value.trim();
  const url = `${apiUrl}/api/hello${name ? `?name=${encodeURIComponent(name)}` : ""}`;

  result.textContent = `GET ${url} …`;
  try {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    result.textContent = JSON.stringify(await response.json(), null, 2);
  } catch (error) {
    result.textContent = `Erreur : ${error.message}`;
  }
});
