/* DexCraft : service worker des notifications seulement (1.10.0). Il ne garde rien en cache et n'intercepte aucune requête :
   une page en cache avec un serveur plus récent casserait le jeu. Rangé dans images/ pour être publié sans changer la commande
   de Cloudflare Pages ; l'en-tête Service-Worker-Allowed de _headers lui permet de s'occuper de tout le site. */
self.addEventListener("install",()=>self.skipWaiting());
self.addEventListener("activate",e=>e.waitUntil(self.clients.claim()));
self.addEventListener("push",e=>{
  let d={};
  try{d=e.data?e.data.json():{}}catch(x){d={body:e.data?e.data.text():""}}
  e.waitUntil(self.registration.showNotification(d.title||"DexCraft",{body:d.body||"",icon:"/images/app/icon-192.png",tag:"dc-"+(d.kind||"info"),data:{kind:d.kind||""}}));
});
self.addEventListener("notificationclick",e=>{
  e.notification.close();
  e.waitUntil(self.clients.matchAll({type:"window",includeUncontrolled:true}).then(cl=>{
    for(const c of cl){if(new URL(c.url).origin===self.location.origin&&"focus" in c)return c.focus()}
    return self.clients.openWindow("/");
  }));
});
