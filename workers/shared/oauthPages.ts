// Minimal, self-contained OAuth login + consent pages served by the API worker.
// These are vanilla HTML/JS reimplementations of krabiclaw's Vue pages that talk
// to the better-auth endpoints over fetch. They are rendered inside the popup
// ChatGPT opens during the connector OAuth flow.

const BASE_STYLE = `
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: #0b0d12; color: #e7e9ee; padding: 32px 20px;
  }
  .card {
    width: 100%; max-width: 360px; background: #14171f; border: 1px solid #232733;
    border-radius: 16px; padding: 28px 24px; box-shadow: 0 12px 40px rgba(0,0,0,.45);
  }
  h1 { font-size: 20px; line-height: 1.3; margin: 0 0 6px; font-weight: 700; }
  p.sub { font-size: 13px; color: #9aa3b2; margin: 0 0 20px; }
  .btn {
    display: flex; align-items: center; justify-content: center; gap: 10px; width: 100%;
    border-radius: 999px; border: 1px solid #2c313d; background: #2563eb; color: #fff;
    font-size: 15px; font-weight: 600; padding: 12px 16px; cursor: pointer; margin-top: 12px;
  }
  .btn:hover { filter: brightness(1.06); }
  .btn[disabled] { opacity: .6; cursor: default; }
  .btn.secondary { background: transparent; color: #cdd3de; }
  .btn.ghost { background: transparent; border: none; color: #9aa3b2; font-weight: 500; font-size: 13px; padding: 8px; }
  .field { margin-top: 12px; text-align: left; }
  .field label { display: block; font-size: 12px; color: #9aa3b2; margin-bottom: 6px; }
  .field input {
    width: 100%; padding: 11px 12px; border-radius: 10px; border: 1px solid #2c313d;
    background: #0f1218; color: #e7e9ee; font-size: 14px;
  }
  .divider { display: flex; align-items: center; gap: 12px; margin: 16px 0; color: #6b7280; font-size: 11px; letter-spacing: .12em; text-transform: uppercase; }
  .divider::before, .divider::after { content: ""; flex: 1; height: 1px; background: #232733; }
  .perm { display: flex; gap: 12px; align-items: flex-start; margin-bottom: 16px; }
  .perm .dot { width: 8px; height: 8px; border-radius: 50%; background: #2563eb; margin-top: 6px; flex-shrink: 0; }
  .perm .ptitle { font-size: 14px; font-weight: 600; margin: 0; }
  .perm .pitem { font-size: 13px; color: #9aa3b2; margin: 2px 0 0; }
  .error { background: #2a1416; border: 1px solid #5b2326; color: #f3b3b6; font-size: 13px; border-radius: 10px; padding: 10px 12px; margin-bottom: 12px; }
  .acct { display: flex; align-items: center; gap: 10px; border: 1px solid #232733; background: #0f1218; border-radius: 12px; padding: 12px; margin-bottom: 4px; }
  .acct .name { font-size: 14px; font-weight: 600; }
  .acct .email { font-size: 12px; color: #9aa3b2; }
  .hidden { display: none !important; }
  .foot { font-size: 11px; color: #6b7280; margin-top: 18px; text-align: center; }
`;

export function renderLoginPage(opts: { googleEnabled: boolean }): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta name="robots" content="noindex, nofollow" />
<title>Sign in - Sky AI</title>
<style>${BASE_STYLE}</style>
</head>
<body>
  <div class="card">
    <h1 id="title">Sign in to connect</h1>
    <p class="sub" id="subtitle">Sign in to grant access to an external application.</p>

    <div id="error" class="error hidden"></div>

    <!-- Existing session -->
    <div id="session-view" class="hidden">
      <div class="acct">
        <div style="flex:1; min-width:0;">
          <div class="name" id="session-name">Your account</div>
          <div class="email" id="session-email"></div>
        </div>
      </div>
      <button class="btn" id="continue-btn">Continue</button>
      <div class="divider">or</div>
      <button class="btn secondary" id="switch-btn">Sign in with a different account</button>
    </div>

    <!-- Sign-in options -->
    <div id="signin-view" class="hidden">
      <button class="btn secondary ${opts.googleEnabled ? '' : 'hidden'}" id="google-btn">Continue with Google</button>
      <div class="divider ${opts.googleEnabled ? '' : 'hidden'}">or</div>

      <div class="field">
        <label for="email">Email</label>
        <input id="email" type="email" autocomplete="email" placeholder="you@example.com" />
      </div>
      <div class="field">
        <label for="password">Password</label>
        <input id="password" type="password" autocomplete="current-password" placeholder="••••••••" />
      </div>
      <div class="field hidden" id="name-field">
        <label for="name">Name</label>
        <input id="name" type="text" autocomplete="name" placeholder="Your name" />
      </div>
      <button class="btn" id="email-btn">Sign in</button>
      <button class="btn ghost" id="toggle-mode">Need an account? Sign up</button>
    </div>
  </div>

