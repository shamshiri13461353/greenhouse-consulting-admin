const CACHE_NAME = "greenhouse-mobile-shell-v3";
const MOBILE_PATH = new URL("mobile/", self.registration.scope).pathname;
const SHELL_URLS = [
  new URL("mobile/", self.registration.scope).href,
  new URL("mobile/manifest.webmanifest", self.registration.scope).href,
  new URL("mobile/icons/icon.svg", self.registration.scope).href
];

self.addEventListener("install", event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(SHELL_URLS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(key => key !== CACHE_NAME).map(key => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("push", event => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; }
  catch { data = { body: event.data?.text() || "" }; }
  const title = data.title || "سامانه مشاوره گلخانه";
  const options = {
    body: data.body || "اعلان جدیدی در سامانه دارید.",
    icon: new URL("mobile/icons/icon.svg", self.registration.scope).href,
    badge: new URL("mobile/icons/icon.svg", self.registration.scope).href,
    data: { url: data.url || "/mobile/" },
    tag: data.tag || "greenhouse-system-notification"
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", event => {
  event.notification.close();
  const target = new URL(event.notification.data?.url || "/mobile/", self.registration.scope).href;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const client of windows) {
      if (client.url.startsWith(self.registration.scope) && "focus" in client) {
        await client.focus();
        if ("navigate" in client && client.url !== target) await client.navigate(target);
        return;
      }
    }
    await self.clients.openWindow(target);
  })());
});

self.addEventListener("fetch", event => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin || !url.pathname.startsWith(MOBILE_PATH)) return;

  event.respondWith((async () => {
    try {
      const response = await fetch(request);
      if (response.ok && (request.mode === "navigate" || SHELL_URLS.includes(request.url))) {
        const cache = await caches.open(CACHE_NAME);
        cache.put(request, response.clone());
      }
      return response;
    } catch {
      const cached = await caches.match(request);
      if (cached) return cached;
      if (request.mode === "navigate") {
        return (await caches.match(SHELL_URLS[0])) || Response.error();
      }
      return Response.error();
    }
  })());
});