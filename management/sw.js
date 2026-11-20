const CACHE_NAME = "peyvand-management-pwa-v4";
const SHELL = [
  "/management/",
  "/management/index.html",
  "/management/install.html",
  "/management/manifest.webmanifest",
  "/management/icons/icon.svg",
  "/management/icons/icon-192.png",
  "/management/icons/icon-512.png"
];
self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(
    keys.filter(key => key.startsWith("peyvand-management-pwa-") && key !== CACHE_NAME).map(key => caches.delete(key))
  )).then(() => self.clients.claim()));
});
self.addEventListener("fetch", event => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== self.location.origin || !url.pathname.startsWith("/management/")) return;
  event.respondWith(fetch(request).then(response => {
    if (response && response.ok) {
      const responseToCache = response.clone();
      caches.open(CACHE_NAME).then(cache => cache.put(request, responseToCache)).catch(() => {});
    }
    return response;
  }).catch(() => caches.match(request).then(cached => cached || Response.error())));
});