<script>
(function () {
  var search = window.location.search;
  var origin = window.location.origin;
  var authorizeUrl = origin + "/api/auth/oauth2/authorize" + search;
  var params = new URLSearchParams(search);
  var clientId = params.get("client_id");
  var mode = "signin";

  var el = function (id) { return document.getElementById(id); };
  function showError(msg) { var e = el("error"); e.textContent = msg; e.classList.remove("hidden"); }
  function clearError() { el("error").classList.add("hidden"); }

  async function api(path, body) {
    var res = await fetch(path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body || {}),
      credentials: "include",
    });
    var data = null;
    try { data = await res.json(); } catch (e) {}
    if (!res.ok) { throw new Error((data && (data.message || data.error)) || ("Request failed (" + res.status + ")")); }
    return data;
  }

  async function loadClientName() {
    if (!clientId) return;
    try {
      var data = await api("/api/auth/oauth2/public-client-prelogin", { client_id: clientId, oauth_query: search.slice(1) });
      if (data && data.client_name) {
        el("title").textContent = "Sign in to connect";
        el("subtitle").innerHTML = "<strong>" + escapeHtml(data.client_name) + "</strong> is requesting access to your Sky AI account.";
      }
    } catch (e) {}
  }

  function escapeHtml(s) { return String(s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }

  async function loadSession() {
    try {
      var res = await fetch("/api/auth/get-session", { credentials: "include", headers: { "content-type": "application/json" } });
      var data = await res.json();
      return data && data.user ? data.user : null;
    } catch (e) { return null; }
  }

  el("continue-btn").addEventListener("click", function () { window.location.href = authorizeUrl; });

  el("switch-btn").addEventListener("click", async function () {
    try { await api("/api/auth/sign-out", {}); } catch (e) {}
    el("session-view").classList.add("hidden");
    el("signin-view").classList.remove("hidden");
  });

  el("google-btn").addEventListener("click", async function () {
    clearError();
    el("google-btn").disabled = true;
    try {
      var data = await api("/api/auth/sign-in/social", { provider: "google", callbackURL: authorizeUrl });
      if (data && data.url) { window.location.href = data.url; return; }
      window.location.href = authorizeUrl;
    } catch (e) { showError("Google sign in failed. Please try again."); el("google-btn").disabled = false; }
  });

  el("toggle-mode").addEventListener("click", function () {
    mode = mode === "signin" ? "signup" : "signin";
    el("name-field").classList.toggle("hidden", mode !== "signup");
    el("email-btn").textContent = mode === "signup" ? "Create account" : "Sign in";
    el("toggle-mode").textContent = mode === "signup" ? "Have an account? Sign in" : "Need an account? Sign up";
    el("password").setAttribute("autocomplete", mode === "signup" ? "new-password" : "current-password");
  });

  el("email-btn").addEventListener("click", async function () {
    clearError();
    var email = el("email").value.trim();
    var password = el("password").value;
    if (!email || !password) { showError("Enter your email and password."); return; }
    el("email-btn").disabled = true;
    try {
      if (mode === "signup") {
        await api("/api/auth/sign-up/email", { email: email, password: password, name: el("name").value.trim() || email, callbackURL: authorizeUrl });
      } else {
        await api("/api/auth/sign-in/email", { email: email, password: password, callbackURL: authorizeUrl });
      }
      window.location.href = authorizeUrl;
    } catch (e) { showError(e.message || "Sign in failed."); el("email-btn").disabled = false; }
  });

  (async function init() {
    await loadClientName();
    var user = await loadSession();
    if (user) {
      el("title").textContent = "Connect your account";
      el("session-name").textContent = user.name || "Your account";
      el("session-email").textContent = user.email || "";
      el("continue-btn").textContent = "Continue as " + ((user.name && user.name.split(" ")[0]) || "this account");
      el("session-view").classList.remove("hidden");
    } else {
      el("signin-view").classList.remove("hidden");
    }
  })();
})();
</script>
</body>
</html>`;
}

export function renderConsentPage(): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta name="robots" content="noindex, nofollow" />
<title>Authorize - Sky AI</title>
<style>${BASE_STYLE}</style>
</head>
<body>
  <div class="card">
    <h1 id="title">This app wants to access your Sky AI account.</h1>
    <p class="sub" id="account-line"></p>

    <p style="font-size:13px; font-weight:600; margin:0 0 14px;">You agree that <span id="app-name">this app</span> will be able to:</p>
    <div id="perms"></div>

    <div id="error" class="error hidden"></div>

    <button class="btn" id="agree-btn">Agree</button>
    <button class="btn ghost" id="cancel-btn">Cancel</button>

    <p class="foot">You can remove this access at any time from your account settings.</p>
  </div>

<script>
(function () {
  var search = window.location.search;
  var params = new URLSearchParams(search);
  var clientId = params.get("client_id");

  var SCOPE_INFO = {
    openid: { title: "Verify your identity", item: "Confirm you are who you say you are" },
    sky: { title: "Access your synced data", item: "Read your mail, calendar events, messages, and contacts" }
  };

  var el = function (id) { return document.getElementById(id); };
  function showError(msg) { var e = el("error"); e.textContent = msg; e.classList.remove("hidden"); }
  function clearError() { el("error").classList.add("hidden"); }
  function escapeHtml(s) { return String(s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }

  async function api(path, body) {
    var res = await fetch(path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body || {}),
      credentials: "include",
    });
    var data = null;
    try { data = await res.json(); } catch (e) {}
    if (!res.ok) { throw new Error((data && (data.message || data.error)) || ("Request failed (" + res.status + ")")); }
    return data;
  }

  function renderPerms() {
    var raw = params.get("scope") || "openid sky";
    var scopes = raw.split(" ").filter(Boolean);
    var container = el("perms");
    container.innerHTML = "";
    var known = { openid: 1, sky: 1, offline_access: 1 };
    scopes.forEach(function (s) {
      if (s === "offline_access") return;
      var info = SCOPE_INFO[s] || { title: s, item: "Additional permission" };
      var div = document.createElement("div");
      div.className = "perm";
      div.innerHTML = '<div class="dot"></div><div><p class="ptitle">' + escapeHtml(info.title) + '</p><p class="pitem">' + escapeHtml(info.item) + '</p></div>';
      container.appendChild(div);
    });
  }

  async function finish(accept) {
    clearError();
    el("agree-btn").disabled = true;
    el("cancel-btn").disabled = true;
    try {
      var result = await api("/api/auth/oauth2/consent", { accept: accept, oauth_query: search.slice(1) });
      if (result && result.url) { window.location.href = result.url; return; }
      showError("Could not complete authorization.");
      el("agree-btn").disabled = false;
      el("cancel-btn").disabled = false;
    } catch (e) {
      showError(e.message || "Something went wrong. Please try again.");
      el("agree-btn").disabled = false;
      el("cancel-btn").disabled = false;
    }
  }

  el("agree-btn").addEventListener("click", function () { finish(true); });
  el("cancel-btn").addEventListener("click", function () { finish(false); });

  (async function init() {
    renderPerms();
    if (clientId) {
      try {
        var data = await api("/api/auth/oauth2/public-client-prelogin", { client_id: clientId, oauth_query: search.slice(1) });
        if (data && data.client_name) {
          el("app-name").textContent = data.client_name;
          el("title").textContent = data.client_name + " wants to access your Sky AI account.";
        }
      } catch (e) {}
    }
    try {
      var res = await fetch("/api/auth/get-session", { credentials: "include", headers: { "content-type": "application/json" } });
      var session = await res.json();
      if (session && session.user) {
        el("account-line").textContent = "Logged in as " + (session.user.name || session.user.email);
      }
    } catch (e) {}
  })();
})();
</script>
</body>
</html>`;
}
